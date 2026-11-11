import 'dart:async';
import 'dart:convert';
import 'dart:io';

class VideoWebOptions {
  const VideoWebOptions({
    this.height = 1080,
    this.fps = 60,
    this.codec = '',
    this.container = '',
    this.audioKbps = 0,
    this.hdr = false,
  });

  static const heights = [0, 480, 720, 1080, 1440, 2160];
  static const frameRates = [0, 30, 60];
  static const codecs = ['', 'avc1', 'vp9', 'av01', 'hev1'];
  static const containers = ['', 'mp4', 'webm'];
  static const audioRates = [0, 96, 128, 192, 256, 320];

  final int height, fps, audioKbps;
  final String codec, container;
  final bool hdr;

  String get selector {
    final limits = [
      if (height > 0) '[height<=?$height]',
      if (fps > 0) '[fps<=?$fps]',
    ].join();
    final preferred = [
      if (codec.isNotEmpty) '[vcodec^=$codec]',
      if (container.isNotEmpty) '[ext=$container]',
      if (hdr) '[dynamic_range!=SDR]',
    ].join();
    final audio = audioKbps == 0 ? 'bestaudio' : 'bestaudio[abr<=?$audioKbps]';
    final fallback = 'bestvideo*$limits+$audio/best$limits/bestvideo$limits';
    return preferred.isEmpty
        ? fallback
        : 'bestvideo*$limits$preferred+$audio/best$limits$preferred/'
              'bestvideo$limits$preferred/$fallback';
  }

  factory VideoWebOptions.fromJson(Object? json) {
    final values = json is Map ? json : const {};
    T option<T>(String name, List<T> accepted, T fallback) {
      final value = values[name];
      return accepted.contains(value) ? value as T : fallback;
    }

    return VideoWebOptions(
      height: option('height', heights, 1080),
      fps: option('fps', frameRates, 60),
      codec: option('codec', codecs, ''),
      container: option('container', containers, ''),
      audioKbps: option('audioKbps', audioRates, 0),
      hdr: values['hdr'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'height': height,
    'fps': fps,
    'codec': codec,
    'container': container,
    'audioKbps': audioKbps,
    'hdr': hdr,
  };
}

bool isVideoWebsite(Uri? address) {
  if (address == null) return false;
  final host = address.host.toLowerCase();
  return const {
    'youtube.com',
    'youtu.be',
    'twitch.tv',
    'bilibili.com',
    'b23.tv',
    'vimeo.com',
    'dailymotion.com',
    'dai.ly',
    'nicovideo.jp',
  }.any((site) => host == site || host.endsWith('.$site'));
}

class VideoWebMedia {
  const VideoWebMedia(this.resource, this.title, this.headers);

  final String resource, title;
  final Map<String, String> headers;

  static VideoWebMedia parse(String data) {
    final payload = jsonDecode(data);
    if (payload is! Map) {
      throw const FormatException('No web video was returned.');
    }
    final formats = payload['requested_formats'];
    final selected = formats is List && formats.isNotEmpty
        ? formats
        : [payload];
    if (selected.length > 2) {
      throw const FormatException('This web video returned too many tracks.');
    }

    final tracks = <(String, Map<String, String>)>[];
    for (final format in selected) {
      if (format is! Map || format['url'] is! String) {
        throw const FormatException(
          'The website did not return a playable stream.',
        );
      }
      final raw = format['url'] as String;
      final url = Uri.tryParse(raw);
      if (url == null ||
          !const {'http', 'https'}.contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          raw.length > 32768) {
        throw const FormatException(
          'The website returned an unsupported media URL.',
        );
      }
      final headers = format['http_headers'] ?? payload['http_headers'];
      tracks.add((
        url.toString(),
        {
          if (headers is Map)
            for (final entry in headers.entries)
              if (entry.key is String &&
                  const {
                    'user-agent',
                    'referer',
                    'origin',
                  }.contains((entry.key as String).toLowerCase()) &&
                  entry.value is String &&
                  (entry.value as String).length <= 4096 &&
                  !(entry.value as String).contains(RegExp(r'[\r\n\x00]')))
                (entry.key as String).toLowerCase(): entry.value as String,
        },
      ));
    }
    String edl(String url) => '%${utf8.encode(url).length}%$url';
    final rawTitle = payload['title'];
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? String.fromCharCodes(rawTitle.trim().runes.take(180))
        : 'Web video';
    return VideoWebMedia(
      tracks.length == 1
          ? tracks.first.$1
          : 'edl://${tracks.map((track) => '!new_stream;!no_clip;${edl(track.$1)}').join(';')}',
      title,
      tracks.first.$2,
    );
  }
}

Future<VideoWebMedia> resolveVideoWebsite(
  Uri url,
  VideoWebOptions options, {
  Future<String?> Function(String url, String format)? androidResolver,
}) async {
  String? result;
  if (androidResolver != null) {
    result = await androidResolver(
      url.toString(),
      options.selector,
    ).timeout(const Duration(seconds: 65));
  } else {
    final executable = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
    late final Process process;
    try {
      process = await Process.start(executable, [
        '--ignore-config',
        '--no-plugin-dirs',
        '--no-playlist',
        '--no-warnings',
        '--no-cache-dir',
        '--socket-timeout',
        '8',
        '--retries',
        '1',
        '--extractor-retries',
        '1',
        '--js-runtimes',
        'node',
        '--skip-download',
        '--dump-single-json',
        '--format',
        options.selector,
        '--',
        url.toString(),
      ]);
    } on ProcessException {
      throw const FormatException(
        'Install yt-dlp and add it to your system PATH.',
      );
    }
    try {
      final tasks = await Future.wait<Object>([
        process.stdout.fold<List<int>>([], (bytes, chunk) {
          if (bytes.length + chunk.length > 16 * 1024 * 1024) {
            throw const FormatException('The website returned too much data.');
          }
          return bytes..addAll(chunk);
        }),
        process.stderr.drain<void>().then((_) => true),
        process.exitCode,
      ], eagerError: true).timeout(const Duration(seconds: 65));
      if (tasks[2] != 0) {
        throw const FormatException('yt-dlp could not extract this video.');
      }
      result = utf8.decode(tasks[0] as List<int>);
    } finally {
      process.kill();
    }
  }
  if (result == null) throw const FormatException('No web video was returned.');
  return VideoWebMedia.parse(result);
}
