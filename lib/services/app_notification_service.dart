import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/call_models.dart';

class AppNotificationService {
  static const MethodChannel _channel = MethodChannel('backchat/notifications');

  bool get _supportsAndroidNotifications => !kIsWeb && Platform.isAndroid;

  Future<bool> requestPermissionIfNeeded() async {
    if (!_supportsAndroidNotifications) {
      return true;
    }

    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> showIncomingMessageNotification({
    required int notificationId,
    required String senderName,
    required String body,
    required int unreadCount,
  }) async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'showMessageNotification',
        <String, dynamic>{
          'id': notificationId,
          'title': senderName,
          'body': body,
          'unreadCount': unreadCount,
        },
      );
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Notification failures should not break chat flow.
    }
  }

  Future<void> showIncomingCallNotification({
    required String callerName,
    required CallKind kind,
  }) async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'showIncomingCallNotification',
        <String, dynamic>{
          'title': callerName,
          'body': 'Incoming ${kind.name} call',
        },
      );
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Notification failures should not break call flow.
    }
  }

  Future<void> showUpdateAvailableNotification({
    required String versionLabel,
    required bool canAutoInstall,
  }) async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    final String actionLabel =
        canAutoInstall ? 'Update now' : 'Download update';
    final String body = versionLabel.trim().isEmpty
        ? 'A new Backchat release is ready. Open Backchat to $actionLabel.'
        : 'Backchat $versionLabel is ready. Open Backchat to $actionLabel.';
    try {
      await _channel.invokeMethod<void>(
        'showUpdateAvailableNotification',
        <String, dynamic>{
          'title': 'Backchat update available',
          'body': body,
        },
      );
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Notification failures should not break update flow.
    }
  }

  Future<void> cancelNotification(int notificationId) async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'cancelNotification',
        <String, dynamic>{'id': notificationId},
      );
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Ignore cleanup errors.
    }
  }

  Future<void> cancelIncomingCallNotification() async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('cancelIncomingCallNotification');
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Ignore cleanup errors.
    }
  }

  Future<void> cancelUpdateNotification() async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('cancelUpdateNotification');
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Ignore cleanup errors.
    }
  }

  Future<void> cancelAllNotifications() async {
    if (!_supportsAndroidNotifications) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('cancelAllNotifications');
    } on MissingPluginException {
      // Ignore unsupported platforms.
    } on PlatformException {
      // Ignore cleanup errors.
    }
  }
}
