import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'models.dart';

class VideoSource {
  const VideoSource.telegram(Track track)
    : telegram = track,
      uri = null,
      name = null;
  const VideoSource.file(this.uri, this.name)
    : telegram = null;

  final Track? telegram;
  final Uri? uri;
  final String? name;

  String get title => telegram?.title ?? name ?? 'Video';
  Duration get duration => telegram?.duration ?? Duration.zero;
  bool get canPlay => telegram != null ||
      (uri != null && _isLocalVideoUri(uri!, title));
  String get id => telegram != null
      ? 'telegram:${telegram!.id}'
      : 'file:${sha256.convert(utf8.encode(uri.toString()))}';

  Map<String, Object?> toJson() => {
    'title': title,
    if (telegram case final Track track) ...{
      'message': track.id,
      'channel': track.source,
    },
    if (uri case final Uri uri) 'uri': uri.toString(),
  };

  static VideoSource? restore(Object? raw) {
    if (raw is! Map || raw['title'] is! String) return null;
    final title = raw['title'] as String;
    if (raw['message'] case final String id
        when RegExp(r'^-?\d+:\d+$').hasMatch(id)) {
      return VideoSource.telegram(
        Track(
          id: id, title: title, artist: '',
          source: raw['channel'] is String ? raw['channel'] as String : 'Telegram',
        ),
      );
    }
    if (raw['uri'] case final String value when value.length <= 8192) {
      final uri = Uri.tryParse(value);
      if (uri != null && _isLocalVideoUri(uri, title)) {
        return VideoSource.file(uri, title);
      }
    }
    return null;
  }

  static bool _isLocalVideoUri(Uri uri, String title) {
    final playlist = RegExp(r'\.m3u8?$', caseSensitive: false);
    if (uri.userInfo.isNotEmpty ||
        playlist.hasMatch(uri.path) ||
        playlist.hasMatch(title)) {
      return false;
    }
    return switch (uri.scheme) {
      'file' => uri.path.isNotEmpty && (uri.host.isEmpty || uri.host == 'localhost'),
      'content' => uri.host.isNotEmpty,
      _ => false,
    };
  }
}

class VideoHistoryEntry {
  const VideoHistoryEntry(this.source, this.playedAt);
  final VideoSource source;
  final DateTime playedAt;
}

class TelegramVideoActivity {
  static const key = 'videoActivity';
  static const recentLimit = 300;
  static const watchedLimit = 50000;
  static final _message = RegExp(r'^-?\d{1,19}:\d{1,19}$');

  static bool isMessage(Object? id) => id is String && _message.hasMatch(id);

  static bool isRecent(Object? value) =>
      value is Map &&
      value.length == 4 &&
      value['title'] is String &&
      (value['title'] as String).length <= 512 &&
      value['channel'] is String &&
      (value['channel'] as String).length <= 256 &&
      value['openedAt'] is int &&
      (value['openedAt'] as int) >= 0 &&
      (value['openedAt'] as int) <= 8640000000000000 &&
      value['position'] is int &&
      (value['position'] as int) >= 0 &&
      (value['position'] as int) <= 31536000000;

  static void validate(Object? value) {
    if (value is! Map || value.length != 2) {
      throw const FormatException('Invalid video activity.');
    }
    final recent = value['recent'];
    final watched = value['watched'];
    if (recent is! Map || recent.length > recentLimit ||
        recent.entries.any((entry) => !isMessage(entry.key) || !isRecent(entry.value)) ||
        watched is! List || watched.length > watchedLimit ||
        watched.any((id) => !isMessage(id)) ||
        watched.toSet().length != watched.length) {
      throw const FormatException('Invalid video activity.');
    }
  }
}

class VideoBookmark {
  const VideoBookmark(this.position, this.name);
  final Duration position;
  final String name;
}


class VideoSkipSegment {
  const VideoSkipSegment(this.start, this.end, this.label);

  final Duration start, end;
  final String label;

  bool contains(Duration position) => position >= start && position < end;
}

