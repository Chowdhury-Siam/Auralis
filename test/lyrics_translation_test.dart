import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_translation.dart';
import 'package:auralis/media_cache.dart';
import 'package:auralis/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'updater_test.dart' show Client, Response, Request;

const track = Track(
  id: 'japanese',
  title: 'Test',
  artist: 'Test artist',
  source: 'Test channel',
);
final japanese = Lyrics.parse(
  '[00:01]今日は晴れです。\n[00:04]明日も歩きます。\n[00:08]今日は晴れです。\n[00:10]\n[00:15]Good night',
);
Response google(String text) => Response(
  utf8.encode(
    jsonEncode([
      [
        [text, 'source', null, null],
      ],
      null,
      'ja',
    ]),
  ),
);
Response myMemory(String text, {bool quota = false}) => Response(
  utf8.encode(
    jsonEncode({
      'responseData': {'translatedText': text},
      'responseStatus': 200,
      'quotaFinished': quota,
    }),
  ),
);

class PendingTranslation extends Client {
  PendingTranslation() : super([]);
  final pending = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requests.add(url);
    return pending.future;
  }
}

void main() {
  test('bilingual lyrics keep timestamps, breaks, English and deduplicated choruses; restart is offline', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-translation-');
    var disk = MediaCache(Directory('${dir.path}/alice'));
    final client = Client([
      google('It is sunny today.\nI will walk tomorrow.'),
    ]);
    final translator = LyricsTranslator(
      createClient: () => client,
      cache: () => disk,
    );
    addTearDown(() async {
      translator.close();
      await MediaCache.drain(dir);
      await dir.delete(recursive: true);
    });
    final result = await translator.translate(
      track,
      japanese,
      active: () => true,
    );
    expect(
      result.lines.map((line) => line.time),
      japanese.lines.map((line) => line.time),
    );
    expect(result.lines.first.text, '今日は晴れです。\nIt is sunny today.');
    expect(result.lines[2].text, result.lines.first.text);
    expect(result.lines[3].text, isEmpty);
    expect(result.lines[4].text, 'Good night');
    expect(japanese.lines.first.text, '今日は晴れです。');
    expect(client.requests.single.host, 'translate.googleapis.com');
    expect(client.requests.single.queryParameters['q'], '今日は晴れです。\n明日も歩きます。');
    expect(client.requests.single.queryParameters.keys.toSet(), {
      'client',
      'sl',
      'tl',
      'dt',
      'q',
    });
    expect(client.closed, isTrue);
    final offline = LyricsTranslator(
      createClient: () => throw StateError('Must use disk'),
      cache: () => disk,
    );
    addTearDown(offline.close);
    expect(
      (await offline.translate(track, japanese, active: () => true)).plain,
      result.plain,
    );
    // Changed lyric text and another account cannot reuse that translation.
    await expectLater(
      offline.translate(track, Lyrics.parse('新しい歌'), active: () => true),
      throwsA(isA<TranslationFailure>()),
    );
    disk = MediaCache(Directory('${dir.path}/bob'));
    await expectLater(
      offline.translate(track, japanese, active: () => true),
      throwsA(isA<TranslationFailure>()),
    );
  });

  test('configured MyMemory first falls back to Google and supports English to Japanese', () async {
    final primary = Client([Response([], statusCode: 503)]);
    final secondary = Client([google('こんにちは')]);
    final clients = [primary, secondary];
    final translator = LyricsTranslator(
      createClient: () => clients.removeAt(0),
    );
    addTearDown(translator.close);
    final source = Lyrics.parse('[00:02]Hello');
    expect(
      LyricsTranslator.supports(
        source,
        direction: TranslationDirection.englishJapanese,
      ),
      isTrue,
    );
    final result = await translator.translate(
      track,
      source,
      active: () => true,
      first: TranslationSource.myMemory,
      fallback: TranslationSource.google,
      direction: TranslationDirection.englishJapanese,
    );
    expect(primary.requests.single.host, 'api.mymemory.translated.net');
    expect(primary.requests.single.queryParameters['langpair'], 'en|ja');
    expect(secondary.requests.single.queryParameters['sl'], 'en');
    expect(secondary.requests.single.queryParameters['tl'], 'ja');
    expect(result.lines.single.text, 'Hello\nこんにちは');
    expect(source.lines.single.text, 'Hello');
  });

  test(
    '429 falls back to documented no-key API and decodes entities',
    () async {
      final googleClient = Client([Response([], statusCode: 429)]);
      final fallback = Client([myMemory('It&#39;s sunny.\nWalk &amp; smile.')]);
      final clients = [googleClient, fallback];
      final translator = LyricsTranslator(
        createClient: () => clients.removeAt(0),
      );
      addTearDown(translator.close);
      final result = await translator.translate(
        track,
        japanese,
        active: () => true,
      );
      expect(result.lines.first.text, "今日は晴れです。\nIt's sunny.");
      expect(result.lines[1].text, '明日も歩きます。\nWalk & smile.');
      expect(fallback.requests.single.host, 'api.mymemory.translated.net');
      expect(fallback.requests.single.path, '/get');
      expect(fallback.requests.single.queryParameters['langpair'], 'ja|en');
      expect(
        utf8.encode(fallback.requests.single.queryParameters['q']!).length,
        lessThanOrEqualTo(500),
      );
      expect(googleClient.closed && fallback.closed, isTrue);
    },
  );

  test(
    'quota and changed line breaks never cache an error or replace originals',
    () async {
      final dir = await Directory.systemTemp.createTemp('auralis-quota-');
      final clients = [
        Client([Response([], statusCode: 429)]),
        Client([myMemory('LIMIT', quota: true)]),
        Client([google('One merged line')]),
        Client([myMemory('One merged line')]),
        Client([google('First\nSecond')]),
      ];
      final translator = LyricsTranslator(
        createClient: () => clients.removeAt(0),
        cache: () => MediaCache(dir),
      );
      addTearDown(() async {
        translator.close();
        await MediaCache.drain(dir);
        await dir.delete(recursive: true);
      });
      await expectLater(
        translator.translate(track, japanese, active: () => true),
        throwsA(isA<TranslationFailure>()),
      );
      expect(await dir.list().length, 0);
      await expectLater(
        translator.translate(track, japanese, active: () => true),
        throwsA(isA<TranslationFailure>()),
      );
      expect(await dir.list().length, 0);
      expect(
        (await translator.translate(track, japanese, active: () => true)).plain,
        contains('First'),
      );
      expect(japanese.lines.first.text, '今日は晴れです。');
    },
  );

  test(
    'late response after account change is discarded before disk write',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'auralis-late-translation-',
      );
      var disk = MediaCache(Directory('${dir.path}/alice'));
      final client = PendingTranslation();
      final translator = LyricsTranslator(
        createClient: () => client,
        cache: () => disk,
      );
      addTearDown(() async {
        translator.close();
        await MediaCache.drain(dir);
        await dir.delete(recursive: true);
      });
      final pending = translator.translate(track, japanese, active: () => true);
      final expectation = expectLater(
        pending,
        throwsA(isA<TranslationFailure>()),
      );
      while (client.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      disk = MediaCache(Directory('${dir.path}/bob'));
      client.pending.complete(Request(google('First\nSecond')));
      await expectation;
      expect(await dir.list(recursive: true).length, 0);
      expect(client.closed, isTrue);
    },
  );

  test('invalid and oversized responses close clients; unsupported lyrics do not call HTTP', () async {
    final bad = Client([Response(utf8.encode('not JSON'))]);
    final huge = Client([Response(List.filled(256 * 1024 + 1, 32))]);
    final translator = LyricsTranslator(
      createClient: () => bad.requests.isEmpty ? bad : huge,
    );
    addTearDown(translator.close);
    await expectLater(
      translator.translate(track, japanese, active: () => true),
      throwsA(isA<TranslationFailure>()),
    );
    expect(bad.closed && huge.closed, isTrue);
    final none = LyricsTranslator(
      createClient: () => throw StateError('No HTTP'),
    );
    addTearDown(none.close);
    expect(LyricsTranslator.supports(Lyrics.parse('Only English')), isFalse);
    await expectLater(
      none.translate(track, Lyrics.parse('Only English'), active: () => true),
      throwsA(isA<TranslationFailure>()),
    );
  });
}
