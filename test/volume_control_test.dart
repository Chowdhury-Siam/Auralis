import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class VolumeSettings extends MemorySettings {
  int saves = 0;
  @override
  Future<void> save() async {
    saves++;
  }
}

void main() {
  Future<(FakeAudio, PlayerController, VolumeSettings)> mount(
    WidgetTester tester, {
    bool openPlayer = true,
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final audio = FakeAudio()..playing = true;
    final settings = VolumeSettings()..reducedMotion = true;
    final player =
        PlayerController(audio, TelegramStreamProxy((_) async => {}), settings)
          ..queue.add(
            const Track(
              id: 'volume-track',
              title: 'Volume test',
              artist: 'Test artist',
              source: 'Music channel',
            ),
          )
          ..index = 0;
    final telegram = TelegramService(Directory('unused'), MemoryVault());
    addTearDown(player.shutdown);
    addTearDown(telegram.shutdown);
    await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
    await tester.pumpAndSettle();
    if (openPlayer) {
      await tester.tap(find.byKey(const ValueKey('open-current-track')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('volume-slider')), findsNothing);
    return (audio, player, settings);
  }

  testWidgets(
    'desktop arrow keys adjust live volume, clamp and show a temporary indicator',
    (tester) async {
      final (audio, player, settings) = await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(audio.volumes.last, 75);
      expect(settings.volume, 75);
      expect(settings.saves, 1);
      expect(find.byKey(const ValueKey('volume-osd')), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(audio.volumes.last, 70);
      await player.setVolume(99);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(audio.volumes.last, 100);
      await player.setVolume(1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(audio.volumes.last, 0);
      expect(find.text('0%'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.byKey(const ValueKey('volume-osd')), findsNothing);
      expect(audio.playing, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'typing keeps arrow keys; the floating desktop dock includes artwork',
    (tester) async {
      final (audio, _, _) = await mount(tester, openPlayer: false);
      final dock = find.byKey(const ValueKey('player-bar'));
      final art = find.descendant(of: dock, matching: find.byType(Artwork));
      expect(art, findsOneWidget);
      expect(tester.widget<Artwork>(art).track?.id, 'volume-track');
      expect(
        find.ancestor(of: dock, matching: find.byType(Positioned)),
        findsWidgets,
      );
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(audio.volumes, isEmpty);
      expect(find.byKey(const ValueKey('volume-osd')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'Android uses its hardware volume and has no app slider or desktop key override',
    (tester) async {
      final (audio, _, _) = await mount(
        tester,
        platform: TargetPlatform.android,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(audio.volumes, isEmpty);
      expect(find.byKey(const ValueKey('volume-osd')), findsNothing);
      expect(find.byKey(const ValueKey('volume-slider')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'final volume persists without writing during every drag update',
    () async {
      final dir = await Directory.systemTemp.createTemp('auralis-volume-');
      final settings = AppSettings(File('${dir.path}/settings.json'));
      final audio = FakeAudio();
      final player = PlayerController(
        audio,
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      addTearDown(() async {
        await player.shutdown();
        await dir.delete(recursive: true);
      });
      await player.setVolume(35, persist: false);
      expect(audio.volumes.last, 35);
      expect(await settings.file.exists(), isFalse);
      await player.setVolume(60);
      final restored = AppSettings(settings.file);
      await restored.load();
      expect(restored.volume, 60);
    },
  );
}
