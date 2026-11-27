import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models.dart';

typedef VideoCacheKey = ({Digest identity, int size});
typedef _Page = (VideoCacheKey, int);
typedef _Slice = ({int slot, int offset, int length, Digest digest});

/// Keeps recently streamed video ranges in a bounded file across app launches.
class VideoStreamCache {
  VideoStreamCache(this.file, {int pages = 512, this.namespace})
    : _pages = pages {
    assert(pages >= 8);
  }

  static const pageSize = 128 * 1024;
  static final _magic = ascii.encode('AURVRC01');
  static const _headerBytes = 12;
  // Each slot has an identity, file size, offset, length, write order and hashes.
  static const _recordBytes = 124;
  final File file;
  final String Function()? namespace;
  final int _pages;
  final _headers = <_Page, _Slice>{};
  final _video = <_Page, _Slice>{};
  final _freeHeaderSlots = <int>[];
  final _freeVideoSlots = <int>[];
  RandomAccessFile? _writer;
  Future<void>? _loading, _writing, _maintenance;
  _Page? _writingPage;
  bool _loaded = false, _hasIndex = false;
  int _writeOrder = 0;

  int get _headerSlots => _pages ~/ 8;
  int get _indexBytes => _headerBytes + _pages * _recordBytes;
  int _dataOffset(int slot) => _indexBytes + slot * pageSize;
  int _indexOffset(int slot) => _headerBytes + slot * _recordBytes;

  VideoCacheKey keyFor(Track track) => (
    identity: sha256.convert(
      utf8.encode(
        jsonEncode([
          namespace?.call(),
          track.id,
          track.remoteFileUniqueId ?? track.fileId,
        ]),
      ),
    ),
    size: track.size,
  );

  // Reserve room for container headers and indexes when a long stream rolls
  // through the rest of the cache.
  bool _isHeader(_Page page) {
    final offset = page.$2 * pageSize;
    return offset < 1024 * 1024 || page.$1.size - offset <= 512 * 1024;
  }

  Map<_Page, _Slice> _entries(_Page page) =>
      _isHeader(page) ? _headers : _video;
  List<int> _freeSlots(_Page page) =>
      _isHeader(page) ? _freeHeaderSlots : _freeVideoSlots;

