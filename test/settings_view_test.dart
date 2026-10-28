import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app.dart';
import 'package:auralis/player.dart';
import 'package:auralis/models.dart';
import 'package:auralis/preference_widgets.dart';
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

  testWidgets('themed settings cards and anchored menus retain real choices', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SavedSettings()
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
    final updater = AppUpdater(
      currentVersion: '0.1.99',
      directory: Directory('unused'),
      settings: settings,
      target: UpdateTarget.android,
      androidAbi: 'arm64-v8a',
    );
    addTearDown(player.shutdown);
    addTearDown(telegram.shutdown);
    addTearDown(updater.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: AuralisApp(player: player, telegram: telegram, updater: updater),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-collection-menu')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PopupMenuItem<int>).first).width,
      lessThanOrEqualTo(280),
    );
    await tester.tap(find.text('Favorites').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Library collection: Favorites'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings').first);
    await tester.pumpAndSettle();
    for (final section in SettingsSection.values) {
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        section.title,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('settings-${section.name}')));
      await tester.pumpAndSettle();
      expect(find.byType(PreferenceCard), findsWidgets);
      final colors = Theme.of(tester.element(find.byType(PreferenceCard).first))
          .colorScheme;
      final card = find
          .descendant(
            of: find.byType(PreferenceCard).first,
            matching: find.byType(Material),
          )
          .first;
      expect(tester.widget<Material>(card).color, colors.surfaceContainerLow);
      if (section == SettingsSection.appearance) {
        await tester.tap(find.byTooltip('App navigation: Expressive pill'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Classic pill').last);
        await tester.pumpAndSettle();
        expect(settings.navigationStyle, AppNavigationStyle.classic);
        expect(settings.saves, greaterThan(0));
      }
      if (section == SettingsSection.media) {
        await tester.tap(find.byKey(const ValueKey('lyrics-preferences')));
        await tester.pumpAndSettle();
        final trigger = find.byTooltip('Lyrics fallback: lyrics.ovh');
        await Scrollable.ensureVisible(tester.element(trigger));
        await tester.pumpAndSettle();
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          settings.lyricsFallback,
          isNotNull,
          reason: 'Dismiss is not None',
        );
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        await tester.tap(find.text('None').last);
        await tester.pumpAndSettle();
        expect(settings.lyricsFallback, isNull);
      }
      expect(tester.takeException(), isNull, reason: section.title);
      await tester.tap(find.byTooltip('Back to Settings'));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox());
  });

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
          tester
              .getTopLeft(
                find
                    .ancestor(
                      of: find.byTooltip('Back to Library'),
                      matching: find.byType(IconButton),
                    )
                    .first,
              )
              .dx,
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
        expect(find.text('Find lyrics automatically'), findsOneWidget);
        expect(find.text('Preload artwork'), findsNothing);
        expect(find.byType(ErrorWidget), findsNothing);
        if (size.width == 320) {
          final fallback = find.byTooltip('Translate fallback: MyMemory');
          await Scrollable.ensureVisible(
            tester.element(fallback),
            alignment: .1,
          );
          await tester.pumpAndSettle();
          await tester.tap(fallback);
          await tester.pumpAndSettle();
          await tester.tap(find.text('None').last);
          await tester.pumpAndSettle();
          expect(settings.translationFallback, isNull);
          expect(tester.takeException(), isNull);
          // Revisit after saving the scroll offset. Expansion state used to
          // share this PageStorage entry and read a double as a bool.
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Lyrics & artwork'));
          await tester.pumpAndSettle();
          expect(find.byType(ErrorWidget), findsNothing);
          expect(find.byTooltip('Translate fallback: None'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
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
