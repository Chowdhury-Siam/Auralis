import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

typedef OfflineDownload = Future<void> Function(
  Future<void> Function(File) copy,
  ValueChanged<double?> reportProgress,
);

/// Explicitly saved media lives outside the disposable Telegram cache.
class OfflineMedia extends ChangeNotifier {
  OfflineMedia(this.directory);

  final Directory directory;
  final _entries = <(bool, String), Track>{};
  final _saving =
      <(bool, String), ({Future<void> job, ValueNotifier<double?> progress})>{};
  final _removing = <(bool, String), Future<void>>{};
  Future<void>? _loading;
  bool _disposed = false;

  String _key(bool video, String id) => sha256
      .convert(utf8.encode('${video ? 'video' : 'music'}:$id'))
      .toString();

  Directory _folder(bool video, String id) =>
      Directory(p.join(directory.path, _key(video, id)));

  bool contains(String id, {required bool video}) =>
      _entries.containsKey((video, id));

  bool saving(String id, {required bool video}) =>
      _saving.containsKey((video, id));

  ValueListenable<double?>? downloadProgress(String id, {required bool video}) =>
      _saving[(video, id)]?.progress;

  List<Track> tracks({required bool video}) => [
    for (final entry in _entries.entries)
      if (entry.key.$1 == video) entry.value,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  Future<Uri?> uri(String id, {required bool video}) async {
    await load();
    return availableUri(id, video: video);
  }

  Uri? availableUri(String id, {required bool video}) {
    if (!contains(id, video: video)) return null;
    final file = File(p.join(_folder(video, id).path, 'media'));
    return file.existsSync() ? file.uri : null;
  }

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      if (!await directory.exists()) return;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (p.basename(entity.path).startsWith('.partial-')) {
          await _delete(entity);
          continue;
        }
        try {
          final value = jsonDecode(
            await File(p.join(entity.path, 'track.json')).readAsString(),
          ) as Map<String, dynamic>;
          final video = value['video'] as bool;
          final id = value['id'] as String;
          final size = value['size'] as int;
          if (p.basename(entity.path) != _key(video, id) ||
              size <= 0 ||
              await File(p.join(entity.path, 'media')).length() != size) {
            continue;
          }
          _entries[(video, id)] = Track(
            id: id,
            title: value['title'] as String,
            artist: value['artist'] as String,
            source: value['source'] as String,
            mime: value['mime'] as String,
            size: size,
            duration: Duration(milliseconds: value['duration'] as int),
            date: value['date'] as int,
            coverPreview: decodePreview(value['preview']),
          );
        } catch (_) {
          // An unreadable entry must not hide other saved media.
        }
      }
    } on FileSystemException {
      // The library can still open and a later save may create the folder.
    } finally {
      _changed();
    }
  }

  Future<void> save(
    Track track, {
    required bool video,
    required OfflineDownload download,
  }) {
    final key = (video, track.id);
    if (_saving[key] case final pending?) return pending.job;
    final progress = ValueNotifier<double?>(null);
    final job = _save(
      track,
      video,
      _removing[key],
      (copy) => download(copy, (value) => progress.value = value),
    ).whenComplete(() {
      _saving.remove(key);
      progress.dispose();
      _changed();
    });
    _saving[key] = (job: job, progress: progress);
    _changed();
    return job;
  }

  Future<void> _save(
    Track track,
    bool video,
    Future<void>? removing,
    Future<void> Function(Future<void> Function(File)) download,
  ) async {
    await removing;
    if (await uri(track.id, video: video) != null) return;
    final folder = _folder(video, track.id);
    await directory.create(recursive: true);
    final stage = await directory.createTemp('.partial-');
    try {
      await download((source) async {
        final copy = await source.copy(p.join(stage.path, 'media'));
        final length = await copy.length();
        if (length <= 0 || (track.size > 0 && track.size != length)) {
          throw StateError('The media download was incomplete.');
        }
        await File(p.join(stage.path, 'track.json')).writeAsString(
          jsonEncode({
            'video': video,
            'id': track.id,
            'title': track.title,
            'artist': track.artist,
            'source': track.source,
            'mime': track.mime,
            'size': length,
            'duration': track.duration.inMilliseconds,
            'date': track.date,
            if (track.coverPreview case final preview?)
              'preview': base64Encode(preview),
          }),
          flush: true,
        );
        if (await folder.exists()) await folder.delete(recursive: true);
        await stage.rename(folder.path);
        _entries[(video, track.id)] = track;
      });
    } finally {
      await _delete(stage);
    }
  }

  Future<void> remove(String id, {required bool video}) {
    final key = (video, id);
    return _removing[key] ??= _remove(
      id,
      video,
      _saving[key]?.job,
    ).whenComplete(() {
      _removing.remove(key);
    });
  }

  Future<void> _remove(String id, bool video, Future<void>? saving) async {
    await load();
    await saving;
    final folder = _folder(video, id);
    if (await folder.exists()) {
      final stage = await directory.createTemp('.partial-');
      await stage.delete();
      await folder.rename(stage.path);
      await _delete(stage);
    }
    _entries.remove((video, id));
    _changed();
  }

  Future<void> _delete(Directory folder) async {
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // A later launch can clean up an interrupted copy.
    }
  }

  Future<void> drain() => Future.wait<void>([
    for (final job in [
      for (final save in _saving.values) save.job,
      ..._removing.values,
    ])
      job.then<void>((_) {}, onError: (Object _) {}),
  ]);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
