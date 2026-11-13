import 'dart:convert';
import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/preference_widgets.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test(
    'Music and Video sort choices persist separately across restarts',
    () async {
      final directory = await Directory.systemTemp.createTemp('auralis-sort-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/settings.json');
      for (final music in LibrarySort.values) {
        for (final video in LibrarySort.values) {
          final settings = AppSettings(file)..librarySort = music;
          settings.videoPlayback.librarySort = video;
          await settings.save();
          final restored = AppSettings(file);
          await restored.load();
          expect(restored.librarySort, music);
          expect(restored.videoPlayback.librarySort, video);
        }
      }
    },
  );

  test(
    'legacy shared sort migrates once without later following Music',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'auralis-sort-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/settings.json');
      for (final oldVideoData in [
        null,
        <String, dynamic>{'seekSeconds': 25},
      ]) {
        await file.writeAsString(
          jsonEncode({
            'librarySort': 'oldest',
            '_videoPlayback': ?oldVideoData,
          }),
        );
        final migrated = AppSettings(file);
        await migrated.load();
        expect(migrated.librarySort, LibrarySort.oldest);
        expect(migrated.videoPlayback.librarySort, LibrarySort.oldest);
        migrated.librarySort = LibrarySort.duration;
        await migrated.save();
        final restored = AppSettings(file);
        await restored.load();
        expect(restored.librarySort, LibrarySort.duration);
        expect(restored.videoPlayback.librarySort, LibrarySort.oldest);
        if (oldVideoData != null) {
          expect(restored.videoPlayback.seekSeconds, 25);
        }
      }
    },
  );

  test('invalid Video sorting falls back safely and Music snapshots do not overwrite it', () {
    final settings = AppSettings(File('unused'))
      ..librarySort = LibrarySort.artist;
    settings.videoPlayback = VideoPlaybackData.fromJson({
      'librarySort': 'unknown',
    });
    expect(settings.videoPlayback.librarySort, LibrarySort.title);
    settings.videoPlayback.librarySort = LibrarySort.newest;
    final musicSnapshot = settings.toJson()..['librarySort'] = 'oldest';
    expect(musicSnapshot.containsKey('_videoPlayback'), isFalse);
    settings.applyJson(musicSnapshot);
    expect(settings.librarySort, LibrarySort.oldest);
    expect(settings.videoPlayback.librarySort, LibrarySort.newest);
    expect(
      VideoPlaybackData.fromJson(settings.videoPlayback.toJson()).librarySort,
      LibrarySort.newest,
    );
  });

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'Settings sorts only the active mode and retains both choices at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final settings = MemorySettings()..librarySort = LibrarySort.oldest;
        settings.videoPlayback.librarySort = LibrarySort.newest;
        final player = PlayerController(
          FakeAudio(),
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: FakeTd(),
        );
        addTearDown(player.shutdown);
        addTearDown(telegram.shutdown);
        for (final mode in [
          AppInterface.music,
          AppInterface.video,
          AppInterface.music,
        ]) {
          settings.defaultInterface = mode;
          await tester.pumpWidget(
            AuralisApp(player: player, telegram: telegram),
          );
          await tester.pumpAndSettle();
          if (mode == AppInterface.video && size.width < 900) {
            await tester.tap(
              find.descendant(
                of: find.byKey(const ValueKey('video-navigation')),
                matching: find.byIcon(Icons.video_library_rounded),
              ),
            );
          } else {
            await tester.tap(find.byTooltip('Library').first);
          }
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Settings').first);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('settings-general')));
          await tester.pumpAndSettle();
          final video = mode == AppInterface.video;
          final preference = find.byKey(
            ValueKey(video ? 'video-sort-preference' : 'music-sort-preference'),
          );
          final beforeMusic = settings.librarySort;
          final beforeVideo = settings.videoPlayback.librarySort;
          final choice = tester.widget<PreferenceChoice<LibrarySort>>(
            preference,
          );
          expect(choice.value, video ? beforeVideo : beforeMusic);
          final next = video ? LibrarySort.artist : LibrarySort.duration;
          final trigger = find.byTooltip(
            'Library sort order: ${choice.value.label}',
          );
          await tester.ensureVisible(trigger);
          await tester.pumpAndSettle();
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          await tester.tap(find.text(next.label).last);
          await tester.pumpAndSettle();
          expect(settings.librarySort, video ? beforeMusic : next);
          expect(
            settings.videoPlayback.librarySort,
            video ? next : beforeVideo,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  }
}
