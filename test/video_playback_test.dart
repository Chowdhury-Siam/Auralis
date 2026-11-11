import 'dart:async';
import 'dart:io';

import 'package:auralis/app_theme.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_playback.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
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
      position: media.start ?? Duration.zero,
      duration: duration,
      tracks: const mpv.Tracks(
        audio: [mpv.AudioTrack('1', 'Japanese audio', 'ja')],
        subtitle: [mpv.SubtitleTrack('2', 'English subtitles', 'en')],
      ),
    );
    _core.opened(play, duration);
  }

  @override
  Future<void> seek(Duration duration, {bool synchronized = true}) async {
    state = state.copyWith(position: duration);
    _core.seeked(duration);
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
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) async {
    state = const mpv.PlayerState();
    _core.opened(false, Duration.zero);
  }

  @override
  Future<void> dispose({bool synchronized = true}) => _core.dispose();

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
  test('M3U imports one source per video and keeps HLS as one stream', () {
    final videos = parseVideoPlaylist(
      '#EXTM3U\n#EXTINF:-1,First episode\nEpisode 1.mkv\n'
      'https://example.com/episode-2.mp4\nhttps://example.com/episode-2.mp4\n'
      'javascript:ignored\nhttps://name:pass@example.com/private\n',
      base: Uri.file('/video/list.m3u'),
    );
    expect(videos.map((video) => video.title), [
      'First episode',
      'episode-2.mp4',
    ]);
    expect(videos.first.uri, Uri.file('/video/Episode 1.mkv'));
    expect(
      () => parseVideoPlaylist('#EXTM3U\n#EXT-X-TARGETDURATION:10\npart.ts'),
      throwsFormatException,
    );
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
      final proxy = TelegramStreamProxy((_) async => {});
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
      addTearDown(music.shutdown);
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

      for (final size in [
        const Size(320, 540),
        const Size(800, 390),
        const Size(1280, 720),
      ]) {
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = size.width < 400
            ? 1.7
            : 1;
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('More player controls').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byTooltip('Now playing queue').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('video-seek')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: '$size');
      }

      const seekZone = Offset(1100, 300);
      await tester.tapAt(seekZone);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(seekZone);
      await tester.pumpAndSettle();
      expect(native.state.position, const Duration(seconds: 10));

      await tester.tap(find.byTooltip('Lock controls'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('More player controls'), findsNothing);
      await tester.tap(find.byTooltip('Unlock controls'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Chapters and bookmarks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Part two'));
      await tester.pumpAndSettle();
      expect(native.state.position, const Duration(seconds: 45));

      await tester.tap(find.byTooltip('Now playing queue'));
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
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
