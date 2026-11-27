import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/models.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/video_stream_cache.dart';

void main() {
  test('preloads one bounded video prefix and hands it to playback', () async {
    final calls = <Map<String, dynamic>>[];
    final proxy = TelegramStreamProxy((request) async {
      calls.add(request);
      return {};
    });
    addTearDown(proxy.close);
    const current = Track(
      id: 'current',
      title: 'Current',
      artist: '',
      source: 'Channel',
      fileId: 1,
      size: 1000,
      duration: Duration(seconds: 30),
    );
    const next = Track(
      id: 'next',
      title: 'Next',
      artist: '',
      source: 'Channel',
      fileId: 2,
      size: 60000000,
      duration: Duration(minutes: 2),
    );
    const other = Track(
      id: 'other',
      title: 'Other',
      artist: '',
      source: 'Channel',
      fileId: 3,
      size: 80000000,
      duration: Duration(seconds: 5),
    );
    await proxy.uri(current);
    await proxy.preload(next);
    await proxy.preload(next);
    expect(proxy.isStreaming(1), isTrue);
    expect(proxy.isPreloading(2), isTrue);
    expect(calls, [
      {'@type': 'getFileDownloadedPrefixSize', 'file_id': 2, 'offset': 0},
      {
        '@type': 'downloadFile',
        'file_id': 2,
        'priority': 2,
        'offset': 0,
        'limit': 5000000,
        'synchronous': false,
      },
    ]);

    await proxy.uri(next);
    expect(proxy.isStreaming(2), isTrue);
    expect(proxy.isPreloading(2), isFalse);
    expect(calls.where((call) => call['@type'] == 'deleteFile'), [
      {'@type': 'deleteFile', 'file_id': 1},
    ]);

    await proxy.preload(other);
    expect(calls.last['limit'], 16 * 1024 * 1024);
    await proxy.stop();
    expect(
      calls
          .where((call) => call['@type'] == 'deleteFile')
          .map((call) => call['file_id']),
      unorderedEquals([1, 2, 3]),
    );
  });

  test('a parked next-video preload serves its bytes before fetching the missing suffix', () async {
    final fixture = await _VideoRanges.create();
    await fixture.proxy.uri(_episode(1));
    final next = _episode(2);
    await fixture.proxy.preload(next);
    await fixture.proxy.preload(next);
    final preload = fixture.downloads.single;
    expect(preload['priority'], 2);
    expect(preload['limit'], next.size ~/ 12);

    await fixture.proxy.stop(keepPreload: true);
    final uri = await fixture.proxy.uri(next);
    expect(await fixture.read(uri, 0, 1023), _VideoRanges.bytes(0, 1024));
    expect(fixture.downloads, hasLength(1));
    final end = preload['limit'] as int;
    expect(
      await fixture.read(uri, end - 8, end + 7),
      _VideoRanges.bytes(end - 8, 16),
    );
    expect(fixture.downloads, hasLength(2));
    expect(fixture.downloads.last['offset'], end);
    expect(fixture.downloads.last['limit'], 8);
    expect(fixture.downloads.last['priority'], 32);
  });

  test(
    'obsolete preload does not start after its prefix check returns',
    () async {
      final fixture = await _VideoRanges.create();
      final started = Completer<void>(), blocked = Completer<Json>();
      fixture.override = (json) {
        if (json['@type'] == 'getFileDownloadedPrefixSize' &&
            json['file_id'] == 2) {
          started.complete();
          return blocked.future;
        }
        return null;
      };
      final abandoned = fixture.proxy.preload(_episode(2));
      await started.future;
      final latest = fixture.proxy.preload(_episode(3));
      blocked.complete({'size': 0});
      await Future.wait([abandoned, latest]);
      expect(fixture.downloads.single['file_id'], 3);
      expect(
        fixture.calls,
        contains(
          equals({
            '@type': 'cancelDownloadFile',
            'file_id': 2,
            'only_if_pending': false,
          }),
        ),
      );
    },
  );

  test('resuming a suspended preload fetches only its missing bytes', () async {
    final fixture = await _VideoRanges.create();
    final episode = _episode(2);
    await fixture.proxy.preload(episode);
    fixture.available[2] = const ByteRange(0, 2047);
    await fixture.proxy.pausePreload(true);
    await fixture.proxy.pausePreload(false);
    expect(fixture.downloads, hasLength(2));
    expect(fixture.downloads.last['offset'], 2048);
    expect(fixture.downloads.last['limit'], episode.size ~/ 12 - 2048);
    await fixture.proxy.pausePreload(true);
    fixture.available[2] = ByteRange(0, episode.size - 1);
    await fixture.proxy.pausePreload(false);
    expect(fixture.downloads, hasLength(2));
  });

  test('unknown and short videos get a partial preload', () async {
    final fixture = await _VideoRanges.create();
    await fixture.proxy.preload(_episode(1, duration: Duration.zero));
    expect(fixture.downloads.single['limit'], 1024 * 1024);
    await fixture.proxy.preload(
      _episode(2, duration: const Duration(seconds: 3)),
    );
    expect(fixture.downloads.last['limit'], lessThan(_episode(2).size));
  });

  test('a reopened video reuses its own header and resume bytes after TDLib cleanup', () async {
    final fixture = await _VideoRanges.create();
    final episode = _episode(1);
    final offset = episode.size * 9 ~/ 10;
    final first = await fixture.proxy.uri(episode);
    expect(await fixture.read(first, 0, 1023), _VideoRanges.bytes(0, 1024));
    expect(
      await fixture.read(first, offset, offset + 511),
      _VideoRanges.bytes(offset, 512),
    );
    await fixture.proxy.stop();
    expect(fixture.available, isEmpty);
    final reopened = await fixture.proxy.uri(episode);
    expect(await fixture.read(reopened, 0, 1023), _VideoRanges.bytes(0, 1024));
    expect(
      await fixture.read(reopened, offset + 8, offset + 511),
      _VideoRanges.bytes(offset + 8, 504),
    );
    expect(fixture.downloads, hasLength(2));

    final different = await fixture.proxy.uri(_episode(2));
    expect(await fixture.read(different, 0, 1023), _VideoRanges.bytes(0, 1024));
    expect(fixture.downloads.last['file_id'], 2);
  });

  test(
    'corrupted and removed cached video data fall back to Telegram',
    () async {
      final fixture = await _VideoRanges.create();
      final episode = _episode(1);
      final first = await fixture.proxy.uri(episode);
      await fixture.read(first, 0, 1023);
      await fixture.proxy.stop();
      await fixture.cache.read(1, episode.size, 0, 1024);
      final writer = await fixture.cache.file.open(mode: FileMode.append);
      await writer.setPosition(0);
      await writer.writeByte(255);
      await writer.close();

      final reopened = await fixture.proxy.uri(episode);
      expect(
        await fixture.read(reopened, 0, 1023),
        _VideoRanges.bytes(0, 1024),
      );
      expect(fixture.downloads, hasLength(2));
      await fixture.proxy.stop();
      await fixture.cache.clear();
      final uncached = await fixture.proxy.uri(episode);
      expect(
        await fixture.read(uncached, 0, 1023),
        _VideoRanges.bytes(0, 1024),
      );
      expect(fixture.downloads, hasLength(3));
    },
  );

  test(
    'the cache evicts old playback bytes and reserves room for headers',
    () async {
      final fixture = await _VideoRanges.create(pages: 8);
      final cache = fixture.cache;
      const page = VideoStreamCache.pageSize;
      final size = _episode(1).size;
      Future<void> store(int offset) async {
        final bytes = Uint8List.fromList(_VideoRanges.bytes(offset, 32));
        cache.store(1, size, offset, bytes);
        expect(await cache.read(1, size, offset, bytes.length), bytes);
      }

      await store(0);
      for (var block = 8; block < 16; block++) {
        await store(block * page);
      }
      expect(await cache.read(1, size, 8 * page, 32), isNull);
      expect(await cache.read(1, size, 0, 32), _VideoRanges.bytes(0, 32));
      expect(await cache.bytes, lessThanOrEqualTo(page * 8));
    },
  );

  test(
    'a short TDLib read is retried and an expired reference is reported',
    () async {
      final fixture = await _VideoRanges.create();
      var reads = 0;
      fixture.override = (json) {
        if (json['@type'] == 'readFilePart' && ++reads == 1) {
          return Future.value({'data': ''});
        }
        return null;
      };
      final uri = await fixture.proxy.uri(_episode(1));
      expect(await fixture.read(uri, 0, 127), _VideoRanges.bytes(0, 128));
      expect(fixture.downloads, hasLength(2));
      final expired = fixture.proxy.expiredReferences.first;
      fixture.override = (json) =>
          json['@type'] == 'getFileDownloadedPrefixSize'
          ? Future.error(TdException(400, 'FILE_REFERENCE_EXPIRED'))
          : null;
      await expectLater(fixture.read(uri, 200, 219), throwsException);
      expect((await expired).fileId, 1);
    },
  );

  test('interrupting a video after many chunks releases its socket before its cache', () async {
    const stallOffset = 128 * 1024 * 24;
    const fileSize = stallOffset + 4;
    final calls = <String>[];
    final stalled = Completer<void>();
    var resumed = false;
    final proxy = TelegramStreamProxy((request) async {
      final type = request['@type'] as String;
      calls.add(type);
      switch (type) {
        case 'getFileDownloadedPrefixSize':
          final offset = request['offset'] as int;
          if (resumed) return {'size': fileSize - offset};
          if (offset < stallOffset) return {'size': stallOffset - offset};
          if (!stalled.isCompleted) stalled.complete();
          return {'size': 0};
        case 'readFilePart':
          return {
            'data': base64Encode(List<int>.filled(request['count'] as int, 7)),
          };
        default:
          return {};
      }
    });
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await proxy.close();
    });
    const video = Track(
      id: 'video',
      title: 'Video',
      artist: '',
      source: 'Cinema',
      fileId: 1,
      size: fileSize,
    );
    final first = await proxy.uri(video);
    final response = await (await client.getUrl(first)).close();
    final interrupted = expectLater(response.drain<void>(), throwsException);
    await stalled.future;
    expect(calls.where((call) => call == 'readFilePart'), hasLength(24));

    await proxy.interrupt();
    await interrupted.timeout(const Duration(seconds: 2));
    expect(calls, isNot(contains('deleteFile')));
    await proxy.stop();
    expect(calls, contains('deleteFile'));

    resumed = true;
    final second = await proxy.uri(video);
    final tail = await client.getUrl(second);
    tail.headers.set('Range', 'bytes=$stallOffset-');
    final replay = await tail.close();
    expect(await replay.expand((chunk) => chunk).toList(), [7, 7, 7, 7]);
  });

  test(
    'changing or stopping tracks deletes only the previous audio buffer',
    () async {
      final calls = <Map<String, dynamic>>[];
      final proxy = TelegramStreamProxy((json) async {
        calls.add(json);
        return {};
      });
      addTearDown(proxy.close);
      const first = Track(
        id: 'first',
        title: 'First',
        artist: 'Artist',
        source: 'Channel',
        fileId: 1,
        size: 100,
      );
      const second = Track(
        id: 'second',
        title: 'Second',
        artist: 'Artist',
        source: 'Channel',
        fileId: 2,
        size: 100,
      );
      await proxy.uri(first);
      expect(
        calls,
        isEmpty,
        reason: 'Active audio stays available for seeking',
      );
      await proxy.uri(second);
      expect(calls, [
        {'@type': 'cancelDownloadFile', 'file_id': 1, 'only_if_pending': false},
        {'@type': 'deleteFile', 'file_id': 1},
      ]);
      expect(proxy.isStreaming(2), isTrue);
      await proxy.stop();
      expect(calls.last, {'@type': 'deleteFile', 'file_id': 2});
      expect(proxy.isStreaming(2), isFalse);
    },
  );

  test(
    'rapid replay waits for old deletion before activating the same file',
    () async {
      final deleting = Completer<void>(), finish = Completer<void>();
      final proxy = TelegramStreamProxy((json) async {
        if (json['@type'] == 'deleteFile') {
          if (!deleting.isCompleted) {
            deleting.complete();
          }
          await finish.future;
        }
        return {};
      });
      addTearDown(() async {
        if (!finish.isCompleted) {
          finish.complete();
        }
        await proxy.close();
      });
      const track = Track(
        id: 'same',
        title: 'Same',
        artist: 'Artist',
        source: 'Channel',
        fileId: 7,
        size: 100,
      );
      await proxy.uri(track);
      final old = proxy.uri(track);
      final oldError = expectLater(old, throwsStateError);
      await deleting.future;
      var opened = false;
      final latest = proxy.uri(track).then((uri) {
        opened = true;
        return uri;
      });
      await Future<void>.delayed(Duration.zero);
      expect(opened, isFalse);
      expect(proxy.isStreaming(7), isFalse);
      finish.complete();
      await oldError;
      await latest;
      expect(proxy.isStreaming(7), isTrue);
    },
  );

  test('new source wins concurrent opens and old URLs expire', () async {
    final proxy = TelegramStreamProxy((_) async => {});
    addTearDown(proxy.close);
    const track = Track(
      id: 'a',
      title: 'A',
      artist: 'B',
      source: 'Chat',
      fileId: 1,
      size: 100,
    );
    final first = proxy.uri(track);
    final firstError = expectLater(first, throwsStateError);
    final second = await proxy.uri(track);
    await firstError;
    final third = await proxy.uri(track);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final old = await (await client.openUrl('HEAD', second)).close();
    expect(old.statusCode, 403);
    await old.drain<void>();
    final current = await (await client.openUrl('HEAD', third)).close();
    expect(current.statusCode, 200);
    await current.drain<void>();
  });

  test(
    'a new seek supersedes a stalled old range without waiting for its timeout',
    () async {
      final started = Completer<void>();
      final proxy = TelegramStreamProxy((json) async {
        if (json['@type'] == 'downloadFile' ||
            json['@type'] == 'cancelDownloadFile') {
          return {};
        }
        if (json['@type'] == 'getFileDownloadedPrefixSize') {
          if (json['offset'] == 0) {
            if (!started.isCompleted) started.complete();
            return {'size': 0};
          }
          return {'size': 10};
        }
        return {'data': base64Encode(List.filled(json['count'] as int, 7))};
      });
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
      });
      final uri = await proxy.uri(
        const Track(
          id: 'a',
          title: 'A',
          artist: 'B',
          source: 'Chat',
          fileId: 1,
          size: 100,
        ),
      );
      final oldRequest = await client.getUrl(uri);
      final oldResult = oldRequest
          .close()
          .then((r) => r.drain<void>())
          .catchError((Object _) {});
      await started.future;
      final seek = await client.getUrl(uri);
      seek.headers.set('Range', 'bytes=90-99');
      final response = await seek.close().timeout(const Duration(seconds: 2));
      expect(response.statusCode, 206);
      expect(
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
        List.filled(10, 7),
      );
      await oldResult;
    },
  );
  test('middle and end seeks bypass an in-flight old cache request and ignore its late error', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    final errors = <String>[];
    final proxy = TelegramStreamProxy((json) async {
      if (json['@type'] == 'downloadFile' ||
          json['@type'] == 'cancelDownloadFile') {
        return {};
      }
      if (json['@type'] == 'getFileDownloadedPrefixSize') {
        if (json['offset'] == 0) {
          if (!started.isCompleted) started.complete();
          return blocked.future;
        }
        return {'size': 100 - (json['offset'] as int)};
      }
      return {
        'data': base64Encode(
          List.generate(
            json['count'] as int,
            (i) => ((json['offset'] as int) + i) % 251,
          ),
        ),
      };
    });
    final subscription = proxy.errors.listen(errors.add);
    final client = HttpClient();
    addTearDown(() async {
      if (!blocked.isCompleted) blocked.complete({'size': 0});
      client.close(force: true);
      await proxy.close();
      await subscription.cancel();
    });
    final uri = await proxy.uri(
      const Track(
        id: 'pending',
        title: 'Pending',
        artist: 'Fixture',
        source: 'Test',
        fileId: 1,
        size: 100,
      ),
    );
    final old = await client.getUrl(uri);
    final oldResult = old
        .close()
        .then((r) => r.drain<void>())
        .catchError((Object _) {});
    await started.future.timeout(const Duration(seconds: 2));
    for (final offset in [50, 90, 20]) {
      final request = await client.getUrl(uri);
      request.headers.set('Range', 'bytes=$offset-${offset + 9}');
      final response = await request.close().timeout(
        const Duration(seconds: 1),
      );
      expect(
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
        List.generate(10, (i) => offset + i),
      );
    }
    blocked.completeError(StateError('Late failure from superseded range'));
    await oldResult;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(errors, isEmpty);
  });

  test('seeking past a backpressured abandoned response still streams middle and tail bytes', () async {
    const size = 64 * 1024 * 1024;
    final chunk = base64Encode(List.filled(128 * 1024, 13));
    var reads = 0;
    final errors = <String>[];
    final proxy = TelegramStreamProxy((json) async {
      if (json['@type'] == 'downloadFile' ||
          json['@type'] == 'cancelDownloadFile') {
        return {};
      }
      if (json['@type'] == 'getFileDownloadedPrefixSize') {
        return {'size': size - (json['offset'] as int)};
      }
      reads++;
      final count = json['count'] as int;
      return {
        'data': count == 128 * 1024
            ? chunk
            : base64Encode(List.filled(count, 13)),
      };
    });
    final errorsSubscription = proxy.errors.listen(errors.add);
    final client = HttpClient();
    StreamSubscription<List<int>>? paused;
    addTearDown(() async {
      client.close(force: true);
      await paused?.cancel();
      await proxy.close();
      await errorsSubscription.cancel();
    });
    final uri = await proxy.uri(
      const Track(
        id: 'slow-reader',
        title: 'Slow reader',
        artist: 'Fixture',
        source: 'Test',
        fileId: 4,
        size: size,
      ),
    );
    final response = await (await client.getUrl(uri)).close();
    final received = Completer<void>();
    paused = response.listen((_) {
      paused!.pause();
      if (!received.isCompleted) received.complete();
    }, onError: (Object _) {});
    await received.future.timeout(const Duration(seconds: 2));
    // Wait for the old response's socket send buffer to stop accepting data.
    var unchanged = 0, previous = reads;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (unchanged < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      unchanged = reads == previous ? unchanged + 1 : 0;
      previous = reads;
    }
    expect(unchanged, 3, reason: 'Fixture must reach socket backpressure');
    expect(reads * 128 * 1024, lessThan(size));
    for (final offset in [size ~/ 2, size - 1024]) {
      final seek = await client.getUrl(uri);
      seek.headers.set('Range', 'bytes=$offset-${offset + 1023}');
      final result = await seek.close().timeout(const Duration(seconds: 2));
      expect(result.statusCode, 206);
      expect(
        await result.fold<List<int>>([], (a, b) => a..addAll(b)),
        List.filled(1024, 13),
      );
    }
    expect(errors, isEmpty);
  });

  test('byte ranges cover full, open-ended, suffix and invalid requests', () {
    expect(ByteRange.parse(null, 100).length, 100);
    expect(ByteRange.parse('bytes=20-', 100).start, 20);
    expect(ByteRange.parse('bytes=-10', 100).start, 90);
    expect(ByteRange.parse('bytes=20-999', 100).end, 99);
    for (final header in [
      'bytes=-0',
      'bytes=200-',
      'bytes=30-20',
      'bytes=0-1,3-4',
      'bytes=-',
      'garbage',
    ]) {
      expect(
        () => ByteRange.parse(header, 100),
        throwsFormatException,
        reason: header,
      );
    }
  });

  test(
    'original file bytes survive full streaming, buffering and seek ranges',
    () async {
      final bytes = List.generate(600000, (i) => i % 251);
      var waits = 0;
      final calls = <Map<String, dynamic>>[];
      final proxy = TelegramStreamProxy((json) async {
        calls.add(json);
        switch (json['@type']) {
          case 'downloadFile':
            return {'@type': 'file'};
          case 'getFileDownloadedPrefixSize':
            if (waits++ == 0) return {'size': 0};
            return {'size': bytes.length - (json['offset'] as int)};
          case 'readFilePart':
            final offset = json['offset'] as int, count = json['count'] as int;
            return {
              'data': base64Encode(bytes.sublist(offset, offset + count)),
            };
          default:
            throw StateError('Unexpected request');
        }
      });
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
      });
      final uri = await proxy.uri(
        Track(
          id: 'a',
          title: 'A',
          artist: 'B',
          source: 'Chat',
          fileId: 12,
          size: bytes.length,
          mime: 'audio/mpeg',
        ),
      );
      final full = await (await client.getUrl(uri)).close();
      expect(full.statusCode, 200);
      expect(full.contentLength, bytes.length);
      expect(full.headers.contentType?.mimeType, 'audio/mpeg');
      final streamed = await full.fold<List<int>>(
        [],
        (previous, chunk) => previous..addAll(chunk),
      );
      expect(streamed.length, bytes.length);
      expect(sha256.convert(streamed), sha256.convert(bytes));
      expect(
        calls.where((c) => c['@type'] == 'readFilePart').length,
        greaterThan(1),
      );
      expect(calls.first['offset'], 0);
      expect(calls.first['limit'], bytes.length);
      final get = await client.getUrl(uri);
      get.headers.set('Range', 'bytes=100-350000');
      final response = await get.close();
      expect(response.statusCode, 206);
      expect(
        response.headers.value('Content-Range'),
        'bytes 100-350000/600000',
      );
      final actual = await response.fold<List<int>>(
        [],
        (previous, chunk) => previous..addAll(chunk),
      );
      expect(actual, bytes.sublist(100, 350001));
      expect(waits, greaterThan(1));
      final downloads = calls
          .where((c) => c['@type'] == 'downloadFile')
          .toList();
      expect(downloads.last['offset'], 100);
      expect(downloads.last['limit'], 349901);
      final head = await client.openUrl('HEAD', uri);
      final headResponse = await head.close();
      expect(headResponse.contentLength, bytes.length);
      await headResponse.drain<void>();
      final bad = await client.getUrl(uri.replace(path: '/wrong/1'));
      final badResponse = await bad.close();
      expect(badResponse.statusCode, 403);
      await badResponse.drain<void>();
      final invalid = await client.getUrl(uri);
      invalid.headers.set('Range', 'bytes=999999-');
      final invalidResponse = await invalid.close();
      expect(invalidResponse.statusCode, 416);
      await invalidResponse.drain<void>();
      final suffix = await client.getUrl(uri);
      suffix.headers.set('Range', 'bytes=-20');
      final suffixResponse = await suffix.close();
      expect(
        await suffixResponse.fold<List<int>>([], (a, b) => a..addAll(b)),
        bytes.sublist(bytes.length - 20),
      );
      expect(calls.every((c) => c['file_id'] == 12), isTrue);
    },
  );

  test(
    'a stalled Telegram download reports an error and terminates the request',
    () async {
      final proxy = TelegramStreamProxy(
        (json) async => json['@type'] == 'downloadFile' ? {} : {'size': 0},
        stallTimeout: const Duration(milliseconds: 50),
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
      });
      final error = proxy.errors.first;
      final uri = await proxy.uri(
        const Track(
          id: 'a',
          title: 'A',
          artist: 'B',
          source: 'Chat',
          fileId: 9,
          size: 50,
        ),
      );
      final request = await client.getUrl(uri);
      final result = request
          .close()
          .then((r) => r.drain<void>())
          .catchError((Object _) {});
      expect(
        await error.timeout(const Duration(seconds: 3)),
        contains('buffer'),
      );
      await result;
    },
  );
}

