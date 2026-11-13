import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/models.dart';
import 'package:auralis/music_playlist_widgets.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _PlaylistTelegram extends TelegramService {
  _PlaylistTelegram(this.tracks)
    : super(Directory('unused'), MemoryVault(), transport: FakeTd());
  final List<Track> tracks;
  @override
  bool get ready => true;
  @override
  Future<MusicChat?> channel(int id) async => const MusicChat(1, 'Music');
  @override
  Future<({List<Track> tracks, int nextMessageId})> music(
    int chatId,
    String title, {
    int before = 0,
    bool documents = false,
  }) async => (tracks: documents ? <Track>[] : tracks, nextMessageId: 0);
  @override
  Future<Uint8List?> cover(Track track) async => null;
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Segoe UI',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(360, 480), 2.0),
    (const Size(844, 390), 2.0),
  ]) {
    testWidgets(
      'Music playlist cards preserve search and editing at $size / $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final tracks = List.generate(
          4,
          (index) => Track(
            id: '1:$index',
            title: 'Song $index',
            artist: 'Artist',
            source: 'Music',
            duration: const Duration(minutes: 3, seconds: 42),
          ),
        );
        final ids = tracks.map((track) => track.id).toList();
        const longName =
            'A very long playlist name for quieter evenings and favorite songs';
        final settings = MemorySettings()
          ..reducedMotion = true
          ..automaticLyrics = false
          ..selectedChannels = [const MusicChat(1, 'Music')];
        settings.playlists.addAll({
          'Night drive': [...ids],
          'Unfinished ideas': [],
          longName: [ids.first, 'missing:1'],
        });
        settings.videoPlayback.putPlaylist('Video list', []);
        final audio = FakeAudio();
        final player = PlayerController(
          audio,
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        final telegram = _PlaylistTelegram(tracks);
        addTearDown(player.shutdown);
        addTearDown(telegram.shutdown);
        await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
        await tester.pumpAndSettle();

        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(finder.hitTestable(), findsOneWidget);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> showInOverview(Finder finder) async {
          final scrollable = find
              .descendant(
                of: find.byType(MusicPlaylistsView),
                matching: find.byType(Scrollable),
              )
              .first;
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            finder,
            180,
            scrollable: find
                .descendant(
                  of: find.byType(MusicPlaylistsView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }

        await tester.tap(find.byTooltip('Library').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('library-collection-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(PopupMenuItem<int>, 'Playlists'));
        await tester.pumpAndSettle();
        expect(find.byType(MusicPlaylistsView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('music-playlists-header')),
          findsOneWidget,
        );
        expect(
          size.width >= 900
              ? find.byType(AppSidebar)
              : find.byKey(const ValueKey('app-navigation')),
          findsOneWidget,
        );
        await showInOverview(find.text('Night drive'));
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(
          delegate.crossAxisCount,
          size.width == 1280
              ? 3
              : size.width == 844
              ? 2
              : 1,
        );
        await showInOverview(find.text(longName));
        final partial = find.byKey(
          const ValueKey(('music-playlist', longName)),
        );
        expect(
          find.descendant(of: partial, matching: find.text('2 songs')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: partial,
            matching: find.text('1 available in Library'),
          ),
          findsOneWidget,
        );
        await showInOverview(find.text('Unfinished ideas'));
        final emptyCard = find.byKey(
          const ValueKey(('music-playlist', 'Unfinished ideas')),
        );
        expect(
          find.descendant(of: emptyCard, matching: find.text('No songs yet')),
          findsOneWidget,
        );
        await showInOverview(find.text('Night drive'));
        await tap(find.text('Night drive'));
        expect(find.byTooltip('Back to playlists'), findsOneWidget);
        expect(find.byKey(const ValueKey('track-title-1:0')), findsOneWidget);
        expect(find.text('3:42'), findsNothing);
        await tap(find.byTooltip('Rename playlist'));
        await tester.enterText(find.byType(TextFormField), 'Evening mix');
        await tap(find.text('Rename'));
        expect(settings.playlists['Evening mix'], ids);
        await tap(find.byTooltip('Delete playlist'));
        await tap(find.text('Cancel'));
        expect(settings.playlists['Evening mix'], ids);
        await tap(find.byTooltip('Back to playlists'));

        await tester.enterText(find.byType(TextField), 'no matching playlist');
        await tester.pumpAndSettle();
        await showInOverview(find.text('No playlists found'));
        expect(find.byType(MusicPlaylistCard), findsNothing);
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        await showInOverview(find.text('Create playlist'));
        await tap(find.text('Create playlist'));
        await tester.enterText(find.byType(TextFormField), 'Fresh mix');
        await tap(find.text('Create'));
        expect(settings.playlists['Fresh mix'], isEmpty);
        await tap(find.byTooltip('Back to playlists'));
        await showInOverview(find.text('Evening mix'));
        await tap(find.text('Evening mix'));
        await tap(find.byTooltip('Delete playlist'));
        await tap(find.text('Delete'));
        expect(settings.playlists.containsKey('Evening mix'), isFalse);
        expect(settings.playlists[longName], [ids.first, 'missing:1']);
        expect(
          settings.videoPlayback.playlists.containsKey('Video list'),
          isTrue,
        );
        expect(player.queue, isEmpty);
        expect(audio.playing, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
