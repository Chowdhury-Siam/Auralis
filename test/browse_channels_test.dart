import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'channel_library_test.dart' show message;
import 'fakes.dart';
import 'telegram_video_test.dart' show post;

void main() {
  for (final mode in AppInterface.values) {
    testWidgets('${mode.name} Browse filters channels and search by media', (
      tester,
    ) async {
      const audio = MusicChat(-1, 'Audio channel');
      const video = MusicChat(-2, 'Video channel');
      const files = MusicChat(-3, 'Media files channel');
      const empty = MusicChat(-4, 'Empty channel');
      final inMusic = mode == AppInterface.music;
      final excluded = inMusic ? audio : video;
      final included = inMusic ? video : audio;
      var emptyHasMedia = false;
      final td = FakeTd()
        ..onRequest = (request) async {
          final id = request['chat_id'];
          final filter = request['filter']?['@type'];
          switch (request['@type']) {
            case 'getChat':
              return {
                'id': id,
                'title': [
                  audio,
                  video,
                  files,
                  empty,
                ].firstWhere((chat) => chat.id == id).title,
                'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
              };
            case 'getChatMessageCount':
              return {
                'count':
                    (id == audio.id && filter == 'searchMessagesFilterAudio') ||
                        (id == video.id &&
                            filter == 'searchMessagesFilterVideo') ||
                        (id == empty.id && emptyHasMedia)
                    ? 1
                    : 0,
              };
            case 'searchChatMessages':
              final first = request['from_message_id'] == 0;
              final documents = filter == 'searchMessagesFilterDocument';
              return {
                'messages': [
                  if (id == files.id && documents)
                    if (first)
                      message(files.id, 20, name: 'notes.pdf', document: true)
                    else ...[
                      message(files.id, 10, name: 'song.flac', document: true),
                      {
                        ...post(9, 'clip.mp4', document: true),
                        'chat_id': files.id,
                      },
                    ],
                ],
                'next_from_message_id': id == files.id && documents && first
                    ? 20
                    : 0,
              };
          }
          return null;
        };
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      )..state = 'authorizationStateReady';
      final settings = MemorySettings()
        ..defaultInterface = mode
        ..selectedChannels = [audio, video, files, empty];
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
          of: find.byType(AppNavigation),
          matching: find.byIcon(Icons.explore_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(included.title), findsOneWidget);
      expect(find.text(files.title), findsOneWidget);
      expect(find.text(excluded.title), findsNothing);
      expect(find.text(empty.title), findsNothing);

      await tester.tap(find.byTooltip('Search channels'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), excluded.title);
      await tester.pumpAndSettle();
      expect(find.text('No matching channels'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      emptyHasMedia = true;
      await tester.drag(find.byType(GridView), const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(find.text(empty.title), findsOneWidget);

      if (inMusic) {
        Future<void> hold(MusicChat chat) async {
          await tester.longPress(find.byKey(ValueKey(chat.id)));
          await tester.pumpAndSettle();
          expect(find.text('Delete channel?'), findsOneWidget);
        }

        await hold(included);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text(included.title), findsOneWidget);
        await hold(included);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text(included.title), findsNothing);
        await tester.tap(find.byTooltip('Show list'));
        await tester.pumpAndSettle();
        await hold(files);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text(files.title), findsNothing);
        expect(settings.hiddenMusicChannelIds, {included.id, files.id});
        expect(settings.hiddenVideoChannelIds, isEmpty);
      }
    });
  }
}
