import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'storage.dart';
import 'lyrics_translation.dart';
import 'media_cache.dart';

class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;
}

class Lyrics {
  const Lyrics(
    this.plain,
    this.lines, {
    this.instrumental = false,
    this.online = false,
    this.embedded = false,
    this.imported = false,
    this.provider,
  });
  final String plain;
  final String? provider;
  final List<LyricLine> lines;
  final bool instrumental, online, embedded, imported;

  String get timestampedText => lines.isEmpty
      ? plain
      : lines
            .expand((line) {
              final ms = line.time.inMilliseconds;
              final stamp =
                  '[${(ms ~/ 60000).toString().padLeft(2, '0')}:'
                  '${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.'
                  '${(ms % 1000).toString().padLeft(3, '0')}]';
              return line.text.split('\n').map((text) => '$stamp$text');
            })
            .join('\n');

  static const maxFileBytes = 256 * 1024;

  static Lyrics fromFileBytes(Uint8List bytes) {
    if (bytes.length > maxFileBytes) {
      throw const FormatException('LRC files must be 256 KiB or smaller.');
    }
    String text;
    if (bytes.length >= 2 &&
        (bytes[0] == 255 && bytes[1] == 254 ||
            bytes[0] == 254 && bytes[1] == 255)) {
      if (bytes.length.isOdd) {
        throw const FormatException('Invalid UTF-16 lyrics.');
      }
      final data = ByteData.sublistView(bytes);
      final endian = bytes[0] == 255 ? Endian.little : Endian.big;
      text = String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian),
      ]);
    } else {
      text = utf8.decode(bytes);
    }
    final lyrics = parse(
      text
          .replaceFirst('\uFEFF', '')
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n'),
      imported: true,
    );
    if (lyrics.plain.isEmpty && lyrics.lines.isEmpty) {
      throw const FormatException('The selected file has no lyrics.');
    }
    return lyrics;
  }

  static Lyrics parse(
    String text, {
    String? plain,
    bool online = false,
    bool embedded = false,
    bool imported = false,
    bool instrumental = false,
    String? provider,
  }) {
    if (text.length > 256 * 1024 || (plain?.length ?? 0) > 256 * 1024) {
      throw const FormatException('Lyrics are too long.');
    }
    final rows = text.split(RegExp(r'\r?\n'));
    if (rows.length > 2000) {
      throw const FormatException('Too many lyric lines.');
    }
    final offsetTag = RegExp(
      r'\[offset:([+-]?\d+)\]',
      caseSensitive: false,
    ).firstMatch(text);
    final offset = int.tryParse(offsetTag?[1] ?? '') ?? 0;
    final stamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final lines = <LyricLine>[];
    for (final row in rows) {
      final times = stamp.allMatches(row).toList();
      final words = row
          .replaceAll(stamp, '')
          .replaceAll(RegExp(r'<\d+:\d+(?:\.\d+)?>'), '')
          .trim();
      for (final time in times) {
        final seconds = int.parse(time[2]!);
        if (seconds >= 60) continue;
        final fraction = (time[3] ?? '').padRight(3, '0');
        final ms =
            int.parse(time[1]!) * 60000 +
            seconds * 1000 +
            int.parse(fraction) +
            offset;
        lines.add(
          LyricLine(
            Duration(milliseconds: ms.clamp(0, 24 * 60 * 60 * 1000)),
            words,
          ),
        );
        if (lines.length > 2000) {
          throw const FormatException('Too many lyric lines.');
        }
      }
    }
    // Stable ordering preserves simultaneous translation/original lines.
    final times = lines.map((line) => line.time).toSet().toList()..sort();
    final grouped = <LyricLine>[
      for (final time in times)
        LyricLine(
          time,
          lines
              .where((line) => line.time == time)
              .map((line) => line.text)
              .join('\n')
              .trim(),
        ),
    ];
    final fallback = grouped.isEmpty
        ? rows
              .where(
                (row) => !RegExp(
                  r'^\s*\[[a-z]+:.*\]\s*$',
                  caseSensitive: false,
                ).hasMatch(row),
              )
              .join('\n')
              .trim()
        : grouped.map((line) => line.text).join('\n');
    return Lyrics(
      (plain?.trim().isNotEmpty ?? false) ? plain!.trim() : fallback,
      grouped,
      provider: provider,
      online: online,
      embedded: embedded,
      imported: imported,
      instrumental: instrumental,
    );
  }

  int activeAt(Duration position) {
    var low = 0, high = lines.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].time <= position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }
}

