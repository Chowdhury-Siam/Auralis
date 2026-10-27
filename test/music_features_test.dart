import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const a = Track(
  id: '-1:1',
  title: 'Evening waves',
  artist: 'Original test artist',
  source: 'Music',
  fileId: 1,
  size: 100,
);
const b = Track(
  id: '-1:2',
  title: 'Morning light',
  artist: 'Original test artist',
  source: 'Music',
  fileId: 2,
  size: 100,
);

PlayerController makePlayer({AudioBackend? audio, AppSettings? settings}) =>
    PlayerController(
      audio ?? FakeAudio(),
      TelegramStreamProxy((_) async => {}),
      settings ?? (MemorySettings()..reducedMotion = true),
    );

class PendingAudio extends FakeAudio {
  final opening = Completer<void>();
  @override
  Future<void> open(String uri) async {
    await opening.future;
    await super.open(uri);
  }
}

class UnwritableSettings extends MemorySettings {
  @override
  Future<void> save() async =>
      throw const FileSystemException('Read-only fixture');
}

void main() {
  setUpAll(() async {
    final font = File(
      Platform.isWindows
          ? 'C:/Windows/Fonts/segoeui.ttf'
          : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    );
    if (font.existsSync()) {
      await (FontLoader('Segoe UI')..addFont(
            font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('shuffle toggles visibly active mode and restores the upcoming order without dropping additions', () async {
    final player = makePlayer()
      ..queue.addAll([a, b, a, b])
      ..index = 0;
    addTearDown(player.shutdown);
    player.shuffle();
    expect(player.shuffleEnabled, isTrue);
    expect(player.current, a);
    expect(player.queue.skip(1), unorderedEquals([b, a, b]));
    const added = Track(
      id: 'added',
      title: 'Added',
      artist: 'Artist',
      source: 'Music',
    );
    player.enqueue(added);
    player.shuffle();
    expect(player.shuffleEnabled, isFalse);
    expect(player.queue, [a, b, a, b, added]);
    await player.clear();
    expect(player.shuffleEnabled, isFalse);
  });

  test('favorites, ordered playlists, recent history and repeat mode survive real settings writes', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-collections-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    final player = makePlayer(settings: AppSettings(file));
    addTearDown(player.shutdown);
    await player.toggleFavorite(a);
    final name = await player.createPlaylist('  Night drive  ');
    await player.addToPlaylist(name, b);
    await player.addToPlaylist(name, a);
    await player.addToPlaylist(name, b);
    await expectLater(
      player.createPlaylist('night DRIVE'),
      throwsArgumentError,
    );
    expect(await player.renamePlaylist(name, 'Evening'), 'Evening');
    player.enqueue(a);
    player.enqueue(b);
    await player.playAt(0);
    await player.next();
    await player.playAt(0);
    player.toggleRepeat();
    player.toggleRepeat();
    await player.settings.save();
    final restored = AppSettings(file);
    await restored.load();
    expect(restored.favoriteIds, {a.id});
    expect(restored.playlists, {
      'Evening': [b.id, a.id],
    });
    expect(restored.recentIds, [a.id, b.id]);
    expect(restored.repeatMode, PlaybackRepeat.one);
    await player.removeFromPlaylist('Evening', b);
    await player.toggleFavorite(a);
    await player.clearRecent();
    await player.deletePlaylist('Evening');
    await restored.load();
    expect(restored.favoriteIds, isEmpty);
    expect(restored.recentIds, isEmpty);
    expect(restored.playlists, isEmpty);
  });

  test('malformed collection fields are bounded and cannot supply stale playback file IDs', () async {
    final dir = await Directory.systemTemp.createTemp(
      'auralis-collection-input-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'favoriteIds': ['', null, 12, a.id, a.id, 'x' * 201],
        'recentIds': List.generate(120, (i) => 'track-$i'),
        'repeatMode': 'unknown',
        'playlists': {
          '': [],
          'x' * 61: [],
          'Valid': [b.id, b.id, 4],
          'valid': [a.id],
        },
      }),
    );
    final settings = AppSettings(file);
    await settings.load();
    expect(settings.favoriteIds, {a.id});
    expect(settings.recentIds.length, 100);
    expect(settings.playlists, {
      'Valid': [b.id],
    });
    expect(settings.repeatMode, PlaybackRepeat.off);
    await settings.save();
    expect(await file.readAsString(), isNot(contains('fileId')));
  });

  test(
    'play next preserves the current queue entry even when IDs repeat',
    () async {
      final player = makePlayer();
      addTearDown(player.shutdown);
      player.enqueue(a);
      player.enqueue(b);
      await player.playAt(0);
      player.playNext(a);
      expect(player.queue, [a, a, b]);
      expect(player.index, 0);
      await player.next();
      expect(player.index, 1);
      await player.next();
      expect(player.current, b);
    },
  );

  test(
    'repeat one restarts a completed track but manual Next still advances',
    () async {
      final audio = FakeAudio();
      final player = makePlayer(audio: audio);
      addTearDown(player.shutdown);
      player.enqueue(a);
      player.enqueue(b);
      await player.playAt(0);
      player.toggleRepeat();
      player.toggleRepeat();
      audio.position = const Duration(minutes: 2);
      audio.playing = false;
      audio.onCompleted!();
      await Future<void>.delayed(Duration.zero);
      expect(player.index, 0);
      expect(audio.position, Duration.zero);
      expect(audio.playing, isTrue);
      await player.next();
      expect(player.index, 1);
      player.toggleRepeat();
      expect(player.repeatMode, PlaybackRepeat.off);
    },
  );

  testWidgets(
    'sleep timer pauses, never resumes paused audio, cancels and overrides repeat one',
    (tester) async {
      final audio = FakeAudio()..playing = true;
      final player = makePlayer(audio: audio)
        ..queue.add(a)
        ..index = 0;
      addTearDown(player.shutdown);
      player.setSleepTimer(const Duration(minutes: 15));
      await tester.pump(const Duration(minutes: 15));
      expect(audio.playing, isFalse);
      expect(player.sleepActive, isFalse);
      player.setSleepTimer(const Duration(minutes: 15));
      await tester.pump(const Duration(minutes: 15));
      expect(audio.playing, isFalse);
      audio.playing = true;
      player.setSleepTimer(const Duration(minutes: 15));
      player.cancelSleepTimer();
      await tester.pump(const Duration(minutes: 16));
      expect(audio.playing, isTrue);
      player.toggleRepeat();
      player.toggleRepeat();
      player.sleepAtTrackEnd();
      audio.onCompleted!();
      await tester.pump();
      expect(audio.playing, isFalse);
      expect(player.index, 0);
      expect(player.sleepActive, isFalse);
      expect(() => player.setSleepTimer(Duration.zero), throwsArgumentError);
      expect(
        () => player.setSleepTimer(const Duration(hours: 25)),
        throwsArgumentError,
      );
    },
  );

  test('sleep expiry during a pending open still pauses when the source becomes ready', () async {
    final audio = PendingAudio();
    final player = makePlayer(audio: audio)..enqueue(a);
    addTearDown(player.shutdown);
    final pending = player.playAt(0);
    player.setSleepTimer(const Duration(milliseconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 25));
    audio.opening.complete();
    await pending;
    expect(audio.playing, isFalse);
    expect(player.sleepActive, isFalse);
  });

  test(
    'collection save failure keeps the session state and reports it',
    () async {
      final player = makePlayer(settings: UnwritableSettings());
      addTearDown(player.shutdown);
      await player.toggleFavorite(a);
      expect(player.settings.favoriteIds, {a.id});
      expect(player.error, contains('could not be saved'));
    },
  );

  testWidgets(
    'collection actions, playlist editing and sleep controls work in compact and wide layouts',
    (tester) async {
      final td = FakeTd();
      td.onRequest = (r) async {
        if (r['@type'] == 'getChat') {
          return {
            'id': -1,
            'title': 'Music',
            'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
          };
        }
        if (r['@type'] == 'searchChatMessages') {
          return {
            'next_from_message_id': 0,
            'messages': r['filter']['@type'] == 'searchMessagesFilterDocument'
                ? []
                : [
                    for (final (id, title) in [(1, a.title), (2, b.title)])
                      {
                        'id': id,
                        'chat_id': -1,
                        'content': {
                          '@type': 'messageAudio',
                          'audio': {
                            'title': title,
                            'performer': 'Original test artist',
                            'audio': {'id': id, 'size': 100},
                          },
                        },
                      },
                  ],
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
        ..reducedMotion = true
        ..selectedChannels = [const MusicChat(-1, 'Music')]
        ..recentIds = [b.id, a.id];
      final player = makePlayer(settings: settings);
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: AuralisApp(player: player, telegram: telegram),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently played'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text(b.title)).dy,
        lessThan(tester.getTopLeft(find.text(a.title)).dy),
      );
      await tester.tap(find.text('All songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Track actions for ${a.title}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to favorites'));
      await tester.pumpAndSettle();
      expect(settings.favoriteIds, {a.id});
      await tester.tap(find.byTooltip('Track actions for ${a.title}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(player.queue.single.id, a.id);
      expect(player.index, -1);
      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('track-title-${a.id}')), findsOneWidget);
      expect(find.text(b.title), findsNothing);
      await tester.tap(find.byTooltip('Track actions for ${a.title}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Night drive');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(settings.playlists, {
        'Night drive': [a.id],
      });
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Night drive'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rename playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Evening mix');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(settings.playlists.keys, ['Evening mix']);
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
          .clearSnackBars();
      await tester.pumpAndSettle();
      for (final size in [const Size(1280, 800), const Size(360, 480)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('track-title-${a.id}')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('docs/screenshots/collections-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('Track actions for ${a.title}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      expect(settings.playlists['Evening mix'], isEmpty);
      await tester.tap(find.byTooltip('Delete playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(settings.playlists, isEmpty);
      await tester.tap(find.byTooltip('Now playing').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sleep-timer-control')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('docs/screenshots/sleep-timer-360.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('30 min'));
      await tester.pumpAndSettle();
      expect(player.sleepActive, isTrue);
      await tester.tap(find.byKey(const ValueKey('sleep-timer-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel timer'));
      await tester.pumpAndSettle();
      expect(player.sleepActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
