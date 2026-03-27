package com.mysticalg.backchat

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannels()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            handleNotificationMethodCall(call, result)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) {
            return
        }

        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    private fun handleNotificationMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> requestNotificationPermission(result)
            "showMessageNotification" -> {
                showMessageNotification(call)
                result.success(null)
            }

            "showIncomingCallNotification" -> {
                showIncomingCallNotification(call)
                result.success(null)
            }

            "cancelNotification" -> {
                val notificationId = call.argument<Number>("id")?.toInt()
                if (notificationId != null) {
                    NotificationManagerCompat.from(this).cancel(notificationId)
                }
                result.success(null)
            }

            "cancelIncomingCallNotification" -> {
                NotificationManagerCompat.from(this).cancel(INCOMING_CALL_NOTIFICATION_ID)
                result.success(null)
            }

            "cancelAllNotifications" -> {
                NotificationManagerCompat.from(this).cancelAll()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        if (notificationsAllowed()) {
            result.success(true)
            return
        }

        if (permissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "Notification permission request already in progress.",
                null,
            )
            return
        }

        permissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun showMessageNotification(call: MethodCall) {
        if (!notificationsAllowed()) {
            return
        }

        val notificationId = call.argument<Number>("id")?.toInt() ?: return
        val title = call.argument<String>("title")?.trim().orEmpty()
        val body = call.argument<String>("body")?.trim().orEmpty()
        val unreadCount = call.argument<Number>("unreadCount")?.toInt() ?: 1
        val pendingIntent = buildLaunchPendingIntent(notificationId)
        val builder =
            NotificationCompat.Builder(this, MESSAGE_NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title.ifEmpty { appDisplayName() })
                .setContentText(body.ifEmpty { "New message" })
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        body.ifEmpty { "New message" },
                    ),
                )
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setNumber(unreadCount)
                .setAutoCancel(true)

        if (unreadCount > 1) {
            builder.setSubText("$unreadCount unread")
        }

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
            builder.setDefaults(NotificationCompat.DEFAULT_VIBRATE)
        }

        NotificationManagerCompat.from(this).notify(notificationId, builder.build())
    }

    private fun showIncomingCallNotification(call: MethodCall) {
        if (!notificationsAllowed()) {
            return
        }

        val title = call.argument<String>("title")?.trim().orEmpty()
        val body = call.argument<String>("body")?.trim().orEmpty()
        val pendingIntent = buildLaunchPendingIntent(INCOMING_CALL_NOTIFICATION_ID)
        val builder =
            NotificationCompat.Builder(this, CALL_NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title.ifEmpty { appDisplayName() })
                .setContentText(body.ifEmpty { "Incoming call" })
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        body.ifEmpty { "Incoming call" },
                    ),
                )
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
            builder.setDefaults(NotificationCompat.DEFAULT_VIBRATE)
        }

        NotificationManagerCompat.from(this).notify(
            INCOMING_CALL_NOTIFICATION_ID,
            builder.build(),
        )
    }

    private fun notificationsAllowed(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun buildLaunchPendingIntent(requestCode: Int): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        return PendingIntent.getActivity(
            this,
            requestCode,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(NotificationManager::class.java) ?: return
        val messageAudioAttributes =
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        val callAudioAttributes =
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

        val messageChannel =
            NotificationChannel(
                MESSAGE_NOTIFICATION_CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alerts for new chat messages."
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    messageAudioAttributes,
                )
            }

        val callChannel =
            NotificationChannel(
                CALL_NOTIFICATION_CHANNEL_ID,
                "Calls",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alerts for incoming calls."
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    callAudioAttributes,
                )
            }

        manager.createNotificationChannel(messageChannel)
        manager.createNotificationChannel(callChannel)
    }

    private fun appDisplayName(): String {
        return applicationInfo.loadLabel(packageManager)?.toString().orEmpty().ifEmpty {
            "Backchat"
        }
    }

    companion object {
        private const val NOTIFICATION_CHANNEL_NAME = "backchat/notifications"
        private const val MESSAGE_NOTIFICATION_CHANNEL_ID = "backchat_messages"
        private const val CALL_NOTIFICATION_CHANNEL_ID = "backchat_calls"
        private const val INCOMING_CALL_NOTIFICATION_ID = 640001
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 640002
    }
}
