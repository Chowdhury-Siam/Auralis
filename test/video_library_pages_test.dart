import 'dart:async';
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
  ..putPlaylist('Friday night', [first, second])
  ..putPlaylist('Watch next', [])
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

/// Exercise slow host I/O without changing the gallery's deletion behavior.
class _SlowSnapshotFile implements File {
  _SlowSnapshotFile(this.file, this.ioZone);
  final File file;
  final Zone ioZone;

  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  bool existsSync() => file.existsSync();
  @override
  Future<int> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      ioZone.run(() async {
        // This is wall-clock time, not Flutter's fake animation clock.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return file.delete(recursive: recursive);
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
      'Video collections adapt to $size and large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final data = fixture();
        for (final playlists in [true, false]) {
          await tester.pumpWidget(
            app(
              VideoLibraryPage(
                key: UniqueKey(),
                data: data,
                save: () async {},
                pickFiles: () async => [],
                playlists: playlists,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('video-collection-header')),
            findsOneWidget,
          );
          await visible(
            tester,
            find.text(playlists ? 'Friday night' : second.title),
          );
          expect(tester.takeException(), isNull);
        }
        final frame = File('test/fixtures/cover.png').absolute;
        final imageContext = tester.element(find.byType(VideoLibraryPage));
        await tester.runAsync(
          () => precacheImage(
            ResizeImage(FileImage(frame), width: 720),
            imageContext,
          ),
        );
        await tester.pumpWidget(
          app(VideoSnapshotsPage(loadSnapshots: () async => [frame])),
        );
        await tester.pumpAndSettle();
        await visible(tester, find.byKey(ValueKey(frame.path)));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          app(
            VideoSnapshotsPage(key: UniqueKey(), loadSnapshots: () async => []),
          ),
        );
        await tester.pumpAndSettle();
        await visible(tester, find.text('Keep a favorite frame'));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('Video collection cards stay readable on a phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final data = fixture();
    for (final playlists in [true, false]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        app(
          VideoLibraryPage(
            key: UniqueKey(),
            data: data,
            save: () async {},
            pickFiles: () async => [],
            playlists: playlists,
          ),
          capture: key,
        ),
      );
      await tester.pumpAndSettle();
      await capture(
        tester,
        key,
        playlists ? 'video-playlists-phone' : 'video-history-phone',
      );
      expect(tester.takeException(), isNull);
    }
    final frame = File('test/fixtures/cover.png').absolute;
    final imageContext = tester.element(find.byType(VideoLibraryPage));
    await tester.runAsync(
      () => precacheImage(
        ResizeImage(FileImage(frame), width: 720),
        imageContext,
      ),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      app(VideoSnapshotsPage(loadSnapshots: () async => [frame]), capture: key),
    );
    await tester.pumpAndSettle();
    await capture(tester, key, 'video-snapshots-phone');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Playlist cards keep rename, add, reorder, remove and empty states',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final data = fixture();
      final local = VideoSource.file(
        Uri.file('/movies/extra.mp4'),
        'Extra video',
      );
      var saves = 0;
      final key = GlobalKey();
      await tester.pumpWidget(
        app(
          VideoLibraryPage(
            data: data,
            playlists: true,
            save: () async {
              saves++;
            },
            pickFiles: () async => [local],
          ),
          capture: key,
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, key, 'video-playlists-desktop');
      expect(find.byType(SliverGrid), findsOneWidget);
      await tester.tap(find.byTooltip('Playlist options: Friday night'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Movie night');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(data.playlists.containsKey('Friday night'), isFalse);
      expect(data.playlists['Movie night'], [first, second]);
      await tester.tap(find.text('Movie night'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add video files'));
      await tester.pumpAndSettle();
      expect(data.playlists['Movie night'], [first, second, local]);
      tester
          .widget<SliverReorderableList>(find.byType(SliverReorderableList))
          .onReorderItem!(0, 1);
      await tester.pumpAndSettle();
      expect(data.playlists['Movie night'], [second, first, local]);
      final localCard = find.byKey(ValueKey(local.id));
      await visible(tester, localCard);
      await tester.tap(
        find.descendant(
          of: localCard,
          matching: find.byTooltip('Remove video'),
        ),
      );
      await tester.pumpAndSettle();
      expect(data.playlists['Movie night'], [second, first]);
      await tester.ensureVisible(find.byType(BackButton));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Playlist options: Movie night'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(data.playlists.containsKey('Movie night'), isTrue);
      await tester.tap(find.byTooltip('Playlist options: Movie night'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(data.playlists.containsKey('Movie night'), isFalse);
      await tester.tap(find.text('Create playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Later');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(data.playlists['Later'], isEmpty);
      expect(find.text('Your playlist starts here'), findsOneWidget);
      expect(saves, 6);
    },
  );

  testWidgets(
    'History cards preserve resume points, watched controls and clear confirmation',
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
          VideoLibraryPage(
            data: data,
            playlists: false,
            save: () async {},
            pickFiles: () async => [],
            changes: changes,
          ),
          capture: key,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Resume at 19:21'), findsOneWidget);
      expect(find.text('Watched'), findsOneWidget);
      expect(
        data.positions[second.id],
        const Duration(minutes: 19, seconds: 21),
      );
      await capture(tester, key, 'video-history-desktop');
      final card = find.byKey(ValueKey(second.id));
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byTooltip('Video actions for ${second.title}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-item-sheet')), findsOneWidget);
      expect(find.text('Remove from history'), findsOneWidget);
      expect(find.text('Add to favorites'), findsNothing);
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
      expect(data.positions.containsKey(second.id), isFalse);
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byTooltip('Video actions for ${second.title}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('media-action-remove')));
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
      expect(data.playlists, hasLength(2));
      data.recordVideo(second);
      changes.value++;
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(second.id)), findsOneWidget);
    },
  );

  testWidgets(
    'Playlist playback returns the unchanged queue and selected index',
    (tester) async {
      final data = fixture();
      VideoSelection? selection;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open collection'),
                onPressed: () async {
                  selection = await Navigator.of(context).push<VideoSelection>(
                    MaterialPageRoute(
                      builder: (_) => VideoLibraryPage(
                        data: data,
                        playlists: true,
                        save: () async {},
                        pickFiles: () async => [],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open collection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Friday night'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play playlist'));
      await tester.pumpAndSettle();
      expect(selection!.$1, [first, second]);
      expect(selection!.$2, 0);
    },
  );

  for (final slowFilesystem in [false, true]) {
    testWidgets(
      'Snapshot gallery previews originals and confirms deletion (slow filesystem: $slowFilesystem)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('auralis-frame-gallery-'),
        ))!;
        final ioZone = (await tester.runAsync(() async => Zone.current))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() => directory.delete(recursive: true));
        });
        final original = File(
          '${directory.path}/1794470400000000-Romantic_Killer_-_01-264221ms.png',
        );
        final File file = slowFilesystem
            ? _SlowSnapshotFile(original, ioZone)
            : original;
        await tester.runAsync(
          () => File('test/fixtures/cover.png').copy(file.path),
        );
        var loads = 0;
        Future<List<File>> load() async {
          loads++;
          return file.existsSync() ? [file] : [];
        }

        await tester.pumpWidget(app(const Scaffold(body: SizedBox.shrink())));
        final imageContext = tester.element(find.byType(Scaffold).first);
        await tester.runAsync(() async {
          await precacheImage(FileImage(file), imageContext);
          await precacheImage(
            ResizeImage(FileImage(file), width: 720),
            imageContext,
          );
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          app(VideoSnapshotsPage(loadSnapshots: load), capture: key),
        );
        await tester.pumpAndSettle();
        expect(find.text('Frame at 4:24'), findsOneWidget);
        expect(find.text(first.title), findsOneWidget);
        await capture(tester, key, 'video-snapshots-desktop');
        await tester.tap(find.text(first.title));
        await tester.pumpAndSettle();
        expect(find.text('Export PNG'), findsOneWidget);
        expect(find.text('Romantic_Killer_-_01-264221ms.png'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Delete snapshot'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(file.existsSync(), isTrue);
        expect(
          loads,
          1,
          reason: 'Cancel must not delete or reload the gallery.',
        );
        await tester.tap(find.byTooltip('Delete snapshot'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
        final waiting = Stopwatch()..start();
        // pumpAndSettle only waits for Flutter frames, not host filesystem I/O.
        // Yield real time and pump its completion back into the widget test zone.
        while (loads < 2 && waiting.elapsed < const Duration(seconds: 10)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          loads,
          2,
          reason: 'Timed out waiting for snapshot deletion and gallery reload.',
        );
        await tester.pumpAndSettle();
        expect(file.existsSync(), isFalse);
        expect(find.text('Keep a favorite frame'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Snapshot failures keep a retry action and do not modify files', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      app(
        VideoSnapshotsPage(
          loadSnapshots: () async {
            if (attempts++ == 0) throw const FileSystemException('Unavailable');
            return [];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load snapshots'), findsOneWidget);
    await tester.tap(find.byTooltip('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Keep a favorite frame'), findsOneWidget);
  });
}