Track _episode(int number, {Duration duration = const Duration(minutes: 2)}) =>
    Track(
      id: '-100:$number',
      title: 'Episode $number',
      artist: '',
      source: 'Test channel',
      fileId: number,
      size: 60 * 1024 * 1024,
      duration: duration,
      mime: 'video/mp4',
    );

class _VideoRanges {
  _VideoRanges(Directory directory, int pages)
    : cache = VideoStreamCache(
        File('${directory.path}/resume.cache'),
        pages: pages,
      );

  static Future<_VideoRanges> create({int pages = 512}) async {
    final directory = await Directory.systemTemp.createTemp(
      'auralis-video-cache-test',
    );
    final fixture = _VideoRanges(directory, pages);
    addTearDown(() async {
      fixture.client.close(force: true);
      await fixture.proxy.close();
      await fixture.cache.clear();
      await directory.delete(recursive: true);
    });
    return fixture;
  }

  final VideoStreamCache cache;
  final client = HttpClient();
  final calls = <Json>[];
  final available = <int, ByteRange>{};
  Future<Json>? Function(Json)? override;
  late final proxy = TelegramStreamProxy(request, videoCache: cache);

  List<Json> get downloads =>
      calls.where((json) => json['@type'] == 'downloadFile').toList();

  static List<int> bytes(int offset, int length) =>
      List.generate(length, (index) => (index + offset) % 251);

  Future<Json> request(Json json) async {
    calls.add(json);
    if (override?.call(json) case final result?) return result;
    final id = json['file_id'] as int;
    final offset = json['offset'] as int? ?? 0;
    switch (json['@type']) {
      case 'downloadFile':
        available[id] = ByteRange(offset, offset + (json['limit'] as int) - 1);
      case 'deleteFile':
        available.remove(id);
      case 'getFileDownloadedPrefixSize':
        final range = available[id];
        return {
          'size': range == null || offset < range.start || offset > range.end
              ? 0
              : range.end - offset + 1,
        };
      case 'readFilePart':
        return {'data': base64Encode(bytes(offset, json['count'] as int))};
    }
    return {};
  }

  Future<List<int>> read(Uri uri, int start, int end) async {
    final request = await client.getUrl(uri);
    request.headers.set('Range', 'bytes=$start-$end');
    final response = await request.close();
    expect(response.statusCode, 206);
    return response.expand((chunk) => chunk).toList();
  }
}
