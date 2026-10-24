import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/android_audio.dart';
import 'package:auralis/android_updater.dart';
import 'package:auralis/account_backup.dart';
import 'package:auralis/data_files.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/android_storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.auralis/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android vault uses encrypted native bytes and retains the old file on failure', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-android-vault');
    addTearDown(() => dir.delete(recursive: true));
    final vault = AndroidSecretVault(File('${dir.path}/vault.aesgcm'));
    var fail = false;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (fail) throw PlatformException(code: 'keystore');
      // This checks the bridge/storage contract, not native cryptography.
      return Uint8List.fromList(
        (call.arguments as Uint8List).map((b) => b ^ 0xff).toList(),
      );
    });
    final secrets = {
      'apiId': 123,
      'apiHash': 'test-secret',
      'databaseKey': 'key',
    };
    await vault.write(secrets);
    final saved = await vault.file.readAsBytes();
    expect(saved, isNot(utf8.encode(jsonEncode(secrets))));
    expect(await vault.read(), secrets);
    expect(calls, ['encrypt', 'decrypt', 'decrypt']);
    fail = true;
    await expectLater(
      vault.write({'apiId': 456}),
      throwsA(isA<PlatformException>()),
    );
    expect(await vault.file.readAsBytes(), saved);
    await expectLater(vault.read(), throwsA(isA<PlatformException>()));
  });

  test('Android vault owns writable copies of read-only platform replies', () async {
    const codec = StandardMethodCodec();
    messenger.setMockMessageHandler(channel.name, (message) async {
      final call = codec.decodeMethodCall(message);
      // Model immutable platform-message memory, not native cryptography.
      final result = Uint8List.fromList(
        (call.arguments as Uint8List).map((byte) => byte ^ 0xff).toList(),
      );
      return codec.encodeSuccessEnvelope(result).asUnmodifiableView();
    });
    final native = (await channel.invokeMethod<Uint8List>(
      'decrypt', Uint8List.fromList([1, 2, 3]),
    ))!;
    expect(() => native.fillRange(0, native.length, 0), throwsUnsupportedError);
    final dir = await Directory.systemTemp.createTemp('auralis-readonly-vault');
    addTearDown(() => dir.delete(recursive: true));
    final vault = AndroidSecretVault(File('${dir.path}/vault.aesgcm'));
    final secrets = {'apiId': 123, 'apiHash': 'synthetic-secret'};
    await vault.write(secrets);
    expect(await vault.read(), secrets);
    final owned = await vault.transform([1, 2, 3], encrypt: false);
    owned.fillRange(0, owned.length, 0);
    expect(owned, [0, 0, 0]);
  });

  test('portable Android restore and rollback work with read-only native buffers', () async {
    const codec = StandardMethodCodec();
    messenger.setMockMessageHandler(channel.name, (message) async {
      final call = codec.decodeMethodCall(message);
      final result = Uint8List.fromList(
        (call.arguments as Uint8List).map((byte) => byte ^ 0xff).toList(),
      );
      return codec.encodeSuccessEnvelope(result).asUnmodifiableView();
    });
    final credentials = <String, dynamic>{
      'apiId': 12345,
      'apiHash': 'abcdef0123456789abcdef0123456789',
      'databaseKey': base64Encode(List.filled(32, 7)),
    };
    final account = TelegramAccount.fromJson({
      'credentials': credentials,
      'files': {'td.binlog': base64Encode(utf8.encode('portable session'))},
    });
    for (final fail in [true, false]) {
      final dir = await Directory.systemTemp.createTemp('auralis-readonly-restore');
      addTearDown(() => dir.delete(recursive: true));
      final vault = AndroidSecretVault(File('${dir.path}/vault.aesgcm'));
      final previous = {...credentials, 'apiId': 98765};
      await vault.write(previous);
      final protected = await vault.file.readAsBytes();
      final database = File('${dir.path}/database/td.binlog');
      await database.parent.create();
      await database.writeAsString('previous session');
      final service = TelegramService(
        dir, vault, transport: FakeTd(), createTransport: FakeTd.new,
      );
      var restored = false;
      Future<void> restore() => service.restoreAccount(account, () async {
        expect(await vault.read(), credentials);
        if (fail) throw const FileSystemException('settings write failed');
        restored = true;
      });
      if (fail) {
        await expectLater(restore(), throwsA(isA<FileSystemException>()));
        expect(await vault.file.readAsBytes(), protected);
        expect(await database.readAsString(), 'previous session');
      } else {
        await restore();
        expect(restored, isTrue);
        expect(await vault.read(), credentials);
        expect(await database.readAsString(), 'portable session');
        expect(service.error, isNull);
      }
      await service.shutdown();
    }
  });

  test('Android update bridge sends only the verified APK handoff', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'updateInfo') {
        return {'abi': 'arm64-v8a', 'directory': '/private/auralis-updates'};
      }
      return true;
    });
    const bridge = AndroidUpdateBridge();
    final info = await bridge.info();
    expect(info.abi, 'arm64-v8a');
    expect(info.directory.path, '/private/auralis-updates');
    await bridge.install(
      File('/private/auralis-updates/update.apk'),
      '0.2.0',
      'a' * 64,
    );
    expect(calls.last.method, 'installUpdate');
    expect(calls.last.arguments['version'], '0.2.0');
    expect(calls.last.arguments['sha256'], 'a' * 64);
  });

  test(
    'Android rejects unreadable encrypted writes before replacing the vault',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'auralis-vault-readback',
      );
      addTearDown(() => dir.delete(recursive: true));
      final vault = AndroidSecretVault(File('${dir.path}/vault.aesgcm'));
      final original = [1, 2, 3, 4];
      await vault.file.writeAsBytes(original);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'decrypt') {
          throw PlatformException(code: 'key_invalidated');
        }
        return Uint8List.fromList([4, 5, 6]);
      });
      await expectLater(
        vault.write({'apiId': 123}),
        throwsA(isA<PlatformException>()),
      );
      expect(await vault.file.readAsBytes(), original);
    },
  );

  test('Android exports use content URIs, preserve Unicode and handle cancellation', () async {
    const files = AndroidDataFiles();
    final calls = <MethodCall>[];
    const uri =
        'content://com.android.providers.downloads.documents/document/1';
    var cancel = false;
    var bytes = Uint8List.fromList(utf8.encode('夜の音楽'));
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'createDocument' || 'openDocument' => cancel ? null : uri,
        'readDocument' => bytes,
        'writeDocument' => null,
        _ => throw StateError('Unexpected bridge call'),
      };
    });
    expect(await files.savePath('stats.csv', 'csv'), uri);
    expect(calls.last.arguments, {'name': 'stats.csv', 'mime': 'text/csv'});
    await files.write(uri, '夜の音楽');
    expect(calls.last.arguments['uri'], uri);
    expect(calls.last.arguments['bytes'], utf8.encode('夜の音楽'));
    expect(await files.openBackup(), uri);
    expect(await files.openLyrics(), uri);
    expect(await files.readBytes(uri, maxBytes: 256 * 1024), bytes);
    expect(calls.last.arguments, {'uri': uri, 'maxBytes': 256 * 1024});
    await expectLater(files.readBytes(uri, maxBytes: 1), throwsFormatException);
    expect(await files.read(uri), '夜の音楽');
    bytes = Uint8List.fromList([0xff]);
    await expectLater(files.read(uri), throwsFormatException);
    cancel = true;
    expect(await files.savePath('backup.json', 'json'), isNull);
    expect(await files.openBackup(), isNull);
    final dir = await Directory.systemTemp.createTemp('auralis-recovery');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/recovery.json';
    await files.write(path, '{"recovery":true}');
    expect(await files.read(path), '{"recovery":true}');
  });

  test(
    'system media controls share the queue, seek tracking and stop behavior',
    () async {
      const a = Track(
        id: '-1:1',
        title: 'First',
        artist: 'Artist',
        source: 'Channel',
        fileId: 1,
        size: 100,
      );
      const b = Track(
        id: '-1:2',
        title: 'Second',
        artist: 'Artist',
        source: 'Channel',
        fileId: 2,
        size: 100,
      );
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      final handler = AndroidAudioHandler(player);
      addTearDown(() async {
        await handler.close();
        await player.shutdown();
      });
      await player.play(a, from: [a, b]);
      expect(handler.mediaItem.value!.id, a.id);
      expect(handler.queue.value.map((item) => item.id), [a.id, b.id]);
      expect(handler.playbackState.value.playing, isTrue);
      audio.duration = const Duration(seconds: 42);
      audio.notifyListeners();
      expect(handler.mediaItem.value!.duration!.inSeconds, 42);
      await handler.pause();
      expect(audio.playing, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play();
      expect(audio.playing, isTrue);
      await handler.seek(const Duration(seconds: 8));
      expect(audio.position.inSeconds, 8);
      expect(handler.playbackState.value.updatePosition.inSeconds, 8);
      await handler.skipToNext();
      expect(player.current, b);
      audio.position = Duration.zero;
      await handler.skipToPrevious();
      expect(player.current, a);
      player.restoringData = true;
      await handler.pause();
      await handler.play();
      expect(audio.playing, isFalse);
      player.restoringData = false;
      await handler.onTaskRemoved();
      expect(player.queue, isEmpty);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    },
  );

  test('system artwork upgrades previews, retries and ignores stale tracks and disposal', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-media-art');
    final preview = File('test/fixtures/cover.png').readAsBytesSync();
    final full = File('test/fixtures/theme-teal.png').readAsBytesSync();
    final a = Track(id: 'a', title: 'First', artist: 'Artist', source: 'Channel', coverPreview: preview);
    const b = Track(id: 'b', title: 'Second', artist: 'Artist', source: 'Channel');
    const c = Track(id: 'c', title: 'No art', artist: 'Artist', source: 'Channel');
    final audio = FakeAudio();
    final player = PlayerController(audio, TelegramStreamProxy((_) async => {}), MemorySettings());
    final changes = ChangeNotifier();
    final pendingA = Completer<Uint8List?>(), pendingB = Completer<Uint8List?>();
    Future<Uint8List?>? nextCover = pendingA.future;
    final handler = AndroidAudioHandler(player,
      artworkDirectory: dir,
      artworkChanges: changes,
      loadArtwork: (_) => nextCover,
    );
    addTearDown(() async {
      await handler.close();
      await player.shutdown();
      changes.dispose();
      await dir.delete(recursive: true);
    });
    Future<MediaItem> withArt(String id, {Uri? differentFrom}) => handler.mediaItem
      .firstWhere((item) => item?.id == id && item?.artUri != null && item?.artUri != differentFrom)
      .then((item) => item!).timeout(const Duration(seconds: 3));

    await player.play(a, from: [a, b, c]);
    final first = await withArt(a.id);
    expect(first.artUri!.scheme, 'file');
    expect(await File.fromUri(first.artUri!).readAsBytes(), preview);
    expect(handler.queue.value.first.artUri, first.artUri);
    pendingA.complete(full);
    final upgraded = await withArt(a.id, differentFrom: first.artUri);
    expect(await File.fromUri(upgraded.artUri!).readAsBytes(), full);
    // Re-publishing duration must retain the cover.
    audio.duration = const Duration(minutes: 3);
    audio.notifyListeners();
    expect(handler.mediaItem.value!.artUri, upgraded.artUri);

    final stale = Completer<Uint8List?>();
    nextCover = stale.future;
    changes.notifyListeners();
    nextCover = pendingB.future;
    await player.playAt(1);
    expect(handler.mediaItem.value!.artUri, isNull, reason: 'Never carry the old cover into a new track');
    stale.complete(preview);
    pendingB.complete(full);
    await withArt(b.id);
    expect(handler.mediaItem.value!.id, b.id);
    expect(await File.fromUri(handler.mediaItem.value!.artUri!).readAsBytes(), full);

    nextCover = null;
    await player.playAt(2);
    expect(handler.mediaItem.value!.artUri, isNull);
    final retry = Completer<Uint8List?>();
    nextCover = retry.future;
    changes.notifyListeners();
    retry.complete(preview);
    await withArt(c.id);
    final lateCover = Completer<Uint8List?>();
    nextCover = lateCover.future;
    changes.notifyListeners();
    final last = handler.mediaItem.value;
    await handler.close();
    lateCover.complete(full);
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value, same(last));
  });

  test(
    'Android builds independently and never require Windows build results',
    () {
      final workflow = loadYaml(
        File('.github/workflows/android.yml').readAsStringSync(),
      ) as YamlMap;
      final jobs = workflow['jobs'] as YamlMap;
      expect(jobs.keys, ['build', 'publish']);
      expect(jobs['build']['needs'], isNull);
      expect(jobs['build']['runs-on'], 'ubuntu-24.04');
      expect(workflow['permissions']['contents'], 'read');
      expect(jobs['publish']['needs'], 'build');
      expect(jobs['publish']['permissions']['contents'], 'write');
      expect(
        jobs['publish']['if'],
        isNot(contains('needs.build.outputs.signed')),
      );
      expect(
        jobs['publish']['env']['SIGNED'],
        r'${{ needs.build.outputs.signed }}',
      );
      expect(
        jobs['publish']['if'],
        contains("github.event_name != 'pull_request'"),
      );
      expect(
        jobs['publish']['concurrency']['group'],
        r'stable-release-${{ github.repository }}',
      );
      final steps = jobs['build']['steps'] as YamlList;
      final sdk = steps.singleWhere((s) => s['name'] == 'Set up Android SDK');
      expect(
        sdk['uses'],
        matches(RegExp(r'^android-actions/setup-android@[0-9a-f]{40}$')),
      );
      expect(sdk['if'], isNull);
      expect(sdk['with']['packages'], 'platform-tools');
      final tools = steps.singleWhere(
        (s) => s['name'] == 'Install Android and host build tools',
      );
      expect(steps.indexOf(sdk), lessThan(steps.indexOf(tools)));
      expect(
        tools['run'],
        contains(
          "sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358'",
        ),
      );
      final build = steps.singleWhere((s) => s['name'] == 'Build Android APK');
      expect(build['run'], contains('flutter build apk'));
      expect(build['run'], contains('android-arm64'));
      // Third-party media libraries include multiple ABIs; only ship the
      // split output matching the requested native TDLib architecture.
      expect(build['run'], contains('--split-per-abi'));
      expect(build['run'], contains('--target-platform "\$target"'));
      expect(build['run'], contains('app-\$ABI-release.apk'));
      expect(build['run'], contains('flutter build apk --release'));
      expect(build['run'], contains('manifest debuggable'));
      expect(build['run'], isNot(contains('mode=debug')));
      expect(build['run'], isNot(contains('app-\$mode.apk"')));
      expect(build['run'], contains('verify-android.py'));
      expect(build['run'], isNot(contains('publish-release')));
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('FOREGROUND_SERVICE_MEDIA_PLAYBACK'));
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, isNot(contains('MANAGE_EXTERNAL_STORAGE')));
    },
  );
}
