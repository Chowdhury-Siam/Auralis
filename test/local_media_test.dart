import 'dart:convert';
import 'dart:io';

import 'package:auralis/local_media.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
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

class _AndroidFolderChannel extends LocalMediaPlatform {
  @override
  bool get android => true;
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
    'retired device-library preferences are ignored without deleting media',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'auralis-retired-device-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final media = await File(p.join(folder.path, 'keep.mp4'))
          .writeAsString('media');
      final settings = AppSettings(File(p.join(folder.path, 'settings.json')));
      await settings.file.writeAsString(
        jsonEncode({
          '_musicLibraryOnDevice': true,
          '_videoLibraryOnDevice': true,
          '_localMediaFolders': [folder.path],
          'favoriteIds': ['kept-song'],
          'volume': 35,
        }),
      );
      await settings.load();
      expect(settings.favoriteIds, {'kept-song'});
      expect(settings.volume, 35);
      await settings.save();
      final saved = jsonDecode(await settings.file.readAsString()) as Map;
      expect(saved.containsKey('_musicLibraryOnDevice'), isFalse);
      expect(saved.containsKey('_videoLibraryOnDevice'), isFalse);
      expect(saved.containsKey('_localMediaFolders'), isFalse);
      expect(saved['favoriteIds'], ['kept-song']);
      expect(await media.readAsString(), 'media');
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
}
