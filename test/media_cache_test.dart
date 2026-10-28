import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/media_cache.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

void main() {
  test('cached art and lyrics survive Telegram file ID changes and migrate existing entries', () async {
    final dir = await Directory.systemTemp.createTemp(
      'auralis-cache-identity-',
    );
    addTearDown(() => dir.delete(recursive: true));
    const original = Track(
      id: '-1:42',
      title: 'Song',
      artist: 'Artist',
      source: 'Music',
      fileId: 10,
      coverFileId: 20,
      size: 100,
      duration: Duration(seconds: 30),
    );
    const refreshed = Track(
      id: '-1:42',
      title: 'Song',
      artist: 'Artist',
      source: 'Music',
      fileId: 91,
      coverFileId: 92,
      size: 100,
      duration: Duration(seconds: 30),
    );
    final disk = MediaCache(dir);
    final legacy = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              original.id,
              original.fileId,
              original.size,
              original.coverFileId,
              original.title,
              original.artist,
              original.duration.inSeconds,
            ]),
          ),
        )
        .toString();
    expect(disk.key(original), disk.key(refreshed));
    for (final kind in ['art', 'lyrics']) {
      final file = File('${dir.path}/$legacy.$kind');
      await file.writeAsBytes([1, 2, 3]);
      await file.setLastModified(DateTime(2000));
      final stamp = await file.lastModified();
      expect(await disk.read(original, kind, 100), [1, 2, 3]);
      expect(await MediaCache(dir).read(refreshed, kind, 100), [1, 2, 3]);
      expect(await file.lastModified(), stamp);
    }
    const changed = Track(
      id: '-1:42',
      title: 'Different song',
      artist: 'Artist',
      source: 'Music',
      size: 100,
    );
    expect(await disk.read(changed, 'art', 100), isNull);
  });

  test(
    'a cached lyric miss does not hide lyrics saved by another lookup',
    () async {
      final dir = await Directory.systemTemp.createTemp('auralis-late-lyrics-');
      addTearDown(() => dir.delete(recursive: true));
      final disk = MediaCache(dir);
      const track = Track(
        id: 'late',
        title: 'Song',
        artist: 'Artist',
        source: 'Music',
      );
      final reader = LyricsRepository(cache: () => disk)..save(track, null);
      final writer = LyricsRepository(cache: () => disk);
      addTearDown(reader.close);
      addTearDown(writer.close);
      await writer.persist(track, Lyrics.parse('[00:01]Saved words'));
      expect(
        (await reader.loadCached(track))!.lines.single.text,
        'Saved words',
      );
      expect(reader.cached(track)!.lines.single.text, 'Saved words');
    },
  );

  test('saved artwork survives restart until explicitly cleared, keeping lyrics intact', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-retained-art-');
    addTearDown(() => dir.delete(recursive: true));
    const track = Track(
      id: 'art',
      title: 'Art',
      artist: 'Artist',
      source: 'Music',
    );
    final cache = MediaCache(dir);
    await cache.write(track, 'art', [1, 2, 3]);
    await cache.write(track, 'lyrics', [4, 5, 6]);
    final restarted = MediaCache(dir);
    expect(await restarted.read(track, 'art', 100), [1, 2, 3]);
    await restarted.clearArtwork();
    expect(await restarted.read(track, 'art', 100), isNull);
    expect(await restarted.read(track, 'lyrics', 100), [4, 5, 6]);
  });

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
