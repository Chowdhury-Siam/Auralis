enum VideoGesture {
  tapControls('Tap to show or hide controls'),
  seekDoubleTap('Double-tap sides to seek'),
  pauseDoubleTap('Double-tap center to play or pause'),
  swipeSeek('Swipe horizontally to seek'),
  swipeVolume('Swipe vertically on the right for volume'),
  swipeBrightness('Swipe vertically on the left for brightness'),
  pinchZoom('Pinch to zoom'),
  panZoom('Drag to pan a zoomed video'),
  holdSpeed('Long-press for temporary speed'),
  hoverControls('Mouse movement shows controls'),
  keyboard('Keyboard playback shortcuts'),
  spaceHold('Hold Space for temporary speed'),
  tapTime('Tap time to switch elapsed or remaining');

  const VideoGesture(this.label);
  final String label;
}

/// Video-only input preferences. Missing/invalid values retain legacy defaults.
class VideoGestureOptions {
  final disabled = <VideoGesture>{};
  int seekZonePercent = 36,
      swipeSeekSeconds = 240,
      spaceHoldMs = 400,
      hideSeconds = 4;
  double swipeSensitivity = 1, zoomSensitivity = 1, boostRate = 2;

  bool enabled(VideoGesture gesture) => !disabled.contains(gesture);
  void setEnabled(VideoGesture gesture, bool value) =>
      value ? disabled.remove(gesture) : disabled.add(gesture);

  VideoGesture? swipeAction({
    required bool horizontal,
    required bool startsOnLeft,
    required bool supportsBrightness,
  }) {
    if (!horizontal && startsOnLeft && !supportsBrightness) return null;
    final action = horizontal
        ? VideoGesture.swipeSeek
        : startsOnLeft
        ? VideoGesture.swipeBrightness
        : VideoGesture.swipeVolume;
    return enabled(action) ? action : null;
  }

  static VideoGestureOptions fromJson(Object? value) {
    final result = VideoGestureOptions();
    if (value is! Map) return result;
    final disabled = value['disabled'];
    if (disabled is List) {
      for (final gesture in VideoGesture.values) {
        if (disabled.contains(gesture.name)) result.disabled.add(gesture);
      }
    }
    if (value['seekZonePercent'] is int &&
        [25, 30, 36, 40].contains(value['seekZonePercent'])) {
      result.seekZonePercent = value['seekZonePercent'] as int;
    }
    if (value['swipeSeekSeconds'] is int &&
        [30, 60, 120, 240, 600].contains(value['swipeSeekSeconds'])) {
      result.swipeSeekSeconds = value['swipeSeekSeconds'] as int;
    }
    if (value['spaceHoldMs'] is int &&
        [250, 400, 600, 800].contains(value['spaceHoldMs'])) {
      result.spaceHoldMs = value['spaceHoldMs'] as int;
    }
    if (value['hideSeconds'] is int &&
        [0, 2, 4, 6, 10].contains(value['hideSeconds'])) {
      result.hideSeconds = value['hideSeconds'] as int;
    }
    if ([.5, 1, 1.5, 2].contains(value['swipeSensitivity'])) {
      result.swipeSensitivity = (value['swipeSensitivity'] as num).toDouble();
    }
    if ([.5, 1, 1.5, 2].contains(value['zoomSensitivity'])) {
      result.zoomSensitivity = (value['zoomSensitivity'] as num).toDouble();
    }
    if ([1.25, 1.5, 1.75, 2, 2.5, 3].contains(value['boostRate'])) {
      result.boostRate = (value['boostRate'] as num).toDouble();
    }
    return result;
  }

  Map<String, Object> toJson() => {
    'disabled': [
      for (final gesture in VideoGesture.values)
        if (!enabled(gesture)) gesture.name,
    ],
    'seekZonePercent': seekZonePercent,
    'swipeSeekSeconds': swipeSeekSeconds,
    'spaceHoldMs': spaceHoldMs,
    'hideSeconds': hideSeconds,
    'swipeSensitivity': swipeSensitivity,
    'zoomSensitivity': zoomSensitivity,
    'boostRate': boostRate,
  };
}
