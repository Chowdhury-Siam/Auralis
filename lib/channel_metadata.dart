import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'json_processing.dart';

import 'package:crypto/crypto.dart';

typedef MetadataFetch = Future<Object?> Function(
  Uri uri,
  Map<String, Object?>? body,
);

enum MetadataKind { any, anime, series, film }

/// Public catalogue information, independent of Telegram sessions and playback.
class ChannelTitle {
  const ChannelTitle({
    required this.id,
    required this.provider,
    required this.title,
    this.aliases = const [],
    this.description = '',
    this.cover,
    this.banner,
    this.genres = const [],
    this.year,
    this.status,
    this.rating,
    this.episodes,
    this.minutes,
    this.studio,
    this.nativeTitle,
    this.url,
    this.format,
  });
  final String id, provider, title, description;
  final List<String> aliases, genres;
  final String? cover, banner, status, studio, nativeTitle, url, format;
  final int? year, episodes, minutes;
  final double? rating;
  String get key => '$provider:$id';
  Map<String, Object?> toJson() => {
    'id': id,
    'provider': provider,
    'title': title,
    'aliases': aliases,
    'description': description,
    'cover': cover,
    'banner': banner,
    'genres': genres,
    'year': year,
    'status': status,
    'rating': rating,
    'episodes': episodes,
    'minutes': minutes,
    'studio': studio,
    'nativeTitle': nativeTitle,
    'url': url,
    'format': format,
  };
  factory ChannelTitle.fromJson(Map<String, dynamic> j) => ChannelTitle(
    id: j['id'] as String,
    provider: j['provider'] as String,
    title: j['title'] as String,
    aliases: _strings(j['aliases']),
    description: j['description'] as String? ?? '',
    cover: j['cover'] as String?,
    banner: j['banner'] as String?,
    genres: _strings(j['genres']),
    year: j['year'] as int?,
    status: j['status'] as String?,
    rating: (j['rating'] as num?)?.toDouble(),
    episodes: j['episodes'] as int?,
    minutes: j['minutes'] as int?,
    studio: j['studio'] as String?,
    nativeTitle: j['nativeTitle'] as String?,
    url: j['url'] as String?,
    format: j['format'] as String?,
  );
}

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : [];

