import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/data_files.dart';

import 'package:auralis/lyrics.dart';
import 'package:auralis/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'updater_test.dart' show Client, Response;

const song = Track(
  id: 'private-message-id',
  title: 'Evening waves',
  artist: 'Test artist',
  source: 'Private channel',
  duration: Duration(seconds: 120),
);

class DelayedLyricsResponse extends Response {
  DelayedLyricsResponse()
    : super(utf8.encode('{"plainLyrics":"Late online words"}'));
  final ready = Completer<void>();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      (() async* {
        await ready.future;
        yield bytes;
      })().listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

void main() {
  test(
    'LRC file decoding supports UTF8/BOM and UTF16 with bounded valid content',
    () {
      const text = '[00:01.50]Original 日本語\r\n[00:03]Another line';
      final encoded = [
        utf8.encode(text),
        [239, 187, 191, ...utf8.encode(text)],
        [
          255,
          254,
          for (final c in text.codeUnits) ...[c & 255, c >> 8],
        ],
        [
          254,
          255,
          for (final c in text.codeUnits) ...[c >> 8, c & 255],
        ],
      ];
      for (final bytes in encoded) {
        final lyrics = Lyrics.fromFileBytes(Uint8List.fromList(bytes));
        expect(lyrics.imported, isTrue);
        expect(lyrics.online, isFalse);
        expect(lyrics.lines.first.text, 'Original 日本語');
        expect(lyrics.lines.first.time, const Duration(milliseconds: 1500));
      }
      for (final bytes in [
        <int>[],
        [255],
        [255, 254, 65],
        List.filled(Lyrics.maxFileBytes + 1, 65),
        utf8.encode(List.filled(2001, '[00:01]line').join('\n')),
      ]) {
        expect(
          () => Lyrics.fromFileBytes(Uint8List.fromList(bytes)),
          throwsFormatException,
        );
      }
    },
  );

  test('local LRC reads enforce the smaller lyric byte limit', () async {
    final directory = await Directory.systemTemp.createTemp('auralis-lrc-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/words.lrc');
    await file.writeAsString('[00:00]Original file words');
    const files = DataFiles();
    expect(
      Lyrics.fromFileBytes(
        await files.readBytes(file.path, maxBytes: Lyrics.maxFileBytes),
      ).lines.single.text,
      'Original file words',
    );
    await file.writeAsBytes(List.filled(Lyrics.maxFileBytes + 1, 65));
    await expectLater(
      files.readBytes(file.path, maxBytes: Lyrics.maxFileBytes),
      throwsFormatException,
    );
  });

  test('LRC sorts repeated timestamps, merges translations, supports fractions and gaps', () {
    final lyrics = Lyrics.parse(
      '[ar:Test]\n[offset:-50]\n[00:12.5][00:25.123]Evening waves\n[00:02]Small lights\n[00:12.50]Translation\n[00:20.00]\n[01:99]Invalid',
    );
    expect(lyrics.lines.map((line) => line.time.inMilliseconds), [
      1950,
      12450,
      19950,
      25073,
    ]);
    expect(lyrics.lines[1].text, 'Evening waves\nTranslation');
    expect(lyrics.lines[2].text, '');
    expect(lyrics.activeAt(Duration.zero), -1);
    expect(lyrics.activeAt(const Duration(milliseconds: 12450)), 1);
    expect(lyrics.activeAt(const Duration(minutes: 2)), 3);
    expect(lyrics.plain, isNot(contains('[ar:')));
    expect(
      Lyrics.parse('[00:00] <00:00.10>Small <00:00.30>lights').plain,
      'Small lights',
    );
  });

  test('plain lyrics, bounds and negative offsets are handled', () {
    expect(Lyrics.parse('Original words\nAnother line').lines, isEmpty);
    expect(
      Lyrics.parse('[00:00.01]Early\n[offset:-500]').lines.single.time,
      Duration.zero,
    );
    expect(() => Lyrics.parse('a' * (256 * 1024 + 1)), throwsFormatException);
    expect(
      () => Lyrics.parse(List.filled(2001, 'line').join('\n')),
      throwsFormatException,
    );
  });

  test(
    'lookup sends only song metadata and closes HTTP; cache is session bounded',
    () async {
      final client = Client([
        Response(
          utf8.encode(
            jsonEncode({
              'syncedLyrics': '[00:02.00]Original test words',
              'plainLyrics': 'Original test words',
              'instrumental': false,
            }),
          ),
        ),
      ]);
      final repository = LyricsRepository(createClient: () => client);
      expect(client.requests, isEmpty);
      final result = await repository.find(song);
      expect(result!.online, isTrue);
      expect(client.requests.single.scheme, 'https');
      expect(client.requests.single.host, 'lrclib.net');
      expect(client.requests.single.queryParameters, {
        'track_name': 'Evening waves',
        'artist_name': 'Test artist',
        'duration': '120',
      });
      expect(client.requests.single.toString(), isNot(contains('Private')));
      expect(client.closed, isTrue);
      expect(repository.cached(song), same(result));
      for (var i = 0; i < 33; i++) {
        repository.save(
          Track(id: '$i', title: 'Title', artist: 'Artist', source: 'Channel'),
          result,
        );
      }
      expect(repository.contains(song), isFalse);
      repository.close();
      expect(() => repository.find(song), throwsStateError);
    },
  );

  test(
    'a late HTTP response cannot overwrite imported session lyrics',
    () async {
      final response = DelayedLyricsResponse();
      final repository = LyricsRepository(
        createClient: () => Client([response]),
      );
      addTearDown(repository.close);
      final request = repository.find(song);
      final imported = Lyrics.parse('Local choice', imported: true);
      repository.save(song, imported);
      response.ready.complete();
      expect(await request, same(imported));
      expect(repository.cached(song), same(imported));
    },
  );

  test('not found and instrumental states differ; invalid/oversized HTTP never caches', () async {
    for (final response in [
      Response([], statusCode: 404),
      Response(utf8.encode('{"instrumental":true}')),
      Response([], statusCode: 302, redirect: 'https://example.com/'),
      Response(utf8.encode('{"plainLyrics":42}')),
      Response(List.filled(512 * 1024 + 1, 32)),
      Response(utf8.encode('not json')),
    ]) {
      final client = Client([
        response,
        Response(utf8.encode('[]')),
        Response([], statusCode: 404),
      ]);
      final repository = LyricsRepository(createClient: () => client);
      if (response.statusCode == 404) {
        expect(await repository.find(song), isNull);
        expect(repository.contains(song), isTrue);
      } else if (response.bytes.length < 40 &&
          response.statusCode == 200 &&
          utf8.decode(response.bytes).contains('true')) {
        expect((await repository.find(song))!.instrumental, isTrue);
      } else {
        await expectLater(repository.find(song), throwsException);
        expect(repository.contains(song), isFalse);
      }
      expect(client.closed, isTrue);
      repository.close();
    }
  });
}
