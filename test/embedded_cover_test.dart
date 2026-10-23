import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/telegram/embedded_cover.dart';

import 'fixtures/cover_data.dart';

void main() {
  final png = File('test/fixtures/cover.png').readAsBytesSync();
  Future<Uint8List?> extract(Uint8List file) => readEmbeddedCover(
    (offset, count) async =>
        Uint8List.sublistView(file, offset, offset + count),
    file.length,
  );

  for (final version in [2, 3, 4]) {
    test(
      'ID3v2.$version extracts exact picture bytes without reading MPEG frames',
      () async {
        final data = id3(png, version: version);
        var total = 0;
        final actual = await readEmbeddedCover((offset, count) async {
          total += count;
          return Uint8List.sublistView(data, offset, offset + count);
        }, data.length);
        expect(actual, png);
        expect(total, lessThan(png.length + 100));
      },
    );
  }
  for (final version in [3, 4]) {
    test(
      'ID3v2.$version handles UTF-16 description, extended header and unsynchronisation',
      () async {
        final bytes = Uint8List.fromList([...png, 255, 224, 255, 0]);
        expect(
          await extract(
            id3(
              bytes,
              version: version,
              utf16: true,
              extended: true,
              synchronized: true,
            ),
          ),
          bytes,
        );
      },
    );
  }
  test(
    'FLAC extracts PICTURE blocks',
    () async => expect(await extract(flac(png)), png),
  );
  test('M4A skips a large audio mdat to read the tail cover atom', () async {
    final first = atom('ftyp', 'M4A \x00\x00\x00\x00'.codeUnits);
    final tail = moov(png);
    const audioSize = 100 * 1024 * 1024;
    final mdat = Uint8List.fromList([
      ...number(audioSize, 4),
      ...'mdat'.codeUnits,
    ]);
    var total = 0;
    final tailStart = first.length + audioSize;
    final actual = await readEmbeddedCover((offset, count) async {
      total += count;
      if (offset < first.length) {
        return Uint8List.sublistView(first, offset, offset + count);
      }
      if (offset == first.length && count == 8) return mdat;
      if (offset >= tailStart) {
        return Uint8List.sublistView(
          tail,
          offset - tailStart,
          offset - tailStart + count,
        );
      }
      fail('Artwork tried to read audio payload');
    }, tailStart + tail.length);
    expect(actual, png);
    expect(total, lessThan(png.length + 200));
  });
  test('extended MP4 atom sizes are supported', () async {
    final file = Uint8List.fromList([
      ...atom('ftyp', 'M4A 0000'.codeUnits),
      ...atom('moov', moov(png).sublist(8), extended: true),
    ]);
    expect(await extract(file), png);
  });
  test(
    'an unsendable TDLib-like source context is never captured by the worker',
    () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final data = id3(png);
      expect(
        await readEmbeddedCover((offset, count) async {
          port.sendPort.send('source callback');
          return Uint8List.sublistView(data, offset, offset + count);
        }, data.length),
        png,
      );
    },
  );
  test(
    'oversized tags, malformed sizes, truncation and absent art return null',
    () async {
      final huge = Uint8List.fromList([
        ...'ID3'.codeUnits,
        3,
        0,
        0,
        127,
        127,
        127,
        127,
      ]);
      var reads = 0;
      expect(
        await readEmbeddedCover((offset, count) async {
          reads++;
          return huge;
        }, 300000000),
        isNull,
      );
      expect(reads, 1);
      for (final file in [
        Uint8List(10),
        id3(png).sublist(0, 20),
        Uint8List.fromList([
          ...atom('ftyp', [0, 0]),
          ...number(2, 4),
          ...'moov'.codeUnits,
        ]),
        Uint8List.fromList([...'fLaC'.codeUnits, 134, 255, 255, 255, 0, 0]),
      ]) {
        expect(await extract(file), isNull);
      }
      final random = Random(12);
      for (var i = 0; i < 300; i++) {
        expect(
          await extract(
            Uint8List.fromList(List.generate(50, (_) => random.nextInt(256))),
          ),
          isNull,
        );
      }
    },
  );
}
