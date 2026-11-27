import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/discovery_widgets.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/stats_view.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class NavigationTelegram extends TelegramService {
  NavigationTelegram(this.tracks)
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
  for (final style in AppNavigationStyle.values) {
    testWidgets('navigation gaps reveal and scroll the page: ${style.label}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final tracks = List.generate(
        30,
        (i) => Track(
          id: '$i',
          title: 'Song ${i.toString().padLeft(2, '0')}',
          artist: 'Artist',
          source: 'Music',
        ),
      );
      final settings = MemorySettings()
        ..navigationStyle = style
        ..selectedChannels = [const MusicChat(1, 'Music')]
        ..automaticLyrics = false;
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = NavigationTelegram(tracks);
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      final list = find.byKey(
        const PageStorageKey(('music-collection', 'All songs')),
      );
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      final navigation = find.byKey(const ValueKey('app-navigation'));
      expect(
        find.descendant(
          of: navigation,
          matching: find.byTooltip('Now playing'),
        ),
        findsNothing,
      );
      final navBounds = tester.getRect(navigation);
      final floating = style != AppNavigationStyle.fullWidth;
      expect(tester.getRect(list).bottom, floating ? 844 : navBounds.top);
      expect(navBounds.bottom, 844);
      if (floating) {
        final capsule = find
            .descendant(of: navigation, matching: find.byType(Material))
            .first;
        expect(tester.getRect(capsule).bottom, lessThanOrEqualTo(844 - 24));
        final gap = Offset(100, navBounds.top + 4);
        // A drag through the unpainted gap reaches the real list underneath.
        await tester.dragFrom(gap, const Offset(0, -90));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
      }
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final last = find.byKey(const ValueKey('track-title-29'));
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(last).bottom, lessThan(navBounds.top));
      final offsetBeforeDock = position.pixels;
      player.queue.add(tracks.first);
      player.index = 0;
      player.refreshSettings();
      await tester.pumpAndSettle();
      final positionWithDock = tester
          .state<ScrollableState>(scrollable)
          .position;
      expect(positionWithDock.pixels, closeTo(offsetBeforeDock, 1));
      positionWithDock.jumpTo(positionWithDock.maxScrollExtent);
      await tester.pumpAndSettle();
      final dock = find.byKey(const ValueKey('open-current-track'));
      expect(dock, findsOneWidget);
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(last).bottom, lessThan(tester.getRect(dock).top));
      expect(tester.getRect(navigation), navBounds);
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-search')), findsNothing);
      expect(find.byKey(const ValueKey('settings-general')), findsOneWidget);
      await tester.tap(find.byTooltip('Library').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Browse channels'), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      await tester.tap(find.byTooltip('Search channels'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search channels'),
        'Missing',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching channels'), findsOneWidget);
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search Library'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Song 29');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('track-title-29')), findsOneWidget);
      expect(find.byKey(const ValueKey('track-title-1')), findsNothing);
      expect(tester.widget<AppNavigation>(navigation).style, style);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Home connects the daily mix, history, stats and Search groups', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tracks = List.generate(
      6,
      (i) => Track(
        id: '1:$i',
        title: 'Track $i',
        artist: i == 5 ? 'Zephyr' : (i.isEven ? 'Lunar' : 'Solar'),
        source: 'Music',
      ),
    );
    final settings = MemorySettings()
      ..reducedMotion = true
      ..automaticLyrics = false
      ..recentIds = [tracks.first.id]
      ..selectedChannels = [const MusicChat(1, 'Music')];
    settings.listening.record(tracks.first, 125000, 2, DateTime.now());
    final player = PlayerController(
      FakeAudio(),
      TelegramStreamProxy((_) async => {}),
      settings,
    );
    final telegram = NavigationTelegram(tracks);
    addTearDown(player.shutdown);
    addTearDown(telegram.shutdown);
    await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
    await tester.pumpAndSettle();
    expect(find.text('Your Mix'), findsOneWidget);
    expect(find.text('Daily Mix'), findsOneWidget);
    final expand = find.text('Show full mix (6)');
    await tester.drag(
      find.byKey(const PageStorageKey('home-scroll')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    expect(expand.hitTestable(), findsOneWidget);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.text('Show fewer tracks'), findsOneWidget);

    final stats = find.byTooltip('Open listening stats');
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(stats);
    await tester.pumpAndSettle();
    expect(find.byType(StatsDataDialog), findsOneWidget);
    expect(find.text('2m 5s'), findsWidgets);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    settings.listening.record(tracks[1], 30000, 2, DateTime.now());
    settings.listening.record(tracks[3], 30000, 1, DateTime.now());
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-collection-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    final grid = find.byKey(const PageStorageKey('music-artists-grid'));
    final lunar = find.widgetWithText(DiscoveryTile, 'Lunar');
    final solar = find.widgetWithText(DiscoveryTile, 'Solar');
    expect(tester.widget(grid), isA<GridView>());
    expect(
      find.descendant(of: lunar, matching: find.text('3 songs')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: solar, matching: find.text('2 songs')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(DiscoveryTile, 'Zephyr'),
        matching: find.text('1 song'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Show list'), findsNothing);
    expect(find.byTooltip('Show grid'), findsNothing);
    expect(tester.getTopLeft(lunar).dx, lessThan(tester.getTopLeft(solar).dx));
    await tester.tap(find.byTooltip('Sort Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most played'));
    await tester.pumpAndSettle();
    expect(settings.librarySort, LibrarySort.mostPlayed);
    expect(tester.getTopLeft(solar).dx, lessThan(tester.getTopLeft(lunar).dx));
    await tester.tap(find.byTooltip('Search Library'));
    await tester.pumpAndSettle();
    expect(find.text('Search your Artists'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'sol');
    await tester.pumpAndSettle();
    expect(lunar, findsNothing);
    await tester.tap(solar);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-title-1:1')), findsOneWidget);
    expect(find.byKey(const ValueKey('track-title-1:0')), findsNothing);
    await tester.tap(find.byTooltip('Back to artists'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Lunar');
    await tester.pumpAndSettle();
    await tester.tap(lunar);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-title-1:0')), findsOneWidget);
    expect(find.byKey(const ValueKey('track-title-1:1')), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    const rightEdge = 1920 - 26;
    expect(tester.getRect(find.byType(DiscoveryHero)).right, rightEdge);
    await tester.tap(find.byTooltip('Browse'));
    await tester.pumpAndSettle();
    final searchButton = find.byTooltip('Search channels');
    final search = find.widgetWithText(TextField, 'Search channels');
    expect(search, findsNothing);
    final header = tester.getRect(find.byType(BrowseChannelsHeader));
    expect(header.right, rightEdge);
    expect(tester.getRect(searchButton).right, closeTo(header.right - 14, 4));
    expect(tester.getRect(find.byType(GridView)).right, rightEdge);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
