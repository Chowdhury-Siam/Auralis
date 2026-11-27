import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_duration.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'telegram_video_test.dart' show channel, post;

Uint8List matroskaHeader() {
  final ticks = ByteData(8)..setFloat64(0, 1462000);
  return Uint8List.fromList([
    0x1a, 0x45, 0xdf, 0xa3, 0x80, // EBML header
    0x18, 0x53, 0x80, 0x67, 0xff, // Segment, unknown length
    0x15, 0x49, 0xa9, 0x66, 0x91, // Info payload, 17 bytes
    0x44, 0x89, 0x88, ...ticks.buffer.asUint8List(),
    0x2a, 0xd7, 0xb1, 0x82, 0x03, 0xe8, // Timestamp scale: 1000 ns
  ]);
}

void main() {
  test('MKV reads Duration and TimestampScale without media payload', () async {
    final header = matroskaHeader();
    final offsets = <int>[];
    final duration = await readVideoDuration((offset, count) async {
      offsets.add(offset);
      if (offset != 0 || count > 4096) fail('Unexpected video payload read');
      return Uint8List(count)..setAll(0, header);
    }, 525 * 1024 * 1024);
    expect(duration, const Duration(seconds: 1, milliseconds: 462));
    expect(offsets, [0]);
  });

  test(
    'MP4 reads a tail movie header without fetching the media body',
    () async {
      const tail = 1024 * 1024;
      final file = Uint8List(tail + 36);
      final data = ByteData.sublistView(file);
      void box(int offset, int size, String name) {
        data.setUint32(offset, size);
        file.setAll(offset + 4, name.codeUnits);
      }

      box(0, 8, 'ftyp');
      box(8, tail - 8, 'mdat');
      box(tail, 36, 'moov');
      box(tail + 8, 28, 'mvhd');
      data.setUint32(tail + 28, 1000);
      data.setUint32(tail + 32, 60000);
      final offsets = <int>[];
      expect(
        await readVideoDuration((offset, length) async {
          offsets.add(offset);
          return Uint8List.sublistView(file, offset, offset + length);
        }, file.length),
        const Duration(minutes: 1),
      );
      expect(offsets, [0, tail]);
    },
  );

  test(
    'saved video duration survives restart and ignores a changed file size',
    () {
      VideoSource source(int size) => VideoSource.telegram(
        Track(
          id: '-1:2',
          title: 'Episode',
          artist: '',
          source: 'Cinema',
          size: size,
        ),
      );
      const duration = Duration(minutes: 24);
      final data = VideoPlaybackData()..rememberDuration(source(500), duration);
      final loaded = VideoPlaybackData.fromJson(data.toJson());
      expect(loaded.durationOf(source(500)), duration);
      expect(loaded.durationOf(source(600)), Duration.zero);
      expect(loaded.durationOf(source(0)), duration);
      loaded.clearTelegram();
      expect(loaded.durationOf(source(500)), Duration.zero);
    },
  );

  testWidgets('an MKV Telegram document shows duration in its row and Info', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final message = post(25, 'Episode 1.mkv', document: true);
    final document = message['content']['document'] as Map<String, dynamic>;
    document.remove('duration');
    document['mime_type'] = 'video/x-matroska';
    document['document']['size'] = 525 * 1024 * 1024;
    final header = matroskaHeader();
    ByteData.sublistView(header).setFloat64(18, 1462000000); // 24:22
    final transport = FakeTd()
      ..onRequest = (request) async => switch (request['@type']) {
        'searchChatMessages' => {
          'messages':
              request['filter']['@type'] == 'searchMessagesFilterDocument'
              ? [message]
              : [],
          'next_from_message_id': 0,
        },
        'getFileDownloadedPrefixSize' => {'size': 4096},
        'readFilePart' => {
          'data': base64Encode(Uint8List(4096)..setAll(0, header)),
        },
        _ => null,
      };
    final telegram = TelegramService(
      Directory('unused'),
      MemoryVault(),
      transport: transport,
    )..state = 'authorizationStateReady';
    final settings = MemorySettings()
      ..defaultInterface = AppInterface.video
      ..videoChannelId = channel.id
      ..selectedChannels = [channel];
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
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    expect(find.text('24:22'), findsOneWidget);
    expect(
      transport.requests.where((r) => r['@type'] == 'readFilePart'),
      hasLength(1),
    );
    await tester.tap(find.byTooltip('Video actions for Episode 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(find.text('Duration'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '24:22'), findsOneWidget);
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'Video Home shows resume for a watched local video at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        tester.platformDispatcher.textScaleFactorTestValue = width == 320
            ? 2
            : 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: FakeTd(),
        );
        final settings = MemorySettings()
          ..defaultInterface = AppInterface.video;
        final source = VideoSource.file(
          Uri.file('/movies/Episode.mp4'),
          'Local episode',
        );
        settings.videoPlayback
          ..recordVideo(source)
          ..setWatched(source, true)
          ..remember(
            source.id,
            const Duration(minutes: 9),
            const Duration(minutes: 10),
          )
          ..rememberDuration(source, const Duration(minutes: 10));
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
        expect(find.text('Continue watching'), findsOneWidget);
        expect(find.text('Local episode'), findsOneWidget);
        expect(find.text('Resume at 9:00'), findsOneWidget);
        final progress = find.byKey(
          const ValueKey('video-home-resume-progress'),
        );
        expect(tester.widget<LinearProgressIndicator>(progress).value, .9);
        expect(find.byTooltip('Open video files'), findsNothing);
        expect(find.byIcon(Icons.folder_open_rounded), findsNothing);
        expect(tester.takeException(), isNull);

        final history = find.byTooltip('Watch history');
        await tester.tap(history);
        await tester.pumpAndSettle();
        expect(find.text('Video history'), findsOneWidget);
        expect(find.text('Local episode'), findsOneWidget);
      },
    );
  }
}
