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
  void completed() {
    playingController.add(false);
    completedController.add(true);
  }
  void tracksChanged(mpv.Tracks tracks) => tracksController.add(tracks);
  void trackChanged(mpv.Track track) => trackController.add(track);
}

class _NativeVideo implements mpv.NativePlayer {
  final _core = _TestPlayerCore();
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
  VoidCallback? beforeStop;
  Future<void> Function()? beforeDispose;
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

  VoidCallback? onStop;

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

void main() {
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

  test('adding to a full Video playlist reports the limit without losing entries', () {
    VideoSource video(int id) => VideoSource.file(Uri.file('/movies/$id.mp4'), 'Video $id');
    final data = VideoPlaybackData();
    final items = List.generate(1000, video);
    data.putPlaylist('Full', items);
    expect(() => data.putPlaylist('Full', [...items, video(1000)]), throwsFormatException);
    expect(data.playlists['Full'], items);
    data.putPlaylist('Full', [...items, items.first]);
    expect(data.playlists['Full'], items);
  });

  test('local and Telegram resume points survive each other’s history limit', () {
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
  });

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
    expect(restored.videoPlayback.positions, isEmpty);
  });

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
    const song = Track(id: 'song', title: 'Song', artist: '', source: 'Music',
        fileId: 1, size: 100);
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
            expect(back.left, greaterThan(pictureLeft));
            expect(more.right, lessThan(pictureRight));
            expect(seek.left, greaterThan(pictureLeft));
            expect(seek.right, lessThan(pictureRight));
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
          tester.getCenter(find.byIcon(Icons.fast_forward_rounded)).dy,
          lessThan(tester.getTopLeft(pauseButton).dy),
        );
        for (final x in [200.0, 1080.0]) {
          final drag = await tester.startGesture(Offset(x, 420));
          await drag.moveBy(const Offset(0, -25));
          await drag.moveBy(const Offset(0, -60));
          await tester.pump();
          final onLeft = x < transportCenter.dx;
          final feedback = tester.getCenter(
            find.byIcon(
              onLeft && Platform.isAndroid
                  ? Icons.brightness_6_rounded
                  : Icons.volume_up_rounded,
            ),
          );
          expect(feedback.dx < transportCenter.dx, onLeft);
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
