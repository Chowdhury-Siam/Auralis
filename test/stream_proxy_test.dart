import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/models.dart';
import 'package:auralis/telegram/stream_proxy.dart';

void main() {
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
