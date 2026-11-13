import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  // Keep Flutter's wide fallback test font: loading a host font hid this overflow.
  testWidgets('search and collection use separate cards on phone and desktop', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final settings = MemorySettings()
      ..navigationStyle = AppNavigationStyle.expressive
      ..recentIds = ['saved'];
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
    for (final size in [
      const Size(320, 568),
      const Size(390, 844),
      const Size(1280, 800),
    ]) {
      tester.view.physicalSize = size;
      settings.recentIds = ['saved'];
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final menu = find.byKey(const ValueKey('library-collection-menu'));
      final search = find.byType(TextField);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(search, findsOneWidget);
      expect(find.descendant(of: search, matching: menu), findsNothing);
      expect(
        find.byKey(const ValueKey('mini-now-playing-layout')),
        findsNothing,
      );
      for (final collection in [
        'Recently played',
        'Favorites',
        'Playlists',
        'All songs',
      ]) {
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text(collection).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: collection);
        final rect = tester.getRect(menu);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        final searchBounds = tester.getRect(search);
        expect(find.byTooltip('Shuffle collection'), findsNothing);
        expect(rect.bottom, lessThan(searchBounds.top));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          collection,
        );
        if (collection == 'Recently played') {
          expect(find.text('Clear history'), findsNothing);
          expect(settings.recentIds, ['saved']);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.enterText(search, 'song');
      await tester.pumpAndSettle();
      if (size.width == 320) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        expect(menu, findsNothing);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.widget<TextField>(search).controller!.text, 'song');
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(menu, findsOneWidget);
      }
      expect(find.byTooltip('Clear search').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(tester.takeException(), isNull, reason: '$size search and clear');
    }
    await tester.pumpWidget(const SizedBox());
  });
}
