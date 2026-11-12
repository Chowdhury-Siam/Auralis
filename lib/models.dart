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

const _videoExtensions = {
  '.mp4',
  '.mkv',
  '.webm',
  '.mov',
  '.avi',
  '.m4v',
  '.mpg',
  '.mpeg',
  '.ts',
  '.m2ts',
  '.wmv',
  '.3gp',
  '.flv',
  '.ogv',
};

/// A real Telegram re-encode, not a display-size or upscaling preset.
class VideoQuality {
  const VideoQuality({
    required this.fileId,
    required this.size,
    required this.width,
    required this.height,
    required this.codec,
  });

  final int fileId, size, width, height;
  final String codec;
  int get resolution => width < height ? width : height;
  String get label => videoResolutionLabel(width, height);

  static VideoQuality? fromTelegram(Object? raw) {
    if (raw is! Map) return null;
    final file = raw['video'];
    final width = raw['width'], height = raw['height'];
    if (file is! Map ||
        file['id'] is! int ||
        file['size'] is! int ||
        (file['id'] as int) <= 0 ||
        (file['size'] as int) <= 0 ||
        width is! int ||
        height is! int ||
        width <= 0 ||
        height <= 0) {
      return null;
    }
    return VideoQuality(
      fileId: file['id'] as int,
      size: file['size'] as int,
      width: width,
      height: height,
      codec: raw['codec'] is String ? raw['codec'] as String : '',
    );
  }
}

String videoResolutionLabel(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return 'Original';
  }
  final resolution = width < height ? width : height;
  return switch (resolution) {
    2160 => '2160p · 4K',
    1440 => '1440p · QHD',
    1080 => '1080p · FHD',
    720 => '720p · HD',
    _ => '${resolution}p',
  };
}

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
    this.videoWidth,
    this.videoHeight,
    this.videoQualities = const [],
  });
  final String id, title, artist, source, mime;
  final int? fileId, coverFileId;
  final Uint8List? coverPreview;
  final int size, date;
  final int? videoWidth, videoHeight;
  final List<VideoQuality> videoQualities;
  final Duration duration;

  // Video sources use the same byte-range proxy as music. They never enter
  // the music library or the listening history.
  static Track? fromVideoMessage(Map<String, dynamic> message, String source) {
    if (message['sending_state'] != null ||
        message['scheduling_state'] != null) {
      return null;
    }
    final content = message['content'];
    if (content is! Map<String, dynamic>) return null;
    final key = switch (content['@type']) {
      'messageVideo' => 'video',
      'messageDocument' => 'document',
      _ => null,
    };
    final media = content[key];
    if (key == null || media is! Map<String, dynamic>) return null;
    final name = (media['file_name'] as String? ?? '').trim();
    final mime = media['mime_type'] as String? ?? 'application/octet-stream';
    if (key == 'document' &&
        !mime.toLowerCase().startsWith('video/') &&
        !_videoExtensions.contains(p.extension(name).toLowerCase())) {
      return null;
    }
    final file = media[key];
    if (file is! Map<String, dynamic> ||
        file['id'] is! int ||
        file['size'] is! int ||
        (file['id'] as int) <= 0 ||
        (file['size'] as int) <= 0) {
      return null;
    }
    final caption = (content['caption']?['text'] as String? ?? '').trim();
    final title = p.basenameWithoutExtension(name);
    final seen = <int>{file['id'] as int};
    final alternatives = content['alternative_videos'];
    final qualities = key == 'video' && alternatives is List
        ? alternatives
              .map(VideoQuality.fromTelegram)
              .whereType<VideoQuality>()
              .where((quality) => seen.add(quality.fileId))
              .toList()
        : <VideoQuality>[];
    qualities.sort((a, b) => b.resolution.compareTo(a.resolution));
    return Track(
      id: '${message['chat_id']}:${message['id']}',
      title: title.isNotEmpty
          ? title
          : caption.isNotEmpty
          ? caption.split('\n').first
          : 'Telegram video',
      artist: '',
      source: source,
      fileId: file['id'] as int,
      size: file['size'] as int,
      duration: Duration(seconds: media['duration'] as int? ?? 0),
      videoWidth: media['width'] as int?,
      videoHeight: media['height'] as int?,
      videoQualities: List.unmodifiable(qualities),
      date: message['date'] as int? ?? 0,
      mime: mime,
      coverPreview: decodePreview(media['minithumbnail']?['data']),
      coverFileId: media['thumbnail']?['file']?['id'] as int?,
    );
  }

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

enum LyricsSource {
  lrclib('LRCLIB'),
  lyricsOvh('lyrics.ovh');

  const LyricsSource(this.label);
  final String label;
}

enum TranslationSource {
  google('Google Translate'),
  myMemory('MyMemory');

  const TranslationSource(this.label);
  final String label;
}

enum TranslationDirection {
  japaneseEnglish('Japanese → English', 'ja', 'en'),
  englishJapanese('English → Japanese', 'en', 'ja');

  const TranslationDirection(this.label, this.source, this.target);
  final String label, source, target;
}

enum AppInterface {
  music('Music'),
  video('Video');

  const AppInterface(this.label);
  final String label;
}

enum PlaybackRepeat { off, all, one }

enum AppNavigationStyle {
  expressive('Expressive pill'),
  classic('Classic pill'),
  fullWidth('Full width bar');

  const AppNavigationStyle(this.label);
  final String label;
}

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
