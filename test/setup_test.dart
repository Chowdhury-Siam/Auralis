import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/data_backup.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/release_notes.dart';
import 'package:auralis/setup_permissions.dart';
import 'package:auralis/setup_view.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/sync/controller.dart';
import 'package:auralis/sync/settings_view.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'sync_accounts_test.dart' show AccountClient;

class Permissions extends SetupPermissions {
  bool enabled = false;
  int requests = 0;
  @override
  Future<({bool notifications, bool battery})> status() async =>
      (notifications: enabled, battery: false);
  @override
  Future<void> notifications() async {
    requests++;
  }

  @override
  Future<void> battery() async {
    requests++;
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

  testWidgets(
    'setup renders on phone and finishes into the selected floating navigation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = MemorySettings();
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      final sync = HttpOverrides.runZoned(
        () => SyncController(
          settings,
          MemoryVault(),
          onApplied: player.refreshSettings,
          paused: () => true,
        ),
        createHttpClient: (_) => AccountClient(),
      );
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      addTearDown(sync.close);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: AuralisApp(
            player: player,
            telegram: telegram,
            sync: sync,
            showSetup: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('docs/screenshots/$name-390.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('setup-welcome');
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.widgetWithText(ListTile, 'Expressive pill'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Preview · Library'), findsOneWidget);
      await capture('setup-navigation');
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
      }
      await capture('setup-finish');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      expect(settings.setupComplete, isTrue);
      expect(settings.lastSeenRelease, currentReleaseVersion);
      expect(find.byType(SetupView), findsNothing);
      expect(find.byTooltip('Browse'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await capture('floating-navigation');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final entry in [
    null,
    SyncAccountEntry.signIn,
    SyncAccountEntry.register,
  ]) {
    final client = AccountClient();
    testWidgets(
      'welcome can ${entry?.name ?? 'skip sync and setup'}',
      (tester) => HttpOverrides.runZoned(() async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final settings = MemorySettings();
        final player = PlayerController(
          FakeAudio(),
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: FakeTd(),
        );
        final vault = MemoryVault();
        final sync = SyncController(
          settings,
          vault,
          onApplied: player.refreshSettings,
          paused: () => true,
        );
        addTearDown(player.shutdown);
        addTearDown(telegram.shutdown);
        addTearDown(sync.close);
        await tester.pumpWidget(
          AuralisApp(
            player: player,
            telegram: telegram,
            sync: sync,
            showSetup: true,
          ),
        );
        await tester.pumpAndSettle();
        if (entry != null) {
          final register = entry == SyncAccountEntry.register;
          final action = find.byKey(
            ValueKey(register ? 'setup-sync-register' : 'setup-sync-sign-in'),
          );
          await tester.ensureVisible(action);
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(find.text('Connect Worker Sync'), findsOneWidget);
          final submit = find.widgetWithText(
            FilledButton,
            register ? 'Create account' : 'Sign in',
          );
          expect(submit, findsOneWidget);
          await tester.enterText(
            find.byKey(const ValueKey('sync-worker-url')),
            'https://sync.example',
          );
          await tester.enterText(
            find.byKey(const ValueKey('sync-username')),
            'alice',
          );
          await tester.enterText(
            find.byKey(const ValueKey('sync-password')),
            'test-password',
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(submit);
          await tester.pumpAndSettle();
          await tester.tap(submit);
          // Drain the fake Worker's HTTP stream and the widget's frame queue.
          for (var frame = 0; frame < 12 && !sync.signedIn; frame++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            sync.signedIn,
            isTrue,
            reason:
                'Worker requests: ${client.requests.map((r) => r.uri.path)}',
          );
          if (register) {
            await tester.pump(const Duration(milliseconds: 350));
            expect(find.text('Save your recovery code'), findsOneWidget);
            await tester.tap(find.text('Done'));
          }
          await tester.pumpAndSettle();
          expect(find.byType(SyncAccountPage), findsNothing);
          expect(find.text('Worker connected'), findsOneWidget);
          expect(sync.account?.username, 'alice');
          expect(vault.data, isNotEmpty);
        }
        await tester.tap(find.byKey(const ValueKey('setup-skip')));
        await tester.pumpAndSettle();
        expect(settings.setupComplete, isTrue);
        expect(find.byType(SetupView), findsNothing);
        expect(sync.signedIn, entry != null);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await sync.close();
      }, createHttpClient: (_) => client),
    );
  }

  test('setup migration, unfinished setup, appearance backup and timestamp round trip', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-setup-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    final fresh = AppSettings(file);
    await fresh.load();
    expect(fresh.setupComplete, isFalse);
    fresh.navigationStyle = AppNavigationStyle.expressive;
    fresh.navigationRadius = 16;
    await fresh.save();
    final resumed = AppSettings(file);
    await resumed.load();
    expect(resumed.setupComplete, isFalse);
    expect(resumed.navigationRadius, 16);
    resumed.setupComplete = true;
    await resumed.save();
    final complete = AppSettings(file);
    await complete.load();
    expect(complete.setupComplete, isTrue);
    final backup = DataBackup.create(complete, DateTime(2026));
    final encoded = jsonDecode(backup.encode()) as Map<String, dynamic>;
    final oldSnapshot = encoded['data'] as Map<String, dynamic>;
    expect(oldSnapshot, isNot(contains('compactLibrary')));
    oldSnapshot['compactLibrary'] = false;
    encoded['sha256'] = sha256
        .convert(utf8.encode(jsonEncode(oldSnapshot)))
        .toString();
    expect(
      DataBackup.parse(jsonEncode(encoded)).snapshot,
      isNot(contains('compactLibrary')),
    );
    expect(complete.toJson().containsKey('_setupComplete'), isFalse);
    await file.writeAsString(
      jsonEncode({
        'favoriteIds': ['kept'],
        'volume': 42,
        'compactLibrary': false,
      }),
    );
    await complete.load();
    expect(complete.setupComplete, isTrue);
    expect(complete.favoriteIds, {'kept'});
    expect(complete.toJson(), isNot(contains('compactLibrary')));
    expect(complete.navigationStyle, AppNavigationStyle.fullWidth);

    final original = Lyrics.parse(
      '[offset:50]\n[00:01.125]夜の歌\n[00:01.125]Second line\n[00:03.456]\n[00:09]End',
    );
    final exported = original.timestampedText;
    expect(
      exported,
      '[00:01.175]夜の歌\n[00:01.175]Second line\n[00:03.506]\n[00:09.050]End',
    );
    final parsed = Lyrics.parse(exported);
    expect(
      parsed.lines.map((v) => (v.time, v.text)),
      original.lines.map((v) => (v.time, v.text)),
    );
    expect(Lyrics.parse('Plain words').timestampedText, 'Plain words');
  });

  testWidgets(
    'phone setup skips optional steps, retains choices, and checks permission truthfully',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = MemorySettings();
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      final permissions = Permissions();
      var finished = false;
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(platform: TargetPlatform.android),
          home: SetupView(
            player: player,
            telegram: telegram,
            version: '0.1.92',
            permissions: permissions,
            connectBuilder: (context) => Scaffold(
              appBar: AppBar(title: const Text('Telegram test connection')),
            ),
            onFinished: () {
              finished = true;
            },
          ),
        ),
      );
      Future<void> next() async {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      expect(find.text('Welcome to\nAuralis'), findsOneWidget);
      await next();
      await tester.ensureVisible(find.text('Connect Telegram'));
      await tester.tap(find.text('Connect Telegram'));
      await tester.pumpAndSettle();
      expect(find.text('Telegram test connection'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await next();
      await tester.ensureVisible(find.text('Enable notifications'));
      await tester.tap(find.text('Enable notifications'));
      await tester.pumpAndSettle();
      expect(permissions.requests, 1);
      expect(find.text('Notifications enabled'), findsNothing);
      permissions.enabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Notifications enabled'), findsOneWidget);
      await next(); // backup
      await next(); // lyrics
      final translation = find.widgetWithText(
        SwitchListTile,
        'Translate automatically',
      );
      await tester.ensureVisible(translation);
      await tester.tap(translation);
      await tester.pumpAndSettle();
      expect(settings.automaticTranslation, isFalse);
      await next(); // artwork
      await next(); // navigation
      expect(find.text('Make it feel yours'), findsOneWidget);
      await tester.ensureVisible(
        find.widgetWithText(ListTile, 'Expressive pill'),
      );
      await tester.tap(find.widgetWithText(ListTile, 'Expressive pill'));
      await tester.pumpAndSettle();
      expect(settings.navigationStyle, AppNavigationStyle.expressive);
      await tester.tap(find.byTooltip('Previous setup step'));
      await tester.pumpAndSettle();
      expect(find.text('Covers stay with you'), findsOneWidget);
      expect(settings.setupComplete, isFalse);
      await next();
      await next(); // playback
      await next(); // battery
      await next(); // all set
      expect(find.text('All set!'), findsOneWidget);
      await next();
      expect(finished, isTrue);
      expect(settings.setupComplete, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'desktop setup fits enlarged text and the chosen navigation works in the app',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = MemorySettings()
        ..navigationStyle = AppNavigationStyle.expressive;
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(player.shutdown);
      addTearDown(telegram.shutdown);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SetupView(
            player: player,
            telegram: telegram,
            version: '0.1.92',
            connectBuilder: (_) => const SizedBox(),
            onFinished: () {},
          ),
        ),
      );
      for (var step = 0; step < 7; step++) {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Step ${step + 1}');
      }
      expect(find.text('All set!'), findsOneWidget);
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-collection-menu')),
        findsOneWidget,
      );
      expect(find.byType(AppNavigation), findsOneWidget);
      await tester.tap(find.byTooltip('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Search your Channel'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Example');
      await tester.pumpAndSettle();
      expect(find.text('Example'), findsOneWidget);
      await tester.tap(find.byTooltip('Library'));
      await tester.pumpAndSettle();
      settings.recentIds = ['saved'];
      player.refreshSettings();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-collection-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently played').last);
      await tester.pumpAndSettle();
      expect(find.text('Clear history'), findsNothing);
      expect(settings.recentIds, ['saved']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final (size, textScale, platform) in [
    (const Size(640, 990), 1.0, TargetPlatform.windows),
    (const Size(390, 844), 1.0, TargetPlatform.android),
    (const Size(320, 568), 2.0, TargetPlatform.windows),
  ]) {
    testWidgets(
      'setup choice menus match the theme and retain choices at $size with text $textScale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final settings = MemorySettings();
        final player = PlayerController(
          FakeAudio(),
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        final telegram = TelegramService(
          Directory('unused'),
          MemoryVault(),
          transport: FakeTd(),
        );
        addTearDown(player.shutdown);
        addTearDown(telegram.shutdown);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: AuralisApp(
              player: player,
              telegram: telegram,
              showSetup: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < (platform == TargetPlatform.android ? 4 : 3); i++) {
          await tester.tap(find.byKey(const ValueKey('setup-next')));
          await tester.pumpAndSettle();
        }
        Future<Rect> open(String title) async {
          final trigger = find.byKey(ValueKey('setup-choice-$title'));
          await tester.ensureVisible(trigger);
          await tester.pumpAndSettle();
          final triggerBounds = tester.getRect(trigger);
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          final items = find.byType(PopupMenuItem<int>);
          expect(items, findsNWidgets(2));
          final material = find
              .ancestor(of: items.first, matching: find.byType(Material))
              .first;
          final menu = tester.widget<Material>(material);
          final theme = Theme.of(tester.element(items.first));
          expect(menu.color, theme.colorScheme.surfaceContainerHigh);
          expect(menu.color, theme.dialogTheme.backgroundColor);
          expect(menu.shape, theme.dialogTheme.shape);
          expect(
            (menu.shape! as RoundedRectangleBorder).borderRadius,
            BorderRadius.circular(24),
          );
          expect(menu.clipBehavior, Clip.antiAlias);
          expect(find.byIcon(Icons.check_rounded), findsOneWidget);
          final bounds = tester.getRect(material);
          expect(bounds.width, lessThanOrEqualTo(280));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(size.width));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(size.height));
          if (size.width == 640) {
            expect(bounds.top, greaterThanOrEqualTo(triggerBounds.bottom));
          }
          expect(tester.takeException(), isNull);
          return bounds;
        }

        await open('Direction');
        if (size.width == 640) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('docs/screenshots/setup-direction-menu-640.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<int>), findsNothing);
        expect(
          settings.translationDirection,
          TranslationDirection.japaneseEnglish,
        );
        await open('Direction');
        await tester.tap(
          find.text(TranslationDirection.englishJapanese.label).last,
        );
        await tester.pumpAndSettle();
        expect(
          settings.translationDirection,
          TranslationDirection.englishJapanese,
        );
        await open('First lyric source');
        await tester.tap(find.text(LyricsSource.lyricsOvh.label).last);
        await tester.pumpAndSettle();
        expect(settings.lyricsFirst, LyricsSource.lyricsOvh);
        expect(settings.lyricsFallback, LyricsSource.lrclib);
        final translator = TranslationSource.values.firstWhere(
          (v) => v != settings.translationFirst,
        );
        await open('First translator');
        await tester.tap(find.text(translator.label).last);
        await tester.pumpAndSettle();
        expect(settings.translationFirst, translator);
        expect(settings.translationFallback, isNot(translator));
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Previous setup step'));
        await tester.pumpAndSettle();
        expect(
          settings.translationDirection,
          TranslationDirection.englishJapanese,
        );
        expect(settings.lyricsFirst, LyricsSource.lyricsOvh);
        expect(settings.translationFirst, translator);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