/// Bounded memory and optional device cache, with sequential online fallbacks.
class LyricsRepository extends ChangeNotifier {
  LyricsRepository({
    HttpClient Function()? createClient,
    this.cache,
    this.preferences,
  }) : _createClient = createClient ?? HttpClient.new;
  final HttpClient Function() _createClient;
  final MediaCache Function()? cache;
  final AppSettings? preferences;
  final _translations = <Object, Lyrics>{};
  final _translationJobs = <Object, Future<Lyrics>>{};
  final _translationReaders = <Object, Set<bool Function()>>{};
  Object _translationKey(Track track, Lyrics source) => (
    _key(track),
    source,
    preferences?.translationFirst ?? TranslationSource.google,
    preferences == null
        ? TranslationSource.myMemory
        : preferences!.translationFallback,
    preferences?.translationDirection ?? TranslationDirection.japaneseEnglish,
  );
  Lyrics? translated(Track track, Lyrics source) =>
      _translations[_translationKey(track, source)];
  late final _translator = LyricsTranslator(
    createClient: _createClient,
    cache: cache,
  );
  Future<Lyrics> translateJapanese(
    Track track,
    Lyrics source, {
    required bool Function() active,
  }) {
    final key = _translationKey(track, source);
    if (_translations[key] case final saved?) return Future.value(saved);
    final readers = _translationReaders.putIfAbsent(key, () => {});
    readers.add(active);
    bool stillNeeded() =>
        !_closed &&
        readers.any((reader) => reader()) &&
        (cached(track) == null || identical(cached(track), source));
    if (_translationJobs[key] case final pending?) return pending;
    late final Future<Lyrics> job;
    job = _translator
        .translate(
          track,
          source,
          active: stillNeeded,
          first: preferences?.translationFirst ?? TranslationSource.google,
          fallback: preferences == null
              ? TranslationSource.myMemory
              : preferences!.translationFallback,
          direction:
              preferences?.translationDirection ??
              TranslationDirection.japaneseEnglish,
        )
        .then((result) {
          if (stillNeeded() && identical(cached(track), source)) {
            _translations[key] = result;
            if (_translations.length > 32) {
              _translations.remove(_translations.keys.first);
            }
            notifyListeners();
          }
          return result;
        })
        .whenComplete(() {
          if (identical(_translationJobs[key], job)) {
            _translationJobs.remove(key);
            _translationReaders.remove(key);
          }
        });
    return _translationJobs[key] = job;
  }

  Future<Lyrics?> prepare(
    Track track, {
    required bool Function() active,
    Future<Lyrics?> Function(Track)? loadEmbedded,
  }) async {
    Lyrics? result = await loadCached(track);
    if (!active() || _closed) return null;
    if (result == null && loadEmbedded != null) {
      try {
        result = await loadEmbedded(track);
      } catch (_) {
        /* Continue online. */
      }
      if (!active() || _closed) return null;
      result = cached(track) ?? result;
      if (result != null &&
          !result.instrumental &&
          result.plain.trim().isEmpty &&
          !result.lines.any((line) => line.text.trim().isNotEmpty)) {
        result = null;
      }
      if (result != null) save(track, result);
    }
    result ??= await find(track);
    if (!active() || _closed || result == null) return null;
    if (preferences?.automaticTranslation != false &&
        LyricsTranslator.supports(
          result,
          direction:
              preferences?.translationDirection ??
              TranslationDirection.japaneseEnglish,
        )) {
      try {
        await translateJapanese(track, result, active: active);
      } catch (_) {
        /* Originals remain available. */
      }
    }
    return result;
  }

