import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'storage.dart';

const releaseRepository = String.fromEnvironment(
  'AURALIS_RELEASE_REPOSITORY',
  defaultValue: 'Chowdhury-Siam/Auralis',
);

class StableVersion implements Comparable<StableVersion> {
  StableVersion(this.major, this.minor, this.patch);
  final int major, minor, patch;
  static StableVersion parse(String value) {
    final match = RegExp(r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
        .firstMatch(value);
    if (match == null) throw const FormatException('Stable version required');
    return StableVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  @override
  int compareTo(StableVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final compared = pair.$1.compareTo(pair.$2);
      if (compared != 0) return compared;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch';
}

enum UpdateTarget { windows, android }

class UpdateAssetUnavailable implements Exception {
  const UpdateAssetUnavailable(this.message);
  final String message;
}

class ReleaseUpdate {
  const ReleaseUpdate(this.version, this.url, this.sha256, this.size);
  final StableVersion version;
  final Uri url;
  final String sha256;
  final int size;
  static ReleaseUpdate? fromJson(
    Map<String, dynamic> json,
    String repository,
    StableVersion installed, {
    UpdateTarget target = UpdateTarget.windows,
    String? androidAbi,
  }) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final version = StableVersion.parse(json['tag_name'] as String);
    if (version.compareTo(installed) <= 0) return null;
    if (target == UpdateTarget.android &&
        !const ['arm64-v8a', 'x86_64'].contains(androidAbi)) {
      throw const FormatException('Unsupported Android update architecture');
    }
    final name = target == UpdateTarget.android
        ? 'auralis-$version-android-$androidAbi-release.apk'
        : 'auralis-$version-windows-x64-setup.exe';
    final assets = (json['assets'] as List)
        .whereType<Map>()
        .where((a) => a['name'] == name)
        .toList();
    if (assets.length != 1) {
      if (target == UpdateTarget.android && assets.isEmpty) {
        throw UpdateAssetUnavailable(
          'The signed Android $androidAbi update is not available in this release yet. Check again later.',
        );
      }
      throw const FormatException('Release has no unique platform installer');
    }
    final asset = assets.single;
    final digest = asset['digest'] as String? ?? '';
    if (!RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Installer has no GitHub SHA-256 digest');
    }
    final size = asset['size'] as int;
    if (size <= 0 || size > 512 * 1024 * 1024) {
      throw const FormatException('Invalid installer size');
    }
    final url = Uri.parse(asset['browser_download_url'] as String);
    final expected = Uri.https(
      'github.com',
      '/$repository/releases/download/${json['tag_name']}/$name',
    );
    if (url != expected) {
      throw const FormatException(
        'Installer URL does not match the configured release',
      );
    }
    return ReleaseUpdate(version, url, digest.substring(7).toLowerCase(), size);
  }
}

/// Checks one public repository; no GitHub token, Telegram data, or private URLs.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    required this.currentVersion,
    required this.directory,
    required this.settings,
    this.repository = releaseRepository,
    HttpClient? client,
    this.launchInstaller,
    this.requestExit,
    this.target = UpdateTarget.windows,
    this.androidAbi,
    this.installAndroid,
  }) : _client = client ?? HttpClient() {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$')
            .hasMatch(repository) ||
        ['.', '..'].contains(repository.split('/').last)) {
      throw ArgumentError('Invalid GitHub repository');
    }
    StableVersion.parse(currentVersion);
    if (target == UpdateTarget.android &&
        !const ['arm64-v8a', 'x86_64'].contains(androidAbi)) {
      throw ArgumentError('A supported Android ABI is required');
    }
    _client.connectionTimeout = const Duration(seconds: 15);
  }
  final String currentVersion, repository;
  final UpdateTarget target;
  final String? androidAbi;
  final Future<void> Function(File, String, String)? installAndroid;
  bool get isAndroid => target == UpdateTarget.android;
  String get installLabel =>
      isAndroid ? 'Install update' : 'Install and restart';
  final Directory directory;
  final AppSettings settings;
  final HttpClient _client;
  final Future<Process> Function(File installer, List<String> arguments)?
  launchInstaller;
  final Future<bool> Function()? requestExit;
  ReleaseUpdate? available;
  File? downloaded;
  bool checking = false, downloading = false, installing = false;
  String? error;
  String status = 'Updates have not been checked yet.';
  double progress = 0;
  Timer? _timer, _initial;
  bool _disposed = false;
  DateTime? _lastAutomaticCheck;

  void start() {
    _initial ??= Timer(const Duration(seconds: 10), () {
      if (settings.automaticUpdates) checkOnResume();
    });
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) {
      if (settings.automaticUpdates) unawaited(_automaticCheck());
    });
  }

  Future<void> _automaticCheck() async {
    if (_disposed ||
        !settings.automaticUpdates ||
        checking ||
        downloading ||
        installing) {
      return;
    }
    _lastAutomaticCheck = DateTime.now();
    await check();
    if (isAndroid &&
        !_disposed &&
        settings.automaticUpdates &&
        available != null &&
        downloaded == null &&
        error == null) {
      await download();
    }
  }

  void checkOnResume() {
    if (_lastAutomaticCheck == null ||
        DateTime.now().difference(_lastAutomaticCheck!) >=
            const Duration(hours: 6)) {
      unawaited(_automaticCheck());
    }
  }

  Future<void> setAutomatic(bool enabled) async {
    settings.automaticUpdates = enabled;
    _changed();
    try {
      await settings.save();
      if (enabled && isAndroid) unawaited(_automaticCheck());
    } catch (_) {
      error = 'Could not save the update preference.';
      _changed();
    }
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    // GitHub release downloads redirect to its asset CDN; never follow HTTP or arbitrary hosts.
    for (var i = 0; i < 6; i++) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && uri.port != 443) ||
          !{
            'api.github.com',
            'github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
          }.contains(uri.host)) {
        throw const FormatException('Untrusted download address');
      }
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set('User-Agent', 'Auralis/$currentVersion');
      if (uri.host == 'api.github.com') {
        request.headers.set('Accept', 'application/vnd.github+json');
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (location == null) {
          throw const FormatException('Missing download location');
        }
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw const FormatException('Too many redirects');
  }

  Future<void> check() async {
    if (checking || downloading || installing || _disposed) return;
    checking = true;
    error = null;
    status = 'Checking GitHub Releases…';
    _changed();
    try {
      final response = await _get(
        Uri.https('api.github.com', '/repos/$repository/releases/latest'),
      );
      if (response.statusCode == 404) {
        await response.drain<void>().timeout(const Duration(seconds: 20));
        status = 'No public stable release is available yet.';
        available = null;
        downloaded = null;
        return;
      }
      if (response.statusCode != 200) {
        await response.drain<void>().timeout(const Duration(seconds: 20));
        throw HttpException('GitHub HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const FormatException('Release response too large');
        }
      }
      final release = ReleaseUpdate.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        repository,
        StableVersion.parse(currentVersion),
        target: target,
        androidAbi: androidAbi,
      );
      if (available?.version.toString() != release?.version.toString() ||
          available?.sha256 != release?.sha256) {
        downloaded = null;
      }
      available = release;
      status = release == null
          ? 'You have the latest stable version.'
          : 'Version ${release.version} is available.';
    } on UpdateAssetUnavailable catch (unavailable) {
      available = null;
      downloaded = null;
      status = unavailable.message;
    } catch (_) {
      error =
          'Could not check for updates. Check your connection and try again.';
      status = 'Update check failed.';
    } finally {
      checking = false;
      _changed();
    }
  }

  Future<void> download() async {
    final release = available;
    if (release == null || downloading || checking || installing || _disposed) {
      return;
    }
    downloading = true;
    downloaded = null;
    error = null;
    progress = 0;
    status = 'Downloading ${release.version}…';
    _changed();
    File? partial;
    try {
      await directory.create(recursive: true);
      final folder = await directory.createTemp('release-');
      final installer = File('${folder.path}/${release.url.pathSegments.last}');
      partial = File('${installer.path}.part');
      final response = await _get(release.url);
      if (response.statusCode != 200 ||
          (response.contentLength >= 0 &&
              response.contentLength != release.size)) {
        await response.drain<void>().timeout(const Duration(seconds: 20));
        throw const HttpException('Installer download failed');
      }
      final file = await partial.open(mode: FileMode.writeOnly);
      var count = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          count += chunk.length;
          if (count > release.size) {
            throw const FormatException('Installer larger than declared size');
          }
          await file.writeFrom(chunk);
          progress = count / release.size;
          _changed();
        }
        await file.flush();
      } finally {
        await file.close();
      }
      if (count != release.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.sha256) {
        throw const FormatException('Installer checksum mismatch');
      }
      await partial.rename(installer.path);
      partial = null;
      downloaded = installer;
      status = 'Download ready. SHA-256 checksum verified.';
    } catch (_) {
      error = 'The update could not be downloaded or verified. Nothing was installed; try downloading again.';
      status = 'Update download failed.';
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        /* A failed cleanup must not leave the updater busy. */
      }
      downloading = false;
      _changed();
    }
  }

  Future<void> install() async {
    final release = available, installer = downloaded;
    if (release == null ||
        installer == null ||
        installing ||
        checking ||
        downloading ||
        (isAndroid ? installAndroid == null : requestExit == null) ||
        _disposed) {
      return;
    }
    installing = true;
    status = 'Starting the update installer…';
    error = null;
    _changed();
    var launched = false;
    try {
      if (!await installer.exists() ||
          await installer.length() != release.size ||
          (await sha256.bind(installer.openRead()).first).toString() !=
              release.sha256) {
        downloaded = null;
        throw const FormatException('Installer changed after verification');
      }
      if (isAndroid) {
        await installAndroid!(
          installer,
          release.version.toString(),
          release.sha256,
        );
        status = 'Android installer opened. Confirm the update on your device.';
        return;
      }
      // Yutaka's direct executable handoff: no PowerShell policy or ready file.
      // The installer waits for this PID before accessing installed files.
      final arguments = [
        '/AURALISUPDATE=1',
        '/AURALISPID=$pid',
        '/NORESTART',
        '/DIR=${File(Platform.resolvedExecutable).parent.path}',
        '/LOG=${installer.parent.path}/installer.log',
      ];
      if (launchInstaller != null) {
        await launchInstaller!(installer, arguments);
      } else {
        await startWindowsInstaller(installer, arguments);
      }
      launched = true;
      status = 'Closing Auralis. Continue in the update installer…';
      _changed();
      if (!await requestExit!()) throw StateError('Application exit cancelled');
    } catch (failure) {
      status = 'Update installation could not start.';
      error = downloaded == null
          ? 'The installer changed after verification. Download the update again.'
          : isAndroid
          ? failure is PlatformException
                ? failure.message ??
                      'Android could not open the update installer. Try again.'
                : 'Android could not open the update installer. Your download is kept; try again.'
          : launched
          ? 'Auralis could not finish closing. Cancel the installer, restart Auralis and retry. Download folder: ${installer.parent.path}'
          : 'Windows could not open the installer. Auralis has stayed open. Close it and run the downloaded installer manually. Download folder: ${installer.parent.path}';
    } finally {
      installing = false;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _initial?.cancel();
    _timer?.cancel();
    _client.close(force: true);
    super.dispose();
  }
}

Future<Process> startWindowsInstaller(File installer, List<String> arguments) =>
    Process.start(
      installer.path,
      arguments,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