List<VideoSkipSegment> videoChapterSegments(
  List<VideoBookmark> chapters, Duration duration,
) {
  final names = RegExp(
    r'^(?:intro(?:duction)?|opening(?: credits)?|recap|previously on|outro|end(?:ing)? credits|credits|next episode preview)(?:$|[\s:–-])',
    caseSensitive: false,
  );
  return [
    for (var i = 0; i < chapters.length; i++)
      if (names.hasMatch(chapters[i].name.trim()) &&
          chapters[i].position >= Duration.zero &&
          chapters[i].position < duration &&
          (i + 1 < chapters.length ? chapters[i + 1].position : duration) >
              chapters[i].position)
        VideoSkipSegment(
          chapters[i].position,
          i + 1 < chapters.length && chapters[i + 1].position < duration
              ? chapters[i + 1].position : duration,
          chapters[i].name,
        ),
  ];
}

class VideoCommand {
  const VideoCommand(this.label, this.args);

  final String label;
  final List<String> args;

  static List<String> parse(String input) {
    final value = jsonDecode(input);
    if (value is! List ||
        value.isEmpty ||
        value.length > 32 ||
        value.any(
          (arg) =>
              arg is! String ||
              arg.length > 2048 ||
              arg.contains(String.fromCharCode(0)),
        )) {
      throw const FormatException('Enter a JSON array of command arguments.');
    }
    final args = value.cast<String>();
    if (args.first.trim().isEmpty ||
        const {
          'quit',
          'quit-watch-later',
          'loadfile',
          'loadlist',
          'stop',
        }.contains(args.first) ||
        args.first.startsWith('playlist-')) {
      throw const FormatException(
        'Use the player queue to open or close videos.',
      );
    }
    return args;
  }
}

enum VideoControl {
  decoder('Decoder'),
  audio('Audio tracks'),
  subtitles('Subtitles'),
  lock('Lock controls'),
  orientation('Orientation'),
  speed('Playback speed'),
  loop('A–B loop'),
  chapters('Chapters and bookmarks'),
  queue('Now playing queue'),
  zoom('Video size and zoom'),
  screenshot('Save video frame'),
  fullscreen('Fullscreen'),
  pip('Picture in picture'),
  skipBack('Seek backward'),
  skipForward('Seek forward'),
  stats('Playback information'),
  skipSegments('Skip segments'),
  customOne('Custom button 1'),
  customTwo('Custom button 2'),
  customThree('Custom button 3');

  const VideoControl(this.label);
  final String label;
}

enum VideoControlZone {
  topStart('Top left', [], []),
  topEnd(
    'Top right',
    [VideoControl.decoder, VideoControl.audio, VideoControl.subtitles],
    [VideoControl.decoder, VideoControl.audio, VideoControl.subtitles],
  ),
  bottomStart(
    'Bottom left',
    [VideoControl.lock, VideoControl.speed, VideoControl.chapters],
    [
      VideoControl.lock,
      VideoControl.orientation,
      VideoControl.speed,
      VideoControl.loop,
      VideoControl.chapters,
    ],
  ),
  bottomEnd(
    'Bottom right',
    [VideoControl.queue, VideoControl.zoom, VideoControl.fullscreen],
    [
      VideoControl.queue,
      VideoControl.zoom,
      VideoControl.screenshot,
      VideoControl.fullscreen,
    ],
  );

  const VideoControlZone(this.label, this.portrait, this.landscape);
  final String label;
  final List<VideoControl> portrait, landscape;
  int get limit => this == topStart || this == topEnd ? 3 : 5;
}

enum VideoControlAnimation {
  standard('Default'),
  elastic('Elastic bounce'),
  scale('Cinematic scale'),
  slide('Slide up'),
  fade('Minimal fade');

  const VideoControlAnimation(this.label);
  final String label;
}

enum VideoHdrProfile {
  off('Automatic / Off'),
  pq('BT.2100 PQ'),
  hlg('BT.2100 HLG'),
  gamut('BT.2020 gamut mapping'),
  linear('Linear HDR');

  const VideoHdrProfile(this.label);
  final String label;
}

