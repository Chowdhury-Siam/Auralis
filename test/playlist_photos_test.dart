import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app_theme.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/music_playlist_widgets.dart';
import 'package:auralis/player.dart';
import 'package:auralis/playlist_photos.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/video_library.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final oldPhoto = '${'a' * 64}.png';
final newPhoto = '${'b' * 64}.png';

class _PhotoFiles extends PlaylistPhotoStore {
  Uint8List? bytes = Uint8List.fromList([1, 2, 3]);
  Completer<Uint8List?>? pending;
  bool fail = false;
  int imports = 0;
  final discarded = <String>[];
  @override
  Future<Uint8List?> pick() async => pending == null ? bytes : pending!.future;
  @override
  Future<String> store(Uint8List bytes) async {
    imports++;
    if (fail) throw const FormatException('Invalid image');
    return newPhoto;
  }

  @override
  Future<void> discard(String? token, PlaylistPhotos photos) async {
    if (token != null && !photos.uses(token)) discarded.add(token);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Segoe UI',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });

  test(
    'photo references are bounded, local, mode-separated and account-scoped',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'auralis-playlist-photos-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final settings = AppSettings(File('${directory.path}/settings.json'));
      settings.playlists['Night'] = ['1:1'];
      final photos = settings.playlistPhotos;
      photos.set('music', 'local', 'Night', oldPhoto);
      photos.set('music', 'account-b', 'Night', newPhoto);
      photos.set('video', 'device', 'Night', newPhoto);
      expect(photos.photo('music', 'local', 'Night'), oldPhoto);
      expect(photos.photo('music', 'account-b', 'Night'), newPhoto);
      expect(photos.photo('video', 'device', 'Night'), newPhoto);
      expect(
        () => photos.set('music', 'local', 'Night', '../../private.png'),
        throwsFormatException,
      );
      await settings.save();
      final saved = jsonDecode(await settings.file.readAsString()) as Map;
      expect(saved['_playlistPhotos'], hasLength(3));
      expect(settings.toJson().containsKey('_playlistPhotos'), isFalse);
      expect(jsonEncode(settings.toJson()), isNot(contains(oldPhoto)));
      final restored = AppSettings(settings.file);
      await restored.load();
      expect(
        restored.playlistPhotos.photo('music', 'local', 'Night'),
        oldPhoto,
      );
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        restored,
      );
      addTearDown(player.shutdown);
      await player.renamePlaylist('Night', 'Evening');
      expect(restored.playlistPhotos.photo('music', 'local', 'Night'), isNull);
      expect(
        restored.playlistPhotos.photo('music', 'local', 'Evening'),
        oldPhoto,
      );
      expect(
        restored.playlistPhotos.photo('video', 'device', 'Night'),
        newPhoto,
      );
      await player.deletePlaylist('Evening');
      expect(
        restored.playlistPhotos.photo('music', 'local', 'Evening'),
        isNull,
      );
      final malformed = PlaylistPhotos()
        ..load({'not-a-key': oldPhoto, 'c' * 64: '../photo.png'});
      expect(malformed.toJson(), isEmpty);
    },
  );

  test('import makes bounded PNG copies and rejects invalid images', () async {
    final directory = await Directory.systemTemp.createTemp(
      'auralis-photo-import-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = PlaylistPhotoStore(directory: directory);
    final original = File('test/fixtures/cover.png');
    final bytes = await original.readAsBytes();
    final token = await store.store(bytes);
    expect(PlaylistPhotos.validToken(token), isTrue);
    final file = await store.file(token);
    expect(await file.exists(), isTrue);
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    final image = (await codec.getNextFrame()).image;
    expect(image.width, lessThanOrEqualTo(512));
    expect(image.height, lessThanOrEqualTo(512));
    image.dispose();
    codec.dispose();
    expect(await store.store(bytes), token);
    await file.writeAsBytes([
      0,
    ]); // A damaged cache entry is repaired on reimport.
    expect(await store.store(bytes), token);
    expect(await file.length(), greaterThan(1));
    await expectLater(store.store(Uint8List(0)), throwsFormatException);
    await expectLater(
      store.store(Uint8List(PlaylistPhotoStore.maxInputBytes + 1)),
      throwsFormatException,
    );
    await expectLater(
      store.store(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
    await expectLater(store.file('../outside.png'), throwsFormatException);
    final photos = PlaylistPhotos()..set('music', 'local', 'One', token);
    await store.discard(token, photos);
    expect(await file.exists(), isTrue);
    photos.remove('music', 'local', 'One');
    await store.discard(token, photos);
    expect(await file.exists(), isFalse);
    expect(await original.readAsBytes(), bytes);
  });

  testWidgets(
    'cancel, invalid import and save failure retain the previous photo',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      final photos = PlaylistPhotos()..set('music', 'local', 'One', oldPhoto);
      final files = _PhotoFiles();
      var saves = 0, refreshes = 0;
      var failSave = false;
      Future<void> change({bool reset = false}) => editPlaylistPhoto(
        context: context,
        photos: photos,
        mode: 'music',
        scope: 'local',
        name: 'One',
        reset: reset,
        valid: () => true,
        store: files,
        save: () async {
          saves++;
          if (failSave) throw StateError('Disk full');
        },
        refresh: () => refreshes++,
      );
      files.bytes = null;
      await change();
      expect(saves, 0);
      expect(photos.photo('music', 'local', 'One'), oldPhoto);
      files.bytes = Uint8List.fromList([1]);
      files.fail = true;
      await change();
      expect(photos.photo('music', 'local', 'One'), oldPhoto);
      files.fail = false;
      failSave = true;
      await change();
      expect(photos.photo('music', 'local', 'One'), oldPhoto);
      expect(files.discarded, contains(newPhoto));
      failSave = false;
      await change();
      expect(photos.photo('music', 'local', 'One'), newPhoto);
      expect(refreshes, 1);
      await change(reset: true);
      expect(photos.photo('music', 'local', 'One'), isNull);
      expect(refreshes, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a late picker cannot overwrite a reset or renamed playlist', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    final photos = PlaylistPhotos()..set('music', 'local', 'One', oldPhoto);
    final files = _PhotoFiles()..pending = Completer<Uint8List?>();
    var saves = 0;
    Future<void> change(bool reset) => editPlaylistPhoto(
      context: context,
      photos: photos,
      mode: 'music',
      scope: 'local',
      name: 'One',
      reset: reset,
      valid: () => true,
      store: files,
      save: () async {
        saves++;
      },
      refresh: () {},
    );
    final pending = change(false);
    await change(true);
    files.pending!.complete(Uint8List.fromList([1]));
    await pending;
    expect(photos.photo('music', 'local', 'One'), isNull);
    expect(files.imports, 0);
    expect(saves, 1);
    files.pending = Completer<Uint8List?>();
    final renamed = change(false);
    photos.rename('music', 'local', 'One', 'Two');
    files.pending!.complete(Uint8List.fromList([1]));
    await renamed;
    expect(files.imports, 0);
    expect(saves, 1);
  });

  testWidgets(
    'Music and Video share card geometry and independent photo actions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Size? musicSize;
      for (final video in [false, true]) {
        var opens = 0, changes = 0, resets = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
            home: Scaffold(
              body: MusicPlaylistsView(
                video: video,
                playlists: const [
                  MusicPlaylistPreview(name: 'One', songCount: 0, tracks: []),
                ],
                artwork: (_) => const SizedBox(),
                onCreate: () {},
                onOpen: (_) => opens++,
                searching: false,
                bottomPadding: 20,
                actionsBuilder: (_) => PlaylistCardMenu(
                  name: 'One',
                  hasPhoto: true,
                  onChangePhoto: () => changes++,
                  onResetPhoto: () => resets++,
                  onRename: () {},
                  onRemove: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final size = tester.getSize(find.byType(MusicPlaylistCard));
        if (video) {
          expect(size, musicSize);
        } else {
          musicSize = size;
        }
        await tester.tap(find.byTooltip('Playlist options: One'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Change playlist photo'));
        await tester.pumpAndSettle();
        expect(changes, 1);
        expect(opens, 0);
        await tester.tap(find.byTooltip('Playlist options: One'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reset photo'));
        await tester.pumpAndSettle();
        expect(resets, 1);
        expect(opens, 0);
      }
    },
  );

  testWidgets(
    'the chosen managed photo renders and reset restores automatic artwork',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('auralis-photo-widget-'),
      ))!;
      final store = PlaylistPhotoStore(directory: directory);
      final token = (await tester.runAsync(
        () async =>
            store.store(await File('test/fixtures/cover.png').readAsBytes()),
      ))!;
      final file = (await tester.runAsync(() => store.file(token)))!;
      String? selected = token;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(home: const Scaffold(body: SizedBox())),
      );
      final context = tester.element(find.byType(Scaffold));
      await tester.runAsync(
        () => precacheImage(ResizeImage(FileImage(file), width: 512), context),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return Scaffold(
                body: SizedBox(
                  width: 240,
                  height: 180,
                  child: PlaylistPhoto(
                    token: selected,
                    store: store,
                    fallback: const Text('Automatic artwork'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Automatic artwork'), findsNothing);
      update(() => selected = null);
      await tester.pumpAndSettle();
      expect(find.text('Automatic artwork'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await directory.delete(recursive: true);
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Video playlist photos follow rename and confirmed removal', (
    tester,
  ) async {
    final data = VideoPlaybackData()..putPlaylist('One', []);
    final photos = PlaylistPhotos()..set('video', 'device', 'One', oldPhoto);
    await tester.pumpWidget(
      MaterialApp(
        theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
        home: VideoLibraryPage(
          data: data,
          save: () async {},
          pickFiles: () async => [],
          playlists: true,
          playlistPhotos: photos,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Playlist options: One'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Two');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(photos.photo('video', 'device', 'Two'), oldPhoto);
    expect(photos.photo('video', 'device', 'One'), isNull);
    await tester.tap(find.byTooltip('Playlist options: Two'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(photos.photo('video', 'device', 'Two'), isNull);
    expect(tester.takeException(), isNull);
  });
}
