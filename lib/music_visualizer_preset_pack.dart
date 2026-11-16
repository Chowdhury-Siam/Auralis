import 'dart:convert';

import 'package:flutter/services.dart';

/// An offline catalogue. Only the page containing the requested preset is read.
class MusicVisualizerPresetPack {
  MusicVisualizerPresetPack._(
    this._bundle,
    this.version,
    this.pageSize,
    this.names,
  );
  static const _path = 'assets/visualizer/projectm';
  final AssetBundle _bundle;
  final String version;
  final int pageSize;
  final List<String> names;

  static Future<MusicVisualizerPresetPack> load(AssetBundle bundle) async {
    final data = jsonDecode(
      await bundle.loadString('$_path/catalog.json', cache: false),
    );
    if (data is! Map ||
        data['version'] is! String ||
        data['pageSize'] is! int ||
        data['names'] is! List) {
      throw const FormatException('Invalid ProjectM catalogue');
    }
    final names = (data['names'] as List).cast<String>();
    final pageSize = data['pageSize'] as int;
    if (names.isEmpty ||
        names.length > 12000 ||
        names.toSet().length != names.length ||
        pageSize < 1 ||
        pageSize > 64 ||
        names.any((name) => name.isEmpty || name.length > 300)) {
      throw const FormatException('Invalid ProjectM catalogue');
    }
    return MusicVisualizerPresetPack._(
      bundle,
      data['version'] as String,
      pageSize,
      List.unmodifiable(names),
    );
  }

  Future<String> jsonFor(int index) async {
    RangeError.checkValidIndex(index, names);
    final page = await _bundle.loadString(
      '$_path/page-${index ~/ pageSize}.json',
      cache: false,
    );
    final preset = (jsonDecode(page) as List)[index % pageSize];
    return jsonEncode(preset);
  }
}