class VideoPlaybackData {
  final playlists = <String, List<VideoSource>>{};
  final history = <String, VideoHistoryEntry>{};
  final _watched = <String>{};
  final subtitleStyle = <String, String>{};
  bool snapshotSubtitles = true;
  String ambientMode = 'off';
  final positions = <String, Duration>{};
  final bookmarks = <String, List<VideoBookmark>>{};
  final skipSegments = <String, List<VideoSkipSegment>>{};
  final orientations = <String, String>{};
  final commands = <VideoControl, VideoCommand>{};
  final _controlLayouts = <String, List<VideoControl>>{};
  VideoControlAnimation animation = VideoControlAnimation.standard;
  bool transparentControls = false;

  String _zoneKey(VideoControlZone zone, bool wide) =>
      '${wide ? 'landscape' : 'portrait'}:${zone.name}';

  List<VideoControl> controls(VideoControlZone zone, {required bool wide}) =>
      _controlLayouts[_zoneKey(zone, wide)] ??
      (wide ? zone.landscape : zone.portrait);

  void setControls(
    VideoControlZone zone, {
    required bool wide,
    List<VideoControl>? controls,
  }) {
    final key = _zoneKey(zone, wide);
    if (controls == null) {
      _controlLayouts.remove(key);
    } else {
      _controlLayouts[key] = controls.toSet().take(zone.limit).toList();
    }
  }

  int seekSeconds = 10;
  bool gestures = true, strictDoubleTap = false, swapSides = false;
  bool autoAdvance = true, background = false, autoPip = false;
  bool volumeBoost = false, autoplay = true;
  bool autoSkip = false;
  bool gpuNext = false;
  bool matchRefreshRate = false;
  VideoHdrProfile hdrProfile = VideoHdrProfile.off;
  String mpvConfig = '', inputConfig = '';

  static const _limit = 300;

  static bool isSubtitleStyle(String name, String value) {
    final range = switch (name) {
      'sub-scale' || 'secondary-sub-scale' => (.4, 2.5),
      'sub-pos' || 'secondary-sub-pos' => (0.0, 100.0),
      'sub-border-size' => (0.0, 10.0),
      'sub-shadow-offset' => (0.0, 8.0),
      _ => null,
    };
    if (range != null) {
      final number = double.tryParse(value);
      return number != null && number >= range.$1 && number <= range.$2;
    }
    return switch (name) {
      'sub-ass-override' => const {'yes', 'force'}.contains(value),
      'sub-bold' || 'sub-italic' => const {'yes', 'no'}.contains(value),
      _ => false,
    };
  }

  void recordVideo(VideoSource source, {DateTime? at}) {
    if (!source.canPlay) return;
    history.remove(source.id);
    history[source.id] = VideoHistoryEntry(source, at ?? DateTime.now());
    final sameKind = history.values
        .where((entry) => (entry.source.telegram != null) == (source.telegram != null));
    if (sameKind.length > _limit) history.remove(sameKind.first.source.id);
  }

  bool isWatched(VideoSource source) => _watched.contains(source.telegram?.id);

  void setWatched(VideoSource source, bool watched) {
    final message = source.telegram?.id;
    if (message == null || !TelegramVideoActivity.isMessage(message)) return;
    if (watched) {
      _watched.add(message);
      positions.remove(source.id);
    } else {
      _watched.remove(message);
    }
  }

  Map<String, dynamic> telegramActivity() => {
    'recent': {
      for (final entry in history.values)
        if (entry.source.telegram case final Track track
            when TelegramVideoActivity.isMessage(track.id))
          track.id: {
            'title': String.fromCharCodes(track.title.runes.take(256)),
            'channel': String.fromCharCodes(track.source.runes.take(128)),
            'openedAt': entry.playedAt.millisecondsSinceEpoch.clamp(0, 8640000000000000),
            'position': (positions[entry.source.id]?.inMilliseconds ?? 0).clamp(0, 31536000000),
          },
    },
    'watched': _watched.toList()..sort(),
  };

