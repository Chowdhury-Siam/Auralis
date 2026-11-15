enum MusicPanel { lyrics, spectrum, visualizer }

/// Device-local rendering preferences. Never included in Music backup/sync.
class MusicVisualizerSettings {
  static const frameLimits = [20, 23, 29, 30, 60, 90, 100, 120, 144];
  static const spectrumStyles = {
    'line': 'Spectrum',
    'bars': 'Bars',
    'radial': 'Radial',
    'fine': 'Fine bars',
    'wide': 'Wide bars',
    'led': 'LED meter',
    'outline': 'Outlined bars',
    'glow': 'Glow bars',
    'mirror': 'Mirror bars',
    'wave': 'Trace',
    'ridge': 'Peak ridge',
    'halo': 'Halo',
    'inward': 'Inward ring',
  };
  static const spectrumPalettes = {
    'prism': 'Rainbow',
    'classic': 'Classic',
    'steelblue': 'Blue',
    'aurora': 'Aurora',
    'sunset': 'Sunset',
    'ember': 'Ember',
    'glacier': 'Glacier',
    'orchid': 'Orchid',
    'mint': 'Mint',
    'neon': 'Neon',
    'sakura': 'Sakura',
    'marine': 'Marine',
    'sand': 'Golden hour',
  };

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
    if (spectrumStyles.containsKey(value['spectrum'])) {
      result.spectrum = value['spectrum'] as String;
    }
    if (spectrumPalettes.containsKey(value['palette'])) {
      result.palette = value['palette'] as String;
    }
    if (value['preset'] case final String name when name.length <= 300) {
      result.preset = name;
    }
    result.cycle = value['cycle'] != false;
    result.songMotion = value['songMotion'] != false;
    if (frameLimits.contains(value['fps'])) result.fps = value['fps'] as int;
    if ([15, 30, 60].contains(value['cycleSeconds'])) {
      result.cycleSeconds = value['cycleSeconds'] as int;
    }
    return result;
  }
}
