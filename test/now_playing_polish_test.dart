import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/lyrics_view.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/preference_widgets.dart';
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

class WarmingTelegram extends TelegramService {
  WarmingTelegram(this.bytes)
    : super(Directory('unused'), MemoryVault(), transport: FakeTd());
  final Uint8List bytes;
  final requested = <String>[];
  final warmed = <String>{};
  @override
  bool get ready => true;
  @override
  Future<Uint8List?> cover(Track track) async => bytes;
  @override
  Uint8List? cachedCover(Track track) =>
      warmed.contains(track.id) ? bytes : null;
  @override
  Future<Uint8List?> savedCover(
    Track track, {
    required bool Function() active,
  }) async {
    if (!active()) return null;
    requested.add(track.id);
    warmed.add(track.id);
    return bytes;
  }
}

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
    await tester.runAsync(
      () => ColorScheme.fromImageProvider(
        provider: MemoryImage(cover),
        brightness: Brightness.dark,
      ),
    );
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

  testWidgets(
    'artwork preloads ten upcoming tracks and adapts the queue window',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final bytes = File('test/fixtures/cover.png').readAsBytesSync();
      await tester.runAsync(
        () => ColorScheme.fromImageProvider(
          provider: MemoryImage(bytes),
          brightness: Brightness.dark,
        ),
      );
      final settings = MemorySettings()
        ..reducedMotion = true
        ..automaticLyrics = false;
      final player =
          PlayerController(
              FakeAudio(),
              TelegramStreamProxy((_) async => {}),
              settings,
            )
            ..queue.addAll(
              List.generate(
                16,
                (i) => Track(
                  id: '$i',
                  fileId: i + 1,
                  title: 'Song $i',
                  artist: 'Artist',
                  source: 'Music',
                ),
              ),
            )
            ..index = 0;
      final telegram = WarmingTelegram(bytes);
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      Future<void> finish(int count) async {
        for (var i = 0; i < 100 && telegram.requested.length < count; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      await finish(11);
      expect(telegram.requested, List.generate(11, (i) => '$i'));
      player.index = 1;
      player.notifyListeners();
      await finish(22);
      expect(telegram.warmed, contains('11'));
      expect(telegram.warmed, isNot(contains('12')));
      final dock = find.byKey(const ValueKey('player-bar'));
      final future = find.descendant(
        of: dock,
        matching: find.byType(FutureBuilder<Uint8List?>),
      );
      expect(
        tester.widget<FutureBuilder<Uint8List?>>(future).initialData,
        same(bytes),
      );
      telegram.requested.clear();
      player.index = 15;
      settings.repeatMode = PlaybackRepeat.all;
      player.refreshSettings();
      await finish(11);
      expect(telegram.requested, ['15', ...List.generate(10, (i) => '$i')]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact Settings changes providers without retired artwork controls',
    (tester) async {
      final (_, player) = await mount(
        tester,
        reduced: true,
        openPlayer: false,
        size: const Size(390, 844),
      );
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      expect(find.byType(PreferenceChoice<LyricsSource?>), findsNothing);
      await tester.tap(find.text('Lyrics & artwork'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lyrics & translation'));
      await tester.pumpAndSettle();
      final first = tester.widget<PreferenceChoice<LyricsSource?>>(
        find.byType(PreferenceChoice<LyricsSource?>).first,
      );
      first.onSelected(LyricsSource.lyricsOvh);
      await tester.pumpAndSettle();
      expect(player.settings.lyricsFirst, LyricsSource.lyricsOvh);
      expect(player.settings.lyricsFallback, LyricsSource.lrclib);
      expect(find.text('Artwork'), findsNothing);
      expect(find.text('Preload artwork'), findsNothing);
      expect(find.text('Keep saved artwork'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

      expect(find.byKey(const ValueKey('volume-slider')), findsNothing);
      final shuffle = find.byKey(const ValueKey('now-playing-shuffle'));
      await tester.tap(shuffle);
      await tester.pumpAndSettle();
      expect(player.shuffleEnabled, isTrue);
      expect(tester.widget<IconButton>(shuffle).isSelected, isTrue);
      final favoriteButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('now-playing-favorite')),
      );
      final shuffleButton = tester.widget<IconButton>(shuffle);
      expect(
        shuffleButton.style!.backgroundColor!.resolve({}),
        favoriteButton.style!.backgroundColor!.resolve({}),
      );
      expect(
        shuffleButton.style!.foregroundColor!.resolve({}),
        favoriteButton.style!.foregroundColor!.resolve({}),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('now-playing-container')),
          matching: find.byTooltip('Settings'),
        ),
        findsNothing,
      );
      await tester.tap(shuffle);
      await tester.pumpAndSettle();
      expect(player.shuffleEnabled, isFalse);
      expect(tester.widget<IconButton>(shuffle).isSelected, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large desktop keeps the open artwork layout and compact modes', (
    tester,
  ) async {
    await mount(tester, reduced: true, size: const Size(1600, 1000));
    expect(
      find.byKey(const ValueKey('now-playing-control-card')),
      findsNothing,
    );
    for (final action in ['shuffle', 'repeat', 'favorite']) {
      final button = find.byKey(ValueKey('now-playing-$action'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getSize(button), const Size(48, 48));
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets('artwork swipes switch songs and respect queue edges at $size', (
      tester,
    ) async {
      final (_, player) = await mount(tester, reduced: true, size: size);
      final artwork = find.byKey(const ValueKey('now-playing-artwork'));
      await tester.drag(artwork, const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'second');
      await tester.drag(artwork, const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'second');
      await player.audio.seek(const Duration(seconds: 40));
      await tester.drag(artwork, const Offset(280, 0));
      await tester.pumpAndSettle();
      // A cover swipe selects the previous song even after the first 3 seconds.
      expect(player.current?.id, 'first');
      await tester.drag(artwork, const Offset(280, 0));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'first');
      await tester.drag(artwork, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(player.current?.id, 'first');
      player.settings.repeatMode = PlaybackRepeat.all;
      await player.playAt(1);
      await tester.pumpAndSettle();
      await tester.drag(artwork, const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(
        player.current?.id,
        'first',
        reason: 'Repeat wraps the cover carousel',
      );
      expect(artwork.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('artwork pages reveal full covers and follow transport changes', (
    tester,
  ) async {
    var selected = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: SizedBox.square(
                dimension: 240,
                child: ArtworkPager(
                  index: selected,
                  itemCount: 3,
                  onSelected: (index) => setState(() => selected = index),
                  itemBuilder: (_, index) => ColoredBox(
                    key: ValueKey('test-cover-$index'),
                    color: [Colors.red, Colors.green, Colors.blue][index],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    final pager = find.byType(ArtworkPager);
    final viewport = tester.getRect(pager);
    final gesture = await tester.startGesture(viewport.center);
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    final next = tester.getRect(find.byKey(const ValueKey('test-cover-1')));
    expect(next.size, viewport.size);
    expect(
      next.intersect(viewport).width,
      greaterThan(80),
      reason: 'The next cover follows the finger beyond a fixed narrow preview',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(
      tester.getRect(find.byKey(const ValueKey('test-cover-1'))),
      viewport,
    );

    // Small drags snap back, while transport changes synchronize the page.
    await tester.timedDrag(
      pager,
      const Offset(-30, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(
      tester.getRect(find.byKey(const ValueKey('test-cover-1'))),
      viewport,
    );
    update(() => selected = 2);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('test-cover-2'))),
      viewport,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'artwork wheel gestures coalesce inertia and allow deliberate reversal',
    (tester) async {
      var next = 0, previous = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 240,
              child: ArtworkTrackSwitcher(
                identity: 'cover',
                reducedMotion: true,
                onNext: () => next++,
                onPrevious: () => previous++,
                child: const ColoredBox(color: Colors.pink),
              ),
            ),
          ),
        ),
      );
      final cover = find.byType(ArtworkTrackSwitcher);
      void wheel(Offset delta, int milliseconds) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: tester.getCenter(cover),
            scrollDelta: delta,
            timeStamp: Duration(milliseconds: milliseconds),
          ),
        );
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
      await tester.timedDrag(
        cover,
        const Offset(30, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(previous, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lyric waiting animation pauses, respects reduced motion and stops offscreen',
    (tester) async {
      Widget indicator({
        bool playing = true,
        bool reduced = false,
        bool visible = true,
      }) => MaterialApp(
        home: TickerMode(
          enabled: visible,
          child: LyricsWaitingIndicator(
            playing: playing,
            reducedMotion: reduced,
            label: 'Waiting for lyrics',
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
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
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
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
    },
  );

  testWidgets(
    'artwork setup permits immediate disposal without a pending image timeout',
    (tester) async {
      await mount(tester, reduced: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      // The binding also verifies that no fake timers remain after this test.
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets('mini-player grows into Now Playing and reopens at $size', (
      tester,
    ) async {
      final (audio, player) = await mount(
        tester,
        openPlayer: false,
        size: size,
      );
      final surface = find.byKey(const ValueKey('now-playing-container'));
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byKey(const ValueKey('open-current-track')));
        await tester.pump();
        final start = tester.getRect(surface);
        expect(start.height, lessThan(150));
        expect(start.top, greaterThan(size.height * .5));
        await tester.pump(const Duration(milliseconds: 150));
        final middle = tester.getRect(surface);
        expect(middle.height, greaterThan(start.height));
        expect(middle.top, lessThan(start.top));
        expect(
          find.byKey(const ValueKey('player-transition-blur')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('open-current-track')).hitTestable(),
          findsNothing,
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<ClipRRect>(surface).borderRadius,
          BorderRadius.zero,
        );
        expect(
          find.byKey(const ValueKey('now-playing-play-pause')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('close-now-playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
      }
      expect(player.current?.id, 'first');
      expect(audio.playing, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets(
      'collapse retains the real dock and settles without a handoff at $size',
      (tester) async {
        final (audio, player) = await mount(
          tester,
          openPlayer: false,
          size: size,
        );
        final dock = find.byKey(const ValueKey('player-bar'));
        final origin = find.byKey(const ValueKey('player-origin-page'));
        final dockElement = tester.element(dock);
        final originElement = tester.element(origin);
        final dockBounds = tester.getRect(dock);
        await tester.tap(find.byKey(const ValueKey('open-current-track')));
        await tester.pumpAndSettle();
        expect(
          identical(
            tester.element(
              find.byKey(const ValueKey('player-bar'), skipOffstage: false),
            ),
            dockElement,
          ),
          isTrue,
          reason: 'Opening retains the existing dock instead of recreating it',
        );
        await tester.tap(find.byKey(const ValueKey('close-now-playing')));
        await tester.pump();
        var previousBlur = 1.0;
        var revealedDock = false;
        // Bound the tail as well as the visible travel: the old transition still
        // blocked the dock after it appeared to have reached its final position.
        for (var frame = 0; frame < 45; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(identical(tester.element(origin), originElement), isTrue);
          expect(identical(tester.element(dock), dockElement), isTrue);
          expect(tester.getRect(dock), dockBounds);
          final blur = find.byKey(
            const ValueKey('player-transition-blur-opacity'),
          );
          if (blur.evaluate().isEmpty) break;
          final opacity = tester.widget<Opacity>(blur).opacity;
          expect(opacity, lessThanOrEqualTo(previousBlur));
          previousBlur = opacity;
          if (opacity == 0) {
            revealedDock = true;
            final cardOpacity = tester
                .widget<Opacity>(
                  find.byKey(const ValueKey('player-transition-card-opacity')),
                )
                .opacity;
            expect(cardOpacity, lessThan(.3));
          }
        }
        expect(
          revealedDock,
          isTrue,
          reason: 'The actual dock is visible before the animation ends',
        );
        expect(
          find.byKey(const ValueKey('now-playing-container')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('open-current-track')).hitTestable(),
          findsOneWidget,
        );
        expect(identical(tester.element(dock), dockElement), isTrue);
        expect(player.current?.id, 'first');
        expect(audio.playing, isFalse);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('automatic expansion advances continuously at frame intervals', (
    tester,
  ) async {
    await mount(tester, openPlayer: false, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('open-current-track')));
    await tester.pump();
    final surface = find.byKey(const ValueKey('now-playing-container'));
    var previous = tester.getRect(surface);
    final initialTop = previous.top;
    var largestStep = 0.0;
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final current = tester.getRect(surface);
      final step = previous.top - current.top;
      expect(step, greaterThanOrEqualTo(-.01));
      if (step > largestStep) largestStep = step;
      expect(current.height, greaterThanOrEqualTo(previous.height - .01));
      previous = current;
    }
    expect(
      largestStep,
      lessThan(initialTop * .09),
      reason: 'No frame jumps across a large part of the expansion',
    );
    expect(previous.top, lessThan(initialTop * .02));
    await tester.pumpAndSettle();
    expect(tester.widget<ClipRRect>(surface).borderRadius, BorderRadius.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'vertical player drags follow the finger and settle in either direction',
    (tester) async {
      final (audio, player) = await mount(
        tester,
        openPlayer: false,
        size: const Size(390, 844),
      );
      final surface = find.byKey(const ValueKey('now-playing-container'));
      var gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('open-current-track'))),
      );
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      final start = tester.getRect(surface);
      final blur = tester
          .widget<ImageFiltered>(
            find.byKey(const ValueKey('player-transition-blur')),
          )
          .imageFilter;
      final cachedPage = tester
          .widget<RepaintBoundary>(
            find.byKey(const ValueKey('player-cached-blur')),
          )
          .child;
      await gesture.moveBy(const Offset(0, -210));
      await tester.pump();
      expect(tester.getRect(surface).height, greaterThan(start.height));
      expect(
        tester.getRect(surface).top,
        closeTo(start.top - 210, .5),
        reason: 'The card follows the finger pixel for pixel without a second easing curve',
      );
      expect(
        identical(
          tester
              .widget<ImageFiltered>(
                find.byKey(const ValueKey('player-transition-blur')),
              )
              .imageFilter,
          blur,
        ),
        isTrue,
      );
      expect(
        identical(
          tester
              .widget<RepaintBoundary>(
                find.byKey(const ValueKey('player-cached-blur')),
              )
              .child,
          cachedPage,
        ),
        isTrue,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('now-playing-play-pause')).hitTestable(),
        findsOneWidget,
      );
      final full = tester.getRect(surface);
      gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('page-title'))),
      );
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(tester.getRect(surface).top, closeTo(full.top + 70, .5));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getRect(surface),
        full,
        reason: 'A short downward drag returns to the full player',
      );
      await tester.drag(
        find.byKey(const ValueKey('page-title')),
        const Offset(0, 320),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
      expect(player.current?.id, 'first');
      expect(audio.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short upward drag returns to the mini-player and resizing stays valid',
    (tester) async {
      await mount(tester, openPlayer: false, size: const Size(390, 844));
      final preview = find.byKey(const ValueKey('open-current-track'));
      var gesture = await tester.startGesture(tester.getCenter(preview));
      await gesture.moveBy(const Offset(0, -25));
      await gesture.moveBy(const Offset(0, -25));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(preview.hitTestable(), findsOneWidget);
      await tester.tap(preview);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('close-now-playing')));
      await tester.pumpAndSettle();
      expect(preview.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the expanding player returns to the page it opened from', (
    tester,
  ) async {
    await mount(tester, openPlayer: false, size: const Size(390, 844));
    await tester.tap(find.byTooltip('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-current-track')));
    await tester.pump();
    final background = find.byKey(const ValueKey('player-collapse-background'));
    expect(
      find.descendant(of: background, matching: find.text('Data & sync')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-now-playing')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
      'Settings',
    );
    expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back interrupts opening without jumping to the top', (
    tester,
  ) async {
    await mount(tester, openPlayer: false, size: const Size(390, 844));
    await tester.tap(find.byTooltip('Now playing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final surface = find.byKey(const ValueKey('now-playing-container'));
    final before = tester.getRect(surface);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      tester.getRect(surface),
      rectMoreOrLessEquals(before, epsilon: .001),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.getRect(surface).top, greaterThan(before.top));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final systemReduced in [false, true]) {
    testWidgets(
      'opening is immediate with reduced motion (system: $systemReduced)',
      (tester) async {
        await mount(tester, reduced: !systemReduced, openPlayer: false);
        if (systemReduced) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await tester.pump();
        }
        await tester.tap(find.byKey(const ValueKey('open-current-track')));
        await tester.pump();
        final surface = find.byKey(const ValueKey('now-playing-container'));
        expect(
          tester.widget<ClipRRect>(surface).borderRadius,
          BorderRadius.zero,
        );
        expect(
          find.byKey(const ValueKey('now-playing-play-pause')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [const Size(390, 844), const Size(1280, 714)]) {
    testWidgets(
      'down arrow reveals Library and mini-player during collapse at $size',
      (tester) async {
        final (audio, player) = await mount(tester, size: size);
        await audio.toggle();
        await tester.pump();
        final artwork = find.byKey(const ValueKey('now-playing-artwork'));
        final before = tester.getTopLeft(artwork);
        await tester.tap(find.byKey(const ValueKey('close-now-playing')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.getTopLeft(artwork).dy, greaterThan(before.dy));
        final background = find.byKey(
          const ValueKey('player-collapse-background'),
        );
        expect(background, findsOneWidget);
        expect(
          find.descendant(of: background, matching: find.text('Library')),
          findsWidgets,
        );
        expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('open-current-track')).hitTestable(),
          findsNothing,
          reason: 'The returning mini-player waits for the animation',
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('close-now-playing')),
              )
              .onPressed,
          isNull,
        );
        await tester.pump(const Duration(milliseconds: 100));
        final surface = find.byKey(const ValueKey('now-playing-container'));
        final fade = tester.widget<Opacity>(
          find.descendant(
            of: surface,
            matching: find.byKey(const ValueKey('now-playing-content-opacity')),
          ),
        );
        expect(fade.opacity, inExclusiveRange(0, 1));
        await tester.pump(const Duration(milliseconds: 180));
        await tester.pump();
        expect(audio.playing, isTrue, reason: 'Collapsing keeps music playing');
        await audio.toggle();
        await tester.pumpAndSettle();
        expect(background, findsNothing);
        expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          'Library',
        );
        expect(player.current?.id, 'first');
        expect(audio.playing, isFalse);
        expect(
          find.byKey(const ValueKey('open-current-track')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    await mount(tester, reduced: true, openPlayer: false);
    await tester.tap(find.byTooltip('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Reduce motion'), findsNothing);
    expect(find.text('Use instant page transitions'), findsNothing);
    expect(find.text('Data & sync'), findsOneWidget);
    expect(find.text('Lyrics & artwork'), findsOneWidget);
    await tester.tap(find.text('Data & sync'));
    await tester.pumpAndSettle();
    expect(find.text('Listening stats'), findsOneWidget);
    expect(find.text('Backup & Restore'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system Back leaves lyrics and Now Playing without exiting or stopping music',
    (tester) async {
      var exits = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
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
      expect(
        find.byKey(const ValueKey('now-playing-play-pause')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        'Library',
      );
      expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
      expect(player.current?.id, 'first');
      expect(audio.playing, isTrue);
      expect(exits, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Settings is a selected full page and system Back returns to Library',
    (tester) async {
      await mount(
        tester,
        reduced: true,
        openPlayer: false,
        size: const Size(390, 844),
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-page')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
      expect(find.byTooltip('Play queue'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        'Library',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'player background covers the top inset while controls and retained dock stay safe',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final (_, player) = await mount(tester, openPlayer: false);
      // Use a phone viewport, including its status and gesture insets.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      final dock = find.byKey(const ValueKey('player-bar'));
      final originalDock = tester.element(dock);
      final dockBounds = tester.getRect(dock);
      expect(
        tester.getRect(find.byKey(const ValueKey('page-title'))).top,
        greaterThanOrEqualTo(32),
      );
      await tester.tap(find.byKey(const ValueKey('open-current-track')));
      await tester.pumpAndSettle();
      final backdrop = find.byKey(const ValueKey('now-playing-backdrop'));
      expect(tester.getRect(backdrop).top, 0);
      expect(tester.getRect(backdrop).bottom, 844);
      expect(
        tester.getRect(find.byKey(const ValueKey('close-now-playing'))).top,
        greaterThanOrEqualTo(32),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('now-playing-play-pause')))
            .bottom,
        lessThanOrEqualTo(844 - 24),
      );
      final shell = tester.state(find.byType(PlayerShell)) as dynamic;
      (shell.lyrics as LyricsRepository).save(
        player.current!,
        Lyrics.parse('[00:01]First line\n[00:03]Second line'),
      );
      await tester.tap(find.byTooltip('Lyrics').first);
      await tester.pumpAndSettle();
      expect(tester.getRect(backdrop).top, 0);
      expect(
        tester.getRect(find.byKey(const ValueKey('lyrics-back'))).top,
        greaterThanOrEqualTo(32),
      );
      await tester.tap(find.byKey(const ValueKey('lyrics-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('close-now-playing')));
      await tester.pump();
      for (var frame = 0; frame < 45; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(dock), dockBounds);
        expect(identical(tester.element(dock), originalDock), isTrue);
      }
      expect(find.byKey(const ValueKey('now-playing-container')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('open-current-track')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(844, 390);
      tester.view.padding = const FakeViewPadding(
        top: 24,
        left: 32,
        bottom: 16,
      );
      tester.view.viewPadding = const FakeViewPadding(
        top: 24,
        left: 32,
        bottom: 16,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(backdrop).top, 0);
      expect(
        tester.getRect(find.byKey(const ValueKey('close-now-playing'))).top,
        greaterThanOrEqualTo(24),
      );
      await tester.tap(find.byKey(const ValueKey('close-now-playing')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('page-title'))).top,
        greaterThanOrEqualTo(24),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'bottom navigation keeps four labels and icons clear of the gesture area',
    (tester) async {
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
        final icon = find.descendant(
          of: destination,
          matching: find.byType(Icon),
        );
        final text = find.descendant(
          of: destination,
          matching: find.text(label),
        );
        final labelBounds = tester.getRect(text);
        expect(text.hitTestable(), findsOneWidget);
        expect(
          labelBounds.top,
          greaterThanOrEqualTo(tester.getRect(icon).bottom),
        );
        expect(labelBounds.bottom, lessThanOrEqualTo(bounds.bottom - 24));
      }
      expect(tester.takeException(), isNull);
    },
  );

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

  for (final size in [const Size(1000, 680), const Size(1280, 714)]) {
    testWidgets(
      'desktop artwork stays inside its rounded frame on hover at $size',
      (tester) async {
        final (_, player) = await mount(tester, size: size);
        final artwork = find.byKey(const ValueKey('now-playing-artwork'));
        final pager = find.byKey(const ValueKey('artwork-pages'));
        final frame = find
            .ancestor(of: artwork, matching: find.byType(DecoratedBox))
            .first;
        final originalArtwork = tester.getRect(artwork);
        final originalFrame = tester.getRect(frame);
        final decoration = tester.widget<DecoratedBox>(frame).decoration;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1, 1));
        for (final position in [
          originalArtwork.center,
          originalArtwork.topLeft + const Offset(10, 10),
          originalArtwork.topRight + const Offset(-10, 10),
          originalArtwork.bottomRight - const Offset(10, 10),
          originalArtwork.bottomLeft + const Offset(10, -10),
          const Offset(1, 1),
        ]) {
          await mouse.moveTo(position);
          await tester.pumpAndSettle();
          expect(tester.getRect(artwork), originalArtwork);
          expect(tester.getRect(frame), originalFrame);
          expect(tester.getRect(pager).contains(originalFrame.topLeft), isTrue);
          expect(
            tester
                .getRect(pager)
                .contains(originalFrame.bottomRight - const Offset(.01, .01)),
            isTrue,
          );
          expect(tester.widget<DecoratedBox>(frame).decoration, decoration);
          expect(player.current?.id, 'first');
          expect(tester.takeException(), isNull);
        }
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
