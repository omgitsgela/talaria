package com.talaria.talaria

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/** Best-effort lifetime for the live Dart gateway connection. */
class TalariaForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "talaria_foreground"
        const val NOTIFICATION_ID = 1
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "Hermes gateway connection", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Keeps the gateway connection alive in the background." })
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(
            intent?.getStringExtra(EXTRA_TITLE) ?: "Hermes is working",
            intent?.getStringExtra(EXTRA_TEXT) ?: "A turn is running on your gateway."
        )
        try {
            // specialUse: exempts this always-on connection keep-alive from the
            // dataSync time budget (Android 15) that would otherwise stop the
            // service while the app is backgrounded. Requires API 29+.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: RuntimeException) {
            // Missing permission or exhausted OS quota must not kill the app.
            stopSelf()
        }
        // Restarting this service cannot recreate the Dart socket/turn.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(title: String, text: String): Notification {
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val tap = PendingIntent.getActivity(this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(tap)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }
}