  void applyTelegramActivity(Object? value) {
    if (value is! Map || value['recent'] is! Map || value['watched'] is! List) return;
    final old = Map<String, VideoHistoryEntry>.of(history);
    history.removeWhere((_, entry) => entry.source.telegram != null);
    positions.removeWhere((id, _) => id.startsWith('telegram:') && old.containsKey(id));
    _watched
      ..clear()
      ..addAll((value['watched'] as List)
          .whereType<String>().where(TelegramVideoActivity.isMessage)
          .take(TelegramVideoActivity.watchedLimit));
    final entries = (value['recent'] as Map).entries
        .where((entry) => TelegramVideoActivity.isMessage(entry.key) &&
            TelegramVideoActivity.isRecent(entry.value))
        .take(TelegramVideoActivity.recentLimit)
        .toList()
      ..sort((a, b) => ((a.value as Map)['openedAt'] as int)
          .compareTo((b.value as Map)['openedAt'] as int));
    for (final entry in entries) {
      final id = entry.key as String;
      final record = entry.value as Map;
      final saved = old['telegram:$id']?.source;
      final source = saved != null &&
              String.fromCharCodes(saved.title.runes.take(256)) == record['title'] &&
              String.fromCharCodes(saved.telegram!.source.runes.take(128)) == record['channel']
          ? saved
          : VideoSource.telegram(Track(
              id: id, title: record['title'] as String, artist: '',
              source: record['channel'] as String,
            ));
      recordVideo(source, at: DateTime.fromMillisecondsSinceEpoch(record['openedAt'] as int, isUtc: true));
      final ms = record['position'] as int;
      if (ms > 0 && !isWatched(source)) {
        positions[source.id] = Duration(milliseconds: ms);
      } else {
        positions.remove(source.id);
      }
    }
  }

  void removeHistory(String id) {
    history.remove(id);
    positions.remove(id);
  }

  void clearHistory() {
    history.clear();
    positions.clear();
  }

  void putPlaylist(String name, Iterable<VideoSource> items) {
    name = name.trim();
    if (name.isEmpty || name.length > 80 ||
        (playlists.length >= 100 && !playlists.containsKey(name))) {
      throw const FormatException('Use a name of 1–80 characters and up to 100 playlists.');
    }
    final entries = <String, VideoSource>{};
    for (final item in items) {
      if (!item.canPlay) continue;
      entries.putIfAbsent(item.id, () => item);
      if (entries.length == 1000) break;
    }
    playlists[name] = entries.values.toList();
  }

  void remember(String id, Duration position, Duration duration) {
    positions.remove(id);
    if (position >= const Duration(seconds: 3) &&
        (duration == Duration.zero ||
            duration - position >= const Duration(seconds: 3))) {
      positions[id] = position;
      if (positions.length > _limit) positions.remove(positions.keys.first);
    }
  }

  void setOrientation(String id, String value) {
    orientations.remove(id);
    if (value == 'free') return;
    orientations[id] = value;
    if (orientations.length > _limit) {
      orientations.remove(orientations.keys.first);
    }
  }

  void clearTelegram({bool keepActivity = false}) {
    if (keepActivity) {
      // TDLib file IDs and previews belong to the old Telegram session.
      history.updateAll((_, entry) {
        final track = entry.source.telegram;
        if (track == null) return entry;
        return VideoHistoryEntry(
          VideoSource.telegram(Track(
            id: track.id, title: track.title, artist: '', source: track.source,
          )),
          entry.playedAt,
        );
      });
    } else {
      _watched.clear();
      history.removeWhere((_, entry) => entry.source.telegram != null);
      positions.removeWhere((id, _) => id.startsWith('telegram:'));
    }
    for (final list in playlists.values) {
      list.removeWhere((source) => source.telegram != null);
    }
    bookmarks.removeWhere((id, _) => id.startsWith('telegram:'));
    skipSegments.removeWhere((id, _) => id.startsWith('telegram:'));
    orientations.removeWhere((id, _) => id.startsWith('telegram:'));
  }

  void setSkipSegments(String id, List<VideoSkipSegment> segments) {
    skipSegments.remove(id);
    if (segments.isEmpty) return;
    skipSegments[id] =
        (segments.toList()..sort((a, b) => a.start.compareTo(b.start)))
            .take(30)
            .toList();
    if (skipSegments.length > _limit) {
      skipSegments.remove(skipSegments.keys.first);
    }
  }

