import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/updater.dart';

import 'fakes.dart';
import 'fixtures/cover_data.dart';

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
  testWidgets(
    'select two channels, play their combined Library with covers, and deselect a source',
    (tester) async {
      late Directory dir;
      final td = FakeTd();
      late TelegramService telegram;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('auralis-ui-channels-');
        telegram = TelegramService(dir, MemoryVault(), transport: td);
        await telegram.start(
          apiId: 12345,
          apiHash: 'abcdef0123456789abcdef0123456789',
        );
      });
      telegram.state = 'authorizationStateReady';
      for (final id in [-1, -2]) {
        td.events.add({
          '@type': 'updateNewChat',
          'chat': {
            'id': id,
            'title': 'Channel $id',
            'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
            'photo': {
              'small': {'id': 90},
            },
          },
        });
      }
      final photoPath = File('test/fixtures/cover.png').absolute.path;
      final coverPng = File(photoPath).readAsBytesSync();
      final fileBytes = id3(coverPng);
      td.onRequest = (r) async {
        if (r['@type'] == 'getFileDownloadedPrefixSize') {
          return {'size': fileBytes.length - (r['offset'] as int)};
        }
        if (r['@type'] == 'readFilePart') {
          final offset = r['offset'] as int;
          return {
            'data': base64Encode(
              fileBytes.sublist(offset, offset + (r['count'] as int)),
            ),
          };
        }
        if (r['@type'] == 'downloadFile') {
          return {
            'local': {'path': photoPath, 'is_downloading_completed': true},
          };
        }
        if (r['@type'] == 'searchChatMessages') {
          return {
            'next_from_message_id': 0,
            'messages': r['filter']['@type'] == 'searchMessagesFilterDocument'
                ? []
                : [
                    {
                      'chat_id': r['chat_id'],
                      'id': 1,
                      'date': r['chat_id'] == -1 ? 200 : 100,
                      'content': {
                        '@type': 'messageAudio',
                        'audio': {
                          'title': 'Song ${r['chat_id']}',
                          'performer': 'Artist',
                          'file_name': 'song.mp3',
                          'audio': {'id': 1, 'size': fileBytes.length},
                        },
                      },
                    },
                  ],
          };
        }
        return null;
      };
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      telegram.isStreaming = player.proxy.isStreaming;
      addTearDown(() async {
        await player.shutdown();
        await telegram.shutdown();
        await dir.delete(recursive: true);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      void expectSortPosition() {
        final button = tester.getRect(
          find.byType(PopupMenuButton<LibrarySort>),
        );
        final first = tester.getRect(
          find.widgetWithText(
            CheckedPopupMenuItem<LibrarySort>,
            'Newest first',
          ),
        );
        final last = tester.getRect(
          find.widgetWithText(
            CheckedPopupMenuItem<LibrarySort>,
            'Duration (shortest first)',
          ),
        );
        expect(first.top, greaterThanOrEqualTo(button.bottom));
        expect(first.left, greaterThanOrEqualTo(0));
        expect(first.right, lessThanOrEqualTo(tester.view.physicalSize.width));
        expect(last.bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: AuralisApp(player: player, telegram: telegram),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose your music channels'), findsOneWidget);
      // Original test artwork is embedded in an MP3 with no Telegram thumbnail.
      await tester.runAsync(() async {
        expect(await telegram.image(90), photoPath);
        final bytes = await telegram.cover(
          Track(
            id: 'fixture',
            title: 'Fixture',
            artist: 'Artist',
            source: 'Channel',
            fileId: 1,
            size: fileBytes.length,
          ),
        );
        expect(bytes, coverPng);
        final context = tester.element(find.byType(MaterialApp));
        await precacheImage(
          ResizeImage(FileImage(File(photoPath)), width: 96),
          context,
        );
        if (!context.mounted) return;
        await precacheImage(
          ResizeImage(MemoryImage(bytes!), width: 96),
          context,
        );
        if (!context.mounted) return;
        await precacheImage(
          ResizeImage(MemoryImage(bytes), width: 640),
          context,
        );
      });
      await tester.tap(find.byTooltip('Telegram').first);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(telegram.channels.map((c) => c.photoFileId), [90, 90]);
      expect(find.byType(Image), findsNWidgets(2));
      await tester.tap(find.text('Channel -2'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Channel -2')).dy,
        lessThan(tester.getTopLeft(find.text('Channel -1')).dy),
      );
      await tester.tap(find.text('Channel -1'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Channel -1')).dy,
        lessThan(tester.getTopLeft(find.text('Channel -2')).dy),
      );
      expect(player.settings.selectedChannels, hasLength(2));
      await tester.tap(find.text('Open Library (2)'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add Song -1 to queue'), findsOneWidget);
      expect(find.byTooltip('Add Song -2 to queue'), findsOneWidget);
      expect(find.text('Choose audio files'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('library-counts'))).data,
        '2 tracks · 2 channels',
      );
      final scansBeforeRefresh = td.requests
          .where((r) => r['@type'] == 'searchChatMessages')
          .length;
      await tester.tap(find.byKey(const ValueKey('library-refresh')));
      await tester.pumpAndSettle();
      expect(
        td.requests.where((r) => r['@type'] == 'searchChatMessages').length,
        greaterThan(scansBeforeRefresh),
      );
      expect(find.byTooltip('Add Song -1 to queue'), findsOneWidget);
      expect(find.byTooltip('Add Song -2 to queue'), findsOneWidget);
      await tester.tap(find.byTooltip('Sort Library'));
      await tester.pumpAndSettle();
      expectSortPosition();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<LibrarySort>, 'Oldest first'),
      );
      await tester.pumpAndSettle();
      expect(player.settings.librarySort, LibrarySort.oldest);
      expect(
        tester.getTopLeft(find.text('Song -2')).dy,
        lessThan(tester.getTopLeft(find.text('Song -1')).dy),
      );
      await tester.tap(find.byTooltip('Sort Library'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<LibrarySort>, 'Title (A–Z)'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Song -1')).dy,
        lessThan(tester.getTopLeft(find.text('Song -2')).dy),
      );
      await tester.enterText(find.byType(TextField).first, 'Channel -2');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add Song -1 to queue'), findsNothing);
      expect(find.byTooltip('Add Song -2 to queue'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add Song -1 to queue'));
      await tester.runAsync(() => player.playAt(0));
      await tester.pump();
      await tester.runAsync(() async {
        await telegram.image(90);
      });
      await tester.pumpAndSettle();
      expect(audio.uri, startsWith('http://127.0.0.1:'));
      expect(player.current?.title, 'Song -1');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Sort Library'));
      await tester.pumpAndSettle();
      expectSortPosition();
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('docs/screenshots/sort-menu.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<LibrarySort>, 'Artist (A–Z)'),
      );
      await tester.pumpAndSettle();
      expect(player.settings.librarySort, LibrarySort.artist);
      expect(player.current?.title, 'Song -1');
      expect(player.queue, hasLength(1));
      expect(find.byType(Image), findsNWidgets(4));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('docs/screenshots/channel-library.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      for (final size in [const Size(760, 650), const Size(520, 560)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Sort Library'));
        await tester.pumpAndSettle();
        expectSortPosition();
        expect(find.text('Duration (shortest first)'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.widgetWithText(
            CheckedPopupMenuItem<LibrarySort>,
            'Duration (shortest first)',
          ),
        );
        await tester.pumpAndSettle();
        expect(player.settings.librarySort, LibrarySort.duration);
        await tester.tap(find.byTooltip('Telegram').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Library').first);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Telegram').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel -1').first);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Channel -2')).dy,
        lessThan(tester.getTopLeft(find.text('Channel -1')).dy),
      );
      await tester.tap(find.text('Open Library (1)'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add Song -1 to queue'), findsNothing);
      expect(find.byTooltip('Add Song -2 to queue'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'responsive library, queue, Telegram, now playing and settings have no layout errors',
    (tester) async {
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        AppSettings(File('unused')),
      );
      final telegram = TelegramService(Directory('unused'), MemoryVault());
      final updater = AppUpdater(
        currentVersion: '0.1.0',
        directory: Directory('unused'),
        settings: player.settings,
      );
      addTearDown(updater.dispose);
      final boundary = GlobalKey();
      addTearDown(() async {
        await player.shutdown();
      });
      for (final size in [
        const Size(1280, 800),
        const Size(760, 650),
        const Size(520, 560),
      ]) {
        tester.view.resetPhysicalSize();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: AuralisApp(
              player: player,
              telegram: telegram,
              updater: updater,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Connect Telegram for your music'), findsOneWidget);
        expect(find.text('Choose audio files'), findsNothing);
        expect(find.text('Add music'), findsNothing);
        expect(tester.takeException(), isNull, reason: '$size Library');
        if (size.width == 1280) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('docs/screenshots/library.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byTooltip('Telegram').first);
        await tester.pumpAndSettle();
        expect(find.text('Telegram API ID'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await telegram.action(() async {
          telegram.state = 'authorizationStateReady';
        });
        await tester.pumpAndSettle();
        expect(find.text('Find an accessible channel'), findsOneWidget);
        expect(find.text('0 channels · Offline'), findsOneWidget);
        expect(find.text('No channels to show'), findsOneWidget);
        expect(find.text('MUSIC IN YOUR CHANNELS'), findsOneWidget);
        expect(tester.takeException(), isNull);
        telegram.state = 'disconnected';
        await tester.tap(find.byTooltip('Now playing').first);
        await tester.pumpAndSettle();
        expect(find.text('Find your next favorite'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        expect(find.text('Reduce motion'), findsNothing);
        expect(find.text('Use instant page transitions'), findsNothing);
        expect(find.text('Listening stats'), findsOneWidget);
        expect(find.text('Backup & Restore'), findsOneWidget);
        expect(find.text('Check automatically'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
        await tester.tap(find.byTooltip('Back to Library'));
        await tester.pumpAndSettle();
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
