import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'lyrics.dart';
import 'media_cache.dart';
import 'models.dart';

class TranslationFailure implements Exception {
  const TranslationFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Optional, on-demand Japanese-to-English lyrics. Never replaces source lyrics.
class LyricsTranslator {
  LyricsTranslator({HttpClient Function()? createClient, this.cache})
    : _createClient = createClient ?? HttpClient.new;
  final HttpClient Function() _createClient;
  final MediaCache Function()? cache;
  final _clients = <HttpClient>{};
  bool _closed = false;
  static final _japanese = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]');
  static bool supports(Lyrics lyrics) =>
      !lyrics.instrumental &&
      (_japanese.hasMatch(lyrics.plain) ||
          lyrics.lines.any((line) => _japanese.hasMatch(line.text)));

  Future<Lyrics> translate(
    Track track,
    Lyrics source, {
    required bool Function() active,
  }) async {
    final elapsed = Stopwatch()..start();
    final disk = cache?.call();
    final scope = disk?.directory?.path;
    void check() {
      if (_closed || !active() || cache?.call().directory?.path != scope) {
        throw const TranslationFailure('Translation cancelled.');
      }
      if (elapsed.elapsed > const Duration(seconds: 90)) {
        throw const TranslationFailure(
          'Translation took too long. Please try again later.',
        );
      }
    }

    check();
    final rows = source.lines.isEmpty
        ? source.plain.split('\n')
        : source.lines.map((line) => line.text).toList();
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'free-ja-en-v1',
              source.plain,
              for (final line in source.lines)
                [line.time.inMilliseconds, line.text],
            ]),
          ),
        )
        .toString();
    final kind = 'translation-en-$fingerprint';
    final bytes = await disk?.read(track, kind, 2 * 1024 * 1024);
    check();
    if (bytes != null) {
      try {
        final saved = jsonDecode(utf8.decode(bytes));
        if (saved is List &&
            saved.length == rows.length &&
            saved.every((v) => v is String && v.length <= 16000)) {
          return _bilingual(source, rows, saved.cast<String>());
        }
      } catch (_) {
        // A damaged cache is retried online without changing the original.
      }
    }
    final parts = rows
        .expand((row) => row.split('\n'))
        .toSet()
        .where((row) => _japanese.hasMatch(row))
        .toList();
    if (parts.isEmpty) {
      throw const TranslationFailure('No Japanese lyrics to translate.');
    }
    if (parts.length > 500 ||
        parts.fold<int>(0, (n, s) => n + s.length) > 20000 ||
        parts.any((s) => utf8.encode(s).length > 480)) {
      throw const TranslationFailure(
        'These lyrics are too long for the free translator.',
      );
    }
    final translated = <String, String>{};
    // Keep each request below MyMemory's documented 500-byte limit. Deduplicate
    // repeated choruses, and preserve alignment rather than guessing timestamps.
    final batches = <List<String>>[];
    var batch = <String>[];
    for (final part in parts) {
      if (utf8.encode([...batch, part].join('\n')).length > 480) {
        batches.add(batch);
        batch = [];
      }
      batch.add(part);
    }
    if (batch.isNotEmpty) batches.add(batch);
    var googleAvailable = true;
    for (final batch in batches) {
      check();
      final text = batch.join('\n');
      List<String>? output;
      if (googleAvailable) {
        try {
          final data = await _request(
            Uri.https('translate.googleapis.com', '/translate_a/single', {
              'client': 'gtx',
              'sl': 'ja',
              'tl': 'en',
              'dt': 't',
              'q': text,
            }),
          );
          if (data is List && data.isNotEmpty && data[0] is List) {
            final segments = data[0] as List;
            if (segments.every(
              (v) => v is List && v.isNotEmpty && v[0] is String,
            )) {
              output = _aligned(
                segments.map((v) => v[0] as String).join(),
                batch.length,
              );
            }
          }
        } catch (_) {
          check();
        }
        if (output == null) googleAvailable = false;
      }
      check();
      if (output == null) {
        final data = await _request(
          Uri.https('api.mymemory.translated.net', '/get', {
            'q': text,
            'langpair': 'ja|en',
            'mt': '1',
          }),
        );
        check();
        if (data is! Map ||
            data['quotaFinished'] == true ||
            '${data['responseStatus']}' != '200') {
          throw const TranslationFailure(
            'The free translator is unavailable or its daily limit was reached. Try again later.',
          );
        }
        final result = data['responseData'];
        if (result is Map && result['translatedText'] is String) {
          output = _aligned(
            _decodeEntities(result['translatedText'] as String),
            batch.length,
          );
        }
      }
      if (output == null) {
        throw const TranslationFailure(
          'The translator changed the lyric line breaks. Original lyrics were kept; please try again later.',
        );
      }
      for (var i = 0; i < batch.length; i++) {
        translated[batch[i]] = output[i];
      }
      if (batches.length > 1) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    check();
    final result = [
      for (final row in rows)
        row.split('\n').map((part) => translated[part] ?? '').join('\n').trim(),
    ];
    final encoded = utf8.encode(jsonEncode(result));
    if (encoded.length > 2 * 1024 * 1024) {
      throw const TranslationFailure('The translation is too large.');
    }
    await disk?.write(track, kind, encoded);
    check();
    return _bilingual(source, rows, result);
  }

  static List<String>? _aligned(String text, int count) {
    final lines = text.replaceAll('\r\n', '\n').trim().split('\n');
    if (lines.length != count ||
        lines.any((s) => s.trim().isEmpty || s.length > 16000)) {
      return null;
    }
    return lines.map((s) => s.trim()).toList();
  }

  static String _decodeEntities(String text) => text.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);'),
    (match) {
      final value = match[1]!;
      const named = {
        'amp': '&',
        'quot': '"',
        'apos': "'",
        'lt': '<',
        'gt': '>',
      };
      if (named.containsKey(value)) return named[value]!;
      final code = value.startsWith('#x')
          ? int.tryParse(value.substring(2), radix: 16)
          : int.tryParse(value.substring(1));
      return code != null &&
              code > 0 &&
              code <= 0x10ffff &&
              !(code >= 0xd800 && code <= 0xdfff)
          ? String.fromCharCode(code)
          : match[0]!;
    },
  );

  static Lyrics _bilingual(
    Lyrics source,
    List<String> rows,
    List<String> translated,
  ) {
    final combined = [
      for (var i = 0; i < rows.length; i++)
        translated[i].isEmpty || translated[i] == rows[i]
            ? rows[i]
            : '${rows[i]}\n${translated[i]}',
    ];
    return Lyrics(
      combined.join('\n'),
      [
        for (var i = 0; i < source.lines.length; i++)
          LyricLine(source.lines[i].time, combined[i]),
      ],
      online: source.online,
      embedded: source.embedded,
      imported: source.imported,
    );
  }

  Future<dynamic> _request(Uri uri) async {
    final client = _createClient();
    _clients.add(client);
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set('Accept', 'application/json');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const TranslationFailure(
            'The free translator is busy. Try again later.',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 256 * 1024) {
            throw const TranslationFailure(
              'The translation response is too large.',
            );
          }
          bytes.add(chunk);
        }
        return jsonDecode(utf8.decode(bytes.takeBytes()));
      })().timeout(const Duration(seconds: 15));
    } on TranslationFailure {
      rethrow;
    } catch (_) {
      throw const TranslationFailure(
        'Could not translate. Check your connection and try again.',
      );
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
