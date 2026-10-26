import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/media_cache.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shutdown drain waits for all cache instances before directory deletion',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'auralis-cache-drain-',
      );
      const track = Track(
        id: 'drain',
        title: 'Drain',
        artist: 'Artist',
        source: 'Channel',
      );
      final work = [
        for (var i = 0; i < 12; i++)
          MediaCache(Directory('${root.path}/account-$i'))
              .write(track, 'art', List.filled(65536, i)),
      ];
      expect(MediaCache.hasPending(root), isTrue);
      await MediaCache.drain(root);
      expect(MediaCache.hasPending(root), isFalse);
      await Future.wait(work);
      await root.delete(recursive: true);
      expect(await root.exists(), isFalse);
    },
  );

  test('all refreshed lyrics survive memory eviction, restart and account isolation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'auralis-media-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final disk = MediaCache(Directory('${directory.path}/alice'));
    final writer = LyricsRepository(cache: () => disk);
    addTearDown(writer.close);
    Track track(int i) =>
        Track(id: '$i', title: 'Song $i', artist: 'Artist', source: 'Channel');
    for (var i = 0; i < 40; i++) {
      await writer.persist(
        track(i),
        Lyrics.parse('[00:01]Line $i', embedded: true),
      );
    }
    final reader = LyricsRepository(
      cache: () => disk,
      createClient: () => throw StateError('Offline'),
    );
    addTearDown(reader.close);
    for (var i = 0; i < 40; i++) {
      expect((await reader.find(track(i)))!.lines.single.text, 'Line $i');
    }
    expect((await reader.find(track(0)))!.embedded, isTrue);
    final other = LyricsRepository(
      cache: () => MediaCache(Directory('${directory.path}/bob')),
    );
    addTearDown(other.close);
    expect(await other.loadCached(track(0)), isNull);
    await File('${disk.directory!.path}/${disk.key(track(1))}.lyrics')
        .writeAsString('broken');
    final fresh = LyricsRepository(cache: () => disk);
    addTearDown(fresh.close);
    expect(await fresh.loadCached(track(1)), isNull);
  });
  test('artwork cache is bounded on reads and never writes audio', () async {
    final directory = await Directory.systemTemp.createTemp(
      'auralis-art-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = MediaCache(directory);
    const track = Track(id: 'a', title: 'A', artist: 'B', source: 'C');
    await cache.write(track, 'art', Uint8List.fromList([1, 2, 3]));
    expect(await cache.read(track, 'art', 2), isNull);
    expect(await cache.read(track, 'art', 3), [1, 2, 3]);
    expect(directory.listSync().every((f) => f.path.endsWith('.art')), isTrue);
  });
}
