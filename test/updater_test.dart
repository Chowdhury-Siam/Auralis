import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/storage.dart';
import 'package:auralis/updater.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(this.bytes, {this.statusCode = 200, String? redirect, int? size})
    : contentLength = size ?? bytes.length {
    if (redirect != null) headers.set('location', redirect);
  }
  final List<int> bytes;
  @override
  final int statusCode, contentLength;
  @override
  final headers = Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([bytes]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  Request(this.response);
  final Response response;
  @override
  final headers = Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Client implements HttpClient {
  Client(this.responses);
  final List<Response> responses;
  final requests = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return Request(responses.removeAt(0));
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Helper extends Fake implements Process {
  bool killed = false;
  @override
  int get pid => 4242;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }
}

const repository = 'Chowdhury-Siam/Auralis';
final installerBytes = utf8.encode(
  'MZ synthetic installer fixture; never executed',
);
Map<String, dynamic> release({String version = '0.2.0', String? digest}) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'assets': [
    {
      'name': 'auralis-$version-windows-x64-setup.exe',
      'size': installerBytes.length,
      'digest': digest ?? 'sha256:${sha256.convert(installerBytes)}',
      'browser_download_url':
          'https://github.com/$repository/releases/download/v$version/auralis-$version-windows-x64-setup.exe',
    },
  ],
};
Response metadata([Map<String, dynamic>? json]) =>
    Response(utf8.encode(jsonEncode(json ?? release())));

