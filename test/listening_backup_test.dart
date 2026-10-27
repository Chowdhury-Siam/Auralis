import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/data_backup.dart';
import 'package:auralis/data_files.dart';
import 'package:auralis/listening.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/stats_view.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const song = Track(
  id: '-1:1',
  title: 'Evening waves',
  artist: 'Original artist',
  source: 'Music',
  fileId: 1,
  size: 100,
  duration: Duration(minutes: 2),
);

class SampleAudio extends FakeAudio {
  @override
  Future<void> open(String uri) async {
    position = Duration.zero;
    await super.open(uri);
  }

  void sample({
    Duration advance = Duration.zero,
    bool? isPlaying,
    bool? isBuffering,
  }) {
    position += advance;
    if (isPlaying != null) playing = isPlaying;
    if (isBuffering != null) buffering = isBuffering;
    notifyListeners();
  }
}

class MemoryDataSettings extends MemorySettings {
  List<int>? recovery;
  @override
  Future<void> replaceSnapshot(
    Map<String, dynamic> data,
    List<int> backup,
  ) async {
    recovery = backup;
    applyJson(data);
  }
}

class ChosenFiles extends DataFiles {
  String? chosenSave = testExportPath('export.json'), chosenOpen;
  final contents = <String, String>{};
  @override
  Future<String?> savePath(String name, String extension) async => chosenSave;
  @override
  Future<String?> openBackup() async => chosenOpen;
  @override
  Future<String> read(String path) async => contents[path]!;
  @override
  Future<void> write(String path, String text) async {
    contents[path] = text;
  }
}

