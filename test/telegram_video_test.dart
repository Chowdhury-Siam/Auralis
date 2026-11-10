import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const channel = MusicChat(-100123, 'Cinema');

Json post(int id, String name, {bool document = false}) {
  final media = document ? 'document' : 'video';
  return {
    'id': id,
    'chat_id': channel.id,
    'date': id,
    'content': {
      '@type': document ? 'messageDocument' : 'messageVideo',
      media: {
        'file_name': name,
        'duration': 90,
        'mime_type': 'video/mp4',
        media: {'id': id, 'size': 64},
      },
    },
  };
}

void main() {
  test(
    'video browsing and message links use TDLib and exclude other files',
    () async {
      final td = FakeTd();
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      )..state = 'authorizationStateReady';
      addTearDown(telegram.shutdown);
      td.onRequest = (request) async {
        if (request['@type'] == 'searchChatMessages') {
          return {
            'messages': [
              post(30, 'Clip.MKV', document: true),
              post(20, 'Song.mp3', document: true),
            ],
            'next_from_message_id': 10,
          };
        }
        if (request['@type'] == 'getMessageLinkInfo') {
          return {'message': post(12, 'Trailer.mp4')};
        }
        return null;
      };

      final page = await telegram.videos(
        channel,
        before: 40,
        query: 'clip',
        documents: true,
      );
      expect(page.nextMessageId, 10);
      expect(page.tracks.single.title, 'Clip');
      expect(page.tracks.single.size, 64);
      expect(td.requests.single['filter'], {
        '@type': 'searchMessagesFilterDocument',
      });
      expect(td.requests.single['from_message_id'], 40);
      expect(td.requests.single['query'], 'clip');

      final video = await telegram.videoLink('https://t.me/c/123/12');
      expect(video!.fileId, 12);
      expect(video.title, 'Trailer');
      expect(video.duration, const Duration(seconds: 90));
      expect(Track.fromMessage(post(12, 'Trailer.mp4'), channel.title), isNull);
      await expectLater(
        telegram.videoLink('https://t.me.example.org/chan/12'),
        throwsFormatException,
      );
      expect(td.requests, hasLength(2));
    },
  );

  for (final style in AppNavigationStyle.values) {
    testWidgets('Home hold opens videos in ${style.name} navigation', (
      tester,
    ) async {
      var taps = 0, holds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: AppNavigation(
              style: style,
              radius: 22,
              selected: 0,
              onSelected: (_) => taps++,
              onHomeHold: () => holds++,
            ),
          ),
        ),
      );
      final home = find.byIcon(Icons.home_rounded);
      await tester.tap(home);
      expect(taps, 1);
      expect(holds, 0);
      final gesture = await tester.startGesture(tester.getCenter(home));
      await tester.pump(const Duration(milliseconds: 600));
      expect(holds, 0);
      await tester.pump(const Duration(milliseconds: 350));
      expect(holds, 1);
      await gesture.up();
      expect(taps, 1);
    });
  }

  testWidgets('desktop Home opens channel videos and can load older results', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 750);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final td = FakeTd();
    final telegram = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: td,
    )..state = 'authorizationStateReady';
    td.onRequest = (request) async {
      switch (request['@type']) {
        case 'getChat':
          return {
            'id': channel.id,
            'title': channel.title,
            'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
          };
        case 'searchChatMessages':
          if (request['filter']?['@type'] == 'searchMessagesFilterVideo') {
            final first = request['from_message_id'] == 0;
            return {
              'messages': [
                if (first)
                  post(30, 'New release.mp4')
                else
                  post(20, 'Older film.mp4'),
              ],
              'next_from_message_id': first ? 25 : 0,
            };
          }
          return {'messages': [], 'next_from_message_id': 0};
        default:
          return null;
      }
    };
    final player = PlayerController(
      FakeAudio(),
      TelegramStreamProxy(telegram.request),
      MemorySettings()..selectedChannels = [channel],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await player.shutdown();
      await telegram.shutdown();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerShell(player: player, telegram: telegram),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Home')),
    );
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Telegram Video'), findsOneWidget);
    expect(find.text('New release'), findsOneWidget);

    await tester.tap(find.text('Load older videos'));
    await tester.pumpAndSettle();
    expect(find.text('New release'), findsOneWidget);
    expect(find.text('Older film'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Telegram Video'), findsNothing);
    expect(find.text('Library'), findsWidgets);
  });
}
