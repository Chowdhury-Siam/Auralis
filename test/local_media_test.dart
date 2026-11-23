import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';
import 'embedded_lyrics_test.dart' show tag;
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

const _androidFolder = (
  location: 'content://folder.test/tree/primary%3AMedia',
  name: 'Media',
);
const _windowsFolder = (location: r'D:\Media', name: 'Media');

class _DeviceMedia extends LocalMediaPlatform {
  _DeviceMedia({this.android = true});

  final events = StreamController<void>.broadcast();
  final scans = <(bool, List<String>)>[];
  int picks = 0;
  LocalMediaFolder? selectedFolder;
  List<LocalMedia> entries = [];

  @override
  final bool android;

  @override
  bool get windows => !android;

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<LocalMediaFolder?> chooseFolder() async {
    picks++;
    return selectedFolder;
  }

  @override
  Future<LocalMediaScan> scan(bool video, List<String> folders) async {
    scans.add((video, folders));
    return (entries: entries, unavailable: 0);
  }

  @override
  Future<LocalMedia> metadata(LocalMedia source) async => source;

  @override
  Future<Uint8List?> artwork(LocalMedia item) async => null;
}

class _AndroidFolderChannel extends LocalMediaPlatform {
  @override
  bool get android => true;
}

Future<void> settleScan(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android folder scans pass only selected trees and page the results', () async {
    const channel = MethodChannel('app.auralis/local_media');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'chooseFolder' => {
          'uri': _androidFolder.location,
          'name': _androidFolder.name,
        },
        'scanFolders' => {'token': 4, 'count': 1, 'unavailable': 1},
        'scanPage' => [
          {
            'uri':
                '${_androidFolder.location}/document/primary%3AMedia%2FSong.mp3',
            'name': 'Song.mp3',
            'folder': 'Media',
          },
        ],
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final platform = _AndroidFolderChannel();
    expect((await platform.scan(false, [])).entries, isEmpty);
    expect(calls, isEmpty);
    final folder = await platform.chooseFolder();
    expect(folder, _androidFolder);
    final scan = await platform.scan(false, [folder!.location]);
    expect(scan.entries.single.name, 'Song.mp3');
    expect(scan.entries.single.uri.scheme, 'content');
    expect(scan.unavailable, 1);
    expect(calls.map((call) => call.method), [
      'chooseFolder',
      'scanFolders',
      'scanPage',
      'finishScan',
    ]);
    expect(calls[1].arguments, {
      'video': false,
      'folders': [_androidFolder.location],
      'extensions': audioExtensions,
    });
  });

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
      final settings = AppSettings(File(p.join(folder.path, 'settings.json')));
      final legacyPath = p.join(folder.path, 'media');
      await settings.file.writeAsString(
        jsonEncode({
          '_musicLibraryOnDevice': true,
          '_localMediaFolders': [legacyPath],
        }),
      );
      await settings.load();
      expect(settings.localMediaFolders, [
        (location: legacyPath, name: 'media'),
      ]);
      settings.localMediaFolders.add(_androidFolder);
      Map<String, dynamic>? synced;
      settings.captureSync = (snapshot) => synced = snapshot;
      await settings.save();
      final loaded = AppSettings(settings.file);
      await loaded.load();
      expect(loaded.musicLibraryOnDevice, isTrue);
      expect(loaded.videoLibraryOnDevice, isFalse);
      expect(loaded.localMediaFolders, settings.localMediaFolders);
      expect(synced.toString(), isNot(contains(legacyPath)));
      expect(synced.toString(), isNot(contains(_androidFolder.location)));
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
    var elapsed = Duration.zero;
    final player = PlayerController(
      audio,
      proxy,
      settings,
      elapsed: () => elapsed,
      now: () => DateTime(2026, 11, 23, 12).add(elapsed),
    )..shuffleEnabled = true;
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
    await player.toggleFavorite(songs[2]);
    expect(settings.favoriteIds, {songs[2].id});
    await player.toggleFavorite(songs[2]);
    expect(settings.favoriteIds, isEmpty);
    for (var second = 1; second <= 31; second++) {
      elapsed = Duration(seconds: second);
      await audio.seek(elapsed);
    }
    expect(settings.listening.tracks[songs[2].id]?.milliseconds, 31000);
    expect(settings.listening.tracks[songs[2].id]?.plays, 1);
    expect(settings.listening.days.values.single.plays, 1);
  });

  test('local audio reads embedded synced lyrics without Telegram', () async {
    final root = await Directory.systemTemp.createTemp('auralis-local-lyrics-');
    addTearDown(() => root.delete(recursive: true));
    final audio = await File(p.join(root.path, 'Song.mp3')).writeAsBytes(
      tag('USLT', [
        3,
        ...'eng'.codeUnits,
        0,
        ...utf8.encode('[00:01.50]First line'),
      ]),
    );
    final track = LocalMedia({
      'uri': audio.uri.toString(),
      'name': 'Song.mp3',
    }, isVideo: false).track;
    final result = await const LocalMediaPlatform().embeddedLyrics(track);
    expect(result?.embedded, isTrue);
    expect(result?.lines.single.text, 'First line');
    expect(result?.lines.single.time, const Duration(milliseconds: 1500));
  });

  testWidgets('Android Video keeps the scanned folder until pull-to-refresh', (
    tester,
  ) async {
    final platform = _DeviceMedia();
    addTearDown(platform.events.close);
    final settings = MemorySettings();
    (List<LocalMedia>, int)? selected;
    var local = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => LibrarySourcePanes(
              local: local,
              telegramPane: (_) => TextButton(
                onPressed: () => update(() => local = true),
                child: const Text('Show device'),
              ),
              devicePane: (_) => LocalMediaViewPane(
                settings: settings,
                video: true,
                bottomPadding: 8,
                sourceButton: TextButton(
                  onPressed: () => update(() => local = false),
                  child: const Text('Show Telegram'),
                ),
                onPlay: (rows, index) => selected = (rows, index),
                onOpenFiles: () {},
                platform: platform,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(platform.scans, isEmpty);
    expect(platform.picks, 0);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(platform.scans, isEmpty);
    expect(settings.localMediaFolders, isEmpty);

    platform.selectedFolder = _androidFolder;
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
    await tester.tap(find.text('Choose folder'));
    await settleScan(tester);
    expect(settings.localMediaFolders, [_androidFolder]);
    expect(platform.picks, 2);
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
    await tester.tap(find.text('Show Telegram'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show device'));
    await tester.pumpAndSettle();
    expect(platform.scans, hasLength(1));
    expect(find.text('S01E02.mp4'), findsOneWidget);
    expect(find.text('Added S01E4.mp4'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 330));
    await pumpUntil(
      tester,
      () => find.text('Added S01E4.mp4').evaluate().isNotEmpty,
      reason: 'Pull-to-refresh did not display the updated local video list.',
    );
    await tester.pumpAndSettle();
    expect(find.text('S01E02.mp4'), findsNothing);
    expect(find.text('Added S01E4.mp4'), findsOneWidget);
    expect(platform.scans.map((scan) => scan.$1), [true, true]);
    expect(platform.scans.map((scan) => scan.$2), [
      [_androidFolder.location],
      [_androidFolder.location],
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('local Music uses shared song rows and opens folders', (
    tester,
  ) async {
    final platform = _DeviceMedia(android: false)
      ..selectedFolder = _windowsFolder
      ..entries = [media('Alpha.mp3'), media('Beta.mp3')];
    final settings = MemorySettings();
    addTearDown(platform.events.close);
    (List<LocalMedia>, int)? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalMediaViewPane(
            settings: settings,
            video: false,
            bottomPadding: 8,
            onPlay: (rows, index) => selected = (rows, index),
            onOpenFiles: () {},
            platform: platform,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose folder'));
    await settleScan(tester);
    expect(settings.localMediaFolders, [_windowsFolder]);
    expect(platform.scans.single.$2, [_windowsFolder.location]);
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
    settings.favoriteIds.add(platform.entries.last.track.id);
    await tester.tap(find.byTooltip('Show Favorites'));
    await settleScan(tester);
    expect(find.text('Beta.mp3'), findsOneWidget);
    expect(find.text('Alpha.mp3'), findsNothing);
    final actions = find.byTooltip('Local library actions');
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove Media from library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Choose folder'), findsOneWidget);
    expect(settings.localMediaFolders, isEmpty);
    expect(platform.scans, hasLength(1));
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
      expect(find.text('Choose folder'), findsOneWidget);
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
