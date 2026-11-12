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
      'Video Browse shares Music navigation appearance and searches for channels: ${style.name}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = const FakeViewPadding(top: 32, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 34);
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
                    ? [
                        post(30, 'Full movie.mp4'),
                        for (var index = 1; index <= 18; index++)
                          post(
                            100 + index,
                            'Video ${index.toString().padLeft(2, '0')}.mp4',
                          ),
                      ]
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
          ..selectedChannels = [channel, const MusicChat(-100456, 'Music only')]
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
        final musicShortcut = find.widgetWithIcon(
          IconButton,
          Icons.music_note_rounded,
        );
        expect(musicShortcut, findsNothing);
        final navigation = find.byKey(const ValueKey('video-navigation'));
        if (style == AppNavigationStyle.fullWidth) {
          expect(
            tester.widget<NavigationBar>(find.byType(NavigationBar))
                .destinations.whereType<NavigationDestination>()
                .map((destination) => destination.label),
            contains('Browse'),
          );
        } else {
          expect(
            find.descendant(of: navigation, matching: find.byTooltip('Browse')),
            findsOneWidget,
          );
        }
        expect(tester.widget<AppNavigation>(navigation).style, style);
        expect(tester.widget<AppNavigation>(navigation).radius, 18);
        final floating = style != AppNavigationStyle.fullWidth;
        expect(
          find.byType(NavigationBar),
          floating ? findsNothing : findsOneWidget,
        );
        final scaffold = find.byType(Scaffold).first;
        expect(tester.widget<Scaffold>(scaffold).extendBody, floating);

        void expectVideoViewport() {
          final viewport = find.byType(CustomScrollView);
          final bottom = tester.getRect(viewport).bottom;
          final navTop = tester.getRect(navigation).top;
          expect(tester.widget<Scaffold>(scaffold).extendBody, floating);
          expect(bottom, floating ? tester.view.physicalSize.height : navTop);
        }

        await tester.tap(
          find.descendant(
            of: navigation,
            matching: find.byIcon(Icons.explore_outlined),
          ),
        );
        await tester.pumpAndSettle();
        final searchField = find.widgetWithText(TextField, 'Search channels');
        expect(searchField, findsOneWidget);
        expect(find.byTooltip('Choose video channel'), findsNothing);
        expect(find.text(channel.title), findsOneWidget);
        expect(find.text('Music only'), findsOneWidget);
        expect(settings.videoChannelId, isNull);

        await tester.enterText(searchField, 'Full movie');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('No matching channels'), findsOneWidget);
        expect(
          td.requests.where((r) => r['@type'] == 'searchChatMessages'),
          isEmpty,
        );

        await tester.enterText(searchField, channel.title.toUpperCase());
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(tester.widget<AppNavigation>(navigation).selected, 1);
        expect(find.text('Full movie'), findsOneWidget);
        expect(find.byTooltip('Back to channels'), findsOneWidget);
        expect(settings.videoChannelId, channel.id);
        final videoRow = find.byKey(ValueKey('${channel.id}:30'));
        final searchRowSize = tester.getSize(videoRow);
        expectVideoViewport();

        await tester.tap(
          find.descendant(
            of: navigation,
            matching: find.byIcon(Icons.video_library_rounded),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Choose video channel'), findsNothing);
        expect(find.text('Full movie'), findsOneWidget);
        expect(musicShortcut, findsNothing);
        expect(tester.getSize(videoRow), searchRowSize);
        expectVideoViewport();
        final list = find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        );
        final lastVideo = find.byKey(ValueKey('${channel.id}:118'));
        await tester.scrollUntilVisible(lastVideo, 420, scrollable: list);
        final position = tester.state<ScrollableState>(list).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(lastVideo.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(lastVideo).bottom,
          lessThan(tester.getRect(navigation).top),
        );
        expect(
          td.requests
              .where((r) => r['@type'] == 'searchChatMessages')
              .map((r) => r['query']),
          ['', ''],
        );
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

  testWidgets(
    'find and switch video channels, sort videos and use square thumbnails',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const archive = MusicChat(-100456, 'Series archive');
      final td = FakeTd();
      td.onRequest = (request) async {
        if (request['@type'] != 'searchChatMessages') return null;
        return {
          'messages': request['filter']?['@type'] == 'searchMessagesFilterVideo'
              ? [
                  if (request['chat_id'] == archive.id)
                    {...post(55, 'Archive episode.mp4'), 'chat_id': archive.id}
                  else ...[
                    post(40, 'Zebra.mp4'),
                    post(30, 'Alpha.mp4'),
                  ],
                ]
              : [],
          'next_from_message_id': 0,
        };
      };
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      )..state = 'authorizationStateReady';
      final settings = MemorySettings()
        ..defaultInterface = AppInterface.video
        ..selectedChannels = [channel, archive]
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
      final navigation = find.byKey(const ValueKey('video-navigation'));
      Future<void> openTab(IconData icon) async {
        await tester.tap(
          find.descendant(of: navigation, matching: find.byIcon(icon)),
        );
        await tester.pumpAndSettle();
      }

      await openTab(Icons.video_library_rounded);
      final alpha = find.text('Alpha'), zebra = find.text('Zebra');
      expect(settings.librarySort, LibrarySort.title);
      expect(
        tester.getTopLeft(alpha).dy,
        lessThan(tester.getTopLeft(zebra).dy),
      );
      final thumbnail = find.descendant(
        of: find.byKey(ValueKey('${channel.id}:30')),
        matching: find.byType(ClipRRect),
      );
      expect(thumbnail, findsOneWidget);
      final dimensions = tester.getSize(thumbnail);
      expect(dimensions.width, dimensions.height);

      await tester.tap(find.byTooltip('Sort Library'));
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      final theme = Theme.of(tester.element(dialog));
      final material = find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.card,
        ),
      );
      expect(
        tester.widget<Material>(material.first).color,
        theme.colorScheme.surfaceContainerHigh,
      );
      expect(
        tester.widget<Material>(material.first).shape,
        theme.dialogTheme.shape,
      );
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Title (A–Z)'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ListTile, 'Newest first'));
      await tester.pumpAndSettle();
      expect(settings.librarySort, LibrarySort.newest);
      expect(
        tester.getTopLeft(zebra).dy,
        lessThan(tester.getTopLeft(alpha).dy),
      );

      await openTab(Icons.explore_outlined);
      Finder channelRow(MusicChat chat) => find.byKey(ValueKey(chat.id));
      Finder selectedIn(MusicChat chat) => find.descendant(
        of: channelRow(chat),
        matching: find.text('Selected in Library'),
      );
      expect(find.text('Browse channels'), findsOneWidget);
      expect(find.byType(DiscoveryTile), findsNWidgets(2));
      expect(
        tester.getTopLeft(channelRow(channel)).dy,
        tester.getTopLeft(channelRow(archive)).dy,
      );
      expect(selectedIn(channel), findsOneWidget);
      expect(selectedIn(archive), findsNothing);
      final searchesBefore = td.requests.length;
      await tester.enterText(
        find.widgetWithText(TextField, 'Search channels'),
        'ARCHI',
      );
      await tester.pumpAndSettle();
      expect(find.text('Matching channels'), findsOneWidget);
      expect(find.byType(DiscoveryTile), findsOneWidget);
      await tester.tap(find.byTooltip('Show list'));
      await tester.pumpAndSettle();
      expect(find.byType(DiscoveryTile), findsNothing);
      expect(td.requests, hasLength(searchesBefore));
      expect(find.text(channel.title), findsNothing);
      expect(
        find.descendant(
          of: channelRow(archive),
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
        findsNothing,
      );
      await tester.tap(find.text(archive.title));
      await tester.pumpAndSettle();
      expect(tester.widget<AppNavigation>(navigation).selected, 1);
      expect(find.text('Archive episode'), findsOneWidget);
      expect(alpha, findsNothing);
      expect(settings.videoChannelId, archive.id);

      await tester.tap(find.byTooltip('Back to channels'));
      await tester.pumpAndSettle();
      final searchField = find.widgetWithText(TextField, 'Search channels');
      expect(selectedIn(archive), findsOneWidget);
      expect(
        find.descendant(
          of: channelRow(archive),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(searchField).controller!.text, 'ARCHI');
      await tester.tap(find.byTooltip('Show grid'));
      await tester.pumpAndSettle();
      expect(find.byType(DiscoveryTile), findsOneWidget);
      expect(selectedIn(archive), findsOneWidget);
      expect(tester.widget<TextField>(searchField).controller!.text, 'ARCHI');
      await tester.enterText(searchField, 'cine');
      await tester.pumpAndSettle();
      expect(find.text(archive.title), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(settings.videoChannelId, channel.id);
      expect(find.text('Archive episode'), findsNothing);
      expect(
        tester.getTopLeft(zebra).dy,
        lessThan(tester.getTopLeft(alpha).dy),
      );
      await openTab(Icons.video_library_rounded);
      expect(find.text('Archive episode'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('Video Home, Browse and Library fit $size with large text', (
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
        ..selectedChannels = [
          channel,
          for (var i = 0; i < 18; i++)
            MusicChat(i + 1000, 'Long Telegram channel title number ${i + 1}'),
        ]
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
      const libraryOptions = ['Playlists', 'History', 'Snapshots'];
      for (final option in libraryOptions) {
        expect(find.text(option), findsNothing);
      }
      final optionsMenu = find.byTooltip('Library options');
      expect(optionsMenu, findsNothing);
      if (size.width >= 900) expect(find.byType(AppSidebar), findsOneWidget);
      await tester.tap(find.byIcon(Icons.explore_outlined));
      await tester.pumpAndSettle();
      final searchField = find.widgetWithText(TextField, 'Search channels');
      expect(searchField, findsOneWidget);
      expect(find.text('Trailer'), findsNothing);
      await tester.enterText(searchField, 'number 18');
      await tester.pumpAndSettle();
      final lastChannel = find.text('Long Telegram channel title number 18');
      expect(lastChannel.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Open Telegram link'), findsNothing);
      await tester.tap(find.byIcon(Icons.video_library_rounded).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Trailer'), findsOneWidget);
      expect(optionsMenu.hitTestable(), findsOneWidget);
      await tester.tap(optionsMenu);
      await tester.pumpAndSettle();
      for (final option in libraryOptions) {
        expect(find.text(option).hitTestable(), findsOneWidget);
      }
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Video history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
