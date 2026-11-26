import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/channel_metadata.dart';
import 'package:auralis/channel_metadata_view.dart';
import 'package:auralis/library_widgets.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'telegram_video_test.dart' show channel, post;

class _BrowseMetadata extends ChannelMetadataRepository {
  _BrowseMetadata(this.channelId) : super(Directory('unused'));

  static const posterUrl = 'https://example.test/series-poster.png';
  final int channelId;
  final lookups = <int>[];

  @override
  Future<MetadataMatch> identify(int id, String name) async {
    lookups.add(id);
    return identifySaved(id);
  }

  @override
  Future<MetadataMatch> identifySaved(int id) async => id == channelId
      ? const MetadataMatch(
          selected: ChannelTitle(
            id: '1',
            provider: 'AniList',
            title: 'Archive series',
            cover: posterUrl,
          ),
        )
      : const MetadataMatch();

  @override
  Future<File?> image(String url) async => File('test/fixtures/cover.png');
}

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
        expect(find.byKey(const ValueKey('video-home-hero')), findsOneWidget);
        expect(find.byTooltip('Open video files'), findsNothing);
        expect(find.byIcon(Icons.folder_open_rounded), findsNothing);
        expect(find.byTooltip('Settings'), findsNothing);
        final musicShortcut = find.widgetWithIcon(
          IconButton,
          Icons.music_note_rounded,
        );
        expect(musicShortcut, findsNothing);
        final navigation = find.byKey(const ValueKey('video-navigation'));
        if (style == AppNavigationStyle.fullWidth) {
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .destinations
                .whereType<NavigationDestination>()
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
        expect(find.byTooltip('Settings'), findsNothing);
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
        expect(find.byTooltip('Refresh videos'), findsNothing);
        expect(find.byType(RefreshIndicator), findsOneWidget);
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
        final libraryRowSize = tester.getSize(videoRow);
        expect(libraryRowSize.height, searchRowSize.height);
        expect(libraryRowSize.width, searchRowSize.width - 16);
        expect(find.byType(LibraryCollectionMenu<int>), findsOneWidget);
        expect(
          find.widgetWithText(TextField, 'Search your videos'),
          findsNothing,
        );
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
    'filter Browse by Telegram chat folders, switch channels and sort videos',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const archive = MusicChat(-100456, 'Series archive');
      final metadata = _BrowseMetadata(archive.id);
      addTearDown(metadata.close);
      final td = FakeTd();
      const movies = {'@type': 'chatListFolder', 'chat_folder_id': 7};
      const series = {'@type': 'chatListFolder', 'chat_folder_id': 8};
      Json folder(int id, String name) => {
        'id': id,
        'name': {
          'text': {'text': name},
        },
      };
      void publishChannel(MusicChat chat, List<Json> lists) => td.events.add({
        '@type': 'updateNewChat',
        'chat': {
          'id': chat.id,
          'title': chat.title,
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
          'chat_lists': lists,
        },
      });
      var seriesPages = 0;
      td.onRequest = (request) async {
        if (request['@type'] == 'loadChats' &&
            request['chat_list']['@type'] == 'chatListFolder') {
          if (request['chat_list']['chat_folder_id'] == 8) {
            seriesPages++;
            if (seriesPages == 2) publishChannel(archive, [series]);
            if (seriesPages <= 2) return {'@type': 'ok'};
          }
          throw TdException(404, 'No more chats');
        }
        if (request['@type'] == 'getChatMessageCount') {
          expect(request['filter']['@type'], 'searchMessagesFilterVideo');
          return {'count': 4};
        }
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
      final directory = Directory.systemTemp.createTempSync('auralis-folders-');
      final telegram = TelegramService(directory, MemoryVault(), transport: td);
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
        directory.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await telegram.start(
          apiId: 12345,
          apiHash: 'abcdef0123456789abcdef0123456789',
        );
        td.auth('authorizationStateReady');
        await telegram.refreshChats();
      });
      expect(telegram.error, isNull);
      await tester.pumpWidget(
        AuralisApp(
          player: player,
          telegram: telegram,
          channelMetadata: metadata,
        ),
      );
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
      await tester.tap(find.byTooltip('Video actions for Alpha'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-item-sheet')), findsOneWidget);
      expect(find.text('Mark as watched'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('media-action-watched')));
      await tester.pumpAndSettle();
      final alphaSource = VideoSource.telegram(
        Track(
          id: '${channel.id}:30',
          title: 'Alpha',
          artist: '',
          source: channel.title,
        ),
      );
      expect(settings.videoPlayback.isWatched(alphaSource), isTrue);
      await tester.tap(find.byTooltip('Video actions for Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as unwatched'));
      await tester.pumpAndSettle();
      expect(settings.videoPlayback.isWatched(alphaSource), isFalse);
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
      expect(settings.videoPlayback.librarySort, LibrarySort.newest);
      expect(
        settings.librarySort,
        LibrarySort.title,
        reason: 'Video sorting must not change Music sorting',
      );
      expect(
        tester.getTopLeft(zebra).dy,
        lessThan(tester.getTopLeft(alpha).dy),
      );

      expect(find.byKey(const ValueKey('video-library-search')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Clear search'), findsNothing);
      expect(find.byTooltip('Shuffle collection'), findsNothing);
      expect(alpha, findsOneWidget);
      expect(zebra, findsOneWidget);

      await openTab(Icons.explore_outlined);
      Finder channelRow(MusicChat chat) => find.byKey(ValueKey(chat.id));
      Finder countIn(MusicChat chat, String label) =>
          find.descendant(of: channelRow(chat), matching: find.text(label));
      expect(find.text('Browse channels'), findsOneWidget);
      final grid = find.byType(GridView);
      expect(grid, findsOneWidget);
      final poster = tester.getSize(channelRow(archive));
      expect(poster.width / poster.height, closeTo(2 / 3, .01));
      final artwork = find.descendant(
        of: channelRow(archive),
        matching: find.byType(MetadataArtwork),
      );
      expect(
        tester.widget<MetadataArtwork>(artwork).url,
        _BrowseMetadata.posterUrl,
      );
      expect(metadata.lookups, isNot(contains(archive.id)));
      expect(
        tester.getTopLeft(channelRow(channel)).dy,
        tester.getTopLeft(channelRow(archive)).dy,
      );
      expect(countIn(channel, '2 videos'), findsOneWidget);
      expect(countIn(archive, '≈ 4 videos'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      publishChannel(channel, [movies]);
      td.events.add({
        '@type': 'updateChatFolders',
        'chat_folders': [folder(8, 'Series'), folder(7, 'Movies')],
      });
      await tester.pumpAndSettle();
      final seriesChip = find.widgetWithText(ChoiceChip, 'Series');
      final moviesChip = find.widgetWithText(ChoiceChip, 'Movies');
      expect(
        tester.getTopLeft(seriesChip).dx,
        lessThan(tester.getTopLeft(moviesChip).dx),
      );
      expect(find.widgetWithText(ChoiceChip, 'All channels'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Recently opened'), findsNothing);
      await tester.tap(moviesChip);
      await tester.pumpAndSettle();
      expect(channelRow(channel), findsOneWidget);
      expect(channelRow(archive), findsNothing);
      await tester.tap(moviesChip);
      await tester.pumpAndSettle();
      expect(channelRow(channel), findsOneWidget);
      expect(channelRow(archive), findsOneWidget);
      await tester.tap(seriesChip);
      await tester.pumpAndSettle();
      expect(seriesPages, 3);
      expect(channelRow(channel), findsNothing);
      expect(channelRow(archive), findsOneWidget);
      td.events.add({
        '@type': 'updateChatRemovedFromList',
        'chat_id': archive.id,
        'chat_list': series,
      });
      await tester.pumpAndSettle();
      expect(channelRow(archive), findsNothing);
      expect(find.text('No channels in this folder'), findsOneWidget);
      td.events.add({
        '@type': 'updateChatAddedToList',
        'chat_id': archive.id,
        'chat_list': series,
      });
      await tester.pumpAndSettle();
      expect(channelRow(archive), findsOneWidget);
      final searchesBefore = td.requests.length;
      final searchField = find.widgetWithText(TextField, 'Search channels');
      await tester.enterText(searchField, 'CINE');
      await tester.pumpAndSettle();
      expect(channelRow(channel), findsNothing);
      expect(find.text('No matching channels in this folder'), findsOneWidget);
      await tester.enterText(searchField, 'ARCHI');
      await tester.pumpAndSettle();
      expect(find.text('Matching channels'), findsOneWidget);
      expect(grid, findsOneWidget);
      await tester.tap(find.byTooltip('Show list'));
      await tester.pumpAndSettle();
      expect(grid, findsNothing);
      expect(td.requests, hasLength(searchesBefore));
      expect(find.text(channel.title), findsNothing);
      int chatRefreshes() => td.requests
          .where((request) => request['@type'] == 'loadChats')
          .length;
      final listRefreshes = chatRefreshes();
      await tester.drag(find.text(archive.title), const Offset(0, 320));
      await tester.pumpAndSettle();
      expect(chatRefreshes(), greaterThan(listRefreshes));
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
      expect(countIn(archive, '1 video'), findsOneWidget);
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
      expect(grid, findsOneWidget);
      expect(countIn(archive, '1 video'), findsOneWidget);
      expect(tester.widget<TextField>(searchField).controller!.text, 'ARCHI');
      td.events.add({
        '@type': 'updateChatFolders',
        'chat_folders': [folder(7, 'Movies')],
      });
      await tester.pumpAndSettle();
      expect(seriesChip, findsNothing);
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

  test('deleted Video channels are remembered on this device', () async {
    final directory = await Directory.systemTemp.createTemp('video-browse-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/settings.json');
    final settings = AppSettings(file);
    await settings.save();
    final loaded = AppSettings(file);
    await loaded.load();
    expect(loaded.hiddenVideoChannelIds, isEmpty);
    loaded.hiddenVideoChannelIds.add(channel.id);
    await loaded.save();
    final restored = AppSettings(file);
    await restored.load();
    expect(restored.hiddenVideoChannelIds, {channel.id});
  });

  testWidgets('Browse can delete channels from the grid and list', (
    tester,
  ) async {
    const other = MusicChat(-100456, 'Second channel');
    final td = FakeTd()
      ..onRequest = (request) async => request['@type'] == 'searchChatMessages'
          ? {'messages': [], 'next_from_message_id': 0}
          : null;
    final telegram = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: td,
    )..state = 'authorizationStateReady';
    final settings = MemorySettings()
      ..defaultInterface = AppInterface.video
      ..selectedChannels = [channel, other]
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('video-navigation')),
        matching: find.byIcon(Icons.explore_outlined),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(ValueKey(channel.id));
    final second = find.byKey(ValueKey(other.id));
    Future<void> hold(Finder tile) async {
      await tester.longPress(tile);
      await tester.pumpAndSettle();
      expect(find.text('Delete channel?'), findsOneWidget);
    }

    await hold(first);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(first, findsOneWidget);
    expect(settings.videoChannelId, channel.id);
    await hold(first);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(first, findsNothing);
    expect(second, findsOneWidget);
    expect(settings.videoChannelId, isNull);

    await tester.tap(find.byTooltip('Show list'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsNothing);
    await hold(second);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(second, findsNothing);
    expect(settings.selectedChannels, [channel, other]);
    expect(settings.hiddenVideoChannelIds, {channel.id, other.id});
    expect(find.text('No Telegram channels available'), findsOneWidget);
  });

  testWidgets(
    'Video Library has no search while Browse channel search stays available with the keyboard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      final td = FakeTd();
      td.onRequest = (request) async => request['@type'] == 'searchChatMessages'
          ? {
              'messages':
                  request['filter']?['@type'] == 'searchMessagesFilterVideo'
                  ? [post(30, 'Alpha.mp4'), post(40, 'Zebra.mp4')]
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
      final navigation = find.byKey(const ValueKey('video-navigation'));
      Future<void> openTab(IconData icon) async {
        await tester.tap(
          find.descendant(of: navigation, matching: find.byIcon(icon)),
        );
        await tester.pumpAndSettle();
      }

      await openTab(Icons.video_library_rounded);
      final menu = find.byKey(const ValueKey('video-library-collection-menu'));
      expect(find.byKey(const ValueKey('video-library-search')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(ValueKey('${channel.id}:30')), findsOneWidget);
      expect(find.text('Zebra'), findsOneWidget);
      await openTab(Icons.explore_outlined);
      final channelSearch = find.widgetWithText(TextField, 'Search channels');
      expect(channelSearch, findsOneWidget);
      await tester.enterText(channelSearch, 'Cinema');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(channelSearch).controller!.text,
        'Cinema',
      );
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await openTab(Icons.video_library_rounded);
      expect(menu, findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(ValueKey('${channel.id}:30')), findsOneWidget);
      expect(find.text('Zebra'), findsOneWidget);
      await openTab(Icons.explore_outlined);
      expect(
        tester.widget<TextField>(channelSearch).controller!.text,
        'Cinema',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
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
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
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
      expect(find.text('History'), findsNothing);
      final optionsMenu = find.byKey(
        const ValueKey('video-library-collection-menu'),
      );
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
      final collectionTitle = find.byKey(const ValueKey('video-library-title'));
      expect(
        tester.getSize(optionsMenu).width -
            tester.getSize(collectionTitle).width,
        lessThanOrEqualTo(40),
      );
      expect(find.byTooltip('Library options'), findsNothing);
      expect(find.byTooltip('Refresh videos'), findsNothing);
      final sort = find.byTooltip('Sort Library');
      final panel = find.byKey(const ValueKey(('video-library-panel', 0)));
      final toolbar = tester.getRect(find.byType(LibraryToolbar));
      expect(toolbar.top, 30);
      expect(tester.getTopLeft(panel).dy - toolbar.bottom, 18);
      expect(find.byTooltip('Shuffle collection'), findsNothing);
      expect(find.byKey(const ValueKey('video-library-counts')), findsNothing);
      expect(sort.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(sort).bottom,
        lessThanOrEqualTo(tester.getRect(panel).top),
      );
      expect(find.byType(LibraryCollectionMenu<int>), findsOneWidget);
      expect(find.text('1 video · Cinema'), findsNothing);
      await tester.tap(optionsMenu);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(PopupMenuItem<int>, 'All videos'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(PopupMenuItem<int>, 'History'),
        findsOneWidget,
      );
      expect(find.widgetWithText(PopupMenuItem<int>, 'Offline'), findsNothing);
      expect(find.text('Playlists').hitTestable(), findsNothing);
      expect(find.text('Snapshots').hitTestable(), findsNothing);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Video history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
