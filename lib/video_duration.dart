import 'dart:math' as math;
import 'dart:typed_data';

typedef VideoMetadataRange = Future<Uint8List?> Function(int offset, int count);

/// Reads container headers with bounded range requests, including a tail moov
/// box. A file without usable duration metadata can be measured during playback.
Future<Duration?> readVideoDuration(VideoMetadataRange source, int size) async {
  try {
    return await _Reader(source, size).duration();
  } on FormatException {
    return null;
  }
}

class _Reader {
  _Reader(this.source, this.size);
  final VideoMetadataRange source;
  final int size;
  int _budget = 128 * 1024;
  int _windowStart = 0;
  Uint8List _window = Uint8List(0);

  Future<ByteData> _read(int offset, int count) async {
    if (offset < 0 || count <= 0 || offset + count > size) {
      throw const FormatException('Invalid video header range');
    }
    if (offset < _windowStart ||
        offset + count > _windowStart + _window.length) {
      final length = math.min(size - offset, math.max(count, 4096));
      if (length > _budget) {
        throw const FormatException('Video header is too large');
      }
      _budget -= length;
      final bytes = await source(offset, length);
      if (bytes == null || bytes.length != length) {
        throw const FormatException('Video header unavailable');
      }
      _window = bytes;
      _windowStart = offset;
    }
    final start = offset - _windowStart;
    return ByteData.sublistView(_window, start, start + count);
  }

  Duration? _microseconds(double value) =>
      value.isFinite &&
          value >= 1 &&
          value <= const Duration(days: 365).inMicroseconds
      ? Duration(microseconds: value.round())
      : null;

  Future<Duration?> duration() async {
    if (size < 12) return null;
    final head = await _read(0, 12);
    if (head.getUint32(0) == 0x1a45dfa3) return _matroska();
    if (head.getUint32(0) == 0x52494646 && head.getUint32(8) == 0x41564920) {
      return _avi();
    }
    return switch (head.getUint32(4)) {
      0x66747970 ||
      0x6d6f6f76 ||
      0x6d646174 ||
      0x66726565 ||
      0x77696465 => _mp4(),
      _ => null,
    };
  }

  Future<(int id, int start, int end)> _element(int offset, int limit) async {
    int width(int first, int max) {
      for (var width = 1; width <= max; width++) {
        if (first & (0x80 >> (width - 1)) != 0) return width;
      }
      throw const FormatException('Invalid EBML integer');
    }

    final bytes = await _read(offset, math.min(12, limit - offset));
    final idSize = width(bytes.getUint8(0), 4);
    if (idSize >= bytes.lengthInBytes) {
      throw const FormatException('Truncated EBML ID');
    }
    final lengthSize = width(bytes.getUint8(idSize), 8);
    final headerSize = idSize + lengthSize;
    if (headerSize > bytes.lengthInBytes) {
      throw const FormatException('Truncated EBML element');
    }
    var id = 0;
    for (var i = 0; i < idSize; i++) {
      id = (id << 8) | bytes.getUint8(i);
    }
    var length = bytes.getUint8(idSize) & (0xff >> lengthSize);
    for (var i = idSize + 1; i < headerSize; i++) {
      length = (length << 8) | bytes.getUint8(i);
    }
    final start = offset + headerSize;
    final unknown = length == (1 << (7 * lengthSize)) - 1;
    final end = unknown && id == 0x18538067 ? limit : start + length;
    if (unknown && id != 0x18538067 || end > limit) {
      throw const FormatException('Invalid EBML element length');
    }
    return (id, start, end);
  }

  Future<Duration?> _matroska() async {
    final (_, _, headerEnd) = await _element(0, size);
    var offset = headerEnd;
    var limit = size;
    for (var i = 0; i < 64 && offset < limit; i++) {
      final (id, start, end) = await _element(offset, limit);
      if (id == 0x18538067) {
        limit = end;
        offset = start;
      } else if (id == 0x1549a966) {
        return _matroskaInfo(start, end);
      } else {
        offset = end;
      }
    }
    return null;
  }

  Future<Duration?> _matroskaInfo(int offset, int end) async {
    var scale = 1000000;
    double? ticks;
    for (var i = 0; i < 128 && offset < end; i++) {
      final (id, start, next) = await _element(offset, end);
      final length = next - start;
      if (id == 0x2ad7b1 && length > 0 && length <= 8) {
        final bytes = await _read(start, length);
        scale = 0;
        for (var byte = 0; byte < length; byte++) {
          scale = (scale << 8) | bytes.getUint8(byte);
        }
      } else if (id == 0x4489 && (length == 4 || length == 8)) {
        final bytes = await _read(start, length);
        ticks = length == 4 ? bytes.getFloat32(0) : bytes.getFloat64(0);
      }
      offset = next;
    }
    return ticks == null || ticks <= 0 || scale <= 0
        ? null
        : _microseconds(ticks * scale / 1000);
  }

  Future<Duration?> _mp4() async {
    var offset = 0;
    var limit = size;
    var inMovie = false;
    for (var i = 0; i < 128 && offset + 8 <= limit; i++) {
      final bytes = await _read(offset, 8);
      final type = bytes.getUint32(4);
      var length = bytes.getUint32(0), header = 8;
      if (length == 1) {
        if (offset + 16 > limit) return null;
        length = (await _read(offset + 8, 8)).getUint64(0);
        header = 16;
      } else if (length == 0) {
        length = limit - offset;
      }
      if (length < header || length > limit - offset) return null;
      if (!inMovie && type == 0x6d6f6f76) {
        inMovie = true;
        limit = offset + length;
        offset += header;
        continue;
      }
      if (inMovie && type == 0x6d766864 && length >= header + 20) {
        final data = await _read(
          offset + header,
          math.min(32, length - header),
        );
        final version = data.getUint8(0);
        final (timescale, ticks) = switch (version) {
          0 => (data.getUint32(12), data.getUint32(16)),
          1 when data.lengthInBytes >= 32 => (
            data.getUint32(20),
            data.getUint64(24),
          ),
          _ => (0, 0),
        };
        return timescale == 0 ||
                ticks <= 0 ||
                version == 0 && ticks == 0xffffffff
            ? null
            : _microseconds(ticks * 1000000.0 / timescale);
      }
      offset += length;
    }
    return null;
  }

  Future<Duration?> _avi() async {
    var offset = 12;
    var limit = size;
    var inHeader = false;
    for (var i = 0; i < 64 && offset + 8 <= limit; i++) {
      final chunk = await _read(offset, 8);
      final type = chunk.getUint32(0);
      final length = chunk.getUint32(4, Endian.little);
      final start = offset + 8;
      if (length > limit - start) return null;
      if (!inHeader && type == 0x4c495354 && length >= 4) {
        final list = await _read(start, 4);
        if (list.getUint32(0) == 0x6864726c) {
          inHeader = true;
          limit = start + length;
          offset = start + 4;
          continue;
        }
      }
      if (inHeader && type == 0x61766968 && length >= 20) {
        final data = await _read(start, 20);
        return _microseconds(
          data.getUint32(0, Endian.little) *
              data.getUint32(16, Endian.little).toDouble(),
        );
      }
      offset = start + length + length % 2;
    }
    return null;
  }
}
