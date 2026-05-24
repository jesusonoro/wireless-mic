package com.wirelessmic.sender

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

class AudioStreamPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    // Mutable state guarded by @Volatile / thread confinement to streamingThread
    private var audioRecord: AudioRecord? = null
    private var socket: DatagramSocket? = null
    private var streamingThread: Thread? = null

    @Volatile private var isStreaming = false
    private var eventSink: EventChannel.EventSink? = null

    companion object {
        private const val SAMPLE_RATE = 16_000       // Hz
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val BYTES_PER_SAMPLE = 2
        private const val CHUNK_MS = 10              // 10ms frames → 50 fps
        private const val HEADER_BYTES = 19
        private const val METRICS_INTERVAL = 50L     // emit metrics every 50 packets (~1s)
    }

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "com.wirelessmic/audio")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "com.wirelessmic/audio_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopStreaming()
    }

    // ── MethodCallHandler ─────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val host = call.argument<String>("host") ?: run {
                    result.error("INVALID_ARG", "host is required", null); return
                }
                val port = call.argument<Int>("port") ?: 7355
                startStreaming(host, port, result)
            }
            "stop" -> {
                stopStreaming()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ── EventChannel.StreamHandler ────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── Core logic ────────────────────────────────────────────────────────────

    private fun startStreaming(host: String, port: Int, result: MethodChannel.Result) {
        if (isStreaming) {
            result.error("ALREADY_RUNNING", "Already streaming", null)
            return
        }

        val chunkSamples = SAMPLE_RATE * CHUNK_MS / 1000     // 160 samples
        val chunkBytes = chunkSamples * BYTES_PER_SAMPLE      // 320 bytes
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufferBytes = max(minBuffer, chunkBytes * 4)      // at least 4 chunks

        try {
            val ar = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferBytes
            )
            check(ar.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord failed to initialise" }

            // Apply hardware DSP if available
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(ar.audioSessionId)
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(ar.audioSessionId)
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(ar.audioSessionId)

            val sock = DatagramSocket()
            val address = InetAddress.getByName(host)
            sock.connect(address, port)

            audioRecord = ar
            socket = sock
            isStreaming = true
            ar.startRecording()

            streamingThread = Thread({ streamingLoop(chunkBytes, address, port) }, "audio-stream")
                .also { it.priority = Thread.MAX_PRIORITY; it.start() }

            result.success(null)
        } catch (e: Exception) {
            cleanupResources()
            result.error("START_FAILED", e.message, null)
        }
    }

    private fun streamingLoop(chunkBytes: Int, address: InetAddress, port: Int) {
        val audioBuffer = ByteArray(chunkBytes)
        // Pre-allocate the packet buffer: header + audio payload
        val packetBytes = ByteArray(HEADER_BYTES + chunkBytes)
        var sequenceNumber = 0L

        while (isStreaming) {
            val read = audioRecord?.read(audioBuffer, 0, chunkBytes) ?: break
            if (read <= 0) continue

            val nowMs = System.currentTimeMillis()

            // ── Build packet header (19 bytes, big-endian) ──────────────────
            // [0..3]  sequence number (uint32)
            // [4..11] sender timestamp ms (int64)
            // [12]    flags (reserved)
            // [13..14] sample rate (uint16)
            // [15]    channels (uint8)
            // [16]    codec: 0=PCM16LE
            // [17..18] payload length (uint16)
            val bb = ByteBuffer.wrap(packetBytes).order(ByteOrder.BIG_ENDIAN)
            bb.putInt(sequenceNumber.toInt())
            bb.putLong(nowMs)
            bb.put(0)                        // flags
            bb.putShort(SAMPLE_RATE.toShort())
            bb.put(1)                        // channels = 1 (mono)
            bb.put(0)                        // codec = PCM
            bb.putShort(read.toShort())
            System.arraycopy(audioBuffer, 0, packetBytes, HEADER_BYTES, read)

            try {
                socket?.send(DatagramPacket(packetBytes, HEADER_BYTES + read, address, port))
            } catch (_: Exception) {
                break  // socket closed during shutdown
            }

            sequenceNumber++

            if (sequenceNumber % METRICS_INTERVAL == 0L) {
                val seq = sequenceNumber
                val ts = nowMs
                mainHandler.post {
                    eventSink?.success(mapOf("sequenceNumber" to seq, "timestampMs" to ts))
                }
            }
        }
    }

    private fun stopStreaming() {
        isStreaming = false
        streamingThread?.join(500)
        streamingThread = null
        cleanupResources()
    }

    private fun cleanupResources() {
        audioRecord?.apply { stop(); release() }
        audioRecord = null
        socket?.close()
        socket = null
    }
}