  Future<int> get bytes async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() {
      _loaded = true;
      _loading = null;
    });
  }

  Future<void> _load() async {
    try {
      final reader = await file.open();
      try {
        final length = await reader.length();
        final table = await reader.read(_indexBytes);
        if (table.length < _headerBytes ||
            !_magic.asMap().entries.every(
              (byte) => table[byte.key] == byte.value,
            ) ||
            ByteData.sublistView(table).getUint32(8) != _pages) {
          return;
        }
        _hasIndex = true;
        final records = <({_Page page, _Slice slice, int order})>[];
        for (var slot = 0; slot < _pages; slot++) {
          final start = _indexOffset(slot);
          if (start + _recordBytes > table.length) break;
          final record = ByteData.sublistView(
            table,
            start,
            start + _recordBytes,
          );
          final size = record.getInt64(32);
          final offset = record.getInt64(40);
          final count = record.getUint32(48);
          final order = record.getInt64(52);
          if (!_validRange(size, offset, count) ||
              order <= 0 ||
              _dataOffset(slot) + count > length) {
            continue;
          }
          final fields = Uint8List.sublistView(table, start, start + 92);
          final checksum = Digest(
            Uint8List.sublistView(table, start + 92, start + _recordBytes),
          );
          if (sha256.convert(fields) != checksum) continue;
          final key = (
            identity: Digest(Uint8List.sublistView(table, start, start + 32)),
            size: size,
          );
          final page = (key, offset ~/ pageSize);
          if (_isHeader(page) != (slot < _headerSlots)) continue;
          records.add((
            page: page,
            slice: (
              slot: slot,
              offset: offset,
              length: count,
              digest: Digest(
                Uint8List.sublistView(table, start + 60, start + 92),
              ),
            ),
            order: order,
          ));
        }
        records.sort((a, b) => a.order.compareTo(b.order));
        for (final record in records) {
          final entries = _entries(record.page);
          entries.remove(record.page);
          entries[record.page] = record.slice;
          _writeOrder = record.order;
        }
      } finally {
        await reader.close();
      }
    } on FileSystemException {
      // An unavailable or legacy cache is an ordinary miss.
    } finally {
      _resetFreeSlots();
    }
  }

  void _resetFreeSlots() {
    final used = {
      for (final slice in _headers.values) slice.slot,
      for (final slice in _video.values) slice.slot,
    };
    _freeHeaderSlots.clear();
    _freeVideoSlots.clear();
    for (var slot = _pages - 1; slot >= 0; slot--) {
      if (!used.contains(slot)) {
        (slot < _headerSlots ? _freeHeaderSlots : _freeVideoSlots).add(slot);
      }
    }
  }

  static bool _validRange(int size, int offset, int count) =>
      offset >= 0 &&
      offset < size &&
      count > 0 &&
      count <= size - offset &&
      count <= pageSize - offset % pageSize;

  Future<int> contiguousPrefix(VideoCacheKey key, int limit) async {
    if (_maintenance != null) return 0;
    await _ensureLoaded();
    if (_maintenance != null) return 0;
    var offset = 0;
    while (offset < limit) {
      final page = (key, offset ~/ pageSize);
      final slice = _entries(page)[page];
      if (slice == null || slice.offset > offset) break;
      final end = slice.offset + slice.length;
      if (end <= offset) break;
      offset = end;
    }
    return min(offset, limit);
  }

  Future<Uint8List?> read(VideoCacheKey key, int offset, int count) async {
    if (_maintenance != null || count <= 0 || offset < 0) return null;
    await _ensureLoaded();
    final page = (key, offset ~/ pageSize);
    if (_writingPage == page) await _writing;
    if (_maintenance != null) return null;
    final entries = _entries(page);
    final slice = entries[page];
    if (slice == null) return null;
    final start = offset - slice.offset;
    if (start < 0 || start >= slice.length) return null;
    try {
      final reader = await file.open();
      late Uint8List data;
      try {
        await reader.setPosition(_dataOffset(slice.slot));
        data = await reader.read(slice.length);
      } finally {
        await reader.close();
      }
      if (_maintenance != null || entries[page] != slice) return null;
      if (data.length == slice.length && sha256.convert(data) == slice.digest) {
        entries.remove(page);
        entries[page] = slice;
        return Uint8List.sublistView(
          data,
          start,
          min(start + count, slice.length),
        );
      }
    } on FileSystemException {
      // Treat unavailable disk as a miss.
    }
    if (entries[page] == slice) {
      entries.remove(page);
      _freeSlots(page).add(slice.slot);
    }
    return null;
  }

  void store(VideoCacheKey key, int offset, Uint8List data) {
    // One best-effort write at a time. A slow disk never queues video data.
    if (_writing != null ||
        _maintenance != null ||
        !_validRange(key.size, offset, data.length)) {
      return;
    }
    final page = _writingPage = (key, offset ~/ pageSize);
    _writing = _store(page, offset, data).whenComplete(() {
      _writingPage = null;
      _writing = null;
    });
  }

  Future<void> _store(_Page page, int offset, Uint8List data) async {
    await _ensureLoaded();
    final entries = _entries(page);
    final old = entries[page];
    if (old != null &&
        (old.length > data.length ||
            (old.offset <= offset &&
                old.offset + old.length >= offset + data.length))) {
      return;
    }
    final free = _freeSlots(page);
    final slot =
        old?.slot ??
        (free.isNotEmpty
            ? free.removeLast()
            : entries.remove(entries.keys.first)!.slot);
    entries.remove(page);
    try {
      final writer = _writer ??= await _openWriter();
      final digest = sha256.convert(data);
      await writer.setPosition(_dataOffset(slot));
      await writer.writeFrom(data);
      // Publish the index only after the bytes. A torn write fails its digest.
      final record = Uint8List(_recordBytes)
        ..setRange(0, 32, page.$1.identity.bytes)
        ..setRange(60, 92, digest.bytes);
      ByteData.sublistView(record)
        ..setInt64(32, page.$1.size)
        ..setInt64(40, offset)
        ..setUint32(48, data.length)
        ..setInt64(52, ++_writeOrder);
      record.setRange(
        92,
        _recordBytes,
        sha256.convert(Uint8List.sublistView(record, 0, 92)).bytes,
      );
      await writer.setPosition(_indexOffset(slot));
      await writer.writeFrom(record);
      entries[page] = (
        slot: slot,
        offset: offset,
        length: data.length,
        digest: digest,
      );
    } on FileSystemException {
      free.add(slot);
    }
  }

  Future<RandomAccessFile> _openWriter() async {
    final writer = await file.open(
      mode: _hasIndex ? FileMode.append : FileMode.write,
    );
    if (_hasIndex) return writer;
    try {
      final header = Uint8List(_headerBytes)
        ..setRange(0, _magic.length, _magic);
      ByteData.sublistView(header).setUint32(8, _pages);
      await writer.writeFrom(header);
      _hasIndex = true;
      return writer;
    } catch (_) {
      await writer.close();
      rethrow;
    }
  }

  Future<void> close() => _maintain(delete: false);
  Future<void> clear() => _maintain(delete: true);

  Future<void> _maintain({required bool delete}) async {
    while (_maintenance != null) {
      await _maintenance;
    }
    await (_maintenance = _finish(delete: delete)
        .whenComplete(() => _maintenance = null));
  }

  Future<void> _finish({required bool delete}) async {
    await _loading;
    await _writing;
    final writer = _writer;
    _writer = null;
    if (writer != null) {
      try {
        if (!delete) await writer.flush();
      } on FileSystemException {
        // Completed ranges with invalid bytes become misses when reopened.
      } finally {
        try {
          await writer.close();
        } on FileSystemException {
          // Still try to remove the file when clearing.
        }
      }
    }
    if (!delete) return;
    _headers.clear();
    _video.clear();
    _hasIndex = false;
    _loaded = true;
    _writeOrder = 0;
    _resetFreeSlots();
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // A later write creates a clean index.
    }
  }
}
