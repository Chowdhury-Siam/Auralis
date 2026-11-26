import 'dart:io';

import 'package:auralis/app.dart';
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
    testWidgets('Video collections have no search fields at $size / $scale', (
      tester,
    ) async {
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
        await tester.tap(find.byTooltip('Show $name'));
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
          find.descendant(of: panel, matching: find.byType(TextField)),
          findsNothing,
        );
        expect(field(index), findsNothing);
        if (index == 1) {
          final header = find.byKey(const ValueKey('video-collection-header'));
          expect(tester.getRect(header).top, tester.getRect(panel).top + 8);
          if (scale == 1) {
            expect(tester.getSize(header).height, lessThanOrEqualTo(68));
          }
        }
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
      expect(find.byTooltip('Library collection: All videos'), findsNothing);
      await select('History');
      checkPanel(1);
      await showRow('Beta episode');
      if (size.width == 390) {
        expect(
          tester.getSize(find.byKey(ValueKey(beta.id))).height,
          lessThan(132),
        );
        expect(find.text('Alpha episode').hitTestable(), findsOneWidget);
      }
      expect(find.byTooltip('Clear search'), findsNothing);
      expect(field(1), findsNothing);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-library-indicator')),
        findsNothing,
      );
      expect(field(1), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await select('All videos');
      checkPanel(0);
      expect(data.history, hasLength(2));
      expect(data.positions[beta.id], const Duration(seconds: 12));
      expect(music.queue, isEmpty);
      if (size.width == 1280) {
        final local = VideoSource.file(
          Uri.file('/videos/local.mkv'),
          'Local episode',
          runtime: const Duration(minutes: 3),
        );
        data.recordVideo(local);
        expect(
          find.byTooltip('Telegram · Switch to On this device'),
          findsNothing,
        );
        await select('History');
        checkPanel(1);
        await showRow('Local episode');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        checkPanel(0);
        expect(find.text('Choose folder'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
