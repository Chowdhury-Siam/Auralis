import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _MusicTelegram extends TelegramService {
  _MusicTelegram(this.tracks)
    : super(Directory('unused'), MemoryVault(), transport: FakeTd());
  final List<Track> tracks;
  @override
  bool get ready => true;
  @override
  Future<MusicChat?> channel(int id) async => const MusicChat(1, 'Music');
  @override
  Future<({List<Track> tracks, int nextMessageId})> music(
    int chatId,
    String title, {
    int before = 0,
    bool documents = false,
  }) async => (tracks: documents ? <Track>[] : tracks, nextMessageId: 0);
  @override
  Future<Uint8List?> cover(Track track) async => null;
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Segoe UI',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(360, 480), 2.0),
  ]) {
    testWidgets('Music rows keep only the actions menu at $size / $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final tracks = List.generate(
        4,
        (index) => Track(
          id: '1:$index',
          title: 'Song $index',
          artist: 'Artist',
          source: 'Music',
          duration: const Duration(minutes: 3, seconds: 42),
        ),
      );
      final settings = MemorySettings()
        ..reducedMotion = true
        ..automaticLyrics = false
        ..selectedChannels = [const MusicChat(1, 'Music')];
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = _MusicTelegram(tracks);
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();

      void checkRows() {
        var count = 0;
        for (final track in tracks) {
          final title = find.byKey(ValueKey('track-title-${track.id}'));
          if (title.evaluate().isEmpty) continue;
          final row = find.ancestor(of: title, matching: find.byType(ListTile));
          final tile = tester.widget<ListTile>(row);
          expect(tile.onTap, isNotNull);
          expect(tile.trailing, isA<IconButton>());
          expect(
            find.descendant(of: row, matching: find.byType(IconButton)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: row,
              matching: find.byIcon(Icons.more_vert_rounded),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.text('3:42')),
            findsNothing,
          );
          count++;
        }
        expect(count, greaterThan(0));
        expect(find.byTooltip(RegExp(r'^Add .* to queue$')), findsNothing);
      }

      Future<void> tapVisible(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tester.scrollUntilVisible(
        find.text('Daily Mix'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('home-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Daily Mix'), findsOneWidget);
      checkRows();
      final actions = find.byTooltip('Track actions for ${tracks.first.title}');
      await tapVisible(actions);
      await tapVisible(find.text('Info'));
      expect(find.text('Duration'), findsOneWidget);
      expect(find.text('3:42'), findsOneWidget);
      await tapVisible(find.byTooltip('Close actions'));
      await tapVisible(actions);
      await tapVisible(find.byKey(const ValueKey('media-action-queue')));
      expect(player.queue, [tracks.first]);
      expect(audio.playing, isFalse);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Library').first);
      await tester.pumpAndSettle();
      expect(find.text('Search your music'), findsOneWidget);
      checkRows();
      await tapVisible(actions);
      await tapVisible(find.byKey(const ValueKey('media-action-next')));
      expect(player.queue, [tracks.first, tracks.first]);
      expect(audio.playing, isFalse);
      checkRows();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
