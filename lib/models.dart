import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

Uint8List? decodePreview(dynamic value) {
  if (value is! String || value.length > 64 * 1024) return null;
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

const audioExtensions = [
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'wav',
  'wma',
];

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    this.fileId,
    this.coverFileId,
    this.coverPreview,
    this.date = 0,
    this.size = 0,
    this.duration = Duration.zero,
    this.mime = 'application/octet-stream',
  });
  final String id, title, artist, source, mime;
  final int? fileId, coverFileId;
  final Uint8List? coverPreview;
  final int size, date;
  final Duration duration;

  static Track? fromMessage(Map<String, dynamic> message, String chatTitle) {
    final content = message['content'] as Map<String, dynamic>?;
    if (content == null) return null;
    final isAudio = content['@type'] == 'messageAudio';
    if (!isAudio && content['@type'] != 'messageDocument') return null;
    final data =
        content[isAudio ? 'audio' : 'document'] as Map<String, dynamic>;
    final name = data['file_name'] as String? ?? '';
    if (!isAudio &&
        !audioExtensions.contains(
          p.extension(name).replaceFirst('.', '').toLowerCase(),
        )) {
      return null;
    }
    final file = data[isAudio ? 'audio' : 'document'] as Map<String, dynamic>;
    final covers =
        <Map<String, dynamic>>[
          if (isAudio && data['album_cover_thumbnail'] is Map<String, dynamic>)
            data['album_cover_thumbnail'],
          if (isAudio)
            ...(data['external_album_covers'] as List? ?? [])
                .whereType<Map<String, dynamic>>(),
          if (!isAudio && data['thumbnail'] is Map<String, dynamic>)
            data['thumbnail'],
        ]..sort(
          (a, b) => ((b['width'] as int? ?? 0) * (b['height'] as int? ?? 0))
              .compareTo(
                (a['width'] as int? ?? 0) * (a['height'] as int? ?? 0),
              ),
        );
    return Track(
      id: '${message['chat_id']}:${message['id']}',
      title: (data['title'] as String? ?? '').isNotEmpty
          ? data['title']
          : p.basenameWithoutExtension(name),
      artist: (data['performer'] as String? ?? '').isNotEmpty
          ? data['performer']
          : chatTitle,
      source: chatTitle,
      date: message['date'] as int? ?? 0,
      fileId: file['id'] as int,
      coverFileId: covers.isEmpty ? null : covers.first['file']?['id'] as int?,
      coverPreview: decodePreview(
        data[isAudio ? 'album_cover_minithumbnail' : 'minithumbnail']?['data'],
      ),
      size: file['size'] as int? ?? 0,
      duration: Duration(seconds: data['duration'] as int? ?? 0),
      mime: data['mime_type'] as String? ?? 'application/octet-stream',
    );
  }
}

enum PlaybackRepeat { off, all, one }

enum LibrarySort {
  newest('Newest first'),
  oldest('Oldest first'),
  title('Title (A–Z)'),
  artist('Artist (A–Z)'),
  duration('Duration (shortest first)');

  const LibrarySort(this.label);
  final String label;

  int compare(Track a, Track b) {
    final result = switch (this) {
      newest || oldest =>
        a.date == 0 || b.date == 0
            ? (a.date == 0 ? 1 : 0).compareTo(b.date == 0 ? 1 : 0)
            : this == newest
            ? b.date.compareTo(a.date)
            : a.date.compareTo(b.date),
      title => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      artist => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
      duration =>
        a.duration == Duration.zero || b.duration == Duration.zero
            ? (a.duration == Duration.zero ? 1 : 0).compareTo(
                b.duration == Duration.zero ? 1 : 0,
              )
            : a.duration.compareTo(b.duration),
    };
    if (result != 0) return result;
    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
  }
}

class MusicChat {
  const MusicChat(this.id, this.title, {this.photoFileId, this.photoPreview});
  final int id;
  final String title;
  final int? photoFileId;
  final Uint8List? photoPreview;

  static MusicChat? fromChat(Map<String, dynamic> chat) {
    final type = chat['type'] as Map<String, dynamic>?;
    return type?['@type'] == 'chatTypeSupergroup' && type?['is_channel'] == true
        ? MusicChat(
            chat['id'] as int,
            chat['title'] as String,
            photoFileId: chat['photo']?['small']?['id'] as int?,
            photoPreview: decodePreview(
              chat['photo']?['minithumbnail']?['data'],
            ),
          )
        : null;
  }
}

String clockText(Duration value) {
  final seconds = value.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
