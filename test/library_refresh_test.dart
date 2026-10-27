import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/app.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/media_cache.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class RefreshTelegram extends TelegramService {
  RefreshTelegram(this.disk, this.tracks, this.png)
    : super(Directory('unused'), MemoryVault(), transport: FakeTd());
  final MediaCache disk;
  final List<Track> tracks;
  final Uint8List png;
  final artworkRequests = <String>[], lyricRequests = <String>[];
  Completer<void>? pause;
  int scans = 0, checks = 0;
  @override
  bool get ready => true;
  @override
  MediaCache get mediaCache => disk;
  @override
  Future<MusicChat?> channel(int id) async => const MusicChat(1, 'Music');
  @override
  Future<({List<Track> tracks, int nextMessageId})> music(
    int chatId,
    String title, {
    int before = 0,
    bool documents = false,
  }) async {
    scans++;
    return (
      tracks: documents ? <Track>[] : List<Track>.of(tracks),
      nextMessageId: 0,
    );
  }

  @override
  Future<bool> hasCachedCover(Track track) {
    checks++;
    return super.hasCachedCover(track);
  }

  // Visible rows are independent of the explicit refresh cache job.
  @override
  Future<Uint8List?> cover(Track track) async => null;
  @override
  Future<Uint8List?> cacheCover(
    Track track, {
    required bool Function() active,
  }) async {
    artworkRequests.add(track.id);
    await pause?.future;
    if (!active()) return null;
    await disk.write(track, 'art', png);
    return png;
  }

  @override
  Future<Lyrics?> embeddedLyrics(Track track) async {
    lyricRequests.add(track.id);
    return Lyrics.parse('[00:01]Words for ${track.id}', embedded: true);
  }
}

void main() {
  testWidgets(
    'refresh queues only missing media and preserves saved files across repeats and restart',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final png = File('test/fixtures/cover.png').readAsBytesSync();
      Track song(int i) => Track(
        id: '$i',
        title: 'Song $i',
        artist: 'Artist',
        source: 'Music',
        fileId: i + 1,
      );
      final tracks = List.generate(43, song);
      late Directory directory;
      late MediaCache disk;
      final stamps = <String, DateTime>{};
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('auralis-refresh-');
        disk = MediaCache(directory);
        final writer = LyricsRepository(cache: () => disk);
        for (var i = 0; i < 43; i++) {
          if (i < 40 || i == 41) {
            await disk.write(tracks[i], 'art', png);
          }
          if (i < 40 || i == 40) {
            await writer.persist(tracks[i], Lyrics.parse('[00:01]Saved $i'));
          }
        }
        writer.close();
        await for (final file in directory.list()) {
          await File(file.path).setLastModified(DateTime(2000));
          stamps[file.path] = await File(file.path).lastModified();
        }
      });
      final settings = MemorySettings()
        ..artworkPreload = 0
        ..automaticLyrics = false
        ..selectedChannels = [const MusicChat(1, 'Music')];
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = RefreshTelegram(disk, tracks, png);
      addTearDown(() async {
        if (telegram.pause?.isCompleted == false) telegram.pause!.complete();
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 300 && MediaCache.hasPending(directory); i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        await tester.runAsync(() async {
          await player.shutdown();
          await telegram.shutdown();
          await MediaCache.drain(directory);
          await directory.delete(recursive: true);
        });
      });
      final counts = <String>[];
      Future<void> until(bool Function() complete) async {
        for (var i = 0; i < 1500; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          final label = find.byKey(const ValueKey('library-counts'));
          if (label.evaluate().isNotEmpty) {
            counts.add(tester.widget<Text>(label).data!);
          }
          if (complete()) return;
        }
        fail(
          'Refresh did not finish: scans=${telegram.scans}, checks=${telegram.checks}, artwork=${telegram.artworkRequests}, lyrics=${telegram.lyricRequests}, counts=${counts.isEmpty ? '' : counts.last}',
        );
      }

      bool caching() => tester
          .widget<Text>(find.byKey(const ValueKey('library-counts')))
          .data!
          .startsWith('Caching');
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      telegram.pause = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('library-refresh')));
      await until(() => telegram.artworkRequests.isNotEmpty);
      expect(find.text('Caching 0 / 3'), findsOneWidget);
      telegram.pause!.complete();
      await until(() => telegram.lyricRequests.length == 2 && !caching());
      expect(telegram.artworkRequests, ['40', '42']);
      expect(telegram.lyricRequests, ['41', '42']);
      await until(() => !MediaCache.hasPending(directory));
      for (final entry in stamps.entries) {
        expect(
          await tester.runAsync(() => File(entry.key).lastModified()),
          entry.value,
        );
      }
      Future<void> fullyCachedRefresh() async {
        counts.clear();
        final scans = telegram.scans, checks = telegram.checks;
        await tester.tap(find.byKey(const ValueKey('library-refresh')));
        await until(
          () =>
              telegram.scans > scans &&
              telegram.checks >= checks + tracks.length,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(counts.where((text) => text.startsWith('Caching')), isEmpty);
        expect(telegram.artworkRequests, ['40', '42']);
        expect(telegram.lyricRequests, ['41', '42']);
      }

      await fullyCachedRefresh();
      // Recreate the repository, then verify all 43 disk entries (beyond its 32-item memory limit).
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      await fullyCachedRefresh();
      tracks.add(song(43));
      telegram.pause = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('library-refresh')));
      await until(() => telegram.artworkRequests.length == 3);
      expect(find.text('Caching 0 / 1'), findsOneWidget);
      telegram.pause!.complete();
      await until(() => telegram.lyricRequests.length == 3 && !caching());
      expect(telegram.artworkRequests.last, '43');
      expect(telegram.lyricRequests.last, '43');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
