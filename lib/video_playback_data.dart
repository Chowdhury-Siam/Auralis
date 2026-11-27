import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'video_gesture_options.dart';

export 'video_gesture_options.dart';

class VideoSource {
  const VideoSource.telegram(Track track)
    : telegram = track,
      uri = null,
      name = null,
      runtime = Duration.zero;
  const VideoSource.file(this.uri, this.name, {this.runtime = Duration.zero})
    : telegram = null;

  final Track? telegram;
  final Uri? uri;
  final String? name;
  final Duration runtime;

  String get title => telegram?.title ?? name ?? 'Video';
  Duration get duration => telegram?.duration ?? runtime;
  bool get canPlay =>
      telegram != null || (uri != null && _isLocalVideoUri(uri!, title));
  String get id => telegram != null
      ? 'telegram:${telegram!.id}'
      : 'file:${sha256.convert(utf8.encode(uri.toString()))}';

  String? get channelId {
    final message = telegram?.id;
    return message != null && TelegramVideoActivity.isMessage(message)
        ? message.split(':').first
        : null;
  }

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
          id: id,
          title: title,
          artist: '',
          source: raw['channel'] is String
              ? raw['channel'] as String
              : 'Telegram',
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
      'file' =>
        uri.path.isNotEmpty && (uri.host.isEmpty || uri.host == 'localhost'),
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

class VideoWatchingStats {
  static const key = 'videoWatching';
  static const sources = ['telegram', 'local'];
  static const maxCounter = 1 << 42;
  static final _id = RegExp(r'^[a-f0-9]{32}$');

  static bool isId(Object? value) => value is String && _id.hasMatch(value);

  static bool isCounter(Object? value) {
    bool valid(Object? n) => n is int && n >= 0 && n <= maxCounter;
    return value is Map &&
        value.length == 3 &&
        sources.contains(value['source']) &&
        valid(value['milliseconds']) &&
        valid(value['plays']);
  }

