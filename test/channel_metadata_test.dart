import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/channel_metadata.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const first = ChannelTitle(
  id: '1',
  provider: 'AniList',
  title: 'Attack on Titan',
  aliases: ['Shingeki no Kyojin'],
  year: 2013,
);
const third = ChannelTitle(
  id: '3',
  provider: 'AniList',
  title: 'Attack on Titan Season 3',
  aliases: ['Shingeki no Kyojin 3'],
  year: 2018,
);

Map<String, Object?> anime(String title, {int id = 1}) => {
  'id': id,
  'title': {'english': title, 'romaji': title, 'native': null},
  'description': 'A <b>story</b> &amp; a journey.',
  'genres': ['Drama'],
  'seasonYear': 2020,
  'averageScore': 85,
  'episodes': 12,
  'duration': 24,
  'status': 'FINISHED',
  'format': 'TV',
  'studios': {
    'nodes': [
      {'name': 'Studio'},
    ],
  },
};
Object animeResponse(List<Object?> rows) => {
  'data': {
    'Page': {'media': rows},
  },
};

void main() {
  test(
    'release tags, abbreviations, seasons and non-Latin names stay meaningful',
    () {
      expect(
        cleanChannelTitle('[1080p] AOT S03 Dual Audio @some_channel'),
        'attack on titan season 3',
      );
      expect(
        cleanChannelTitle('JJK 2nd Season x265'),
        'jujutsu kaisen season 2',
      );
      expect(cleanChannelTitle('炎炎ノ消防隊 S03'), '炎炎ノ消防隊 season 3');
      expect(cleanChannelTitle('Overlord III'), 'overlord 3');
      expect(
        ChannelTitleMatcher.confident(
          'AOT S03 1080p',
          ChannelTitleMatcher.ranked('AOT S03 1080p', [first, third]),
        ),
        third,
      );
      expect(
        ChannelTitleMatcher.confident('Shingeki no Kyojin', [first]),
        first,
      );
      expect(
        ChannelTitleMatcher.confident('Attack on Titan S02', [first, third]),
        isNull,
      );
      expect(ChannelTitleMatcher.confident('Attack on Titan', [third]), isNull);
      expect(ChannelTitleMatcher.confident('AOT S01', [first]), first);
    },
  );

  test(
    'ambiguity and conflicting years never select the first result blindly',
    () {
      const original = ChannelTitle(
        id: '1',
        provider: 'Wikipedia',
        title: 'Dune',
        year: 1984,
      );
      const remake = ChannelTitle(
        id: '2',
        provider: 'Wikipedia',
        title: 'Dune',
        year: 2021,
      );
      expect(
        ChannelTitleMatcher.confident(
          'Dune',
          ChannelTitleMatcher.ranked('Dune', [original, remake]),
        ),
        isNull,
      );
      expect(
        ChannelTitleMatcher.confident(
          'Dune 2021',
          ChannelTitleMatcher.ranked('Dune 2021', [original, remake]),
        ),
        remake,
      );
      expect(ChannelTitleMatcher.confident('random channel', [first]), isNull);
      expect(
        metadataPlainText('<p>A &amp; B<br>Hi &#39;there&#39;</p>'),
        "A & B\nHi 'there'",
      );
    },
  );

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('auralis-metadata-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('AniList is first, in-flight requests coalesce, and restart uses saved metadata', () async {
    var calls = 0;
    final repository = ChannelMetadataRepository(
      root,
      fetch: (uri, body) async {
        calls++;
        expect(uri.host, 'graphql.anilist.co');
        expect(body!['variables'], {'search': 'example'});
        return animeResponse([anime('Example')]);
      },
    );
    addTearDown(repository.close);
    final matches = await Future.wait([
      repository.identify(-1, 'Example'),
      repository.identify(-1, 'Example'),
    ]);
    expect(calls, 1);
    expect(matches.first.selected?.title, 'Example');
    expect(matches.first.selected?.description, 'A story & a journey.');
    expect(matches.first.selected?.episodes, 12);
    final restarted = ChannelMetadataRepository(
      root,
      fetch: (_, _) async => throw StateError('offline'),
    );
    addTearDown(restarted.close);
    expect(
      (await restarted.identify(-1, 'Example')).selected?.title,
      'Example',
    );
    expect((await repository.search('Example')).single.title, 'Example');
    expect(calls, 1);
  });

  test('TV series and films still resolve when AniList fails', () async {
    final hosts = <String>[];
    final repository = ChannelMetadataRepository(
      root,
      fetch: (uri, _) async {
        hosts.add(uri.host);
        if (uri.host == 'graphql.anilist.co') {
          throw const HttpException('offline');
        }
        if (uri.path.endsWith('/images')) {
          return [
            {
              'type': 'background',
              'resolutions': {
                'original': {'url': 'https://static.tvmaze.com/banner.jpg'},
              },
            },
          ];
        }
        if (uri.path.endsWith('/episodes')) return [{}, {}, {}];
        if (uri.host == 'api.tvmaze.com') {
          return [
            {
              'show': {
                'id': 10,
                'name': 'Example',
                'summary': '<p>Overview</p>',
                'premiered': '2020-01-01',
                'rating': {'average': 8.5},
                'genres': ['Drama'],
              },
            },
          ];
        }
        return {
          'query': {
            'pages': [
              {
                'pageid': 2,
                'title': 'Other (2023 film)',
                'extract': 'Film overview',
                'terms': {
                  'description': ['2023 film'],
                },
              },
            ],
          },
        };
      },
    );
    addTearDown(repository.close);
    final result = await repository.identify(-2, 'Example');
    expect(result.selected?.provider, 'TVmaze');
    expect(result.selected?.banner, 'https://static.tvmaze.com/banner.jpg');
    expect(result.selected?.episodes, 3);
    expect(hosts.first, 'graphql.anilist.co');
    final films = await repository.search('Other', kind: MetadataKind.film);
    expect(films.single.title, 'Other');
    expect(films.single.year, 2023);
  });

  test(
    'manual selection wins a late automatic response and survives renaming',
    () async {
      final pending = Completer<Object?>();
      final repository = ChannelMetadataRepository(
        root,
        fetch: (_, _) => pending.future,
      );
      addTearDown(repository.close);
      final auto = repository.identify(-3, 'Example');
      // Ensure the lookup has started, then pin another title.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await repository.select(-3, 'Example', third);
      pending.complete(animeResponse([anime('Example')]));
      expect((await auto).selected?.id, third.id);
      expect(
        (await repository.identify(-3, 'Renamed channel')).selected?.id,
        third.id,
      );
      expect((await repository.identify(-3, 'Renamed channel')).manual, isTrue);
    },
  );

  test(
    'a failed lookup does not poison the cache or replace saved information',
    () async {
      var offline = false;
      var date = DateTime(2026, 1, 1);
      final repository = ChannelMetadataRepository(
        root,
        now: () => date,
        fetch: (uri, _) async {
          if (offline) throw const HttpException('offline');
          if (uri.host == 'graphql.anilist.co') {
            return animeResponse([anime('Example')]);
          }
          return [];
        },
      );
      addTearDown(repository.close);
      expect((await repository.identify(-4, 'Example')).selected, isNotNull);
      date = date.add(const Duration(days: 8));
      offline = true;
      expect(
        (await repository.identify(-4, 'Example')).selected?.title,
        'Example',
      );
      expect(
        (await repository.identify(-4, 'Different channel name')).selected,
        isNull,
      );
      final unknown = await repository.identify(-5, 'New title');
      expect(unknown.failed, isTrue);
      offline = false;
      expect(
        (await repository.identify(-5, 'Example')).selected?.title,
        'Example',
      );
    },
  );

  test(
    'existing artwork is served from disk without an HTTP request',
    () async {
      const url = 'https://example.com/poster.jpg';
      final hash = sha256.convert(utf8.encode(url));
      final file = File('${root.path}/images/$hash.img');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      final repository = ChannelMetadataRepository(root);
      addTearDown(repository.close);
      expect((await repository.image(url))?.path, file.path);
    },
  );
}
