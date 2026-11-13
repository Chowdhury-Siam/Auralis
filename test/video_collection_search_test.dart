import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_theme.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_library.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const alpha = VideoSource.telegram(
  Track(
    id: '-1:1',
    title: 'Alpha episode',
    artist: '',
    source: 'Cinema',
    duration: Duration(minutes: 2),
  ),
);
const beta = VideoSource.telegram(
  Track(
    id: '-1:2',
    title: 'Beta episode',
    artist: '',
    source: 'Cinema',
    duration: Duration(minutes: 2),
  ),
);

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Segoe UI',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(320, 568), 2.0),
  ]) {
    testWidgets(
      'all Video collections share the search panel at $size / $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final settings = MemorySettings()
          ..defaultInterface = AppInterface.video
          ..reducedMotion = true;
        final data = settings.videoPlayback;
        data.putPlaylist('Season', [beta, alpha]);
        data.putPlaylist('Bonus', [beta]);
        data.recordVideo(alpha);
        data.recordVideo(beta);
        data.remember(beta.id, const Duration(seconds: 12), beta.duration);
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: FakeTd(),
        );
        final music = PlayerController(
          FakeAudio(),
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await music.shutdown();
          await telegram.shutdown();
        });
        await tester.pumpWidget(AuralisApp(player: music, telegram: telegram));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Library').first);
        await tester.pumpAndSettle();

        Finder field(int index) => find.byKey(
          index == 0
              ? const ValueKey('video-library-search')
              : ValueKey(('video-collection-search', index)),
        );
        Future<void> select(String name) async {
          await tester.tap(
            find.byKey(const ValueKey('video-library-collection-menu')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(PopupMenuItem<int>, name));
          await tester.pump();
          // Snapshots read the real filesystem, independently of frame pumping.
          final waiting = Stopwatch()..start();
          var frames = 0;
          while ((frames < 2 ||
                  find
                      .byType(CircularProgressIndicator)
                      .evaluate()
                      .isNotEmpty) &&
              waiting.elapsed < const Duration(seconds: 5)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 16));
            frames++;
          }
          expect(
            find.byType(CircularProgressIndicator),
            findsNothing,
            reason: 'The snapshot directory read must finish before settling frames.',
          );
          await tester.pumpAndSettle();
        }

        void checkPanel(int index) {
          final panel = find.byKey(ValueKey(('video-library-panel', index)));
          final material = tester.widget<Material>(panel);
          final colors = Theme.of(tester.element(panel)).colorScheme;
          expect(material.color, colors.surfaceContainerLowest);
          expect(
            material.borderRadius,
            const BorderRadius.vertical(top: Radius.circular(26)),
          );
          expect(
            find.descendant(of: panel, matching: field(index)),
            findsOneWidget,
          );
          expect(
            tester.getRect(field(index)).top,
            tester.getRect(panel).top + 4,
          );
        }

        Future<void> showRow(String text) async {
          final scrollable = find
              .descendant(
                of: find.byType(VideoLibraryPage),
                matching: find.byType(Scrollable),
              )
              .first;
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(text),
            160,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
        }

        checkPanel(0);
        await tester.enterText(field(0), 'Original filter');
        await select('Playlists');
        checkPanel(1);
        await tester.enterText(field(1), 'Alpha');
        await tester.pumpAndSettle();
        await showRow('Season');
        expect(find.text('Bonus'), findsNothing);
        await select('History');
        checkPanel(2);
        await tester.enterText(field(2), 'Beta');
        await tester.pumpAndSettle();
        await showRow('Beta episode');
        expect(find.text('Alpha episode'), findsNothing);
        await select('Snapshots');
        checkPanel(3);
        await tester.enterText(field(3), 'Favorite frame');
        await tester.pumpAndSettle();
        await select('Playlists');
        expect(tester.widget<TextField>(field(1)).controller!.text, 'Alpha');
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        await showRow('Bonus');
        await select('History');
        expect(tester.widget<TextField>(field(2)).controller!.text, 'Beta');
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('video-library-collection-menu')),
          findsNothing,
        );
        expect(field(2), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await select('All videos');
        expect(
          tester.widget<TextField>(field(0)).controller!.text,
          'Original filter',
        );
        expect(data.playlists['Season'], [beta, alpha]);
        expect(data.history, hasLength(2));
        expect(data.positions[beta.id], const Duration(seconds: 12));
        expect(music.queue, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'filtered playlist playback keeps the original queue and indices',
    (tester) async {
      final data = VideoPlaybackData()..putPlaylist('Season', [beta, alpha]);
      var query = 'Alpha';
      late StateSetter update;
      VideoSelection? selection;
      await tester.pumpWidget(
        MaterialApp(
          theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return Scaffold(
                body: VideoLibraryPage(
                  data: data,
                  save: () async {},
                  pickFiles: () async => [],
                  playlists: true,
                  embedded: true,
                  query: query,
                  onPlay: (value) => selection = value,
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season'));
      await tester.pumpAndSettle();
      expect(find.text('Beta episode'), findsNothing);
      expect(find.byTooltip('Reorder video'), findsNothing);
      await tester.ensureVisible(find.text('Alpha episode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha episode'));
      expect(selection!.$1, [beta, alpha]);
      expect(selection!.$2, 1);
      update(() => query = '');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Reorder video'), findsNWidgets(2));
      expect(data.playlists['Season'], [beta, alpha]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'snapshot searching filters names without reloading or deleting files',
    (tester) async {
      final file = File('test/fixtures/cover.png').absolute;
      var query = 'not a frame name';
      var loads = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return VideoSnapshotsPage(
                query: query,
                loadSnapshots: () async {
                  loads++;
                  return [file];
                },
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No snapshots found'), findsOneWidget);
      update(() => query = 'cover');
      await tester.pumpAndSettle();
      expect(find.text('No snapshots found'), findsNothing);
      expect(find.byTooltip('Delete snapshot'), findsOneWidget);
      expect(loads, 1);
      expect(file.existsSync(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      });
      expect(tester.takeException(), isNull);
    },
  );
}
