import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/app_theme.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/stats_view.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/video_playback_data.dart';
import 'package:auralis/video_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class RefreshSettings extends MemorySettings {
  int saves = 0;
  bool failSave = false;
  @override
  Future<void> save() async {
    saves++;
    if (failSave) throw const FileSystemException('Not writable');
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> reviewImage(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final directory = Platform.environment['AURALIS_REVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$directory/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'Segoe UI',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });

  final theme = auralisTheme(
    ColorScheme.fromSeed(
      seedColor: const Color(0xFFBFA5F5),
      brightness: Brightness.dark,
    ),
  );

  for (final (size, scale) in [
    (const Size(1280, 800), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(320, 568), 2.0),
  ]) {
    testWidgets(
      'Video settings cards, grouped forms and layout choices at $size / $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final settings = RefreshSettings();
        final music = jsonEncode(settings.toJson());
        var volumeResets = 0;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                appBar: AppBar(title: const Text('Settings & diagnostics')),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 760,
                      child: VideoSettingsOptions(
                        settings: settings,
                        onVolumeBoostDisabled: () => volumeResets++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('video-settings-intro')),
          findsOneWidget,
        );
        expect(find.widgetWithText(ListTile, 'Video decoder'), findsNothing);
        expect(
          find.byKey(const ValueKey('video-diagnostics-idle')),
          findsOneWidget,
        );
        if (size.width > 1000) {
          await reviewImage(tester, boundary, 'video-settings-refresh-desktop');
        }
        await tapVisible(tester, find.text('Player settings'));
        expect(find.byType(VideoSettingsDialog), findsOneWidget);
        if (size.width > 1000) {
          await reviewImage(tester, boundary, 'video-settings-form-desktop');
        }
        final gestures = find.widgetWithText(
          SwitchListTile,
          'Tap and swipe gestures',
        );
        await tapVisible(tester, gestures);
        expect(settings.videoPlayback.gestures, isFalse);
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(35);
        slider.onChangeEnd!(35);
        await tester.pumpAndSettle();
        expect(settings.videoPlayback.seekSeconds, 35);
        final boost = find.widgetWithText(SwitchListTile, 'Allow volume boost');
        await tapVisible(tester, boost);
        expect(settings.videoPlayback.volumeBoost, isTrue);
        await tapVisible(tester, boost);
        expect(volumeResets, 1);
        await tapVisible(tester, find.text('Done'));
        await tapVisible(tester, find.text('Player control layout'));
        await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Portrait'));
        await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Top left'));
        final control = find.widgetWithText(FilterChip, 'Playback speed');
        await tapVisible(tester, control);
        expect(
          settings.videoPlayback.controls(
            VideoControlZone.topStart,
            wide: false,
          ),
          [VideoControl.speed],
        );
        await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Landscape'));
        expect(
          settings.videoPlayback.controls(
            VideoControlZone.topStart,
            wide: true,
          ),
          isEmpty,
        );
        await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Portrait'));
        await tapVisible(tester, find.byTooltip('Control animation: Default'));
        await tapVisible(tester, find.text('Minimal fade').last);
        expect(settings.videoPlayback.animation, VideoControlAnimation.fade);
        await tapVisible(tester, find.text('Reset this area'));
        expect(
          settings.videoPlayback.controls(
            VideoControlZone.topStart,
            wide: false,
          ),
          isEmpty,
        );
        await tapVisible(tester, find.text('Done'));
        expect(settings.saves, greaterThan(0));
        expect(
          jsonEncode(settings.toJson()),
          music,
          reason: 'Music preferences are untouched',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'configuration and custom button editors handle save, cancel and keyboard at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final settings = RefreshSettings();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: VideoSettingsOptions(settings: settings),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> openConfig() async {
          await tapVisible(tester, find.text('mpv configuration'));
          await tapVisible(tester, find.text('mpv.conf'));
        }

        await openConfig();
        await tester.enterText(find.byType(TextFormField), 'keep-open=yes');
        if (size.width < 900) {
          tester.view.viewInsets = FakeViewPadding(
            bottom: size.height < 600 ? 220 : 300,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tapVisible(tester, find.text('Save'));
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(settings.videoPlayback.mpvConfig, 'keep-open=yes');
        await openConfig();
        await tester.enterText(find.byType(TextFormField), 'discard this');
        await tapVisible(tester, find.text('Cancel'));
        expect(settings.videoPlayback.mpvConfig, 'keep-open=yes');
        await tapVisible(tester, find.text('Custom buttons'));
        await tapVisible(tester, find.text('Custom button 1'));
        final fields = find.byType(TextFormField);
        await tester.enterText(fields.first, 'Ready');
        await tester.enterText(fields.last, 'not JSON');
        await tapVisible(tester, find.text('Save'));
        expect(settings.videoPlayback.commands, isEmpty);
        await tester.enterText(fields.last, '["show-text","Ready"]');
        await tapVisible(tester, find.text('Save'));
        expect(
          settings.videoPlayback.commands[VideoControl.customOne]!.label,
          'Ready',
        );
        expect(settings.videoPlayback.commands[VideoControl.customOne]!.args, [
          'show-text',
          'Ready',
        ]);
        await tapVisible(tester, find.text('Custom buttons'));
        await tapVisible(tester, find.text('Ready'));
        await tapVisible(tester, find.text('Remove'));
        expect(settings.videoPlayback.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Listening stats refresh preserves ranges, rankings and stored data at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final settings = RefreshSettings();
        for (var day = 0; day < 10; day++) {
          settings.listening.record(
            Track(
              id: '$day',
              title: 'Evening waves $day',
              artist: 'Auralis artist $day',
              source: 'Music',
            ),
            (day + 1) * 120000,
            day + 1,
            DateTime.now().subtract(Duration(days: day)),
          );
        }
        final before = jsonEncode(settings.listening.toJson());
        final player = PlayerController(
          FakeAudio(),
          TelegramStreamProxy((_) async => {}),
          settings,
        );
        addTearDown(player.shutdown);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: theme,
              home: StatsDataDialog(player: player, fullscreen: true),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('stats-intro')), findsOneWidget);
        expect(find.byKey(const ValueKey('stats-summary')), findsOneWidget);
        if (size.width > 1000) {
          await reviewImage(
            tester,
            boundary,
            'listening-stats-refresh-desktop',
          );
        }
        for (final label in ['7 days', '30 days', 'This year', 'All time']) {
          await tapVisible(tester, find.widgetWithText(ChoiceChip, label));
          expect(tester.takeException(), isNull);
        }
        await tapVisible(tester, find.text('Play count'));
        expect(
          tester.widget<ListeningBars>(find.byType(ListeningBars)).plays,
          isTrue,
        );
        await tapVisible(tester, find.text('Artists'));
        expect(find.text('Auralis artist 9'), findsOneWidget);
        await tapVisible(tester, find.text('Tracks'));
        expect(find.text('Evening waves 9'), findsOneWidget);
        expect(jsonEncode(settings.listening.toJson()), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'only active player diagnostics invoke callbacks, save errors stay visible',
    (tester) async {
      final settings = RefreshSettings()..failSave = true;
      final opened = <VideoDiagnostic>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: VideoSettingsOptions(
                settings: settings,
                diagnostics: {
                  for (final diagnostic in VideoDiagnostic.values)
                    diagnostic: (_) async => opened.add(diagnostic),
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final diagnostic in VideoDiagnostic.values) {
        await tapVisible(tester, find.text(diagnostic.label));
      }
      expect(opened, VideoDiagnostic.values);
      await tapVisible(tester, find.text('Player settings'));
      await tapVisible(
        tester,
        find.widgetWithText(SwitchListTile, 'Tap and swipe gestures'),
      );
      expect(find.text('Could not save video settings.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
