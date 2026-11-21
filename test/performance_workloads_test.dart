import 'dart:math';

import 'package:auralis/library_widgets.dart';
import 'package:auralis/listening.dart';
import 'package:auralis/lyrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/legacy_lyrics_parser.dart';

String _lrc(int count) => [
  for (var i = count - 1; i >= 0; i--)
    '[${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}.123]行 $i',
].join('\n');

void main() {
  test('linear timestamp grouping is identical to the delivered parser', () {
    final random = Random(37);
    for (var iteration = 0; iteration < 20; iteration++) {
      final text = [
        '[ar:Artist]',
        '[offset:${iteration.isEven ? -500 : 800}]',
        for (var i = 0; i < 500; i++)
          '[00:${random.nextInt(60).toString().padLeft(2, '0')}.5]'
              '${i % 3 == 0 ? '[00:01.5]' : ''}'
              '${i % 7 == 0 ? '' : '日本語 <00:01.50>line $i'}',
      ].join('\n');
      expect(
        Lyrics.parse(text).timestampedText,
        legacyParse(text).timestampedText,
      );
    }
    final maximum = _lrc(2000);
    expect(
      Lyrics.parse(maximum).timestampedText,
      legacyParse(maximum).timestampedText,
    );
  });

  test('single top track matches the existing full sort, including mutable data and ties', () {
    final stats = ListeningStats();
    expect(stats.topTrack, isNull);
    for (var i = 100; i >= 0; i--) {
      stats.tracks['id-$i'] = ListeningTrack(
        title: '$i',
        artist: '',
        source: '',
        milliseconds: i % 13,
      );
      expect(stats.topTrack!.key, stats.topTracks.first.key);
    }
    stats.tracks['id-70']!.milliseconds = 99999;
    expect(stats.topTrack!.key, stats.topTracks.first.key);
    stats.tracks.clear();
    expect(stats.topTrack, isNull);
  });

  testWidgets(
    'collection visibility wrappers do not rebuild on every swipe pixel',
    (tester) async {
      var index = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: LibraryCollectionPager(
                index: index,
                count: 3,
                onChanged: (value) => update(() => index = value),
                itemBuilder: (_, page) => Center(child: Text('Page $page')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pageView = find.byType(PageView);
      final gesture = await tester.startGesture(tester.getCenter(pageView));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      List<Widget> wrappers() => tester
          .widgetList<Offstage>(
            find.descendant(
              of: pageView,
              matching: find.byType(Offstage),
              skipOffstage: false,
            ),
          )
          .toList();
      final previous = wrappers();
      expect(previous, isNotEmpty);
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      final current = wrappers();
      expect(current.length, previous.length);
      for (var i = 0; i < current.length; i++) {
        expect(current[i], same(previous[i]));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.drag(pageView, const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(index, greaterThan(0));
      expect(find.text('Page $index').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  test('equivalent CPU workloads (opt-in, not native frame profiling)', () {
    final text = _lrc(2000);
    final stats = ListeningStats();
    final random = Random(37);
    for (var i = 0; i < 10000; i++) {
      stats.tracks['id-$i'] = ListeningTrack(
        title: '$i',
        artist: '',
        source: '',
        milliseconds: random.nextInt(100000),
      );
    }
    Object? sink;
    double measure(Object? Function() work, int repetitions) {
      for (var i = 0; i < 5; i++) {
        sink = work();
      }
      final runs = <double>[];
      for (var trial = 0; trial < 7; trial++) {
        final watch = Stopwatch()..start();
        for (var i = 0; i < repetitions; i++) {
          sink = work();
        }
        watch.stop();
        runs.add(watch.elapsedMicroseconds / repetitions);
      }
      runs.sort();
      return runs[runs.length ~/ 2];
    }

    final beforeLyrics = measure(() => legacyParse(text), 20);
    final afterLyrics = measure(() => Lyrics.parse(text), 20);
    final beforeTop = measure(() => stats.topTracks.first, 50);
    final afterTop = measure(() => stats.topTrack, 50);
    // Diagnostic output only: wall-time thresholds are deliberately not CI assertions.
    debugPrint(
      'CPU BENCHMARK median us/op, 7 trials: LRC(2000) '
      '${beforeLyrics.toStringAsFixed(1)} -> ${afterLyrics.toStringAsFixed(1)}; '
      'topTrack(10000) ${beforeTop.toStringAsFixed(1)} -> ${afterTop.toStringAsFixed(1)}',
    );
    expect(sink, isNotNull);
  }, skip: !const bool.fromEnvironment('AURALIS_BENCHMARK'));
}
