import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/lyrics.dart';
import 'package:auralis/media_cache.dart';
import 'package:auralis/models.dart';
import 'package:auralis/storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lyrics_test.dart' show song;
import 'updater_test.dart' show Client, Request, Response;

Response jsonResponse(Object value) => Response(utf8.encode(jsonEncode(value)));

class WaitingClient extends Client {
  WaitingClient() : super([]);
  final ready = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requests.add(url);
    return ready.future;
  }
}

void main() {
  test(
    'automatic preparation finds and translates while preserving originals',
    () async {
      final preferences = AppSettings(File('unused'));
      final client = Client([
        jsonResponse({'syncedLyrics': '[00:02]今日は晴れです。'}),
        jsonResponse([
          [
            ['It is sunny today.', '今日は晴れです。'],
          ],
          null,
          'ja',
        ]),
      ]);
      final repository = LyricsRepository(
        preferences: preferences,
        createClient: () => client,
      );
      addTearDown(repository.close);
      final source = await repository.prepare(
        song,
        active: () => true,
        loadEmbedded: (_) async => null,
      );
      expect(client.requests.map((r) => r.host), [
        'lrclib.net',
        'translate.googleapis.com',
      ]);
      expect(source!.lines.single.text, '今日は晴れです。');
      expect(repository.cached(song), same(source));
      expect(
        repository.translated(song, source)!.lines.single.text,
        '今日は晴れです。\nIt is sunny today.',
      );
    },
  );

  test(
    'background translation continues after the lyrics view stops waiting',
    () async {
      final client = WaitingClient();
      final repository = LyricsRepository(createClient: () => client);
      final source = Lyrics.parse('[00:02]今日は晴れです。');
      repository.save(song, source);
      addTearDown(repository.close);
      var viewActive = true;
      final view = repository.translateJapanese(
        song,
        source,
        active: () => viewActive,
      );
      final background = repository.translateJapanese(
        song,
        source,
        active: () => true,
      );
      expect(view, same(background));
      await Future<void>.delayed(Duration.zero);
      viewActive = false;
      client.ready.complete(
        Request(
          jsonResponse([
            [
              ['Sunny', '今日は晴れです。'],
            ],
            null,
            'ja',
          ]),
        ),
      );
      expect((await background).plain, '今日は晴れです。\nSunny');
      expect(repository.translated(song, source), isNotNull);
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'a new lyric import wins over a late embedded-lyric preparation',
    () async {
      final preferences = AppSettings(File('unused'))
        ..automaticTranslation = false;
      final repository = LyricsRepository(
        preferences: preferences,
        createClient: () =>
            throw StateError('Imported lyrics must avoid lookup'),
      );
      addTearDown(repository.close);
      final embedded = Completer<Lyrics?>();
      final work = repository.prepare(
        song,
        active: () => true,
        loadEmbedded: (_) => embedded.future,
      );
      await Future<void>.delayed(Duration.zero);
      final imported = Lyrics.parse('Imported original', imported: true);
      repository.save(song, imported);
      embedded.complete(
        Lyrics.parse('Older embedded original', embedded: true),
      );
      expect(await work, same(imported));
      expect(repository.cached(song), same(imported));
    },
  );

  test(
    'lyrics source order and disabled fallback follow preferences',
    () async {
      final preferences = AppSettings(File('unused'))
        ..lyricsFirst = LyricsSource.lyricsOvh
        ..lyricsFallback = LyricsSource.lrclib
        ..automaticTranslation = false;
      final client = Client([
        jsonResponse({'lyrics': 'Preferred original words'}),
      ]);
      final repository = LyricsRepository(
        preferences: preferences,
        createClient: () => client,
      );
      addTearDown(repository.close);
      final result = await repository.prepare(
        song,
        active: () => true,
        loadEmbedded: (_) async => null,
      );
      expect(result!.provider, 'lyrics.ovh');
      expect(client.requests.single.host, 'api.lyrics.ovh');
      preferences.lyricsFirst = LyricsSource.lrclib;
      preferences.lyricsFallback = null;
      final missing = Client([Response([], statusCode: 404), jsonResponse([])]);
      final onlyPrimary = LyricsRepository(
        preferences: preferences,
        createClient: () => missing,
      );
      addTearDown(onlyPrimary.close);
      expect(await onlyPrimary.find(song), isNull);
      expect(missing.requests.map((r) => r.host), ['lrclib.net', 'lrclib.net']);
    },
  );

  test('missing, empty, invalid, oversized and failed first sources fall through to lyrics.ovh', () async {
    for (final first in [
      Response([], statusCode: 404),
      Response([], statusCode: 503),
      jsonResponse({'plainLyrics': '  '}),
      jsonResponse({'plainLyrics': 42}),
      Response(utf8.encode('not JSON')),
      Response(List.filled(512 * 1024 + 1, 32)),
    ]) {
      final clients = [
        Client([first]),
        Client([jsonResponse([])]),
        Client([
          jsonResponse({'lyrics': 'Fallback original words\nAnother line'}),
        ]),
      ];
      var index = 0;
      final repository = LyricsRepository(createClient: () => clients[index++]);
      try {
        final result = await repository.find(song);
        expect(result!.plain, 'Fallback original words\nAnother line');
        expect(result.lines, isEmpty);
        expect(result.provider, 'lyrics.ovh');
        expect(result.online, isTrue);
        expect(clients.map((c) => c.requests.single.host), [
          'lrclib.net',
          'lrclib.net',
          'api.lyrics.ovh',
        ]);
        expect(clients.map((c) => c.closed), everyElement(isTrue));
        expect(repository.cached(song), same(result));
      } finally {
        repository.close();
      }
    }
  });

  test('search rejects wrong artist/version and chooses the closest matching synced record', () async {
    Map<String, Object?> record(
      String words, {
      String artist = 'Test artist',
      num? duration = 120,
      bool synced = true,
    }) => {
      'trackName': 'Evening Waves',
      'artistName': artist,
      'duration': duration,
      if (synced) 'syncedLyrics': '[00:02]$words' else 'plainLyrics': words,
    };
    final client = Client([
      Response([], statusCode: 404),
      jsonResponse([
        record('Wrong artist', artist: 'Someone else'),
        record('Wrong length', duration: 180),
        record('Less precise', duration: 119, synced: false),
        record('Desired original words'),
        record('Unknown length', duration: null),
        {
          'trackName': 'Evening Waves',
          'artistName': 'Test artist',
          'plainLyrics': 42,
        },
      ]),
    ]);
    final repository = LyricsRepository(createClient: () => client);
    addTearDown(repository.close);
    final result = await repository.find(song);
    expect(result!.lines.single.text, 'Desired original words');
    expect(result.provider, 'LRCLIB');
    expect(client.requests.map((u) => u.path), ['/api/get', '/api/search']);
    expect(client.requests.last.queryParameters, {
      'track_name': song.title,
      'artist_name': song.artist,
    });
  });

  test(
    'all clean misses are distinct from outages and can be retried',
    () async {
      final client = Client([
        Response([], statusCode: 404),
        jsonResponse([]),
        Response([], statusCode: 404),
        jsonResponse({'plainLyrics': 'Now available'}),
      ]);
      final repository = LyricsRepository(createClient: () => client);
      addTearDown(repository.close);
      expect(await repository.find(song), isNull);
      expect(repository.contains(song), isTrue);
      expect((await repository.find(song))!.plain, 'Now available');
    },
  );

  test('fallback source persists and explicit retry bypasses cache without erasing it on failure', () async {
    final dir = await Directory.systemTemp.createTemp(
      'auralis-fallback-cache-',
    );
    final disk = MediaCache(dir);
    final client = Client([
      Response([], statusCode: 503),
      jsonResponse([]),
      jsonResponse({'lyrics': 'Saved fallback words'}),
    ]);
    final repository = LyricsRepository(
      createClient: () => client,
      cache: () => disk,
    );
    final retryClient = Client([
      Response([], statusCode: 404),
      jsonResponse([]),
      Response([], statusCode: 404),
    ]);
    final reopened = LyricsRepository(
      createClient: () => retryClient,
      cache: () => disk,
    );
    addTearDown(() async {
      repository.close();
      reopened.close();
      await MediaCache.drain(dir);
      await dir.delete(recursive: true);
    });
    await repository.find(song);
    await MediaCache.drain(dir);
    final saved = await reopened.find(song);
    expect(saved!.provider, 'lyrics.ovh');
    expect(retryClient.requests, isEmpty);
    expect(await reopened.find(song, refresh: true), isNull);
    expect(retryClient.requests, hasLength(3));
    expect(reopened.cached(song), same(saved));
  });

  test('lyrics.ovh path safely encodes metadata and never includes private channel identifiers', () async {
    const special = Track(
      id: 'private-message',
      title: '日本語 / 題?x#%',
      artist: 'Artist/Name',
      source: 'Private channel',
    );
    final client = Client([
      Response([], statusCode: 404),
      jsonResponse([]),
      jsonResponse({'lyrics': 'Original words'}),
    ]);
    final repository = LyricsRepository(createClient: () => client);
    addTearDown(repository.close);
    await repository.find(special);
    final uri = client.requests.last;
    expect(uri.scheme, 'https');
    expect(uri.host, 'api.lyrics.ovh');
    expect(uri.pathSegments, ['v1', special.artist, special.title]);
    expect(uri.query, isEmpty);
    expect(uri.toString(), isNot(contains('private-message')));
    expect(uri.toString(), isNot(contains('Private')));
  });

  testWidgets(
    'a stalled provider times out, closes and lets another source succeed',
    (tester) async {
      final waiting = WaitingClient();
      final search = Client([jsonResponse([])]);
      final fallback = Client([
        jsonResponse({'lyrics': 'Timeout fallback words'}),
      ]);
      final clients = [waiting, search, fallback];
      var index = 0;
      final repository = LyricsRepository(createClient: () => clients[index++]);
      addTearDown(repository.close);
      final pending = repository.find(song);
      await tester.pump(const Duration(seconds: 8));
      final result = await pending;
      expect(result!.plain, 'Timeout fallback words');
      expect(waiting.closed, isTrue);
      // The timed-out provider cannot later replace the successful result.
      waiting.ready.complete(
        Request(jsonResponse({'plainLyrics': 'Stale first response'})),
      );
      await tester.pump();
      expect(repository.cached(song), same(result));
    },
  );

  test(
    'closing during a request prevents any further fallback calls',
    () async {
      final waiting = WaitingClient();
      var clients = 0;
      final repository = LyricsRepository(
        createClient: () {
          clients++;
          return waiting;
        },
      );
      final pending = repository.find(song);
      repository.close();
      waiting.ready.complete(Request(Response([], statusCode: 404)));
      expect(await pending, isNull);
      expect(clients, 1);
      expect(waiting.closed, isTrue);
    },
  );
}
