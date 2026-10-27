import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Only extracted artwork and lyrics live here; audio stays in TDLib's temporary buffer.
class MediaCache {
  MediaCache(this.directory);
  final Directory? directory;
  static final _pending = <String, Set<Future<dynamic>>>{};
  static bool hasPending(Directory root) => _pending.entries.any(
    (entry) =>
        (p.equals(root.absolute.path, entry.key) ||
            p.isWithin(root.absolute.path, entry.key)) &&
        entry.value.isNotEmpty,
  );
  static Future<void> drain(Directory root) async {
    while (hasPending(root)) {
      final work = [
        for (final entry in _pending.entries)
          if (p.equals(root.absolute.path, entry.key) ||
              p.isWithin(root.absolute.path, entry.key))
            ...entry.value,
      ];
      await Future.wait(work);
    }
  }

  Future<T> _track<T>(Future<T> Function() operation) {
    if (directory == null) return operation();
    final path = directory!.absolute.path;
    final work = _pending.putIfAbsent(path, () => {});
    late final Future<T> result;
    result = operation().whenComplete(() {
      work.remove(result);
      if (work.isEmpty) _pending.remove(path);
    });
    work.add(result);
    return result;
  }

  String key(Track track) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            track.id,
            track.fileId,
            track.size,
            track.coverFileId,
            track.title,
            track.artist,
            track.duration.inSeconds,
          ]),
        ),
      )
      .toString();
  Future<Uint8List?> read(Track track, String kind, int limit) =>
      _track(() => _read(track, kind, limit));
  Future<Uint8List?> _read(Track track, String kind, int limit) async {
    if (directory == null) return null;
    try {
      final file = File('${directory!.path}/${key(track)}.$kind');
      if (await file.length() > limit) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> clearArtwork() => _track(() async {
    if (directory == null || !await directory!.exists()) return;
    await for (final entry in directory!.list(followLinks: false)) {
      if (entry is File &&
          RegExp(r'^[a-f0-9]{64}\.art$').hasMatch(p.basename(entry.path))) {
        try {
          await entry.delete();
        } on FileSystemException {
          /* Retry on the next explicit clear. */
        }
      }
    }
  });

  Future<void> write(Track track, String kind, List<int> bytes) =>
      _track(() => _write(track, kind, bytes));
  Future<void> _write(Track track, String kind, List<int> bytes) async {
    if (directory == null) return;
    File? temporary;
    try {
      await directory!.create(recursive: true);
      final file = File('${directory!.path}/${key(track)}.$kind');
      temporary = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } on FileSystemException {
      // Storage failure must not interrupt playback or a library refresh.
    } finally {
      if (temporary != null && await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          /* best effort */
        }
      }
    }
  }
}
