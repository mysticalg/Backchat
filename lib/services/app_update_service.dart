import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_update/in_app_update.dart' as play_update;
import 'package:package_info_plus/package_info_plus.dart';

enum AppUpdatePlatform {
  android,
  ios,
  windows,
  macos,
  linux,
  other,
}

enum AppUpdateStatus {
  upToDate,
  autoInstallStarted,
  installerPermissionRequired,
  manualUpdateAvailable,
  unavailable,
}

enum AndroidApkInstallStatus {
  started,
  permissionRequired,
  failed,
}

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    this.releaseUrl,
    this.downloadUrl,
  });

  final String version;
  final Uri? releaseUrl;
  final Uri? downloadUrl;
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.status,
    required this.currentVersion,
    this.latestRelease,
    this.message = '',
    this.canAutoInstall = false,
    this.shouldRetryOnResume = false,
  });

  final AppUpdateStatus status;
  final String currentVersion;
  final AppReleaseInfo? latestRelease;
  final String message;
  final bool canAutoInstall;
  final bool shouldRetryOnResume;

  Uri? get actionUrl => latestRelease?.downloadUrl ?? latestRelease?.releaseUrl;
}

typedef PackageInfoLoader = Future<PackageInfo> Function();
typedef LatestReleaseFetcher = Future<Map<String, dynamic>?> Function();
typedef PlayUpdateInfoLoader = Future<play_update.AppUpdateInfo> Function();
typedef PlayImmediateUpdater = Future<play_update.AppUpdateResult> Function();
typedef AndroidApkInstaller = Future<AndroidApkInstallStatus> Function({
  required Uri downloadUrl,
  required String versionLabel,
});

class AppUpdateService {
  AppUpdateService({
    PackageInfoLoader? packageInfoLoader,
    LatestReleaseFetcher? latestReleaseFetcher,
    PlayUpdateInfoLoader? playUpdateInfoLoader,
    PlayImmediateUpdater? playImmediateUpdater,
    AndroidApkInstaller? androidApkInstaller,
    AppUpdatePlatform? platform,
  })  : _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
        _latestReleaseFetcher =
            latestReleaseFetcher ?? AppUpdateService.fetchLatestRelease,
        _playUpdateInfoLoader =
            playUpdateInfoLoader ?? play_update.InAppUpdate.checkForUpdate,
        _playImmediateUpdater = playImmediateUpdater ??
            play_update.InAppUpdate.performImmediateUpdate,
        _androidApkInstaller = androidApkInstaller ??
            AppUpdateService._downloadAndInstallAndroidApk,
        _platform = platform ?? _detectPlatform();

  static const String _ownerRepo = 'mysticalg/Backchat';
  static const MethodChannel _androidUpdatesChannel =
      MethodChannel('backchat/updates');

  final PackageInfoLoader _packageInfoLoader;
  final LatestReleaseFetcher _latestReleaseFetcher;
  final PlayUpdateInfoLoader _playUpdateInfoLoader;
  final PlayImmediateUpdater _playImmediateUpdater;
  final AndroidApkInstaller _androidApkInstaller;
  final AppUpdatePlatform _platform;

