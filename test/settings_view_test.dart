import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/player.dart';
import 'package:auralis/settings_view.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:auralis/updater.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class SavedSettings extends MemorySettings {
  int saves = 0;
  @override
  Future<void> save() async {
    saves++;
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

  test(
    'settings search matches individual features, providers and punctuation',
    () {
      expect(SettingsSection.data.matches('backup restore'), isTrue);
      expect(SettingsSection.media.matches('translate'), isTrue);
      expect(SettingsSection.media.matches('MyMemory fallback'), isTrue);
      expect(SettingsSection.about.matches("What's new"), isTrue);
      expect(SettingsSection.about.matches('What’s new'), isTrue);
      expect(SettingsSection.appearance.matches('banana'), isFalse);
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(1280, 800),
    const Size(320, 568),
  ]) {
    testWidgets(
      'settings categories, search, Back and existing controls work at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (size.width == 320) {
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        }
        final settings = SavedSettings();
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
        final updater = AppUpdater(
          currentVersion: '0.1.93',
          directory: Directory('unused'),
          settings: settings,
        );
        addTearDown(player.shutdown);
        addTearDown(telegram.shutdown);
        addTearDown(updater.dispose);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: AuralisApp(
              player: player,
              telegram: telegram,
              updater: updater,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Settings').first);
        await tester.pumpAndSettle();
        if (size.width == 320) {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          await tester.pumpAndSettle();
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'Settings with enlarged text',
        );
        expect(find.byKey(const ValueKey('settings-search')), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('settings-search'))).dx,
          tester.getTopLeft(find.byKey(const ValueKey('page-title'))).dx,
        );
        if (size.width == 390) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('docs/screenshots/settings-directory-390.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.enterText(
          find.byKey(const ValueKey('settings-search')),
          'fallback',
        );
        await tester.pumpAndSettle();
        expect(find.text('Lyrics & artwork'), findsOneWidget);
        expect(find.text('Data & sync'), findsNothing);
        await tester.tap(find.text('Lyrics & artwork'));
        await tester.pumpAndSettle();
        expect(find.text('Lyrics & translation'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('settings-search')))
              .controller!
              .text,
          'fallback',
        );
        await tester.tap(find.byTooltip('Clear settings search'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('settings-search')),
          'no-such-setting',
        );
        await tester.pumpAndSettle();
        expect(find.text('No matching settings'), findsOneWidget);
        await tester.tap(find.text('Show all settings'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('settings-search')),
          'backup',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Data & sync'));
        await tester.pumpAndSettle();
        expect(find.text('Listening stats'), findsOneWidget);
        expect(find.text('Backup & Restore'), findsOneWidget);
        await tester.tap(find.byTooltip('Back to Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Clear settings search'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Appearance'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(SwitchListTile, 'Compact library navigation'),
        );
        await tester.pumpAndSettle();
        expect(settings.compactLibrary, isTrue);
        expect(settings.saves, greaterThan(0));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('settings-search')), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'Settings categories and controls',
        );
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          'Library',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