  void setBookmarks(String id, List<VideoBookmark> points) {
    bookmarks.remove(id);
    if (points.isEmpty) return;
    bookmarks[id] =
        (points.toList()..sort((a, b) => a.position.compareTo(b.position)))
            .take(100)
            .toList();
    if (bookmarks.length > _limit) bookmarks.remove(bookmarks.keys.first);
  }

  static Duration? _duration(Object? value) =>
      value is int &&
          value >= 0 &&
          value <= const Duration(days: 365).inMilliseconds
      ? Duration(milliseconds: value)
      : null;

  factory VideoPlaybackData.fromJson(Object? json) {
    final data = VideoPlaybackData();
    if (json is! Map) return data;
    if (json['watched'] case final List watched) {
      data._watched.addAll(watched.whereType<String>()
          .where(TelegramVideoActivity.isMessage).take(TelegramVideoActivity.watchedLimit));
    }
    data.snapshotSubtitles = json['snapshotSubtitles'] != false;
    if (json['ambientMode'] case final String mode when mode.length <= 32) {
      data.ambientMode = mode;
    }
    if (json['subtitleStyle'] case final Map style) {
      for (final entry in style.entries.take(16)) {
        if (entry.key is String && entry.value is String &&
            isSubtitleStyle(entry.key as String, entry.value as String)) {
          data.subtitleStyle[entry.key as String] = entry.value as String;
        }
      }
    }
    if (json['playlists'] case final Map lists) {
      for (final entry in lists.entries.take(100)) {
        if (entry.key case final String name
            when name.trim().isNotEmpty && name.length <= 80) {
          if (entry.value case final List items) {
            data.putPlaylist(name, items.take(1000).map(VideoSource.restore)
                .whereType<VideoSource>());
          }
        }
      }
    }
    if (json['history'] case final List entries) {
      for (final entry in entries.whereType<Map>().take(_limit * 2)) {
        final source = VideoSource.restore(entry['source']);
        final at = entry['at'];
        if (source != null && at is String) {
          final date = DateTime.tryParse(at);
          if (date != null) data.recordVideo(source, at: date);
        }
      }
    }
    final seek = json['seekSeconds'];
    if (seek is int) data.seekSeconds = math.max(1, math.min(60, seek));
    data
      ..gestures = json['gestures'] != false
      ..strictDoubleTap = json['strictDoubleTap'] == true
      ..swapSides = json['swapSides'] == true
      ..autoAdvance = json['autoAdvance'] != false
      ..background = json['background'] == true
      ..autoPip = json['autoPip'] == true
      ..volumeBoost = json['volumeBoost'] == true
      ..autoSkip = json['autoSkip'] == true
      ..gpuNext = json['gpuNext'] == true
      ..matchRefreshRate = json['matchRefreshRate'] == true
      ..hdrProfile = VideoHdrProfile.values.firstWhere(
        (profile) => profile.name == json['hdrProfile'],
        orElse: () => VideoHdrProfile.off,
      )
      ..mpvConfig = _configText(json['mpvConfig'])
      ..inputConfig = _configText(json['inputConfig'])
      ..autoplay = json['autoplay'] != false
      ..transparentControls = json['transparentControls'] == true
      ..animation = VideoControlAnimation.values.firstWhere(
        (style) => style.name == json['animation'],
        orElse: () => VideoControlAnimation.standard,
      );
    if (json['controlLayouts'] case final Map layouts) {
      for (final wide in [false, true]) {
        for (final zone in VideoControlZone.values) {
          final raw = layouts[data._zoneKey(zone, wide)];
          if (raw is! List) continue;
          final controls = <VideoControl>[
            for (final item in raw.take(20))
              if (VideoControl.values
                      .where((control) => control.name == item)
                      .firstOrNull
                  case final VideoControl control)
                control,
          ];
          data.setControls(zone, wide: wide, controls: controls);
        }
      }
    }
    if (json['positions'] case final Map positions) {
      for (final entry in positions.entries.take(_limit * 2)) {
        if (entry.key is! String) continue;
        if (_duration(entry.value) case final Duration value) {
          data.positions[entry.key as String] = value;
        }
      }
    }
    if (json['bookmarks'] case final Map groups) {
      for (final entry in groups.entries.take(_limit)) {
        if (entry.key is! String || entry.value is! List) continue;
        data.setBookmarks(entry.key as String, [
          for (final point in (entry.value as List).whereType<Map>().take(100))
            if (point['name'] case final String name)
              if (_duration(point['position']) case final Duration position)
                VideoBookmark(position, name),
        ]);
      }
    }
    if (json['orientations'] case final Map orientations) {
      for (final entry in orientations.entries.take(_limit)) {
        if (entry.key is String && entry.value is String) {
          data.orientations[entry.key as String] = entry.value as String;
        }
      }
    }
    if (json['skipSegments'] case final Map groups) {
      for (final entry in groups.entries.take(_limit)) {
        if (entry.key is! String || entry.value is! List) continue;
        data.setSkipSegments(entry.key as String, [
          for (final segment in (entry.value as List).whereType<Map>().take(30))
            if (segment['label'] case final String label)
              if (_duration(segment['start']) case final Duration start)
                if (_duration(segment['end']) case final Duration end
                    when end > start)
                  VideoSkipSegment(start, end, label),
        ]);
      }
    }
    if (json['commands'] case final Map commands) {
      for (final slot in const [
        VideoControl.customOne,
        VideoControl.customTwo,
        VideoControl.customThree,
      ]) {
        final raw = commands[slot.name];
        if (raw is! Map || raw['label'] is! String) continue;
        try {
          data.commands[slot] = VideoCommand(
            raw['label'] as String,
            VideoCommand.parse(jsonEncode(raw['args'])),
          );
        } on FormatException {
          // Ignore corrupt or unavailable commands.
        }
      }
    }
    return data;
  }

