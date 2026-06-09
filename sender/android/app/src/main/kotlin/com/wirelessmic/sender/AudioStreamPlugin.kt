package com.wirelessmic.sender

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class AudioStreamPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context

    private var audioService: AudioForegroundService? = null
    private var isBound = false
    private var eventSink: EventChannel.EventSink? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    // Activity binding for MediaProjection consent dialog
    private var activityBinding: ActivityPluginBinding? = null

    // Stashed DJ args while we wait for the consent result
    private var pendingDjHost: String? = null
    private var pendingDjPort: Int = 7355

    companion object {
        private const val REQ_MEDIA_PROJECTION = 1001
        private const val TAG = "evermic"
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val svc = (binder as AudioForegroundService.LocalBinder).getService()
            audioService = svc
            isBound = true
            svc.metricsListener = { seq, ts, level ->
                eventSink?.success(
                    mapOf("sequenceNumber" to seq, "timestampMs" to ts, "level" to level)
                )
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            audioService = null
            isBound = false
        }
    }

    private val activityResultListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
        if (requestCode != REQ_MEDIA_PROJECTION) return@ActivityResultListener false
        if (resultCode == Activity.RESULT_OK && data != null) {
            val host = pendingDjHost
            val port = pendingDjPort
            if (host == null) {
                Log.e(TAG, "startDj: projection returned OK but pendingDjHost is null")
            } else {
                val intent = Intent(appContext, AudioForegroundService::class.java).apply {
                    putExtra(AudioForegroundService.EXTRA_HOST, host)
                    putExtra(AudioForegroundService.EXTRA_PORT, port)
                    putExtra(AudioForegroundService.EXTRA_MODE, "dj")
                    putExtra(AudioForegroundService.EXTRA_PROJECTION_RESULT_CODE, resultCode)
                    putExtra(AudioForegroundService.EXTRA_PROJECTION_DATA, data)
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appContext.startForegroundService(intent)
                    } else {
                        appContext.startService(intent)
                    }
                    val bindIntent = Intent(appContext, AudioForegroundService::class.java)
                    appContext.bindService(bindIntent, serviceConnection, Context.BIND_AUTO_CREATE)
                } catch (e: Exception) {
                    Log.e(TAG, "startDj service start failed", e)
                }
            }
        } else {
            Log.i(TAG, "startDj: user denied MediaProjection consent (resultCode=$resultCode)")
        }
        pendingDjHost = null
        true
    }

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "com.wirelessmic/audio")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "com.wirelessmic/audio_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        releaseMulticastLock()
        unbind()
    }

    // ── ActivityAware ─────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(activityResultListener)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(activityResultListener)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
    }

    // ── Multicast/broadcast lock (needed to receive discovery beacons) ─────────

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("evermic-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        if (multicastLock?.isHeld == true) multicastLock?.release()
        multicastLock = null
    }

    // ── MethodCallHandler ─────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val host = call.argument<String>("host") ?: run {
                    result.error("INVALID_ARG", "host is required", null); return
                }
                val port = call.argument<Int>("port") ?: 7355
                startService(host, port, result)
            }
            "startDj" -> {
                val host = call.argument<String>("host") ?: run {
                    result.error("INVALID_ARG", "host is required", null); return
                }
                val port = call.argument<Int>("port") ?: 7355
                startDj(host, port, result)
            }
            "stop" -> {
                stopService()
                result.success(null)
            }
            "acquireMulticastLock" -> {
                acquireMulticastLock()
                result.success(null)
            }
            "releaseMulticastLock" -> {
                releaseMulticastLock()
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

    // ── Service lifecycle ─────────────────────────────────────────────────────

    private fun startService(host: String, port: Int, result: MethodChannel.Result) {
        val intent = Intent(appContext, AudioForegroundService::class.java).apply {
            putExtra(AudioForegroundService.EXTRA_HOST, host)
            putExtra(AudioForegroundService.EXTRA_PORT, port)
            putExtra(AudioForegroundService.EXTRA_MODE, "mic")
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(intent)
            } else {
                appContext.startService(intent)
            }
            // Bind to get a direct reference so we can wire the metrics listener
            val bindIntent = Intent(appContext, AudioForegroundService::class.java)
            appContext.bindService(bindIntent, serviceConnection, Context.BIND_AUTO_CREATE)
            result.success(null)
        } catch (e: Exception) {
            result.error("START_FAILED", e.message, null)
        }
    }

    private fun startDj(host: String, port: Int, result: MethodChannel.Result) {
        val binding = activityBinding ?: run {
            result.error("NO_ACTIVITY", "Activity not attached; cannot show MediaProjection consent", null)
            return
        }
        pendingDjHost = host
        pendingDjPort = port
        val mgr = appContext.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        binding.activity.startActivityForResult(mgr.createScreenCaptureIntent(), REQ_MEDIA_PROJECTION)
        // Reply immediately — the service starts (or logs error) asynchronously in activityResultListener.
        result.success(null)
    }

    private fun stopService() {
        audioService?.stopStreaming()
        unbind()
        appContext.stopService(Intent(appContext, AudioForegroundService::class.java))
    }

    private fun unbind() {
        if (isBound) {
            audioService?.metricsListener = null
            appContext.unbindService(serviceConnection)
            isBound = false
            audioService = null
        }
    }
}
