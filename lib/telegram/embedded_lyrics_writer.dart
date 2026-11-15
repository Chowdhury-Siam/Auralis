part of 'embedded_cover.dart';

/// Writes a separate audio file and copies encoded samples without transcoding.
Future<String> writeEmbeddedLyrics(
  File source,
  Directory destination,
  String lyrics, {
  required String name,
}) => Isolate.run(() async {
  final text = utf8.encode(lyrics);
  if (text.isEmpty || text.length > 256 * 1024) {
    throw const FormatException('Lyrics must fit in a 256 KiB audio tag.');
  }
  final input = await source.open();
  try {
    final size = await input.length();
    Future<Uint8List> read(int offset, int length) async {
      if (offset < 0 || length < 0 || offset + length > size) {
        throw const FormatException('Invalid audio metadata.');
      }
      await input.setPosition(offset);
      final bytes = await input.read(length);
      if (bytes.length != length) {
        throw const FormatException('Incomplete audio file.');
      }
      return bytes;
    }

    final header = await read(0, 12);
    final magic = _text(header, 0, 4);
    final extension = switch (magic) {
      'fLaC' => 'flac',
      _ when _text(header, 4, 4) == 'ftyp' => 'm4a',
      _
          when _text(header, 0, 3) == 'ID3' ||
              (header[0] == 0xff &&
                  header[1] & 0xe0 == 0xe0 &&
                  header[1] & 0x06 != 0) =>
        'mp3',
      _ => throw const FormatException(
        'Lyrics can be embedded in MP3, FLAC, and M4A songs.',
      ),
    };

    final output = File('${destination.path}/$name.$extension');
    final sink = output.openWrite();
    try {
      switch (extension) {
        case 'mp3':
          final (metadata, audioStart) = await _writeId3(
            read,
            header,
            lyrics,
            text,
          );
          sink.add(metadata);
          await sink.addStream(source.openRead(audioStart));
        case 'flac':
          await _writeFlac(read, source, sink, lyrics);
        case 'm4a':
          await _writeM4a(read, source, sink, text, size);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return output.path;
  } finally {
    await input.close();
  }
});

typedef _ReadAudio = Future<Uint8List> Function(int offset, int length);
const _maxTagBytes = 32 * 1024 * 1024;

List<int> _tagNumber(int value, int length, {bool sync = false}) {
  final bits = sync ? 7 : 8;
  return [
    for (var i = length - 1; i >= 0; i--)
      (value >> (i * bits)) & ((1 << bits) - 1),
  ];
}

bool _lyricId(String id) => const {
  'LYRICS',
  'USLT',
  'SYLT',
  'UNSYNCEDLYRICS',
  'SYNCEDLYRICS',
  'UNSYNCED LYRICS',
  'SYNCED LYRICS',
}.contains(id.toUpperCase());

bool _id3CustomLyric(Uint8List bytes) {
  if (bytes.isEmpty || bytes[0] > 3) return false;
  final step = bytes[0] == 1 || bytes[0] == 2 ? 2 : 1;
  for (var end = 1; end + step <= bytes.length; end += step) {
    if (bytes[end] != 0 || (step == 2 && bytes[end + 1] != 0)) continue;
    return _lyricId(
      _decodeText(Uint8List.sublistView(bytes, 1, end), bytes[0]),
    );
  }
  return false;
}

Future<(Uint8List, int)> _writeId3(
  _ReadAudio read,
  Uint8List header,
  String lyrics,
  List<int> utf8Lyrics,
) async {
  final tagged = _text(header, 0, 3) == 'ID3';
  final version = tagged ? header[3] : 4;
  final flags = tagged ? header[5] : 0;
  if (version < 2 || version > 4 || (version == 2 && flags & 64 != 0)) {
    throw const FormatException(
      'This ID3 tag version cannot be edited safely.',
    );
  }
  final tagLength = tagged ? _number(header, 6, 4, sync: true) : 0;
  if (tagLength > _maxTagBytes) {
    throw const FormatException('ID3 tag is too large.');
  }
  final unsynchronized = flags & 128 != 0;
  final raw = await read(10, tagLength);
  final body = version != 4 && unsynchronized ? _unsync(raw) : raw;
  var offset = version >= 3 && flags & 64 != 0
      ? _number(body, 0, 4, sync: version == 4) + (version == 3 ? 4 : 0)
      : 0;
  if (offset > body.length) throw const FormatException('Invalid ID3 tag.');
  final short = version == 2;
  final headerSize = short ? 6 : 10;
  final idLength = short ? 3 : 4;
  final frames = BytesBuilder(copy: false);
  while (offset + headerSize <= body.length && body[offset] != 0) {
    final id = _text(body, offset, idLength);
    final length = _number(
      body,
      offset + idLength,
      short ? 3 : 4,
      sync: version == 4,
    );
    final start = offset + headerSize, end = start + length;
    if (end > body.length) throw const FormatException('Invalid ID3 frame.');
    var discard = const {'USLT', 'ULT', 'SYLT', 'SLT'}.contains(id);
    if (id == 'TXXX' || id == 'TXX') {
      final format = short ? 0 : body[offset + 9];
      if (format & (version == 4 ? 12 : 192) == 0) {
        var data = Uint8List.sublistView(body, start, end);
        if (version == 4 && (unsynchronized || format & 2 != 0)) {
          data = _unsync(data);
        }
        final prefix =
            (format & (version == 4 ? 64 : 32) != 0 ? 1 : 0) +
            (version == 4 && format & 1 != 0 ? 4 : 0);
        if (prefix < data.length) {
          discard = _id3CustomLyric(Uint8List.sublistView(data, prefix));
        }
      }
    }
    if (!discard) frames.add(Uint8List.sublistView(body, offset, end));
    offset = end;
  }
  final payload = [
    version == 4 ? 3 : 1,
    ...ascii.encode('und'),
    if (version == 4) ...[
      0,
      ...utf8Lyrics,
    ] else ...[
      0xfe,
      0xff,
      0,
      0,
      0xfe,
      0xff,
      for (final unit in lyrics.codeUnits) ...[unit >> 8, unit & 0xff],
    ],
  ];
  frames.add(ascii.encode(short ? 'ULT' : 'USLT'));
  frames.add(_tagNumber(payload.length, short ? 3 : 4, sync: version == 4));
  if (!short) frames.add([0, 0]);
  frames.add(payload);
  var encoded = frames.takeBytes();
  if (version != 4 && unsynchronized) {
    final escaped = BytesBuilder();
    for (var i = 0; i < encoded.length; i++) {
      final byte = encoded[i];
      escaped.addByte(byte);
      if (byte == 255 &&
          (i + 1 == encoded.length ||
              encoded[i + 1] == 0 ||
              encoded[i + 1] >= 224)) {
        escaped.addByte(0);
      }
    }
    encoded = escaped.takeBytes();
  }
  return (
    Uint8List.fromList([
      73,
      68,
      51,
      version,
      0,
      unsynchronized ? 128 : 0,
      ..._tagNumber(encoded.length, 4, sync: true),
      ...encoded,
    ]),
    tagged ? 10 + tagLength + (version == 4 && flags & 16 != 0 ? 10 : 0) : 0,
  );
}

Uint8List _vorbisLyrics(Uint8List? previous, String? lyrics) {
  final vendor = BytesBuilder(copy: false);
  final comments = <Uint8List>[];
  if (previous == null) {
    vendor.add(utf8.encode('Auralis'));
  } else {
    final data = ByteData.sublistView(previous);
    var offset = 0;
    int number() {
      final value = data.getUint32(offset, Endian.little);
      offset += 4;
      return value;
    }

    Uint8List bytes() {
      final length = number();
      final value = Uint8List.sublistView(previous, offset, offset + length);
      offset += length;
      return value;
    }

    vendor.add(bytes());
    final count = number();
    if (count > (previous.length - offset) ~/ 4) {
      throw const FormatException('Invalid FLAC comments.');
    }
    for (var i = 0; i < count; i++) {
      final item = bytes();
      final equals = item.indexOf(61);
      if (equals < 0 || !_lyricId(_text(item, 0, equals))) comments.add(item);
    }
  }
  if (lyrics != null) {
    comments.add(Uint8List.fromList(utf8.encode('LYRICS=$lyrics')));
  }
  final result = BytesBuilder(copy: false);
  void number(int value) => result.add(_tagNumber(value, 4).reversed.toList());
  number(vendor.length);
  result.add(vendor.takeBytes());
  number(comments.length);
  for (final comment in comments) {
    number(comment.length);
    result.add(comment);
  }
  return result.takeBytes();
}

Future<void> _writeFlac(
  _ReadAudio read,
  File source,
  IOSink sink,
  String lyrics,
) async {
  sink.add(ascii.encode('fLaC'));
  var offset = 4;
  var added = false;
  void block(int type, Uint8List bytes, {required bool last}) {
    if (bytes.length > 0xffffff) {
      throw const FormatException('FLAC block is too large.');
    }
    sink.add([type | (last ? 128 : 0), ..._tagNumber(bytes.length, 3)]);
    sink.add(bytes);
  }

  for (var blocks = 0; blocks < 1024; blocks++) {
    final header = await read(offset, 4);
    final length = _number(header, 1, 3);
    final type = header[0] & 127, last = header[0] & 128 != 0;
    final bytes = await read(offset + 4, length);
    offset += 4 + length;
    if (type == 4) {
      block(4, _vorbisLyrics(bytes, added ? null : lyrics), last: last);
      added = true;
    } else {
      block(type, bytes, last: last && added);
    }
    await sink.flush();
    if (last) {
      if (!added) block(4, _vorbisLyrics(null, lyrics), last: true);
      await sink.addStream(source.openRead(offset));
      return;
    }
  }
  throw const FormatException('Invalid FLAC metadata.');
}

typedef _AudioBox = ({String type, int header, int start, int end});

_AudioBox _audioBox(Uint8List data, int offset, int limit) {
  var count = _number(data, offset, 4);
  final header = count == 1 ? 16 : 8;
  if (count == 1) count = _number(data, offset + 8, 8);
  if (count == 0) count = limit - offset;
  if (count < header || offset + count > limit) {
    throw const FormatException('Invalid M4A metadata.');
  }
  return (
    type: _text(data, offset + 4, 4),
    header: header,
    start: offset + header,
    end: offset + count,
  );
}

Uint8List _makeAudioBox(String type, List<int> body) => Uint8List.fromList([
  ..._tagNumber(body.length + 8, 4),
  ...latin1.encode(type),
  ...body,
]);

Uint8List _m4aLyrics(Uint8List movie, List<int> lyrics) {
  final lyric = _makeAudioBox(
    '©lyr',
    _makeAudioBox('data', [0, 0, 0, 1, 0, 0, 0, 0, ...lyrics]),
  );
  const iTunesHandler = [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    109,
    100,
    105,
    114,
    97,
    112,
    112,
    108,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ];
  var added = false;
  Uint8List update(String type, int start, int end) {
    final body = BytesBuilder(copy: false);
    if (type == 'meta') {
      if (start + 4 > end || _number(movie, start, 4) != 0) {
        return _makeAudioBox(type, Uint8List.sublistView(movie, start, end));
      }
      body.add([0, 0, 0, 0]);
      start += 4;
    }
    final next = switch (type) {
      'moov' => 'udta',
      'udta' => 'meta',
      'meta' => 'ilst',
      _ => '©lyr',
    };
    var childFound = false;
    for (var offset = start; offset < end;) {
      final child = _audioBox(movie, offset, end);
      if (child.type == next) {
        childFound = true;
        if (next != '©lyr') body.add(update(next, child.start, child.end));
      } else {
        body.add(Uint8List.sublistView(movie, offset, child.end));
      }
      offset = child.end;
    }
    if (!added && (!childFound || type == 'ilst')) {
      final items = _makeAudioBox('ilst', lyric);
      body.add(switch (type) {
        'ilst' => lyric,
        'meta' => items,
        'udta' => _makeAudioBox('meta', [
          0,
          0,
          0,
          0,
          ..._makeAudioBox('hdlr', iTunesHandler),
          ...items,
        ]),
        _ => _makeAudioBox(
          'udta',
          _makeAudioBox('meta', [
            0,
            0,
            0,
            0,
            ..._makeAudioBox('hdlr', iTunesHandler),
            ...items,
          ]),
        ),
      });
      added = true;
    }
    return _makeAudioBox(type, body.takeBytes());
  }

  final result = update('moov', 0, movie.length);
  if (!added) {
    throw const FormatException(
      'The M4A metadata layout cannot be edited safely.',
    );
  }
  return result;
}

Future<void> _writeM4a(
  _ReadAudio read,
  File source,
  IOSink sink,
  List<int> lyrics,
  int size,
) async {
  Uint8List? revised;
  var start = 0;
  for (var boxes = 0; start < size && boxes < 2048; boxes++) {
    final head = await read(start, size - start < 16 ? size - start : 16);
    final box = _audioBox(head, 0, size - start);
    final end = start + box.end;
    if (box.type == 'moov') {
      if (revised != null || box.end > _maxTagBytes) {
        throw const FormatException(
          'The M4A movie tag cannot be edited safely.',
        );
      }
      revised = _m4aLyrics(
        await read(start + box.header, box.end - box.header),
        lyrics,
      );
      // Keep all audio offsets and sample tables valid by padding the old slot.
      sink.add([..._tagNumber(box.end, 4), ...ascii.encode('free')]);
      var remaining = box.end - 8;
      final padding = Uint8List(64 * 1024);
      while (remaining > 0) {
        final count = remaining < padding.length ? remaining : padding.length;
        sink.add(Uint8List.sublistView(padding, 0, count));
        remaining -= count;
      }
    } else if (box.type == 'moof') {
      throw const FormatException(
        'Fragmented M4A audio cannot be edited safely.',
      );
    } else if (_number(head, 0, 4) == 0) {
      if (box.end > 0xffffffff) {
        throw const FormatException('The M4A file is too large to edit.');
      }
      sink.add(_tagNumber(box.end, 4));
      await sink.addStream(source.openRead(start + 4, end));
    } else {
      await sink.addStream(source.openRead(start, end));
    }
    start = end;
  }
  if (revised == null || start != size) {
    throw const FormatException('The M4A metadata is incomplete.');
  }
  sink.add(revised);
}
