import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'telegram/embedded_cover.dart';
import 'video_files.dart';
import 'video_playback_data.dart';

enum LocalMediaView {
  songs('Songs'),
  albums('Albums'),
  artists('Artists'),
  genres('Genres'),
  videos('All videos'),
  playlists('Playlists'),
  history('History'),
  snapshots('Snapshots'),
  offline('Offline'),
  folders('Folders');

  const LocalMediaView(this.label);
  final String label;

  bool get isSavedVideoCollection =>
      this == playlists || this == history || this == snapshots;
}

String? _tag(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty || text.toLowerCase() == '<unknown>' ? null : text;
}

class LocalMedia {
  LocalMedia(Map<Object?, Object?> row, {required this.isVideo})
    : uri = Uri.parse(row['uri'] as String),
      name = _tag(row['name']) ?? (isVideo ? 'Video' : 'Song'),
      folder = _tag(row['folder']) ?? '',
      date = row['date'] as int? ?? 0,
      size = row['size'] as int? ?? 0,
      albumKey = _tag(row['albumKey']),
      tags = row;

  final Uri uri;
  final bool isVideo;
  final String name, folder;
  final String? albumKey;
  final int date, size;
  final Map<Object?, Object?> tags;

  String get title => _tag(tags['title']) ?? name;
  String get artist => _tag(tags['artist']) ?? 'Unknown artist';
  String get album => _tag(tags['album']) ?? 'Unknown album';
  String get albumArtist => _tag(tags['albumArtist']) ?? artist;
  String get genre => _tag(tags['genre']) ?? 'Unknown genre';
  Duration get duration =>
      Duration(milliseconds: tags['duration'] as int? ?? 0);
  (Uri, int, int) get revision => (uri, date, size);

  LocalMedia withTags(Map<Object?, Object?> metadata) =>
      LocalMedia({...tags, ...metadata}, isVideo: isVideo);

  late final video = VideoSource.file(uri, title, runtime: duration);
  late final track = Track(
    id: 'local:${sha256.convert(utf8.encode(uri.toString()))}',
    title: title,
    artist: isVideo ? '' : artist,
    source: 'On this device',
    localUri: uri,
    duration: duration,
    date: date,
    size: size,
  );

  bool matches(String query) => [
    title,
    name,
    folder,
    if (!isVideo) ...[artist, album, albumArtist, genre],
  ].any((part) => part.toLowerCase().contains(query));
}

typedef LocalMediaGroup = ({
  String key,
  String label,
  String detail,
  int count,
});

class LocalMediaSelection {
  const LocalMediaSelection(this.rows, this.groups);
  final List<LocalMedia> rows;
  final List<LocalMediaGroup> groups;
}

/// Builds one snapshot so row indices and playback queue are always aligned.
LocalMediaSelection selectLocalMedia(
  List<LocalMedia> entries,
  LocalMediaView view,
  String? group,
  String query,
  LibrarySort sort,
) {
  final matching = <LocalMedia>[];
  final groups = <String, LocalMediaGroup>{};
  final groupSortKeys = <String, Track>{};
  for (final item in entries) {
    final (key, label, detail) = switch (view) {
      LocalMediaView.albums => (
        item.albumKey ??
            '${item.album.toLowerCase()}\u0000${item.albumArtist.toLowerCase()}',
        item.album,
        item.albumArtist,
      ),
      LocalMediaView.artists => (item.artist.toLowerCase(), item.artist, ''),
      LocalMediaView.genres => (item.genre.toLowerCase(), item.genre, ''),
      LocalMediaView.folders => (
        _tag(item.tags['folderKey']) ?? item.folder,
        item.folder.isEmpty ? 'Storage' : p.basename(item.folder),
        item.folder,
      ),
      _ => ('', '', ''),
    };
    if (group != null && group != key) continue;
    if (query.isNotEmpty && !item.matches(query)) continue;
    if (view == LocalMediaView.songs ||
        view == LocalMediaView.videos ||
        group != null) {
      matching.add(item);
    } else {
      groups[key] = (
        key: key,
        label: label,
        detail: detail,
        count: (groups[key]?.count ?? 0) + 1,
      );
      if (sort != LibrarySort.title) {
        final previous = groupSortKeys[key];
        if (previous == null || sort.compare(item.track, previous) < 0) {
          groupSortKeys[key] = item.track;
        }
      }
    }
  }
  final byTrack = <Track, LocalMedia>{
    for (final item in matching) item.track: item,
  };
  final groupRows = groups.values.toList()
    ..sort((a, b) {
      if (sort != LibrarySort.title) {
        final order = sort.compare(
          groupSortKeys[a.key]!,
          groupSortKeys[b.key]!,
        );
        if (order != 0) return order;
      }
      final name = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return name != 0 ? name : a.key.compareTo(b.key);
    });
  final sorted = matching.firstOrNull?.isVideo == true
      ? sortVideoLibrary(byTrack.keys, sort)
      : (byTrack.keys.toList()..sort(sort.compare));
  return LocalMediaSelection([
    for (final track in sorted) byTrack[track]!,
  ], groupRows);
}

