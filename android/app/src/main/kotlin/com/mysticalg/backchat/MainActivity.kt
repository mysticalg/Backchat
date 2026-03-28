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
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

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
        restorePendingApkDownloadState()
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_IMPORT_CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            handleMediaImportMethodCall(call, result)
        }
    }

    override fun onDestroy() {
        if (apkDownloadReceiverRegistered) {
            unregisterReceiver(apkDownloadReceiver)
            apkDownloadReceiverRegistered = false
        }
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        restorePendingApkDownloadState()
        ensureApkDownloadReceiverRegistered()
        reconcilePendingApkDownload()
    }

    override fun onResume() {
        super.onResume()
        restorePendingApkDownloadState()
        reconcilePendingApkDownload()
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

            "showUpdateAvailableNotification" -> {
                showUpdateAvailableNotification(call)
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

            "cancelUpdateNotification" -> {
                NotificationManagerCompat.from(this).cancel(UPDATE_NOTIFICATION_ID)
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

    private fun handleMediaImportMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readInsertedContent" -> readInsertedContent(call, result)
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
        clearPendingApkDownload(downloadManager)
        deleteStaleDownloadedApk()

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
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                )
                .setMimeType(APK_MIME_TYPE)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)

        request.setDestinationInExternalFilesDir(
            this,
            Environment.DIRECTORY_DOWNLOADS,
            "backchat-update.apk",
        )

        pendingApkDownloadId = downloadManager.enqueue(request)
        persistPendingApkDownloadState(pendingApkDownloadId)
        result.success("started")
    }

    private fun readInsertedContent(call: MethodCall, result: MethodChannel.Result) {
        val rawUri = call.argument<String>("uri")?.trim().orEmpty()
        if (rawUri.isEmpty()) {
            result.error("missing_uri", "Inserted content URI was not provided.", null)
            return
        }

        val uri = Uri.parse(rawUri)
        try {
            val bytes =
                contentResolver.openInputStream(uri)?.use { inputStream ->
                    val buffer = ByteArrayOutputStream()
                    inputStream.copyTo(buffer)
                    buffer.toByteArray()
                }

            if (bytes == null || bytes.isEmpty()) {
                result.success(null)
                return
            }

            result.success(
                mapOf(
                    "data" to bytes,
                    "mimeType" to (contentResolver.getType(uri) ?: ""),
                ),
            )
        } catch (error: SecurityException) {
            result.error(
                "content_permission_denied",
                "Backchat could not access media inserted by the keyboard.",
                error.message,
            )
        } catch (error: Exception) {
            result.error(
                "content_read_failed",
                "Backchat could not read media inserted by the keyboard.",
                error.message,
            )
        }
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

    private fun showUpdateAvailableNotification(call: MethodCall) {
        if (!notificationsAllowed()) {
            return
        }

        val title = call.argument<String>("title")?.trim().orEmpty()
        val body = call.argument<String>("body")?.trim().orEmpty()
        val pendingIntent = buildLaunchPendingIntent(UPDATE_NOTIFICATION_ID)
        val builder =
            NotificationCompat.Builder(this, UPDATE_NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title.ifEmpty { "${appDisplayName()} update available" })
                .setContentText(body.ifEmpty { "A newer Backchat release is ready." })
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        body.ifEmpty { "A newer Backchat release is ready." },
                    ),
                )
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
        }

        NotificationManagerCompat.from(this).notify(UPDATE_NOTIFICATION_ID, builder.build())
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
                clearPendingApkDownloadState()
                return
            }

            val statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            if (statusIndex == -1) {
                clearPendingApkDownloadState()
                return
            }

            val status = cursor.getInt(statusIndex)
            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                val downloadUri = downloadManager.getUriForDownloadedFile(downloadId)
                if (downloadUri != null) {
                    promptApkInstall(downloadUri)
                } else {
                    showUpdateToast("Backchat finished downloading, but Android could not open the installer.")
                }
            } else if (status == DownloadManager.STATUS_FAILED) {
                showUpdateToast(downloadFailureMessage(cursor))
            }
        }
        clearPendingApkDownloadState()
    }

    private fun promptApkInstall(downloadUri: android.net.Uri) {
        try {
            val installIntent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(downloadUri, APK_MIME_TYPE)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            startActivity(installIntent)
        } catch (_: Exception) {
            showUpdateToast("Backchat downloaded the update, but Android could not launch the installer.")
        }
    }

    private fun reconcilePendingApkDownload() {
        val downloadId = pendingApkDownloadId ?: return
        val downloadManager = getSystemService(DownloadManager::class.java) ?: return
        val query = DownloadManager.Query().setFilterById(downloadId)
        downloadManager.query(query)?.use { cursor ->
            if (!cursor.moveToFirst()) {
                clearPendingApkDownloadState()
                return
            }

            val statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            if (statusIndex == -1) {
                clearPendingApkDownloadState()
                return
            }

            when (cursor.getInt(statusIndex)) {
                DownloadManager.STATUS_SUCCESSFUL -> handleCompletedApkDownload(downloadId)
                DownloadManager.STATUS_FAILED -> {
                    showUpdateToast(downloadFailureMessage(cursor))
                    clearPendingApkDownloadState()
                }
            }
        }
    }

    private fun downloadFailureMessage(cursor: android.database.Cursor): String {
        val reasonIndex = cursor.getColumnIndex(DownloadManager.COLUMN_REASON)
        val reason = if (reasonIndex != -1) cursor.getInt(reasonIndex) else 0
        return when (reason) {
            DownloadManager.ERROR_CANNOT_RESUME ->
                "Backchat could not resume the update download. Please try again."
            DownloadManager.ERROR_DEVICE_NOT_FOUND ->
                "Backchat could not access device storage for the update download."
            DownloadManager.ERROR_FILE_ALREADY_EXISTS ->
                "Backchat found an old update file. Please try the update again."
            DownloadManager.ERROR_FILE_ERROR ->
                "Backchat could not write the update file to storage."
            DownloadManager.ERROR_HTTP_DATA_ERROR ->
                "Backchat hit a network error while downloading the update."
            DownloadManager.ERROR_INSUFFICIENT_SPACE ->
                "There is not enough free space to download the Backchat update."
            DownloadManager.ERROR_TOO_MANY_REDIRECTS ->
                "The update download redirected too many times."
            DownloadManager.ERROR_UNHANDLED_HTTP_CODE ->
                "The update server returned an unexpected response."
            DownloadManager.ERROR_UNKNOWN ->
                "Android could not finish downloading the Backchat update."
            else -> "Backchat could not finish downloading the update."
        }
    }

    private fun clearPendingApkDownload(downloadManager: DownloadManager) {
        pendingApkDownloadId?.let { activeDownloadId ->
            runCatching {
                downloadManager.remove(activeDownloadId)
            }
        }
        clearPendingApkDownloadState()
    }

    private fun restorePendingApkDownloadState() {
        val savedDownloadId = updatePrefs().getLong(PENDING_APK_DOWNLOAD_ID_KEY, -1L)
        pendingApkDownloadId = savedDownloadId.takeIf { it > 0L }
    }

    private fun persistPendingApkDownloadState(downloadId: Long?) {
        val prefs = updatePrefs().edit()
        if (downloadId == null || downloadId <= 0L) {
            prefs.remove(PENDING_APK_DOWNLOAD_ID_KEY)
        } else {
            prefs.putLong(PENDING_APK_DOWNLOAD_ID_KEY, downloadId)
        }
        prefs.apply()
    }

    private fun clearPendingApkDownloadState() {
        pendingApkDownloadId = null
        persistPendingApkDownloadState(null)
    }

    private fun deleteStaleDownloadedApk() {
        val apkFile = downloadedApkFile() ?: return
        if (apkFile.exists()) {
            apkFile.delete()
        }
    }

    private fun downloadedApkFile(): File? {
        val downloadsDir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: return null
        return File(downloadsDir, "backchat-update.apk")
    }

    private fun updatePrefs() = getSharedPreferences(UPDATE_PREFS_NAME, Context.MODE_PRIVATE)

    private fun showUpdateToast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
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

        val updateChannel =
            NotificationChannel(
                UPDATE_NOTIFICATION_CHANNEL_ID,
                "Updates",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Alerts when a newer Backchat build is available."
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    messageAudioAttributes,
                )
            }

        manager.createNotificationChannel(messageChannel)
        manager.createNotificationChannel(callChannel)
        manager.createNotificationChannel(updateChannel)
    }

    private fun appDisplayName(): String {
        return applicationInfo.loadLabel(packageManager)?.toString().orEmpty().ifEmpty {
            "Backchat"
        }
    }

    companion object {
        private const val NOTIFICATION_CHANNEL_NAME = "backchat/notifications"
        private const val UPDATE_CHANNEL_NAME = "backchat/updates"
        private const val MEDIA_IMPORT_CHANNEL_NAME = "backchat/media_import"
        private const val MESSAGE_NOTIFICATION_CHANNEL_ID = "backchat_messages"
        private const val CALL_NOTIFICATION_CHANNEL_ID = "backchat_calls"
        private const val UPDATE_NOTIFICATION_CHANNEL_ID = "backchat_updates"
        private const val INCOMING_CALL_NOTIFICATION_ID = 640001
        private const val UPDATE_NOTIFICATION_ID = 640003
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 640002
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private const val UPDATE_PREFS_NAME = "backchat_updates"
        private const val PENDING_APK_DOWNLOAD_ID_KEY = "pending_apk_download_id_v1"
    }
}