void main() {
  test('default updater targets the canonical Auralis repository', () {
    if (!const bool.hasEnvironment('AURALIS_RELEASE_REPOSITORY')) {
      expect(releaseRepository, repository);
    }
  });
  test(
    'stable numeric version comparison rejects prereleases and malformed tags',
    () {
      expect(
        StableVersion.parse('v0.1.10').compareTo(StableVersion.parse('0.1.9')),
        greaterThan(0),
      );
      expect(
        StableVersion.parse('2.0.0').compareTo(StableVersion.parse('1.99.99')),
        greaterThan(0),
      );
      for (final value in [
        '1.0.0-beta',
        '01.0.0',
        '1.0',
        '../1.0.0',
        '1.0.0+2',
      ]) {
        expect(() => StableVersion.parse(value), throwsFormatException);
      }
    },
  );
  test('release metadata requires stable newer version, exact repo installer, checksum and size', () {
    final current = StableVersion.parse('0.1.0');
    expect(
      ReleaseUpdate.fromJson(
        release(),
        repository,
        current,
      )!.version.toString(),
      '0.2.0',
    );
    expect(
      ReleaseUpdate.fromJson(release(version: '0.1.0'), repository, current),
      isNull,
    );
    expect(
      ReleaseUpdate.fromJson(
        release()..['prerelease'] = true,
        repository,
        current,
      ),
      isNull,
    );
    expect(
      ReleaseUpdate.fromJson(release()..['draft'] = true, repository, current),
      isNull,
    );
    for (final field in ['digest', 'size', 'browser_download_url']) {
      final json = release();
      json['assets'][0][field] = switch (field) {
        'digest' => '',
        'size' => 0,
        _ => 'https://example.com/setup.exe',
      };
      expect(
        () => ReleaseUpdate.fromJson(json, repository, current),
        throwsFormatException,
      );
    }
  });

  late Directory dir;
  late AppSettings settings;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auralis-update-tests-');
    settings = AppSettings(File('${dir.path}/settings.json'));
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Map<String, dynamic> androidRelease({String abi = 'arm64-v8a'}) {
    final json = release();
    final name = 'auralis-0.2.0-android-$abi-release.apk';
    (json['assets'] as List).add({
      'name': name,
      'size': installerBytes.length,
      'digest': 'sha256:${sha256.convert(installerBytes)}',
      'browser_download_url':
          'https://github.com/$repository/releases/download/v0.2.0/$name',
    });
    return json;
  }

  test(
    'Android selects only the signed APK for the installed architecture',
    () {
      for (final abi in ['arm64-v8a', 'x86_64']) {
        final json = androidRelease(abi: abi);
        final update = ReleaseUpdate.fromJson(
          json,
          repository,
          StableVersion.parse('0.1.0'),
          target: UpdateTarget.android,
          androidAbi: abi,
        )!;
        expect(update.url.path, endsWith('android-$abi-release.apk'));
        expect(
          () => ReleaseUpdate.fromJson(
            release(),
            repository,
            StableVersion.parse('0.1.0'),
            target: UpdateTarget.android,
            androidAbi: abi,
          ),
          throwsA(isA<UpdateAssetUnavailable>()),
        );
        json['assets'].add(json['assets'].last);
        expect(
          () => ReleaseUpdate.fromJson(
            json,
            repository,
            StableVersion.parse('0.1.0'),
            target: UpdateTarget.android,
            androidAbi: abi,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('Android verifies APK downloads and retries install permission without exiting', () async {
    var attempts = 0, exited = false;
    final updates = AppUpdater(
      currentVersion: '0.1.0',
      directory: Directory('${dir.path}/android'),
      settings: settings,
      client: Client([metadata(androidRelease()), Response(installerBytes)]),
      target: UpdateTarget.android,
      androidAbi: 'arm64-v8a',
      requestExit: () async {
        exited = true;
        return true;
      },
      installAndroid: (file, version, digest) async {
        attempts++;
        expect(file.path, endsWith('.apk'));
        expect(await file.readAsBytes(), installerBytes);
        expect(version, '0.2.0');
        expect(digest, sha256.convert(installerBytes).toString());
        if (attempts == 1) {
          throw PlatformException(
            code: 'permission',
            message: 'Allow installs from Auralis.',
          );
        }
      },
    );
    addTearDown(updates.dispose);
    await updates.check();
    await updates.download();
    expect(updates.downloaded, isNotNull);
    await updates.install();
    expect(updates.error, contains('Allow installs'));
    expect(updates.downloaded, isNotNull);
    await updates.install();
    expect(updates.error, isNull);
    expect(updates.status, contains('Android installer opened'));
    expect(exited, isFalse);
    expect(attempts, 2);
  });

  test(
    'Android automatically downloads verified updates but never auto-installs',
    () async {
      settings.automaticUpdates = false;
      var installed = false;
      final client = Client([
        metadata(androidRelease()),
        Response(installerBytes),
      ]);
      final updates = AppUpdater(
        currentVersion: '0.1.0',
        directory: Directory('${dir.path}/automatic'),
        settings: settings,
        client: client,
        target: UpdateTarget.android,
        androidAbi: 'arm64-v8a',
        installAndroid: (_, _, _) async {
          installed = true;
        },
      );
      addTearDown(updates.dispose);
      final ready = Completer<void>();
      updates.addListener(() {
        if (updates.downloaded != null && !ready.isCompleted) ready.complete();
      });
      await updates.setAutomatic(true);
      await ready.future.timeout(const Duration(seconds: 5));
      expect(client.requests, hasLength(2));
      expect(installed, isFalse);
      expect(await updates.downloaded!.readAsBytes(), installerBytes);
    },
  );

  test('Android missing APK reports publishing delay instead of claiming latest version', () async {
    final updates = AppUpdater(
      currentVersion: '0.1.0',
      directory: dir,
      settings: settings,
      client: Client([metadata()]),
      target: UpdateTarget.android,
      androidAbi: 'arm64-v8a',
    );
    addTearDown(updates.dispose);
    await updates.check();
    expect(updates.available, isNull);
    expect(updates.error, isNull);
    expect(updates.status, contains('not available'));
  });

  AppUpdater updater(
    Client client, {
    Future<Process> Function(File, List<String>)? launch,
    Future<bool> Function()? exit,
  }) {
    final result = AppUpdater(
      currentVersion: '0.1.0',
      directory: Directory('${dir.path}/updates'),
      settings: settings,
      client: client,
      launchInstaller: launch,
      requestExit: exit,
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'direct installer launch failure keeps the app open and permits retry',
    () async {
      var exited = false, fail = true;
      final updates = updater(
        Client([metadata(), Response(installerBytes)]),
        launch: (_, _) async {
          if (fail) {
            throw const ProcessException('setup.exe', [], 'fixture failure');
          }
          return Helper();
        },
        exit: () async {
          exited = true;
          return true;
        },
      );
      await updates.check();
      await updates.download();
      await updates.install();
      expect(exited, isFalse);
      expect(updates.error, contains('stayed open'));
      expect(updates.downloaded, isNotNull);
      fail = false;
      await updates.install();
      expect(exited, isTrue);
      expect(updates.error, isNull);
    },
  );

  test('verified installer starts directly before graceful exit', () async {
    final events = <String>[];
    final client = Client([metadata(), Response(installerBytes)]);
    final updates = updater(
      client,
      launch: (file, arguments) async {
        events.add('helper');
        expect(arguments, contains('/AURALISUPDATE=1'));
        expect(arguments, contains('/AURALISPID=$pid'));
        expect(arguments.any((arg) => arg.startsWith('/DIR=')), isTrue);
        expect(arguments.any((arg) => arg.startsWith('/LOG=')), isTrue);
        expect(
          await file.parent.list().any((file) => file.path.endsWith('.ps1')),
          isFalse,
        );
        expect(await file.readAsBytes(), installerBytes);
        return Helper();
      },
      exit: () async {
        events.add('exit');
        return true;
      },
    );
    await updates.check();
    expect(updates.available, isNotNull);
    await updates.download();
    expect(updates.error, isNull);
    expect(updates.downloaded, isNotNull);
    expect(updates.progress, 1);
    expect(client.requests.first.host, 'api.github.com');
    await updates.install();
    expect(events, ['helper', 'exit']);
    expect(updates.error, isNull);
  });
  test(
    'tampered and truncated installers are rejected and partial files removed',
    () async {
      for (final bytes in [
        utf8.encode('same length incorrect contents...............'),
        installerBytes.sublist(0, 8),
      ]) {
        final updates = updater(
          Client([metadata(), Response(bytes, size: installerBytes.length)]),
        );
        await updates.check();
        await updates.download();
        expect(updates.downloaded, isNull);
        expect(updates.error, contains('verified'));
      }
      expect(
        await dir
            .list(recursive: true)
            .where((f) => f.path.endsWith('.part'))
            .length,
        0,
      );
    },
  );
  test(
    'installer is hashed again before launch; cancelled exit reports recovery',
    () async {
      var launched = false;
      final updates = updater(
        Client([metadata(), Response(installerBytes)]),
        launch: (_, _) async {
          launched = true;
          return Helper();
        },
        exit: () async => true,
      );
      await updates.check();
      await updates.download();
      await updates.downloaded!.writeAsString('tampered');
      await updates.install();
      expect(launched, isFalse);
      expect(updates.downloaded, isNull);
      final helper = Helper();
      final cancelled = updater(
        Client([metadata(), Response(installerBytes)]),
        launch: (_, _) async => helper,
        exit: () async => false,
      );
      await cancelled.check();
      await cancelled.download();
      await cancelled.install();
      expect(cancelled.error, contains('Cancel the installer'));
    },
  );
  test('404 is a normal no-release state; rate limits surface without quitting the app', () async {
    final absent = updater(Client([Response([], statusCode: 404)]));
    await absent.check();
    expect(absent.available, isNull);
    expect(absent.error, isNull);
    final limited = updater(Client([Response([], statusCode: 403)]));
    await limited.check();
    expect(limited.error, isNotNull);
    expect(limited.checking, isFalse);
  });
  test(
    'launch and cleanup failures retain the verified installer for recovery',
    () async {
      for (final duringCleanup in [false, true]) {
        final helper = Helper();
        var exitCalled = false;
        final updates = updater(
          Client([metadata(), Response(installerBytes)]),
          launch: (_, _) async {
            if (!duringCleanup) {
              throw const ProcessException(
                'powershell.exe',
                [],
                'test launch failure',
                5,
              );
            }
            return helper;
          },
          exit: () async {
            exitCalled = true;
            throw StateError('test cleanup failed');
          },
        );
        await updates.check();
        await updates.download();
        await updates.install();
        expect(
          updates.error,
          contains(duringCleanup ? 'finish closing' : 'could not open'),
        );
        expect(updates.error, contains('Download folder'));
        expect(updates.downloaded, isNotNull);
        expect(updates.installing, isFalse);
        expect(exitCalled, duringCleanup);
      }
    },
  );
  test(
    'redirects allow GitHub CDN over HTTPS and reject an arbitrary host',
    () async {
      final good = updater(
        Client([
          metadata(),
          Response(
            [],
            statusCode: 302,
            redirect: 'https://release-assets.githubusercontent.com/asset',
          ),
          Response(installerBytes),
        ]),
      );
      await good.check();
      await good.download();
      expect(good.downloaded, isNotNull);
      final client = Client([
        metadata(),
        Response(
          [],
          statusCode: 302,
          redirect: 'https://example.com/installer.exe',
        ),
      ]);
      final bad = updater(client);
      await bad.check();
      await bad.download();
      expect(bad.downloaded, isNull);
      expect(client.requests.length, 2);
    },
  );
  test(
    'automatic update preference persists independently of existing settings',
    () async {
      final updates = updater(Client([]));
      await updates.setAutomatic(false);
      final restored = AppSettings(settings.file);
      await restored.load();
      expect(restored.automaticUpdates, isFalse);
      await settings.file.writeAsString('{}');
      await restored.load();
      expect(restored.automaticUpdates, isTrue);
    },
  );
}
