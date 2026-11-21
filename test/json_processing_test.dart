import 'dart:convert';
import 'dart:typed_data';

import 'package:auralis/json_processing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [100, 256 * 1024, 1024 * 1024]) {
    test(
      'JSON decoding preserves Unicode, values and errors at $size bytes',
      () async {
        final original = {
          'text': '日本語' * (size ~/ 3),
          'values': [null, false, 123, 1.5],
        };
        final encoded = utf8.encode(jsonEncode(original));
        expect(await decodeJsonBytes(encoded), original);
        expect(
          await decodeJsonBytes(
            Uint8List.fromList([239, 187, 191, ...encoded]),
          ),
          original,
        );
        await expectLater(
          decodeJsonBytes(utf8.encode('${' ' * size}{bad')),
          throwsFormatException,
        );
        await expectLater(
          decodeJsonBytes(Uint8List.fromList([...List.filled(size, 32), 255])),
          throwsFormatException,
        );
      },
    );
  }
}
