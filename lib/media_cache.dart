import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// Only extracted artwork and lyrics live here; audio stays in TDLib's temporary buffer.
class MediaCache {
  MediaCache(this.directory);
  final Directory? directory;
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
  Future<Uint8List?> read(Track track, String kind, int limit) async {
    if (directory == null) return null;
    try {
      final file = File('${directory!.path}/${key(track)}.$kind');
      if (await file.length() > limit) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> write(Track track, String kind, List<int> bytes) async {
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
