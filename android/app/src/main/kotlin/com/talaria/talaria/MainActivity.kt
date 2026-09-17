package com.talaria.talaria

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "talaria/foreground"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title")
                        val text = call.argument<String>("text")
                        try {
                            startForegroundServiceInternal(title, text)
                            result.success(true)
                        } catch (_: RuntimeException) {
                            // Android 12+ can reject background starts. Never crash the activity.
                            result.error("foreground_unavailable", "Android denied foreground service startup", null)
                        }
                    }
                    "stop" -> {
                        stopServiceInternal()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startForegroundServiceInternal(title: String?, text: String?) {
        val intent = Intent(this, TalariaForegroundService::class.java)
            .putExtra(TalariaForegroundService.EXTRA_TITLE, title)
            .putExtra(TalariaForegroundService.EXTRA_TEXT, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopServiceInternal() {
        stopService(Intent(this, TalariaForegroundService::class.java))
    }
}
