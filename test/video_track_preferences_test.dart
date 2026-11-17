import 'dart:convert';

import 'package:auralis/models.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:auralis/video_track_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mpv;

void main() {
  for (final label in [
    'ja',
    'jp',
    'jpn',
    'jap',
    'Japan',
    'Japanese',
    'JA-jp',
    'ja_JP',
    '日本語',
  ]) {
    test('Japanese audio matches language or title: $label', () {
      for (final useTitle in [false, true]) {
        final preferred = mpv.AudioTrack(
          '2',
          useTitle ? '[$label] AAC 5.1' : null,
          useTitle ? 'und' : label,
        );
        expect(
          preferredVideoAudio([
            mpv.AudioTrack.auto(),
            mpv.AudioTrack.no(),
            const mpv.AudioTrack('1', 'English', 'en', isDefault: true),
            preferred,
          ]),
          preferred,
        );
      }
    });
  }

  for (final label in ['en', 'eng', 'English', 'EN-us', 'en_GB', '英語']) {
    test('English subtitles match language or title: $label', () {
      for (final useTitle in [false, true]) {
        final preferred = mpv.SubtitleTrack(
          '2',
          useTitle ? '[$label] Subtitles' : null,
          useTitle ? null : label,
        );
        expect(
          preferredVideoSubtitle([
            mpv.SubtitleTrack.auto(),
            mpv.SubtitleTrack.no(),
            const mpv.SubtitleTrack('1', 'Japanese', 'ja', isDefault: true),
            preferred,
          ]),
          preferred,
        );
      }
    });
  }

  test('missing preferred languages leave default selection unchanged', () {
    expect(
      preferredVideoAudio([
        mpv.AudioTrack.auto(),
        mpv.AudioTrack.no(),
        const mpv.AudioTrack('1', 'English', 'eng', isDefault: true),
        const mpv.AudioTrack('2', 'JPG cover', 'und'),
      ]),
      isNull,
    );
    expect(
      preferredVideoSubtitle([
        mpv.SubtitleTrack.auto(),
        mpv.SubtitleTrack.no(),
        const mpv.SubtitleTrack('1', 'French', 'fr', isDefault: true),
        const mpv.SubtitleTrack('2', 'Commentary / Bengali', 'bn'),
      ]),
      isNull,
    );
    expect(preferredVideoAudio([]), isNull);
    expect(preferredVideoSubtitle([]), isNull);
  });

  test('language metadata outranks title matches and default breaks ties', () {
    const japanese = mpv.AudioTrack('2', 'Main audio', 'jpn');
    const defaultJapanese = mpv.AudioTrack('3', null, 'ja', isDefault: true);
    expect(
      preferredVideoAudio([
        const mpv.AudioTrack('1', 'Japanese', null, isDefault: true),
        japanese,
        defaultJapanese,
      ]),
      defaultJapanese,
    );
    const english = mpv.SubtitleTrack('2', null, 'eng');
    const defaultEnglish = mpv.SubtitleTrack('3', null, 'en', isDefault: true);
    expect(
      preferredVideoSubtitle([
        const mpv.SubtitleTrack('1', 'English', null, isDefault: true),
        english,
        defaultEnglish,
      ]),
      defaultEnglish,
    );
  });

  test('region subtags do not masquerade as the preferred language', () {
    expect(
      preferredVideoAudio([
        const mpv.AudioTrack('1', 'English audio', 'en-JP'),
      ]),
      isNull,
    );
    expect(
      preferredVideoSubtitle([
        const mpv.SubtitleTrack('1', 'French subtitles', 'fr_EN'),
      ]),
      isNull,
    );
  });

  test(
    'channel preferences survive a settings reload and follow the channel ID',
    () {
      VideoSource source(String message, String channel) =>
          VideoSource.telegram(
            Track(id: message, title: 'Episode', artist: '', source: channel),
          );

      final first = source('-1001:20', 'Anime');
      final next = source('-1001:21', 'Renamed channel');
      final other = source('-1002:20', 'Anime');
      final preferences = VideoPlaybackData();
      preferences.channels[first.channelId!] = VideoChannelSettings()
        ..audio = const VideoTrackChoice('2', 'English dub', 'eng')
        ..subtitles = const VideoTrackChoice('no', null, null)
        ..volume = 55
        ..brightness = .4
        ..pictureBrightness = 18;

      final restored = VideoPlaybackData.fromJson(
        jsonDecode(jsonEncode(preferences.toJson())),
      );
      final channel = restored.channels[next.channelId]!;
      expect(channel.volume, 55);
      expect(channel.brightness, .4);
      expect(channel.pictureBrightness, 18);
      expect(restored.channels[other.channelId], isNull);
      expect(
        VideoSource.file(Uri.file('/movies/video.mp4'), 'Episode').channelId,
        isNull,
      );

      const japanese = mpv.AudioTrack('2', 'Japanese', 'jpn');
      const english = mpv.AudioTrack('4', 'English dub', 'en-US');
      expect(
        preferredVideoAudio([japanese, english], choice: channel.audio),
        english,
      );
      expect(preferredVideoAudio([japanese], choice: channel.audio), japanese);
      expect(
        preferredVideoSubtitle([
          const mpv.SubtitleTrack('2', 'English', 'en'),
        ], choice: channel.subtitles)?.id,
        'no',
      );

      restored.clearTelegram(keepActivity: true);
      expect(restored.channels, isEmpty);
    },
  );

  test(
    'saved subtitle title identifies the correct track when its ID changes',
    () {
      const dialogue = mpv.SubtitleTrack('5', 'Dialogue', 'en');
      const signs = mpv.SubtitleTrack('9', 'Signs & Songs', 'eng');
      const choice = VideoTrackChoice('5', 'Signs & Songs', 'en');
      expect(preferredVideoSubtitle([dialogue, signs], choice: choice), signs);
    },
  );

  test('external tracks are never automatically loaded again', () {
    expect(
      preferredVideoAudio([
        mpv.AudioTrack.uri('file:///japanese.mka', language: 'ja'),
      ]),
      isNull,
    );
    expect(
      preferredVideoSubtitle([
        mpv.SubtitleTrack.uri('file:///english.srt', language: 'en'),
        mpv.SubtitleTrack.data('Subtitle text', title: 'English'),
      ]),
      isNull,
    );
  });
}
