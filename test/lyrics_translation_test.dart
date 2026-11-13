import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_translation.dart';
import 'package:auralis/media_cache.dart';
import 'package:auralis/models.dart';
import 'package:auralis/storage.dart';
import 'package:crypto/crypto.dart';
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
  for (final provider in TranslationSource.values) {
    for (final (language, words) in [
      ('Spanish', 'Hola mundo'),
      ('French', 'Bonjour le monde'),
      ('German', 'Guten Morgen'),
      ('Bengali', 'আজ সুন্দর দিন'),
      ('Hindi', 'आज अच्छा दिन है'),
      ('Arabic', 'مرحبا بالعالم'),
      ('Russian', 'Привет мир'),
      ('Korean', '안녕하세요'),
      ('Chinese', '你好世界'),
      ('Japanese', '今日は晴れです。'),
      ('Thai', 'สวัสดี'),
      ('Greek', 'Καλημέρα'),
    ]) {
      test(
        '$language lyrics auto-detect to English with ${provider.label}',
        () async {
          final source = Lyrics.parse('[00:01]$words\n[00:03]$words');
          final client = Client([
            provider == TranslationSource.google
                ? google('English translation')
                : myMemory('English translation'),
          ]);
          final translator = LyricsTranslator(createClient: () => client);
          addTearDown(translator.close);
          expect(LyricsTranslator.supports(source), isTrue);
          final result = await translator.translate(
            track,
            source,
            active: () => true,
            first: provider,
            fallback: null,
          );
          final query = client.requests.single.queryParameters;
          if (provider == TranslationSource.google) {
            expect(query['sl'], 'auto');
            expect(query['tl'], 'en');
          } else {
            expect(query['langpair'], 'autodetect|en');
          }
          expect(query['q'], words, reason: 'Deduplicate repeated choruses');
          expect(
            result.lines.map((line) => line.time),
            source.lines.map((line) => line.time),
          );
          expect(result.lines.first.text, '$words\nEnglish translation');
          expect(result.lines.last.text, result.lines.first.text);
          expect(source.lines.first.text, words);
        },
      );
    }
  }

  test(
    'English-only auto-detection does not duplicate original lyrics',
    () async {
      final source = Lyrics.parse('[00:01]Good morning\n[00:02]Good night');
      final client = Client([google('Good morning\nGood night')]);
      final translator = LyricsTranslator(createClient: () => client);
      addTearDown(translator.close);
      expect(
        LyricsTranslator.supports(source),
        isTrue,
        reason: 'ASCII alone cannot distinguish English from other languages',
      );
      final translated = await translator.translate(
        track,
        source,
        active: () => true,
      );
      expect(translated.plain, source.plain);
      expect(source.lines.first.text, 'Good morning');
    },
  );

  test('existing Japanese-to-English preference upgrades without resetting other settings', () {
    final settings = AppSettings(File('unused'));
    settings.applyJson({
      ...settings.toJson(),
      'translationDirection': 'japaneseEnglish',
      'translationFirst': 'myMemory',
      'automaticTranslation': false,
    });
    expect(settings.translationDirection.label, 'Any language → English');
    expect(settings.translationDirection.source, 'auto');
    expect(settings.translationDirection.target, 'en');
    expect(settings.translationFirst, TranslationSource.myMemory);
    expect(settings.automaticTranslation, isFalse);
    expect(
      settings.toJson()['translationDirection'],
      'japaneseEnglish',
      reason: 'Keep backup and Worker Sync compatibility',
    );
  });

  test(
    'auto-detected translations never reuse old Japanese-only disk caches',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'auralis-auto-translation-',
      );
      final disk = MediaCache(dir);
      final source = Lyrics.parse('[00:01]你好世界');
      final fingerprint = sha256.convert(
        utf8.encode(
          jsonEncode([
            'free-ja-en-v1',
            source.plain,
            for (final line in source.lines)
              [line.time.inMilliseconds, line.text],
          ]),
        ),
      );
      await disk.write(
        track,
        'translation-en-$fingerprint',
        utf8.encode(jsonEncode(['Incorrect old translation'])),
      );
      final client = Client([google('Hello world')]);
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
        source,
        active: () => true,
      );
      expect(result.lines.single.text, '你好世界\nHello world');
      expect(client.requests, hasLength(1));
    },
  );

  test('bilingual lyrics keep timestamps, breaks, English and deduplicated choruses; restart is offline', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-translation-');
    var disk = MediaCache(Directory('${dir.path}/alice'));
    final client = Client([
      google('It is sunny today.\nI will walk tomorrow.\nGood night'),
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
    expect(
      client.requests.single.queryParameters['q'],
      '今日は晴れです。\n明日も歩きます。\nGood night',
    );
    expect(client.requests.single.queryParameters['sl'], 'auto');
    expect(client.requests.single.queryParameters['tl'], 'en');
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
      final fallback = Client([
        myMemory('It&#39;s sunny.\nWalk &amp; smile.\nGood night'),
      ]);
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
      expect(
        fallback.requests.single.queryParameters['langpair'],
        'autodetect|en',
      );
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
        Client([google('First\nSecond\nGood night')]),
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
    expect(LyricsTranslator.supports(Lyrics.parse('♪ ... 123')), isFalse);
    await expectLater(
      none.translate(track, Lyrics.parse('♪ ... 123'), active: () => true),
      throwsA(isA<TranslationFailure>()),
    );
  });
}
