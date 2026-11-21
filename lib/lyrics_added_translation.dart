import 'dart:convert';

import 'lyrics.dart';

/// Pair a user-supplied translation with the original, never replace it or guess
/// timestamps for a different number of lines. Used by display and audio tags.
Lyrics addLyricsTranslation(Lyrics source, String text) {
  if (source.instrumental || source.plain.trim().isEmpty) {
    throw const FormatException('Load the original lyrics first.');
  }
  final input = Lyrics.parse(
    text
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n'),
    imported: true,
  );
  if (input.plain.trim().isEmpty) {
    throw const FormatException('Paste the translated lyrics first.');
  }
  final rows = source.lines.isEmpty
      ? source.plain.split('\n')
      : source.lines.map((line) => line.text).toList();
  final translated = List.filled(rows.length, '');
  if (input.lines.isNotEmpty) {
    if (source.lines.isEmpty) {
      throw const FormatException(
        'The original lyrics have no timestamps. Paste a plain translation with matching lines.',
      );
    }
    final byTime = {for (final line in input.lines) line.time: line.text};
    final sourceTimes = {for (final line in source.lines) line.time};
    final requiredTimes = {
      for (final line in source.lines)
        if (line.text.trim().isNotEmpty) line.time,
    };
    if (byTime.keys.any((time) => !sourceTimes.contains(time)) ||
        requiredTimes.any((time) => byTime[time]?.trim().isNotEmpty != true)) {
      throw const FormatException(
        'Keep the original timestamps for every translated lyric line.',
      );
    }
    for (var i = 0; i < source.lines.length; i++) {
      // Empty timed instrumental gaps remain empty.
      if (rows[i].trim().isNotEmpty) {
        translated[i] = byTime[source.lines[i].time] ?? '';
      }
    }
  } else {
    final lines = input.plain
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final indexes = [
      for (var i = 0; i < rows.length; i++)
        if (rows[i].trim().isNotEmpty) i,
    ];
    if (lines.length != indexes.length) {
      throw const FormatException(
        'Use one translated line per original lyric line, or paste LRC with the original timestamps.',
      );
    }
    for (var i = 0; i < indexes.length; i++) {
      translated[indexes[i]] = lines[i].trim();
    }
  }
  final combined = [
    for (var i = 0; i < rows.length; i++)
      translated[i].isEmpty || translated[i] == rows[i]
          ? rows[i]
          : '${rows[i]}\n${translated[i]}',
  ];
  final result = Lyrics(
    combined.join('\n'),
    [
      for (var i = 0; i < source.lines.length; i++)
        LyricLine(source.lines[i].time, combined[i]),
    ],
    imported: true,
    provider: 'Added translation',
  );
  if (utf8.encode(result.timestampedText).length > Lyrics.maxFileBytes) {
    throw const FormatException(
      'Original and translation must fit in a 256 KiB lyrics tag.',
    );
  }
  return result;
}