void main() {
  setUpAll(() async {
    final font = File(
      Platform.isWindows
          ? 'C:/Windows/Fonts/segoeui.ttf'
          : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    );
    if (font.existsSync()) {
      await (FontLoader('Segoe UI')
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('media preferences round-trip and old backups retain safe defaults', () {
    final settings = MemorySettings()
      ..lyricsFirst = LyricsSource.lyricsOvh
      ..lyricsFallback = LyricsSource.lrclib
      ..translationFirst = TranslationSource.myMemory
      ..translationFallback = TranslationSource.google
      ..artworkPreload = 20;
    final saved = DataBackup.parse(
      DataBackup.create(settings, DateTime.now()).encode(),
    );
    final restored = MemorySettings()..applyJson(saved.snapshot);
    expect(restored.lyricsFirst, LyricsSource.lyricsOvh);
    expect(restored.translationFirst, TranslationSource.myMemory);
    expect(restored.artworkPreload, 20);
    final legacy = {...saved.snapshot}
      ..removeWhere(
        (key, _) => const {
          'automaticLyrics',
          'automaticTranslation',
          'keepArtwork',
          'artworkPreload',
          'lyricsFirst',
          'lyricsFallback',
          'translationFirst',
          'translationFallback',
          'translationDirection',
        }.contains(key),
      );
    DataBackup.validateSnapshot(legacy);
    restored.applyJson(legacy);
    expect(
      restored.automaticLyrics &&
          restored.automaticTranslation &&
          restored.keepArtwork,
      isTrue,
    );
    expect(restored.artworkPreload, 10);
    expect(
      () => DataBackup.validateSnapshot({
        ...saved.snapshot,
        'artworkPreload': -1,
      }),
      throwsFormatException,
    );
  });

  test('observed active playback counts; seeks, buffering, pauses and long gaps do not inflate time', () async {
    final audio = SampleAudio()..duration = song.duration;
    var elapsed = Duration.zero;
    final base = DateTime(2026, 10, 20, 12);
    final settings = MemorySettings();
    final player = PlayerController(
      audio,
      TelegramStreamProxy((_) async => {}),
      settings,
      now: () => base.add(elapsed),
      elapsed: () => elapsed,
    );
    addTearDown(player.shutdown);
    await player.play(song);
    void tick({
      bool? playing,
      bool? buffering,
      int milliseconds = 1000,
      bool advance = true,
    }) {
      elapsed += Duration(milliseconds: milliseconds);
      audio.sample(
        advance: advance ? Duration(milliseconds: milliseconds) : Duration.zero,
        isPlaying: playing,
        isBuffering: buffering,
      );
    }

    for (var i = 0; i < 40; i++) {
      tick();
    }
    expect(settings.listening.milliseconds, 40000);
    expect(settings.listening.plays, 1);
    audio.sample(isPlaying: false);
    tick(milliseconds: 10000, advance: false);
    audio.sample(isPlaying: true);
    for (var i = 0; i < 5; i++) {
      tick();
    }
    audio.sample(isBuffering: true);
    tick(milliseconds: 3000, advance: false);
    audio.sample(isBuffering: false);
    expect(settings.listening.milliseconds, 45000);
    await player.seek(const Duration(hours: 1));
    expect(settings.listening.milliseconds, 45000);
    tick();
    await player.seek(const Duration(seconds: 2));
    tick();
    tick(milliseconds: 3600000);
    expect(settings.listening.milliseconds, 47000);
    tick();
    expect(settings.listening.milliseconds, 48000);
    expect(settings.listening.plays, 1);
    await player.flushListeningStats();
  });

  test('short tracks qualify at half duration and a repeated track can qualify again', () async {
    final audio = SampleAudio()..duration = const Duration(seconds: 10);
    var elapsed = Duration.zero;
    final settings = MemorySettings();
    final player = PlayerController(
      audio,
      TelegramStreamProxy((_) async => {}),
      settings,
      now: () => DateTime(2026, 10, 20).add(elapsed),
      elapsed: () => elapsed,
    );
    addTearDown(player.shutdown);
    await player.play(song);
    for (var i = 0; i < 5; i++) {
      elapsed += const Duration(seconds: 1);
      audio.sample(advance: const Duration(seconds: 1));
    }
    expect(settings.listening.plays, 1);
    player.toggleRepeat();
    player.toggleRepeat();
    audio.onCompleted!();
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 5; i++) {
      elapsed += const Duration(seconds: 1);
      audio.sample(advance: const Duration(seconds: 1));
    }
    expect(settings.listening.plays, 2);
    expect(settings.listening.milliseconds, 10000);
    player.toggleRepeat();
    audio.sample(isPlaying: false);
    audio.onCompleted!();
    await Future<void>.delayed(Duration.zero);
    await player.seek(Duration.zero);
    audio.sample(isPlaying: true);
    for (var i = 0; i < 5; i++) {
      elapsed += const Duration(seconds: 1);
      audio.sample(advance: const Duration(seconds: 1));
    }
    expect(settings.listening.plays, 3);
    expect(settings.listening.milliseconds, 15000);
  });

  test(
    'day splitting, metadata, CSV quoting and JSON statistics round-trip',
    () {
      const tricky = Track(
        id: '-9:1',
        title: '=HYPERLINK("test")\nwords',
        artist: '@Artist',
        source: 'Music, channel',
      );
      final stats = ListeningStats()
        ..record(tricky, 2000, 1, DateTime(2026, 10, 21, 0, 0, 1));
      expect(stats.days['2026-10-20']!.milliseconds, 1000);
      expect(stats.days['2026-10-21']!.milliseconds, 1000);
      expect(stats.days['2026-10-21']!.plays, 1);
      final restored = ListeningStats.fromJson(
        jsonDecode(jsonEncode(stats.toJson())),
      );
      expect(restored.toJson(), stats.toJson());
      expect(restored.topArtists.single.key, '@Artist');
      final csv = stats.toCsv();
      expect(csv, startsWith('\uFEFFrecord_type,'));
      expect(csv, contains('"\'=HYPERLINK(""test"")\nwords"'));
      expect(csv, contains('"\'@Artist"'));
      expect(csv, contains('"Music, channel"'));
      expect(csv, contains('day,2026-10-20,,,,,1.000,0,'));
      final longStats = ListeningStats()
        ..record(
          Track(
            id: 'long',
            title: 'x' * 2000,
            artist: 'y' * 2000,
            source: 'z' * 2000,
          ),
          1000,
          0,
          DateTime(2026, 10, 21),
        );
      expect(
        ListeningStats.fromJson(longStats.toJson())
            .tracks['long']!
            .title
            .length,
        1000,
      );
      final invalid = stats.toJson();
      (invalid['days'] as Map)['2026-10-20']['milliseconds'] = -1;
      expect(() => ListeningStats.fromJson(invalid), throwsFormatException);
    },
  );

  test('backup integrity and schema are validated before playback or settings change', () async {
    final settings = MemorySettings()..favoriteIds = {song.id};
    final audio = FakeAudio()..playing = true;
    final player =
        PlayerController(audio, TelegramStreamProxy((_) async => {}), settings)
          ..queue.add(song)
          ..index = 0;
    addTearDown(player.shutdown);
    final good = DataBackup.create(settings, DateTime(2026, 10, 20));
    final encoded = good.encode();
    expect(DataBackup.parse(encoded).snapshot, settings.toJson());
    expect(encoded, isNot(contains('apiHash')));
    expect(encoded, isNot(contains('fileId')));
    expect(
      () => DataBackup.parse(
        encoded.replaceFirst('"volume": 70.0', '"volume": 71.0'),
      ),
      throwsFormatException,
    );
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    json['version'] = 99;
    expect(() => DataBackup.parse(jsonEncode(json)), throwsFormatException);
    good.snapshot['volume'] = 400;
    await expectLater(player.restoreBackup(good), throwsFormatException);
    expect(settings.favoriteIds, {song.id});
    expect(settings.volume, 70);
    expect(player.queue, [song]);
    expect(audio.playing, isTrue);
  });

  test('restore writes valid data atomically and leaves a portable UTF-8 recovery backup', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-restore-');
    addTearDown(() => dir.delete(recursive: true));
    final settings = AppSettings(File('${dir.path}/settings.json'))
      ..volume = 23
      ..favoriteIds = {song.id}
      ..playlists = {
        '夜の音楽': [song.id],
      };
    settings.listening.record(song, 5000, 0, DateTime(2026, 10, 20));
    await settings.save();
    final candidate = MemorySettings()
      ..volume = 82
      ..favoriteIds = {'-2:2'}
      ..selectedChannels = [const MusicChat(-2, 'New channel')];
    candidate.listening.record(song, 60000, 1, DateTime(2026, 10, 21));
    final audio = FakeAudio()..playing = true;
    final player =
        PlayerController(audio, TelegramStreamProxy((_) async => {}), settings)
          ..queue.add(song)
          ..index = 0;
    addTearDown(player.shutdown);
    await player.restoreBackup(
      DataBackup.create(candidate, DateTime(2026, 10, 21)),
    );
    expect(settings.toJson(), candidate.toJson());
    expect(player.queue, isEmpty);
    expect(audio.playing, isFalse);
    expect(audio.volumes.last, 82);
    final disk = AppSettings(settings.file);
    await disk.load();
    expect(disk.toJson(), candidate.toJson());
    final recovery = DataBackup.parse(
      await File('${dir.path}/auralis-before-restore.json').readAsString(),
    );
    expect(recovery.snapshot['playlists'], {
      '夜の音楽': [song.id],
    });
    expect(recovery.snapshot['volume'], 23);
    await player.restoreBackup(recovery);
    expect(settings.volume, 23);
    expect(settings.listening.milliseconds, 5000);
  });

  test(
    'a failed restore write leaves current settings and on-disk data intact',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'auralis-failed-restore-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final settings = AppSettings(File('${dir.path}/settings.json'))
        ..volume = 23;
      await settings.save();
      final original = await settings.file.readAsString();
      await Directory('${settings.file.path}.tmp').create();
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      addTearDown(player.shutdown);
      await expectLater(
        player.restoreBackup(
          DataBackup.create(MemorySettings()..volume = 90, DateTime.now()),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(settings.volume, 23);
      expect(await settings.file.readAsString(), original);
    },
  );

  test(
    'real export files preserve Unicode and backup reads reject invalid bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp('auralis-data-files-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/backup.json';
      const files = DataFiles();
      final settings = MemorySettings()
        ..playlists = {
          '音楽': [song.id],
        };
      final text = DataBackup.create(settings, DateTime.now()).encode();
      await files.write(path, text);
      expect(DataBackup.parse(await files.read(path)).snapshot['playlists'], {
        '音楽': [song.id],
      });
      await File(path).writeAsBytes([255, 255]);
      await expectLater(files.read(path), throwsFormatException);
    },
  );

  testWidgets(
    'compact stats show the overview and keep rankings usable with large text',
    (tester) async {
      final settings = MemoryDataSettings()..reducedMotion = true;
      settings.listening.record(song, 125000, 2, DateTime.now());
      final before = jsonEncode(settings.listening.toJson());
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      addTearDown(player.shutdown);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final (size, scale) in [
        (const Size(360, 480), 1.0),
        (const Size(320, 568), 2.0),
        (const Size(1280, 800), 1.0),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'Segoe UI',
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: StatsDataDialog(player: player, files: ChosenFiles()),
          ),
        );
        await tester.pumpAndSettle();
        if (scale == 1) {
          expect(
            find.text(song.title).hitTestable(),
            findsOneWidget,
            reason: 'The activity overview and first ranked track fit without scrolling',
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('stats-summary'))).height,
            lessThan(110),
          );
        }
        final tabs = find.byKey(const ValueKey('stats-ranking-tabs'));
        await tester.ensureVisible(tabs);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: tabs, matching: find.text('Artists')),
        );
        await tester.pumpAndSettle();
        expect(find.text(song.artist), findsOneWidget);
        expect(find.text(song.title), findsNothing);
        await tester.tap(
          find.descendant(of: tabs, matching: find.text('Tracks')),
        );
        await tester.pumpAndSettle();
        expect(find.text(song.title), findsOneWidget);
        expect(find.text('Create backup'), findsNothing);
        expect(jsonEncode(settings.listening.toJson()), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      // An empty history must also render a finite, zero-valued activity chart.
      settings.listening = ListeningStats();
      await tester.pumpWidget(
        MaterialApp(home: StatsDataDialog(player: player)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Play some music'), findsOneWidget);
      expect(find.byKey(const ValueKey('stats-ranking-tabs')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stats layouts, CSV/JSON export, backup, restore preview and cancellation',
    (tester) async {
      final settings = MemoryDataSettings()
        ..reducedMotion = true
        ..favoriteIds = {song.id};
      settings.listening.record(song, 125000, 2, DateTime.now());
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      addTearDown(player.shutdown);
      final files = ChosenFiles();
      final boundary = GlobalKey();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget view() => MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Segoe UI'),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: StatsDataDialog(player: player, files: files),
          ),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      for (final size in [const Size(1280, 800), const Size(360, 480)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(find.text('2m 5s'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('docs/screenshots/stats-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      Future<void> click(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      // Keep the safety check covered while using native external paths below.
      files.chosenSave = settings.file.absolute.path;
      await click('Export CSV');
      expect(files.contents, isEmpty);
      expect(
        find.text(
          'Choose a destination outside Auralis’s internal app-data folder.',
        ),
        findsOneWidget,
      );

      files.chosenSave = testExportPath('stats.csv');
      await click('Export CSV');
      expect(
        files.contents[testExportPath('stats.csv')],
        contains('qualified_plays'),
      );
      files.chosenSave = testExportPath('stats.json');
      await click('Export JSON');
      expect(
        jsonDecode(files.contents[testExportPath('stats.json')]!)['format'],
        'auralis-listening-stats',
      );
      await click('Backup & Restore');
      files.chosenSave = testExportPath('backup.json');
      await click('Create backup');
      expect(
        DataBackup.parse(files.contents[testExportPath('backup.json')]!)
            .snapshot['favoriteIds'],
        [song.id],
      );
      files.chosenSave = null;
      final before = files.contents.length;
      await click('Create backup');
      expect(files.contents.length, before);
      final candidate = MemorySettings()
        ..favoriteIds = {'-9:9'}
        ..volume = 55;
      files.chosenOpen = testExportPath('restore.json');
      files.contents[files.chosenOpen!] = DataBackup.create(
        candidate,
        DateTime.now(),
      ).encode();
      await click('Restore backup');
      expect(
        find.textContaining('Telegram sign-in: not included.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.favoriteIds, {song.id});
      await click('Restore backup');
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(settings.favoriteIds, {'-9:9'});
      expect(settings.volume, 55);
      expect(settings.recovery, isNotNull);
      expect(
        find.textContaining('This backup has no Telegram sign-in'),
        findsOneWidget,
      );
      files.contents[files.chosenOpen!] = '{broken';
      await click('Restore backup');
      expect(settings.favoriteIds, {'-9:9'});
      expect(find.textContaining('Unexpected'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Android restore reports provider errors, retries and keeps committed settings after refresh fails',
    (tester) async {
      const channel = MethodChannel('app.auralis/platform');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final settings = MemoryDataSettings()..volume = 23;
      final candidate = MemorySettings()..volume = 55;
      final bytes = utf8.encode(
        DataBackup.create(candidate, DateTime.now()).encode(),
      );
      var denied = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openDocument') {
          return 'content://test.documents/backup.json';
        }
        if (call.method == 'readDocument') {
          if (denied) {
            throw PlatformException(
              code: 'document_permission',
              message: 'Select the backup again using the system file picker.',
            );
          }
          return bytes;
        }
        throw StateError('Unexpected call: ${call.method}');
      });
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      addTearDown(player.shutdown);
      await tester.pumpWidget(
        MaterialApp(
          home: StatsDataDialog(
            player: player,
            files: const AndroidDataFiles(),
            openBackupSection: true,
            onRestored: () async => throw StateError('Refresh failed'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore backup'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Restore failed (document_permission)'),
        findsOneWidget,
      );
      expect(settings.volume, 23);
      expect(settings.recovery, isNull);
      denied = false;
      await tester.tap(find.text('Restore backup'));
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(settings.volume, 55);
      expect(settings.recovery, isNotNull);
      expect(find.textContaining('Settings restored.'), findsOneWidget);
      expect(find.textContaining('Reopen the Library'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'listening stats and backup remain reachable from compact Settings',
    (tester) async {
      final settings = MemoryDataSettings()..reducedMotion = true;
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final td = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(player.shutdown);
      addTearDown(td.shutdown);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 480);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: AuralisApp(
            player: player,
            telegram: td,
            dataFiles: ChosenFiles(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Listening stats'), findsNothing);
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'backup',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Data & sync'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Listening stats'));
      await tester.pumpAndSettle();
      expect(find.byType(StatsDataDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(StatsDataDialog), findsNothing);
      await tester.ensureVisible(find.text('Backup & Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup & Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Create backup').hitTestable(), findsOneWidget);
      expect(find.text('Restore backup').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('docs/screenshots/backup-360.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
