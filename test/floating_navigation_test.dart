import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
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
      final list = find.ancestor(
        of: find.byKey(const ValueKey('track-title-0')),
        matching: find.byType(ListView),
      );
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      final navigation = find.byKey(const ValueKey('app-navigation'));
      final navBounds = tester.getRect(navigation);
      final floating = style != AppNavigationStyle.fullWidth;
      expect(tester.getRect(list).bottom, floating ? 844 : navBounds.top);
      expect(navBounds.bottom, 844);
      if (floating) {
        final capsule = find
            .descendant(of: navigation, matching: find.byType(Material))
            .first;
        expect(tester.getRect(capsule).bottom, lessThanOrEqualTo(844 - 24));
        final x = style == AppNavigationStyle.expressive
            ? tester.getRect(capsule).right + 4
            : 100.0;
        final gap = Offset(
          x,
          navBounds.top + (style == AppNavigationStyle.expressive ? 40 : 4),
        );
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
      player.queue.add(tracks.first);
      player.index = 0;
      player.refreshSettings();
      await tester.pumpAndSettle();
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final dock = find.byKey(const ValueKey('open-current-track'));
      expect(dock, findsOneWidget);
      expect(tester.getRect(last).bottom, lessThan(tester.getRect(dock).top));
      expect(tester.getRect(navigation), navBounds);
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-search')), findsOneWidget);
      await tester.tap(find.byTooltip('Library').first);
      await tester.pumpAndSettle();
      if (style == AppNavigationStyle.expressive) {
        await tester.tap(find.byTooltip('Search library'));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        await tester.enterText(
          find.descendant(of: dialog, matching: find.byType(TextField)),
          'Song 29',
        );
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('track-title-29')), findsOneWidget);
        expect(find.byKey(const ValueKey('track-title-1')), findsNothing);
      }
      expect(tester.widget<AppNavigation>(navigation).style, style);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
