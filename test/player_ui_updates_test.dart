import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_view.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/wave_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const track = Track(
  id: 'one',
  title: 'Kept song',
  artist: 'Artist',
  source: 'Music',
);

void main() {
  test('structural UI relay preserves all existing events without forwarding progress ticks', () async {
    final audio = FakeAudio();
    final player = PlayerController(
      audio,
      TelegramStreamProxy((_) async => {}),
      MemorySettings(),
    );
    addTearDown(player.shutdown);
    var all = 0, structure = 0;
    player.addListener(() => all++);
    player.viewChanges.addListener(() => structure++);
    for (var i = 1; i <= 100; i++) {
      audio.position = Duration(milliseconds: i * 20);
      audio.buffered = Duration(seconds: i);
      audio.notifyListeners();
    }
    expect(
      all,
      100,
      reason: 'Lyrics, stats and sync listeners keep every event.',
    );
    expect(structure, 0);
    for (final change in <VoidCallback>[
      () => audio.playing = true,
      () => audio.buffering = true,
      () => audio.duration = const Duration(minutes: 3),
      () => audio.error = 'Visible failure',
    ]) {
      final before = structure;
      change();
      audio.notifyListeners();
      expect(structure, before + 1);
    }
    final before = structure;
    player.settings.reducedMotion = true;
    player.notifyListeners();
    expect(
      structure,
      before + 1,
      reason: 'Explicit state/settings updates are never filtered.',
    );
    expect(all, 105);
  });

  testWidgets(
    'native progress updates seek bars without rebuilding library, artwork or backdrop',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final audio = FakeAudio()
        ..playing = true
        ..duration = const Duration(seconds: 100);
      final player =
          PlayerController(
              audio,
              TelegramStreamProxy((_) async => {}),
              MemorySettings()
                ..automaticLyrics = false
                ..automaticTranslation = false,
            )
            ..queue.add(track)
            ..index = 0;
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerShell(player: player, telegram: telegram),
        ),
      );
      // Playback's decorative wave intentionally keeps animating.
      Future<void> settleTransition() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }

      await settleTransition();
      final origin = find.byKey(
        const ValueKey('player-origin-page'),
        skipOffstage: false,
      );
      final libraryLayer = tester.widget<RepaintBoundary>(origin);
      final libraryTitle = tester.widget<Text>(find.text('All songs'));
      for (var i = 1; i <= 20; i++) {
        audio.position = Duration(milliseconds: i * 500);
        audio.buffered = Duration(seconds: 30 + i);
        audio.notifyListeners();
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<RepaintBoundary>(origin), same(libraryLayer));
        expect(tester.widget<Text>(find.text('All songs')), same(libraryTitle));
      }
      expect(
        tester.widget<WaveSeekBar>(find.byType(WaveSeekBar).first).value,
        .1,
      );
      await tester.tap(find.byKey(const ValueKey('open-current-track')));
      await settleTransition();
      final artwork = find.byKey(const ValueKey('now-playing-artwork'));
      final backdrop = find.byKey(const ValueKey('now-playing-backdrop'));
      final coverWidget = tester.widget(artwork),
          backdropWidget = tester.widget(backdrop);
      for (var i = 1; i <= 20; i++) {
        audio.position = Duration(seconds: 10 + i);
        audio.notifyListeners();
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget(artwork), same(coverWidget));
        expect(tester.widget(backdrop), same(backdropWidget));
      }
      expect(
        tester.widget<WaveSeekBar>(find.byType(WaveSeekBar).first).value,
        .3,
      );
      expect(
        find.descendant(
          of: origin,
          matching: find.byType(SnapshotWidget, skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
      audio.buffering = true;
      audio.notifyListeners();
      await tester.pump();
      expect(
        tester.widget(artwork),
        isNot(same(coverWidget)),
        reason: 'Real playback state still refreshes controls.',
      );
      audio.buffering = false;
      audio.notifyListeners();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('close-now-playing')));
      await settleTransition();
      expect(
        tester.widget<WaveSeekBar>(find.byType(WaveSeekBar).first).value,
        .3,
      );
      expect(audio.playing, isTrue);
      expect(player.current, same(track));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Home listening stats stay live without rebuilding the daily mix',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final audio = FakeAudio();
      final settings = MemorySettings()..reducedMotion = true;
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerShell(
            player: player,
            telegram: telegram,
            startOnHome: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final home = find.byKey(const PageStorageKey('home-scroll'));
      final homeWidget = tester.widget(home);
      expect(find.text('0s'), findsOneWidget);
      settings.listening.record(track, 60000, 1, DateTime.now());
      audio.position = const Duration(seconds: 1);
      audio.notifyListeners();
      await tester.pump();
      expect(find.text('1m 0s'), findsOneWidget);
      expect(find.text('1 plays · 1 tracks'), findsOneWidget);
      expect(tester.widget(home), same(homeWidget));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Lyrics follows native position changes without rebuilding its parent shell',
    (tester) async {
      final audio = FakeAudio()..duration = const Duration(seconds: 100);
      final player =
          PlayerController(
              audio,
              TelegramStreamProxy((_) async => {}),
              MemorySettings()
                ..automaticLyrics = false
                ..automaticTranslation = false
                ..reducedMotion = true,
            )
            ..queue.add(track)
            ..index = 0;
      final lyrics = LyricsRepository()
        ..save(track, Lyrics.parse('[00:00]First line\n[00:10]Second line'));
      addTearDown(player.shutdown);
      addTearDown(lyrics.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricsView(
              player: player,
              repository: lyrics,
              artwork: const Icon(Icons.album),
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final second = find.byKey(const ValueKey('lyric-focus-1'));
      expect(tester.widget<ImageFiltered>(second).enabled, isTrue);
      await audio.seek(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(tester.widget<ImageFiltered>(second).enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
