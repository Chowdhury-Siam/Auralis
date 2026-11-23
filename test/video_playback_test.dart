import 'dart:async';
import 'dart:io';

import 'package:auralis/app_theme.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_playback.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';

import 'fakes.dart';

class _TestPlayerCore extends mpv.PlatformPlayer {
  _TestPlayerCore() : super(configuration: const mpv.PlayerConfiguration());

  void opened(bool playing, Duration duration) {
    durationController.add(duration);
    playingController.add(playing);
  }

  void seeked(Duration position) => positionController.add(position);
  void rateChanged(double rate) => rateController.add(rate);
  void bufferingChanged(bool buffering) => bufferingController.add(buffering);
  void decoderWarning() => errorController.add('Recoverable decoder error');
  void completed() {
    playingController.add(false);
    completedController.add(true);
  }

  void tracksChanged(mpv.Tracks tracks) => tracksController.add(tracks);
  void trackChanged(mpv.Track track) => trackController.add(track);
}

class _NativeVideo implements mpv.NativePlayer {
  final _core = _TestPlayerCore();
  final _playbackErrors = StreamController<int>.broadcast();
  @override
  Stream<int> get playbackErrors => _playbackErrors.stream;
  @override
  mpv.PlayerConfiguration get configuration => _core.configuration;
  @override
  mpv.PlayerStream get stream => _core.stream;
  @override
  mpv.PlayerState get state => _core.state;
  @override
  set state(mpv.PlayerState value) => _core.state = value;

  final opened = <mpv.Media>[];
  mpv.Tracks availableTracks = mpv.Tracks(
    audio: [
      mpv.AudioTrack.auto(),
      mpv.AudioTrack.no(),
      const mpv.AudioTrack('3', 'English audio', 'en', isDefault: true),
      const mpv.AudioTrack('1', 'Japanese audio', 'ja'),
    ],
    subtitle: [
      mpv.SubtitleTrack.auto(),
      mpv.SubtitleTrack.no(),
      const mpv.SubtitleTrack('4', 'French subtitles', 'fr', isDefault: true),
      const mpv.SubtitleTrack('2', 'English subtitles', 'en'),
    ],
  );
  final audioSelections = <String>[];
  final subtitleSelections = <String>[];
  final seeks = <Duration>[];
  Future<void> Function(Duration)? beforeSeek;
  VoidCallback? beforeStop;
  Future<void> Function()? beforeDispose;
  bool warnOnOpen = false;
  final properties = <String, String>{
    'chapter-list/count': '2',
    'chapter-list/0/time': '0',
    'chapter-list/0/title': 'Opening',
    'chapter-list/1/time': '45',
    'chapter-list/1/title': 'Part two',
  };

  @override
  Future<void> open(
    mpv.Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    final media = playable as mpv.Media;
    opened.add(media);
    const duration = Duration(minutes: 2);
    state = state.copyWith(
      playing: play,
      completed: false,
      position: media.start ?? Duration.zero,
      duration: duration,
      tracks: availableTracks,
    );
    _core.opened(play, duration);
    _core.tracksChanged(availableTracks);
    if (warnOnOpen) warn();
  }

  void warn() => _core.decoderWarning();

  void abortPlayback() {
    state = state.copyWith(playing: false);
    _playbackErrors.add(-13);
  }

  void publishTracks(mpv.Tracks tracks) {
    state = state.copyWith(tracks: tracks);
    _core.tracksChanged(tracks);
  }

  @override
  Future<void> setAudioTrack(
    mpv.AudioTrack track, {
    bool synchronized = true,
  }) async {
    audioSelections.add(track.id);
    state = state.copyWith(track: state.track.copyWith(audio: track));
    _core.trackChanged(state.track);
  }

  @override
  Future<void> setSubtitleTrack(
    mpv.SubtitleTrack track, {
    bool synchronized = true,
  }) async {
    subtitleSelections.add(track.id);
    state = state.copyWith(track: state.track.copyWith(subtitle: track));
    _core.trackChanged(state.track);
  }

  @override
  Future<void> seek(Duration duration, {bool synchronized = true}) async {
    seeks.add(duration);
    await beforeSeek?.call(duration);
    state = state.copyWith(position: duration);
    _core.seeked(duration);
  }

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {
    state = state.copyWith(rate: rate);
    _core.rateChanged(rate);
  }

  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) async {
    state = state.copyWith(volume: volume);
  }

  void setBuffering(bool buffering) {
    state = state.copyWith(buffering: buffering);
    _core.bufferingChanged(buffering);
  }

  @override
  Future<void> playOrPause({
    bool notify = true,
    bool synchronized = true,
  }) async {
    state = state.copyWith(playing: !state.playing);
    _core.opened(state.playing, state.duration);
  }

  @override
  Future<void> play({bool synchronized = true}) async {
    state = state.copyWith(playing: true, completed: false);
    _core.opened(true, state.duration);
  }

  @override
  Future<void> pause({bool synchronized = true}) async {
    state = state.copyWith(playing: false);
    _core.opened(false, state.duration);
  }

  void complete() {
    state = state.copyWith(playing: false, completed: true);
    _core.completed();
  }

  @override
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) async {
    beforeStop?.call();
    state = const mpv.PlayerState();
    _core.opened(false, Duration.zero);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    await beforeDispose?.call();
    await _playbackErrors.close();
    await _core.dispose();
  }

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => properties[property] ?? '';

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    properties[property] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingVideoProxy extends TelegramStreamProxy {
  _RecordingVideoProxy() : super((_) async => {});

  final preloads = <(int?, Duration?)>[];

  @override
  Future<void> preload(Track? track, {Duration? duration}) {
    if (track != null) preloads.add((track.fileId, duration));
    return super.preload(track, duration: duration);
  }

  @override
  Future<Uri> uri(Track track) async =>
      Uri.parse('http://127.0.0.1/video/${track.fileId}');

  VoidCallback? onStop;
  int interruptions = 0;

  @override
  Future<void> interrupt() {
    interruptions++;
    return super.interrupt();
  }

  @override
  Future<void> stop() {
    onStop?.call();
    return super.stop();
  }
}

class _TestSurface extends PlatformVideoController {
  _TestSurface(mpv.Player player)
    : super(player, const VideoControllerConfiguration());

  @override
  Future<void> setSize({int? width, int? height}) async {}
}

class _VideoController implements VideoController {
  _VideoController(_NativeVideo native)
    : player = mpv.Player(platformPlayer: native) {
    platform.complete(_TestSurface(player));
  }

