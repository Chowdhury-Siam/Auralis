import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/wave_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  setUpAll(() async {
    final font = File(
      Platform.isWindows
          ? 'C:/Windows/Fonts/segoeui.ttf'
          : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    );
    if (font.existsSync()) {
      await (FontLoader('Segoe UI')
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  WaveTrack shape(WidgetTester tester) =>
      tester
              .widget<SliderTheme>(
                find
                    .descendant(
                      of: find.byType(WaveSeekBar),
                      matching: find.byType(SliderTheme),
                    )
                    .first,
              )
              .data
              .trackShape!
          as WaveTrack;

  Widget wave({
    bool playing = true,
    bool reduced = false,
    bool systemReduced = false,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: systemReduced),
      child: Scaffold(
        body: WaveSeekBar(
          value: .6,
          playing: playing,
          reducedMotion: reduced,
          format: (v) => '$v',
          onChanged: (_) {},
        ),
      ),
    ),
  );

  testWidgets(
    'player dock hides without a current track and stays while paused',
    (tester) async {
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings()..reducedMotion = true,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final dock = find.byKey(const ValueKey('player-bar'));

      for (final size in [const Size(390, 844), const Size(1280, 800)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
        await tester.pumpAndSettle();
        expect(dock, findsNothing, reason: '$size idle');

        player.queue.add(
          const Track(
            id: 'dock-track',
            title: 'A quiet start',
            artist: 'Test artist',
            source: 'Music channel',
          ),
        );
        player.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          dock,
          findsNothing,
          reason: 'Queued songs are not a current track',
        );

        player.index = 0;
        player.notifyListeners();
        await tester.pumpAndSettle();
        expect(dock, findsOneWidget, reason: '$size loaded and paused');
        await tester.tap(
          find.descendant(of: dock, matching: find.byTooltip('Play')),
        );
        await tester.pumpAndSettle();
        expect(audio.playing, isTrue);
        expect(dock, findsOneWidget);

        await tester.tap(
          find.descendant(of: dock, matching: find.byTooltip('Pause')),
        );
        await tester.pumpAndSettle();
        expect(audio.playing, isFalse);
        expect(dock, findsOneWidget, reason: 'Paused music can be resumed');

        await player.clear();
        await tester.pumpAndSettle();
        expect(player.current, isNull);
        expect(dock, findsNothing, reason: '$size queue cleared');
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('wave animates only during playback and freezes when paused', (
    tester,
  ) async {
    await tester.pumpWidget(wave());
    await tester.pump(const Duration(milliseconds: 80));
    final first = shape(tester).phase;
    await tester.pump(const Duration(milliseconds: 100));
    expect(shape(tester).phase, isNot(first));
    await tester.pumpWidget(wave(playing: false));
    final paused = shape(tester).phase;
    await tester.pump(const Duration(milliseconds: 250));
    expect(shape(tester).phase, paused);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('user and system reduced motion disable the wave ticker', (
    tester,
  ) async {
    for (final system in [false, true]) {
      await tester.pumpWidget(wave(reduced: !system, systemReduced: system));
      await tester.pumpAndSettle();
      final phase = shape(tester).phase;
      expect(shape(tester).amplitude, 0);
      await tester.pump(const Duration(milliseconds: 250));
      expect(shape(tester).phase, phase);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
  });

  testWidgets(
    'current-track navigation, seeking and controls survive adaptive window sizes',
    (tester) async {
      final art = File('test/fixtures/cover.png').readAsBytesSync();
      final td = FakeTd();
      td.onRequest = (r) async {
        if (r['@type'] == 'getChat') {
          return {
            'id': -1,
            'title': 'Music channel',
            'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
          };
        }
        if (r['@type'] == 'searchChatMessages') {
          return {
            'next_from_message_id': 0,
            'messages': r['filter']['@type'] == 'searchMessagesFilterDocument'
                ? []
                : [
                    {
                      'id': 1,
                      'chat_id': -1,
                      'content': {
                        '@type': 'messageAudio',
                        'audio': {
                          'title': 'Evening waves',
                          'performer': 'Auralis test artist',
                          'file_name': 'waves.mp3',
                          'audio': {'id': 1, 'size': 0},
                        },
                      },
                    },
                  ],
          };
        }
        return null;
      };
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      )..state = 'authorizationStateReady';
      final settings = MemorySettings()
        ..reducedMotion = true
        ..selectedChannels = [const MusicChat(-1, 'Music channel')];
      final audio = FakeAudio()
        ..duration = const Duration(minutes: 4)
        ..position = const Duration(minutes: 2)
        ..buffered = const Duration(minutes: 3)
        ..playing = true;
      final player =
          PlayerController(
              audio,
              TelegramStreamProxy((_) async => {}),
              settings,
            )
            ..queue.add(
              Track(
                id: 'current',
                title:
                    'Evening waves — a longer track title for the fixed player',
                artist: 'Auralis test artist',
                source: 'Music channel',
                mime: 'audio/x-flac',
                coverPreview: art,
              ),
            )
            ..index = 0;
      player.queue.addAll(
        List.generate(
          576,
          (i) => Track(
            id: 'next-$i',
            title: 'Upcoming track $i',
            artist: 'Another artist',
            source: 'Music channel',
          ),
        ),
      );
      addTearDown(() async {
        await player.shutdown();
        await telegram.shutdown();
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(() async {
        final context = tester.element(find.byType(MaterialApp));
        await precacheImage(ResizeImage(MemoryImage(art), width: 96), context);
        if (context.mounted) {
          await precacheImage(
            ResizeImage(MemoryImage(art), width: 640),
            context,
          );
        }
      });
      final sizes = [
        const Size(360, 480),
        const Size(390, 844),
        const Size(844, 390),
        const Size(915, 412),
        const Size(520, 560),
        const Size(760, 650),
        const Size(900, 480),
        const Size(1000, 700),
        const Size(1018, 680),
        const Size(1280, 714),
        const Size(1280, 800),
        const Size(1920, 1080),
      ];
      for (final size in sizes) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: AuralisApp(player: player, telegram: telegram),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size Library');
        expect(find.byTooltip('Listening stats'), findsNothing);
        expect(find.byTooltip('Choose channels'), findsNothing);
        expect(find.byKey(const ValueKey('library-counts')), findsOneWidget);
        expect(find.byTooltip('Refresh library').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Sort Library').hitTestable(), findsOneWidget);
        expect(
          tester.getRect(find.byTooltip('Sort Library')).right,
          inInclusiveRange(
            tester.getRect(find.byType(TextField).first).right - 8,
            tester.getRect(find.byType(TextField).first).right,
          ),
          reason: '$size keeps Library actions at the right edge',
        );
        expect(find.text('Refresh library'), findsNothing);

        expect(
          find.byType(NavigationBar),
          size.width < 900 ? findsOneWidget : findsNothing,
        );
        expect(find.byKey(const ValueKey('volume-slider')), findsOneWidget);
        final seek = find.byKey(const ValueKey('playback-seek'));
        expect(
          tester.widget<Slider>(seek).secondaryTrackValue,
          isNull,
          reason:
              'Only played progress is shown, even with audio buffered ahead',
        );
        await tester.tapAt(tester.getCenter(seek) + const Offset(18, 0));
        await tester.pumpAndSettle();
        expect(audio.position, greaterThan(const Duration(minutes: 2)));
        final beforeKey = audio.position;
        final focus = tester.widget<FocusableActionDetector>(
          find
              .descendant(
                of: seek,
                matching: find.byType(FocusableActionDetector),
              )
              .first,
        );
        focus.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(audio.position, greaterThan(beforeKey));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          'Library',
        );
        await tester.tap(find.byKey(const ValueKey('open-current-track')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          'Now playing',
        );
        expect(audio.playing, isTrue);
        expect(find.byTooltip('Listening stats'), findsNothing);
        expect(find.text('FLAC'), findsNothing);
        expect(tester.takeException(), isNull, reason: '$size Now Playing');
        final layout = find.byKey(const ValueKey('now-playing-layout'));
        final pageBounds = tester.getRect(layout).inflate(.1);
        final controls = [
          find.byKey(const ValueKey('now-playing-play-pause')),
          find.byKey(const ValueKey('now-playing-shuffle')),
          find.byKey(const ValueKey('now-playing-repeat')),
          find.byKey(const ValueKey('now-playing-favorite')),
          find.byTooltip('Lyrics').last,
          find.byTooltip('Add to playlist').last,
          find.byKey(const ValueKey('sleep-timer-control')),
          find.byKey(const ValueKey('volume-slider')),
          find.byTooltip('Previous track'),
          find.byTooltip('Next track'),
        ];
        for (final target in [
          find.byKey(const ValueKey('now-playing-artwork')),
          ...controls,
        ]) {
          final bounds = tester.getRect(target);
          expect(
            pageBounds.contains(bounds.topLeft) &&
                pageBounds.contains(bounds.bottomRight),
            isTrue,
            reason: '$size keeps artwork and every control inside the page',
          );
          expect(
            target.hitTestable(),
            findsOneWidget,
            reason: '$size every player control must remain reachable',
          );
        }
        expect(
          find.byKey(const ValueKey('player-bar')),
          findsNothing,
          reason: 'Full Now Playing owns its controls without a second dock',
        );
        expect(find.byKey(const ValueKey('playback-seek')), findsOneWidget);
        expect(
          find.descendant(of: layout, matching: find.byType(Scrollable)),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('now-playing-queue')),
          findsNothing,
        );
        if (size.width >= 760 && size.height >= 650) {
          final next = find.byKey(const ValueKey('now-playing-next-0'));
          expect(
            next.hitTestable(),
            findsOneWidget,
            reason: '$size must show the next song',
          );
          final page = tester.getRect(layout), row = tester.getRect(next);
          expect(row.bottom, lessThanOrEqualTo(page.bottom));
          expect(row.top, greaterThanOrEqualTo(page.top));
        }
        if (size.width >= 1000 && size.height >= 680) {
          expect(
            tester
                .getSize(find.byKey(const ValueKey('now-playing-artwork')))
                .width,
            greaterThanOrEqualTo(180),
            reason: '$size gives the cover room rather than a tiny thumbnail',
          );
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('now-playing-title')))
                .style!
                .fontSize,
            greaterThanOrEqualTo(28),
            reason: '$size keeps the desktop title readable',
          );
        }
        await tester.tap(find.byKey(const ValueKey('now-playing-play-pause')));
        await tester.pumpAndSettle();
        expect(audio.playing, isFalse);
        await tester.tap(find.byKey(const ValueKey('now-playing-play-pause')));
        await tester.pumpAndSettle();
        expect(audio.playing, isTrue);
        final favorite = settings.favoriteIds.contains(player.current!.id);
        await tester.tap(find.byKey(const ValueKey('now-playing-favorite')));
        await tester.pumpAndSettle();
        expect(settings.favoriteIds.contains(player.current!.id), !favorite);
        final repeat = player.repeatMode;
        await tester.tap(find.byKey(const ValueKey('now-playing-repeat')));
        await tester.pumpAndSettle();
        expect(player.repeatMode, isNot(repeat));
        final fullSeek = tester.widget<Slider>(
          find.byKey(const ValueKey('playback-seek')),
        );
        expect(fullSeek.secondaryTrackValue, isNull);
        fullSeek.onChanged!(.25);
        await tester.pumpAndSettle();
        expect(audio.position, const Duration(minutes: 1));
        final artPosition = tester.getRect(
          find.byKey(const ValueKey('now-playing-artwork')),
        );
        await tester.dragFrom(
          tester.getCenter(find.byKey(const ValueKey('now-playing-artwork'))),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('now-playing-artwork'))),
          artPosition,
        );
        if ([360, 390, 844, 1000, 1280, 1920].contains(size.width.toInt())) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final suffix = size == const Size(1280, 714)
                ? '1280-714'
                : '${size.width.toInt()}';
            await File('docs/screenshots/now-playing-$suffix.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byTooltip('Settings').first);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          'Settings',
        );
        expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull, reason: '$size Settings');
        await tester.tap(find.byTooltip('Back to Library'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Telegram').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size Telegram');
        final channel = find.widgetWithText(
          CheckboxListTile,
          'Music channel',
        );
        await tester.scrollUntilVisible(
          channel,
          80,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('telegram-channels')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(channel.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size channel list');
        await tester.tap(find.byTooltip('Library').first);
        await tester.pumpAndSettle();
        if (size.width == 360 || size.width == 1280) {
          settings.reducedMotion = false;
          await player.setVolume(settings.volume, persist: false);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 220));
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('docs/screenshots/adaptive-${size.width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          settings.reducedMotion = true;
          await player.setVolume(settings.volume, persist: false);
          await tester.pumpAndSettle();
        }
      }
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final (size, scale) in [
        (const Size(760, 650), 1.3),
        (const Size(360, 480), 1.8),
        (const Size(390, 844), 2.0),
        (const Size(844, 390), 1.3),
      ]) {
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpAndSettle();
        if (find
            .byKey(const ValueKey('now-playing-play-pause'))
            .evaluate()
            .isEmpty) {
          await tester.tap(find.byTooltip('Now playing').first);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull, reason: '$size at $scale text');
        for (final key in [
          'now-playing-play-pause',
          'volume-slider',
          'sleep-timer-control',
        ]) {
          expect(
            find.byKey(ValueKey(key)).hitTestable(),
            findsOneWidget,
            reason: '$size at $scale text keeps $key reachable',
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