  VideoPlaybackData();

  static String _configText(Object? value) =>
      value is String && value.length <= 32768 ? value : '';

  Map<String, dynamic> toJson() => {
    'watched': _watched.toList(),
    'ambientMode': ambientMode,
    'snapshotSubtitles': snapshotSubtitles,
    'subtitleStyle': subtitleStyle,
    'playlists': {
      for (final entry in playlists.entries)
        entry.key: [for (final item in entry.value) item.toJson()],
    },
    'history': [
      for (final entry in history.values)
        {'source': entry.source.toJson(), 'at': entry.playedAt.toIso8601String()},
    ],
    'seekSeconds': seekSeconds,
    'gestures': gestures,
    'strictDoubleTap': strictDoubleTap,
    'swapSides': swapSides,
    'autoAdvance': autoAdvance,
    'background': background,
    'autoPip': autoPip,
    'volumeBoost': volumeBoost,
    'autoSkip': autoSkip,
    'gpuNext': gpuNext,
    'matchRefreshRate': matchRefreshRate,
    'hdrProfile': hdrProfile.name,
    'mpvConfig': mpvConfig,
    'inputConfig': inputConfig,
    'autoplay': autoplay,
    'transparentControls': transparentControls,
    'animation': animation.name,
    'controlLayouts': {
      for (final entry in _controlLayouts.entries)
        entry.key: entry.value.map((control) => control.name).toList(),
    },
    'positions': {
      for (final entry in positions.entries)
        entry.key: entry.value.inMilliseconds,
    },
    'bookmarks': {
      for (final entry in bookmarks.entries)
        entry.key: [
          for (final point in entry.value)
            {'position': point.position.inMilliseconds, 'name': point.name},
        ],
    },
    'orientations': orientations,
    'skipSegments': {
      for (final entry in skipSegments.entries)
        entry.key: [
          for (final segment in entry.value)
            {
              'start': segment.start.inMilliseconds,
              'end': segment.end.inMilliseconds,
              'label': segment.label,
            },
        ],
    },
    'commands': {
      for (final entry in commands.entries)
        entry.key.name: {'label': entry.value.label, 'args': entry.value.args},
    },
  };
}
