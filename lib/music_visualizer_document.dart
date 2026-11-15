import 'package:flutter/services.dart';

/// Reuse the immutable offline document across visits. Renderer state and
/// audio samples remain per-WebView; this cache contains only bundled code.
class MusicVisualizerDocument {
  MusicVisualizerDocument(this.bundle);

  static final bundled = MusicVisualizerDocument(rootBundle);
  final AssetBundle bundle;
  Future<String>? _pending;
  int _generation = 0;
  void clear() {
    _generation++;
    _pending = null;
  }

  Future<String> load() {
    final generation = _generation;
    return _pending ??= _compose().catchError((Object error) {
      if (generation == _generation) _pending = null;
      throw error;
    });
  }

  Future<String> _compose() async {
    const scripts = {
      'BUTTERCHURN': 'butterchurn.js',
      'PRESETS': 'presets.js',
      'AUDIOMOTION': 'audiomotion.js',
      'BRIDGE': 'bridge.js',
    };
    var html = await bundle.loadString(
      'assets/visualizer/index.html',
      cache: false,
    );
    for (final entry in scripts.entries) {
      final script = await bundle.loadString(
        'assets/visualizer/${entry.value}',
        cache: false,
      );
      html = html.replaceFirst(
        '/*__${entry.key}__*/',
        script.replaceAll('</script', r'<\/script'),
      );
    }
    return html;
  }
}
