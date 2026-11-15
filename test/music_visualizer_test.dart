import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_view.dart';
import 'package:auralis/models.dart';
import 'package:auralis/music_visualizer.dart';
import 'package:auralis/music_visualizer_capture.dart';
import 'package:auralis/music_visualizer_data.dart';
import 'package:auralis/music_visualizer_webview.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const channel = MethodChannel('app.auralis/visualizer');
const song = Track(
  id: 'one',
  title: 'Original song',
  artist: 'Original artist',
  source: 'Music',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'visualizer preferences are bounded, device-local and survive restarts',
    () async {
      final dir = await Directory.systemTemp.createTemp('auralis-visuals-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final settings = AppSettings(file);
      settings.musicVisualizer
        ..spectrum = 'radial'
        ..palette = 'classic'
        ..fps = 20
        ..preset = 'Preset A'
        ..cycleSeconds = 60
        ..cycle = false;
      expect(settings.toJson().containsKey('_musicVisualizer'), isFalse);
      await settings.save();
      final restored = AppSettings(file);
      await restored.load();
      expect(
        restored.musicVisualizer.toJson(),
        settings.musicVisualizer.toJson(),
      );
      restored.applyJson(settings.toJson()..['librarySort'] = 'oldest');
      expect(restored.musicVisualizer.preset, 'Preset A');
      final invalid = MusicVisualizerSettings.fromJson({
        'fps': 1000,
        'cycleSeconds': -1,
        'spectrum': 'unknown',
        'palette': 'unknown',
        'preset': List.filled(301, 'x').join(),
      });
      expect(invalid.fps, 30);
      expect(invalid.cycleSeconds, 30);
      expect(invalid.spectrum, 'line');
      expect(invalid.preset, isEmpty);
    },
  );

  testWidgets(
    'capture serializes permission, stop and disposal without background reads',
    (tester) async {
      final start = Completer<void>();
      final calls = <String>[], errors = <String>[];
      var frames = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'start') await start.future;
        if (call.method == 'read') {
          return {'samples': Uint8List(1024), 'rate': 44100};
        }
        return null;
      });
      final capture = MusicVisualizerCapture(
        onFrame: (_, _) => frames++,
        onError: errors.add,
      );
      capture.setActive(true);
      await tester.pump();
      expect(calls, ['stop', 'start']);
      capture.setActive(false);
      final disposed = capture.dispose();
      start.complete();
      await tester.pump();
      await disposed;
      await tester.pump(const Duration(seconds: 1));
      expect(calls.where((name) => name == 'read'), isEmpty);
      expect(calls.last, 'stop');
      expect(frames, 0);
      expect(errors, isEmpty);
    },
  );

  testWidgets('sample reads never overlap and stale frames are discarded', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    var reads = 0, frames = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') {
        reads++;
        return gate.future;
      }
      return null;
    });
    final capture = MusicVisualizerCapture(
      onFrame: (_, _) => frames++,
      onError: (_) => fail('No error expected'),
    );
    capture.setActive(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(reads, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(reads, 1);
    capture.setActive(false);
    gate.complete({'samples': Uint8List(1024), 'rate': 44100});
    await tester.pump();
    expect(frames, 0);
    await capture.dispose();
  });

  testWidgets(
    'denied output permission keeps playback running and can be retried',
    (tester) async {
      final errors = <String>[];
      var attempts = 0, frames = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start' && ++attempts == 1) {
          throw PlatformException(
            code: 'permission',
            message: 'Permission denied',
          );
        }
        if (call.method == 'read') {
          return {'samples': Uint8List(1024), 'rate': 48000};
        }
        return null;
      });
      final capture = MusicVisualizerCapture(
        onFrame: (_, _) => frames++,
        onError: errors.add,
      );
      capture.setActive(true);
      await tester.pump();
      expect(errors, ['Permission denied']);
      capture.setActive(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(attempts, 2);
      expect(frames, 1);
      await capture.dispose();
    },
  );

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'Lyrics remains the default, switches back intact, and never captures without consent at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final audio = FakeAudio()..playing = true;
        final settings = MemorySettings()
          ..automaticTranslation = false
          ..automaticLyrics = false;
        final player =
            PlayerController(
                audio,
                TelegramStreamProxy((_) async => {}),
                settings,
              )
              ..queue.add(song)
              ..index = 0;
        final repository = LyricsRepository()
          ..save(song, Lyrics.parse('[00:00]Original words'));
        addTearDown(player.shutdown);
        addTearDown(repository.close);
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LyricsView(
                player: player,
                repository: repository,
                artwork: const Icon(Icons.album),
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Original words'), findsOneWidget);
        expect(find.byType(MusicVisualizerWebView), findsNothing);
        for (final mode in ['spectrum', 'visualizer']) {
          await tester.tap(find.byKey(ValueKey('music-panel-$mode')));
          await tester.pumpAndSettle();
          expect(find.text('Enable visualizer'), findsOneWidget);
          expect(find.byType(MusicVisualizerWebView), findsNothing);
          expect(calls.where((call) => call == 'start'), isEmpty);
          await tester.tap(find.byKey(const ValueKey('music-panel-lyrics')));
          await tester.pumpAndSettle();
          expect(find.text('Original words'), findsOneWidget);
        }
        expect(player.current, same(song));
        expect(audio.playing, isTrue);
        expect(repository.cached(song)!.plain, 'Original words');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'enabled visualizers stop for pause, background, focus, dialogs and reduced motion',
    (tester) async {
      final audio = FakeAudio()..playing = true;
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      addTearDown(player.shutdown);
      final calls = <String>[], scripts = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'read') {
          return {'samples': Uint8List(1024), 'rate': 44100};
        }
        return null;
      });
      var rendererReady = false;
      var reduced = false;
      late StateSetter update;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: Scaffold(
                  body: MusicVisualizerPane(
                    player: player,
                    mode: MusicPanel.spectrum,
                    fullscreen: false,
                    onFullscreen: () {},
                    webController: MusicVisualizerWebController(
                      runScript: (script) async => scripts.add(script),
                    ),
                    rendererBuilder: (message, _) {
                      if (!rendererReady) {
                        rendererReady = true;
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => message({
                            'type': 'ready',
                            'presets': ['A', 'B'],
                          }),
                        );
                      }
                      return const SizedBox();
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((call) => call == 'start'), isEmpty);
      await tester.tap(find.text('Enable visualizer'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(calls, contains('start'));
      expect(scripts.any((script) => script.contains('.feed(')), isTrue);
      audio.playing = false;
      player.notifyListeners();
      await tester.pump();
      expect(calls.last, 'stop');
      audio.playing = true;
      player.notifyListeners();
      await tester.pump();
      expect(calls.last, 'start');
      audio.buffering = true;
      player.notifyListeners();
      await tester.pump();
      expect(calls.last, 'stop');
      audio.buffering = false;
      player.notifyListeners();
      await tester.pump();
      expect(calls.last, 'start');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(calls.last, 'stop');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.last, 'start');
      void focus(bool focused) => tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: focused
              ? ui.ViewFocusState.focused
              : ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      focus(false);
      await tester.pump();
      expect(calls.last, 'stop');
      focus(true);
      await tester.pump();
      expect(calls.last, 'start');
      unawaited(
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (_) => const AlertDialog(title: Text('Covered')),
        ),
      );
      await tester.pump();
      expect(calls.last, 'stop');
      navigator.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(calls.last, 'start');
      update(() => reduced = true);
      await tester.pump();
      expect(calls.last, 'stop');
      expect(find.textContaining('reduced-motion'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last, 'stop');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mode changes and expansion retain consent; renderer failures stop capture and allow retry',
    (tester) async {
      final audio = FakeAudio()..playing = true;
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      addTearDown(player.shutdown);
      final calls = <String>[], scripts = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      final web = MusicVisualizerWebController(
        runScript: (script) async => scripts.add(script),
      );
      var mode = MusicPanel.spectrum, expanded = false, hidden = false;
      var announceReady = true;
      late StateSetter update;
      late ValueChanged<String> failRenderer;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: TickerMode(
                  enabled: !hidden,
                  child: MusicVisualizerPane(
                    player: player,
                    mode: mode,
                    fullscreen: expanded,
                    onFullscreen: () => update(() => expanded = !expanded),
                    webController: web,
                    rendererBuilder: (message, error) {
                      failRenderer = error;
                      if (announceReady) {
                        announceReady = false;
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => message({
                            'type': 'ready',
                            'presets': ['A', 'B'],
                          }),
                        );
                      }
                      return const SizedBox();
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Enable visualizer'));
      await tester.pump();
      await tester.pump();
      final starts = calls.where((call) => call == 'start').length;
      expect(starts, 1);
      await tester.tap(find.byTooltip('Expand visualizer'));
      await tester.pump();
      expect(expanded, isTrue);
      expect(find.byTooltip('Exit expanded visualizer'), findsOneWidget);
      update(() => mode = MusicPanel.visualizer);
      await tester.pump();
      expect(find.text('Enable visualizer'), findsNothing);
      expect(scripts.last, contains('"mode":"visualizer"'));
      expect(calls.where((call) => call == 'start').length, starts);
      await tester.tap(find.byTooltip('Next preset'));
      await tester.pump();
      expect(scripts.last, contains('.step(1)'));
      update(() => hidden = true);
      await tester.pump();
      expect(calls.last, 'stop');
      update(() => hidden = false);
      await tester.pump();
      expect(calls.last, 'start');
      failRenderer('Synthetic GPU failure');
      await tester.pump();
      expect(calls.last, 'stop');
      expect(find.text('Synthetic GPU failure'), findsOneWidget);
      expect(audio.playing, isTrue);
      announceReady = true;
      await tester.tap(find.text('Retry visualizer'));
      await tester.pump();
      await tester.pump();
      expect(calls.last, 'start');
      expect(find.text('Synthetic GPU failure'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last, 'stop');
      expect(tester.takeException(), isNull);
    },
  );

  test('Windows PCM locals do not collide with SDK RPC macros', () {
    final windows = File('windows/runner/music_visualizer.cpp')
        .readAsStringSync();
    // Windows RPC headers define small as char, including through WASAPI.
    // Source validation also runs on hosts without MSVC or the Windows SDK.
    final collisions = RegExp(
      r'\b(?:int16_t|int32_t|float|double)\s+(?:small|near|far|interface)\b',
    ).allMatches(windows).map((match) => match.group(0)).toList();
    expect(
      collisions,
      isEmpty,
      reason: 'Local PCM identifiers must not expand into Windows SDK macros.',
    );
  });

  test('bundled renderers are offline, licensed and do not open microphone or media sources', () {
    final html = File('assets/visualizer/index.html').readAsStringSync();
    final bridge = File('assets/visualizer/bridge.js').readAsStringSync();
    expect(html, contains("connect-src 'none'"));
    expect(bridge, contains('timeByteArray:waveform'));
    expect(bridge, contains('analyzer._analyzer'));
    for (final forbidden in [
      'getUserMedia',
      'getDisplayMedia',
      'fetch(',
      'XMLHttpRequest',
      'new Audio(',
    ]) {
      expect(bridge, isNot(contains(forbidden)));
    }
    for (final license in ['butterchurn', 'presets', 'audiomotion']) {
      expect(
        File('assets/visualizer/LICENSE-$license.txt').lengthSync(),
        greaterThan(1000),
      );
    }
    final android = File(
      'android/app/src/main/kotlin/com/auralis/siam/MusicVisualizer.kt',
    ).readAsStringSync();
    expect(android, contains('Visualizer(0)'));
    expect(android, isNot(contains('AudioRecord(')));
    final windows = File('windows/runner/music_visualizer.cpp')
        .readAsStringSync();
    expect(windows, contains('AUDCLNT_STREAMFLAGS_LOOPBACK'));
    expect(windows, isNot(contains('eCapture')));
  });
}
