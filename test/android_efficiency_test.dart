import 'dart:convert';
import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/library_widgets.dart';
import 'package:auralis/listening.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/wave_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  for (final mode in AppInterface.values) {
    testWidgets(
      '${mode.label} has no device source or folder-management option',
      (tester) async {
        final settings = MemorySettings()..defaultInterface = mode;
        final td = FakeTd();
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: td,
        );
        final player = PlayerController(
          FakeAudio(),
          TelegramStreamProxy(telegram.request),
          settings,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await player.shutdown();
          await telegram.shutdown();
        });
        await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Open video files'), findsNothing);
        expect(find.byIcon(Icons.folder_open_rounded), findsNothing);
        await tester.tap(find.byTooltip('Library').first);
        await tester.pumpAndSettle();
        expect(find.byType(LibraryLayout), findsOneWidget);
        expect(
          find.byTooltip('Telegram · Switch to On this device'),
          findsNothing,
        );
        expect(find.text('Choose folder'), findsNothing);
        final actions = find.byTooltip('Library actions');
        if (mode == AppInterface.video) {
          expect(actions, findsNothing);
        } else {
          await tester.tap(actions);
          await tester.pumpAndSettle();
          expect(find.text('Manage folders'), findsNothing);
          expect(find.text('Refresh library'), findsOneWidget);
        }
        expect(td.requests.where((r) => r['@type'] == 'scanFolders'), isEmpty);
      },
    );
  }

  testWidgets(
    'wave motion paints without rebuilding the slider and sleeps when hidden',
    (tester) async {
      late StateSetter update;
      var visible = true;
      var value = .4;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return Scaffold(
                body: TickerMode(
                  enabled: visible,
                  child: WaveSeekBar(
                    value: value,
                    playing: true,
                    reducedMotion: false,
                    format: (v) => '${(v * 100).round()} seconds',
                    onChanged: (v) => update(() => value = v),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final slider = find.byKey(const ValueKey('playback-seek'));
      final before = tester.widget<Slider>(slider);
      final shape =
          tester
                  .widget<SliderTheme>(find.byType(SliderTheme).last)
                  .data
                  .trackShape!
              as WaveTrack;
      final initial = shape.motion!.value;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<Slider>(slider), same(before));
      }
      expect(shape.motion!.value, isNot(initial));
      update(() => visible = false);
      await tester.pump();
      final stopped = shape.motion!.value;
      await tester.pump(const Duration(milliseconds: 250));
      expect(shape.motion!.value, stopped);
      update(() => visible = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shape.motion!.value, isNot(stopped));
      await tester.tapAt(
        tester.getRect(slider).centerRight - const Offset(35, 0),
      );
      await tester.pump();
      expect(value, greaterThan(.4));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  test('stats relay avoids subsecond and buffer churn without dropping playback events', () async {
    final audio = FakeAudio();
    final player = PlayerController(
      audio,
      TelegramStreamProxy((_) async => {}),
      MemorySettings(),
    );
    addTearDown(player.shutdown);
    var samples = 0, labels = 0;
    player.addListener(() => samples++);
    player.statsChanges.addListener(() => labels++);
    for (var i = 0; i < 100; i++) {
      audio.position = Duration(milliseconds: i * 10);
      audio.buffered = Duration(seconds: i);
      audio.notifyListeners();
    }
    expect(samples, 100);
    expect(labels, 1);
    audio.position = const Duration(seconds: 1);
    audio.notifyListeners();
    expect(labels, 2);
    player.notifyListeners();
    expect(labels, 3);
  });

  test('large settings encode detached snapshots, preserve save order and skip identical writes', () async {
    final root = await Directory.systemTemp.createTemp(
      'auralis-settings-efficiency-',
    );
    addTearDown(() => root.delete(recursive: true));
    final settings = AppSettings(File('${root.path}/settings.json'));
    for (var i = 0; i < 250; i++) {
      settings.listening.tracks['track-$i'] = ListeningTrack(
        title: '$i',
        artist: '',
        source: '',
        milliseconds: i,
      );
    }
    settings.volume = 31;
    settings.playlists['Kept'] = ['first'];
    final first = settings.save();
    settings.volume = 76;
    settings.playlists['Kept']!.add('second');
    await first;
    final firstDisk = jsonDecode(await settings.file.readAsString()) as Map;
    expect(firstDisk['volume'], 31);
    expect(firstDisk['playlists']['Kept'], ['first']);
    await settings.save();
    var saved = jsonDecode(await settings.file.readAsString()) as Map;
    expect(saved['volume'], 76);
    expect(saved['playlists']['Kept'], ['first', 'second']);
    final sentinel = DateTime(2020, 1, 1);
    await settings.file.setLastModified(sentinel);
    await settings.save();
    expect(await settings.file.lastModified(), sentinel);
    settings.volume = 20;
    final a = settings.save();
    settings.volume = 76;
    final b = settings.save();
    await Future.wait([a, b]);
    saved = jsonDecode(await settings.file.readAsString()) as Map;
    expect(saved['volume'], 76);
    await settings.file.delete();
    await settings.save();
    expect(await settings.file.exists(), isTrue);
  });
}
