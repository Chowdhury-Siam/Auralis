import 'dart:convert';

import 'package:auralis/video_playback_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('vertical swipes select levels by side and horizontal swipes seek', () {
    final options = VideoGestureOptions();
    VideoGesture? action({
      bool horizontal = false,
      bool left = false,
      bool brightness = true,
    }) => options.swipeAction(
      horizontal: horizontal,
      startsOnLeft: left,
      supportsBrightness: brightness,
    );

    for (final left in [true, false]) {
      expect(action(horizontal: true, left: left), VideoGesture.swipeSeek);
    }
    expect(action(left: true), VideoGesture.swipeBrightness);
    expect(action(), VideoGesture.swipeVolume);
    expect(action(left: true, brightness: false), isNull);
    expect(action(brightness: false), VideoGesture.swipeVolume);
    options.setEnabled(VideoGesture.swipeBrightness, false);
    expect(action(left: true), isNull);
    options.setEnabled(VideoGesture.swipeSeek, false);
    expect(action(horizontal: true), isNull);
    expect(action(), VideoGesture.swipeVolume);
  });

  test('old settings preserve all legacy gesture defaults', () {
    final data = VideoPlaybackData.fromJson({});
    final options = data.gestureOptions;
    expect(VideoGesture.values.every(options.enabled), isTrue);
    expect(options.toJson(), {
      'disabled': [],
      'seekZonePercent': 36,
      'swipeSeekSeconds': 240,
      'spaceHoldMs': 400,
      'hideSeconds': 4,
      'swipeSensitivity': 1.0,
      'zoomSensitivity': 1.0,
      'boostRate': 2.0,
    });
    expect(data.gestures, isTrue);
  });

  for (final gesture in VideoGesture.values) {
    test(
      '${gesture.name} toggles and persists independently of the master switch',
      () {
        final data = VideoPlaybackData()..gestures = false;
        data.gestureOptions.setEnabled(gesture, false);
        final restored = VideoPlaybackData.fromJson(
          jsonDecode(jsonEncode(data.toJson())),
        );
        expect(restored.gestures, isFalse);
        for (final other in VideoGesture.values) {
          expect(restored.gestureOptions.enabled(other), other != gesture);
        }
        restored.gestureOptions.setEnabled(gesture, true);
        expect(
          VideoGesture.values.every(restored.gestureOptions.enabled),
          isTrue,
        );
      },
    );
  }

  test('custom sensitivity and timing settings round-trip', () {
    final options = VideoGestureOptions()
      ..seekZonePercent = 25
      ..swipeSeekSeconds = 60
      ..spaceHoldMs = 800
      ..hideSeconds = 0
      ..swipeSensitivity = .5
      ..zoomSensitivity = 2
      ..boostRate = 1.25;
    expect(
      VideoGestureOptions.fromJson(jsonDecode(jsonEncode(options.toJson())))
          .toJson(),
      options.toJson(),
    );
  });

  test('invalid JSON, unknown names, nonfinite values and fractional integers are safe', () {
    final defaults = VideoGestureOptions().toJson();
    for (final invalid in [
      null,
      true,
      [],
      'bad',
      {
        'disabled': ['unknown', 1, null],
        'seekZonePercent': 36.0,
        'swipeSeekSeconds': 240.0,
        'spaceHoldMs': 400.0,
        'hideSeconds': 4.0,
        'swipeSensitivity': double.nan,
        'zoomSensitivity': double.infinity,
        'boostRate': -1,
      },
    ]) {
      expect(VideoGestureOptions.fromJson(invalid).toJson(), defaults);
    }
  });
}
