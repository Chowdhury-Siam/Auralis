import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/now_playing_effects.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  Future<(FakeAudio, PlayerController)> mount(
    WidgetTester tester, {
    bool reduced = false,
    Size size = const Size(1280, 714),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final audio = FakeAudio();
    final settings = MemorySettings()..reducedMotion = reduced;
    final player =
        PlayerController(audio, TelegramStreamProxy((_) async => {}), settings)
          ..queue.addAll([
            Track(
              id: 'first',
              title: 'First song',
              artist: 'Artist',
              source: 'Library',
              coverPreview: File('test/fixtures/cover.png').readAsBytesSync(),
            ),
            const Track(
              id: 'second',
              title: 'Second song',
              artist: 'Artist',
              source: 'Library',
            ),
          ])
          ..index = 0;
    final telegram = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: FakeTd(),
    );
    addTearDown(player.shutdown);
    addTearDown(telegram.shutdown);
    await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-current-track')));
    await tester.pumpAndSettle();
    return (audio, player);
  }

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets('compact controls remain usable at $size', (tester) async {
      final (audio, _) = await mount(tester, reduced: true, size: size);
      final play = find.byKey(const ValueKey('now-playing-play-pause'));
      final bounds = tester.getSize(play);
      expect(bounds.width, bounds.height);
      expect(bounds.width, inInclusiveRange(48, 64));
      expect(play.hitTestable(), findsOneWidget);
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(audio.playing, isTrue);

      final slider = find.byKey(const ValueKey('volume-slider'));
      final sliderBounds = tester.getRect(slider);
      await tester.tapAt(
        Offset(sliderBounds.left + 12, sliderBounds.center.dy),
      );
      await tester.pumpAndSettle();
      final low = audio.volumes.last;
      await tester.tapAt(
        Offset(sliderBounds.right - 12, sliderBounds.center.dy),
      );
      await tester.pumpAndSettle();
      expect(audio.volumes.last, greaterThan(low));
      expect(audio.playing, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('down arrow slides the whole player before restoring the dock', (
    tester,
  ) async {
    final (audio, player) = await mount(tester);
    final artwork = find.byKey(const ValueKey('now-playing-artwork'));
    final before = tester.getTopLeft(artwork);
    await tester.tap(find.byKey(const ValueKey('close-now-playing')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(artwork).dy, greaterThan(before.dy));
    expect(find.byKey(const ValueKey('player-bar')), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('close-now-playing')))
          .onPressed,
      isNull,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
      'Library',
    );
    expect(player.current?.id, 'first');
    expect(audio.playing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar navigation during dismissal keeps the requested page', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('close-now-playing')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byTooltip('Play queue').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
      'Play queue',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion closes immediately without translating artwork', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await tester.tap(find.byKey(const ValueKey('close-now-playing')));
    await tester.pump();
    expect(find.byKey(const ValueKey('now-playing-backdrop')), findsNothing);
    expect(find.byKey(const ValueKey('now-playing-play-pause')), findsNothing);
    expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('background follows the current cover and falls back safely', (
    tester,
  ) async {
    final (_, player) = await mount(tester, reduced: true);
    Artwork backgroundArtwork() => tester.widget<Artwork>(
      find.descendant(
        of: find.byKey(const ValueKey('now-playing-backdrop')),
        matching: find.byType(Artwork),
      ),
    );
    expect(backgroundArtwork().track?.id, 'first');
    expect(backgroundArtwork().track?.coverPreview, isNotNull);
    player.index = 1;
    player.notifyListeners();
    await tester.pumpAndSettle();
    expect(backgroundArtwork().track?.id, 'second');
    expect(backgroundArtwork().track?.coverPreview, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings keep app features without the retired motion toggle', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await tester.tap(find.byTooltip('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Reduce motion'), findsNothing);
    expect(find.text('Use instant page transitions'), findsNothing);
    expect(find.text('Listening stats'), findsOneWidget);
    expect(find.text('Backup & Restore'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'playback rebuilds reuse the blur while artwork updates stay live',
    (tester) async {
      final ticks = ValueNotifier(0);
      final artworkUpdates = ChangeNotifier();
      addTearDown(ticks.dispose);
      addTearDown(artworkUpdates.dispose);
      var builds = 0;
      var identity = 'first';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: ticks,
              builder: (context, _) => NowPlayingBackdrop(
                identity: identity,
                reducedMotion: true,
                artworkUpdates: artworkUpdates,
                artwork: Builder(
                  builder: (context) {
                    builds++;
                    return const ColoredBox(color: Colors.pink);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = builds;
      for (var i = 0; i < 5; i++) {
        ticks.value++;
        await tester.pump();
      }
      expect(builds, original);
      artworkUpdates.notifyListeners();
      await tester.pumpAndSettle();
      expect(builds, original + 1);
      identity = 'second';
      ticks.value++;
      await tester.pumpAndSettle();
      expect(builds, original + 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final reduced in [false, true]) {
    for (final systemReduced in [false, true]) {
      testWidgets(
        'artwork hover and reset: user=$reduced system=$systemReduced',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: systemReduced),
                child: Center(
                  child: SizedBox.square(
                    dimension: 240,
                    child: ArtworkMotion(
                      reducedMotion: reduced,
                      child: const ColoredBox(color: Colors.pink),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final tilt = find.byKey(const ValueKey('artwork-hover-tilt'));
          final scale = find.byKey(const ValueKey('artwork-hover-scale'));
          final rest = tester.widget<Transform>(tilt).transform.clone();
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(1, 1));
          await mouse.moveTo(tester.getTopRight(tilt) + const Offset(-24, 24));
          await tester.pumpAndSettle();
          if (reduced || systemReduced) {
            expect(tester.widget<Transform>(tilt).transform, rest);
            expect(tester.widget<AnimatedScale>(scale).scale, 1);
          } else {
            expect(tester.widget<Transform>(tilt).transform, isNot(rest));
            expect(tester.widget<AnimatedScale>(scale).scale, greaterThan(1));
          }
          await mouse.moveTo(const Offset(1, 1));
          await tester.pumpAndSettle();
          expect(tester.widget<Transform>(tilt).transform, rest);
          expect(tester.widget<AnimatedScale>(scale).scale, 1);
          await mouse.removePointer();
          expect(tester.binding.hasScheduledFrame, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
