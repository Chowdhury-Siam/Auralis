import 'dart:typed_data';

List<int> number(int value, int count, {bool sync = false}) => [
  for (var i = count - 1; i >= 0; i--)
    (value >> (i * (sync ? 7 : 8))) & (sync ? 127 : 255),
];

Uint8List unsync(List<int> bytes) => Uint8List.fromList([
  for (final b in bytes) ...[b, if (b == 255) 0],
]);

Uint8List id3(
  Uint8List picture, {
  int version = 3,
  bool utf16 = false,
  bool synchronized = false,
  bool extended = false,
  int type = 3,
}) {
  final payload = [
    utf16 ? 1 : 0,
    if (version == 2) ...'PNG'.codeUnits else ...[...'image/png'.codeUnits, 0],
    type,
    if (utf16) ...[255, 254, 67, 0, 0, 0] else ...[67, 0],
    ...picture,
  ];
  final encoded = version == 4 && synchronized ? unsync(payload) : payload;
  final frame = [
    ...(version == 2 ? 'PIC' : 'APIC').codeUnits,
    ...number(encoded.length, version == 2 ? 3 : 4, sync: version == 4),
    if (version != 2) ...[0, version == 4 && synchronized ? 2 : 0],
    ...encoded,
  ];
  final header = extended
      ? (version == 3
            ? [...number(6, 4), ...List.filled(6, 0)]
            : [...number(6, 4, sync: true), 1, 0])
      : <int>[];
  final body = [...header, ...frame];
  final tag = version < 4 && synchronized ? unsync(body) : body;
  return Uint8List.fromList([
    ...'ID3'.codeUnits, version, 0,
    (version < 4 && synchronized ? 128 : 0) | (extended ? 64 : 0),
    ...number(tag.length, 4, sync: true), ...tag,
    // Independently generated silent MPEG frames, never a copyrighted track.
    for (var i = 0; i < 50; i++) ...[255, 251, 144, 0, ...List.filled(413, 0)],
  ]);
}

Uint8List flac(Uint8List picture) {
  final body = [
    ...number(3, 4),
    ...number(9, 4),
    ...'image/png'.codeUnits,
    ...number(0, 4),
    ...number(256, 4),
    ...number(256, 4),
    ...number(24, 4),
    ...number(0, 4),
    ...number(picture.length, 4),
    ...picture,
  ];
  return Uint8List.fromList([
    ...'fLaC'.codeUnits,
    128 | 6,
    ...number(body.length, 3),
    ...body,
  ]);
}

Uint8List atom(String type, List<int> payload, {bool extended = false}) =>
    Uint8List.fromList([
      ...number(extended ? 1 : payload.length + 8, 4),
      ...type.codeUnits,
      if (extended) ...number(payload.length + 16, 8),
      ...payload,
    ]);

Uint8List moov(Uint8List picture) => atom(
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
        atom('covr', atom('data', [0, 0, 0, 14, 0, 0, 0, 0, ...picture])),
      ),
    ]),
  ),
);
