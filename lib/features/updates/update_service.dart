import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_info.dart';
import '../../core/network/dio_factory.dart';

/// Semantic version helper for release comparison.
@immutable
class SemVer {
  final int major;
  final int minor;
  final int patch;
  final int build;
  final String raw;

  const SemVer({
    required this.major,
    required this.minor,
    required this.patch,
    this.build = 0,
    required this.raw,
  });

  static SemVer parse(String versionStr) {
    var v = versionStr.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1).trim();
    }
    var buildNum = 0;
    if (v.contains('+')) {
      final parts = v.split('+');
      v = parts[0];
      buildNum = int.tryParse(parts[1]) ?? 0;
    }
    if (v.contains('-')) {
      v = v.split('-')[0];
    }
    final parts = v.split('.');
    final major = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final patch = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;

    return SemVer(
      major: major,
      minor: minor,
      patch: patch,
      build: buildNum,
      raw: versionStr,
    );
  }

  bool isGreaterThan(SemVer other) {
    if (major != other.major) return major > other.major;
    if (minor != other.minor) return minor > other.minor;
    if (patch != other.patch) return patch > other.patch;
    return build > other.build;
  }

  @override
  String toString() => '$major.$minor.$patch${build > 0 ? '+$build' : ''}';
}

/// A release asset published on GitHub.
class AppReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;

  const AppReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  factory AppReleaseAsset.fromJson(Map<String, dynamic> json) {
    return AppReleaseAsset(
      name: json['name'] as String? ?? '',
      downloadUrl: json['browser_download_url'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Installation type of the running application instance.
enum AppInstallType {
  windowsInstalled('Windows Setup (Installed)'),
  windowsPortable('Windows Portable (.zip)'),
  linuxAppImage('Linux AppImage'),
  linuxDeb('Linux Debian / Ubuntu (.deb)'),
  linuxRpm('Linux Fedora / RHEL (.rpm)'),
  macosZip('macOS Archive (.zip)'),
  other('Universal / Other');

  final String label;
  const AppInstallType(this.label);
}

/// Detect whether the current app is running as an installed setup, portable zip, or specific distro format.
AppInstallType detectCurrentInstallType() {
  if (Platform.isWindows) {
    try {
      final exePath = Platform.resolvedExecutable;
      final exeDir = p.dirname(exePath);
      // Inno Setup places unins000.exe or unins001.exe in the installation folder
      final hasUninstaller = File(p.join(exeDir, 'unins000.exe')).existsSync() ||
          File(p.join(exeDir, 'unins001.exe')).existsSync();
      final inPrograms = exePath.toLowerCase().contains(r'programs\lastwave') ||
          exePath.toLowerCase().contains(r'program files');

      if (hasUninstaller || inPrograms) {
        return AppInstallType.windowsInstalled;
      }
      return AppInstallType.windowsPortable;
    } catch (_) {
      return AppInstallType.windowsInstalled;
    }
  }

  if (Platform.isLinux) {
    if (Platform.environment.containsKey('APPIMAGE')) {
      return AppInstallType.linuxAppImage;
    }
    try {
      if (File('/etc/debian_version').existsSync()) {
        return AppInstallType.linuxDeb;
      }
      if (File('/etc/fedora-release').existsSync() ||
          File('/etc/redhat-release').existsSync()) {
        return AppInstallType.linuxRpm;
      }
      if (File('/etc/os-release').existsSync()) {
        final content = File('/etc/os-release').readAsStringSync().toLowerCase();
        if (content.contains('ubuntu') || content.contains('debian')) {
          return AppInstallType.linuxDeb;
        }
        if (content.contains('fedora') || content.contains('rhel') || content.contains('suse')) {
          return AppInstallType.linuxRpm;
        }
      }
    } catch (_) {}
    return AppInstallType.linuxAppImage;
  }

  if (Platform.isMacOS) {
    return AppInstallType.macosZip;
  }

  return AppInstallType.other;
}

/// Metadata describing an available GitHub release.
class AppUpdateInfo {
  final String tagName;
  final String version;
  final String title;
  final String changelog;
  final String htmlUrl;
  final DateTime? publishedAt;
  final List<AppReleaseAsset> assets;

  const AppUpdateInfo({
    required this.tagName,
    required this.version,
    required this.title,
    required this.changelog,
    required this.htmlUrl,
    required this.publishedAt,
    required this.assets,
  });

  factory AppUpdateInfo.fromGitHubJson(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String? ?? '';
    var ver = tagName;
    if (ver.startsWith('v') || ver.startsWith('V')) {
      ver = ver.substring(1);
    }
    final title = json['name'] as String? ?? tagName;
    final changelog = json['body'] as String? ?? '';
    final htmlUrl = json['html_url'] as String? ?? '';
    final rawPublished = json['published_at'] as String?;
    final publishedAt =
        rawPublished != null ? DateTime.tryParse(rawPublished) : null;

    final rawAssets = json['assets'] as List<dynamic>? ?? const [];
    final assets = rawAssets
        .whereType<Map<String, dynamic>>()
        .map(AppReleaseAsset.fromJson)
        .toList();

    return AppUpdateInfo(
      tagName: tagName,
      version: ver,
      title: title,
      changelog: changelog,
      htmlUrl: htmlUrl,
      publishedAt: publishedAt,
      assets: assets,
    );
  }

  /// Locate the most suitable binary or installer asset for the host platform.
  AppReleaseAsset? findBestAsset([AppInstallType? targetType]) {
    if (assets.isEmpty) return null;
    final type = targetType ?? detectCurrentInstallType();

    switch (type) {
      case AppInstallType.windowsInstalled:
        return assets.firstWhere(
          (a) =>
              a.name.toLowerCase().endsWith('.exe') &&
              a.name.toLowerCase().contains('setup'),
          orElse: () => assets.firstWhere(
            (a) => a.name.toLowerCase().endsWith('.exe'),
            orElse: () => assets.first,
          ),
        );

      case AppInstallType.windowsPortable:
        return assets.firstWhere(
          (a) =>
              a.name.toLowerCase().contains('portable') &&
              a.name.toLowerCase().endsWith('.zip'),
          orElse: () => assets.firstWhere(
            (a) =>
                a.name.toLowerCase().contains('windows') &&
                a.name.toLowerCase().endsWith('.zip'),
            orElse: () => assets.firstWhere(
              (a) => a.name.toLowerCase().endsWith('.exe'),
              orElse: () => assets.first,
            ),
          ),
        );

      case AppInstallType.linuxAppImage:
        return assets.firstWhere(
          (a) => a.name.toLowerCase().endsWith('.appimage'),
          orElse: () => assets.first,
        );

      case AppInstallType.linuxDeb:
        return assets.firstWhere(
          (a) => a.name.toLowerCase().endsWith('.deb'),
          orElse: () => assets.firstWhere(
            (a) => a.name.toLowerCase().endsWith('.appimage'),
            orElse: () => assets.first,
          ),
        );

      case AppInstallType.linuxRpm:
        return assets.firstWhere(
          (a) => a.name.toLowerCase().endsWith('.rpm'),
          orElse: () => assets.firstWhere(
            (a) => a.name.toLowerCase().endsWith('.appimage'),
            orElse: () => assets.first,
          ),
        );

      case AppInstallType.macosZip:
        return assets.firstWhere(
          (a) =>
              a.name.toLowerCase().contains('macos') &&
              a.name.toLowerCase().endsWith('.zip'),
          orElse: () => assets.firstWhere(
            (a) => a.name.toLowerCase().endsWith('.dmg'),
            orElse: () => assets.first,
          ),
        );

      case AppInstallType.other:
        return assets.firstOrNull;
    }
  }
}

/// Service handling GitHub release checks, downloading and running updates.
class UpdateService {
  final Dio _dio;

  static const String repoOwner = 'Clash-Projects';
  static const String repoName = 'LastWave-Desktop';
  static const String releasesLatestUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';

  UpdateService({Dio? dio}) : _dio = dio ?? DioFactory.create();

  /// Query GitHub for the latest release and determine if an update is available.
  Future<AppUpdateInfo?> checkForUpdate() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        releasesLatestUrl,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github.v3+json',
          },
        ),
      );

      final data = response.data;
      if (data == null) return null;

      final update = AppUpdateInfo.fromGitHubJson(data);
      final latestSemver = SemVer.parse(update.version);
      final currentSemver = SemVer.parse(appVersion);

      if (latestSemver.isGreaterThan(currentSemver)) {
        return update;
      }
      return null;
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Download the selected or best installer asset for the current OS and launch it.
  Future<void> downloadAndInstall({
    required AppUpdateInfo update,
    AppReleaseAsset? targetAsset,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final asset = targetAsset ?? update.findBestAsset();
    if (asset == null || asset.downloadUrl.isEmpty) {
      throw StateError('No suitable release asset found for this platform.');
    }

    final tempDir = await getTemporaryDirectory();
    final fileName = asset.name.isNotEmpty
        ? asset.name
        : 'lastwave_update_${update.version}.exe';
    final savePath = p.join(tempDir.path, fileName);

    // Delete any stale partially-downloaded file first
    final file = File(savePath);
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }

    // Stream download with progress callback
    await _dio.download(
      asset.downloadUrl,
      savePath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        onProgress(received, total);
      },
    );

    // Launch the downloaded package / installer
    if (Platform.isWindows) {
      if (savePath.toLowerCase().endsWith('.exe')) {
        await Process.start(
          savePath,
          [],
          mode: ProcessStartMode.detached,
          runInShell: true,
        );
        // Give the OS process launcher a moment to spin up the installer before exiting
        await Future<void>.delayed(const Duration(milliseconds: 400));
        exit(0);
      } else {
        // Portable zip: reveal in File Explorer
        await Process.start('explorer.exe', ['/select,', savePath]);
      }
    } else if (Platform.isLinux) {
      if (savePath.toLowerCase().endsWith('.appimage')) {
        Process.runSync('chmod', ['+x', savePath]);
        await Process.start(savePath, [], mode: ProcessStartMode.detached);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        exit(0);
      } else if (savePath.toLowerCase().endsWith('.deb') ||
          savePath.toLowerCase().endsWith('.rpm')) {
        // Open with default GUI package installer
        await Process.start('xdg-open', [savePath]);
      } else {
        await Process.start('xdg-open', [tempDir.path]);
      }
    } else if (Platform.isMacOS) {
      if (savePath.toLowerCase().endsWith('.zip')) {
        // Reveal zip in Finder so user can extract without Gatekeeper issues
        await Process.start('open', ['-R', savePath]);
      } else {
        await Process.start('open', [savePath]);
      }
    }
  }
}

final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService();
});
