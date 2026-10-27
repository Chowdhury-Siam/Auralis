import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/app_navigation.dart';
import 'package:auralis/data_backup.dart';
import 'package:auralis/lyrics.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/setup_permissions.dart';
import 'package:auralis/setup_view.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

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
            installedVersion: '0.1.92',
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
      for (var i = 0; i < 7; i++) {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.widgetWithText(ListTile, 'Expressive pill'));
      await tester.pumpAndSettle();
      await capture('setup-navigation');
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
      }
      await capture('setup-finish');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      expect(settings.setupComplete, isTrue);
      expect(settings.lastSeenRelease, '0.1.92');
      expect(find.byType(SetupView), findsNothing);
      expect(find.byTooltip('Search library'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await capture('floating-navigation');
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('setup migration, unfinished setup, appearance backup and timestamp round trip', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-setup-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings.json');
    final fresh = AppSettings(file);
    await fresh.load();
    expect(fresh.setupComplete, isFalse);
    fresh.compactLibrary = true;
    fresh.navigationStyle = AppNavigationStyle.expressive;
    fresh.navigationRadius = 16;
    await fresh.save();
    final resumed = AppSettings(file);
    await resumed.load();
    expect(resumed.setupComplete, isFalse);
    expect(resumed.compactLibrary, isTrue);
    expect(resumed.navigationRadius, 16);
    resumed.setupComplete = true;
    await resumed.save();
    final complete = AppSettings(file);
    await complete.load();
    expect(complete.setupComplete, isTrue);
    final backup = DataBackup.create(complete, DateTime(2026));
    DataBackup.parse(backup.encode());
    expect(complete.toJson().containsKey('_setupComplete'), isFalse);
    await file.writeAsString(
      jsonEncode({
        'favoriteIds': ['kept'],
        'volume': 42,
      }),
    );
    await complete.load();
    expect(complete.setupComplete, isTrue);
    expect(complete.favoriteIds, {'kept'});
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
      await next(); // library
      await tester.ensureVisible(find.text('Compact mode'));
      await tester.tap(find.widgetWithText(SwitchListTile, 'Compact mode'));
      await tester.pumpAndSettle();
      expect(settings.compactLibrary, isTrue);
      await next(); // navigation
      await tester.ensureVisible(
        find.widgetWithText(ListTile, 'Expressive pill'),
      );
      await tester.tap(find.widgetWithText(ListTile, 'Expressive pill'));
      await tester.pumpAndSettle();
      expect(settings.navigationStyle, AppNavigationStyle.expressive);
      await tester.tap(find.byTooltip('Previous setup step'));
      await tester.pumpAndSettle();
      expect(settings.compactLibrary, isTrue);
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
        ..compactLibrary = true
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
      for (var step = 0; step < 8; step++) {
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('All set!'), findsOneWidget);
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-collection-menu')),
        findsOneWidget,
      );
      expect(find.byType(AppNavigation), findsOneWidget);
      await tester.tap(find.byTooltip('Search library'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Example');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Example'), findsOneWidget);
      settings.recentIds = ['saved'];
      player.refreshSettings();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-collection-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently played').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      expect(settings.recentIds, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
