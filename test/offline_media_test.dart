import 'dart:async';
import 'dart:io';

import 'package:auralis/models.dart';
import 'package:auralis/offline_media.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

const song = Track(
  id: '-100:1',
  title: 'Song for the road',
  artist: 'Artist',
  source: 'Music channel',
  fileId: 11,
  size: 4,
  duration: Duration(seconds: 2),
);

void main() {
  test(
    'completed copies survive Telegram cleanup and play after restart',
    () async {
      final root = await Directory.systemTemp.createTemp('auralis-offline-');
      addTearDown(() => root.delete(recursive: true));
      final cached = await File(p.join(root.path, 'td-download'))
          .writeAsBytes([1, 2, 3, 4]);
      final downloadStarted = Completer<void>();
      var requested = false;
      final transport = FakeTd()
        ..onRequest = (call) async {
          switch (call['@type']) {
            case 'downloadFile':
              requested = true;
              downloadStarted.complete();
            case 'getFile':
              return {
                'local': {
                  'path': cached.path,
                  'is_downloading_completed': requested,
                  'downloaded_size': requested ? 4 : 2,
                },
              };
            case 'deleteFile':
              await cached.delete();
          }
          return {};
        };
      final telegram = TelegramService(
        root,
        MemoryVault(),
        transport: transport,
      )..state = 'authorizationStateReady';
      addTearDown(telegram.shutdown);

      final saved = Future.wait([
        telegram.saveOffline(song, video: false),
        telegram.saveOffline(song, video: false),
      ]);
      await Future.any([downloadStarted.future, saved]);
      expect(
        telegram.offline.downloadProgress(song.id, video: false)?.value,
        .5,
      );
      expect(telegram.offline.contains(song.id, video: false), isFalse);
      await saved;
      expect(telegram.offline.downloadProgress(song.id, video: false), isNull);
      expect(
        transport.requests.where((call) => call['@type'] == 'downloadFile'),
        [
          {
            '@type': 'downloadFile',
            'file_id': 11,
            'priority': 8,
            'offset': 0,
            'limit': 0,
            'synchronous': false,
          },
        ],
      );
      expect(await cached.exists(), isFalse);
      final restarted = OfflineMedia(telegram.offline.directory);
      addTearDown(restarted.dispose);
      await restarted.load();
      final local = await restarted.uri(song.id, video: false);
      expect(local!.scheme, 'file');
      expect(await File.fromUri(local).readAsBytes(), [1, 2, 3, 4]);
      expect(restarted.tracks(video: true), isEmpty);
      final restored = restarted.tracks(video: false).single;
      expect(restored.id, song.id);
      expect(restored.duration, song.duration);

      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => throw StateError('Offline')),
        MemorySettings(),
        offlineUri: (track) => restarted.availableUri(track.id, video: false),
      );
      addTearDown(player.shutdown);
      await player.play(restored);
      expect(audio.uri, local.toString());
      expect(player.current?.id, song.id);

      await restarted.remove(song.id, video: false);
      expect(await restarted.uri(song.id, video: false), isNull);
      expect(await File.fromUri(local).exists(), isFalse);
    },
  );

  testWidgets('video row shows progress and marks completed copies offline', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('auralis-offline-row-');
    final media = OfflineMedia(Directory(p.join(root.path, 'offline')));
    final source = File(p.join(root.path, 'source'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    Completer<void>? finish;
    late Future<void> saving;
    final meter = find.byType(LinearProgressIndicator);
    final badge = find.byIcon(Icons.download_done_rounded);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoLibraryRow(
            title: song.title,
            artwork: const Icon(Icons.movie_outlined),
            offline: (media: media, id: song.id),
            onTap: () {},
          ),
        ),
      );
      expect(meter, findsNothing);
      expect(badge, findsNothing);
      await tester.runAsync(() async {
        final started = Completer<void>();
        final readyToSave = finish = Completer<void>();
        saving = media.save(
          song,
          video: true,
          download: (copy, reportProgress) async {
            reportProgress(.5);
            started.complete();
            await readyToSave.future;
            await copy(source);
          },
        );
        await Future.any([started.future, saving]);
      });
      await tester.pump();
      expect(tester.widget<LinearProgressIndicator>(meter).value, .5);
      expect(badge, findsNothing);

      await tester.runAsync(() {
        finish!.complete();
        return saving;
      });
      await tester.pump();
      expect(meter, findsNothing);
      expect(badge, findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);

      await tester.runAsync(() => media.remove(song.id, video: true));
      await tester.pump();
      expect(badge, findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() {
        if (finish case final pending? when !pending.isCompleted) {
          pending.complete();
        }
        return media.drain();
      });
      media.dispose();
      root.deleteSync(recursive: true);
    }
  });

  test(
    'partial copies stay hidden and a retry can save the same file',
    () async {
      final root = await Directory.systemTemp.createTemp('auralis-offline-');
      addTearDown(() => root.delete(recursive: true));
      final media = OfflineMedia(Directory(p.join(root.path, 'offline')));
      addTearDown(media.dispose);
      final source = await File(p.join(root.path, 'source')).writeAsBytes([1]);
      await expectLater(
        media.save(song, video: true, download: (copy, _) => copy(source)),
        throwsStateError,
      );
      expect(media.tracks(video: true), isEmpty);
      expect(media.downloadProgress(song.id, video: true), isNull);
      expect(await media.directory.list().toList(), isEmpty);
      await source.writeAsBytes([1, 2, 3, 4]);
      final downloading = Completer<void>();
      final job = media.save(
        song,
        video: true,
        download: (copy, _) async {
          await downloading.future;
          await copy(source);
        },
      );
      expect(media.saving(song.id, video: true), isTrue);
      expect(media.tracks(video: true), isEmpty);
      downloading.complete();
      await job;
      expect(media.saving(song.id, video: true), isFalse);
      expect(media.contains(song.id, video: true), isTrue);
      expect(media.contains(song.id, video: false), isFalse);
    },
  );
}