  Future<Lyrics?> loadCached(Track track) async {
    if (contains(track)) return cached(track);
    final disk = cache?.call();
    final bytes = await disk?.read(track, 'lyrics', 2 * 1024 * 1024);
    if (bytes == null ||
        _closed ||
        cache?.call().directory?.path != disk?.directory?.path) {
      return null;
    }
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final lines = (data['lines'] as List)
          .map(
            (v) =>
                LyricLine(Duration(milliseconds: v[0] as int), v[1] as String),
          )
          .toList();
      if (lines.length > 2000) return null;
      final result = Lyrics(
        data['plain'] as String,
        lines,
        provider: data['provider'] is String
            ? data['provider'] as String
            : null,
        instrumental: data['instrumental'] == true,
        online: data['online'] == true,
        embedded: data['embedded'] == true,
        imported: data['imported'] == true,
      );
      if (!contains(track)) {
        _cache[_key(track)] = result;
        if (_cache.length > 32) _cache.remove(_cache.keys.first);
      }
      return cached(track);
    } catch (_) {
      return null;
    }
  }

  Future<void> persist(Track track, Lyrics value) async {
    await cache?.call().write(
      track,
      'lyrics',
      utf8.encode(
        jsonEncode({
          'plain': value.plain,
          'provider': value.provider,
          'lines': [
            for (final line in value.lines)
              [line.time.inMilliseconds, line.text],
          ],
          'instrumental': value.instrumental,
          'online': value.online,
          'embedded': value.embedded,
          'imported': value.imported,
        }),
      ),
    );
  }

  final _cache = <String, Lyrics?>{};
  final _pending = <String, Object>{};
  final _lookups = <Object, Future<Lyrics?>>{};
  final _clients = <HttpClient>{};
  bool _closed = false;
  String _key(Track track) => jsonEncode([
    cache?.call().directory?.path,
    track.id,
    track.title,
    track.artist,
    track.duration.inSeconds,
  ]);
  bool contains(Track track) => _cache.containsKey(_key(track));
  Lyrics? cached(Track track) => _cache[_key(track)];
  void save(Track track, Lyrics? lyrics) {
    if (_closed) return;
    _pending.remove(_key(track));
    _cache.remove(_key(track));
    _cache[_key(track)] = lyrics;
    if (_cache.length > 32) _cache.remove(_cache.keys.first);
    if (lyrics != null) unawaited(persist(track, lyrics));
    notifyListeners();
  }

  Future<Lyrics?> find(Track track, {bool refresh = false}) {
    final key = (
      _key(track),
      preferences?.lyricsFirst,
      preferences?.lyricsFallback,
    );
    if (!refresh && _lookups[key] != null) return _lookups[key]!;
    late final Future<Lyrics?> job;
    job = _find(track, refresh: refresh).whenComplete(() {
      if (identical(_lookups[key], job)) _lookups.remove(key);
    });
    return _lookups[key] = job;
  }

  Future<Lyrics?> _find(Track track, {bool refresh = false}) async {
    if (_closed) throw StateError('Lyrics lookup is closed.');
    final saved = refresh || cache == null ? null : await loadCached(track);
    if (saved != null) return saved;
    final title = track.title.trim(), artist = track.artist.trim();
    if (title.isEmpty ||
        artist.isEmpty ||
        title.length > 1000 ||
        artist.length > 1000) {
      throw const FormatException(
        'A song title and artist are needed for lookup.',
      );
    }
    final scope = cache?.call().directory?.path;
    final key = _key(track), requestId = Object();
    _pending[key] = requestId;
    bool current() =>
        !_closed &&
        identical(_pending[key], requestId) &&
        cache?.call().directory?.path == scope;
    Lyrics? superseded() => !_closed && cache?.call().directory?.path == scope
        ? cached(track)
        : null;
    final signature = {'track_name': title, 'artist_name': artist};
    final providers = <Future<Lyrics?> Function()>[
      () async => _lrclib(
        await _fetch(
          Uri.https('lrclib.net', '/api/get', {
            ...signature,
            if (track.duration.inSeconds >= 1 &&
                track.duration.inSeconds <= 3600)
              'duration': '${track.duration.inSeconds}',
          }),
        ),
      ),
      () async => _search(
        await _fetch(Uri.https('lrclib.net', '/api/search', signature)),
        track,
      ),
      () async {
        final data = await _fetch(
          Uri(
            scheme: 'https',
            host: 'api.lyrics.ovh',
            pathSegments: ['v1', artist, title],
          ),
        );
        if (data == null) return null;
        if (data is! Map || data['lyrics'] is! String) {
          throw const FormatException('Invalid lyrics.ovh response.');
        }
        // This provider supplies plain text, so do not manufacture sync timings.
        final text = (data['lyrics'] as String).trim();
        if (text.isEmpty) return null;
        final parsed = Lyrics.parse(text, online: true, provider: 'lyrics.ovh');
        return Lyrics(
          parsed.plain,
          const [],
          online: true,
          provider: 'lyrics.ovh',
        );
      },
    ];
    var failed = false;
    try {
      final order = preferences == null
          ? [LyricsSource.lrclib, LyricsSource.lyricsOvh]
          : [
              preferences!.lyricsFirst,
              if (preferences!.lyricsFallback != null)
                preferences!.lyricsFallback!,
            ];
      for (final lookup in [
        for (final source in order)
          if (source == LyricsSource.lrclib)
            ...providers.take(2)
          else
            providers[2],
      ]) {
        if (!current()) return superseded();
        Lyrics? result;
        try {
          result = await lookup();
        } catch (_) {
          failed = true;
        }
        if (!current()) return superseded();
        if (result != null) {
          save(track, result);
          return result;
        }
      }
      // Unavailability is retryable and must never become a cached "not found".
      if (failed) {
        throw const HttpException(
          'Lyrics sources are unavailable. Try again later.',
        );
      }
      if (cached(track) == null) save(track, null);
      return null;
    } finally {
      if (identical(_pending[key], requestId)) _pending.remove(key);
    }
  }

  Future<dynamic> _fetch(Uri uri) async {
    final client = _createClient();
    _clients.add(client);
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set('Accept', 'application/json');
        request.headers.set(
          'User-Agent',
          'Auralis (https://github.com/Chowdhury-Siam/Auralis)',
        );
        final response = await request.close();
        if (response.statusCode == 404) return null;
        if (response.statusCode != 200) {
          throw const HttpException('Lyrics source unavailable.');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 512 * 1024) {
            throw const FormatException('Lyrics response is too large.');
          }
          bytes.add(chunk);
        }
        return jsonDecode(utf8.decode(bytes.takeBytes()));
      })().timeout(const Duration(seconds: 7));
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  static Lyrics? _lrclib(dynamic data) {
    if (data == null) return null;
    if (data is! Map ||
        (data['plainLyrics'] != null && data['plainLyrics'] is! String) ||
        (data['syncedLyrics'] != null && data['syncedLyrics'] is! String)) {
      throw const FormatException('Invalid LRCLIB response.');
    }
    final result = Lyrics.parse(
      data['syncedLyrics'] as String? ?? '',
      plain: data['plainLyrics'] as String?,
      online: true,
      instrumental: data['instrumental'] == true,
      provider: 'LRCLIB',
    );
    return result.instrumental ||
            result.plain.trim().isNotEmpty ||
            result.lines.any((line) => line.text.trim().isNotEmpty)
        ? result
        : null;
  }

  static String _matchText(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s\-_.:,!?/()（）「」・]+'), '');

  static Lyrics? _search(dynamic data, Track track) {
    if (data == null) return null;
    if (data is! List) {
      throw const FormatException('Invalid LRCLIB search response.');
    }
    final title = _matchText(track.title), artist = _matchText(track.artist);
    if (title.isEmpty || artist.isEmpty) return null;
    Lyrics? best;
    var bestScore = double.infinity;
    for (final row in data.take(100)) {
      if (row is! Map ||
          row['trackName'] is! String ||
          row['artistName'] is! String ||
          _matchText(row['trackName'] as String) != title ||
          _matchText(row['artistName'] as String) != artist) {
        continue;
      }
      final duration = row['duration'];
      final known = duration is num && duration.isFinite && duration > 0;
      final difference = track.duration > Duration.zero && known
          ? (duration - track.duration.inMilliseconds / 1000).abs().toDouble()
          : 0.0;
      if (difference > 5) continue;
      Lyrics? result;
      try {
        result = _lrclib(row);
      } catch (_) {
        continue;
      }
      if (result == null) continue;
      final score =
          difference * 10 +
          (track.duration > Duration.zero && !known ? 1000 : 0) +
          (result.lines.isEmpty ? 1 : 0);
      if (score < bestScore) {
        best = result;
        bestScore = score;
      }
    }
    return best;
  }

  void close() {
    if (_closed) return;
    _translations.clear();
    _translationJobs.clear();
    _translationReaders.clear();
    _translator.close();
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
    _pending.clear();
    _lookups.clear();
    _cache.clear();
    dispose();
  }
}
