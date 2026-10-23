import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/data_files.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_view.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const song = Track(
  id: 'one',
  title: 'Evening waves',
  artist: 'Auralis test artist',
  source: 'Music channel',
);
const second = Track(
  id: 'two',
  title: 'Morning light',
  artist: 'Auralis test artist',
  source: 'Music channel',
);
final fixture =
    '[00:00]A quiet start\n[00:08]Small lights over water\n[00:16]The evening carries us home\n[00:24]We follow the river\n${List.generate(28, (i) => '[${((i + 4) * 8) ~/ 60}:${(((i + 4) * 8) % 60).toString().padLeft(2, '0')}]Original test line ${i + 4}').join('\n')}';

class PendingLyrics extends LyricsRepository {
  final pending = Completer<Lyrics?>();
  int calls = 0;
  @override
  Future<Lyrics?> find(Track track) {
    calls++;
    return pending.future;
  }
}

class LrcFiles extends DataFiles {
  String? path = 'selected.lrc';
  Uint8List bytes = Uint8List.fromList(
    utf8.encode('[00:00]Original imported line'),
  );
  Completer<String?>? pending;
  int? limit;
  @override
  Future<String?> openLyrics() => pending?.future ?? Future.value(path);
  @override
  Future<Uint8List> readBytes(
    String path, {
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    limit = maxBytes;
    return bytes;
  }
}

Future<void> chooseImport(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Lyrics options').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Import .lrc file').last);
  await tester.pumpAndSettle();
}

PlayerController controller() =>
    PlayerController(
        FakeAudio()..duration = const Duration(minutes: 5),
        TelegramStreamProxy((_) async => {}),
        MemorySettings()..reducedMotion = true,
      )
      ..queue.add(song)
      ..index = 0;

