package com.wirelessmic.sender

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
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

    // DJ-mode extra resources
    private var djPlaybackRecord: AudioRecord? = null
    private var mediaProjection: MediaProjection? = null

    @Volatile private var isStreaming = false

    // Plugin sets this to receive metrics callbacks on the main thread.
    // level is the peak mic amplitude over the last window, normalized 0..1.
    var metricsListener: ((sequenceNumber: Long, timestampMs: Long, level: Double) -> Unit)? = null

    companion object {
        const val ACTION_STOP = "com.wirelessmic.sender.STOP_STREAMING"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_MODE = "mode"
        const val EXTRA_PROJECTION_RESULT_CODE = "projection_result_code"
        const val EXTRA_PROJECTION_DATA = "projection_data"
        const val NOTIFICATION_ID = 1
        const val CHANNEL_ID = "evermic_mic"
        const val TAG = "evermic"

        // ── MIC mode constants (unchanged) ────────────────────────────────────
        private const val SAMPLE_RATE = 16_000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val BYTES_PER_SAMPLE = 2
        private const val CHUNK_MS = 10
        private const val HEADER_BYTES = 19
        private const val METRICS_INTERVAL = 5L     // ~50ms @ 10ms chunks → smooth VU meter

        // ── DJ mode constants ─────────────────────────────────────────────────
        private const val DJ_SAMPLE_RATE = 48_000
        // 5 ms chunk at 48 kHz stereo = 240 frames → 960-byte payload (979 total, under MTU)
        private const val DJ_CHUNK_FRAMES = 240
        private const val DJ_METRICS_INTERVAL = 10L  // ~50ms @ 5ms chunks → ~20 Hz VU
        private const val MUSIC_GAIN = 0.85f
        private const val MIC_GAIN = 1.0f
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
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: "mic"

        if (mode == "dj") {
            val resultCode = intent.getIntExtra(EXTRA_PROJECTION_RESULT_CODE, 0)
            val projectionData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_PROJECTION_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(EXTRA_PROJECTION_DATA)
            }
            if (projectionData == null) {
                Log.e(TAG, "DJ mode: missing projection data")
                stopSelf()
                return START_NOT_STICKY
            }
            // Android 14 ordering: start foreground with mediaProjection type BEFORE
            // calling getMediaProjection. Also include microphone type since we use the mic.
            startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            startDj(host, port, resultCode, projectionData)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            startAudio(host, port)
        }

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

    // ── MIC mode (unchanged) ──────────────────────────────────────────────────

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

    // ── DJ mode ───────────────────────────────────────────────────────────────

    private fun startDj(host: String, port: Int, resultCode: Int, projectionData: Intent) {
        if (isStreaming) return

        try {
            // Build MediaProjection (FGS with mediaProjection type already started above).
            // Register a no-op Callback on a Handler — required by API 34+ before creating
            // the playback AudioRecord; without it getMediaProjection throws.
            val mpManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val mp = mpManager.getMediaProjection(resultCode, projectionData)
                ?: throw IllegalStateException("getMediaProjection returned null")
            mp.registerCallback(object : MediaProjection.Callback() {}, Handler(Looper.getMainLooper()))
            mediaProjection = mp

            // Mic AudioRecord at 48 kHz mono — skip AGC and AEC (they mangle music);
            // NoiseSuppressor on the mic channel is safe to keep.
            val micMinBuf = AudioRecord.getMinBufferSize(
                DJ_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            )
            val micBufBytes = max(micMinBuf, DJ_CHUNK_FRAMES * BYTES_PER_SAMPLE * 4)
            val micAr = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                DJ_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                micBufBytes
            )
            check(micAr.state == AudioRecord.STATE_INITIALIZED) { "DJ mic AudioRecord failed to init" }
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(micAr.audioSessionId)

            // Playback capture AudioRecord at 48 kHz stereo
            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(mp)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val playbackMinBuf = AudioRecord.getMinBufferSize(
                DJ_SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT
            )
            val playbackBufBytes = max(playbackMinBuf, DJ_CHUNK_FRAMES * 2 * BYTES_PER_SAMPLE * 4)
            val playbackAr = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(captureConfig)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(DJ_SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(playbackBufBytes)
                .build()
            check(playbackAr.state == AudioRecord.STATE_INITIALIZED) { "DJ playback AudioRecord failed to init" }

            // Unconnected socket — same invariant as MIC mode (fire-and-forget, explicit destination).
            val sock = DatagramSocket()
            val address = InetAddress.getByName(host)

            audioRecord = micAr
            djPlaybackRecord = playbackAr
            socket = sock
            isStreaming = true

            micAr.startRecording()
            playbackAr.startRecording()
            Log.i(TAG, "DJ streaming started -> $host:$port")

            streamingThread = Thread({ djStreamingLoop(address, port) }, "dj-audio-stream")
                .also { it.priority = Thread.MAX_PRIORITY; it.start() }

        } catch (e: Exception) {
            Log.e(TAG, "startDj failed", e)
            cleanupResources()
            stopSelf()
        }
    }

    private fun djStreamingLoop(address: InetAddress, port: Int) {
        // Per chunk: DJ_CHUNK_FRAMES mic samples (mono) + DJ_CHUNK_FRAMES*2 playback samples (stereo).
        // Payload = DJ_CHUNK_FRAMES * 2 channels * 2 bytes = DJ_CHUNK_FRAMES * 4 bytes.
        // At 240 frames: 960-byte payload, 979-byte packet — safely under 1500 MTU.
        //
        // NOTE: sequential blocking reads from two AudioRecords at the same sample rate keeps
        // them roughly aligned for MVP. Long sessions (hours) may accumulate drift; if that
        // matters, replace with per-source ring buffers and a mixing thread.
        val micBuf = ShortArray(DJ_CHUNK_FRAMES)                // mono
        val playbackBuf = ShortArray(DJ_CHUNK_FRAMES * 2)       // interleaved stereo
        val payloadBytes = DJ_CHUNK_FRAMES * 2 * BYTES_PER_SAMPLE  // 960 bytes
        val packetBytes = ByteArray(HEADER_BYTES + payloadBytes)
        var sequenceNumber = 0L
        var windowPeak = 0

        while (isStreaming) {
            val micRead = audioRecord?.read(micBuf, 0, DJ_CHUNK_FRAMES) ?: break
            if (micRead < 0) {
                Log.e(TAG, "DJ mic AudioRecord.read error $micRead")
                break
            }

            val pbRead = djPlaybackRecord?.read(playbackBuf, 0, DJ_CHUNK_FRAMES * 2) ?: break
            if (pbRead < 0) {
                Log.e(TAG, "DJ playback AudioRecord.read error $pbRead")
                break
            }

            val nowMs = System.currentTimeMillis()

            // Build header (BIG_ENDIAN fields — receiver reads with struct.unpack(">iQBHBBH")).
            // sampleRate written as (48000 & 0xFFFF).toShort() so the unsigned u16 field on
            // the receiver decodes back to 48000 correctly (48000 > 32767, signed short is -17536,
            // but ">H" unsigned unpack reads the same two bytes as 48000).
            val headerBuf = ByteBuffer.wrap(packetBytes, 0, HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
            headerBuf.putInt(sequenceNumber.toInt())
            headerBuf.putLong(nowMs)
            headerBuf.put(0)                                    // flags
            headerBuf.putShort((DJ_SAMPLE_RATE and 0xFFFF).toShort())
            headerBuf.put(2)                                    // channels = stereo
            headerBuf.put(0)                                    // codec = PCM16
            headerBuf.putShort(payloadBytes.toShort())

            // Mix and write payload as little-endian int16 (matching the MIC path's native
            // AudioRecord byte order — do NOT use the BIG_ENDIAN ByteBuffer for the payload).
            var payloadOff = HEADER_BYTES
            for (i in 0 until micRead) {
                val micSample = micBuf[i].toInt()
                val pbIdx = i * 2
                val playL = if (pbIdx < pbRead) playbackBuf[pbIdx].toInt() else 0
                val playR = if (pbIdx + 1 < pbRead) playbackBuf[pbIdx + 1].toInt() else 0

                val mixL = clamp16((playL * MUSIC_GAIN + micSample * MIC_GAIN).toInt())
                val mixR = clamp16((playR * MUSIC_GAIN + micSample * MIC_GAIN).toInt())

                // Track peak over both channels for VU meter
                val peakL = abs(mixL)
                val peakR = abs(mixR)
                if (peakL > windowPeak) windowPeak = peakL
                if (peakR > windowPeak) windowPeak = peakR

                // little-endian int16
                packetBytes[payloadOff++] = (mixL and 0xFF).toByte()
                packetBytes[payloadOff++] = ((mixL shr 8) and 0xFF).toByte()
                packetBytes[payloadOff++] = (mixR and 0xFF).toByte()
                packetBytes[payloadOff++] = ((mixR shr 8) and 0xFF).toByte()
            }

            val actualPayload = micRead * 2 * BYTES_PER_SAMPLE

            try {
                // Unconnected socket — fire-and-forget with explicit destination (same invariant as MIC mode).
                socket?.send(DatagramPacket(packetBytes, HEADER_BYTES + actualPayload, address, port))
            } catch (e: Exception) {
                Log.e(TAG, "DJ send failed at seq=$sequenceNumber -> $address:$port", e)
                break
            }

            sequenceNumber++

            if (sequenceNumber % DJ_METRICS_INTERVAL == 0L) {
                val seq = sequenceNumber
                val ts = nowMs
                val level = windowPeak / 32768.0
                windowPeak = 0
                mainHandler.post { metricsListener?.invoke(seq, ts, level) }
            }
        }

        // Fatal error path: clean up both AudioRecords, socket, and MediaProjection.
        Log.i(TAG, "DJ streaming loop exited, cleaning up")
        isStreaming = false
        cleanupResources()
    }

    private fun clamp16(value: Int): Int = when {
        value > 32767  ->  32767
        value < -32768 -> -32768
        else           ->  value
    }

    // ── Shared stop/cleanup ───────────────────────────────────────────────────

    fun stopStreaming() {
        isStreaming = false
        streamingThread?.join(500)
        streamingThread = null
        cleanupResources()
    }

    @Synchronized
    private fun cleanupResources() {
        audioRecord?.apply { stop(); release() }
        audioRecord = null
        djPlaybackRecord?.apply { stop(); release() }
        djPlaybackRecord = null
        socket?.close()
        socket = null
        mediaProjection?.stop()
        mediaProjection = null
    }
}
