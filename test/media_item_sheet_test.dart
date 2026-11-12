import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app_theme.dart';
import 'package:auralis/media_item_sheet.dart';
import 'package:auralis/models.dart';
import 'package:auralis/video_library.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const track = Track(
  id: '-1001:1',
  title: 'A very long music and video item title',
  artist: 'Artist',
  source: 'Channel',
  duration: Duration(minutes: 4),
  mime: 'audio/flac',
);
const actions = [
  MediaItemAction('play', 'Play', Icons.play_arrow_rounded, primary: true),
  MediaItemAction(
    'favorite',
    'Add to favorites',
    Icons.favorite_border_rounded,
  ),
  MediaItemAction('queue', 'Add to queue', Icons.queue_music_rounded),
  MediaItemAction('next', 'Play next', Icons.playlist_play_rounded),
  MediaItemAction('playlist', 'Add to playlist', Icons.playlist_add_rounded),
  MediaItemAction(
    'remove',
    'Remove from playlist',
    Icons.remove_circle_outline_rounded,
    destructive: true,
  ),
];

Widget host(Future<void> Function(BuildContext) open) => MaterialApp(
  theme: auralisTheme(
    ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: Brightness.dark,
    ),
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => open(context),
        child: const Text('Open actions'),
      ),
    ),
  ),
);

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
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

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('item action sheet preview at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: host((context) async {
            await showMediaItemSheet(
              context: context,
              title: 'Feel Invincible',
              subtitle: 'Skillet · Unleashed',
              artwork: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.deepOrange, Colors.deepPurple],
                  ),
                ),
                child: Icon(
                  Icons.music_note_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              ),
              actions: actions,
              details: mediaItemDetails(track, video: false),
            );
          }),
        ),
      );
      await tester.tap(find.text('Open actions'));
      await tester.pumpAndSettle();
      final directory = Platform.environment['AURALIS_ITEM_PREVIEWS'];
      if (directory != null) {
        final render =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(directory).create(recursive: true);
            await File('$directory/item-actions-${size.width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      expect(tester.takeException(), isNull);
    });
  }
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'item sheet Options and Info fit $size with large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        String? choice;
        await tester.pumpWidget(
          host((context) async {
            choice = await showMediaItemSheet(
              context: context,
              title: track.title,
              subtitle: '${track.artist} · ${track.source}',
              artwork: const ColoredBox(color: Colors.purple),
              actions: actions,
              details: mediaItemDetails(track, video: false),
            );
          }),
        );
        await tester.tap(find.text('Open actions'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('media-item-sheet')), findsOneWidget);
        expect(
          find.byType(size.width < 700 ? BottomSheet : Dialog),
          findsOneWidget,
        );
        expect(choice, isNull);
        await reveal(tester, find.text('Info'));
        await tester.tap(find.text('Info'));
        await tester.pumpAndSettle();
        expect(find.text('Artist'), findsWidgets);
        expect(find.byKey(const ValueKey('media-action-play')), findsNothing);
        expect(choice, isNull);
        await reveal(tester, find.text('Options'));
        await tester.tap(find.text('Options'));
        await tester.pumpAndSettle();
        final next = find.byKey(const ValueKey('media-action-next'));
        await reveal(tester, next);
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(choice, 'next');
        expect(find.byKey(const ValueKey('media-item-sheet')), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('dismissing a sheet never chooses an action', (tester) async {
    String? choice;
    await tester.pumpWidget(
      host((context) async {
        choice = await showMediaItemSheet(
          context: context,
          title: track.title,
          subtitle: track.source,
          artwork: const SizedBox(),
          actions: actions,
          details: mediaItemDetails(track, video: false),
        );
      }),
    );
    await tester.tap(find.text('Open actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close actions'));
    await tester.pumpAndSettle();
    expect(choice, isNull);
  });

  testWidgets('video actions stay mode-specific and contextual', (
    tester,
  ) async {
    final data = VideoPlaybackData();
    const source = VideoSource.telegram(track);
    await tester.pumpWidget(
      host((context) async {
        await showVideoItemSheet(
          context: context,
          source: source,
          data: data,
          playNext: true,
          removeLabel: 'Remove from queue',
        );
      }),
    );
    await tester.tap(find.text('Open actions'));
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Remove from queue'), findsOneWidget);
    expect(find.text('Mark as watched'), findsOneWidget);
    expect(find.text('Add to favorites'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    await tester.tap(find.byTooltip('Close actions'));
    await tester.pumpAndSettle();
    final local = VideoSource.file(Uri.file('/movies/local.mp4'), 'Local');
    await tester.pumpWidget(
      host((context) async {
        await showVideoItemSheet(context: context, source: local, data: data);
      }),
    );
    await tester.tap(find.text('Open actions'));
    await tester.pumpAndSettle();
    expect(find.text('Add to playlist'), findsOneWidget);
    expect(find.text('Play next'), findsNothing);
    expect(find.text('Mark as watched'), findsNothing);
    expect(find.text('Remove from queue'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
