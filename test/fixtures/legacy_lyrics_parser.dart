// Pre-0.1.228 algorithm retained ONLY as a differential benchmark oracle.
// Keep production changes in lib/lyrics.dart, not in this test fixture.
import 'package:auralis/lyrics.dart';

Lyrics legacyParse(String text) {
  if (text.length > 256 * 1024) {
    throw const FormatException('Lyrics are too long.');
  }
  final rows = text.split(RegExp(r'\r?\n'));
  if (rows.length > 2000) throw const FormatException('Too many lyric lines.');
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
  return Lyrics(fallback, grouped);
}
