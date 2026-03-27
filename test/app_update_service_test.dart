import 'package:backchat/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart' as play_update;
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  PackageInfo packageInfo({String? installerStore}) {
    return PackageInfo(
      appName: 'Backchat',
      packageName: 'com.mysticalg.backchat',
      version: '0.1.0',
      buildNumber: '8',
      buildSignature: '',
      installerStore: installerStore,
    );
  }

  Map<String, dynamic> latestRelease({
    String? name,
    String tagName = 'v0.1.0-build.9',
  }) {
    return <String, dynamic>{
      'name': name ?? 'Backchat 0.1.0+9',
      'tag_name': tagName,
      'html_url': 'https://github.com/mysticalg/Backchat/releases/tag/$tagName',
      'assets': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'backchat-windows-x64-0.1.0+9.zip',
          'browser_download_url': 'https://example.com/backchat-windows.zip',
        },
        <String, dynamic>{
          'name': 'backchat-macos-0.1.0+9.zip',
          'browser_download_url': 'https://example.com/backchat-macos.zip',
        },
        <String, dynamic>{
          'name': 'backchat-linux-x64-0.1.0+9.tar.gz',
          'browser_download_url': 'https://example.com/backchat-linux.tar.gz',
        },
        <String, dynamic>{
          'name': 'backchat-android-0.1.0+9.apk',
          'browser_download_url': 'https://example.com/backchat-android.apk',
        },
      ],
    };
  }

  test('reports up to date when the installed build matches the latest release',
      () async {
    final AppUpdateService service = AppUpdateService(
      packageInfoLoader: () async => packageInfo(),
      latestReleaseFetcher: () async => latestRelease(name: 'Backchat 0.1.0+8'),
      platform: AppUpdatePlatform.windows,
    );

    final AppUpdateCheckResult result = await service.checkForStartupUpdate();

    expect(result.status, AppUpdateStatus.upToDate);
    expect(result.latestRelease?.version, '0.1.0+8');
  });

  test('prompts manual desktop download when a newer release exists', () async {
    final AppUpdateService service = AppUpdateService(
      packageInfoLoader: () async => packageInfo(),
      latestReleaseFetcher: () async => latestRelease(),
      platform: AppUpdatePlatform.windows,
    );

    final AppUpdateCheckResult result = await service.checkForStartupUpdate();

    expect(result.status, AppUpdateStatus.manualUpdateAvailable);
    expect(result.latestRelease?.version, '0.1.0+9');
    expect(
      result.actionUrl,
      Uri.parse('https://example.com/backchat-windows.zip'),
    );
  });

  test('starts APK install for newer sideloaded Android releases', () async {
    Uri? requestedUrl;
    String? requestedVersion;
    final AppUpdateService service = AppUpdateService(
      packageInfoLoader: () async => packageInfo(),
      latestReleaseFetcher: () async => latestRelease(),
      platform: AppUpdatePlatform.android,
      androidApkInstaller: ({
        required Uri downloadUrl,
        required String versionLabel,
      }) async {
        requestedUrl = downloadUrl;
        requestedVersion = versionLabel;
        return AndroidApkInstallStatus.started;
      },
    );

    final AppUpdateCheckResult result = await service.checkForStartupUpdate();

    expect(result.status, AppUpdateStatus.autoInstallStarted);
    expect(requestedVersion, '0.1.0+9');
    expect(
      requestedUrl,
      Uri.parse('https://example.com/backchat-android.apk'),
    );
  });

  test('retries after Android installer permission is granted', () async {
    final AppUpdateService service = AppUpdateService(
      packageInfoLoader: () async => packageInfo(),
      latestReleaseFetcher: () async => latestRelease(),
      platform: AppUpdatePlatform.android,
      androidApkInstaller: ({
        required Uri downloadUrl,
        required String versionLabel,
      }) async {
        return AndroidApkInstallStatus.permissionRequired;
      },
    );

    final AppUpdateCheckResult result = await service.checkForStartupUpdate();

    expect(result.status, AppUpdateStatus.installerPermissionRequired);
    expect(result.shouldRetryOnResume, isTrue);
  });

  test('uses Google Play immediate updates for Play-managed Android installs',
      () async {
    bool releaseFetchCalled = false;
    final AppUpdateService service = AppUpdateService(
      packageInfoLoader: () async =>
          packageInfo(installerStore: 'com.android.vending'),
      latestReleaseFetcher: () async {
        releaseFetchCalled = true;
        return latestRelease();
      },
      playUpdateInfoLoader: () async {
        return play_update.AppUpdateInfo(
          updateAvailability: play_update.UpdateAvailability.updateAvailable,
          immediateUpdateAllowed: true,
          immediateAllowedPreconditions: const <int>[],
          flexibleUpdateAllowed: false,
          flexibleAllowedPreconditions: const <int>[],
          availableVersionCode: 9,
          installStatus: play_update.InstallStatus.pending,
          packageName: 'com.mysticalg.backchat',
          clientVersionStalenessDays: 2,
          updatePriority: 5,
        );
      },
      playImmediateUpdater: () async => play_update.AppUpdateResult.success,
      platform: AppUpdatePlatform.android,
    );

    final AppUpdateCheckResult result = await service.checkForStartupUpdate();

    expect(result.status, AppUpdateStatus.autoInstallStarted);
    expect(releaseFetchCalled, isFalse);
  });

  test('parses release versions from build tags when the release name is blank',
      () async {
    final AppUpdateService service = AppUpdateService(
      packageInfoLoader: () async => packageInfo(),
      latestReleaseFetcher: () async =>
          latestRelease(name: '', tagName: 'v0.1.0-build.10'),
      platform: AppUpdatePlatform.windows,
    );

    final AppUpdateCheckResult result = await service.checkForStartupUpdate();

    expect(result.status, AppUpdateStatus.manualUpdateAvailable);
    expect(result.latestRelease?.version, '0.1.0+10');
  });
}
