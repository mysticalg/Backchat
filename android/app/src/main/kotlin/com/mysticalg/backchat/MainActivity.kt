package com.mysticalg.backchat

import android.Manifest
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
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
    private var pendingApkDownloadId: Long? = null
    private val apkDownloadReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) {
                    return
                }

                val completedDownloadId =
                    intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                if (completedDownloadId == -1L || completedDownloadId != pendingApkDownloadId) {
                    return
                }

                handleCompletedApkDownload(completedDownloadId)
            }
        }
    private var apkDownloadReceiverRegistered = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannels()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            handleNotificationMethodCall(call, result)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            handleUpdateMethodCall(call, result)
        }
    }

    override fun onDestroy() {
        if (apkDownloadReceiverRegistered) {
            unregisterReceiver(apkDownloadReceiver)
            apkDownloadReceiverRegistered = false
        }
        super.onDestroy()
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

    private fun handleUpdateMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "downloadAndInstallApk" -> startApkDownloadAndInstall(call, result)
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

    private fun startApkDownloadAndInstall(call: MethodCall, result: MethodChannel.Result) {
        val rawUrl = call.argument<String>("url")?.trim().orEmpty()
        val versionLabel = call.argument<String>("versionLabel")?.trim().orEmpty()
        if (rawUrl.isEmpty()) {
            result.error("missing_url", "APK download URL was not provided.", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val permissionIntent =
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    android.net.Uri.parse("package:$packageName"),
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            startActivity(permissionIntent)
            result.success("permission_required")
            return
        }

        val downloadManager = getSystemService(DownloadManager::class.java)
        if (downloadManager == null) {
            result.error(
                "download_manager_unavailable",
                "Android DownloadManager is unavailable on this device.",
                null,
            )
            return
        }

        ensureApkDownloadReceiverRegistered()

        val request =
            DownloadManager.Request(android.net.Uri.parse(rawUrl))
                .setTitle("${appDisplayName()} update")
                .setDescription(
                    if (versionLabel.isEmpty()) {
                        "Downloading the latest Backchat update."
                    } else {
                        "Downloading Backchat $versionLabel."
                    },
                )
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                .setMimeType(APK_MIME_TYPE)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)

        request.setDestinationInExternalFilesDir(
            this,
            Environment.DIRECTORY_DOWNLOADS,
            "backchat-update.apk",
        )

        pendingApkDownloadId = downloadManager.enqueue(request)
        result.success("started")
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

    private fun ensureApkDownloadReceiverRegistered() {
        if (apkDownloadReceiverRegistered) {
            return
        }

        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(apkDownloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(apkDownloadReceiver, filter)
        }
        apkDownloadReceiverRegistered = true
    }

    private fun handleCompletedApkDownload(downloadId: Long) {
        val downloadManager = getSystemService(DownloadManager::class.java) ?: return
        val query = DownloadManager.Query().setFilterById(downloadId)
        downloadManager.query(query)?.use { cursor ->
            if (!cursor.moveToFirst()) {
                pendingApkDownloadId = null
                return
            }

            val statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            if (statusIndex == -1) {
                pendingApkDownloadId = null
                return
            }

            val status = cursor.getInt(statusIndex)
            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                val downloadUri = downloadManager.getUriForDownloadedFile(downloadId)
                if (downloadUri != null) {
                    promptApkInstall(downloadUri)
                }
            }
        }
        pendingApkDownloadId = null
    }

    private fun promptApkInstall(downloadUri: android.net.Uri) {
        val installIntent =
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(downloadUri, APK_MIME_TYPE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        startActivity(installIntent)
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
        private const val UPDATE_CHANNEL_NAME = "backchat/updates"
        private const val MESSAGE_NOTIFICATION_CHANNEL_ID = "backchat_messages"
        private const val CALL_NOTIFICATION_CHANNEL_ID = "backchat_calls"
        private const val INCOMING_CALL_NOTIFICATION_ID = 640001
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 640002
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