typedef LocalMediaScan = ({List<LocalMedia> entries, int unavailable});

/// Runs on a worker isolate. Overlapping roots are visited once and directory
/// links are skipped to avoid cycles and scanning outside the selected roots.
LocalMediaScan scanLocalFolders(List<String> folders, {required bool video}) {
  final entries = <LocalMedia>[];
  final visited = <String>{};
  var unavailable = 0;
  for (final folder in folders) {
    final pending = <String>[folder];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final Directory directory;
      try {
        directory = Directory(Directory(current).resolveSymbolicLinksSync());
      } on FileSystemException {
        unavailable++;
        continue;
      }
      final key = Platform.isWindows
          ? directory.path.toLowerCase()
          : directory.path;
      if (!visited.add(key)) continue;
      try {
        for (final entity in directory.listSync(followLinks: false)) {
          if (entity is Directory) {
            pending.add(entity.path);
          } else if (entity is File &&
              (video ? videoExtensions : audioExtensions).contains(
                p.extension(entity.path).toLowerCase().replaceFirst('.', ''),
              )) {
            try {
              final stat = entity.statSync();
              if (stat.type != FileSystemEntityType.file) continue;
              entries.add(
                LocalMedia({
                  'uri': entity.uri.toString(),
                  'name': p.basename(entity.path),
                  'folder': directory.path,
                  'date': stat.modified.millisecondsSinceEpoch,
                  'size': stat.size,
                }, isVideo: video),
              );
            } on FileSystemException {
              // A file can disappear while a folder is being scanned.
            }
          }
        }
      } on FileSystemException {
        unavailable++;
      }
    }
  }
  return (entries: entries, unavailable: unavailable);
}

const _android = MethodChannel('app.auralis/local_media');
const _windows = MethodChannel('app.auralis/local_media_windows');
const _changes = EventChannel('app.auralis/local_media_changes');

class LocalMediaPlatform {
  const LocalMediaPlatform();

  bool get android => Platform.isAndroid;
  bool get windows => Platform.isWindows;
  Stream<void> get changes => _changes.receiveBroadcastStream().map((_) {});

  Future<LocalMediaFolder?> chooseFolder() async {
    if (android) {
      final folder = await _android.invokeMapMethod<String, String>(
        'chooseFolder',
      );
      if (folder case {'uri': final String uri, 'name': final String name}) {
        return (location: uri, name: name);
      }
      return null;
    }
    final folder = await getDirectoryPath();
    if (folder == null) return null;
    final location = p.normalize(folder);
    final name = p.basename(location);
    return (location: location, name: name.isEmpty ? location : name);
  }

  Future<LocalMediaScan> scan(bool video, List<String> folders) async {
    if (folders.isEmpty) return (entries: const <LocalMedia>[], unavailable: 0);
    if (android) {
      final snapshot = await _android.invokeMapMethod<String, int>(
        'scanFolders',
        {
          'video': video,
          'folders': folders,
          'extensions': video ? videoExtensions : audioExtensions,
        },
      );
      final rows = <Map<Object?, Object?>>[];
      if (snapshot case {'token': final int token, 'count': final int count}) {
        try {
          for (var start = 0; start < count; start += 512) {
            final page = await _android.invokeListMethod<Map<Object?, Object?>>(
              'scanPage',
              {'token': token, 'start': start},
            );
            if (page != null) rows.addAll(page);
          }
        } finally {
          await _android.invokeMethod<void>('finishScan', token);
        }
      }
      return Isolate.run(() {
        final seen = <String>{};
        return (
          entries: [
            for (final row in rows)
              if (seen.add(row['uri'] as String))
                LocalMedia(row, isVideo: video),
          ],
          unavailable: snapshot?['unavailable'] ?? 0,
        );
      });
    }
    return Isolate.run(() => scanLocalFolders(folders, video: video));
  }

