import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'video_web_streams.dart';

class VideoSource {
  const VideoSource.telegram(Track track)
    : telegram = track,
      uri = null,
      name = null,
      webOptions = null;
  const VideoSource.file(this.uri, this.name, {this.webOptions})
    : telegram = null;

  final Track? telegram;
  final Uri? uri;
  final String? name;
  final VideoWebOptions? webOptions;

  String get title => telegram?.title ?? name ?? 'Video';
  Duration get duration => telegram?.duration ?? Duration.zero;
  String get id => telegram != null
      ? 'telegram:${telegram!.id}'
      : 'file:${sha256.convert(utf8.encode(uri.toString()))}';
}

class VideoBookmark {
  const VideoBookmark(this.position, this.name);
  final Duration position;
  final String name;
}

/// HLS manifests represent one stream. M3U lists represent a queue.
List<VideoSource> parseVideoPlaylist(String text, {Uri? base}) {
  final lines = const LineSplitter().convert(text);
  if (lines.any((line) => line.trimLeft().startsWith('#EXT-X-'))) {
    throw const FormatException('Open an HLS manifest as a video stream.');
  }
  final result = <VideoSource>[];
  final seen = <Uri>{};
  String? title;
  for (final raw in lines) {
    final line = raw.replaceFirst('\ufeff', '').trim();
    if (line.startsWith('#EXTINF:')) {
      final comma = line.indexOf(',');
      title = comma < 0 ? null : line.substring(comma + 1).trim();
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      var uri = Uri.tryParse(line);
      if (base?.scheme == 'file' &&
          (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(line) ||
              line.startsWith(r'\\'))) {
        uri = Uri.file(line, windows: true);
      } else if (uri?.hasScheme == false && base != null) {
        uri = base.resolveUri(uri!);
      }
      if (uri != null &&
          (uri.scheme == 'file' && base?.scheme == 'file' ||
              {'http', 'https'}.contains(uri.scheme) &&
                  uri.host.isNotEmpty &&
                  uri.userInfo.isEmpty) &&
          seen.add(uri)) {
        result.add(
          VideoSource.file(
            uri,
            title?.isNotEmpty == true
                ? title
                : uri.pathSegments.lastOrNull ?? uri.host,
          ),
        );
        if (result.length == 1000) break;
      }
      title = null;
    }
  }
  return result;
}

class VideoSkipSegment {
  const VideoSkipSegment(this.start, this.end, this.label);

  final Duration start, end;
  final String label;

  bool contains(Duration position) => position >= start && position < end;
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
  final folders = <String, String>{};
  String? lastLocalVideo;
  VideoWebOptions webOptions = const VideoWebOptions();
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

  void clearTelegram() {
    positions.removeWhere((id, _) => id.startsWith('telegram:'));
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
    final seek = json['seekSeconds'];
    if (seek is int) data.seekSeconds = math.max(1, math.min(60, seek));
    if (json['folders'] case final Map folders) {
      for (final entry in folders.entries.take(30)) {
        if (entry.key case final String uri when uri.length <= 4096) {
          if (entry.value case final String label when label.length <= 512) {
            data.folders[uri] = label;
          }
        }
      }
    }
    if (json['lastLocalVideo'] case final String id when id.length <= 100) {
      data.lastLocalVideo = id;
    }
    data
      ..gestures = json['gestures'] != false
      ..strictDoubleTap = json['strictDoubleTap'] == true
      ..swapSides = json['swapSides'] == true
      ..autoAdvance = json['autoAdvance'] != false
      ..background = json['background'] == true
      ..autoPip = json['autoPip'] == true
      ..volumeBoost = json['volumeBoost'] == true
      ..autoSkip = json['autoSkip'] == true
      ..webOptions = VideoWebOptions.fromJson(json['webOptions'])
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
      for (final entry in positions.entries.take(_limit)) {
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
    'folders': folders,
    'lastLocalVideo': lastLocalVideo,
    'webOptions': webOptions.toJson(),
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
