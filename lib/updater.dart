import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

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

class ReleaseUpdate {
  const ReleaseUpdate(this.version, this.url, this.sha256, this.size);
  final StableVersion version;
  final Uri url;
  final String sha256;
  final int size;
  static ReleaseUpdate? fromJson(
    Map<String, dynamic> json,
    String repository,
    StableVersion installed,
  ) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final version = StableVersion.parse(json['tag_name'] as String);
    if (version.compareTo(installed) <= 0) return null;
    final name = 'auralis-$version-windows-x64-setup.exe';
    final assets = (json['assets'] as List)
        .whereType<Map>()
        .where((a) => a['name'] == name)
        .toList();
    if (assets.length != 1) {
      throw const FormatException('Release has no unique Windows installer');
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
    this.launchHelper,
    this.requestExit,
  }) : _client = client ?? HttpClient() {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$')
            .hasMatch(repository) ||
        ['.', '..'].contains(repository.split('/').last)) {
      throw ArgumentError('Invalid GitHub repository');
    }
    StableVersion.parse(currentVersion);
    _client.connectionTimeout = const Duration(seconds: 15);
  }
  final String currentVersion, repository;
  final Directory directory;
  final AppSettings settings;
  final HttpClient _client;
  final Future<Process> Function(File script, File installer, String digest)?
  launchHelper;
  final Future<bool> Function()? requestExit;
  ReleaseUpdate? available;
  File? downloaded;
  bool checking = false, downloading = false, installing = false;
  String? error;
  String status = 'Updates have not been checked yet.';
  double progress = 0;
  Timer? _timer, _initial;
  bool _disposed = false;

  void start() {
    _initial ??= Timer(const Duration(seconds: 10), () {
      if (settings.automaticUpdates) unawaited(check());
    });
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) {
      if (settings.automaticUpdates) unawaited(check());
    });
  }

  Future<void> setAutomatic(bool enabled) async {
    settings.automaticUpdates = enabled;
    _changed();
    try {
      await settings.save();
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
      );
      if (available?.version.toString() != release?.version.toString() ||
          available?.sha256 != release?.sha256) {
        downloaded = null;
      }
      available = release;
      status = release == null
          ? 'You have the latest stable version.'
          : 'Version ${release.version} is available.';
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
      final installer = File(
        '${folder.path}/auralis-${release.version}-windows-x64-setup.exe',
      );
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
        requestExit == null ||
        _disposed) {
      return;
    }
    installing = true;
    status = 'Starting the update installer…';
    error = null;
    _changed();
    Process? helper;
    var closing = false;
    try {
      if ((await sha256.bind(installer.openRead()).first).toString() !=
          release.sha256) {
        downloaded = null;
        throw const FormatException('Installer changed after verification');
      }
      final ready = File('${installer.parent.path}/update-helper.ready');
      final failure = File('${installer.parent.path}/update-error.txt');
      for (final file in [ready, failure]) {
        if (await file.exists()) await file.delete();
      }
      final script = File('${installer.parent.path}/install-update.ps1');
      await script.writeAsString(installerScript, flush: true);
      helper = launchHelper != null
          ? await launchHelper!(script, installer, release.sha256)
          : await Process.start(
              '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
              [
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-WindowStyle',
                'Hidden',
                '-File',
                script.path,
                '-AppProcessId',
                '$pid',
                '-Installer',
                installer.path,
                '-ExpectedHash',
                release.sha256,
                '-ReadyFile',
                ready.path,
                '-InstallDirectory',
                File(Platform.resolvedExecutable).parent.path,
              ],
              mode: ProcessStartMode.detached,
            );
      await waitForUpdateHelper(ready, failure, helper.pid);
      status = 'Closing Auralis to install the update…';
      _changed();
      closing = true;
      if (!await requestExit!()) {
        helper.kill();
        throw StateError('Application exit cancelled');
      }
    } catch (_) {
      helper?.kill();
      status = 'Update installation could not start.';
      error = downloaded == null
          ? 'The installer changed after verification. Download the update again.'
          : closing
          ? 'Auralis could not finish closing for the update. Restart Auralis and retry, or close it and run the downloaded installer manually.'
          : 'Could not start the installer helper. Auralis has stayed open. Close it and run the downloaded installer manually. Download folder: ${installer.parent.path}';
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

/// A detached process can start and then fail before loading the script.
/// Require its acknowledgement before shutting down the running application.
Future<void> waitForUpdateHelper(
  File ready,
  File failure,
  int helperPid, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  do {
    if (await failure.exists()) throw StateError('Installer helper failed.');
    if (await ready.exists() &&
        (await ready.readAsString()).trim() == '$helperPid') {
      return;
    }
    if (watch.elapsed >= timeout) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  } while (watch.elapsed < timeout);
  throw TimeoutException('Installer helper did not become ready.');
}

// Wait for the framework's graceful audio/TDLib shutdown before touching installed files.
const installerScript = r'''
param(
  [Parameter(Mandatory=$true)][int]$AppProcessId,
  [Parameter(Mandatory=$true)][string]$Installer,
  [Parameter(Mandatory=$true)][string]$ExpectedHash,
  [Parameter(Mandatory=$true)][string]$ReadyFile,
  [Parameter(Mandatory=$true)][string]$InstallDirectory
)
$ErrorActionPreference = 'Stop'
try {
  $AppProcess = $null
  try { $AppProcess = [System.Diagnostics.Process]::GetProcessById($AppProcessId) } catch [System.ArgumentException] { }
  [System.IO.File]::WriteAllText("$ReadyFile.tmp", [string]$PID)
  [System.IO.File]::Move("$ReadyFile.tmp", $ReadyFile)
  if ($AppProcess -and -not $AppProcess.WaitForExit(90000)) { throw 'Auralis did not close; update cancelled.' }
  $Hash = [System.Security.Cryptography.SHA256]::Create()
  $Stream = [System.IO.File]::OpenRead($Installer)
  try { $ActualHash = [System.BitConverter]::ToString($Hash.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant() }
  finally { $Stream.Dispose(); $Hash.Dispose() }
  if ($ActualHash -ne $ExpectedHash) { throw 'Installer checksum mismatch.' }
  $Log = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Installer), 'installer.log')
  $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $StartInfo.FileName = $Installer
  $StartInfo.UseShellExecute = $false
  $StartInfo.Arguments = '/SILENT /NORESTART /CLOSEAPPLICATIONS /AURALISUPDATE=1 /DIR="{0}" /LOG="{1}"' -f $InstallDirectory, $Log
  $Setup = [System.Diagnostics.Process]::Start($StartInfo)
  # Wait for the actual GUI installer and read its exit code, never $LASTEXITCODE.
  $Setup.WaitForExit()
  $Code = $Setup.ExitCode
  $Setup.Dispose()
  if ($Code -ne 0) { throw "Installer failed with exit code $Code. See installer.log." }
} catch {
  [System.IO.File]::WriteAllText([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Installer), 'update-error.txt'), $_.Exception.Message)
  exit 1
}
''';
