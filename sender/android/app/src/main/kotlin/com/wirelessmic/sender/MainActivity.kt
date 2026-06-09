package com.wirelessmic.sender

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(AudioForegroundService.CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                AudioForegroundService.CHANNEL_ID,
                "EVERDJ",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Se muestra mientras EVERDJ transmite audio" }
            nm.createNotificationChannel(channel)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AudioStreamPlugin())
    }
}
