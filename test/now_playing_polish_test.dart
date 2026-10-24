import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/lyrics_view.dart';
import 'package:auralis/models.dart';
import 'package:auralis/now_playing_effects.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  Future<(FakeAudio, PlayerController)> mount(
    WidgetTester tester, {
    bool reduced = false,
    bool openPlayer = true,
    Size size = const Size(1280, 714),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final cover = File('test/fixtures/cover.png').readAsBytesSync();
    // Image decoding uses the engine, so finish it outside the fake test clock.
    // Reuse these exact bytes so the app resolves the cached MemoryImage and
    // cancels ColorScheme's image-load timeout synchronously.
    await tester.runAsync(() => ColorScheme.fromImageProvider(
      provider: MemoryImage(cover),
      brightness: Brightness.dark,
    ));
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
              coverPreview: cover,
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
    if (openPlayer) {
      await tester.tap(find.byKey(const ValueKey('open-current-track')));
      await tester.pumpAndSettle();
    }
    return (audio, player);
  }

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets('compact controls remain usable at $size', (tester) async {
      final (audio, player) = await mount(tester, reduced: true, size: size);
      expect(find.text('MP3'), findsNothing);
      final play = find.byKey(const ValueKey('now-playing-play-pause'));
      final bounds = tester.getSize(play);
      expect(bounds.width, bounds.height);
      expect(bounds.width, inInclusiveRange(48, 64));
      expect(play.hitTestable(), findsOneWidget);
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(audio.playing, isTrue);
      await tester.tap(find.byKey(const ValueKey('now-playing-repeat')));
      await tester.pumpAndSettle();
      expect(player.repeatMode, PlaybackRepeat.all);
      await tester.tap(find.byKey(const ValueKey('now-playing-favorite')));
      await tester.pumpAndSettle();
      expect(player.settings.favoriteIds, contains('first'));

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

  testWidgets('large desktop keeps the open artwork layout and compact modes', (
    tester,
  ) async {
    await mount(tester, reduced: true, size: const Size(1600, 1000));
    expect(find.byKey(const ValueKey('now-playing-control-card')), findsNothing);
    for (final action in ['shuffle', 'repeat', 'favorite']) {
      final button = find.byKey(ValueKey('now-playing-$action'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getSize(button), const Size(48, 48));
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets('artwork swipes switch songs and respect queue edges at $size', (tester) async {
      final (_, player) = await mount(tester, reduced: true, size: size);
      final artwork = find.byKey(const ValueKey('now-playing-artwork'));
      await tester.drag(artwork, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'second');
      await tester.drag(artwork, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'second');
      await player.audio.seek(const Duration(seconds: 40));
      await tester.drag(artwork, const Offset(180, 0));
      await tester.pumpAndSettle();
      // A cover swipe selects the previous song even after the first 3 seconds.
      expect(player.current?.id, 'first');
      await tester.drag(artwork, const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'first');
      await tester.drag(artwork, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'first');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('artwork wheel gestures coalesce inertia and allow deliberate reversal', (tester) async {
    var next = 0, previous = 0;
    await tester.pumpWidget(MaterialApp(home: Center(
      child: SizedBox.square(dimension: 240, child: ArtworkTrackSwitcher(
        identity: 'cover',
        reducedMotion: true,
        onNext: () => next++,
        onPrevious: () => previous++,
        child: const ColoredBox(color: Colors.pink),
      )),
    )));
    final cover = find.byType(ArtworkTrackSwitcher);
    void wheel(Offset delta, int milliseconds) {
      tester.binding.handlePointerEvent(PointerScrollEvent(
        position: tester.getCenter(cover),
        scrollDelta: delta,
        timeStamp: Duration(milliseconds: milliseconds),
      ));
    }
    wheel(const Offset(0, 24), 0);
    wheel(const Offset(0, 30), 10);
    wheel(const Offset(0, 90), 30);
    wheel(const Offset(0, 40), 60);
    expect(next, 1);
    wheel(const Offset(0, 60), 400);
    expect(next, 2);
    wheel(const Offset(-60, 0), 410);
    expect(previous, 1);
    await tester.timedDrag(cover, const Offset(30, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(previous, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lyric waiting animation pauses, respects reduced motion and stops offscreen', (tester) async {
    Widget indicator({bool playing = true, bool reduced = false, bool visible = true}) => MaterialApp(
      home: TickerMode(enabled: visible, child: LyricsWaitingIndicator(
        playing: playing,
        reducedMotion: reduced,
        label: 'Waiting for lyrics',
      )),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.pumpWidget(indicator());
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(indicator(playing: false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(indicator(reduced: true));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(indicator(visible: false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(indicator());
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pumpWidget(indicator());
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artwork setup permits immediate disposal without a pending image timeout', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // The binding also verifies that no fake timers remain after this test.
    expect(tester.takeException(), isNull);
  });

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
    await tester.tap(find.byTooltip('Telegram').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
      'Telegram',
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

  testWidgets('system Back leaves lyrics and Now Playing without exiting or stopping music', (
    tester,
  ) async {
    var exits = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final (audio, player) = await mount(
      tester,
      reduced: true,
      size: const Size(390, 844),
    );
    await audio.toggle();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lyrics').last);
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsNothing);
    expect(find.byKey(const ValueKey('now-playing-play-pause')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data, 'Library');
    expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
    expect(player.current?.id, 'first');
    expect(audio.playing, isTrue);
    expect(exits, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings is a selected full page and system Back returns to Library', (
    tester,
  ) async {
    await mount(
      tester,
      reduced: true,
      openPlayer: false,
      size: const Size(390, 844),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-page')).hitTestable(), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 3);
    expect(find.byTooltip('Play queue'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data, 'Library');
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom navigation keeps four labels and icons clear of the gesture area', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await mount(
      tester,
      reduced: true,
      openPlayer: false,
      size: const Size(360, 780),
    );
    final navigation = find.byKey(const ValueKey('app-navigation'));
    final bounds = tester.getRect(navigation);
    final destinations = find.descendant(
      of: navigation,
      matching: find.byType(NavigationDestination),
    );
    expect(destinations, findsNWidgets(4));
    for (final label in ['Library', 'Telegram', 'Now playing', 'Settings']) {
      final destination = find.widgetWithText(NavigationDestination, label);
      final icon = find.descendant(of: destination, matching: find.byType(Icon));
      final text = find.descendant(of: destination, matching: find.text(label));
      final labelBounds = tester.getRect(text);
      expect(text.hitTestable(), findsOneWidget);
      expect(labelBounds.top, greaterThanOrEqualTo(tester.getRect(icon).bottom));
      expect(labelBounds.bottom, lessThanOrEqualTo(bounds.bottom - 24));
    }
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
