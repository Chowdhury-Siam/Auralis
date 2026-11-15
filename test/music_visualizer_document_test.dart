import 'dart:async';
import 'dart:convert';

import 'package:auralis/music_visualizer_document.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class VisualizerBundle extends CachingAssetBundle {
  final reads = <String>[];
  final cacheFlags = <bool>[];
  final gates = <Completer<String>>[];
  bool failNext = false;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(key)));

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    reads.add(key);
    cacheFlags.add(cache);
    if (key.endsWith('index.html')) {
      if (gates.isNotEmpty) return gates.removeAt(0).future;
      if (failNext) {
        failNext = false;
        throw StateError('Asset unavailable');
      }
      return template;
    }
    return '$key </script>';
  }

  static const template =
      '/*__BUTTERCHURN__*/ /*__PRESETS__*/ /*__AUDIOMOTION__*/ /*__BRIDGE__*/';
}

void main() {
  test(
    'offline document shares loads and caches only the assembled HTML',
    () async {
      final bundle = VisualizerBundle();
      final document = MusicVisualizerDocument(bundle);
      final first = document.load();
      expect(document.load(), same(first));
      final html = await first;
      expect(document.load(), same(first));
      expect(bundle.reads, hasLength(5));
      expect(bundle.cacheFlags, everyElement(isFalse));
      expect(html, isNot(contains('/*__')));
      expect(html, contains(r'<\/script>'));
      expect(html, isNot(contains('</script>')));
      for (final script in [
        'butterchurn',
        'presets',
        'audiomotion',
        'bridge',
      ]) {
        expect(html, contains('$script.js'));
      }
      document.clear();
      expect(await document.load(), html);
      expect(bundle.reads, hasLength(10));
    },
  );

  test('failed document assembly can be retried', () async {
    final bundle = VisualizerBundle()..failNext = true;
    final document = MusicVisualizerDocument(bundle);
    await expectLater(document.load(), throwsStateError);
    expect(await document.load(), contains('bridge.js'));
    expect(bundle.reads, hasLength(6));
  });

  test(
    'clearing an in-flight load cannot evict its replacement on failure',
    () async {
      final old = Completer<String>(), replacement = Completer<String>();
      final bundle = VisualizerBundle()..gates.addAll([old, replacement]);
      final document = MusicVisualizerDocument(bundle);
      final first = document.load();
      final failed = expectLater(first, throwsStateError);
      document.clear();
      final second = document.load();
      old.completeError(StateError('Old load failed'));
      await failed;
      expect(document.load(), same(second));
      replacement.complete(VisualizerBundle.template);
      expect(await second, contains('bridge.js'));
      expect(document.load(), same(second));
      expect(bundle.reads, hasLength(6));
    },
  );
}
