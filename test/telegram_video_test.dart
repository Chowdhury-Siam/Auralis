import 'dart:async';
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
        if (!document) ...{'width': 720, 'height': 1280},
        'mime_type': name.endsWith('.mp3') ? 'audio/mpeg' : 'video/mp4',
        media: {'id': id, 'size': 64},
      },
    },
  };
}

void main() {
  test(
    'Telegram quality parsing keeps only real alternate video files',
    () async {
      final message = post(12, 'Trailer.mp4');
      final content = message['content'] as Map<String, dynamic>;
      Map<String, dynamic> quality(int id, int width, int height) => {
        'id': '$id',
        'width': width,
        'height': height,
        'codec': 'h264',
        'video': {'id': id, 'size': 4096},
        'hls_file': {'id': id + 100, 'size': 128},
      };
      content['alternative_videos'] = [
        quality(21, 640, 360),
        quality(22, 1280, 720),
        quality(22, 1280, 720),
        quality(12, 720, 1280),
        quality(23, 0, 1080),
        quality(-1, 1280, 720),
        {
          ...quality(24, 1920, 1080),
          'video': {'id': 24, 'size': 0},
        },
        {...quality(25, 1920, 1080), 'video': null},
        null,
        'invalid',
      ];
      final track = Track.fromVideoMessage(message, channel.title)!;
      expect(track.videoQualities.map((quality) => quality.fileId), [22, 21]);
      expect(track.videoQualities.map((quality) => quality.label), [
        '720p · HD',
        '360p',
      ]);
      expect(track.fileId, 12);
      expect(() => track.videoQualities.clear(), throwsUnsupportedError);
      expect(videoResolutionLabel(2160, 3840), '2160p · 4K');
      expect(videoResolutionLabel(null, null), 'Original');
      expect(videoResolutionLabel(1920, 800), '800p');
      final document = post(15, 'Movie.mkv', document: true);
      (document['content'] as Map)['alternative_videos'] =
          content['alternative_videos'];
      expect(
        Track.fromVideoMessage(document, channel.title)!.videoQualities,
        isEmpty,
      );

      final td = FakeTd()..onRequest = (_) async => message;
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      )..state = 'authorizationStateReady';
      addTearDown(telegram.shutdown);
      final restored = await telegram.restoreVideo(
        const Track(
          id: '-100123:12',
          title: 'Saved',
          artist: '',
          source: 'Cinema',
        ),
      );
      expect(restored!.videoQualities.map((quality) => quality.fileId), [
        22,
        21,
      ]);
    },
  );

  test('video browsing and saved video references use TDLib and exclude other files', () async {
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
      if (request['@type'] == 'getMessage') {
        expect(request['chat_id'], channel.id);
        expect(request['message_id'], 12);
        return post(12, 'Trailer.mp4');
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
    expect(page.tracks.single.videoWidth, isNull);
    expect(page.tracks.single.videoHeight, isNull);
    expect(td.requests.single['filter'], {
      '@type': 'searchMessagesFilterDocument',
    });
    expect(td.requests.single['from_message_id'], 40);
    expect(td.requests.single['query'], 'clip');

    final video = await telegram.restoreVideo(
      Track(
        id: '${channel.id}:12',
        title: 'Trailer',
        artist: '',
        source: channel.title,
      ),
    );
    expect(video!.fileId, 12);
    expect(video.title, 'Trailer');
    expect(video.duration, const Duration(seconds: 90));
    expect(video.videoWidth, 720);
    expect(video.videoHeight, 1280);
    expect(Track.fromMessage(post(12, 'Trailer.mp4'), channel.title), isNull);
    expect(td.requests, hasLength(2));
  });

  testWidgets(
    'Browse discovers a new channel and Library shows history and live videos before indexing catches up',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final td = FakeTd();
      final delayedIndex = Completer<void>();
      td.onRequest = (request) async {
        if (request['@type'] == 'getChatHistory') {
          expect(request['chat_id'], channel.id);
          return {
            'messages': [
              post(40, 'New episode', document: true),
              post(20, 'Music.mp3', document: true),
            ],
          };
        }
        if (request['@type'] == 'searchChatMessages' &&
            request['chat_id'] == channel.id) {
          await delayedIndex.future;
          throw TdException(400, 'Search index is unavailable');
        }
        return null;
      };
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('auralis-video-channel-'),
      );
      final telegram = TelegramService(
        directory!,
        MemoryVault(),
        transport: td,
      );
      await tester.runAsync(() async {
        await telegram.start(
          apiId: 12345,
          apiHash: 'abcdef0123456789abcdef0123456789',
        );
        td.auth('authorizationStateReady');
        await telegram.refreshChats();
      });
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy(telegram.request),
        MemorySettings()..defaultInterface = AppInterface.video,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await player.shutdown();
        await telegram.shutdown();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      final navigation = find.byKey(const ValueKey('video-navigation'));
      final browse = find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.explore_outlined),
      );
      final library = find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.video_library_rounded),
      );
      final refresh = find.byTooltip('Refresh videos');
      expect(refresh, findsNothing);
      await tester.tap(browse);
      await tester.pumpAndSettle();
      expect(find.text('No Telegram channels available'), findsOneWidget);
      expect(refresh, findsOneWidget);
      expect(find.text(channel.title), findsNothing);
      td.events.add({
        '@type': 'updateNewChat',
        'chat': {
          'id': channel.id,
          'title': channel.title,
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        },
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text(channel.title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Browse channels'), findsOneWidget);
      expect(find.text('Selected in Library'), findsOneWidget);
      expect(find.text('New episode'), findsNothing);
      expect(find.text('Music'), findsNothing);
      expect(delayedIndex.isCompleted, isFalse);

      final incoming = post(41, 'Next episode.mp4');
      td.events.add({
        '@type': 'updateChatLastMessage',
        'chat_id': channel.id,
        'last_message': incoming,
      });
      td.events.add({'@type': 'updateNewMessage', 'message': incoming});
      delayedIndex.complete();
      await tester.pumpAndSettle();
      expect(find.text('Next episode'), findsNothing);
      await tester.tap(library);
      await tester.pumpAndSettle();
      expect(refresh, findsNothing);
      expect(find.text('Next episode'), findsOneWidget);
      expect(find.text('New episode'), findsOneWidget);
      final episode = find.byKey(ValueKey('${channel.id}:40'));
      final watch = find.descendant(
        of: episode,
        matching: find.byTooltip('Mark as watched'),
      );
      final artworkFilter = find.descendant(
        of: episode,
        matching: find.byType(ColorFiltered),
      );
      final title = find.descendant(
        of: episode,
        matching: find.text('New episode'),
      );
      final unwatchedColor = tester.widget<Text>(title).style?.color;
      expect(artworkFilter, findsNothing);
      await tester.tap(watch);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: episode, matching: find.textContaining('Watched')),
        findsOneWidget,
      );
      expect(artworkFilter, findsOneWidget);
      expect(
        tester.widget<Text>(title).style?.color,
        Theme.of(tester.element(title)).colorScheme.onSurfaceVariant,
      );
      await tester.tap(
        find.descendant(
          of: episode,
          matching: find.byTooltip('Mark as unwatched'),
        ),
      );
      await tester.pumpAndSettle();
      expect(artworkFilter, findsNothing);
      expect(tester.widget<Text>(title).style?.color, unwatchedColor);
      expect(find.text('Could not load videos'), findsNothing);
      final distance =
          tester.getCenter(find.text('Next episode')).dy -
          tester.getCenter(find.text('New episode')).dy;
      expect(distance, inExclusiveRange(0, 110));
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
        isFalse,
      );

      final refreshes = td.requests
          .where((r) => r['@type'] == 'loadChats')
          .length;
      final videoSearches = td.requests
          .where((r) => r['@type'] == 'searchChatMessages')
          .length;
      await tester.tap(browse);
      await tester.pumpAndSettle();
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(
        td.requests.where((r) => r['@type'] == 'loadChats').length,
        greaterThan(refreshes),
      );
      expect(
        td.requests.where((r) => r['@type'] == 'searchChatMessages').length,
        greaterThan(videoSearches),
      );
      await tester.tap(library);
      await tester.pumpAndSettle();
      expect(refresh, findsNothing);
      expect(find.text('New episode'), findsOneWidget);
      expect(tester.takeException(), isNull);
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

  testWidgets(
    'desktop channel selection stays in Browse and Library keeps loaded videos',
    (tester) async {
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
      expect(find.text('Auralis Video'), findsOneWidget);
      expect(find.byTooltip('Telegram'), findsNothing);
      final musicShortcut = find.widgetWithIcon(
        IconButton,
        Icons.music_note_rounded,
      );
      expect(musicShortcut, findsNothing);
      await tester.tap(find.text('Browse videos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(channel.title));
      await tester.pumpAndSettle();
      expect(find.text('Browse channels'), findsOneWidget);
      expect(find.text('Selected in Library'), findsOneWidget);
      expect(find.text('New release'), findsNothing);

      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      expect(find.text('New release'), findsOneWidget);
      expect(find.text('Older film'), findsOneWidget);
      expect(find.text('Load older videos'), findsNothing);
      expect(musicShortcut, findsNothing);

      await tester.tap(find.byTooltip('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Selected in Library'), findsOneWidget);
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Older film'), findsOneWidget);
      expect(
        td.requests.where(
          (r) =>
              r['@type'] == 'searchChatMessages' && r['from_message_id'] == 25,
        ),
        hasLength(1),
      );
      final returnGesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Home')),
      );
      await tester.pump(const Duration(seconds: 1));
      await returnGesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Auralis Video'), findsNothing);
      expect(find.text('Your Mix'), findsOneWidget);
    },
  );
  test(
    'startup interface settings preserve old installs and round-trip',
    () async {
      final settings = MemorySettings();
      settings.applyJson({});
      expect(settings.defaultInterface, AppInterface.music);
      settings.defaultInterface = AppInterface.video;
      settings.videoChannelId = channel.id;
      final restored = MemorySettings()..applyJson(settings.toJson());
      expect(restored.defaultInterface, AppInterface.video);
      expect(restored.videoChannelId, channel.id);
      restored.applyJson({'defaultInterface': 'invalid'});
      expect(restored.defaultInterface, AppInterface.music);
    },
  );

  testWidgets(
    'Video startup opens its own home and settings can switch to Music',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy(telegram.request),
        MemorySettings()..defaultInterface = AppInterface.video,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await player.shutdown();
        await telegram.shutdown();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerShell(
            startOnHome: true,
            player: player,
            telegram: telegram,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Auralis Video'), findsOneWidget);
      expect(find.text('Connect Telegram'), findsOneWidget);
      expect(
        find.widgetWithIcon(IconButton, Icons.music_note_rounded),
        findsNothing,
      );
      expect(find.byTooltip('Settings'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('video-navigation')),
          matching: find.byIcon(Icons.video_library_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-media')), findsNothing);
      final search = find.byKey(const ValueKey('settings-search'));
      await tester.enterText(search, 'mpv console');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-video')));
      await tester.pumpAndSettle();
      final decoder = find.widgetWithText(ListTile, 'Video decoder');
      expect(tester.widget<ListTile>(decoder).enabled, isFalse);
      await tester.tap(find.text('Player settings'));
      await tester.pumpAndSettle();
      final gestures = find.widgetWithText(
        SwitchListTile,
        'Tap and swipe gestures',
      );
      final gesturesEnabled = player.settings.videoPlayback.gestures;
      await tester.tap(gestures);
      await tester.pumpAndSettle();
      expect(player.settings.videoPlayback.gestures, !gesturesEnabled);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.enterText(search, 'mymemory');
      await tester.pumpAndSettle();
      expect(find.text('No matching settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear settings search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('General'));
      await tester.pumpAndSettle();
      expect(find.text('Open on startup'), findsOneWidget);
      await tester.tap(find.text('Switch to Music'));
      await tester.pumpAndSettle();
      expect(find.text('Your Mix'), findsOneWidget);
    },
  );
  testWidgets('setup startup choice opens the selected Video interface', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final settings = MemorySettings();
    final telegram = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: FakeTd(),
    );
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
    await tester.pumpWidget(
      AuralisApp(player: player, telegram: telegram, showSetup: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open on startup: Music'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setup-skip')));
    await tester.pumpAndSettle();
    expect(settings.defaultInterface, AppInterface.video);
    expect(settings.setupComplete, isTrue);
    expect(find.text('Auralis Video'), findsOneWidget);
  });
}
