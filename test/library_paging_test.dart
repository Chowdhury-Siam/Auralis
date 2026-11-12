import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_theme.dart';
import 'package:auralis/library_widgets.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_library.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'collection pager follows swipe, indicator and rapid dropdown changes: reduced=$reduced',
      (tester) async {
        var selected = 0;
        late StateSetter update;
        final changes = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Scaffold(
                  body: Column(
                    children: [
                      LibraryPageIndicator(
                        labels: const ['One', 'Two', 'Three', 'Four'],
                        index: selected,
                        reducedMotion: reduced,
                        onSelected: (index) => update(() => selected = index),
                      ),
                      Expanded(
                        child: LibraryCollectionPager(
                          index: selected,
                          count: 4,
                          reducedMotion: reduced,
                          onChanged: (index) {
                            changes.add(index);
                            update(() => selected = index);
                          },
                          itemBuilder: (_, index) =>
                              Center(child: Text('Collection $index')),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        final pager = find.byType(LibraryCollectionPager);
        await tester.drag(pager, const Offset(-600, 0));
        await tester.pumpAndSettle();
        expect(selected, 1);
        expect(changes, [1]);
        await tester.tap(find.byTooltip('Show Four'));
        await tester.pumpAndSettle();
        expect(selected, 3);
        expect(changes, [
          1,
        ], reason: 'Programmatic paging must not select intermediate pages.');
        update(() => selected = 0);
        await tester.pump();
        update(() => selected = 2);
        await tester.pumpAndSettle();
        expect(selected, 2);
        final page = tester.widget<PageView>(find.byType(PageView));
        expect(page.controller!.page, 2);
        await tester.drag(
          pager,
          const Offset(-600, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(selected, 3);
        await tester.drag(pager, const Offset(-600, 0));
        await tester.pumpAndSettle();
        expect(selected, 3, reason: 'The final collection must not wrap.');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'collection paging keeps scroll positions and does not consume vertical drags',
    (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: LibraryCollectionPager(
                index: selected,
                count: 3,
                onChanged: (index) => update(() => selected = index),
                itemBuilder: (_, index) => ListView.builder(
                  key: PageStorageKey('collection-$index'),
                  itemCount: 60,
                  itemBuilder: (_, row) =>
                      SizedBox(height: 60, child: Text('Page $index row $row')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -360));
      await tester.pumpAndSettle();
      expect(selected, 0);
      final firstList = find.byKey(const PageStorageKey('collection-0'));
      double position() => tester
          .state<ScrollableState>(
            find.descendant(of: firstList, matching: find.byType(Scrollable)),
          )
          .position
          .pixels;
      final before = position();
      expect(before, greaterThan(0));
      final pager = find.byType(LibraryCollectionPager);
      await tester.drag(pager, const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.drag(pager, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(selected, 2);
      await tester.drag(pager, const Offset(600, 0));
      await tester.pumpAndSettle();
      await tester.drag(pager, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(selected, 0);
      expect(position(), closeTo(before, .1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in AppInterface.values) {
    testWidgets(
      '${mode.name} Library swipes collections and keeps navigation and playback intact',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final settings = MemorySettings()..defaultInterface = mode;
        settings.videoPlayback.putPlaylist('Watch later', []);
        settings.playlists['Evening mix'] = [];
        final audio = FakeAudio();
        final player = PlayerController(
          audio,
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: FakeTd(),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await player.shutdown();
          await telegram.shutdown();
        });
        await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
        await tester.pumpAndSettle();
        final video = mode == AppInterface.video;
        final navigation = find.byKey(
          ValueKey(video ? 'video-navigation' : 'app-navigation'),
        );
        await tester.tap(
          find.descendant(
            of: navigation,
            matching: find.byIcon(
              video ? Icons.video_library_rounded : Icons.library_music_rounded,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final pager = find.byKey(
          ValueKey(video ? 'video-library-pager' : 'music-library-pager'),
        );
        final title = find.byKey(
          ValueKey(video ? 'video-library-title' : 'page-title'),
        );
        final labels = video
            ? ['All videos', 'Playlists', 'History', 'Snapshots']
            : [
                'All songs',
                'Artists',
                'Favorites',
                'Playlists',
                'Recently played',
              ];
        for (final label in labels.skip(1)) {
          await tester.drag(pager, const Offset(-320, 0));
          if (label == 'Snapshots') {
            // Directory reads run in the real zone, unlike page animations.
            for (var frame = 0; frame < 30; frame++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 5)),
              );
              await tester.pump(const Duration(milliseconds: 16));
              if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
                break;
              }
            }
          }
          await tester.pumpAndSettle();
          expect(tester.widget<Text>(title).data, label);
          expect(navigation.hitTestable(), findsOneWidget);
          expect(player.queue, isEmpty);
          expect(audio.playing, isFalse);
          expect(tester.takeException(), isNull, reason: label);
        }
        await tester.tap(find.byTooltip('Show ${labels.first}'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, labels.first);
        await tester.tap(
          find.byKey(
            ValueKey(
              video
                  ? 'video-library-collection-menu'
                  : 'library-collection-menu',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(PopupMenuItem<int>, 'Playlists'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(title).data, 'Playlists');
        expect(
          find.text(video ? 'Watch later' : 'Evening mix'),
          findsOneWidget,
        );
        if (video) {
          await tester.ensureVisible(find.text('Watch later'));
          await tester.tap(find.text('Watch later'));
          await tester.pumpAndSettle();
          expect(find.text('Your playlist starts here'), findsOneWidget);
          await tester.drag(pager, const Offset(-320, 0));
          await tester.pumpAndSettle();
          await tester.drag(pager, const Offset(320, 0));
          await tester.pumpAndSettle();
          expect(find.text('Your playlist starts here'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Video playlists'), findsOneWidget);
          expect(tester.widget<Text>(title).data, 'Playlists');
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(tester.widget<Text>(title).data, 'All videos');
        }
        expect(
          settings.videoPlayback.playlists.containsKey('Watch later'),
          isTrue,
        );
        expect(settings.playlists.containsKey('Evening mix'), isTrue);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'embedded video playlist playback calls its owner without popping Library',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final data = VideoPlaybackData();
      final source = VideoSource.file(
        Uri.file('/movies/episode.mp4'),
        'Episode',
      );
      data.putPlaylist('Season', [source]);
      VideoSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
          home: VideoLibraryPage(
            data: data,
            save: () async {},
            pickFiles: () async => [],
            playlists: true,
            embedded: true,
            onPlay: (value) => selected = value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play playlist'));
      await tester.pumpAndSettle();
      expect(selected!.$1, [source]);
      expect(selected!.$2, 0);
      expect(find.byType(VideoLibraryPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
