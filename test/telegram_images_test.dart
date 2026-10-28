import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/models.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/telegram_service.dart';

import 'fakes.dart';
import 'fixtures/cover_data.dart';

void main() {
  late Directory dir;
  late FakeTd td;
  late TelegramService service;
  late File photo;
  final png = File('test/fixtures/cover.png').readAsBytesSync();
  final audio = id3(png);
  Track song(int id, {int? thumbnail}) => Track(
    id: '1:$id',
    title: 'Song',
    artist: 'Artist',
    source: 'Channel',
    fileId: id,
    coverFileId: thumbnail,
    size: audio.length,
  );
  void cachedAudio() {
    final fallback = td.onRequest!;
    td.onRequest = (r) async {
      if (r['@type'] == 'getFileDownloadedPrefixSize') {
        return {'size': audio.length - (r['offset'] as int)};
      }
      if (r['@type'] == 'readFilePart') {
        final offset = r['offset'] as int;
        return {
          'data': base64Encode(
            audio.sublist(offset, offset + (r['count'] as int)),
          ),
        };
      }
      return fallback(r);
    };
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auralis-photos-');
    photo = await File('assets/branding/auralis.png')
        .copy('${dir.path}/photo.png');
    td = FakeTd();
    service = TelegramService(dir, MemoryVault(), transport: td);
    await service.start(
      apiId: 12345,
      apiHash: 'abcdef0123456789abcdef0123456789',
    );
    service.state = 'authorizationStateReady';
    td.onRequest = (r) async => r['@type'] == 'downloadFile'
        ? {
            'local': {'path': photo.path, 'is_downloading_completed': true},
          }
        : null;
  });
  tearDown(() async {
    await service.shutdown();
    await dir.delete(recursive: true);
  });

  test('saved cover checks and warming reuse valid files without rewrites or requests', () async {
    final track = song(1);
    final disk = service.mediaCache;
    await disk.write(track, 'art', png);
    final file = File('${disk.directory!.path}/${disk.key(track)}.art');
    await file.setLastModified(DateTime(2000));
    final savedTime = await file.lastModified();
    final requests = td.requests.length;
    expect(await service.hasCachedCover(track), isTrue);
    expect(await service.cacheCover(track, active: () => true), png);
    expect(td.requests, hasLength(requests));
    expect(await file.lastModified(), savedTime);
    final alias = Track(
      id: 'alias',
      title: track.title,
      artist: track.artist,
      source: track.source,
      fileId: track.fileId,
      size: track.size,
    );
    expect(await service.hasCachedCover(alias), isFalse);
    expect(await service.cacheCover(alias, active: () => true), png);
    expect(await service.hasCachedCover(alias), isTrue);
    expect(td.requests, hasLength(requests));
    await file.writeAsBytes([0, 1, 2]);
    service.clearImageCache();
    expect(await service.hasCachedCover(track), isFalse);
    cachedAudio();
    expect(await service.cacheCover(track, active: () => true), png);
    expect(await service.hasCachedCover(track), isTrue);
    service.state = 'disconnected';
    expect(await service.hasCachedCover(track), isFalse);
  });

  test(
    'saved covers bypass busy metadata and corrupt images remain missing',
    () async {
      service.isStreaming = (_) => true;
      final pending = <Completer<Json>>[];
      final started = Completer<void>();
      td.onRequest = (request) async {
        if (request['@type'] == 'getFileDownloadedPrefixSize') {
          final job = Completer<Json>();
          pending.add(job);
          if (pending.length == 2) started.complete();
          return job.future;
        }
        return null;
      };
      final disk = service.mediaCache;
      await disk.write(song(3), 'art', png);
      final first = service.cover(song(1));
      final second = service.cover(song(2));
      await started.future;
      expect(await service.hasCachedCover(song(3)), isTrue);
      expect(
        await service.cover(song(3)),
        png,
        reason: 'Disk reads cannot be refused by the metadata job limit',
      );
      expect(pending, hasLength(2));
      for (final job in pending) {
        job.complete({'size': 0});
      }
      await Future.wait([first, second]);
      final damaged = song(4, thumbnail: 94);
      await disk.write(damaged, 'art', png.sublist(0, 16));
      expect(
        await service.hasCachedCover(damaged),
        isFalse,
        reason: 'An image signature alone does not prove a cover can display',
      );
      td.onRequest = (request) async => request['@type'] == 'downloadFile'
          ? {
              'local': {'path': photo.path, 'is_downloading_completed': true},
            }
          : null;
      expect(
        await service.cacheCover(damaged, active: () => true),
        await photo.readAsBytes(),
      );
      expect(await service.hasCachedCover(damaged), isTrue);
    },
  );

  test(
    'explicit warming sees a saved cover after an earlier clean miss',
    () async {
      const track = Track(
        id: 'late',
        title: 'Late cover',
        artist: 'Artist',
        source: 'Music',
        fileId: 10,
      );
      expect(await service.cover(track), isNull);
      await service.mediaCache.write(track, 'art', png);
      expect(await service.cacheCover(track, active: () => true), png);
      expect(service.cachedCover(track), png);
      expect(await service.cover(track), png);
    },
  );

  test(
    'visible artwork downloads are shared and lower priority than playback',
    () async {
      final first = service.image(90);
      final second = service.image(90);
      expect(identical(first, second), isTrue);
      expect(await first, photo.path);
      expect(await second, photo.path);
      final requests = td.requests
          .where((r) => r['@type'] == 'downloadFile')
          .toList();
      expect(requests, hasLength(1));
      expect(requests.single, {
        '@type': 'downloadFile',
        'file_id': 90,
        'priority': 1,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      });
    },
  );

  test(
    'channel photo changes and removals preserve titles and channel filtering',
    () async {
      td.events.add({
        '@type': 'updateNewChat',
        'chat': {
          'id': -1,
          'title': 'Music',
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
          'photo': {
            'small': {'id': 11},
          },
        },
      });
      expect(service.channels.single.photoFileId, 11);
      td.events.add({
        '@type': 'updateChatTitle',
        'chat_id': -1,
        'title': 'Albums',
      });
      expect(service.channels.single.photoFileId, 11);
      td.events.add({
        '@type': 'updateChatPhoto',
        'chat_id': -1,
        'photo': {
          'small': {'id': 12},
        },
      });
      expect(service.channels.single.photoFileId, 12);
      expect(service.channels.single.title, 'Albums');
      td.events.add({
        '@type': 'updateChatPhoto',
        'chat_id': -2,
        'photo': {
          'small': {'id': 99},
        },
      });
      expect(service.channels, hasLength(1));
      td.events.add({'@type': 'updateChatPhoto', 'chat_id': -1, 'photo': null});
      expect(service.channels.single.photoFileId, isNull);
    },
  );

  test(
    'missing, incomplete and failed artwork falls back; refresh can retry',
    () async {
      final normal = td.onRequest!;
      td.onRequest = (r) async => {
        'local': {'path': photo.path, 'is_downloading_completed': false},
      };
      expect(await service.image(1), isNull);
      td.onRequest = (r) async => {
        'local': {
          'path': '${dir.path}/missing.png',
          'is_downloading_completed': true,
        },
      };
      expect(await service.image(2), isNull);
      td.onRequest = (r) async => throw TimeoutException('test timeout');
      expect(await service.image(3), isNull);
      service.clearImageCache();
      td.onRequest = normal;
      expect(await service.image(3), photo.path);
    },
  );

  test('sign-out invalidates an artwork request still in flight', () async {
    final pending = Completer<Json>();
    td.onRequest = (r) async =>
        r['@type'] == 'downloadFile' ? pending.future : null;
    final request = service.image(1);
    td.auth('authorizationStateLoggingOut');
    pending.complete({
      'local': {'path': photo.path, 'is_downloading_completed': true},
    });
    expect(await request, isNull);
    expect(await service.image(2), isNull);
  });

  test(
    'embedded lyrics reuse cached stream ranges and discard sign-out results',
    () async {
      final payload = [
        3,
        ...'eng'.codeUnits,
        0,
        ...utf8.encode('[00:01]Original file words'),
      ];
      final frame = [
        ...'USLT'.codeUnits,
        ...number(payload.length, 4),
        0,
        0,
        ...payload,
      ];
      final bytes = [
        ...'ID3'.codeUnits,
        3,
        0,
        0,
        ...number(frame.length, 4, sync: true),
        ...frame,
      ];
      final track = Track(
        id: 'lyrics',
        title: 'Song',
        artist: 'Artist',
        source: 'Channel',
        fileId: 7,
        size: bytes.length,
      );
      service.isStreaming = (_) => true;
      td.onRequest = (r) async {
        final offset = r['offset'] as int? ?? 0;
        if (r['@type'] == 'getFileDownloadedPrefixSize') {
          return {'size': bytes.length - offset};
        }
        if (r['@type'] == 'readFilePart') {
          return {
            'data': base64Encode(
              bytes.sublist(offset, offset + (r['count'] as int)),
            ),
          };
        }
        return null;
      };
      final result = await service.embeddedLyrics(track);
      expect(result!.embedded, isTrue);
      expect(result.lines.single.text, 'Original file words');
      expect(td.requests.where((r) => r['@type'] == 'downloadFile'), isEmpty);
      td.onRequest = (r) async {
        if (r['@type'] == 'readFilePart') {
          service.clearImageCache();
          return {'data': base64Encode(bytes.sublist(0, r['count'] as int))};
        }
        return {'size': bytes.length};
      };
      expect(await service.embeddedLyrics(track), isNull);
      td.onRequest = (_) async => {'size': 0};
      expect(await service.embeddedLyrics(track), isNull);
      expect(td.requests.where((r) => r['@type'] == 'downloadFile'), isEmpty);
    },
  );

  test(
    'metadata buffers are removed after extraction while artwork stays cached',
    () async {
      final reading = Completer<void>(), finish = Completer<void>();
      addTearDown(() {
        if (!finish.isCompleted) {
          finish.complete();
        }
      });
      expect(await service.image(90), photo.path);
      cachedAudio();
      final normal = td.onRequest!;
      td.onRequest = (r) async {
        if (r['@type'] == 'readFilePart') {
          if (!reading.isCompleted) {
            reading.complete();
          }
          await finish.future;
        }
        return normal(r);
      };
      final cover = service.cover(song(1));
      await reading.future;
      await service.releaseAudio(1);
      expect(td.requests.where((r) => r['@type'] == 'deleteFile'), isEmpty);
      finish.complete();
      expect(await cover, png);
      expect(td.requests.where((r) => r['@type'] == 'deleteFile').toList(), [
        {'@type': 'deleteFile', 'file_id': 1},
      ]);
      final requests = td.requests.length;
      expect(await service.cover(song(1)), png);
      expect(await service.image(90), photo.path);
      expect(
        td.requests,
        hasLength(requests),
        reason: 'Extracted artwork is retained',
      );
      expect(await photo.exists(), isTrue);
    },
  );

  test('active playback protects its buffer from metadata cleanup', () async {
    service.isStreaming = (_) => true;
    cachedAudio();
    expect(await service.cover(song(1)), png);
    await service.releaseAudio(1);
    expect(td.requests.where((r) => r['@type'] == 'deleteFile'), isEmpty);
    service.isStreaming = (_) => false;
    await service.releaseAudio(1);
    expect(td.requests.last, {'@type': 'deleteFile', 'file_id': 1});
  });

  test(
    'deleting a metadata buffer does not endlessly retry a missing cover',
    () async {
      td.onRequest = (r) async {
        if (r['@type'] == 'getFileDownloadedPrefixSize') return {'size': 100};
        if (r['@type'] == 'readFilePart') {
          td.events.add({
            '@type': 'updateFile',
            'file': {
              'id': 1,
              'local': {'downloaded_size': 100},
            },
          });
          return {'data': base64Encode(List.filled(r['count'] as int, 0))};
        }
        if (r['@type'] == 'deleteFile') {
          td.events.add({
            '@type': 'updateFile',
            'file': {
              'id': 1,
              'local': {'downloaded_size': 0},
            },
          });
        }
        return null;
      };
      expect(await service.cover(song(1)), isNull);
      final count = td.requests.length;
      expect(await service.cover(song(1)), isNull);
      expect(td.requests, hasLength(count));
    },
  );

  test('embedded cover downloads only bounded metadata ranges', () async {
    final ranges = <int, int>{};
    td.onRequest = (r) async {
      final offset = r['offset'] as int? ?? 0;
      if (r['@type'] == 'getFileDownloadedPrefixSize') {
        return {'size': ranges[offset] ?? 0};
      }
      if (r['@type'] == 'downloadFile') {
        expect(r['priority'], 1);
        ranges[offset] = r['limit'] as int;
        return {};
      }
      if (r['@type'] == 'readFilePart') {
        return {
          'data': base64Encode(
            audio.sublist(offset, offset + (r['count'] as int)),
          ),
        };
      }
      return null;
    };
    final first = service.cover(song(1));
    expect(identical(first, service.cover(song(1))), isTrue);
    expect(await first, png);
    expect(ranges.values.fold(0, (a, b) => a + b), lessThan(audio.length));
    expect(ranges.keys, [0, 10]);
  });

  test(
    'embedded cover uses a playing file cache without moving its download',
    () async {
      service.isStreaming = (_) => true;
      cachedAudio();
      expect(await service.cover(song(1)), png);
      expect(td.requests.where((r) => r['@type'] == 'downloadFile'), isEmpty);
    },
  );

  test(
    'missing stream bytes retry on file progress without resetting playback',
    () async {
      service.isStreaming = (_) => true;
      td.onRequest = (r) async =>
          r['@type'] == 'getFileDownloadedPrefixSize' ? {'size': 0} : null;
      expect(await service.cover(song(1)), isNull);
      cachedAudio();
      td.events.add({
        '@type': 'updateFile',
        'file': {'id': 1},
      });
      expect(await service.cover(song(1)), png);
      expect(td.requests.where((r) => r['@type'] == 'downloadFile'), isEmpty);
    },
  );

  test('failed Telegram thumbnail falls back to embedded cover', () async {
    td.onRequest = (r) async => throw TimeoutException('thumbnail unavailable');
    cachedAudio();
    expect(await service.cover(song(1, thumbnail: 90)), png);
  });

  test('sign-out discards pending embedded artwork', () async {
    final prefix = Completer<Json>();
    td.onRequest = (r) async =>
        r['@type'] == 'getFileDownloadedPrefixSize' ? prefix.future : null;
    final request = service.cover(song(1));
    td.auth('authorizationStateLoggingOut');
    prefix.complete({'size': audio.length});
    expect(await request, isNull);
    expect(td.requests.where((r) => r['@type'] == 'readFilePart'), isEmpty);
  });

  test('at most two metadata jobs run and waiting covers finish', () async {
    service.isStreaming = (_) => true;
    final pending = <int, Completer<Json>>{};
    final twoStarted = Completer<void>(), retryStarted = Completer<void>();
    td.onRequest = (r) async {
      if (r['@type'] == 'getFileDownloadedPrefixSize') {
        final result = pending[r['file_id'] as int] = Completer<Json>();
        if (pending.length == 2) twoStarted.complete();
        if (pending.length == 3) retryStarted.complete();
        return result.future;
      }
      return null;
    };
    final first = service.cover(song(1));
    final second = service.cover(song(2));
    await twoStarted.future;
    var thirdCompleted = false;
    final third = service.cover(song(3)).then((bytes) {
      thirdCompleted = true;
      return bytes;
    });
    expect(thirdCompleted, isFalse);
    expect(pending.keys, [1, 2]);
    pending[1]!.complete({'size': 0});
    pending[2]!.complete({'size': 0});
    await Future.wait([first, second]);
    await retryStarted.future;
    expect(pending.keys, [1, 2, 3]);
    pending[3]!.complete({'size': 0});
    expect(await third, isNull);
  });

  test('supplied thumbnail still works when audio size is unknown', () async {
    expect(
      await service.cover(
        const Track(
          id: 'unknown',
          title: 'Song',
          artist: 'Artist',
          source: 'Channel',
          fileId: 1,
          coverFileId: 90,
        ),
      ),
      await photo.readAsBytes(),
    );
    expect(
      td.requests.where((r) => r['@type'] == 'getFileDownloadedPrefixSize'),
      isEmpty,
    );
  });

  test(
    'artwork request cache is bounded instead of retaining every viewed cover',
    () async {
      for (var id = 1; id <= 129; id++) {
        expect(await service.image(id), photo.path);
      }
      await service.image(129);
      await service.image(1);
      expect(
        td.requests.where((r) => r['@type'] == 'downloadFile'),
        hasLength(130),
      );
    },
  );
}
