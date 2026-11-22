import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:auralis/app.dart';
import 'package:auralis/library_widgets.dart';
import 'package:auralis/local_media.dart';
import 'package:auralis/local_media_view.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/video_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';
import 'video_duration_test.dart' show matroskaHeader;

LocalMedia media(String name, {bool video = false, String? album}) =>
    LocalMedia({
      'uri': Uri.file('/device/$name').toString(),
      'name': name,
      'folder': 'Music/Local',
      'artist': 'Test artist',
      'album': ?album,
      'genre': 'Jazz',
      'duration': 120000,
    }, isVideo: video);

class _AndroidMedia extends LocalMediaPlatform {
  final events = StreamController<void>.broadcast();
  final requests = <bool>[];
  final scans = <bool>[];
  LocalMediaAccess permission = LocalMediaAccess.denied;
  LocalMediaAccess grant = LocalMediaAccess.denied;
  int settingsVisits = 0;
  List<LocalMedia> entries = [];

  @override
  bool get android => true;

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<LocalMediaAccess> access(bool video, {bool request = false}) async {
    if (request) {
      requests.add(video);
      permission = grant;
    }
    return permission;
  }

  @override
  Future<void> settings() async {
    settingsVisits++;
  }

  @override
  Future<LocalMediaScan> scan(bool video, List<String> folders) async {
    scans.add(video);
    return (entries: entries, unavailable: 0);
  }

  @override
  Future<Uint8List?> artwork(LocalMedia item) async => null;
}

