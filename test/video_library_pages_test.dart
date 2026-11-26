import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app_theme.dart';
import 'package:auralis/models.dart';
import 'package:auralis/video_library.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const first = VideoSource.telegram(
  Track(
    id: '-1001:1',
    title: 'Romantic Killer - 01',
    artist: '',
    source: 'Anime · Season 1',
    duration: Duration(minutes: 24),
  ),
);
const second = VideoSource.telegram(
  Track(
    id: '-1001:2',
    title: 'Romantic Killer - 02',
    artist: '',
    source: 'Anime · Season 1',
    duration: Duration(minutes: 24),
  ),
);

VideoPlaybackData fixture() => VideoPlaybackData()
  ..recordVideo(first, at: DateTime(2026, 11, 11))
  ..recordVideo(second, at: DateTime(2026, 11, 12))
  ..remember(
    second.id,
    const Duration(minutes: 19, seconds: 21),
    second.duration,
  )
  ..setWatched(first, true);

Widget app(Widget page, {GlobalKey? capture}) => MaterialApp(
  theme: auralisTheme(
    ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: Brightness.dark,
    ),
  ),
  home: RepaintBoundary(key: capture, child: page),
);

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['AURALIS_COLLECTION_PREVIEWS'];
  if (directory == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<void> visible(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final font = File(
      Platform.isWindows
          ? 'C:/Windows/Fonts/segoeui.ttf'
          : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    );
    if (await font.exists()) {
      await (FontLoader(
        'Segoe UI',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'Video history adapts to $size and large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final data = fixture();
        await tester.pumpWidget(
          app(VideoLibraryPage(data: data, save: () async {})),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('video-collection-header')),
          findsOneWidget,
        );
        await visible(tester, find.text(second.title));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('Video history stays readable on a phone', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey();
    await tester.pumpWidget(
      app(
        VideoLibraryPage(data: fixture(), save: () async {}),
        capture: key,
      ),
    );
    await tester.pumpAndSettle();
    await capture(tester, key, 'video-history-phone');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'History date groups preserve resume points, watched controls and clear confirmation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final data = fixture();
      final changes = ValueNotifier(0);
      addTearDown(changes.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        app(
          VideoLibraryPage(data: data, save: () async {}, changes: changes),
          capture: key,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('19:21 / 24:00'), findsOneWidget);
      expect(find.byTooltip('Mark as unwatched'), findsOneWidget);
      expect(
        find.byKey(ValueKey(('video-history-date', DateTime(2026, 11, 12)))),
        findsOneWidget,
      );
      expect(
        data.positions[second.id],
        const Duration(minutes: 19, seconds: 21),
      );
      await capture(tester, key, 'video-history-desktop');
      final card = find.byKey(ValueKey(second.id));
      await tester.longPress(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-item-sheet')), findsOneWidget);
      expect(find.text('Remove from history'), findsOneWidget);
      expect(find.text('Add to favorites'), findsNothing);
      expect(find.text('Add to playlist'), findsNothing);
      await tester.tap(find.text('Info'));
      await tester.pumpAndSettle();
      expect(find.text('Status'), findsOneWidget);
      await tester.tap(find.byTooltip('Close actions'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Mark as watched')),
      );
      await tester.pumpAndSettle();
      expect(data.isWatched(second), isTrue);
      expect(
        data.positions[second.id],
        const Duration(minutes: 19, seconds: 21),
      );
      expect(find.textContaining('19:21 / 24:00'), findsOneWidget);
      expect(find.byTooltip('Mark as unwatched'), findsNWidgets(2));
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byTooltip('Remove from history'),
        ),
      );
      await tester.pumpAndSettle();
      expect(data.history.containsKey(second.id), isFalse);
      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(data.history, isNotEmpty);
      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(data.history, isEmpty);
      expect(data.positions, isEmpty);
      expect(find.text('A fresh start'), findsOneWidget);
      data.recordVideo(second);
      changes.value++;
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(second.id)), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
    },
  );
}
