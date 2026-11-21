import 'dart:io';

import 'package:auralis/cache_management.dart';
import 'package:auralis/media_cache.dart';
import 'package:auralis/models.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

void main() {
  test(
    'removing song artwork also removes legacy artwork and leaves lyrics',
    () async {
      final root = await Directory.systemTemp.createTemp('auralis-cache-test-');
      addTearDown(() => root.delete(recursive: true));
      final cache = MediaCache(root);
      const track = Track(
        id: '1:1',
        title: 'Song',
        artist: 'Artist',
        source: 'Channel',
      );
      final keys = cache.keys(track).toList();
      final legacy = await File(p.join(root.path, '${keys.last}.art'))
          .writeAsBytes([1, 2, 3]);
      await cache.write(track, 'art', [4, 5]);
      await cache.write(track, 'art-checked', [6]);
      await cache.write(track, 'lyrics', [7, 8]);
      final unrelated = await File(p.join(root.path, 'library.json'))
          .writeAsString('{}');

      final entries = await musicCacheEntries(cache, [track], () => true);
      final artwork = entries.singleWhere(
        (entry) => entry.category == CacheCategory.artwork,
      );
      expect(artwork.title, 'Song');
      expect(artwork.bytes, 6);
      await artwork.remove();
      expect(await legacy.exists(), isFalse);
      expect(await cache.read(track, 'art', 10), isNull);
      expect(await cache.read(track, 'art-checked', 10), isNull);
      expect(await cache.read(track, 'lyrics', 10), [7, 8]);
      expect(await unrelated.exists(), isTrue);
    },
  );

  test('Telegram cleanup is scoped to the selected mode and guarded during playback', () async {
    final transport = FakeTd();
    final service = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: transport,
    )..state = 'authorizationStateReady';
    addTearDown(service.shutdown);
    transport.onRequest = (request) async {
      if (request['@type'] == 'getStorageStatistics') {
        return {
          'by_chat': [
            {
              'by_file_type': [
                {
                  'file_type': {'@type': 'fileTypeAudio'},
                  'size': 50,
                },
                {
                  'file_type': {'@type': 'fileTypeVideo'},
                  'size': 100,
                },
              ],
            },
          ],
        };
      }
      return null;
    };
    expect(await service.playbackCacheBytes(video: false), 50);
    expect(await service.playbackCacheBytes(video: true), 100);

    service.hasActiveStream = () => true;
    await expectLater(
      service.clearPlaybackCache(video: false),
      throwsStateError,
    );
    expect(
      transport.requests.where((r) => r['@type'] == 'optimizeStorage'),
      isEmpty,
    );
    service.hasActiveStream = () => false;
    await service.clearPlaybackCache(video: true);
    expect(transport.requests.last['file_types'], [
      {'@type': 'fileTypeVideo'},
    ]);
  });

  testWidgets('video cache can delete one thumbnail and keep the rest', (
    tester,
  ) async {
    final entries = <CacheEntry>[];
    for (final id in ['Episode 1', 'Episode 2']) {
      entries.add(
        CacheEntry(
          id: id,
          category: CacheCategory.videoThumbnails,
          title: id,
          bytes: 100,
          remove: () async => entries.removeWhere((entry) => entry.id == id),
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CacheManagement(
            video: true,
            load: () async => (entries: [...entries], message: null),
            prepareRemoval: (_) async {},
            bottomPadding: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('200 B used'), findsOneWidget);
    expect(find.text('Lyrics'), findsNothing);
    await tester.tap(find.text('Video thumbnails'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Episode 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete selected (100 B)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Episode 1'), findsNothing);
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.text('100 B used'), findsOneWidget);
  });
}
