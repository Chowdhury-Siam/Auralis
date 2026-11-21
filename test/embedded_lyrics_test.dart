import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_added_translation.dart';
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
  for (final extension in ['mp3', 'flac', 'm4a']) {
    test(
      'bilingual $extension metadata round-trip preserves original audio and source file',
      () async {
        final dir = await Directory.systemTemp.createTemp('auralis-bilingual-');
        addTearDown(() => dir.delete(recursive: true));
        final source = File('${dir.path}/source.$extension');
        final audio = List<int>.generate(1024, (index) => index % 251);
        final ftyp = atom('ftyp', 'M4A 0000'.codeUnits);
        final mp3Tag = tag('TIT2', [3, ...utf8.encode('Title')]);
        final original = switch (extension) {
          'mp3' => Uint8List.fromList([
            ...mp3Tag.take(mp3Tag.length - 1024),
            ...audio,
          ]),
          'flac' => Uint8List.fromList([
            ...'fLaC'.codeUnits,
            128,
            0,
            0,
            34,
            ...List.filled(34, 0),
            ...audio,
          ]),
          _ => Uint8List.fromList([
            ...ftyp,
            ...atom('mdat', audio),
            ...atom(
              'moov',
              atom('udta', atom('meta', [0, 0, 0, 0, ...atom('ilst', [])])),
            ),
          ]),
        };
        await source.writeAsBytes(original);
        final bilingual = addLyricsTranslation(
          Lyrics.parse('[00:01.123]日本語\n[00:03.456]次の行'),
          'English\nNext line',
        );
        final output = File(
          await writeEmbeddedLyrics(
            source,
            dir,
            bilingual.timestampedText,
            name: 'bilingual',
          ),
        );
        final bytes = await output.readAsBytes();
        final parsed = Lyrics.parse((await extract(bytes))!);
        expect(parsed.timestampedText, bilingual.timestampedText);
        expect(await source.readAsBytes(), original);
        final start = extension == 'm4a'
            ? ftyp.length + 8
            : bytes.length - audio.length;
        expect(bytes.sublist(start, start + audio.length), audio);
      },
    );
  }
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
    'MP3 export adds or replaces Unicode timed lyrics and copies audio',
    () async {
      final temp = await Directory.systemTemp.createTemp('auralis-embedded-');
      addTearDown(() => temp.delete(recursive: true));
      const replacement = '[00:00.320]新しい歌詞\n[00:01.125]次の行';
      final audio = [0xff, 0xfb, ...List.filled(1022, 42)];
      for (final version in [0, 2, 3, 4]) {
        final source = File('${temp.path}/input-$version.mp3');
        final metadata = version == 0
            ? const <int>[]
            : tag(version == 2 ? 'TXX' : 'TXXX', [
                0,
                ...ascii.encode('USLT'),
                0,
                ...ascii.encode('old lyric'),
              ], version: version);
        await source.writeAsBytes([
          if (version != 0) ...metadata.take(metadata.length - 1024),
          ...audio,
        ]);
        final exported = File(
          await writeEmbeddedLyrics(
            source,
            temp,
            replacement,
            name: 'exported-$version',
          ),
        );
        final bytes = await exported.readAsBytes();
        expect(await extract(bytes), replacement);
        expect(bytes.sublist(bytes.length - audio.length), audio);
        expect(latin1.decode(bytes), isNot(contains('old lyric')));
      }
    },
  );

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
