import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef _Page = (int fileId, int size, int index);
typedef _Slice = ({int slot, int offset, int length, Digest digest});

/// Keeps recently streamed video ranges in one bounded, session-scoped file.
class VideoStreamCache {
  VideoStreamCache(this.file, {int pages = 512}) : _pages = pages {
    assert(pages >= 8);
  }

  static const pageSize = 128 * 1024;
  final File file;
  final int _pages;
  final _headers = <_Page, _Slice>{};
  final _video = <_Page, _Slice>{};
  final _freeHeaderSlots = <int>[];
  final _freeVideoSlots = <int>[];
  int _nextHeaderSlot = 0;
  late int _nextVideoSlot = _pages ~/ 8;
  RandomAccessFile? _writer;
  Future<void>? _writing, _clearing;
  _Page? _writingPage;
  bool _used = false;

  // Reserve room for container headers and indexes when a long stream rolls
  // through the rest of the cache.
  Map<_Page, _Slice> _entries(_Page page) {
    final offset = page.$3 * pageSize;
    return offset < 1024 * 1024 || page.$2 - offset <= 512 * 1024
        ? _headers
        : _video;
  }

  Future<int> get bytes async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }

  int contiguousPrefix(int id, int size, int limit) {
    var offset = 0;
    while (offset < limit) {
      final page = (id, size, offset ~/ pageSize);
      final slice = _entries(page)[page];
      if (slice == null || slice.offset > offset) break;
      final end = slice.offset + slice.length;
      if (end <= offset) break;
      offset = end;
    }
    return min(offset, limit);
  }

  Future<Uint8List?> read(int id, int size, int offset, int count) async {
    final page = (id, size, offset ~/ pageSize);
    if (_writingPage == page) await _writing;
    final entries = _entries(page);
    final slice = entries[page];
    if (slice == null) return null;
    final start = offset - slice.offset;
    if (start < 0 || start >= slice.length) return null;
    try {
      final reader = await file.open();
      late Uint8List data;
      try {
        await reader.setPosition(slice.slot * pageSize);
        data = await reader.read(slice.length);
      } finally {
        await reader.close();
      }
      if (entries[page] != slice) return null;
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
      (identical(entries, _headers) ? _freeHeaderSlots : _freeVideoSlots).add(
        slice.slot,
      );
    }
    return null;
  }

  void store(int id, int size, int offset, Uint8List data) {
    // One best-effort write at a time. A slow disk never queues video data.
    if (_writing != null || _clearing != null || data.isEmpty) return;
    final page = (id, size, offset ~/ pageSize);
    final entries = _entries(page);
    final old = entries[page];
    if (old != null &&
        (old.length > data.length ||
            (old.offset <= offset &&
                old.offset + old.length >= offset + data.length))) {
      return;
    }
    final header = identical(entries, _headers);
    final free = header ? _freeHeaderSlots : _freeVideoSlots;
    final int slot;
    if (old != null) {
      slot = old.slot;
    } else if (free.isNotEmpty) {
      slot = free.removeLast();
    } else if (header && _nextHeaderSlot < _pages ~/ 8) {
      slot = _nextHeaderSlot++;
    } else if (!header && _nextVideoSlot < _pages) {
      slot = _nextVideoSlot++;
    } else {
      slot = entries.remove(entries.keys.first)!.slot;
    }
    entries.remove(page);
    _used = true;
    _writingPage = page;
    _writing =
        () async {
          try {
            final writer = _writer ??= await file.open(mode: FileMode.write);
            await writer.setPosition(slot * pageSize);
            await writer.writeFrom(data);
            entries[page] = (
              slot: slot,
              offset: offset,
              length: data.length,
              digest: sha256.convert(data),
            );
          } on FileSystemException {
            free.add(slot);
          }
        }().whenComplete(() {
          _writingPage = null;
          _writing = null;
        });
  }

  Future<void> clear({bool removeAbandoned = false}) {
    if (!_used && !removeAbandoned) return Future<void>.value();
    return _clearing ??= _clear().whenComplete(() => _clearing = null);
  }

  Future<void> _clear() async {
    await _writing;
    _headers.clear();
    _video.clear();
    _freeHeaderSlots.clear();
    _freeVideoSlots.clear();
    _nextHeaderSlot = 0;
    _nextVideoSlot = _pages ~/ 8;
    try {
      await _writer?.close();
    } on FileSystemException {
      // Still try to remove the file.
    }
    _writer = null;
    try {
      await file.delete();
    } on FileSystemException {
      // The next write truncates the old file.
    }
    _used = false;
  }
}
