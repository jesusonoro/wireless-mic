package com.wirelessmic.sender

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

class AudioForegroundService : Service() {

    inner class LocalBinder : Binder() {
        fun getService(): AudioForegroundService = this@AudioForegroundService
    }

    private val binder = LocalBinder()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioRecord: AudioRecord? = null
    private var socket: DatagramSocket? = null
    private var streamingThread: Thread? = null

    @Volatile private var isStreaming = false

    // Plugin sets this to receive metrics callbacks on the main thread.
    // level is the peak mic amplitude over the last window, normalized 0..1.
    var metricsListener: ((sequenceNumber: Long, timestampMs: Long, level: Double) -> Unit)? = null

    companion object {
        const val ACTION_STOP = "com.wirelessmic.sender.STOP_STREAMING"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val NOTIFICATION_ID = 1
        const val CHANNEL_ID = "evermic_mic"
        const val TAG = "evermic"

        private const val SAMPLE_RATE = 16_000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val BYTES_PER_SAMPLE = 2
        private const val CHUNK_MS = 10
        private const val HEADER_BYTES = 19
        private const val METRICS_INTERVAL = 5L     // ~50ms @ 10ms chunks → smooth VU meter
    }

    override fun onBind(intent: Intent): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopStreaming()
            stopSelf()
            return START_NOT_STICKY
        }

        val host = intent?.getStringExtra(EXTRA_HOST) ?: run { stopSelf(); return START_NOT_STICKY }
        val port = intent.getIntExtra(EXTRA_PORT, 7355)

        startForeground(NOTIFICATION_ID, buildNotification())
        startAudio(host, port)

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopStreaming()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, AudioForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPi = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("evermic")
            .setContentText("Streaming…")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(null, "Stop", stopPi).build()
            )
            .build()
    }

    private fun startAudio(host: String, port: Int) {
        if (isStreaming) return

        val chunkSamples = SAMPLE_RATE * CHUNK_MS / 1000      // 160 samples
        val chunkBytes = chunkSamples * BYTES_PER_SAMPLE       // 320 bytes
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufferBytes = max(minBuffer, chunkBytes * 4)

        try {
            val ar = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferBytes
            )
            check(ar.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord failed to initialise" }

            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(ar.audioSessionId)
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(ar.audioSessionId)
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(ar.audioSessionId)

            // Unconnected socket: send fire-and-forget with an explicit destination.
            // A connected DatagramSocket would throw on send if the route ever
            // hiccups (or surfaces an async ICMP error), killing the whole stream.
            val sock = DatagramSocket()
            val address = InetAddress.getByName(host)

            audioRecord = ar
            socket = sock
            isStreaming = true
            ar.startRecording()
            Log.i(TAG, "streaming started -> $host:$port (state=${ar.recordingState})")

            streamingThread = Thread({ streamingLoop(chunkBytes, address, port) }, "audio-stream")
                .also { it.priority = Thread.MAX_PRIORITY; it.start() }

        } catch (e: Exception) {
            Log.e(TAG, "startAudio failed", e)
            cleanupResources()
            stopSelf()
        }
    }

    private fun streamingLoop(chunkBytes: Int, address: InetAddress, port: Int) {
        val audioBuffer = ByteArray(chunkBytes)
        val packetBytes = ByteArray(HEADER_BYTES + chunkBytes)
        var sequenceNumber = 0L
        var windowPeak = 0          // loudest |sample| since the last metrics post

        while (isStreaming) {
            val read = audioRecord?.read(audioBuffer, 0, chunkBytes) ?: break
            if (read <= 0) {
                if (read < 0) Log.w(TAG, "AudioRecord.read error $read")
                continue
            }

            val nowMs = System.currentTimeMillis()

            // Track peak amplitude for the input-level meter (PCM16 little-endian).
            var bi = 0
            while (bi + 1 < read) {
                val sample = ((audioBuffer[bi + 1].toInt() shl 8) or
                              (audioBuffer[bi].toInt() and 0xFF)).toShort().toInt()
                val mag = if (sample < 0) -sample else sample
                if (mag > windowPeak) windowPeak = mag
                bi += 2
            }

            val bb = ByteBuffer.wrap(packetBytes).order(ByteOrder.BIG_ENDIAN)
            bb.putInt(sequenceNumber.toInt())
            bb.putLong(nowMs)
            bb.put(0)                         // flags
            bb.putShort(SAMPLE_RATE.toShort())
            bb.put(1)                         // channels = mono
            bb.put(0)                         // codec = PCM16
            bb.putShort(read.toShort())
            System.arraycopy(audioBuffer, 0, packetBytes, HEADER_BYTES, read)

            try {
                socket?.send(DatagramPacket(packetBytes, HEADER_BYTES + read, address, port))
            } catch (e: Exception) {
                Log.e(TAG, "send failed at seq=$sequenceNumber -> $address:$port", e)
                break
            }

            sequenceNumber++

            if (sequenceNumber % METRICS_INTERVAL == 0L) {
                val seq = sequenceNumber
                val ts = nowMs
                val level = windowPeak / 32768.0
                windowPeak = 0
                mainHandler.post { metricsListener?.invoke(seq, ts, level) }
            }
        }
    }

    fun stopStreaming() {
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