Widget view(
  PlayerController player,
  LyricsRepository repository, {
  Future<Lyrics?> Function(Track)? embedded,
  DataFiles files = const DataFiles(),
}) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Segoe UI'),
  ),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: player,
      builder: (_, _) => LyricsView(
        player: player,
        repository: repository,
        loadEmbedded: embedded,
        files: files,
        artwork: const Icon(Icons.album),
        onBack: () {},
      ),
    ),
  ),
);

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

  testWidgets(
    'imports LRC; cancellation and invalid files preserve existing lyrics',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository();
      final files = LrcFiles();
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository, files: files));
      await tester.tap(find.widgetWithText(TextButton, 'Import .lrc file'));
      await tester.pumpAndSettle();
      expect(find.text('Original imported line'), findsOneWidget);
      expect(find.text('Imported LRC · session only'), findsOneWidget);
      expect(repository.cached(song)!.imported, isTrue);
      expect(files.limit, Lyrics.maxFileBytes);
      final imported = repository.cached(song);
      files.path = null;
      await chooseImport(tester);
      expect(repository.cached(song), same(imported));
      files.path = 'invalid.lrc';
      files.bytes = Uint8List.fromList([255]);
      await chooseImport(tester);
      expect(repository.cached(song), same(imported));
      expect(find.textContaining('Could not import lyrics.'), findsOneWidget);
      expect(find.text('Original imported line'), findsOneWidget);
    },
  );

  testWidgets('an import picked for a previous song is discarded', (
    tester,
  ) async {
    final player = controller();
    final repository = LyricsRepository();
    final files = LrcFiles()..pending = Completer<String?>();
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    await tester.pumpWidget(view(player, repository, files: files));
    await tester.tap(find.widgetWithText(TextButton, 'Import .lrc file'));
    await tester.pump();
    player.queue.add(second);
    player.index = 1;
    player.notifyListeners();
    await tester.pump();
    files.pending!.complete('selected.lrc');
    await tester.pumpAndSettle();
    expect(repository.cached(song), isNull);
    expect(repository.cached(second), isNull);
    expect(files.limit, isNull);
  });

  testWidgets(
    'embedded lyrics load automatically and late songs cannot overwrite',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository();
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      final pending = Completer<Lyrics?>();
      var calls = 0;
      Future<Lyrics?> load(Track track) async {
        calls++;
        if (track.id == song.id) return pending.future;
        return Lyrics.parse('Original embedded second song', embedded: true);
      }

      await tester.pumpWidget(view(player, repository, embedded: load));
      expect(calls, 1);
      player.queue.add(second);
      player.index = 1;
      player.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Original embedded second song'), findsOneWidget);
      expect(find.text('Lyrics from music file'), findsOneWidget);
      pending.complete(
        Lyrics.parse('Stale embedded first song', embedded: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stale embedded first song'), findsNothing);
      expect(repository.cached(second)!.embedded, isTrue);
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('lyrics-immersive')))
            .color,
        const Color(0xFF111015),
      );
      expect(lyricsHighlight, accent);
    },
  );

  testWidgets('both lyrics menus keep their action labels', (tester) async {
    final player = controller();
    final repository = LyricsRepository()
      ..save(song, Lyrics.parse('Cached lyrics'));
    addTearDown(player.shutdown);
    addTearDown(repository.close);

    await tester.pumpWidget(
      view(
        player,
        repository,
        embedded: (_) async => Lyrics.parse('Embedded lyrics', embedded: true),
      ),
    );
    await tester.pumpAndSettle();
    final buttons = find.byTooltip('Lyrics options');
    expect(buttons, findsNWidgets(2));

    for (final index in [0, 1]) {
      await tester.tap(buttons.at(index));
      await tester.pumpAndSettle();
      expect(find.text('Import .lrc file'), findsOneWidget);
      expect(find.text('Read lyrics from music file'), findsOneWidget);
      expect(find.text('Find lyrics on LRCLIB'), findsOneWidget);
      expect(find.text('Paste lyrics'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Read lyrics from music file'), findsNothing);
    }
  });

  testWidgets('cached pasted lyrics take precedence over embedded tags', (
    tester,
  ) async {
    final player = controller();
    final repository = LyricsRepository()
      ..save(song, Lyrics.parse('Original pasted words'));
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    var calls = 0;
    await tester.pumpWidget(
      view(
        player,
        repository,
        embedded: (_) async {
          calls++;
          return Lyrics.parse('Original embedded words', embedded: true);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Original pasted words'), findsOneWidget);
    await tester.tap(find.byTooltip('Lyrics options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read lyrics from music file'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Original embedded words'), findsOneWidget);
  });

  testWidgets(
    'sync follows playback and seek, manual scrolling can resume, static reads all',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()..save(song, Lyrics.parse(fixture));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      await player.audio.seek(const Duration(seconds: 160));
      await tester.pumpAndSettle();
      expect(find.text('Original test line 20'), findsOneWidget);
      final active = tester.widget<AnimatedDefaultTextStyle>(
        find
            .ancestor(
              of: find.text('Original test line 20'),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .first,
      );
      expect(active.style.color, lyricsHighlight);
      await tester.tap(find.byKey(const ValueKey('lyric-21')));
      await tester.pumpAndSettle();
      expect(player.audio.position, const Duration(seconds: 168));
      await tester.drag(
        find.byKey(const ValueKey('synced-lyrics')),
        const Offset(0, 200),
      );
      await tester.pumpAndSettle();
      expect(find.text('Follow song'), findsOneWidget);
      await tester.tap(find.text('Follow song'));
      await tester.pumpAndSettle();
      expect(find.text('Follow song'), findsNothing);
      await tester.tap(find.text('Static'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        contains('Original test line 31'),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reference controls seek, toggle playback and center multiline lyrics',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()
        ..save(
          song,
          Lyrics.parse(
            '[00:00]Opening words\n[00:08]A longer original test line that wraps across the narrow window\n[00:16]Another line\n[00:24]Last words',
          ),
        );
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await player.audio.seek(const Duration(seconds: 8));
      for (final size in [
        const Size(360, 480),
        const Size(390, 844),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(view(player, repository));
        await tester.pumpAndSettle();
        final viewport = tester.getRect(
          find.byKey(const ValueKey('synced-lyrics')),
        );
        final line = tester.getRect(find.byKey(const ValueKey('lyric-1')));
        expect(line.center.dy, closeTo(viewport.center.dy, 1), reason: '$size');
        expect(find.byKey(const ValueKey('lyric-focus-1')), findsOneWidget);
        // Check materialized rows without forcing the lazy list to build
        // offscreen lines in short phone viewports.
        for (final filter in tester.widgetList<ImageFiltered>(
          find.descendant(
            of: find.byKey(const ValueKey('synced-lyrics')),
            matching: find.byType(ImageFiltered),
          ),
        )) {
          expect(
            filter.enabled,
            filter.key != const ValueKey('lyric-focus-1'),
            reason: 'Only the highlighted line stays sharp at $size',
          );
        }
        final neighbor = tester.widget<AnimatedDefaultTextStyle>(
          find.descendant(
            of: find.byKey(const ValueKey('lyric-2')),
            matching: find.byType(AnimatedDefaultTextStyle),
          ),
        );
        expect(neighbor.style.color!.a, greaterThanOrEqualTo(.5));
        expect(find.text(song.title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      final play = find.byKey(const ValueKey('lyrics-play-pause'));
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(player.audio.playing, isTrue);
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(player.audio.playing, isFalse);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('playback-seek')),
      );
      expect(slider.secondaryTrackValue, isNull);
      slider.onChanged!(.5);
      await tester.pumpAndSettle();
      expect(player.audio.position, const Duration(seconds: 150));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('focus blur follows the highlight and static lyrics stay clear', (
    tester,
  ) async {
    final player = controller();
    final repository = LyricsRepository()
      ..save(
        song,
        Lyrics.parse(
          '[00:08]Opening words\n[00:16]The highlighted middle line\n[00:24]Closing words',
        ),
      );
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    await tester.pumpWidget(view(player, repository));
    await tester.pumpAndSettle();
    bool softened(int index) => tester
        .widget<ImageFiltered>(find.byKey(ValueKey('lyric-focus-$index')))
        .enabled;
    // There is no highlighted line before the first timestamp.
    for (var index = 0; index < 3; index++) {
      expect(softened(index), isFalse);
    }
    await player.audio.seek(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(softened(0), isFalse);
    expect(softened(1), isTrue);
    expect(softened(2), isTrue);
    await player.audio.seek(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(softened(0), isTrue);
    expect(softened(1), isFalse);
    expect(softened(2), isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(find.text('Static'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byKey(const ValueKey('lyric-focus-1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'lyrics remain usable with large text and system reduced motion',
    (tester) async {
      final player = controller()..settings.reducedMotion = false;
      final repository = LyricsRepository()..save(song, Lyrics.parse(fixture));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 480);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      await player.audio.seek(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lyric-2')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lyrics-play-pause')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lyric advances blur briefly, settle sharply, and respect manual and reduced motion',
    (tester) async {
      final player = controller()..settings.reducedMotion = false;
      final repository = LyricsRepository()..save(song, Lyrics.parse(fixture));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      bool blurred() => tester
          .widget<ImageFiltered>(
            find.byKey(const ValueKey('lyrics-motion-blur')),
          )
          .enabled;
      expect(blurred(), isFalse);
      bool softened(int index) => tester
          .widget<ImageFiltered>(find.byKey(ValueKey('lyric-focus-$index')))
          .enabled;
      expect(softened(0), isFalse);
      expect(softened(1), isTrue);

      await player.audio.seek(const Duration(seconds: 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(blurred(), isTrue);
      // A new line during the animation restarts the same bounded transition.
      await player.audio.seek(const Duration(seconds: 16));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(blurred(), isTrue);
      await tester.pumpAndSettle();
      expect(blurred(), isFalse);
      expect(softened(2), isFalse);
      expect(softened(1), isTrue);
      expect(softened(3), isTrue);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('synced-lyrics')),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('lyric-2'))).center.dy,
        closeTo(viewport.center.dy, 1),
      );

      await tester.drag(
        find.byKey(const ValueKey('synced-lyrics')),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();
      await player.audio.seek(const Duration(seconds: 24));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(blurred(), isFalse);
      expect(softened(3), isFalse);
      expect(softened(2), isTrue);
      expect(find.text('Follow song'), findsOneWidget);
      await tester.tap(find.text('Follow song'));
      await tester.pumpAndSettle();

      player.settings.reducedMotion = true;
      await player.audio.seek(const Duration(seconds: 32));
      await tester.pumpAndSettle();
      expect(blurred(), isFalse);
      expect(softened(4), isFalse);
      expect(softened(3), isTrue);
      expect(tester.binding.hasScheduledFrame, isFalse);

      player.settings.reducedMotion = false;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await player.audio.seek(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      expect(blurred(), isFalse);
      expect(softened(5), isFalse);
      expect(softened(4), isTrue);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('lookup needs a click; stale results cannot replace a new song', (
    tester,
  ) async {
    final player = controller();
    final repository = PendingLyrics();
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    await tester.pumpWidget(view(player, repository));
    expect(repository.calls, 0);
    expect(find.textContaining('title, artist and duration'), findsOneWidget);
    await tester.tap(find.text('Find lyrics'));
    await tester.pump();
    expect(repository.calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    player.queue[0] = second;
    await player.audio.seek(Duration.zero);
    await tester.pump();
    repository.pending.complete(Lyrics.parse('[00:00]Stale result'));
    await tester.pumpAndSettle();
    expect(find.text('Stale result'), findsNothing);
    expect(find.text('Morning light'), findsOneWidget);
    expect(find.text('Find lyrics'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'plain, not found, instrumental and network errors have useful states',
    (tester) async {
      final player = controller();
      addTearDown(player.shutdown);
      for (final lyrics in [
        Lyrics.parse('Original plain words'),
        null,
        Lyrics.parse('', instrumental: true),
      ]) {
        final repository = LyricsRepository()..save(song, lyrics);
        await tester.pumpWidget(view(player, repository));
        await tester.pumpAndSettle();
        if (lyrics?.instrumental == true) {
          expect(find.text('Instrumental · no lyrics'), findsOneWidget);
        } else if (lyrics != null) {
          expect(find.byType(SelectableText), findsOneWidget);
          final syncedButton = tester.widget<TextButton>(
            find.byKey(const ValueKey('lyrics-synced-mode')),
          );
          expect(syncedButton.onPressed, isNull);
        } else {
          expect(find.text('No lyrics found for this song.'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        repository.close();
      }
      final repository = PendingLyrics();
      await tester.pumpWidget(view(player, repository));
      await tester.tap(find.text('Find lyrics'));
      await tester.pump();
      repository.pending.completeError(const SocketException('offline'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load lyrics'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      repository.close();
    },
  );

  testWidgets(
    'Now Playing opens lyrics, paste works, wide and tiny layouts stay usable',
    (tester) async {
      final player = controller();
      final td = FakeTd();
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      );
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
      await tester.tap(find.text('Lyrics').first);
      await tester.pumpAndSettle();
      expect(find.byType(LyricsView), findsOneWidget);
      final backdrop = find.byKey(const ValueKey('now-playing-backdrop'));
      expect(backdrop, findsOneWidget);
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('lyrics-immersive')))
            .color,
        Colors.transparent,
        reason:
            'The full-page artwork background remains visible behind lyrics',
      );
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('player-bar')), findsNothing);
      expect(find.byKey(const ValueKey('lyrics-song-pill')), findsOneWidget);
      expect(find.byKey(const ValueKey('playback-seek')), findsOneWidget);
      await tester.tap(find.text('Paste lyrics instead'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, fixture);
      await tester.tap(find.text('Use lyrics'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await player.audio.seek(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      for (final size in [
        const Size(1280, 800),
        const Size(360, 480),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
        expect(find.text('Synced'), findsOneWidget);
        expect(
          tester.getRect(backdrop),
          tester.getRect(find.byKey(const ValueKey('lyrics-immersive'))),
          reason: '$size artwork fills the entire immersive lyrics view',
        );
        expect(
          tester
              .widget<ImageFiltered>(
                find.byKey(const ValueKey('lyric-focus-2')),
              )
              .enabled,
          isFalse,
        );
        expect(
          tester
              .widget<ImageFiltered>(
                find.byKey(const ValueKey('lyric-focus-1')),
              )
              .enabled,
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('lyrics-motion-blur')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('lyric-2')).hitTestable(),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('docs/screenshots/lyrics-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('Back to cover'));
      await tester.pumpAndSettle();
      expect(find.byType(LyricsView), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('player-bar')), findsNothing);
      expect(
        find.byKey(const ValueKey('now-playing-play-pause')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Back to Library'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
