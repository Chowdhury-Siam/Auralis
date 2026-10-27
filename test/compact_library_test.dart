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
  testWidgets(
    'compact collection dropdown fits narrow windows with fallback fonts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = MemorySettings()
        ..compactLibrary = true
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
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final menu = find.byKey(const ValueKey('library-collection-menu'));
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
        expect(rect.right, lessThanOrEqualTo(320));
        if (collection == 'Recently played') {
          await tester.tap(find.text('Clear history'));
          await tester.pumpAndSettle();
          expect(settings.recentIds, isEmpty);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
