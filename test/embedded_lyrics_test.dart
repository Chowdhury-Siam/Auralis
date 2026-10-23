import 'dart:convert';
import 'dart:typed_data';

import 'package:auralis/lyrics.dart';
import 'package:auralis/telegram/embedded_cover.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/cover_data.dart';

Uint8List tag(String id, List<int> payload, {int version = 3}) {
  final frame = [
    ...id.codeUnits,
    ...number(payload.length, version == 2 ? 3 : 4, sync: version == 4),
    if (version != 2) 0,
    if (version != 2) 0,
    ...payload,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    version,
    0,
    0,
    ...number(frame.length, 4, sync: true),
    ...frame,
    ...List.filled(1024, 0),
  ]);
}

Future<String?> extract(Uint8List data) => readEmbeddedLyrics(
  (offset, count) async => Uint8List.sublistView(data, offset, offset + count),
  data.length,
);

void main() {
  for (final version in [2, 3, 4]) {
    test(
      'ID3v2.$version reads embedded plain and LRC Unicode lyrics without audio',
      () async {
        const text = '[00:01.250]Original lyric 日本語\n[00:03]Another line';
        final data = tag(version == 2 ? 'ULT' : 'USLT', [
          3,
          ...'eng'.codeUnits,
          0,
          ...utf8.encode(text),
        ], version: version);
        var total = 0;
        final actual = await readEmbeddedLyrics((offset, count) async {
          total += count;
          return Uint8List.sublistView(data, offset, offset + count);
        }, data.length);
        expect(actual, text);
        expect(total, data.length - 1024);
        expect(
          Lyrics.parse(actual!).lines.first.time,
          const Duration(milliseconds: 1250),
        );
      },
    );
  }
  test(
    'ID3 Latin1, both UTF16 byte orders, descriptions and custom LYRICS',
    () async {
      expect(
        await extract(
          tag('USLT', [
            0,
            ...'eng'.codeUnits,
            ...'description'.codeUnits,
            0,
            ...latin1.encode('Original café'),
          ]),
        ),
        'Original café',
      );
      for (final little in [true, false]) {
        List<int> encoded(String text) => [
          for (final c in text.codeUnits)
            ...little ? [c & 255, c >> 8] : [c >> 8, c & 255],
        ];
        expect(
          await extract(
            tag('USLT', [
              1,
              ...'jpn'.codeUnits,
              ...little ? [255, 254] : [254, 255],
              ...encoded('description'),
              0,
              0,
              ...encoded('Original 日本語'),
            ]),
          ),
          'Original 日本語',
        );
      }
      expect(
        await extract(
          tag('TXXX', [
            3,
            ...utf8.encode('LYRICS'),
            0,
            ...utf8.encode('Original custom words'),
          ]),
        ),
        'Original custom words',
      );
      expect(
        await extract(
          tag('TXXX', [
            3,
            ...utf8.encode('OTHER'),
            0,
            ...utf8.encode('Not lyrics'),
          ]),
        ),
        isNull,
      );
    },
  );
  test(
    'SYLT uses millisecond timings and rejects MPEG frame timings',
    () async {
      final entries = [
        for (final ms in [1000, 2500]) ...[
          ...utf8.encode('Original at $ms'),
          0,
          ...number(ms, 4),
        ],
      ];
      final result = await extract(
        tag('SYLT', [3, ...'eng'.codeUnits, 2, 1, 0, ...entries]),
      );
      expect(
        Lyrics.parse(result!).lines[1].time,
        const Duration(milliseconds: 2500),
      );
      expect(
        await extract(
          tag('SYLT', [3, ...'eng'.codeUnits, 1, 1, 0, ...entries]),
        ),
        isNull,
      );
    },
  );
  test(
    'FLAC comment lyrics and M4A lyric atom retain Unicode and timestamps',
    () async {
      const text = '[00:04]Original 日本語';
      final comment = utf8.encode('LYRICS=$text');
      List<int> le(int n) => number(n, 4).reversed.toList();
      final body = [...le(0), ...le(1), ...le(comment.length), ...comment];
      expect(
        await extract(
          Uint8List.fromList([
            ...'fLaC'.codeUnits,
            132,
            ...number(body.length, 3),
            ...body,
          ]),
        ),
        text,
      );
      final mp4 = Uint8List.fromList([
        ...atom('ftyp', 'M4A 0000'.codeUnits),
        ...atom('mdat', List.filled(1000, 0)),
        ...atom(
          'moov',
          atom(
            'udta',
            atom('meta', [
              0,
              0,
              0,
              0,
              ...atom(
                'ilst',
                atom(
                  '\xA9lyr',
                  atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(text)]),
                ),
              ),
            ]),
          ),
        ),
      ]);
      expect(await extract(mp4), text);
    },
  );
  test(
    'absent, oversized, truncated and malformed tags fall back safely',
    () async {
      for (final data in [
        Uint8List(32),
        tag('USLT', [1, ...'eng'.codeUnits, 0]),
        tag('USLT', [
          3,
          ...'eng'.codeUnits,
          0,
          ...List.filled(256 * 1024 + 1, 65),
        ]),
        Uint8List.fromList([...'ID3'.codeUnits, 4, 0, 0, 127, 127, 127, 127]),
      ]) {
        expect(await extract(data), isNull);
      }
    },
  );
}