  Future<AppUpdateCheckResult> checkForStartupUpdate({
    bool startInstall = false,
  }) async {
    final PackageInfo packageInfo = await _packageInfoLoader();
    final String currentVersion = _installedVersion(packageInfo);

    if (_platform == AppUpdatePlatform.android &&
        _isPlayManagedInstall(packageInfo.installerStore)) {
      return _checkPlayManagedAndroidUpdate(
        currentVersion,
        startInstall: startInstall,
      );
    }

    final Map<String, dynamic>? release = await _latestReleaseFetcher();
    if (release == null) {
      return AppUpdateCheckResult(
        status: AppUpdateStatus.unavailable,
        currentVersion: currentVersion,
      );
    }

    final AppReleaseInfo? latestRelease = _buildReleaseInfo(release);
    if (latestRelease == null) {
      return AppUpdateCheckResult(
        status: AppUpdateStatus.unavailable,
        currentVersion: currentVersion,
      );
    }

    if (_compareVersions(latestRelease.version, currentVersion) <= 0) {
      return AppUpdateCheckResult(
        status: AppUpdateStatus.upToDate,
        currentVersion: currentVersion,
        latestRelease: latestRelease,
      );
    }

    final bool canAutoInstall = _platform == AppUpdatePlatform.android &&
        latestRelease.downloadUrl != null;
    if (startInstall && canAutoInstall) {
      final AndroidApkInstallStatus installStatus = await _androidApkInstaller(
        downloadUrl: latestRelease.downloadUrl!,
        versionLabel: latestRelease.version,
      );
      if (installStatus == AndroidApkInstallStatus.started) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.autoInstallStarted,
          currentVersion: currentVersion,
          latestRelease: latestRelease,
          message:
              'Downloading Backchat ${latestRelease.version}. Android will ask the user to install it when it is ready.',
        );
      }
      if (installStatus == AndroidApkInstallStatus.permissionRequired) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.installerPermissionRequired,
          currentVersion: currentVersion,
          latestRelease: latestRelease,
          message:
              'Allow Backchat to install updates from this source, then return to finish updating.',
          shouldRetryOnResume: true,
        );
      }
    }

    return AppUpdateCheckResult(
      status: AppUpdateStatus.manualUpdateAvailable,
      currentVersion: currentVersion,
      latestRelease: latestRelease,
      message: 'Backchat ${latestRelease.version} is available.',
      canAutoInstall: canAutoInstall,
    );
  }

  Future<AppUpdateCheckResult> _checkPlayManagedAndroidUpdate(
    String currentVersion, {
    required bool startInstall,
  }) async {
    try {
      final play_update.AppUpdateInfo updateInfo =
          await _playUpdateInfoLoader();
      final bool resumeImmediateUpdate = updateInfo.updateAvailability ==
          play_update.UpdateAvailability.developerTriggeredUpdateInProgress;
      final bool immediateUpdateAvailable = updateInfo.updateAvailability ==
              play_update.UpdateAvailability.updateAvailable &&
          updateInfo.immediateUpdateAllowed;

      if (!resumeImmediateUpdate && !immediateUpdateAvailable) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.upToDate,
          currentVersion: currentVersion,
        );
      }

      if (!startInstall) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.manualUpdateAvailable,
          currentVersion: currentVersion,
          message: 'A Backchat update is available.',
          canAutoInstall: true,
        );
      }

      final play_update.AppUpdateResult updateResult =
          await _playImmediateUpdater();
      if (updateResult == play_update.AppUpdateResult.success) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.autoInstallStarted,
          currentVersion: currentVersion,
        );
      }

      return AppUpdateCheckResult(
        status: AppUpdateStatus.unavailable,
        currentVersion: currentVersion,
        message: updateResult == play_update.AppUpdateResult.userDeniedUpdate
            ? 'The startup update was dismissed in Google Play.'
            : 'Google Play could not start the automatic update.',
      );
    } on MissingPluginException {
      return AppUpdateCheckResult(
        status: AppUpdateStatus.unavailable,
        currentVersion: currentVersion,
      );
    } on PlatformException {
      return AppUpdateCheckResult(
        status: AppUpdateStatus.unavailable,
        currentVersion: currentVersion,
      );
    }
  }

  static Future<Map<String, dynamic>?> fetchLatestRelease() async {
    final Uri uri =
        Uri.parse('https://api.github.com/repos/$_ownerRepo/releases/latest');
    final http.Response response = await http.get(
      uri,
      headers: const <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Backchat-Updater',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Ignore malformed release payloads and fail closed.
    }
    return null;
  }

  static Future<AndroidApkInstallStatus> _downloadAndInstallAndroidApk({
    required Uri downloadUrl,
    required String versionLabel,
  }) async {
    try {
      final String? rawStatus =
          await _androidUpdatesChannel.invokeMethod<String>(
        'downloadAndInstallApk',
        <String, dynamic>{
          'url': downloadUrl.toString(),
          'versionLabel': versionLabel,
        },
      );
      return switch (rawStatus) {
        'started' => AndroidApkInstallStatus.started,
        'permission_required' => AndroidApkInstallStatus.permissionRequired,
        _ => AndroidApkInstallStatus.failed,
      };
    } on MissingPluginException {
      return AndroidApkInstallStatus.failed;
    } on PlatformException {
      return AndroidApkInstallStatus.failed;
    }
  }

  AppReleaseInfo? _buildReleaseInfo(Map<String, dynamic> release) {
    final String? version = _extractReleaseVersion(release['name']) ??
        _extractReleaseVersion(release['tag_name']);
    if (version == null) {
      return null;
    }

    return AppReleaseInfo(
      version: version,
      releaseUrl: _tryParseUri(release['html_url']?.toString()),
      downloadUrl: _preferredDownloadUrl(release),
    );
  }

  Uri? _preferredDownloadUrl(Map<String, dynamic> release) {
    return switch (_platform) {
      AppUpdatePlatform.android => _findAssetUrl(
          release,
          prefix: 'backchat-android-',
          suffixes: const <String>['.apk'],
        ),
      AppUpdatePlatform.windows => _findAssetUrl(
          release,
          prefix: 'backchat-windows-x64-',
          suffixes: const <String>['-setup.exe', '.zip'],
        ),
      AppUpdatePlatform.macos => _findAssetUrl(
          release,
          prefix: 'backchat-macos-',
          suffixes: const <String>['.zip'],
        ),
      AppUpdatePlatform.linux => _findAssetUrl(
          release,
          prefix: 'backchat-linux-x64-',
          suffixes: const <String>['.tar.gz'],
        ),
      _ => null,
    };
  }

  Uri? _findAssetUrl(
    Map<String, dynamic> release, {
    required String prefix,
    required List<String> suffixes,
  }) {
    final Object? rawAssets = release['assets'];
    if (rawAssets is! List<Object?>) {
      return null;
    }

    for (final String suffix in suffixes) {
      for (final Object? rawAsset in rawAssets) {
        if (rawAsset is! Map<String, dynamic>) {
          continue;
        }
        final String assetName = rawAsset['name']?.toString() ?? '';
        if (assetName.startsWith(prefix) && assetName.endsWith(suffix)) {
          return _tryParseUri(rawAsset['browser_download_url']?.toString());
        }
      }
    }
    return null;
  }

  static AppUpdatePlatform _detectPlatform() {
    if (kIsWeb) {
      return AppUpdatePlatform.other;
    }
    if (Platform.isAndroid) {
      return AppUpdatePlatform.android;
    }
    if (Platform.isIOS) {
      return AppUpdatePlatform.ios;
    }
    if (Platform.isWindows) {
      return AppUpdatePlatform.windows;
    }
    if (Platform.isMacOS) {
      return AppUpdatePlatform.macos;
    }
    if (Platform.isLinux) {
      return AppUpdatePlatform.linux;
    }
    return AppUpdatePlatform.other;
  }

  bool _isPlayManagedInstall(String? installerStore) {
    final String normalized = installerStore?.trim().toLowerCase() ?? '';
    return normalized == 'com.android.vending' ||
        normalized == 'com.google.android.feedback';
  }

  String _installedVersion(PackageInfo packageInfo) {
    final String version = packageInfo.version.trim();
    final String buildNumber = packageInfo.buildNumber.trim();
    if (version.isEmpty) {
      return buildNumber;
    }
    if (buildNumber.isEmpty || version.endsWith('+$buildNumber')) {
      return version;
    }
    return '$version+$buildNumber';
  }

  String? _extractReleaseVersion(Object? rawValue) {
    final String input = rawValue?.toString().trim() ?? '';
    if (input.isEmpty) {
      return null;
    }
    final List<RegExpMatch> matches =
        RegExp(r'v?(\d+(?:\.\d+)+(?:[+-][0-9A-Za-z.\-]+)?)')
            .allMatches(input)
            .toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }
    final String? matchedValue = matches.last.group(1);
    if (matchedValue == null || matchedValue.isEmpty) {
      return null;
    }
    return matchedValue.replaceFirst(
        RegExp(r'-build\.', caseSensitive: false), '+');
  }

  Uri? _tryParseUri(String? value) {
    final Uri? uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    return uri;
  }

  int _compareVersions(String left, String right) {
    final _ParsedVersion a = _ParsedVersion.parse(left);
    final _ParsedVersion b = _ParsedVersion.parse(right);
    final int coreComparison = _compareIntLists(a.coreParts, b.coreParts);
    if (coreComparison != 0) {
      return coreComparison;
    }
    return a.buildNumber.compareTo(b.buildNumber);
  }

  int _compareIntLists(List<int> left, List<int> right) {
    final int maxLength =
        left.length > right.length ? left.length : right.length;
    for (int index = 0; index < maxLength; index += 1) {
      final int leftValue = index < left.length ? left[index] : 0;
      final int rightValue = index < right.length ? right[index] : 0;
      if (leftValue != rightValue) {
        return leftValue.compareTo(rightValue);
      }
    }
    return 0;
  }
}

class _ParsedVersion {
  const _ParsedVersion({
    required this.coreParts,
    required this.buildNumber,
  });

  final List<int> coreParts;
  final int buildNumber;

  factory _ParsedVersion.parse(String rawValue) {
    final String normalized =
        rawValue.trim().replaceFirst(RegExp(r'^v', caseSensitive: false), '');
    final String canonical =
        normalized.replaceFirst(RegExp(r'-build\.', caseSensitive: false), '+');
    final List<String> parts = canonical.split('+');
    final List<int> coreParts = parts.first
        .split('.')
        .map((String value) => int.tryParse(value) ?? 0)
        .toList(growable: false);
    final int buildNumber = parts.length < 2
        ? 0
        : int.tryParse(
              RegExp(r'\d+').stringMatch(parts.sublist(1).join('+')) ?? '',
            ) ??
            0;
    return _ParsedVersion(
      coreParts: coreParts,
      buildNumber: buildNumber,
    );
  }
}
