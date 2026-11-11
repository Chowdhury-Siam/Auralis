import 'dart:convert';

import 'package:auralis/video_folder_browser.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:auralis/video_web_streams.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'web quality caps and preferences round-trip with the video settings',
    () {
      final data = VideoPlaybackData()
        ..gpuNext = true
        ..matchRefreshRate = true
        ..hdrProfile = VideoHdrProfile.hlg
        ..webOptions = const VideoWebOptions(
          height: 720,
          fps: 30,
          codec: 'av01',
          container: 'webm',
          audioKbps: 128,
          hdr: true,
        );
      final restored = VideoPlaybackData.fromJson(data.toJson());
      expect(restored.hdrProfile, VideoHdrProfile.hlg);
      expect(restored.gpuNext && restored.matchRefreshRate, isTrue);
      expect(
        restored.webOptions.selector,
        contains('[height<=?720][fps<=?30]'),
      );
      expect(
        restored.webOptions.selector,
        contains('[vcodec^=av01][ext=webm]'),
      );
      expect(restored.webOptions.selector, contains('[abr<=?128]'));
      expect(VideoWebOptions.fromJson({'height': 'bad'}).height, 1080);
      expect(
        isVideoWebsite(Uri.parse('https://m.youtube.com/watch?v=a')),
        isTrue,
      );
      expect(
        isVideoWebsite(Uri.parse('https://youtube.com.example.com/v')),
        isFalse,
      );
    },
  );

  test('yt-dlp split streams retain their signed URLs and safe headers', () {
    final media = VideoWebMedia.parse(
      jsonEncode({
        'title': 'Example video',
        'requested_formats': [
          {
            'url': 'https://cdn.example/video.mp4?x=a%2Cb',
            'http_headers': {
              'User-Agent': 'Extractor',
              'Referer': 'https://example.com/',
              'Authorization': 'do not forward',
              'Origin': 'bad\nheader',
            },
          },
          {'url': 'https://cdn.example/audio.webm?token=123'},
        ],
      }),
    );
    expect(media.title, 'Example video');
    expect(media.resource, startsWith('edl://!new_stream;!no_clip;%'));
    expect(media.resource, contains('https://cdn.example/video.mp4?x=a%2Cb'));
    expect(
      media.resource,
      contains('https://cdn.example/audio.webm?token=123'),
    );
    expect(media.headers, {
      'user-agent': 'Extractor',
      'referer': 'https://example.com/',
    });
    expect(
      () => VideoWebMedia.parse('{"url":"file:///etc/passwd"}'),
      throwsFormatException,
    );
  });

  test('Android shared videos accept content URIs and preserve file order', () {
    final sources = videosFromAndroid([
      {'uri': 'content://sample/videos/1', 'name': 'first'},
      {'uri': 'https://example.com/video.mp4', 'name': 'invalid'},
      {'uri': 'content://sample/videos/2', 'name': 'second'},
    ]);
    expect(sources.map((source) => source.title), ['first', 'second']);
  });
}