  static String newId() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
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
    if (recent is! Map ||
        recent.length > recentLimit ||
        recent.entries.any(
          (entry) => !isMessage(entry.key) || !isRecent(entry.value),
        ) ||
        watched is! List ||
        watched.length > watchedLimit ||
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

  String get buttonLabel {
    final name = videoSkipChapterLabel(label) ?? label.trim();
    return 'Skip ${name.isEmpty ? 'segment' : name}';
  }
}

/// Recognize named sections, never guess timings from a file name or length.
/// Word boundaries keep OP/ED from matching Operation, Education, etc.
String? videoSkipChapterLabel(String name) {
  var title = name.trim();
  title = title.replaceFirst(
    RegExp(r'^(?:chapter\s+)?\d{1,3}\s*[.:\-–—]\s*', caseSensitive: false),
    '',
  );
  title = title.replaceFirst(RegExp(r'^[\[(]\s*'), '');
  const boundary = r'(?:$|[\s:;.,_/\-–—()\[\]])';
  bool starts(String pattern) =>
      RegExp('^(?:$pattern)$boundary', caseSensitive: false).hasMatch(title);
  if (starts(r'(?:nc)?op(?:\s*#?\d{1,2})?|opening|オープニング')) {
    return 'Opening';
  }
  if (starts(r'(?:nc)?ed(?:\s*#?\d{1,2})?|ending|end|エンディング')) {
    return 'Ending';
  }
  if (starts(r'intro(?:duction)?')) return 'Intro';
  if (starts(r'outro|outtro') ||
      RegExp(
        r'^outer(?:$|[\]\):\-–—]|\s+credits?\b)',
        caseSensitive: false,
      ).hasMatch(title)) {
    return 'Outro';
  }
  if (starts(r'recap|previously\s+on')) return 'Recap';
  if (starts(r'credits?')) return 'Credits';
  if (starts(r'(?:next\s+episode\s+)?preview')) return 'Preview';
  return null;
}

List<VideoSkipSegment> videoChapterSegments(
  List<VideoBookmark> chapters,
  Duration duration,
) {
  if (duration <= Duration.zero) return const [];
  final byTime = <Duration, List<VideoBookmark>>{};
  for (final chapter in chapters) {
    if (chapter.position >= Duration.zero && chapter.position <= duration) {
      byTime.putIfAbsent(chapter.position, () => []).add(chapter);
    }
  }
  final times = byTime.keys.toList()..sort();
  return [
    for (var i = 0; i < times.length; i++)
      // Conflicting names at the same timestamp are not reliable skip metadata.
      if (times[i] < duration &&
          videoSkipChapterLabel(byTime[times[i]]!.first.name) != null &&
          byTime[times[i]]!.every(
            (chapter) =>
                videoSkipChapterLabel(chapter.name) ==
                videoSkipChapterLabel(byTime[times[i]]!.first.name),
          ))
        VideoSkipSegment(
          times[i],
          i + 1 < times.length ? times[i + 1] : duration,
          byTime[times[i]]!.first.name.trim(),
        ),
  ];
}

/// Saved/manual/AniSkip ranges take precedence over derived chapter ranges.
/// Return the existing object so hidden HUDs only rebuild on segment changes.
VideoSkipSegment? videoActiveSkipSegment(
  List<VideoSkipSegment> saved,
  List<VideoSkipSegment> chapters,
  Duration position,
  Duration duration,
) {
  if (duration <= Duration.zero || position < Duration.zero) return null;
  bool valid(VideoSkipSegment segment) =>
      segment.start >= Duration.zero &&
      segment.end > segment.start &&
      segment.end <= duration;
  for (final source in [saved, chapters]) {
    for (final segment in source.reversed) {
      if (valid(segment) &&
          segment.contains(position) &&
          (identical(source, saved) ||
              !saved.any(
                (override) =>
                    valid(override) &&
                    override.start < segment.end &&
                    segment.start < override.end,
              ))) {
        return segment;
      }
    }
  }
  return null;
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
    [
      VideoControl.lock,
      VideoControl.orientation,
      VideoControl.speed,
      VideoControl.chapters,
    ],
    [
      VideoControl.lock,
      VideoControl.orientation,
      VideoControl.speed,
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

class VideoTrackChoice {
  const VideoTrackChoice(this.id, this.title, this.language);

  final String id;
  final String? title, language;

  static VideoTrackChoice? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    final id = json['id'] as String;
    if (id != 'no' && int.tryParse(id) == null) return null;
    String? label(Object? value) =>
        value is String && value.length <= 512 ? value : null;
    return VideoTrackChoice(id, label(json['title']), label(json['language']));
  }

  Map<String, Object?> toJson() => {
    'id': id,
    if (title != null) 'title': title,
    if (language != null) 'language': language,
  };
}

class VideoChannelSettings {
  VideoTrackChoice? audio, subtitles;
  double? volume, brightness, pictureBrightness;

  static VideoChannelSettings? fromJson(Object? json) {
    if (json is! Map) return null;
    double? level(Object? value, num min, num max) =>
        value is num && value.isFinite && value >= min && value <= max
        ? value.toDouble()
        : null;
    return VideoChannelSettings()
      ..audio = VideoTrackChoice.fromJson(json['audio'])
      ..subtitles = VideoTrackChoice.fromJson(json['subtitles'])
      ..volume = level(json['volume'], 0, 130)
      ..brightness = level(json['brightness'], .01, 1)
      ..pictureBrightness = level(json['pictureBrightness'], -100, 100);
  }

  Map<String, Object?> toJson() => {
    if (audio != null) 'audio': audio!.toJson(),
    if (subtitles != null) 'subtitles': subtitles!.toJson(),
    if (volume != null) 'volume': volume,
    if (brightness != null) 'brightness': brightness,
    if (pictureBrightness != null) 'pictureBrightness': pictureBrightness,
  };
}

class VideoPlaybackData {
  LibrarySort librarySort = LibrarySort.title;
  final history = <String, VideoHistoryEntry>{};
  final _watched = <String>{};
  final _watchedFiles = <String>{};
  final _watchingOrigins = <String, String>{};
  final _watching = <String, Map<String, dynamic>>{};
  static final _localVideoId = RegExp(r'^file:[a-f0-9]{64}$');
  final channels = <String, VideoChannelSettings>{};
  final subtitleStyle = <String, String>{};
  bool snapshotSubtitles = true;
  String ambientMode = 'off';
  final positions = <String, Duration>{};
  final _runtimes = <String, (int, Duration)>{};
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
  bool gestures = true, strictDoubleTap = false;
  VideoGestureOptions gestureOptions = VideoGestureOptions();
  bool autoAdvance = true, background = false, autoPip = false;
  bool volumeBoost = false, autoplay = true;
  bool audioPitchCorrection = true;
  double defaultVideoSpeed = 1;
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
    final sameKind = history.values.where(
      (entry) => (entry.source.telegram != null) == (source.telegram != null),
    );
    if (sameKind.length > _limit) history.remove(sameKind.first.source.id);
  }

  int _watchingTotal(String field, {String? source}) => _watching.values
      .where((value) => source == null || value['source'] == source)
      .fold<int>(
        0,
        (total, value) => math.min(1 << 52, total + (value[field] as int)),
      );
  Duration get watchTime =>
      Duration(milliseconds: _watchingTotal('milliseconds'));
  int get videoPlays => _watchingTotal('plays');
  int get watchedCount => _watched.length + _watchedFiles.length;

  ({int milliseconds, int plays}) watchingTotals({required bool telegram}) {
    final source = telegram ? 'telegram' : 'local';
    return (
      milliseconds: _watchingTotal('milliseconds', source: source),
      plays: _watchingTotal('plays', source: source),
    );
  }

  void recordWatching(
    VideoSource source,
    Duration time, {
    required bool newPlay,
  }) {
    _addWatching(
      source.telegram != null ? 'telegram' : 'local',
      time.inMilliseconds,
      newPlay ? 1 : 0,
    );
  }

  void _addWatching(String source, int milliseconds, int plays) {
    if (milliseconds <= 0 && plays <= 0) return;
    final id = _watchingOrigins.putIfAbsent(source, VideoWatchingStats.newId);
    final previous = _watching[id];
    _watching[id] = {
      'source': source,
      'milliseconds': math.min(
        VideoWatchingStats.maxCounter,
        (previous?['milliseconds'] as int? ?? 0) + milliseconds,
      ),
      'plays': math.min(
        VideoWatchingStats.maxCounter,
        (previous?['plays'] as int? ?? 0) + plays,
      ),
    };
  }

  Map<String, dynamic> watchingStats() => {
    for (final entry in _watching.entries) entry.key: {...entry.value},
  };

  void applyWatchingStats(Object? value) {
    if (value is! Map) return;
    _watching.clear();
    for (final entry in value.entries) {
      if (VideoWatchingStats.isId(entry.key) &&
          VideoWatchingStats.isCounter(entry.value)) {
        _watching[entry.key as String] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }
  }

  bool isWatched(VideoSource source) => source.telegram == null
      ? _watchedFiles.contains(source.id)
      : _watched.contains(source.telegram!.id);

  bool setWatched(VideoSource source, bool watched) {
    if (source.telegram case final Track track) {
      if (!TelegramVideoActivity.isMessage(track.id)) return false;
      return watched ? _watched.add(track.id) : _watched.remove(track.id);
    }
    if (!source.canPlay) return false;
    final id = source.id;
    if (!watched) return _watchedFiles.remove(id);
    final added = _watchedFiles.add(id);
    if (_watchedFiles.length > _limit) {
      _watchedFiles.remove(_watchedFiles.first);
    }
    return added;
  }

  Map<String, dynamic> telegramActivity() => {
    'recent': {
      for (final entry in history.values)
        if (entry.source.telegram case final Track track
            when TelegramVideoActivity.isMessage(track.id))
          track.id: {
            'title': String.fromCharCodes(track.title.runes.take(256)),
            'channel': String.fromCharCodes(track.source.runes.take(128)),
            'openedAt': entry.playedAt.millisecondsSinceEpoch.clamp(
              0,
              8640000000000000,
            ),
            'position': (positions[entry.source.id]?.inMilliseconds ?? 0).clamp(
              0,
              31536000000,
            ),
          },
    },
    'watched': _watched.toList()..sort(),
  };

  void applyTelegramActivity(Object? value) {
    if (value is! Map || value['recent'] is! Map || value['watched'] is! List) {
      return;
    }
    final old = Map<String, VideoHistoryEntry>.of(history);
    history.removeWhere((_, entry) => entry.source.telegram != null);
    positions.removeWhere(
      (id, _) => id.startsWith('telegram:') && old.containsKey(id),
    );
    _watched
      ..clear()
      ..addAll(
        (value['watched'] as List)
            .whereType<String>()
            .where(TelegramVideoActivity.isMessage)
            .take(TelegramVideoActivity.watchedLimit),
      );
    final entries =
        (value['recent'] as Map).entries
            .where(
              (entry) =>
                  TelegramVideoActivity.isMessage(entry.key) &&
                  TelegramVideoActivity.isRecent(entry.value),
            )
            .take(TelegramVideoActivity.recentLimit)
            .toList()
          ..sort(
            (a, b) => ((a.value as Map)['openedAt'] as int).compareTo(
              (b.value as Map)['openedAt'] as int,
            ),
          );
    for (final entry in entries) {
      final id = entry.key as String;
      final record = entry.value as Map;
      final saved = old['telegram:$id']?.source;
      final source =
          saved != null &&
              String.fromCharCodes(saved.title.runes.take(256)) ==
                  record['title'] &&
              String.fromCharCodes(saved.telegram!.source.runes.take(128)) ==
                  record['channel']
          ? saved
          : VideoSource.telegram(
              Track(
                id: id,
                title: record['title'] as String,
                artist: '',
                source: record['channel'] as String,
              ),
            );
      recordVideo(
        source,
        at: DateTime.fromMillisecondsSinceEpoch(
          record['openedAt'] as int,
          isUtc: true,
        ),
      );
      final ms = record['position'] as int;
      if (ms > 0) {
        _storePosition(source.id, Duration(milliseconds: ms));
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

  Duration durationOf(VideoSource source) {
    final saved = _runtimes[source.id];
    final size = source.telegram?.size ?? 0;
    if (saved != null && (size == 0 || saved.$1 == 0 || size == saved.$1)) {
      return saved.$2;
    }
    return source.duration;
  }

  bool rememberDuration(VideoSource source, Duration duration) {
    if (duration <= Duration.zero || duration > const Duration(days: 365)) {
      return false;
    }
    final id = source.id;
    final entry = (source.telegram?.size ?? 0, duration);
    if (_runtimes[id] == entry) return false;
    _runtimes.remove(id);
    _runtimes[id] = entry;
    if (_runtimes.length > 4096) _runtimes.remove(_runtimes.keys.first);
    return true;
  }

  void remember(String id, Duration position, Duration duration) {
    positions.remove(id);
    if (position > Duration.zero) {
      _storePosition(
        id,
        duration > Duration.zero && position > duration ? duration : position,
      );
    }
  }

  void _storePosition(String id, Duration position) {
    positions[id] = position;
    if (positions.length <= _limit) return;
    // History has separate limits for local files and Telegram videos.
    final telegram = id.startsWith('telegram:');
    final sameKind = positions.keys.where(
      (key) => key.startsWith('telegram:') == telegram,
    );
    if (sameKind.length > _limit) positions.remove(sameKind.first);
  }

  void setOrientation(String id, String value) {
    orientations.remove(id);
    if (value == 'video') return;
    orientations[id] = value;
    if (orientations.length > _limit) {
      orientations.remove(orientations.keys.first);
    }
  }

  void clearTelegram({bool keepActivity = false}) {
    channels.clear();
    if (keepActivity) {
      // TDLib file IDs and previews belong to the old Telegram session.
      history.updateAll((_, entry) {
        final track = entry.source.telegram;
        if (track == null) return entry;
        return VideoHistoryEntry(
          VideoSource.telegram(
            Track(
              id: track.id,
              title: track.title,
              artist: '',
              source: track.source,
            ),
          ),
          entry.playedAt,
        );
      });
    } else {
      _watching.removeWhere((_, counter) => counter['source'] == 'telegram');
      _watchingOrigins.remove('telegram');
      _watched.clear();
      history.removeWhere((_, entry) => entry.source.telegram != null);
      positions.removeWhere((id, _) => id.startsWith('telegram:'));
      _runtimes.removeWhere((id, _) => id.startsWith('telegram:'));
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
    if (json['watchingOrigins'] case final Map origins) {
      for (final source in VideoWatchingStats.sources) {
        if (VideoWatchingStats.isId(origins[source])) {
          data._watchingOrigins[source] = origins[source] as String;
        }
      }
    }
    if (json[VideoWatchingStats.key] case final Map watching) {
      data.applyWatchingStats(watching);
    } else if (json['watching'] case final Map legacy) {
      for (final source in VideoWatchingStats.sources) {
        final raw = legacy[source];
        if (raw is List && raw.length == 2) {
          final counter = {
            'source': source,
            'milliseconds': raw[0],
            'plays': raw[1],
          };
          if (VideoWatchingStats.isCounter(counter)) {
            data._addWatching(source, raw[0] as int, raw[1] as int);
          }
        }
      }
    }
    if (json['channelSettings'] case final Map channels) {
      for (final entry in channels.entries) {
        if (entry.key case final String id
            when TelegramVideoActivity.isMessage('$id:0')) {
          if (VideoChannelSettings.fromJson(entry.value) case final settings?) {
            data.channels[id] = settings;
          }
        }
      }
    }
    data.librarySort = LibrarySort.videoValues.firstWhere(
      (sort) => sort.name == json['librarySort'],
      orElse: () => data.librarySort,
    );
    if (json['watched'] case final List watched) {
      data._watched.addAll(
        watched
            .whereType<String>()
            .where(TelegramVideoActivity.isMessage)
            .take(TelegramVideoActivity.watchedLimit),
      );
    }
    if (json['watchedFiles'] case final List watched) {
      data._watchedFiles.addAll(
        watched.whereType<String>().where(_localVideoId.hasMatch).take(_limit),
      );
    }
    data.snapshotSubtitles = json['snapshotSubtitles'] != false;
    if (json['ambientMode'] case final String mode when mode.length <= 32) {
      data.ambientMode = mode;
    }
    if (json['subtitleStyle'] case final Map style) {
      for (final entry in style.entries.take(16)) {
        if (entry.key is String &&
            entry.value is String &&
            isSubtitleStyle(entry.key as String, entry.value as String)) {
          data.subtitleStyle[entry.key as String] = entry.value as String;
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
    data.gestureOptions = VideoGestureOptions.fromJson(json['gestureOptions']);
    if (seek is int) data.seekSeconds = math.max(1, math.min(60, seek));
    final speed = json['defaultVideoSpeed'];
    if (speed is num && speed.isFinite && speed >= .25 && speed <= 4) {
      data.defaultVideoSpeed = speed.toDouble();
    }
    data
      ..audioPitchCorrection = json['audioPitchCorrection'] != false
      ..gestures = json['gestures'] != false
      ..strictDoubleTap = json['strictDoubleTap'] == true
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
    if (json['videoDurations'] case final Map runtimes) {
      for (final entry in runtimes.entries.take(4096)) {
        final id = entry.key;
        final value = entry.value;
        if (id is! String ||
            !(_localVideoId.hasMatch(id) ||
                id.startsWith('telegram:') &&
                    TelegramVideoActivity.isMessage(id.substring(9))) ||
            value is! List ||
            value.length != 2 ||
            value[0] is! int ||
            (value[0] as int) < 0) {
          continue;
        }
        if (_duration(value[1]) case final duration?
            when duration > Duration.zero) {
          data._runtimes[id] = (value[0] as int, duration);
        }
      }
    }
    if (json['positions'] case final Map positions) {
      for (final entry in positions.entries.take(_limit * 2)) {
        if (entry.key is! String) continue;
        if (_duration(entry.value) case final Duration value) {
          data._storePosition(entry.key as String, value);
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
    'librarySort': librarySort.name,
    'channelSettings': {
      for (final entry in channels.entries) entry.key: entry.value.toJson(),
    },
    'watched': _watched.toList(),
    'watchedFiles': _watchedFiles.toList(),
    VideoWatchingStats.key: watchingStats(),
    'watchingOrigins': {..._watchingOrigins},
    'ambientMode': ambientMode,
    'snapshotSubtitles': snapshotSubtitles,
    'subtitleStyle': subtitleStyle,
    'history': [
      for (final entry in history.values)
        {
          'source': entry.source.toJson(),
          'at': entry.playedAt.toIso8601String(),
        },
    ],
    'seekSeconds': seekSeconds,
    'gestures': gestures,
    'gestureOptions': gestureOptions.toJson(),
    'strictDoubleTap': strictDoubleTap,
    'autoAdvance': autoAdvance,
    'background': background,
    'autoPip': autoPip,
    'volumeBoost': volumeBoost,
    'defaultVideoSpeed': defaultVideoSpeed,
    'audioPitchCorrection': audioPitchCorrection,
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
    'videoDurations': {
      for (final entry in _runtimes.entries)
        entry.key: [entry.value.$1, entry.value.$2.inMilliseconds],
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