Future<void> settleScan(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('folder scan deduplicates overlapping roots and reflects moves and deletion', () async {
    final folder = await Directory.systemTemp.createTemp('auralis-local-');
    addTearDown(() => folder.delete(recursive: true));
    final nested = await Directory(p.join(folder.path, 'nested')).create();
    final a = await File(p.join(nested.path, 'a.MP3')).writeAsString('audio');
    await File(p.join(folder.path, 'readme.txt')).writeAsString('unrelated');
    final video = await File(p.join(nested.path, 'S01E1.mkv'))
        .writeAsBytes(matroskaHeader());
    final library = const LocalMediaPlatform();
    final roots = [folder.path, nested.path];

    final music = await library.scan(false, roots);
    expect(music.entries.map((item) => item.name), ['a.MP3']);
    final videos = await library.scan(true, roots);
    expect(videos.entries.single.name, 'S01E1.mkv');
    expect(
      (await library.metadata(videos.entries.single)).duration,
      const Duration(seconds: 1, milliseconds: 462),
    );
    await a.rename(p.join(folder.path, 'renamed.mp3'));
    await video.delete();
    expect((await library.scan(true, roots)).entries, isEmpty);
    expect(
      (await library.scan(false, roots)).entries.single.name,
      'renamed.mp3',
    );
    expect((await library.scan(false, [])).entries, isEmpty);
    expect(await File(p.join(folder.path, 'renamed.mp3')).exists(), isTrue);
  });

  test('album and folder search produce the displayed queue and numerical episodes', () {
    final tracks = [
      media('Zeta.mp3', album: 'One'),
      media('Alpha.mp3', album: 'One'),
      media('Lambda.mp3', album: 'Other'),
    ];
    final albums = selectLocalMedia(
      tracks,
      LocalMediaView.albums,
      null,
      '',
      LibrarySort.title,
    );
    final one = albums.groups.first;
    expect(one.label, 'One');
    expect(one.count, 2);
    final songs = selectLocalMedia(
      tracks,
      LocalMediaView.albums,
      one.key,
      '',
      LibrarySort.title,
    );
    expect(songs.rows.map((item) => item.name), ['Alpha.mp3', 'Zeta.mp3']);
    expect(
      selectLocalMedia(
        tracks,
        LocalMediaView.artists,
        null,
        'jazz',
        LibrarySort.title,
      ).groups.single.count,
      3,
    );
    expect(
      selectLocalMedia(
        tracks,
        LocalMediaView.genres,
        null,
        '',
        LibrarySort.title,
      ).groups.single.label,
      'Jazz',
    );

    final episodes = [
      media('Series S01E10.mp4', video: true),
      media('Series S01E02.mp4', video: true),
      media('Series S01E1.mp4', video: true),
      media('Other S01E3.mp4', video: true),
    ];
    final filtered = selectLocalMedia(
      episodes,
      LocalMediaView.folders,
      'Music/Local',
      'series',
      LibrarySort.title,
    );
    expect(filtered.rows.map((item) => item.title), [
      'Series S01E1.mp4',
      'Series S01E02.mp4',
      'Series S01E10.mp4',
    ]);
  });

  test(
    'source selections and folders persist locally without entering sync data',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'auralis-local-settings-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final settings = AppSettings(File(p.join(folder.path, 'settings.json')))
        ..musicLibraryOnDevice = true
        ..localMediaFolders = [p.join(folder.path, 'media')];
      Map<String, dynamic>? synced;
      settings.captureSync = (snapshot) => synced = snapshot;
      await settings.save();
      final loaded = AppSettings(settings.file);
      await loaded.load();
      expect(loaded.musicLibraryOnDevice, isTrue);
      expect(loaded.videoLibraryOnDevice, isFalse);
      expect(loaded.localMediaFolders, settings.localMediaFolders);
      expect(
        synced.toString(),
        isNot(contains(settings.localMediaFolders.single)),
      );
      expect(synced!.keys, isNot(contains('_musicLibraryOnDevice')));
      loaded.videoLibraryOnDevice = true;
      loaded.musicLibraryOnDevice = false;
      await loaded.save();
      await settings.load();
      expect(settings.videoLibraryOnDevice, isTrue);
      expect(settings.musicLibraryOnDevice, isFalse);
    },
  );

  test('Music player opens local files offline in displayed order', () async {
    final audio = FakeAudio();
    final requests = <Map<String, dynamic>>[];
    final proxy = TelegramStreamProxy((request) async {
      requests.add(request);
      throw StateError('No Telegram connection');
    });
    final settings = MemorySettings();
    final player = PlayerController(audio, proxy, settings)
      ..shuffleEnabled = true;
    addTearDown(player.shutdown);
    final songs = [
      for (final name in ['A.mp3', 'B.mp3', 'C.mp3']) media(name).track,
    ];
    await player.play(songs[1], from: songs);
    expect(player.queue, songs);
    expect(player.index, 1);
    expect(audio.uri, songs[1].localUri.toString());
    await player.next();
    expect(audio.uri, songs[2].localUri.toString());
    expect(audio.playing, isTrue);
    expect(requests, isEmpty);
    expect(settings.recentIds, isEmpty);
    expect(settings.listening.tracks, isEmpty);
  });

  testWidgets(
    'local Video manages denied and limited access and refreshes changes',
    (tester) async {
      final platform = _AndroidMedia();
      addTearDown(platform.events.close);
      final settings = MemorySettings();
      (List<LocalMedia>, int)? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalMediaViewPane(
              settings: settings,
              video: true,
              bottomPadding: 8,
              onPlay: (rows, index) => selected = (rows, index),
              onOpenFiles: () {},
              platform: platform,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.requests, [true]);
      expect(platform.scans, isEmpty);
      expect(find.text('Allow access'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pump();
      expect(platform.settingsVisits, 1);

      platform.grant = LocalMediaAccess.limited;
      platform.entries = [
        media('S01E10.mp4', video: true),
        media('S01E02.mp4', video: true),
        media('S01E1.mp4', video: true),
      ];
      settings.videoPlayback
        ..setWatched(platform.entries[1].video, true)
        ..remember(
          platform.entries[1].video.id,
          const Duration(seconds: 108),
          const Duration(seconds: 120),
        );
      await tester.tap(find.text('Allow access'));
      await settleScan(tester);
      expect(find.text('Manage access'), findsOneWidget);
      expect(find.byType(VideoLibraryRow), findsNWidgets(3));
      expect(find.text('2:00 · Watched · Resume at 1:48'), findsOneWidget);
      await tester.tap(find.text('S01E02.mp4'));
      expect(selected!.$2, 1);
      expect(selected!.$1.map((item) => item.name), [
        'S01E1.mp4',
        'S01E02.mp4',
        'S01E10.mp4',
      ]);
      await tester.tap(find.byTooltip('Info for S01E02.mp4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Info'));
      await tester.pumpAndSettle();
      expect(find.text('Duration'), findsOneWidget);
      expect(find.widgetWithText(SelectableText, '2:00'), findsOneWidget);
      Navigator.of(tester.element(find.text('Duration'))).pop();
      await tester.pumpAndSettle();

      platform.entries = [media('Added S01E4.mp4', video: true)];
      platform.events.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleScan(tester);
      expect(find.text('S01E02.mp4'), findsNothing);
      expect(find.text('Added S01E4.mp4'), findsOneWidget);
      expect(platform.scans, [true, true]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('local Music uses shared song rows and opens folders', (
    tester,
  ) async {
    final platform = _AndroidMedia()
      ..permission = LocalMediaAccess.full
      ..entries = [media('Alpha.mp3'), media('Beta.mp3')];
    addTearDown(platform.events.close);
    (List<LocalMedia>, int)? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalMediaViewPane(
            settings: MemorySettings(),
            video: false,
            bottomPadding: 8,
            onPlay: (rows, index) => selected = (rows, index),
            onOpenFiles: () {},
            platform: platform,
          ),
        ),
      ),
    );
    await settleScan(tester);
    expect(find.byType(MusicLibraryRow), findsNWidgets(2));
    expect(find.text('Test artist · 2:00'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Show Folders'));
    await settleScan(tester);
    expect(find.text('Alpha.mp3'), findsNothing);
    await tester.tap(find.text('Local'));
    await settleScan(tester);
    await tester.tap(find.text('Beta.mp3'));
    expect(selected!.$2, 1);
    expect(selected!.$1.map((item) => item.name), ['Alpha.mp3', 'Beta.mp3']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final mode in AppInterface.values) {
    testWidgets('one header button switches both ways in ${mode.label}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = MemorySettings()..defaultInterface = mode;
      final transport = FakeTd();
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: transport,
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
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      final sourceButton = find.byType(LibrarySourceButton);
      final toDevice = find.byTooltip('Telegram · Switch to On this device');
      final toTelegram = find.byTooltip('On this device · Switch to Telegram');
      final toolbar = find.byType(LibraryToolbar);
      expect(sourceButton, findsOneWidget);
      expect(find.descendant(of: toolbar, matching: toDevice), findsOneWidget);
      expect(find.byType(LibraryPanel), findsOneWidget);
      final headerHeight = tester.getSize(toolbar).height;
      await tester.tap(toDevice);
      await settleScan(tester);
      expect(find.byType(LocalMediaViewPane), findsOneWidget);
      expect(sourceButton, findsOneWidget);
      expect(
        find.descendant(of: toolbar, matching: toTelegram),
        findsOneWidget,
      );
      expect(find.byType(LibraryPanel), findsOneWidget);
      expect(tester.getSize(toolbar).height, headerHeight);
      expect(settings.musicLibraryOnDevice, mode == AppInterface.music);
      expect(settings.videoLibraryOnDevice, mode == AppInterface.video);
      expect(transport.requests, isEmpty);
      await tester.tap(toTelegram);
      await tester.pumpAndSettle();
      expect(find.byType(LocalMediaViewPane), findsNothing);
      expect(toDevice, findsOneWidget);
      expect(settings.musicLibraryOnDevice, isFalse);
      expect(settings.videoLibraryOnDevice, isFalse);
    });
  }
}
