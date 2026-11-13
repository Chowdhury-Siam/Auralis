import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/data_files.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/external_links.dart';
import 'package:auralis/lyrics_view.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show Wakelock;
import 'package:wakelock_plus/wakelock_plus.dart' as wakelock;
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'fakes.dart';
import 'updater_test.dart' show Client, Response;

const song = Track(
  id: 'one',
  title: 'Evening waves',
  artist: 'Auralis test artist',
  source: 'Music channel',
);

class TestScreenAwake extends WakelockPlusPlatformInterface {
  final requests = <bool>[];
  bool awake = false;
  @override
  Future<void> toggle({required bool enable}) async {
    awake = enable;
    requests.add(enable);
  }
}

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
  final other = Completer<Lyrics?>();
  int calls = 0;
  @override
  Future<Lyrics?> find(Track track, {bool refresh = false}) {
    calls++;
    return track.id == song.id ? pending.future : other.future;
  }
}

class EditableSearchLyrics extends LyricsRepository {
  final searches = <({Track track, LyricsSearchBy by, String? query})>[];
  final pending = <Completer<List<LyricsSearchMatch>>>[];
  @override
  Future<List<LyricsSearchMatch>> search(
    Track track,
    LyricsSearchBy by, {
    String? query,
  }) {
    searches.add((track: track, by: by, query: query));
    final result = Completer<List<LyricsSearchMatch>>();
    pending.add(result);
    return result.future;
  }
}

LyricsSearchMatch searchMatch(String title, String words) => (
  title: title,
  artist: 'Search artist',
  album: '',
  duration: null,
  lyrics: Lyrics.parse(words),
);

Future<void> openEditableLyricsSearch(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Lyrics options'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Find lyrics online'));
  await tester.pumpAndSettle();
  await tester.longPress(find.text('Find lyrics online'));
  await tester.pumpAndSettle();
}

class TranslationLyrics extends LyricsRepository {
  Completer<Lyrics> result = Completer<Lyrics>();
  int translations = 0;
  bool Function()? isActive;
  @override
  Future<Lyrics> translateJapanese(
    Track track,
    Lyrics source, {
    required bool Function() active,
  }) {
    translations++;
    isActive = active;
    return result.future;
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

Future<void> chooseTranslation(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('lyrics-translate')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

PlayerController controller() =>
    PlayerController(
        FakeAudio()..duration = const Duration(minutes: 5),
        TelegramStreamProxy((_) async => {}),
        MemorySettings()
          ..reducedMotion = true
          ..automaticTranslation = false,
      )
      ..queue.add(song)
      ..index = 0;

Widget view(
  PlayerController player,
  LyricsRepository repository, {
  Future<Lyrics?> Function(Track)? embedded,
  DataFiles files = const DataFiles(),
  Future<void> Function(String) openLink = openExternalLink,
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
        openLink: openLink,
        artwork: const Icon(Icons.album),
        onBack: () {},
      ),
    ),
  ),
);

void main() {
  late TestScreenAwake screenAwake;
  late WakelockPlusPlatformInterface originalScreenAwake;
  setUp(() {
    originalScreenAwake = wakelock.wakelockPlusPlatformInstance;
    wakelock.wakelockPlusPlatformInstance = screenAwake = TestScreenAwake();
  });
  tearDown(() {
    wakelock.wakelockPlusPlatformInstance = originalScreenAwake;
  });

  testWidgets(
    'paused Lyrics stays awake through idle time and repeated visits',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()
        ..save(song, Lyrics.parse('Static lyrics'));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      for (var visit = 0; visit < 3; visit++) {
        await tester.pumpWidget(view(player, repository));
        await tester.pumpAndSettle();
        expect(player.audio.playing, isFalse);
        expect(screenAwake.awake, isTrue);
        final requests = screenAwake.requests.length;
        await tester.pump(const Duration(minutes: 20));
        player.notifyListeners();
        await tester.pump();
        expect(screenAwake.awake, isTrue);
        expect(
          screenAwake.requests.length,
          requests,
          reason: 'One ownership per visit',
        );
        await tester.pumpWidget(const SizedBox());
        expect(screenAwake.awake, isFalse);
      }
      expect(screenAwake.requests, [true, false, true, false, true, false]);
    },
  );

