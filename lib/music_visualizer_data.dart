enum MusicPanel { lyrics, spectrum, visualizer }

/// Device-local rendering preferences. Never included in Music backup/sync.
class MusicVisualizerSettings {
  String spectrum = 'line', palette = 'prism', preset = '';
  bool cycle = true, songMotion = true;
  int fps = 30, cycleSeconds = 30;

  Map<String, Object> toJson() => {
    'spectrum': spectrum,
    'palette': palette,
    'preset': preset,
    'cycle': cycle,
    'songMotion': songMotion,
    'fps': fps,
    'cycleSeconds': cycleSeconds,
  };

  static MusicVisualizerSettings fromJson(Object? value) {
    final result = MusicVisualizerSettings();
    if (value is! Map) return result;
    if (['line', 'bars', 'radial'].contains(value['spectrum'])) {
      result.spectrum = value['spectrum'] as String;
    }
    if (['prism', 'classic', 'steelblue'].contains(value['palette'])) {
      result.palette = value['palette'] as String;
    }
    if (value['preset'] case final String name when name.length <= 300) {
      result.preset = name;
    }
    result.cycle = value['cycle'] != false;
    result.songMotion = value['songMotion'] != false;
    if ([20, 30, 60].contains(value['fps'])) result.fps = value['fps'] as int;
    if ([15, 30, 60].contains(value['cycleSeconds'])) {
      result.cycleSeconds = value['cycleSeconds'] as int;
    }
    return result;
  }
}
