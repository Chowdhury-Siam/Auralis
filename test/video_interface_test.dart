import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/discovery_widgets.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'telegram_video_test.dart' show channel, post;

void main() {
  setUpAll(() async {
    final font = File(
      Platform.isWindows
          ? 'C:/Windows/Fonts/segoeui.ttf'
          : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    );
    if (await font.exists()) {
      await (FontLoader('Segoe UI')
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final style in AppNavigationStyle.values) {
    testWidgets(
      'Video shares Music navigation appearance and searches channel videos: ${style.name}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final td = FakeTd();
        td.onRequest = (request) async =>
            request['@type'] == 'searchChatMessages'
            ? {
                'messages':
                    request['filter']?['@type'] == 'searchMessagesFilterVideo'
                    ? [post(30, 'Trailer.mp4')]
                    : [],
                'next_from_message_id': 0,
              }
            : null;
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: td,
        )..state = 'authorizationStateReady';
        final settings = MemorySettings()
          ..defaultInterface = AppInterface.video
          ..selectedChannels = [channel]
          ..navigationStyle = style
          ..navigationRadius = 18;
        final player = PlayerController(
          FakeAudio(),
          TelegramStreamProxy(telegram.request),
          settings,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await player.shutdown();
          await telegram.shutdown();
        });
        await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
        await tester.pumpAndSettle();
        expect(find.byType(DiscoveryHero), findsOneWidget);
        final navigation = find.byKey(const ValueKey('video-navigation'));
        expect(tester.widget<AppNavigation>(navigation).style, style);
        expect(tester.widget<AppNavigation>(navigation).radius, 18);
        if (style == AppNavigationStyle.fullWidth) {
          expect(find.byType(NavigationBar), findsOneWidget);
        } else {
          expect(find.byType(NavigationBar), findsNothing);
          expect(
            tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
            isTrue,
          );
        }
        await tester.tap(
          find.descendant(
            of: navigation,
            matching: find.byIcon(Icons.search_rounded),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextField, 'Search your videos'),
          findsOneWidget,
        );
        expect(find.byType(DiscoveryTile), findsOneWidget);
        expect(find.byType(DropdownButton<int>), findsNothing);
        await tester.tap(find.text(channel.title));
        await tester.pumpAndSettle();
        expect(tester.widget<AppNavigation>(navigation).selected, 1);
        expect(find.text('Trailer'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'trailer');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(
          td.requests.where(
            (r) =>
                r['@type'] == 'searchChatMessages' && r['query'] == 'trailer',
          ),
          hasLength(2),
        );
        expect(find.text('Trailer'), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Home hold still switches interfaces with all three navigation styles.
        final hold = await tester.startGesture(
          tester.getCenter(
            find.descendant(
              of: navigation,
              matching: find.byIcon(Icons.home_rounded),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await hold.up();
        await tester.pumpAndSettle();
        expect(find.text('Your Mix'), findsOneWidget);
        expect(
          tester
              .widget<AppNavigation>(
                find.byKey(const ValueKey('app-navigation')),
              )
              .style,
          style,
        );
      },
    );
  }

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('Video Home, Search and Library fit $size with large text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final td = FakeTd();
      td.onRequest = (request) async => request['@type'] == 'searchChatMessages'
          ? {
              'messages':
                  request['filter']?['@type'] == 'searchMessagesFilterVideo'
                  ? [post(30, 'Trailer.mp4')]
                  : [],
              'next_from_message_id': 0,
            }
          : null;
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      )..state = 'authorizationStateReady';
      final settings = MemorySettings()
        ..defaultInterface = AppInterface.video
        ..selectedChannels = [channel]
        ..videoChannelId = channel.id;
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy(telegram.request),
        settings,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await player.shutdown();
        await telegram.shutdown();
      });
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (size.width >= 900) expect(find.byType(AppSidebar), findsOneWidget);
      await tester.tap(find.byIcon(Icons.search_rounded).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Trailer'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.video_library_rounded).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Trailer'), findsOneWidget);
    });
  }
}