  Future<List<LocalMedia>> openSongs() async {
    final List<Map<Object?, Object?>> rows;
    if (android) {
      rows =
          await _android.invokeListMethod<Map<Object?, Object?>>('openSongs') ??
          [];
    } else {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Audio files', extensions: audioExtensions),
        ],
      );
      rows = [
        for (final file in files)
          {'uri': File(file.path).uri.toString(), 'name': file.name},
      ];
    }
    final seen = <Object?>{};
    return [
      for (final row in rows)
        if (seen.add(row['uri'])) LocalMedia(row, isVideo: false),
    ];
  }

  /// Reads tags on demand for the visible rows and tag-dependent collections.
  Future<LocalMedia> metadata(LocalMedia source) async {
    if (windows || (android && !source.isVideo)) {
      try {
        final channel = windows ? _windows : _android;
        final tags = await channel.invokeMapMethod<Object?, Object?>(
          'metadata',
          windows ? source.uri.toFilePath() : source.uri.toString(),
        );
        if (tags != null) {
          if (source.isVideo) tags.remove('title');
          source = source.withTags(tags);
        }
      } on Exception {
        // Try the same header lookup used by the Video player and Info sheet.
      }
    }
    try {
      if (source.duration <= Duration.zero && source.isVideo) {
        final video = source.video;
        final duration = video.uri!.scheme == 'file'
            ? await Isolate.run(() => readLocalVideoDuration(video))
            : await readLocalVideoDuration(video);
        if (duration != null) {
          source = source.withTags({'duration': duration.inMilliseconds});
        }
      }
    } on Exception {
      // Unsupported tags and files removed during browsing use the indexed data.
    }
    return source;
  }

  Future<Uint8List?> artwork(LocalMedia item) async {
    try {
      if (android) {
        return await _android.invokeMethod<Uint8List>('artwork', {
          'uri': item.uri.toString(),
          'video': item.isVideo,
        });
      }
      if (windows) {
        try {
          final image = await _windows.invokeMethod<Uint8List>(
            'artwork',
            item.uri.toFilePath(),
          );
          if (image != null) return image;
        } on Exception {
          // The bounded embedded-cover reader can still handle audio files.
        }
      }
      if (item.isVideo || item.uri.scheme != 'file') return null;
      final file = File.fromUri(item.uri);
      final input = await file.open();
      try {
        return await readEmbeddedCover((offset, count) async {
          await input.setPosition(offset);
          return input.read(count);
        }, await input.length());
      } finally {
        await input.close();
      }
    } on Exception {
      return null;
    }
  }
}

/// Limits concurrent jobs and keeps a bounded cache, including missing images.
class LocalArtworkCache {
  LocalArtworkCache(this.platform);
  final LocalMediaPlatform platform;
  final _images = <(Uri, int, int), Future<Uint8List?>>{};
  final _pending = Queue<Future<void> Function()>();
  var _running = 0;

  Future<Uint8List?> load(LocalMedia item) {
    final key = item.revision;
    final cached = _images.remove(key);
    if (cached != null) return _images[key] = cached;
    final result = Completer<Uint8List?>();
    if (_images.length >= 96) _images.remove(_images.keys.first);
    _images[key] = result.future;
    _pending.add(() async {
      if (identical(_images[key], result.future)) {
        result.complete(await platform.artwork(item));
      } else {
        result.complete(null);
      }
    });
    _drain();
    return result.future;
  }

  void _drain() {
    while (_running < 3 && _pending.isNotEmpty) {
      _running++;
      unawaited(
        _pending.removeFirst()().whenComplete(() {
          _running--;
          _drain();
        }),
      );
    }
  }
}

final localLibraryArtwork = LocalArtworkCache(const LocalMediaPlatform());

Future<Uint8List?> localSongArtwork(Track track) => localLibraryArtwork.load(
  LocalMedia({
    'uri': track.localUri.toString(),
    'name': track.title,
    'date': track.date,
    'size': track.size,
  }, isVideo: false),
);