String metadataPlainText(String value) => value
    .replaceAll(RegExp(r'<br\s*/?>|</p>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|\d+);'), (m) {
      final s = m[1]!;
      final code = int.tryParse(
        s.startsWith('x') ? s.substring(1) : s,
        radix: s.startsWith('x') ? 16 : 10,
      );
      return code != null &&
              code <= 0x10ffff &&
              !(code >= 0xd800 && code <= 0xdfff)
          ? String.fromCharCode(code)
          : '';
    })
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// Remove release tags, retaining title words, non-Latin letters and seasons.
String cleanChannelTitle(String value) {
  var s = value
      .replaceAll(RegExp(r'https?://\S+|@\w+'), ' ')
      .replaceAll(
        RegExp(
          r'\b(?:480|720|1080|1440|2160)p\b|\b[248]k\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'\b(?:dual|multi)[ -]*(?:audio|sub(?:s|bed)?)\b|\b(?:judas|subsplease|erai[ -]raws|ember|asw|x26[45]|hevc|av1|aac|bluray|blu-ray|web-dl|webrip|hdtv|batch|complete|completed|ongoing|dubbed|dub|subbed|sub|eng(?:lish)?|hindi|bangla|telegram|channel)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAllMapped(
        RegExp(r'\bs(?:eason)?\s*0*(\d+)\b', caseSensitive: false),
        (m) => ' season ${int.parse(m[1]!)} ',
      )
      .replaceAllMapped(
        RegExp(r'\b(\d+)(?:st|nd|rd|th)\s+season\b', caseSensitive: false),
        (m) => ' season ${m[1]} ',
      )
      .replaceAllMapped(
        RegExp(r'\bpart\s*0*(\d+)\b', caseSensitive: false),
        (m) => ' part ${int.parse(m[1]!)} ',
      )
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .toLowerCase();
  s = s.replaceAllMapped(
    RegExp(r'\b(ii|iii|iv|v|vi)\b'),
    (m) => const {'ii': '2', 'iii': '3', 'iv': '4', 'v': '5', 'vi': '6'}[m[1]]!,
  );
  s = s.replaceAllMapped(
    RegExp(r'\b(aot|snk|jjk|kny|mha|bnha|fmab|hxh|opm|csm|sao)\b'),
    (m) => const {
      'aot': 'attack on titan',
      'snk': 'shingeki no kyojin',
      'jjk': 'jujutsu kaisen',
      'kny': 'kimetsu no yaiba',
      'mha': 'my hero academia',
      'bnha': 'boku no hero academia',
      'fmab': 'fullmetal alchemist brotherhood',
      'hxh': 'hunter x hunter',
      'opm': 'one punch man',
      'csm': 'chainsaw man',
      'sao': 'sword art online',
    }[m[1]]!,
  );
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class ChannelTitleMatcher {
  static double score(String channel, ChannelTitle item) {
    final query = cleanChannelTitle(channel);
    if (query.isEmpty) return 0;
    var best = 0.0;
    for (final alias in [item.title, ...item.aliases]) {
      final name = cleanChannelTitle(alias);
      if (name.isEmpty) continue;
      final qNumbers = RegExp(r'\b\d+\b')
          .allMatches(query)
          .map((m) => m[0]!)
          .toSet();
      final nNumbers = RegExp(r'\b\d+\b')
          .allMatches(name)
          .map((m) => m[0]!)
          .toSet();
      final year = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(query)?[0];
      if (year != null && item.year != null && item.year.toString() != year) {
        continue;
      }
      qNumbers.remove(year);
      nNumbers.remove(item.year?.toString());
      final implicitFirst =
          nNumbers.isEmpty && RegExp(r'\bseason 1\b').hasMatch(query);
      if (implicitFirst) qNumbers.remove('1');
      // Never assume a sequel/season when its number conflicts or is missing.
      if (qNumbers.isNotEmpty && !nNumbers.containsAll(qNumbers)) continue;
      final q =
          (implicitFirst
                  ? query.replaceAll(RegExp(r'\bseason 1\b'), '')
                  : query)
              .replaceAll(RegExp(r'\b(?:season|part|19\d{2}|20\d{2})\b'), '')
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ');
      final n = name
          .replaceAll(RegExp(r'\b(?:season|part|19\d{2}|20\d{2})\b'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      double value;
      if (q == n) {
        value = 1;
      } else {
        final a = q.split(' ').toSet(), b = n.split(' ').toSet();
        value = 2 * a.intersection(b).length / (a.length + b.length);
        final initials = n
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .join();
        if (!q.contains(' ') && q.length >= 3 && q == initials) value = .9;
      }
      if (qNumbers.isEmpty && nNumbers.isNotEmpty) value *= .75;
      if (value > best) best = value;
    }
    return best;
  }

  static List<ChannelTitle> ranked(String query, Iterable<ChannelTitle> items) {
    final rows = {for (final item in items) item.key: item}.values.toList();
    rows.sort((a, b) => score(query, b).compareTo(score(query, a)));
    return rows;
  }

  static ChannelTitle? confident(String query, List<ChannelTitle> rows) {
    if (rows.isEmpty || score(query, rows.first) < .9) return null;
    if (rows.length > 1 &&
        score(query, rows.first) - score(query, rows[1]) < .12) {
      return null;
    }
    return rows.first;
  }
}

class MetadataMatch {
  const MetadataMatch({
    this.selected,
    this.candidates = const [],
    this.manual = false,
    this.failed = false,
  });
  final ChannelTitle? selected;
  final List<ChannelTitle> candidates;
  final bool manual, failed;
}

class ChannelMetadataRepository {
  ChannelMetadataRepository(
    this.directory, {
    MetadataFetch? fetch,
    DateTime Function()? now,
  }) : _customFetch = fetch,
       _now = now ?? DateTime.now;
  final Directory directory;
  final MetadataFetch? _customFetch;
  final DateTime Function() _now;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final _identifying = <(int, String), Future<MetadataMatch>>{};
  final _searching = <String, Future<List<ChannelTitle>>>{};
  final _images = <String, Future<File?>>{};
  final _revisions = <int, int>{};
  final _blocked = <String, DateTime>{};
  Future<void> _requests = Future.value(), _writes = Future.value();
  DateTime? _lastRequest;
  bool _closed = false;
  String _hash(String s) => sha256.convert(utf8.encode(s)).toString();
  File _file(String key) => File('${directory.path}/$key.json');

  Future<Map<String, dynamic>?> _read(String key) async {
    try {
      return jsonDecode(await _file(key).readAsString())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, Map<String, Object?> value) {
    final operation = _writes.then((_) async {
      if (_closed) return;
      try {
        await directory.create(recursive: true);
        final file = _file(key), temp = File('${_file(key).path}.tmp');
        await temp.writeAsString(jsonEncode(value), flush: true);
        if (Platform.isWindows && await file.exists()) await file.delete();
        await temp.rename(file.path);
      } catch (_) {
        /* Metadata cache failure must never interrupt videos. */
      }
    });
    _writes = operation;
    return operation;
  }

  Future<Object?> _request(Uri uri, [Map<String, Object?>? body]) async {
    if (_closed) throw StateError('Metadata closed');
    if (_customFetch != null) return _customFetch(uri, body);
    final completer = Completer<Object?>();
    _requests = _requests.then((_) async {
      try {
        if (_closed) throw StateError('Metadata closed');
        if (_blocked[uri.host]?.isAfter(_now()) == true) {
          throw const HttpException('Catalogue rate limited');
        }
        final last = _lastRequest;
        if (last != null) {
          final delay =
              const Duration(milliseconds: 2100) - _now().difference(last);
          if (delay > Duration.zero) await Future<void>.delayed(delay);
        }
        if (_closed) throw StateError('Metadata closed');
        _lastRequest = _now();
        final request = await _client.openUrl(
          body == null ? 'GET' : 'POST',
          uri,
        );
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Auralis/1.0 (https://github.com/Chowdhury-Siam/Auralis)',
        );
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode == 429) {
          final seconds =
              int.tryParse(response.headers.value('retry-after') ?? '') ?? 60;
          _blocked[uri.host] = _now().add(
            Duration(seconds: seconds.clamp(30, 3600).toInt()),
          );
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw HttpException('Catalogue unavailable (${response.statusCode})');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 10),
        )) {
          bytes.add(chunk);
          if (bytes.length > 4 * 1024 * 1024) {
            throw const FormatException('Catalogue response too large');
          }
        }
        completer.complete(await decodeJsonBytes(bytes.takeBytes()));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<List<ChannelTitle>> search(
    String query, {
    MetadataKind kind = MetadataKind.any,
  }) {
    query = cleanChannelTitle(query);
    if (query.isEmpty) return Future.value([]);
    final key = '${kind.name}:$query';
    return _searching.putIfAbsent(
      key,
      () => _search(query, kind).whenComplete(() {
        _searching.remove(key);
      }),
    );
  }

  Future<List<ChannelTitle>> _search(String query, MetadataKind kind) async {
    final key = 'search-${_hash('${kind.name}:$query')}';
    final cached = await _read(key);
    final stamp = DateTime.tryParse(cached?['at'] as String? ?? '');
    List<ChannelTitle> rows(Map<String, dynamic> value) =>
        (value['rows'] as List)
            .map((j) => ChannelTitle.fromJson(j as Map<String, dynamic>))
            .toList();
    if (cached != null &&
        stamp != null &&
        _now().difference(stamp) <
            ((cached['rows'] as List?)?.isEmpty == true
                ? const Duration(hours: 6)
                : const Duration(days: 7))) {
      try {
        return rows(cached);
      } catch (_) {
        /* Ignore invalid caches. */
      }
    }
    final items = <ChannelTitle>[];
    var successes = 0;
    for (final provider in [
      if (kind == MetadataKind.any || kind == MetadataKind.anime) _anime,
      if (kind == MetadataKind.any || kind == MetadataKind.series) _series,
      if (kind == MetadataKind.any || kind == MetadataKind.film) _films,
    ]) {
      try {
        items.addAll(await provider(query));
        successes++;
      } catch (_) {
        /* Try the next catalogue. */
      }
      // AniList is authoritative for a confident anime match.
      if (kind == MetadataKind.any &&
          items.isNotEmpty &&
          items.first.provider == 'AniList' &&
          ChannelTitleMatcher.confident(
                query,
                ChannelTitleMatcher.ranked(query, items),
              ) !=
              null) {
        break;
      }
    }
    if (successes == 0) {
      if (cached != null) {
        try {
          return rows(cached);
        } catch (_) {}
      }
      throw const HttpException(
        'Metadata services are unavailable. Try again later.',
      );
    }
    final ranked = ChannelTitleMatcher.ranked(query, items);
    await _write(key, {
      'at': _now().toIso8601String(),
      'rows': [for (final row in ranked) row.toJson()],
    });
    return ranked;
  }

  Future<MetadataMatch> identify(int channelId, String name) =>
      _identifying.putIfAbsent(
        (channelId, name),
        () => _identify(channelId, name).whenComplete(() {
          _identifying.remove((channelId, name));
        }),
      );

  Future<MetadataMatch> _identify(int id, String name) async {
    final revision = _revisions[id] ?? 0;
    final cached = await _read('channel-$id');
    final selected = cached?['selected'];
    ChannelTitle? previous;
    try {
      if (selected is Map<String, dynamic>) {
        previous = ChannelTitle.fromJson(selected);
      }
    } catch (_) {}
    if (cached?['manual'] == true && previous != null) {
      return MetadataMatch(selected: previous, manual: true);
    }
    final at = DateTime.tryParse(cached?['at'] as String? ?? '');
    final same = cached?['name'] == name;
    if (same &&
        at != null &&
        _now().difference(at) <
            (previous == null
                ? const Duration(hours: 6)
                : const Duration(days: 7))) {
      return MetadataMatch(selected: previous);
    }
    try {
      final candidates = await search(name);
      var title = ChannelTitleMatcher.confident(name, candidates);
      if (title != null) title = await _enrich(title);
      if ((_revisions[id] ?? 0) != revision) return await identifySaved(id);
      await _write('channel-$id', {
        'name': name,
        'at': _now().toIso8601String(),
        'manual': false,
        'selected': title?.toJson(),
      });
      return MetadataMatch(selected: title, candidates: candidates);
    } catch (_) {
      return MetadataMatch(selected: same ? previous : null, failed: true);
    }
  }

  Future<MetadataMatch> identifySaved(int id) async {
    await _writes;
    final value = await _read('channel-$id');
    final title = value?['selected'];
    return MetadataMatch(
      selected: title is Map<String, dynamic>
          ? ChannelTitle.fromJson(title)
          : null,
      manual: value?['manual'] == true,
    );
  }

  Future<void> select(int id, String name, ChannelTitle title) async {
    final revision = (_revisions[id] ?? 0) + 1;
    _revisions[id] = revision;
    title = await _enrich(title);
    if (_closed || _revisions[id] != revision) return;
    await _write('channel-$id', {
      'name': name,
      'at': _now().toIso8601String(),
      'manual': true,
      'selected': title.toJson(),
    });
  }

  Future<List<ChannelTitle>> _anime(
    String query, {
    bool simplified = false,
  }) async {
    final response = await _request(Uri.https('graphql.anilist.co', '/'), {
      'query': r'''query($search:String!){Page(page:1,perPage:12){media(search:$search,type:ANIME){id title{romaji english native} synonyms description(asHtml:false) coverImage{extraLarge large} bannerImage genres seasonYear status averageScore episodes duration format siteUrl studios(isMain:true){nodes{name}}}}}''',
      'variables': {'search': query},
    }) as Map<String, dynamic>;
    if (response['errors'] != null) {
      throw const FormatException('AniList unavailable');
    }
    final rows = response['data']?['Page']?['media'] as List? ?? [];
    final base = query
        .replaceAll(RegExp(r'\b(?:season|part) \d+\b'), '')
        .trim();
    if (rows.isEmpty && !simplified && base.isNotEmpty && base != query) {
      return _anime(base, simplified: true);
    }
    return [
      for (final m in rows)
        ChannelTitle(
          id: '${m['id']}',
          provider: 'AniList',
          title:
              (m['title']['english'] ??
                      m['title']['romaji'] ??
                      m['title']['native'])
                  as String,
          aliases: [
            for (final s in [
              m['title']['english'],
              m['title']['romaji'],
              m['title']['native'],
              ...?m['synonyms'],
            ])
              if (s is String) s,
          ],
          nativeTitle: m['title']['native'] as String?,
          description: metadataPlainText(m['description'] as String? ?? ''),
          cover:
              (m['coverImage']?['extraLarge'] ?? m['coverImage']?['large'])
                  as String?,
          banner: m['bannerImage'] as String?,
          genres: _strings(m['genres']),
          year: m['seasonYear'] as int?,
          status: (m['status'] as String?)?.replaceAll('_', ' '),
          rating: (m['averageScore'] as num?)?.toDouble(),
          episodes: m['episodes'] as int?,
          minutes: m['duration'] as int?,
          format: m['format'] as String?,
          studio: ((m['studios']?['nodes'] as List?) ?? [])
              .map((s) => s['name'])
              .join(', '),
          url: m['siteUrl'] as String?,
        ),
    ];
  }

  Future<List<ChannelTitle>> _series(String query) async {
    // Seasons belong to the TV show, not separate title matches.
    final term = query.replaceAll(RegExp(r'\bseason \d+\b'), '').trim();
    final rows = await _request(
      Uri.https('api.tvmaze.com', '/search/shows', {'q': term}),
    ) as List;
    return [
      for (final row in rows)
        if (row['show'] case final Map<String, dynamic> m)
          ChannelTitle(
            id: '${m['id']}',
            provider: 'TVmaze',
            title: m['name'] as String,
            description: metadataPlainText(m['summary'] as String? ?? ''),
            cover:
                (m['image']?['original'] ?? m['image']?['medium']) as String?,
            genres: _strings(m['genres']),
            year: int.tryParse('${m['premiered'] ?? ''}'.split('-').first),
            status: m['status'] as String?,
            rating: (m['rating']?['average'] as num?)?.toDouble(),
            minutes: (m['averageRuntime'] ?? m['runtime']) as int?,
            format: m['type'] as String?,
            studio:
                (m['network']?['name'] ?? m['webChannel']?['name']) as String?,
            url: m['url'] as String?,
          ),
    ];
  }

  Future<List<ChannelTitle>> _films(String query) async {
    final response = await _request(
      Uri.https('en.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'generator': 'search',
        'gsrsearch': '$query film',
        'gsrnamespace': '0',
        'gsrlimit': '8',
        'prop': 'extracts|pageimages|pageterms',
        'exintro': '1',
        'explaintext': '1',
        'exlimit': '8',
        'piprop': 'original',
        'pilimit': '8',
        'wbptterms': 'description|alias',
      }),
    ) as Map<String, dynamic>;
    if (response['error'] != null) {
      throw const FormatException('Wikipedia unavailable');
    }
    final pages = response['query']?['pages'] as List? ?? [];
    final results = <ChannelTitle>[];
    for (final p in pages) {
      final raw = p['title'] as String? ?? '';
      final descriptions = _strings(p['terms']?['description']);
      if (!RegExp(
        r'\bfilm\b',
        caseSensitive: false,
      ).hasMatch('$raw ${descriptions.join(' ')}')) {
        continue;
      }
      final year = RegExp(r'\b(?:19|20)\d{2}\b')
          .firstMatch('$raw ${descriptions.join(' ')}')?[0];
      results.add(
        ChannelTitle(
          id: '${p['pageid']}',
          provider: 'Wikipedia',
          title: raw.replaceAll(RegExp(r'\s*\([^)]*film\)'), ''),
          aliases: _strings(p['terms']?['alias']),
          description: metadataPlainText(p['extract'] as String? ?? ''),
          cover: p['original']?['source'] as String?,
          year: int.tryParse(year ?? ''),
          format: 'Film',
          url: 'https://en.wikipedia.org/?curid=${p['pageid']}',
        ),
      );
    }
    return results;
  }

  Future<ChannelTitle> _enrich(ChannelTitle title) async {
    if (title.provider != 'TVmaze') return title;
    final result = title.toJson();
    final key = 'details-${_hash(title.key)}';
    final cached = await _read(key);
    final stamp = DateTime.tryParse(cached?['at'] as String? ?? '');
    if (cached != null &&
        stamp != null &&
        _now().difference(stamp) < const Duration(days: 7)) {
      try {
        return ChannelTitle.fromJson(cached['title'] as Map<String, dynamic>);
      } catch (_) {}
    }
    try {
      final images = await _request(
        Uri.https('api.tvmaze.com', '/shows/${title.id}/images'),
      ) as List;
      final banners = images.where(
        (i) => i['type'] == 'background' || i['type'] == 'banner',
      );
      if (banners.isNotEmpty) {
        result['banner'] = banners.first['resolutions']?['original']?['url'];
      }
    } catch (_) {}
    try {
      final episodes = await _request(
        Uri.https('api.tvmaze.com', '/shows/${title.id}/episodes'),
      ) as List;
      result['episodes'] = episodes.length;
    } catch (_) {}
    await _write(key, {'at': _now().toIso8601String(), 'title': result});
    return ChannelTitle.fromJson(result);
  }

  Future<File?> image(String url) {
    final existing = _images[url];
    if (existing != null) return existing;
    final job = _image(url).whenComplete(() {
      _images.remove(url);
    });
    _images[url] = job;
    return job;
  }

  Future<File?> _image(String url) async {
    try {
      final file = File('${directory.path}/images/${_hash(url)}.img');
      if (await file.exists() && await file.length() > 0) return file;
      final uri = Uri.parse(url);
      if (_closed || uri.scheme != 'https' || uri.host.isEmpty) return null;
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200 ||
          response.headers.contentType?.primaryType != 'image') {
        await response.drain<void>();
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.add(chunk);
        if (bytes.length > 12 * 1024 * 1024) return null;
      }
      if (bytes.isEmpty || _closed) return null;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes.takeBytes());
      await temp.rename(file.path);
      unawaited(_trimImages(file));
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<void> _trimImages(File keep) async {
    try {
      final files = await keep.parent
          .list()
          .where((f) => f is File && f.path.endsWith('.img'))
          .cast<File>()
          .toList();
      final stats = {for (final file in files) file: await file.stat()};
      files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
      var bytes = stats.values.fold<int>(0, (sum, s) => sum + s.size);
      var count = files.length;
      for (final file in files) {
        if (bytes <= 100 * 1024 * 1024 && count <= 120) break;
        if (file.path == keep.path) continue;
        await file.delete();
        bytes -= stats[file]!.size;
        count--;
      }
    } catch (_) {}
  }

  void close() {
    _closed = true;
    _client.close(force: true);
  }
}
