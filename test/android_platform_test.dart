import 'dart:convert';
import 'dart:io';

import 'package:auralis/android_audio.dart';
import 'package:auralis/data_files.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/android_storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
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
    expect(calls, ['encrypt', 'decrypt']);
    fail = true;
    await expectLater(
      vault.write({'apiId': 456}),
      throwsA(isA<PlatformException>()),
    );
    expect(await vault.file.readAsBytes(), saved);
    await expectLater(vault.read(), throwsA(isA<PlatformException>()));
  });

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
      expect(jobs['publish']['if'], isNot(contains('needs.build.outputs.signed')));
      expect(jobs['publish']['env']['SIGNED'], r'${{ needs.build.outputs.signed }}');
      expect(jobs['publish']['if'], contains("github.event_name != 'pull_request'"));
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
      expect(build['run'], contains('app-\$ABI-\$mode.apk'));
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
