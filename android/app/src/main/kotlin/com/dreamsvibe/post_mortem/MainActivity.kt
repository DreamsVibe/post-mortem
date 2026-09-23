package com.dreamsvibe.post_mortem

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var serviceRunning = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "post_mortem/background")
            .setMethodCallHandler { call, result ->
                val text = call.argument<String>("text") ?: "Analyzing games…"
                when (call.method) {
                    "start" -> {
                        askForNotifications()
                        try {
                            val intent = Intent(this, AnalysisService::class.java)
                                .putExtra(AnalysisService.EXTRA_TEXT, text)
                            ContextCompat.startForegroundService(this, intent)
                            serviceRunning = true
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "update" -> {
                        if (serviceRunning) AnalysisService.updateNotification(this, text)
                        result.success(true)
                    }
                    "stop" -> {
                        try {
                            stopService(Intent(this, AnalysisService::class.java))
                        } catch (_: Exception) {
                        }
                        serviceRunning = false
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 71)
        }
    }
}
