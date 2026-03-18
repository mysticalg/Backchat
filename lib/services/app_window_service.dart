import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppWindowService {
  static const MethodChannel _channel = MethodChannel('backchat/window');

  bool get _supportsDesktopBadge => !kIsWeb && Platform.isWindows;

  Future<void> setUnreadCount(int count) async {
    if (!_supportsDesktopBadge) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'setUnreadCount',
        <String, dynamic>{'count': count},
      );
    } on MissingPluginException {
      // Ignore when the host platform does not implement window badges.
    } on PlatformException {
      // Ignore desktop notification errors rather than breaking chat flow.
    }
  }
}
