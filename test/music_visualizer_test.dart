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

void expectCenteredRows(WidgetTester tester, Finder group, Finder children) {
  final center = tester.getRect(group).center.dx;
  final rows = <int, List<Rect>>{};
  for (final element in children.evaluate()) {
    final rect = tester.getRect(
      find.byElementPredicate((candidate) => identical(candidate, element)),
    );
    rows.putIfAbsent(rect.top.round(), () => []).add(rect);
  }
  expect(rows, isNotEmpty);
  for (final row in rows.values) {
    final bounds = row.reduce((a, b) => a.expandToInclude(b));
    expect(
      bounds.center.dx,
      closeTo(center, .5),
      reason: 'Every wrapped row must remain centered in the panel.',
    );
  }
}

class ReadyVisualizer extends StatefulWidget {
  const ReadyVisualizer(this.onMessage, {super.key});
  final ValueChanged<Map<String, dynamic>> onMessage;
  @override
  State<ReadyVisualizer> createState() => _ReadyVisualizerState();
}

class _ReadyVisualizerState extends State<ReadyVisualizer> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onMessage({
          'type': 'ready',
          'presets': ['A', 'B'],
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

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
        ..songMotion = false
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
      expect(invalid.songMotion, isTrue);
      expect(MusicVisualizerSettings.fromJson({}).songMotion, isTrue);
      expect(
        MusicVisualizerSettings.fromJson({'songMotion': false}).songMotion,
        isFalse,
      );
    },
  );

  testWidgets(
    'song-driven motion is automatic, reversible and preserves preset choices',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      addTearDown(player.shutdown);
      final scripts = <String>[];
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicVisualizerPane(
              player: player,
              mode: MusicPanel.visualizer,
              fullscreen: false,
              onFullscreen: () {},
              webController: MusicVisualizerWebController(
                runScript: (script) async => scripts.add(script),
              ),
              rendererBuilder: (message, _) => ReadyVisualizer(message),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Expand visualizer'), findsNothing);
      expect(scripts.last, contains('"songMotion":true'));
      await tester.tap(find.byTooltip('Visualizer settings'));
      await tester.pumpAndSettle();
      expect(find.text('Cycle presets'), findsOneWidget);
      expect(find.text('Choose preset'), findsOneWidget);
      await tester.tap(find.text('Song-driven motion'));
      await tester.pumpAndSettle();
      expect(player.settings.musicVisualizer.songMotion, isFalse);
      expect(scripts.last, contains('"songMotion":false'));
      await tester.tap(find.text('Song-driven motion'));
      await tester.pumpAndSettle();
      expect(player.settings.musicVisualizer.songMotion, isTrue);
      expect(scripts.last, contains('"songMotion":true'));
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Previous preset'), findsOneWidget);
      expect(find.byTooltip('Random preset'), findsOneWidget);
      expect(find.byTooltip('Next preset'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
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
    'capture skips native reads while the renderer is backpressured',
    (tester) async {
      var available = false, reads = 0, frames = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') {
          reads++;
          return {'samples': Uint8List(1024), 'rate': 44100};
        }
        return null;
      });
      final capture = MusicVisualizerCapture(
        canRead: () => available,
        onFrame: (_, _) => frames++,
        onError: (_) => fail('No capture error expected'),
      );
      capture.setActive(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reads, 0);
      available = true;
      await tester.pump(const Duration(milliseconds: 20));
      expect(reads, 1);
      expect(frames, 1);
      available = false;
      await tester.pump(const Duration(milliseconds: 200));
      expect(reads, 1);
      await capture.dispose();
    },
  );

  testWidgets(
    'phone capture stays below 30 Hz at 60 FPS and reuses the renderer on ticks',
    (tester) async {
      final audio = FakeAudio()..playing = true;
      final settings = MemorySettings()..musicVisualizer.fps = 60;
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      addTearDown(player.shutdown);
      var reads = 0, builds = 0, feeds = 0;
      final scripts = <String>[];
      Completer<void>? feedGate;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') {
          reads++;
          return {'samples': Uint8List(1024), 'rate': 44100};
        }
        return null;
      });
      final web = MusicVisualizerWebController(
        runScript: (script) async {
          scripts.add(script);
          if (script.contains('.feed(')) {
            feeds++;
            await feedGate?.future;
          }
        },
      );
      Widget renderer(
        ValueChanged<Map<String, dynamic>> message,
        ValueChanged<String> _,
      ) {
        builds++;
        return ReadyVisualizer(message);
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: player,
              builder: (_, _) => MusicVisualizerPane(
                player: player,
                mode: MusicPanel.visualizer,
                fullscreen: false,
                onFullscreen: () {},
                webController: web,
                rendererBuilder: renderer,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(builds, 1);
      expect(scripts.first, contains('"fps":60'));
      expect(scripts.first, contains('"mobile":true'));
      for (var i = 0; i < 100; i++) {
        audio.position = Duration(milliseconds: i * 10);
        player.notifyListeners();
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(reads, 29);
      expect(feeds, reads);
      expect(
        builds,
        1,
        reason: 'Playback position must not recreate the WebView.',
      );
      expect(
        scripts.where((value) => value.contains('.configure(')),
        hasLength(1),
      );
      feedGate = Completer<void>();
      await tester.pump(const Duration(milliseconds: 40));
      final blockedReads = reads;
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        reads,
        blockedReads,
        reason: 'Do not read samples a busy renderer cannot consume.',
      );
      feedGate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(reads, blockedReads + 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden Lyrics stays frozen across playback ticks and retains manual reading position',
    (tester) async {
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
        ..save(
          song,
          Lyrics.parse(
            List.generate(
              80,
              (i) =>
                  '[${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}]Line $i',
            ).join('\n'),
          ),
        );
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      Widget renderer(
        ValueChanged<Map<String, dynamic>> message,
        ValueChanged<String> _,
      ) => ReadyVisualizer(message);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: player,
              builder: (_, _) => LyricsView(
                player: player,
                repository: repository,
                artwork: const Icon(Icons.album),
                onBack: () {},
                visualizerRendererBuilder: renderer,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('synced-lyrics'));
      await tester.drag(list, const Offset(0, -250));
      await tester.pumpAndSettle();
      final controller = tester.widget<ListView>(list).controller!;
      final offset = controller.offset;
      expect(offset, greaterThan(150));
      await tester.tap(find.byKey(const ValueKey('music-panel-spectrum')));
      await tester.pumpAndSettle();
      final hidden = find.byKey(
        const ValueKey('synced-lyrics'),
        skipOffstage: false,
      );
      final frozen = tester.widget<ListView>(hidden);
      for (var i = 1; i <= 10; i++) {
        audio.position = Duration(seconds: i * 4);
        player.notifyListeners();
        await tester.pump(const Duration(milliseconds: 40));
        expect(tester.widget<ListView>(hidden), same(frozen));
        expect(controller.offset, closeTo(offset, .1));
      }
      await tester.tap(find.byKey(const ValueKey('music-panel-lyrics')));
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(list).controller, same(controller));
      expect(controller.offset, closeTo(offset, .1));
      expect(player.current, same(song));
      expect(audio.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'automatic start respects denied permission and retries only on request',
    (tester) async {
      final audio = FakeAudio()..playing = true;
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      addTearDown(player.shutdown);
      var starts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start' && ++starts == 1) {
          throw PlatformException(
            code: 'permission',
            message: 'Permission denied',
          );
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicVisualizerPane(
              player: player,
              mode: MusicPanel.spectrum,
              fullscreen: false,
              onFullscreen: () {},
              rendererBuilder: (message, _) => ReadyVisualizer(message),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(starts, 1);
      expect(find.text('Enable visualizer'), findsNothing);
      expect(find.text('Permission denied'), findsOneWidget);
      expect(find.text('Retry visualizer'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(
        starts,
        1,
        reason: 'Do not repeatedly request a denied system permission.',
      );
      expect(audio.playing, isTrue);
      await tester.tap(find.text('Retry visualizer'));
      await tester.pumpAndSettle();
      expect(starts, 2);
      expect(find.text('Permission denied'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic visualizers wait for playback and buffering to finish',
    (tester) async {
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      addTearDown(player.shutdown);
      var starts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') starts++;
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicVisualizerPane(
              player: player,
              mode: MusicPanel.visualizer,
              fullscreen: false,
              onFullscreen: () {},
              rendererBuilder: (message, _) => ReadyVisualizer(message),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(starts, 0);
      expect(find.text('Paused'), findsOneWidget);
      audio
        ..playing = true
        ..buffering = true;
      player.notifyListeners();
      await tester.pump();
      expect(starts, 0);
      audio.buffering = false;
      player.notifyListeners();
      await tester.pump();
      expect(starts, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'Lyrics remains the default; selecting a visualizer starts automatically and returning stops it at $size',
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
                visualizerRendererBuilder: (message, _) =>
                    ReadyVisualizer(message),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Original words'), findsOneWidget);
        final selector = find.byKey(const ValueKey('music-panel-selector'));
        expectCenteredRows(
          tester,
          selector,
          find.descendant(of: selector, matching: find.byType(ChoiceChip)),
        );
        expect(find.byType(MusicVisualizerWebView), findsNothing);
        expect(calls.where((call) => call == 'start'), isEmpty);
        for (final mode in ['spectrum', 'visualizer']) {
          final starts = calls.where((call) => call == 'start').length;
          await tester.tap(find.byKey(ValueKey('music-panel-$mode')));
          await tester.pumpAndSettle();
          expect(find.text('Enable visualizer'), findsNothing);
          expect(find.byType(ReadyVisualizer), findsOneWidget);
          expect(calls.where((call) => call == 'start').length, starts + 1);
          await tester.tap(find.byKey(const ValueKey('music-panel-lyrics')));
          await tester.pumpAndSettle();
          expect(find.text('Original words'), findsOneWidget);
          expect(calls.last, 'stop');
        }
        expect(player.current, same(song));
        expect(audio.playing, isTrue);
        expect(repository.cached(song)!.plain, 'Original words');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final mode in [MusicPanel.spectrum, MusicPanel.visualizer]) {
    testWidgets(
      'Windows $mode keeps sampling behind another app but stops when minimized',
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
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: MusicVisualizerPane(
                player: player,
                mode: mode,
                fullscreen: false,
                onFullscreen: () {},
                webController: MusicVisualizerWebController(
                  runScript: (script) async => scripts.add(script),
                ),
                rendererBuilder: (message, _) => ReadyVisualizer(message),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(calls.where((call) => call == 'start'), hasLength(1));
        final initialStops = calls.where((call) => call == 'stop').length;
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
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(milliseconds: 40));
        final reads = calls.where((call) => call == 'read').length;
        expect(reads, greaterThan(0));
        expect(scripts.last, contains('.feed('));
        expect(calls.where((call) => call == 'stop'), hasLength(initialStops));
        // Minimize the front app: Auralis regains focus without restarting capture.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        focus(true);
        await tester.pump(const Duration(milliseconds: 40));
        expect(calls.where((call) => call == 'start'), hasLength(1));
        expect(
          calls.where((call) => call == 'read').length,
          greaterThan(reads),
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(calls.last, 'stop');
        final hiddenReads = calls.where((call) => call == 'read').length;
        await tester.pump(const Duration(milliseconds: 200));
        expect(calls.where((call) => call == 'read'), hasLength(hiddenReads));
        // Restore Auralis while still unfocused: visible Windows animation resumes.
        focus(false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(calls.last, 'start');
        unawaited(
          showDialog<void>(
            context: navigator.currentContext!,
            builder: (_) => const AlertDialog(title: Text('In-app dialog')),
          ),
        );
        await tester.pump();
        expect(calls.last, 'stop');
        navigator.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(calls.last, 'start');
        audio.playing = false;
        player.notifyListeners();
        await tester.pump();
        expect(calls.last, 'stop');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        focus(true);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Android visualizers stop for pause, background, focus, dialogs and reduced motion',
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
      await tester.pump();
      await tester.pump();
      expect(find.text('Enable visualizer'), findsNothing);
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
    'desktop expansion works; renderer failures stop capture and allow retry',
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
          theme: ThemeData(platform: TargetPlatform.windows),
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
      await tester.pump();
      await tester.pump();
      final starts = calls.where((call) => call == 'start').length;
      expect(starts, 1);
      void checkPanelLayout() {
        final controls = find.byKey(
          const ValueKey('music-visualizer-controls'),
        );
        expectCenteredRows(
          tester,
          controls,
          find.descendant(of: controls, matching: find.byType(IconButton)),
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('music-visualizer-surface')))
              .width,
          closeTo(tester.getSize(find.byType(MusicVisualizerPane)).width, .5),
        );
      }

      checkPanelLayout();
      await tester.tap(find.byTooltip('Expand visualizer'));
      await tester.pump();
      expect(expanded, isTrue);
      expect(find.byTooltip('Exit expanded visualizer'), findsOneWidget);
      update(() => mode = MusicPanel.visualizer);
      await tester.pump();
      expect(find.text('Enable visualizer'), findsNothing);
      expect(scripts.last, contains('"mode":"visualizer"'));
      checkPanelLayout();
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

  test('Windows native capture stops on minimize/hide, not application deactivation', () {
    final host = File('windows/runner/flutter_window.cpp').readAsStringSync();
    expect(host, isNot(contains('message == WM_ACTIVATEAPP')));
    expect(host, contains('message == WM_SIZE && wparam == SIZE_MINIMIZED'));
    expect(host, contains('message == WM_SHOWWINDOW && !wparam'));
    expect(host, contains('music_visualizer_->Stop()'));
  });

  test('bundled renderers are offline, licensed and do not open microphone or media sources', () {
    final html = File('assets/visualizer/index.html').readAsStringSync();
    final bridge = File('assets/visualizer/bridge.js').readAsStringSync();
    expect(html, contains("connect-src 'none'"));
    expect(
      html,
      matches(
        RegExp(r'#spectrum canvas\s*\{[^}]*width:\s*100%[^}]*height:\s*100%'),
      ),
    );
    expect(bridge, contains('timeByteArray:waveform'));
    expect(bridge, contains('analyzer._analyzer'));
    expect(bridge, contains('loRes:options.mobile'));
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
    expect(
      android,
      contains('setScalingMode(Visualizer.SCALING_MODE_AS_PLAYED)'),
    );
    expect(
      android,
      isNot(contains('setScalingMode(Visualizer.SCALING_MODE_NORMALIZED)')),
    );
    expect(android, isNot(contains('AudioRecord(')));
    final windows = File('windows/runner/music_visualizer.cpp')
        .readAsStringSync();
    expect(windows, contains('AUDCLNT_STREAMFLAGS_LOOPBACK'));
    expect(windows, isNot(contains('eCapture')));
  });
}