  testWidgets(
    'Lyrics releases on background and focus loss, reacquires on return',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()
        ..save(song, Lyrics.parse('[00:00]Synced line'));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(screenAwake.awake, isFalse);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(screenAwake.awake, isTrue);
      void focus(bool focused, {int? id}) =>
          tester.binding.handleViewFocusChanged(
            ui.ViewFocusEvent(
              viewId: id ?? tester.view.viewId,
              state: focused
                  ? ui.ViewFocusState.focused
                  : ui.ViewFocusState.unfocused,
              direction: ui.ViewFocusDirection.undefined,
            ),
          );
      focus(false, id: tester.view.viewId + 1);
      expect(screenAwake.awake, isTrue, reason: 'Ignore other windows');
      focus(false);
      expect(screenAwake.awake, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(screenAwake.awake, isFalse, reason: 'Focus is also required');
      focus(true);
      expect(screenAwake.awake, isTrue);
      await tester.pumpWidget(const SizedBox());
      focus(false);
      focus(true);
      expect(
        screenAwake.awake,
        isFalse,
        reason: 'Disposed page cannot reacquire',
      );
    },
  );

  testWidgets('Lyrics does not acquire while mounted in the background', (
    tester,
  ) async {
    final player = controller();
    final repository = LyricsRepository()
      ..save(song, Lyrics.parse('Static lyrics'));
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(view(player, repository));
    expect(screenAwake.awake, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(screenAwake.awake, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(screenAwake.awake, isFalse);
  });

  testWidgets('covered routes and disabled Lyrics surfaces release ownership', (
    tester,
  ) async {
    final player = controller();
    final repository = LyricsRepository()
      ..save(song, Lyrics.parse('Static lyrics'));
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    final navigator = GlobalKey<NavigatorState>();
    late StateSetter update;
    var visible = true;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return TickerMode(
              enabled: visible,
              child: LyricsView(
                player: player,
                repository: repository,
                artwork: const Icon(Icons.album),
                onBack: () {},
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(screenAwake.awake, isTrue);
    update(() => visible = false);
    await tester.pump();
    expect(screenAwake.awake, isFalse);
    update(() => visible = true);
    await tester.pump();
    expect(screenAwake.awake, isTrue);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Another page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(screenAwake.awake, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(screenAwake.awake, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(screenAwake.awake, isFalse);
  });

  testWidgets(
    'Lyrics and video share independent reference-counted wake ownership',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()
        ..save(song, Lyrics.parse('Static lyrics'));
      final video = Wakelock();
      addTearDown(video.disable);
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      video.enable();
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(
        screenAwake.awake,
        isTrue,
        reason: 'Leaving Lyrics must not release video',
      );
      video.disable();
      expect(screenAwake.awake, isFalse);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      video.enable();
      video.disable();
      video.disable();
      expect(
        screenAwake.awake,
        isTrue,
        reason: 'Stopping video must not release Lyrics',
      );
      await tester.pumpWidget(const SizedBox());
      expect(screenAwake.awake, isFalse);
    },
  );

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
    'automatic translation starts without confirmation and keeps original lyrics',
    (tester) async {
      final player = controller()..settings.automaticTranslation = true;
      final repository = TranslationLyrics()
        ..save(song, Lyrics.parse('[00:00]今日は晴れです。'));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pump();
      expect(repository.translations, 1);
      expect(find.byType(AlertDialog), findsNothing);
      repository.result.complete(
        Lyrics.parse('[00:00]今日は晴れです。\n[00:00]It is sunny today.'),
      );
      await tester.pumpAndSettle();
      expect(find.text('今日は晴れです。\nIt is sunny today.'), findsOneWidget);
      expect(repository.cached(song)!.plain, '今日は晴れです。');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'non-Japanese lyrics translate automatically with an English-target menu label',
    (tester) async {
      final player = controller()..settings.automaticTranslation = true;
      final repository = TranslationLyrics()
        ..save(song, Lyrics.parse('[00:00]আজ সুন্দর দিন'));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pump();
      expect(repository.translations, 1);
      repository.result.complete(
        Lyrics.parse('[00:00]আজ সুন্দর দিন\n[00:00]Today is a beautiful day'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('আজ সুন্দর দিন\nToday is a beautiful day'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('lyrics-translate')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Any language → English'), findsOneWidget);
      await tester.tap(find.text('Show original lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('আজ সুন্দর দিন'), findsOneWidget);
      expect(repository.cached(song)!.plain, 'আজ সুন্দর দিন');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed automatic translation ignores unrelated updates but translates new lyrics',
    (tester) async {
      final player = controller()..settings.automaticTranslation = true;
      final repository = TranslationLyrics()
        ..save(song, Lyrics.parse('[00:00]今日は晴れです。'));
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pump();
      expect(repository.translations, 1);
      repository.result.completeError(StateError('Provider unavailable'));
      await tester.pumpAndSettle();

      repository.save(second, Lyrics.parse('[00:00]Unrelated song'));
      await tester.pumpAndSettle();
      expect(repository.translations, 1);
      expect(find.byType(SnackBar), findsNothing);

      repository.result = Completer<Lyrics>()
        ..complete(Lyrics.parse('[00:00]新しい歌\n[00:00]A new song'));
      repository.save(song, Lyrics.parse('[00:00]新しい歌', imported: true));
      await tester.pumpAndSettle();
      expect(repository.translations, 2);
      expect(find.text('新しい歌\nA new song'), findsOneWidget);
      expect(repository.cached(song)!.plain, '新しい歌');
      expect(repository.cached(song)!.imported, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Japanese translation confirms sharing, toggles original, and fits phone and desktop',
    (tester) async {
      final player = controller();
      addTearDown(player.shutdown);
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      tester.view.devicePixelRatio = 1;
      for (final size in [const Size(390, 844), const Size(1280, 800)]) {
        tester.view.physicalSize = size;
        final repository = TranslationLyrics()
          ..save(song, Lyrics.parse('[00:00]今日は晴れです。'));
        await tester.pumpWidget(view(player, repository));
        await tester.pumpAndSettle();
        await chooseTranslation(tester, 'Translate in Auralis');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repository.translations, 0);
        await chooseTranslation(tester, 'Translate in Auralis');
        await tester.tap(find.text('Translate'));
        await tester.pump();
        expect(repository.translations, 1);
        repository.result.complete(
          Lyrics.parse('[00:00]今日は晴れです。\n[00:00]It is sunny today.'),
        );
        await tester.pumpAndSettle();
        expect(find.text('今日は晴れです。\nIt is sunny today.'), findsOneWidget);
        await chooseTranslation(tester, 'Show original lyrics');
        expect(find.text('今日は晴れです。'), findsOneWidget);
        expect(repository.cached(song)!.plain, '今日は晴れです。');
        await chooseTranslation(tester, 'Translate in Auralis');
        expect(repository.translations, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        repository.close();
      }
    },
  );

  testWidgets('late translation cannot appear after switching songs', (
    tester,
  ) async {
    final player = controller();
    final repository = TranslationLyrics()
      ..save(song, Lyrics.parse('[00:00]今日は晴れです。'))
      ..save(second, Lyrics.parse('[00:00]Other original lyrics'));
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    await tester.pumpWidget(view(player, repository));
    await tester.pumpAndSettle();
    await chooseTranslation(tester, 'Translate in Auralis');
    await tester.tap(find.text('Translate'));
    await tester.pump();
    player.queue.add(second);
    player.index = 1;
    player.notifyListeners();
    await tester.pumpAndSettle();
    expect(repository.isActive!(), isFalse);
    repository.result.complete(Lyrics.parse('[00:00]Stale English'));
    await tester.pumpAndSettle();
    expect(find.text('Stale English'), findsNothing);
    expect(find.text('Other original lyrics'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'DeepL confirms copying, preserves originals and opens both directions on phone and desktop',
    (tester) async {
      final player = controller();
      final opened = <String>[];
      String? copied = 'previous clipboard';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      addTearDown(player.shutdown);
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      tester.view.devicePixelRatio = 1;
      for (final size in [const Size(390, 844), const Size(1280, 800)]) {
        tester.view.physicalSize = size;
        final repository = LyricsRepository()
          ..save(song, Lyrics.parse('[00:00]今日は晴れです。\n[00:02]明日も歩きます。'));
        await tester.pumpWidget(
          view(
            player,
            repository,
            openLink: (url) async {
              opened.add(url);
            },
          ),
        );
        await tester.pumpAndSettle();
        final before = opened.length, oldClipboard = copied;
        await chooseTranslation(tester, 'Translate with DeepL');
        expect(
          find.textContaining('Results stay in the browser.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(opened.length, before);
        expect(copied, oldClipboard);
        await chooseTranslation(tester, 'Translate with DeepL');
        await tester.tap(find.text('Copy lyrics & open DeepL'));
        await tester.pumpAndSettle();
        expect(opened.last, 'https://www.deepl.com/en/translator/l/auto/en');
        expect(copied, '[00:00.000]今日は晴れです。\n[00:02.000]明日も歩きます。');
        expect(repository.cached(song)!.plain, '今日は晴れです。\n明日も歩きます。');
        expect(find.text('今日は晴れです。'), findsOneWidget);
        await chooseTranslation(tester, 'Translate with DeepL');
        await tester.tap(
          find.byTooltip('Translation direction: Any language → English'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('English → Japanese').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy lyrics & open DeepL'));
        await tester.pumpAndSettle();
        expect(opened.last, 'https://www.deepl.com/en/translator/l/en/ja');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        repository.close();
      }
    },
  );

  testWidgets(
    'DeepL does not open stale lyrics after song changes while copying',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()
        ..save(song, Lyrics.parse('[00:00]今日は晴れです。'))
        ..save(second, Lyrics.parse('[00:00]Other original lyrics'));
      final gate = Completer<void>();
      var opened = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') await gate.future;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(
        view(
          player,
          repository,
          openLink: (_) async {
            opened = true;
          },
        ),
      );
      await tester.pumpAndSettle();
      await chooseTranslation(tester, 'Translate with DeepL');
      await tester.tap(find.text('Copy lyrics & open DeepL'));
      await tester.pumpAndSettle();
      player.queue.add(second);
      player.index = 1;
      player.notifyListeners();
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(opened, isFalse);
      expect(find.text('Other original lyrics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('DeepL browser launch failure keeps lyrics and allows retry', (
    tester,
  ) async {
    final player = controller();
    final repository = LyricsRepository()
      ..save(song, Lyrics.parse('Original English lyrics'));
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    await tester.pumpWidget(
      view(
        player,
        repository,
        openLink: (_) async {
          if (++calls == 1) throw const FileSystemException('No browser');
        },
      ),
    );
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 2; attempt++) {
      await chooseTranslation(tester, 'Translate with DeepL');
      await tester.tap(find.text('Copy lyrics & open DeepL'));
      await tester.pumpAndSettle();
      expect(repository.cached(song)!.plain, 'Original English lyrics');
    }
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'imports LRC; cancellation and invalid files preserve existing lyrics',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()..save(song, null);
      final files = LrcFiles();
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository, files: files));
      await tester.tap(find.widgetWithText(TextButton, 'Import .lrc file'));
      await tester.pumpAndSettle();
      expect(find.text('Original imported line'), findsOneWidget);
      expect(find.text('Imported LRC · session only'), findsNothing);
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
    final repository = LyricsRepository()
      ..save(song, null)
      ..save(second, null);
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
      expect(find.text('Lyrics from music file'), findsNothing);
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
        Theme.of(tester.element(find.byType(LyricsView))).colorScheme.surface,
      );
    },
  );

  testWidgets('one top menu keeps all actions and Back stays in the header', (
    tester,
  ) async {
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
    expect(buttons, findsOneWidget);
    final header = tester.getRect(
      find.byKey(const ValueKey('lyrics-song-pill')),
    );
    final back = tester.getRect(find.byTooltip('Back to cover'));
    expect(back.center.dy, inInclusiveRange(header.top, header.bottom));
    expect(
      tester.getRect(buttons).center.dy,
      inInclusiveRange(header.top, header.bottom),
    );
    expect(find.textContaining('Lyrics source'), findsNothing);

    await tester.tap(buttons);
    await tester.pumpAndSettle();
    expect(find.text('Import .lrc file'), findsOneWidget);
    expect(find.text('Read lyrics from music file'), findsOneWidget);
    expect(find.text('Find lyrics online'), findsOneWidget);
    expect(find.text('Paste lyrics'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Read lyrics from music file'), findsNothing);
  });

  testWidgets('hold or right-click to choose a song or artist lyrics search', (
    tester,
  ) async {
    final player = controller();
    Response response(Object data) => Response(utf8.encode(jsonEncode(data)));
    final client = Client([
      response([
        {'trackName': 'Incomplete entry'},
        {
          'trackName': 'Alternate song match',
          'artistName': 'Another artist',
          'plainLyrics': 'Unselected words',
        },
      ]),
      response([
        {
          'trackName': 'Correct song match',
          'artistName': song.artist,
          'albumName': 'Studio album',
          'duration': 245,
          'syncedLyrics': '[00:01]Chosen words',
        },
      ]),
      response({'plainLyrics': 'Standard lookup words'}),
    ]);
    final saved = Lyrics.parse('Saved words');
    final repository = LyricsRepository(createClient: () => client)
      ..save(song, saved);
    addTearDown(player.shutdown);
    addTearDown(repository.close);
    await tester.pumpWidget(view(player, repository));
    await tester.pumpAndSettle();

    Future<Finder> openMenu() async {
      await tester.tap(find.byTooltip('Lyrics options'));
      await tester.pumpAndSettle();
      return find.text('Find lyrics online');
    }

    await tester.longPress(await openMenu());
    await tester.pumpAndSettle();
    expect(find.text('Search lyrics by'), findsOneWidget);
    expect(client.requests, isEmpty);
    await tester.tap(find.byTooltip('Search by song name'));
    await tester.pumpAndSettle();
    expect(client.requests.single.path, '/api/search');
    expect(client.requests.single.queryParameters, {'track_name': song.title});
    expect(find.text('Alternate song match'), findsOneWidget);
    expect(find.text('Incomplete entry'), findsNothing);
    expect(repository.cached(song), same(saved));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.cached(song), same(saved));

    await tester.tap(
      await openMenu(),
      buttons: kSecondaryMouseButton,
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Search lyrics by'), findsOneWidget);
    await tester.tap(find.byTooltip('Search by artist'));
    await tester.pumpAndSettle();
    expect(client.requests[1].queryParameters, {
      'q': song.artist,
      'artist_name': song.artist,
    });
    expect(find.textContaining('Studio album · 4:05'), findsOneWidget);
    await tester.tap(find.text('Correct song match'));
    await tester.pumpAndSettle();
    expect(repository.cached(song)!.lines.single.text, 'Chosen words');

    await tester.tap(await openMenu());
    await tester.pumpAndSettle();
    expect(client.requests[2].path, '/api/get');
    expect(client.requests[2].queryParameters['artist_name'], song.artist);
    expect(repository.cached(song)!.plain, 'Standard lookup words');
    expect(tester.takeException(), isNull);
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(360, 480), 2.0),
  ]) {
    testWidgets(
      'type song and artist searches without changing metadata at $size / $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final player = controller();
        final client = Client([
          Response(utf8.encode('[]')),
          Response(
            utf8.encode(
              jsonEncode([
                {
                  'trackName': 'Found song',
                  'artistName': 'Edited artist',
                  'plainLyrics': 'Chosen edited-search words',
                },
              ]),
            ),
          ),
        ]);
        final original = Lyrics.parse('Original saved lyrics');
        final repository = LyricsRepository(createClient: () => client)
          ..save(song, original);
        addTearDown(player.shutdown);
        addTearDown(repository.close);
        await tester.pumpWidget(view(player, repository));
        await tester.pumpAndSettle();
        await openEditableLyricsSearch(tester);
        final title = find.byKey(const ValueKey('lyrics-search-title'));
        final artist = find.byKey(const ValueKey('lyrics-search-artist'));
        expect(tester.widget<TextFormField>(title).initialValue, song.title);
        expect(tester.widget<TextFormField>(artist).initialValue, song.artist);
        await tester.enterText(title, '  JEOPARDY & 光?  ');
        await tester.pumpAndSettle();
        expect(
          client.requests,
          isEmpty,
          reason: 'Typing does not send requests',
        );
        if (size.width < 900) {
          tester.view.viewInsets = FakeViewPadding(
            bottom: size.height < 500 ? 220 : 300,
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Dialog fits above keyboard',
          );
        }
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(client.requests.single.queryParameters, {
          'track_name': 'JEOPARDY & 光?',
        });
        expect(repository.cached(song), same(original));
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repository.cached(song), same(original));
        await openEditableLyricsSearch(tester);
        expect(
          tester.widget<TextFormField>(title).initialValue,
          song.title,
          reason: 'Search edits are not song metadata',
        );
        await tester.ensureVisible(artist);
        await tester.enterText(artist, '  Edited artist  ');
        await tester.pumpAndSettle();
        final search = find.byTooltip('Search by artist');
        await tester.ensureVisible(search);
        await tester.pumpAndSettle();
        await tester.tap(search);
        await tester.pumpAndSettle();
        expect(client.requests.last.queryParameters, {
          'q': 'Edited artist',
          'artist_name': 'Edited artist',
        });
        final result = find.text('Found song');
        await tester.ensureVisible(result);
        await tester.pumpAndSettle();
        await tester.tap(result);
        await tester.pumpAndSettle();
        expect(repository.cached(song)!.plain, 'Chosen edited-search words');
        expect(player.current, same(song));
        expect(player.current!.title, song.title);
        expect(player.current!.artist, song.artist);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'editing invalidates pending search results and song changes reject selection',
    (tester) async {
      final player = controller();
      final saved = Lyrics.parse('Saved lyrics');
      final repository = EditableSearchLyrics()
        ..save(song, saved)
        ..save(second, saved);
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      await openEditableLyricsSearch(tester);
      final title = find.byKey(const ValueKey('lyrics-search-title'));
      final search = find.byTooltip('Search by song name');
      await tester.enterText(title, '   ');
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('lyrics-search-submit-title')),
            )
            .onPressed,
        isNull,
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(repository.searches, isEmpty);
      await tester.enterText(title, 'First query');
      await tester.pump();
      await tester.tap(search);
      await tester.pump();
      expect(repository.searches.single.query, 'First query');
      await tester.enterText(title, 'New query');
      await tester.pump();
      repository.pending.first.complete([
        searchMatch('Old result', 'Stale words'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Old result'), findsNothing);
      await tester.tap(search);
      await tester.pump();
      expect(repository.searches.last.query, 'New query');
      repository.pending.last.complete([
        searchMatch('Current result', 'Chosen words'),
      ]);
      await tester.pumpAndSettle();
      player.queue.add(second);
      player.index = 1;
      player.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current result'));
      await tester.pumpAndSettle();
      expect(repository.cached(song), same(saved));
      expect(repository.cached(second), same(saved));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'missing metadata can be typed and failed searches can be edited and retried',
    (tester) async {
      final player = controller();
      const unnamed = Track(
        id: 'unnamed',
        title: '',
        artist: '',
        source: 'Music',
      );
      player.queue[0] = unnamed;
      final saved = Lyrics.parse('Saved words');
      final repository = EditableSearchLyrics()..save(unnamed, saved);
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      await openEditableLyricsSearch(tester);
      final artist = find.byKey(const ValueKey('lyrics-search-artist'));
      final search = find.byTooltip('Search by artist');
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('lyrics-search-submit-artist')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(artist, 'Typed artist');
      await tester.pump();
      await tester.tap(search);
      await tester.pump();
      repository.pending.single.completeError(StateError('Offline'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not search LRCLIB.'), findsOneWidget);
      expect(repository.cached(unnamed), same(saved));
      await tester.enterText(artist, 'Corrected artist');
      await tester.pump();
      await tester.tap(search);
      await tester.pump();
      repository.pending.last.complete([
        searchMatch('Found result', 'New words'),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Found result'));
      await tester.pumpAndSettle();
      expect(repository.cached(unnamed)!.plain, 'New words');
      expect(player.current, same(unnamed));
      expect(repository.searches.last.query, 'Corrected artist');
      await tester.pumpWidget(const SizedBox());
    },
  );

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
    'missing, empty or unreadable embedded tags automatically fall back to LRCLIB',
    (tester) async {
      final player = controller();
      addTearDown(player.shutdown);
      for (final mode in ['missing', 'empty', 'unreadable']) {
        final client = Client([
          Response(
            utf8.encode('{"syncedLyrics":"[00:00]Online fallback words"}'),
          ),
        ]);
        final repository = LyricsRepository(createClient: () => client);
        await tester.pumpWidget(
          view(
            player,
            repository,
            embedded: (_) async {
              expect(
                client.requests,
                isEmpty,
                reason: 'Embedded tags are checked first',
              );
              if (mode == 'unreadable') throw const FormatException('bad tags');
              return mode == 'empty'
                  ? Lyrics.parse('[ar:Artist]', embedded: true)
                  : null;
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Online fallback words'), findsOneWidget);
        expect(client.requests, hasLength(1));
        expect(repository.cached(song)!.online, isTrue);
        expect(find.byTooltip('Lyrics options'), findsOneWidget);
        expect(find.text('Lyrics from music file'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(view(player, repository));
        await tester.pumpAndSettle();
        expect(
          client.requests,
          hasLength(1),
          reason: 'Reopening uses the session cache',
        );
        await tester.pumpWidget(const SizedBox());
        repository.close();
      }
    },
  );

  testWidgets(
    'embedded words prevent online lookup and imported words win a pending lookup',
    (tester) async {
      final player = controller();
      final repository = PendingLyrics();
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(
        view(
          player,
          repository,
          embedded: (_) async => Lyrics.parse('Embedded first', embedded: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.calls, 0);
      expect(find.text('Embedded first'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final pending = PendingLyrics();
      addTearDown(pending.close);
      await tester.pumpWidget(view(player, pending, files: LrcFiles()));
      expect(pending.calls, 1);
      await tester.tap(find.byTooltip('Lyrics options'));
      // Start the menu transition before advancing it. The pending lookup keeps
      // a progress indicator running, so pumpAndSettle cannot open this menu.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final importItem = find.widgetWithText(
        PopupMenuItem<String>,
        'Import .lrc file',
      );
      expect(importItem.hitTestable(), findsOneWidget);
      await tester.tap(importItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Original imported line'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.pending.complete(Lyrics.parse('Late online words', online: true));
      await tester.pumpAndSettle();
      expect(find.text('Late online words'), findsNothing);
      expect(pending.cached(song)!.imported, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
      expect(
        active.style.color,
        Theme.of(tester.element(find.byType(LyricsView))).colorScheme.primary,
      );
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
      expect(softened(index), isTrue);
    }
    expect(find.byKey(const ValueKey('lyrics-waiting')), findsOneWidget);
    await player.audio.seek(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(softened(0), isFalse);
    expect(softened(1), isTrue);
    expect(softened(2), isTrue);
    expect(find.byKey(const ValueKey('lyrics-waiting')), findsNothing);
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
    'timed instrumental gaps blur every line and recover after seeking',
    (tester) async {
      final player = controller();
      final repository = LyricsRepository()
        ..save(
          song,
          Lyrics.parse('[00:08]First words\n[00:12]\n[00:16]Words return'),
        );
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for lyrics'), findsOneWidget);
      await player.audio.seek(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lyrics-waiting')), findsNothing);
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-focus-0')))
            .enabled,
        isFalse,
      );
      await player.audio.seek(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Instrumental break'), findsOneWidget);
      for (var index = 0; index < 3; index++) {
        expect(
          tester
              .widget<ImageFiltered>(find.byKey(ValueKey('lyric-focus-$index')))
              .enabled,
          isTrue,
        );
      }
      await player.audio.seek(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lyrics-waiting')), findsNothing);
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-focus-2')))
            .enabled,
        isFalse,
      );
      await player.audio.seek(Duration.zero);
      await tester.pumpAndSettle();
      expect(find.text('Waiting for lyrics'), findsOneWidget);
      expect(tester.takeException(), isNull);
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

  testWidgets(
    'lookup starts automatically; stale results cannot replace a new song',
    (tester) async {
      final player = controller();
      final repository = PendingLyrics();
      addTearDown(player.shutdown);
      addTearDown(repository.close);
      await tester.pumpWidget(view(player, repository));
      expect(repository.calls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      player.queue[0] = second;
      await player.audio.seek(Duration.zero);
      await tester.pump();
      repository.pending.complete(Lyrics.parse('[00:00]Stale result'));
      repository.other.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('Stale result'), findsNothing);
      expect(find.text('Morning light'), findsOneWidget);
      expect(find.text('Find lyrics'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
      expect(
        screenAwake.awake,
        isFalse,
        reason: 'Home keeps normal screen timeout',
      );
      await tester.tap(find.byKey(const ValueKey('open-current-track')));
      await tester.pumpAndSettle();
      expect(
        screenAwake.awake,
        isFalse,
        reason: 'The cover page does not hold a wake lock',
      );
      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();
      expect(find.byType(LyricsView), findsOneWidget);
      expect(
        screenAwake.awake,
        isTrue,
        reason: 'Even the empty Lyrics page stays awake',
      );
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
      expect(
        screenAwake.awake,
        isFalse,
        reason: 'Back to cover releases Lyrics ownership',
      );
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('player-bar')), findsNothing);
      expect(
        find.byKey(const ValueKey('now-playing-play-pause')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Back to Home'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('player-bar')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