  @override
  final mpv.Player player;
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SkipVideoFixture {
  _SkipVideoFixture({Directory? telegramDirectory})
    : telegram = TelegramService(
        telegramDirectory ?? Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );

  final native = _NativeVideo();
  late final controller = _VideoController(native);
  final direction = ValueNotifier(TextDirection.ltr);
  final settings = MemorySettings();
  final proxy = _RecordingVideoProxy();
  final source = VideoSource.file(
    Uri.file('/movies/segments.mp4'),
    'Segment video',
  );
  late final music = PlayerController(
    FakeAudio(),
    TelegramStreamProxy((_) async => {}),
    settings,
  );
  final TelegramService telegram;

  Future<void> mount(
    WidgetTester tester, {
    VideoSource? videoSource,
    List<VideoSource> next = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder(
          valueListenable: direction,
          builder: (context, value, _) =>
              Directionality(textDirection: value, child: child!),
        ),
        home: VideoPlayback(
          sources: [videoSource ?? source, ...next],
          initialIndex: 0,
          telegram: telegram,
          music: music,
          proxy: proxy,
          onOpened: (_) {},
          createController: () => controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var finished = false;
    unawaited(music.shutdown().then((_) => finished = true));
    for (var frame = 0; frame < 30 && !finished; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(finished, isTrue);
    await proxy.close();
    await telegram.shutdown();
    direction.dispose();
  }
}

void main() {
  testWidgets('tap speed toggles 2× and 1× while holding opens the picker', (
    tester,
  ) async {
    final fixture = _SkipVideoFixture();
    try {
      await fixture.mount(tester);
      final speedButton = find.byTooltip('Playback speed');
      final twoTimes = find.widgetWithText(ChoiceChip, '2×');

      await tester.tap(speedButton);
      await tester.pumpAndSettle();
      expect(fixture.native.state.rate, 2);
      expect(twoTimes, findsNothing);

      await tester.tap(speedButton);
      await tester.pumpAndSettle();
      expect(fixture.native.state.rate, 1);
      expect(twoTimes, findsNothing);

      await tester.longPress(speedButton);
      await tester.pumpAndSettle();
      expect(fixture.native.state.rate, 1);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1×'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '1.5×'));
      await tester.pumpAndSettle();
      expect(fixture.native.state.rate, 1.5);

      await tester.tap(speedButton);
      await tester.pumpAndSettle();
      expect(fixture.native.state.rate, 2);
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets(
    'stable video playback preloads only the immediate next episode',
    (tester) async {
      final fixture = _SkipVideoFixture();
      fixture.telegram.state = 'authorizationStateReady';
      VideoSource episode(int n) => VideoSource.telegram(
        Track(
          id: '-100:$n',
          title: 'Episode $n',
          artist: '',
          source: 'Test channel',
          fileId: n + 30,
          size: 16000000,
          duration: const Duration(minutes: 2),
        ),
      );
      try {
        await fixture.mount(
          tester,
          videoSource: episode(1),
          next: [episode(2), episode(3)],
        );
        expect(fixture.proxy.preloads, isEmpty);
        await fixture.native.seek(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        await fixture.native.seek(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(fixture.proxy.preloads, [(32, const Duration(minutes: 2))]);
        await tester.tap(find.byTooltip('Next video'));
        await tester.pumpAndSettle();
        expect(fixture.native.opened.last.uri, 'http://127.0.0.1/video/32');
        await fixture.native.seek(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(fixture.proxy.preloads.last, (33, const Duration(minutes: 2)));
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'saved videos reopen offline with their original resume position',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('auralis-offline-video-'),
      ))!;
      final fixture = _SkipVideoFixture(telegramDirectory: root);
      const source = VideoSource.telegram(
        Track(
          id: '-100:22',
          title: 'Offline episode',
          artist: '',
          source: 'Test channel',
          size: 4,
          duration: Duration(minutes: 2),
        ),
      );
      final uri = (await tester.runAsync(() async {
        final file = await File('${root.path}/source.mp4')
            .writeAsBytes([1, 2, 3, 4]);
        await fixture.telegram.offline.save(
          source.telegram!,
          video: true,
          download: (copy) => copy(file),
        );
        return fixture.telegram.offline.availableUri(
          source.telegram!.id,
          video: true,
        );
      }))!;
      const position = Duration(seconds: 30);
      fixture.settings.videoPlayback.remember(
        source.id,
        position,
        source.duration,
      );
      try {
        await fixture.mount(tester, videoSource: source);
        expect(fixture.telegram.ready, isFalse);
        expect(fixture.native.opened.single.uri, uri.toString());
        expect(fixture.native.opened.single.start, position);
        expect(fixture.native.state.playing, isTrue);
      } finally {
        await fixture.close(tester);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'foreground recovery reopens a stalled Telegram video at its last position',
    (tester) async {
      final fixture = _SkipVideoFixture();
      fixture.telegram.state = 'authorizationStateReady';
      final source = VideoSource.telegram(
        const Track(
          id: '-100:1',
          title: 'Episode one',
          artist: '',
          source: 'Test channel',
          mime: 'video/mp4',
          fileId: 21,
          size: 4096,
          duration: Duration(minutes: 2),
        ),
      );
      const position = Duration(seconds: 26);
      try {
        await fixture.mount(tester, videoSource: source);
        await fixture.native.seek(position);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(fixture.native.state.playing, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(fixture.native.state.playing, isTrue);
        fixture.native.setBuffering(true);
        await tester.pump(const Duration(seconds: 12));
        await tester.pumpAndSettle();
        expect(fixture.proxy.interruptions, 1);
        expect(fixture.native.opened, hasLength(2));
        expect(fixture.native.opened.last.start, position);
        expect(fixture.native.state.playing, isTrue);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets('85 percent marks watched and reopening uses the last position', (
    tester,
  ) async {
    final fixture = _SkipVideoFixture();
    final source = fixture.source;
    final data = fixture.settings.videoPlayback;
    try {
      await fixture.mount(tester);
      await fixture.native.seek(
        const Duration(seconds: 101, milliseconds: 999),
      );
      await tester.pump();
      expect(data.isWatched(source), isFalse);
      await fixture.native.seek(const Duration(seconds: 102));
      await tester.pump();
      expect(data.isWatched(source), isTrue);
      expect(data.positions[source.id], const Duration(seconds: 102));
      data.setWatched(source, false);
      expect(data.positions[source.id], const Duration(seconds: 102));
      data.setWatched(source, true);
      await fixture.native.seek(const Duration(seconds: 108));
      await tester.pump();
    } finally {
      await fixture.close(tester);
    }

    final reopened = _SkipVideoFixture();
    reopened.settings.videoPlayback = VideoPlaybackData.fromJson(data.toJson());
    try {
      await reopened.mount(tester, videoSource: source);
      expect(reopened.settings.videoPlayback.isWatched(source), isTrue);
      expect(reopened.native.opened.single.start, const Duration(seconds: 108));
    } finally {
      await reopened.close(tester);
    }
  });

  testWidgets('backgrounding preserves a manual pause', (tester) async {
    final fixture = _SkipVideoFixture();
    try {
      await fixture.mount(tester);
      await fixture.native.pause();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 13));
      expect(fixture.native.state.playing, isFalse);
      expect(fixture.native.opened, hasLength(1));
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets(
    'video progress rebuilds only the live timeline, preserving controls',
    (tester) async {
      final fixture = _SkipVideoFixture();
      try {
        await fixture.mount(tester);
        await fixture.native.seek(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        final top = tester.widget(
          find.byKey(const ValueKey('video-top-controls')),
        );
        final pause = tester.widget(find.byTooltip('Pause video'));
        for (var second = 2; second <= 12; second++) {
          await fixture.native.seek(Duration(seconds: second));
          await tester.idle();
          await tester.pump();
          expect(
            tester.widget(find.byKey(const ValueKey('video-top-controls'))),
            same(top),
          );
          expect(tester.widget(find.byTooltip('Pause video')), same(pause));
          final slider = tester.widget<Slider>(
            find.byKey(const ValueKey('video-seek')),
          );
          expect(slider.value, closeTo(second / 120, .00001));
        }
        expect(
          find.byKey(const ValueKey('video-skip-segment')),
          findsOneWidget,
        );
        await fixture.native.seek(const Duration(seconds: 46));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('video-skip-segment')), findsNothing);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'all surface gestures can be disabled without trapping controls or locked skip',
    (tester) async {
      final fixture = _SkipVideoFixture();
      for (final gesture in VideoGesture.values) {
        fixture.settings.videoPlayback.gestureOptions.setEnabled(
          gesture,
          false,
        );
      }
      try {
        await fixture.mount(tester);
        final surface = tester.widget<GestureDetector>(
          find.byKey(const ValueKey('video-gesture-surface')),
        );
        expect(surface.onDoubleTap, isNull);
        expect(surface.onLongPressStart, isNull);
        expect(surface.onScaleStart, isNull);
        await tester.tapAt(const Offset(640, 300));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Pause video').hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(fixture.native.state.playing, isTrue);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Show controls').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Show controls'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Pause video').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Lock controls'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('video-skip-segment')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Unlock controls'));
        await tester.pumpAndSettle();
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'disabling Space hold retains Space play/pause and custom boost restores speed',
    (tester) async {
      final fixture = _SkipVideoFixture();
      final options = fixture.settings.videoPlayback.gestureOptions;
      options.setEnabled(VideoGesture.spaceHold, false);
      try {
        await fixture.mount(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 900));
        expect(fixture.native.state.rate, 1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(fixture.native.state.playing, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(fixture.native.state.playing, isTrue);
        options.setEnabled(VideoGesture.spaceHold, true);
        options.boostRate = 1.75;
        options.spaceHoldMs = 600;
        await fixture.native.setRate(1.25);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 500));
        expect(fixture.native.state.rate, 1.25);
        await tester.pump(const Duration(milliseconds: 150));
        expect(fixture.native.state.rate, 1.75);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(fixture.native.state.rate, 1.25);
        expect(fixture.native.state.playing, isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 650));
        options.setEnabled(VideoGesture.keyboard, false);
        fixture.native.setBuffering(true);
        await tester.pump();
        fixture.native.setBuffering(false);
        await tester.pumpAndSettle();
        expect(fixture.native.state.rate, 1.25);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final enabled in [
    VideoGesture.seekDoubleTap,
    VideoGesture.pauseDoubleTap,
    VideoGesture.swipeSeek,
    VideoGesture.swipeVolume,
    VideoGesture.holdSpeed,
  ]) {
    testWidgets(
      '${enabled.name} works independently with other surface actions disabled',
      (tester) async {
        final fixture = _SkipVideoFixture();
        final options = fixture.settings.videoPlayback.gestureOptions;
        for (final gesture in VideoGesture.values) {
          options.setEnabled(gesture, gesture == enabled);
        }
        options.boostRate = 1.5;
        try {
          await fixture.mount(tester);
          final surface = tester.widget<GestureDetector>(
            find.byKey(const ValueKey('video-gesture-surface')),
          );
          switch (enabled) {
            case VideoGesture.seekDoubleTap:
            case VideoGesture.pauseDoubleTap:
              final point = Offset(
                enabled == VideoGesture.seekDoubleTap ? 1100 : 640,
                300,
              );
              await tester.tapAt(point);
              await tester.pump(const Duration(milliseconds: 60));
              await tester.tapAt(point);
              await tester.pumpAndSettle();
              expect(
                fixture.native.state.playing,
                enabled == VideoGesture.seekDoubleTap,
              );
              expect(
                fixture.native.seeks.isNotEmpty,
                enabled == VideoGesture.seekDoubleTap,
              );
            case VideoGesture.swipeSeek:
              surface.onScaleStart!(
                ScaleStartDetails(localFocalPoint: const Offset(600, 500)),
              );
              surface.onScaleUpdate!(
                ScaleUpdateDetails(
                  localFocalPoint: const Offset(800, 500),
                  focalPointDelta: const Offset(200, 0),
                ),
              );
              surface.onScaleEnd!(ScaleEndDetails());
              await tester.pumpAndSettle();
              expect(fixture.native.seeks.last, greaterThan(Duration.zero));
            case VideoGesture.swipeVolume:
              final original = fixture.native.state.volume;
              surface.onScaleStart!(
                ScaleStartDetails(localFocalPoint: const Offset(1100, 500)),
              );
              surface.onScaleUpdate!(
                ScaleUpdateDetails(
                  localFocalPoint: const Offset(1100, 600),
                  focalPointDelta: const Offset(0, 100),
                ),
              );
              surface.onScaleEnd!(ScaleEndDetails());
              await tester.pumpAndSettle();
              expect(fixture.native.state.volume, lessThan(original));
            case VideoGesture.holdSpeed:
              final haptics = <MethodCall>[];
              final messenger = tester.binding.defaultBinaryMessenger;
              messenger.setMockMethodCallHandler(SystemChannels.platform, (
                call,
              ) async {
                if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
                return null;
              });
              addTearDown(
                () => messenger.setMockMethodCallHandler(
                  SystemChannels.platform,
                  null,
                ),
              );
              await tester.longPressAt(const Offset(640, 300));
              await tester.pumpAndSettle();
              expect(fixture.native.state.rate, 1);
              expect(haptics, hasLength(1));
              final gesture = await tester.startGesture(const Offset(640, 300));
              await tester.pump(const Duration(milliseconds: 300));
              expect(haptics, hasLength(1));
              await tester.pump(const Duration(milliseconds: 300));
              expect(fixture.native.state.rate, 1.5);
              expect(haptics, hasLength(2));
              await gesture.moveBy(const Offset(40, 0));
              await tester.pump();
              expect(fixture.native.state.rate, 1.75);
              expect(haptics, hasLength(2));
              await gesture.up();
              await tester.pumpAndSettle();
              expect(fixture.native.state.rate, 1);
              expect(haptics, hasLength(2));
            default:
              fail('Unexpected gesture');
          }
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'pinch and pan are independent and master switch cancels recognition',
    (tester) async {
      final fixture = _SkipVideoFixture();
      final options = fixture.settings.videoPlayback.gestureOptions;
      for (final gesture in VideoGesture.values) {
        options.setEnabled(gesture, gesture == VideoGesture.pinchZoom);
      }
      GestureDetector surface() => tester.widget<GestureDetector>(
        find.byKey(const ValueKey('video-gesture-surface')),
      );
      try {
        await fixture.mount(tester);
        surface().onScaleStart!(
          ScaleStartDetails(localFocalPoint: const Offset(600, 500)),
        );
        surface().onScaleUpdate!(
          ScaleUpdateDetails(
            localFocalPoint: const Offset(700, 500),
            scale: 2,
            pointerCount: 2,
            focalPointDelta: const Offset(100, 0),
          ),
        );
        surface().onScaleEnd!(ScaleEndDetails());
        await tester.pumpAndSettle();
        expect(fixture.native.properties['video-zoom'], '1.000');
        expect(fixture.native.properties['video-pan-x'], '0.000');
        options.setEnabled(VideoGesture.pinchZoom, false);
        options.setEnabled(VideoGesture.panZoom, true);
        fixture.native._core.rateChanged(1);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        surface().onScaleStart!(
          ScaleStartDetails(localFocalPoint: const Offset(600, 500)),
        );
        surface().onScaleUpdate!(
          ScaleUpdateDetails(
            localFocalPoint: const Offset(728, 500),
            scale: 4,
            pointerCount: 2,
            focalPointDelta: const Offset(128, 0),
          ),
        );
        surface().onScaleEnd!(ScaleEndDetails());
        await tester.pumpAndSettle();
        expect(fixture.native.properties['video-zoom'], '1.000');
        expect(fixture.native.properties['video-pan-x'], '0.200');
        fixture.settings.videoPlayback.gestures = false;
        fixture.native.setBuffering(true);
        await tester.idle();
        await tester.pump();
        expect(surface().onScaleStart, isNull);
        expect(surface().onLongPressStart, isNull);
        expect(surface().onDoubleTap, isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final pixelRatio in [1.0, 2.0]) {
    testWidgets(
      'video bars span the viewport and safe areas, independent of picture at DPR $pixelRatio',
      (tester) async {
        final fixture = _SkipVideoFixture();
        try {
          await fixture.mount(tester);
          tester.view.devicePixelRatio = pixelRatio;
          for (final (size, scale, leftSafe, rightSafe, rtl) in [
            (const Size(1600, 720), 1.0, 0.0, 0.0, false),
            (const Size(1920, 800), 1.0, 0.0, 0.0, false),
            (const Size(1280, 800), 1.0, 0.0, 0.0, false),
            (const Size(740, 360), 1.0, 48.0, 14.0, false),
            (const Size(740, 360), 1.0, 14.0, 48.0, true),
            (const Size(390, 844), 1.0, 0.0, 0.0, false),
            (const Size(360, 640), 1.7, 0.0, 0.0, false),
          ]) {
            tester.view.physicalSize = size * pixelRatio;
            tester.view.padding = FakeViewPadding(
              left: leftSafe * pixelRatio,
              right: rightSafe * pixelRatio,
              top: 24 * pixelRatio,
              bottom: 16 * pixelRatio,
            );
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            final direction = rtl ? TextDirection.rtl : TextDirection.ltr;
            fixture.direction.value = direction;
            await tester.pumpAndSettle();

            final top = find.byKey(const ValueKey('video-top-controls'));
            final bottom = find.byKey(const ValueKey('video-bottom-controls'));
            final bounds = Rect.fromLTRB(
              leftSafe > 10 ? leftSafe : 10,
              0,
              size.width - (rightSafe > 10 ? rightSafe : 10),
              size.height,
            );
            final rects = <Rect>[];
            for (final texture in [
              null,
              const Rect.fromLTWH(0, 0, 1920, 1080),
              const Rect.fromLTWH(0, 0, 1080, 1920),
              const Rect.fromLTWH(0, 0, 1440, 1080),
            ]) {
              fixture.controller.rect.value = texture;
              await tester.pumpAndSettle();
              for (final bar in [top, bottom]) {
                final rect = tester.getRect(bar);
                expect(
                  rect.left,
                  closeTo(bounds.left, .01),
                  reason: '$size DPR $pixelRatio $direction',
                );
                expect(rect.right, closeTo(bounds.right, .01));
                expect(rect.top, greaterThanOrEqualTo(24));
                expect(rect.bottom, lessThanOrEqualTo(size.height - 16));
              }
              final current = [
                tester.getRect(top),
                tester.getRect(bottom),
                tester.getRect(find.byKey(const ValueKey('video-seek'))),
              ];
              if (rects.isEmpty) {
                rects.addAll(current);
              } else {
                expect(
                  current,
                  rects,
                  reason:
                      'Decoder aspect changes must not pull controls inward.',
                );
              }
              expect(
                tester.widget<Video>(find.byType(Video)).fit,
                BoxFit.contain,
                reason:
                    'Do not stretch/crop the actual video to widen controls.',
              );
              expect(
                find.byTooltip('Back to videos').hitTestable(),
                findsOneWidget,
              );
              expect(
                find.byTooltip('More player controls').hitTestable(),
                findsOneWidget,
              );
              expect(
                find.byTooltip('Lock controls').hitTestable(),
                findsOneWidget,
              );
              expect(
                find.byTooltip('Now playing queue').hitTestable(),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
            }
          }
        } finally {
          tester.view.resetPadding();
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'chapter skip stays usable while locked and auto-hidden across layouts',
    (tester) async {
      final fixture = _SkipVideoFixture();
      final native = fixture.native;
      native.properties.addAll({
        'chapter-list/count': '5',
        'chapter-list/0/time': '0',
        'chapter-list/0/title': '[OP] Theme',
        'chapter-list/1/time': '10',
        'chapter-list/1/title': 'Story',
        'chapter-list/2/time': '80',
        'chapter-list/2/title': 'ED',
        'chapter-list/3/time': '100',
        'chapter-list/3/title': 'Post-credit scene',
        'chapter-list/4/time': '110',
        'chapter-list/4/title': 'Outro',
      });
      // Automatic chapter prompts must not silently expand saved auto-skip.
      fixture.settings.videoPlayback.autoSkip = true;
      try {
        await fixture.mount(tester);
        final skip = find.byKey(const ValueKey('video-skip-segment'));
        expect(find.text('Skip Opening'), findsOneWidget);
        expect(fixture.settings.videoPlayback.skipSegments, isEmpty);
        await tester.tap(find.byTooltip('Lock controls'));
        await tester.pumpAndSettle();
        for (final (size, scale) in [
          (const Size(390, 844), 1.0),
          (const Size(740, 360), 1.0),
          (const Size(1280, 800), 1.0),
          (const Size(360, 640), 2.0),
        ]) {
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await native.seek(const Duration(seconds: 2));
          await tester.pump();
          await tester.pump(const Duration(seconds: 5));
          expect(native.state.position, const Duration(seconds: 2));
          expect(find.byTooltip('Unlock controls'), findsNothing);
          expect(find.byTooltip('Pause video'), findsNothing);
          expect(find.byTooltip('More player controls'), findsNothing);
          expect(skip.hitTestable(), findsOneWidget, reason: '$size / $scale');
          expect(tester.getRect(skip).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(skip).right, lessThanOrEqualTo(size.width));
          await tester.tap(skip);
          await tester.pumpAndSettle();
          expect(native.state.position, const Duration(seconds: 10));
          expect(native.state.playing, isTrue);
          expect(skip, findsNothing);
          // Skip must not unlock ordinary controls or change playback.
          await tester.tapAt(Offset(size.width / 2, size.height / 2));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Unlock controls'), findsOneWidget);
          expect(find.byTooltip('Pause video'), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pump(const Duration(seconds: 5));
        expect(find.byTooltip('Unlock controls'), findsNothing);
        await native.seek(const Duration(seconds: 85));
        await tester.pumpAndSettle();
        expect(find.text('Skip Ending'), findsOneWidget);
        expect(
          find.byTooltip('Unlock controls'),
          findsNothing,
          reason:
              'Entering a segment must not expose ordinary locked controls.',
        );
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(
          native.state.position,
          const Duration(seconds: 100),
          reason: 'Preserve the post-credit scene.',
        );
        expect(skip, findsNothing);
        await native.seek(const Duration(seconds: 115));
        await tester.pumpAndSettle();
        expect(find.text('Skip Outro'), findsOneWidget);
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(native.state.position, const Duration(minutes: 2));
        expect(skip, findsNothing);
        expect(fixture.settings.videoPlayback.skipSegments, isEmpty);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  for (final label in ['Opening', 'Intro']) {
    testWidgets(
      'Skip $label expires after 15 seconds and reappears on re-entry',
      (tester) async {
        final fixture = _SkipVideoFixture();
        fixture.native.properties.addAll({
          'chapter-list/count': '4',
          'chapter-list/0/title': 'Prologue',
          'chapter-list/1/time': '10',
          'chapter-list/1/title': 'OP',
          'chapter-list/2/time': '70',
          'chapter-list/2/title': 'Episode',
          'chapter-list/3/time': '95',
          'chapter-list/3/title': 'ED',
        });
        if (label == 'Intro') {
          fixture.settings.videoPlayback.setSkipSegments(
            fixture.source.id,
            const [
              VideoSkipSegment(
                Duration(seconds: 10),
                Duration(seconds: 70),
                'Introduction',
              ),
            ],
          );
        }
        try {
          await fixture.mount(tester);
          await tester.tap(find.byTooltip('Lock controls'));
          await tester.pumpAndSettle();
          final prompt = find.text('Skip $label');
          expect(prompt, findsNothing);

          await fixture.native.seek(const Duration(seconds: 20));
          await tester.idle();
          await tester.pump();
          expect(prompt.hitTestable(), findsOneWidget);
          await tester.pump(const Duration(seconds: 14, milliseconds: 999));
          expect(prompt.hitTestable(), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 1));
          expect(prompt, findsNothing);
          expect(fixture.native.state.position, const Duration(seconds: 20));
          await fixture.native.seek(const Duration(seconds: 21));
          await tester.idle();
          await tester.pump();
          expect(prompt, findsNothing);

          await fixture.native.seek(const Duration(seconds: 100));
          await tester.idle();
          await tester.pump(const Duration(seconds: 16));
          expect(find.text('Skip Ending'), findsOneWidget);
          await fixture.native.seek(const Duration(seconds: 20));
          await tester.idle();
          await tester.pump();
          expect(prompt.hitTestable(), findsOneWidget);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'saved ranges take priority and skipping while locked preserves pause',
    (tester) async {
      final fixture = _SkipVideoFixture();
      fixture.settings.videoPlayback.setSkipSegments(fixture.source.id, const [
        VideoSkipSegment(Duration.zero, Duration(seconds: 20), 'Introduction'),
        VideoSkipSegment(Duration(seconds: 80), Duration(seconds: 100), 'ED'),
      ]);
      try {
        await fixture.mount(tester);
        final skip = find.byKey(const ValueKey('video-skip-segment'));
        expect(find.text('Skip Intro'), findsOneWidget);
        await tester.tap(find.byTooltip('Lock controls'));
        await tester.pumpAndSettle();
        await fixture.native.pause();
        await tester.pump();
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(fixture.native.state.position, const Duration(seconds: 20));
        expect(fixture.native.state.playing, isFalse);
        expect(
          skip,
          findsNothing,
          reason:
              'Do not offer the wider chapter after a corrected saved range.',
        );
        expect(find.byTooltip('Unlock controls'), findsOneWidget);
        expect(find.byTooltip('Play video'), findsNothing);
        await fixture.native.seek(const Duration(seconds: 85));
        await tester.pumpAndSettle();
        expect(find.text('Skip Ending'), findsOneWidget);
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(fixture.native.state.position, const Duration(seconds: 100));
        expect(fixture.native.state.playing, isFalse);
        expect(skip, findsNothing);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets('unmarked videos never get guessed intro or ending buttons', (
    tester,
  ) async {
    final fixture = _SkipVideoFixture();
    fixture.native.properties['chapter-list/count'] = '0';
    try {
      await fixture.mount(tester);
      await tester.tap(find.byTooltip('Lock controls'));
      await tester.pumpAndSettle();
      for (final seconds in [0, 5, 30, 100, 119]) {
        await fixture.native.seek(Duration(seconds: seconds));
        await tester.pump();
        expect(find.byKey(const ValueKey('video-skip-segment')), findsNothing);
      }
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets(
    'skip prevents overlapping requests and recovers after a seek failure',
    (tester) async {
      final fixture = _SkipVideoFixture();
      try {
        await fixture.mount(tester);
        await tester.tap(find.byTooltip('Lock controls'));
        await tester.pumpAndSettle();
        final gate = Completer<void>();
        fixture.native.beforeSeek = (_) => gate.future;
        final skip = find.byKey(const ValueKey('video-skip-segment'));
        final activate = tester.widget<FilledButton>(skip).onPressed!;
        activate();
        activate();
        await tester.pump();
        expect(fixture.native.seeks, [const Duration(seconds: 45)]);
        expect(tester.widget<FilledButton>(skip).onPressed, isNull);
        gate.completeError(StateError('Test seek failure'));
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(skip).onPressed, isNotNull);
        expect(
          find.text('This playback action could not be applied.'),
          findsOneWidget,
        );
        expect(find.byTooltip('Unlock controls'), findsOneWidget);
        fixture.native.beforeSeek = null;
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(fixture.native.state.position, const Duration(seconds: 45));
        expect(skip, findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  test('playlist and history restore Telegram and local videos only', () {
    final data = VideoPlaybackData();
    final local = VideoSource.file(
      Uri.parse('content://provider/video/1'),
      'Local',
    );
    final other = VideoSource.file(Uri.file('/movies/other.mp4'), 'Other');
    final telegram = VideoSource.telegram(
      const Track(
        id: '-1001:42',
        title: 'Telegram video',
        artist: '',
        source: 'Channel',
        fileId: 7,
      ),
    );
    data.putPlaylist('Queue', [telegram, local, other, local]);
    data.recordVideo(local, at: DateTime.utc(2026, 10, 1));
    data.recordVideo(telegram, at: DateTime.utc(2026, 10, 2));
    data.recordVideo(local, at: DateTime.utc(2026, 10, 3));
    data.remember(
      local.id,
      const Duration(seconds: 8),
      const Duration(minutes: 1),
    );
    data.subtitleStyle['sub-pos'] = '75';
    data.subtitleStyle['sub-scale'] = 'Infinity';
    final json = data.toJson();
    final oldWeb = {
      'title': 'Website',
      'uri': 'https://youtu.be/test',
      'web': {'height': 720},
    };
    (json['playlists']['Queue'] as List).add(oldWeb);
    (json['history'] as List).add({
      'source': oldWeb,
      'at': '2026-10-04T00:00:00Z',
    });
    final restored = VideoPlaybackData.fromJson(json);
    final list = restored.playlists['Queue']!;
    expect(list.map((source) => source.id), [telegram.id, local.id, other.id]);
    expect(list.first.telegram!.fileId, isNull);
    expect(
      VideoSource.restore({
        'title': 'Playlist',
        'uri': 'file:///tmp/play.m3u8',
      }),
      isNull,
    );
    expect(restored.history.keys, [telegram.id, local.id]);
    expect(restored.history[local.id]!.playedAt, DateTime.utc(2026, 10, 3));
    expect(restored.subtitleStyle, {'sub-pos': '75'});
    restored.clearTelegram();
    expect(restored.playlists['Queue']!.map((source) => source.id), [
      local.id,
      other.id,
    ]);
    expect(restored.history.keys, [local.id]);
    restored.removeHistory(local.id);
    expect(restored.positions, isEmpty);
    expect(restored.playlists['Queue']!.length, 2);
  });

  test(
    'adding to a full Video playlist reports the limit without losing entries',
    () {
      VideoSource video(int id) =>
          VideoSource.file(Uri.file('/movies/$id.mp4'), 'Video $id');
      final data = VideoPlaybackData();
      final items = List.generate(1000, video);
      data.putPlaylist('Full', items);
      expect(
        () => data.putPlaylist('Full', [...items, video(1000)]),
        throwsFormatException,
      );
      expect(data.playlists['Full'], items);
      data.putPlaylist('Full', [...items, items.first]);
      expect(data.playlists['Full'], items);
    },
  );

  test(
    'local and Telegram resume points survive each other’s history limit',
    () {
      final data = VideoPlaybackData();
      const position = Duration(seconds: 18);
      final local = VideoSource.file(Uri.file('/movies/local.mp4'), 'Local');
      data.recordVideo(local);
      data.remember(local.id, position, Duration.zero);

      for (var i = 1; i <= 301; i++) {
        final episode = VideoSource.telegram(
          Track(id: '-100:$i', title: 'Episode $i', artist: '', source: 'TV'),
        );
        data.recordVideo(episode);
        data.remember(episode.id, position, Duration.zero);
      }
      final reloaded = VideoPlaybackData.fromJson(data.toJson());
      reloaded.applyTelegramActivity(data.telegramActivity());
      expect(reloaded.positions[local.id], position);
      expect(reloaded.positions['telegram:-100:1'], isNull);
      expect(reloaded.positions['telegram:-100:2'], position);

      for (var i = 1; i <= 300; i++) {
        final source = VideoSource.file(Uri.file('/movies/$i.mp4'), 'Video $i');
        reloaded.recordVideo(source);
        reloaded.remember(source.id, position, Duration.zero);
      }
      expect(reloaded.positions[local.id], isNull);
      expect(reloaded.positions['telegram:-100:2'], position);
      expect(reloaded.positions, hasLength(600));
      final restored = VideoPlaybackData.fromJson(reloaded.toJson());
      restored.applyTelegramActivity(reloaded.telegramActivity());
      expect(restored.positions, reloaded.positions);
    },
  );

  test('skip chapter import respects boundaries and known labels', () {
    final segments = videoChapterSegments(const [
      VideoBookmark(Duration.zero, 'Intro'),
      VideoBookmark(Duration(seconds: 15), 'Story'),
      VideoBookmark(Duration(seconds: 90), 'End Credits'),
    ], const Duration(seconds: 100));
    expect(segments.map((segment) => segment.label), ['Intro', 'End Credits']);
    expect(segments.first.end, const Duration(seconds: 15));
    expect(segments.last.end, const Duration(seconds: 100));
  });

  test('video progress and custom controls persist locally and clear on Telegram sign-out', () async {
    final root = await Directory.systemTemp.createTemp(
      'auralis-video-settings',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/settings.json');
    final settings = AppSettings(file);
    const point = Duration(seconds: 45);
    final data = settings.videoPlayback;
    expect(
      data.controls(VideoControlZone.bottomStart, wide: false),
      contains(VideoControl.orientation),
    );
    final legacy = VideoPlaybackData.fromJson({
      'controlLayouts': {
        'landscape:bottomStart': ['lock', 'loop', 'speed'],
      },
    });
    expect(legacy.controls(VideoControlZone.bottomStart, wide: true), [
      VideoControl.lock,
      VideoControl.speed,
    ]);
    data.remember('telegram:1:2', point, const Duration(minutes: 2));
    data.remember('file:example', point, const Duration(minutes: 2));
    data.setBookmarks('telegram:1:2', [const VideoBookmark(point, 'Opening')]);
    data.setSkipSegments('telegram:1:2', [
      const VideoSkipSegment(Duration(seconds: 5), point, 'Intro'),
    ]);
    data.commands[VideoControl.customOne] = VideoCommand(
      'Message',
      VideoCommand.parse('["show-text","Ready"]'),
    );
    data.mpvConfig = 'keep-open=yes';
    expect(
      () => VideoCommand.parse('["loadfile","other.mp4"]'),
      throwsFormatException,
    );
    data.setControls(
      VideoControlZone.topEnd,
      wide: true,
      controls: [
        VideoControl.audio,
        VideoControl.audio,
        VideoControl.screenshot,
      ],
    );
    data.animation = VideoControlAnimation.slide;
    await settings.save();

    final restored = AppSettings(file);
    await restored.load();
    expect(restored.toJson(), isNot(contains('_videoPlayback')));
    expect(restored.videoPlayback.positions['telegram:1:2'], point);
    expect(
      restored.videoPlayback.bookmarks['telegram:1:2']!.single.name,
      'Opening',
    );
    expect(
      restored.videoPlayback.controls(VideoControlZone.topEnd, wide: true),
      [VideoControl.audio, VideoControl.screenshot],
    );
    expect(restored.videoPlayback.animation, VideoControlAnimation.slide);
    expect(
      restored.videoPlayback.skipSegments['telegram:1:2']!.single.end,
      point,
    );
    expect(restored.videoPlayback.commands[VideoControl.customOne]!.args, [
      'show-text',
      'Ready',
    ]);
    expect(restored.videoPlayback.mpvConfig, 'keep-open=yes');
    restored.videoPlayback.clearTelegram();
    expect(restored.videoPlayback.positions.keys, ['file:example']);
    expect(restored.videoPlayback.bookmarks, isEmpty);
    expect(restored.videoPlayback.skipSegments, isEmpty);
    restored.videoPlayback.remember(
      'file:example',
      const Duration(seconds: 118),
      const Duration(minutes: 2),
    );
    expect(
      restored.videoPlayback.positions['file:example'],
      const Duration(seconds: 118),
    );
  });

  testWidgets(
    'decoder warnings leave video playing and a real abort offers Retry',
    (tester) async {
      final native = _NativeVideo()..warnOnOpen = true;
      final proxy = _RecordingVideoProxy();
      final music = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      final source = VideoSource.file(Uri.file('/movies/one.mp4'), 'One video');
      final opened = <VideoSource>[];
      addTearDown(proxy.close);
      addTearDown(telegram.shutdown);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: VideoPlayback(
              sources: [source],
              initialIndex: 0,
              telegram: telegram,
              music: music,
              proxy: proxy,
              onOpened: opened.add,
              createController: () => _VideoController(native),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(opened, [source]);
        expect(find.text('Retry'), findsNothing);
        await native.seek(const Duration(seconds: 12));
        native.warn();
        await native.seek(const Duration(seconds: 13));
        await tester.idle();
        await tester.pump();
        expect(native.state.playing, isTrue);
        expect(find.text('The video could not be played.'), findsNothing);

        native.abortPlayback();
        await tester.idle();
        await tester.pump();
        expect(find.text('The video could not be played.'), findsOneWidget);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(opened, [source, source]);
        expect(native.state.playing, isTrue);
        expect(find.text('Retry'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        var shutdown = false;
        unawaited(music.shutdown().then((_) => shutdown = true));
        for (var frame = 0; frame < 20 && !shutdown; frame++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          tester.binding.scheduleFrame();
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(shutdown, isTrue);
      }
    },
  );

  testWidgets('finishing and closing a video resume the interrupted song', (
    tester,
  ) async {
    final native = _NativeVideo();
    final proxy = _RecordingVideoProxy();
    final audio = FakeAudio();
    final music = PlayerController(
      audio,
      TelegramStreamProxy((_) async => {}),
      MemorySettings(),
    );
    final telegram = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: FakeTd(),
    );
    const song = Track(
      id: 'song',
      title: 'Song',
      artist: '',
      source: 'Music',
      fileId: 1,
      size: 100,
    );
    final video = VideoSource.file(Uri.file('/movies/one.mp4'), 'One video');
    addTearDown(proxy.close);
    addTearDown(telegram.shutdown);
    addTearDown(music.shutdown);
    await tester.runAsync(() => music.play(song));
    const position = Duration(seconds: 28);
    await music.seek(position);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayback(
          sources: [video],
          initialIndex: 0,
          telegram: telegram,
          music: music,
          proxy: proxy,
          onOpened: (_) {},
          createController: () => _VideoController(native),
          minimized: true,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(native.state.playing, isTrue);
    expect(audio.playing, isFalse);
    native.complete();
    await tester.pumpAndSettle();
    expect(audio.playing, isTrue);
    expect(audio.position, position);

    await tester.tap(find.byTooltip('Play video'));
    await tester.pumpAndSettle();
    expect(native.state.playing, isTrue);
    expect(audio.playing, isFalse);
    final release = music.releaseVideo!();
    await tester.pumpWidget(const SizedBox.shrink());
    var released = false;
    unawaited(release.then((_) => released = true));
    for (var frame = 0; frame < 30 && !released; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(released, isTrue);
    expect(audio.playing, isTrue);
    expect(audio.position, position);
  });

  testWidgets(
    'Telegram episodes restore only their channel playback settings',
    (tester) async {
      final native = _NativeVideo();
      final proxy = _RecordingVideoProxy();
      final settings = MemorySettings();
      final music = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      )..state = 'authorizationStateReady';
      addTearDown(proxy.close);
      addTearDown(telegram.shutdown);
      VideoSource episode(int channel, int fileId) => VideoSource.telegram(
        Track(
          id: '$channel:$fileId',
          title: 'Episode $fileId',
          artist: '',
          source: 'Anime',
          fileId: fileId,
          size: 100,
        ),
      );
      settings.videoPlayback.channels['-1001'] = VideoChannelSettings()
        ..audio = const VideoTrackChoice('18', 'English audio', 'eng')
        ..subtitles = const VideoTrackChoice('no', null, null)
        ..pictureBrightness = 24;

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: VideoPlayback(
              sources: [
                episode(-1001, 1),
                episode(-1002, 2),
                episode(-1001, 3),
              ],
              initialIndex: 0,
              telegram: telegram,
              music: music,
              proxy: proxy,
              onOpened: (_) {},
              createController: () => _VideoController(native),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, '3');
        expect(native.state.track.subtitle.id, 'no');
        expect(double.parse(native.properties['brightness']!), 24);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(native.state.volume, 95);
        expect(settings.videoPlayback.channels['-1001']!.volume, 95);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, '1');
        expect(native.state.track.subtitle.id, '2');
        expect(native.state.volume, 100);
        expect(native.properties['brightness'], '0');

        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, '3');
        expect(native.state.track.subtitle.id, 'no');
        expect(native.state.volume, 95);
        expect(double.parse(native.properties['brightness']!), 24);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        var shutdown = false;
        unawaited(music.shutdown().then((_) => shutdown = true));
        for (var frame = 0; frame < 20 && !shutdown; frame++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          tester.binding.scheduleFrame();
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(shutdown, isTrue);
      }
    },
  );

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('video language defaults and manual overrides at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final native = _NativeVideo();
      final preferredTracks = native.availableTracks;
      native.availableTracks = mpv.Tracks(
        audio: [
          mpv.AudioTrack.auto(),
          mpv.AudioTrack.no(),
          const mpv.AudioTrack('3', 'English audio', 'en'),
        ],
        subtitle: [mpv.SubtitleTrack.auto(), mpv.SubtitleTrack.no()],
      );
      final proxy = _RecordingVideoProxy();
      final music = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(proxy.close);
      addTearDown(telegram.shutdown);
      final first = VideoSource.file(
        Uri.file('/movies/first.mp4'),
        'First video',
      );
      final second = VideoSource.file(
        Uri.file('/movies/second.mp4'),
        'Second video',
      );

      Future<void> select(String panel, String label) async {
        await tester.tap(find.byTooltip(panel));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: auralisTheme(
              ColorScheme.fromSeed(
                seedColor: Colors.purple,
                brightness: Brightness.dark,
              ),
            ),
            home: VideoPlayback(
              sources: [first, second],
              initialIndex: 0,
              telegram: telegram,
              music: music,
              proxy: proxy,
              onOpened: (_) {},
              createController: () => _VideoController(native),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, 'auto');
        expect(native.state.track.subtitle.id, 'auto');

        // Telegram/libmpv can discover track metadata after open completes.
        native.publishTracks(preferredTracks);
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, '1');
        expect(native.state.track.subtitle.id, '2');
        final audioCount = native.audioSelections.length;
        final subtitleCount = native.subtitleSelections.length;
        native.publishTracks(preferredTracks);
        await tester.pumpAndSettle();
        expect(native.audioSelections.length, audioCount);
        expect(native.subtitleSelections.length, subtitleCount);

        await select('Audio tracks', 'English audio');
        await select('Subtitles', 'Off');
        native.publishTracks(preferredTracks);
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, '3');
        expect(native.state.track.subtitle.id, 'no');

        await select('Audio tracks', 'Automatic');
        await select('Subtitles', 'Automatic');
        expect(native.state.track.audio.id, '1');
        expect(native.state.track.subtitle.id, '2');

        await select('Audio tracks', 'Off');
        await select('Subtitles', 'French subtitles');
        native.publishTracks(preferredTracks);
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, 'no');
        expect(native.state.track.subtitle.id, '4');

        native.availableTracks = preferredTracks;
        await tester.tap(find.byTooltip('Now playing queue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Second video'));
        await tester.pumpAndSettle();
        expect(native.state.track.audio.id, '1');
        expect(native.state.track.subtitle.id, '2');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        var shutdown = false;
        unawaited(music.shutdown().then((_) => shutdown = true));
        for (var frame = 0; frame < 20 && !shutdown; frame++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          tester.binding.scheduleFrame();
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(shutdown, isTrue);
      }
    });
  }

  testWidgets(
    'video controls adapt, seek, unlock and switch to a saved queue entry',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final native = _NativeVideo();
      final surface = _VideoController(native);
      final proxy = _RecordingVideoProxy();
      final music = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(proxy.close);
      addTearDown(telegram.shutdown);
      final first = VideoSource.file(
        Uri.file('/movies/first.mp4'),
        'First video',
      );
      final second = VideoSource.file(
        Uri.file('/movies/second.mp4'),
        'Second video',
      );
      music.settings.videoPlayback = VideoPlaybackData.fromJson({
        'swapSides': true,
      });
      music.settings.videoPlayback.remember(
        second.id,
        const Duration(seconds: 21),
        const Duration(minutes: 2),
      );
      var minimized = false;
      var browserTaps = 0;
      final events = <String>[];
      final decoderReleased = Completer<void>();
      var releaseFinished = false;
      var shutdownFinished = false;
      bool? surfacePresentAtStop;
      bool? surfacePresentAtDispose;

      Future<bool> pumpUntil(bool Function() ready) async {
        for (var frame = 0; frame < 20 && !ready(); frame++) {
          // Service real-zone futures and the frame awaited by player shutdown.
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          tester.binding.scheduleFrame();
          await tester.pump(const Duration(milliseconds: 16));
        }
        return ready();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: auralisTheme(
              ColorScheme.fromSeed(
                seedColor: Colors.purple,
                brightness: Brightness.dark,
              ),
            ),
            home: StatefulBuilder(
              builder: (context, update) => Stack(
                fit: StackFit.expand,
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: TextButton(
                      onPressed: () => browserTaps++,
                      child: const Text('Video browser'),
                    ),
                  ),
                  VideoPlayback(
                    sources: [first, second],
                    initialIndex: 0,
                    telegram: telegram,
                    music: music,
                    proxy: proxy,
                    onOpened: (_) {},
                    minimized: minimized,
                    onBack: () => update(() => minimized = true),
                    onMinimize: () => update(() => minimized = true),
                    onExpand: () => update(() => minimized = false),
                    createController: () => surface,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(native.state.track.audio.id, '1');
        expect(native.state.track.subtitle.id, '2');
        expect(native.properties['alang'], 'ja,jpn,jp,japan,japanese');
        expect(native.properties['slang'], 'en,eng,english');

        final pauseButton = find.byTooltip('Pause video');
        final spinner = find.byWidgetPredicate(
          (widget) =>
              widget is CircularProgressIndicator &&
              widget.semanticsLabel == 'Loading video',
        );
        expect(spinner, findsNothing);
        native.setBuffering(true);
        // The broadcast stream schedules the rebuild after delivering its event.
        await tester.idle();
        await tester.pump();
        expect(spinner, findsOneWidget);
        expect(tester.getCenter(spinner), tester.getCenter(pauseButton));
        expect(find.byIcon(Icons.pause_rounded), findsNothing);
        native.setBuffering(false);
        await tester.idle();
        await tester.pump();
        expect(spinner, findsNothing);

        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          const space = LogicalKeyboardKey.space;
          await tester.sendKeyDownEvent(space);
          await tester.pump(const Duration(milliseconds: 100));
          expect(native.state.playing, isTrue);
          await tester.sendKeyUpEvent(space);
          await tester.pumpAndSettle();
          expect(native.state.playing, isFalse);
          await tester.sendKeyEvent(space);
          await tester.pumpAndSettle();
          expect(native.state.playing, isTrue);

          await native.setRate(1.5);
          await tester.sendKeyDownEvent(space);
          await tester.pump(const Duration(milliseconds: 450));
          expect(native.state.rate, 2);
          expect(native.state.playing, isTrue);
          await tester.sendKeyUpEvent(space);
          await tester.pumpAndSettle();
          expect(native.state.rate, 1.5);
          expect(native.state.playing, isTrue);
          await native.setRate(1);
        }

        final backControl = find.byTooltip('Back to videos');
        final moreControl = find.byTooltip('More player controls');
        final seekControl = find.byKey(const ValueKey('video-seek'));
        for (final size in [
          const Size(320, 540),
          const Size(800, 390),
          const Size(1280, 720),
        ]) {
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = size.width < 400
              ? 1.7
              : 1;
          surface.rect.value = null;
          await tester.pumpAndSettle();
          final beforeTexture = [
            tester.getRect(backControl),
            tester.getRect(moreControl),
            tester.getRect(seekControl),
          ];
          // The decoder may report a different aspect ratio from the startup
          // frame. The control positions must survive that update.
          surface.rect.value = const Rect.fromLTWH(0, 0, 1440, 1080);
          await tester.pumpAndSettle();
          expect([
            tester.getRect(backControl),
            tester.getRect(moreControl),
            tester.getRect(seekControl),
          ], beforeTexture);
          expect(find.text('Previous chapter'), findsNothing);
          expect(find.text('Next chapter'), findsNothing);
          expect(find.byTooltip('Chapters and bookmarks'), findsOneWidget);
          expect(
            find.byTooltip('More player controls').hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byTooltip('Now playing queue').hitTestable(),
            findsOneWidget,
          );
          if (Platform.isAndroid) {
            expect(find.byTooltip('Orientation').hitTestable(), findsOneWidget);
            expect(find.byTooltip('Fullscreen'), findsNothing);
          } else {
            expect(find.byTooltip('Fullscreen').hitTestable(), findsOneWidget);
          }
          expect(
            find.byKey(const ValueKey('video-seek')).hitTestable(),
            findsOneWidget,
          );
          if (size.width > size.height * 16 / 9) {
            final pictureLeft = (size.width - size.height * 16 / 9) / 2;
            final pictureRight = size.width - pictureLeft;
            final back = tester.getRect(find.byTooltip('Back to videos'));
            final more = tester.getRect(find.byTooltip('More player controls'));
            final seek = tester.getRect(
              find.byKey(const ValueKey('video-seek')),
            );
            expect(back.left, closeTo(10, .01));
            expect(more.right, closeTo(size.width - 10, .01));
            expect(back.left, lessThan(pictureLeft));
            expect(more.right, greaterThan(pictureRight));
            expect(seek.left, greaterThanOrEqualTo(10));
            expect(seek.right, lessThanOrEqualTo(size.width - 10));
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('video-bottom-controls')))
                  .left,
              closeTo(10, .01),
            );
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('video-bottom-controls')))
                  .right,
              closeTo(size.width - 10, .01),
            );
          }
          await tester.tap(find.byTooltip('Now playing queue'));
          await tester.pumpAndSettle();
          expect(find.text('Queue'), findsOneWidget);
          expect(find.text('Save as playlist').hitTestable(), findsOneWidget);
          expect(
            find.widgetWithText(FilterChip, 'Shuffle').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: 'Queue at $size');
          await tester.tap(find.byTooltip('Close panel'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$size');
        }

        await tester.tap(find.byTooltip('More player controls'));
        await tester.pumpAndSettle();
        expect(find.text('Quality'), findsNothing);
        expect(find.text('Settings & diagnostics'), findsNothing);
        final settingsShortcut = find.text('Video settings');
        await tester.ensureVisible(settingsShortcut);
        await tester.tap(settingsShortcut);
        await tester.pumpAndSettle();
        expect(find.text('Settings & diagnostics'), findsOneWidget);
        final decoder = find.widgetWithText(ListTile, 'Video decoder');
        expect(tester.widget<ListTile>(decoder).enabled, isTrue);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();

        const seekZone = Offset(1100, 300);
        await tester.tapAt(seekZone);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(seekZone);
        await tester.pumpAndSettle();
        expect(native.state.position, const Duration(seconds: 10));
        final transportCenter = tester.getCenter(pauseButton);
        expect(
          tester
              .getCenter(
                find.descendant(
                  of: find
                      .ancestor(
                        of: find.text('+10 s'),
                        matching: find.byType(Row),
                      )
                      .first,
                  matching: find.byIcon(Icons.fast_forward_rounded),
                ),
              )
              .dy,
          lessThan(tester.getTopLeft(pauseButton).dy),
        );
        for (final x in [200.0, 1080.0]) {
          final volumeBefore = native.state.volume;
          final drag = await tester.startGesture(Offset(x, 420));
          await drag.moveBy(const Offset(0, 25));
          await drag.moveBy(const Offset(0, 60));
          await tester.pump();
          final brightness = x < transportCenter.dx && Platform.isAndroid;
          final feedback = tester.getCenter(
            find.byIcon(
              brightness
                  ? Icons.brightness_6_rounded
                  : Icons.volume_up_rounded,
            ),
          );
          expect(feedback.dx < transportCenter.dx, brightness);
          final meter = tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
          final fraction = meter.value!;
          expect(fraction, inExclusiveRange(0.0, 1.0));
          expect(find.text('${(fraction * 100).round()}%'), findsOneWidget);
          if (brightness) {
            expect(native.state.volume, volumeBefore);
          } else {
            expect(native.state.volume, lessThan(volumeBefore));
            expect(fraction, closeTo(native.state.volume / 100, .0001));
          }
          await drag.up();
          await tester.pump();
        }

        await tester.tap(find.byTooltip('Lock controls'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('More player controls'), findsNothing);
        await tester.tap(find.byTooltip('Unlock controls'));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Chapters and bookmarks'));
        await tester.pumpAndSettle();
        expect(find.text('No bookmarks yet.'), findsOneWidget);
        await tester.tap(find.text('Part two'));
        await tester.pumpAndSettle();
        expect(native.state.position, const Duration(seconds: 45));

        await tester.tap(find.byTooltip('Now playing queue'));
        await tester.pumpAndSettle();
        final current = find.widgetWithText(ListTile, 'First video');
        expect(tester.widget<ListTile>(current).selected, isTrue);
        expect(
          find.descendant(
            of: current,
            matching: find.byTooltip('Remove from queue'),
          ),
          findsNothing,
        );
        final shuffle = find.widgetWithText(FilterChip, 'Shuffle');
        expect(tester.widget<FilterChip>(shuffle).selected, isFalse);
        await tester.tap(find.byTooltip('Video actions for Second video'));
        await tester.pumpAndSettle();
        expect(find.text('Play next'), findsOneWidget);
        expect(find.byKey(const ValueKey('media-item-sheet')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('media-action-next')));
        await tester.pumpAndSettle();
        expect(tester.widget<ListTile>(current).selected, isTrue);
        expect(native.opened, hasLength(1));
        await tester.tap(shuffle);
        await tester.pumpAndSettle();
        expect(tester.widget<FilterChip>(shuffle).selected, isTrue);
        await tester.tap(shuffle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Second video'));
        await tester.pumpAndSettle();
        expect(native.opened.last.start, const Duration(seconds: 21));
        expect(find.textContaining('Second video'), findsOneWidget);
        expect(
          music.settings.videoPlayback.positions[first.id],
          const Duration(seconds: 45),
        );
        await tester.tap(find.byTooltip('More player controls'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Playback'));
        await tester.pumpAndSettle();
        expect(find.text('A–B loop'), findsNothing);
        expect(find.text('Previous chapter'), findsNothing);
        expect(find.text('Next chapter'), findsNothing);
        expect(find.text('Chapters and bookmarks'), findsOneWidget);
        await tester.tap(find.text('Playback speed'));
        await tester.pumpAndSettle();
        expect(find.text('Normal'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, '1×'), findsOneWidget);
        await tester.tap(find.byTooltip('Close panel'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('More player controls'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Minimize video'));
        await tester.pumpAndSettle();
        final dock = find.byKey(const ValueKey('video-mini-player'));
        expect(dock.hitTestable(), findsOneWidget);
        await tester.tap(find.text('Video browser'));
        expect(browserTaps, 1);
        await tester.tap(find.byTooltip('Pause video'));
        await tester.pumpAndSettle();
        expect(native.state.playing, isFalse);
        await tester.tap(find.text('Second video'));
        await tester.pumpAndSettle();
        expect(dock, findsNothing);
        expect(native.opened, hasLength(2));
        expect(tester.takeException(), isNull);

        native.beforeStop = () {
          surfacePresentAtStop = find.byType(Video).evaluate().isNotEmpty;
          events.add('stop');
        };
        native.beforeDispose = () async {
          surfacePresentAtDispose = find.byType(Video).evaluate().isNotEmpty;
          events.add('decoder');
          await decoderReleased.future;
        };
        proxy.onStop = () => events.add('stream');
        unawaited(
          music.releaseVideo!().then((_) {
            releaseFinished = true;
          }),
        );
        expect(
          await pumpUntil(() => surfacePresentAtDispose != null),
          isTrue,
          reason: 'Decoder disposal did not start after removing the surface.',
        );
        expect(surfacePresentAtStop, Platform.isWindows ? isTrue : isNull);
        expect(surfacePresentAtDispose, isFalse);
        expect(events, [if (Platform.isWindows) 'stop', 'decoder']);
        expect(releaseFinished, isFalse);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          decoderReleased.complete();
          unawaited(
            music.shutdown().then((_) {
              shutdownFinished = true;
            }),
          );
          await pumpUntil(() => shutdownFinished);
        }
      }
      expect(
        shutdownFinished,
        isTrue,
        reason: 'Player shutdown did not finish.',
      );
      expect(releaseFinished, isTrue);
      expect(events, [if (Platform.isWindows) 'stop', 'decoder', 'stream']);
      expect(music.releaseVideo, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
