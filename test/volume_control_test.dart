import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
    WidgetTester tester,
  ) async {
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
    addTearDown(player.shutdown);
    await tester.pumpWidget(
      AuralisApp(
        player: player,
        telegram: TelegramService(Directory('unused'), MemoryVault()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('volume-control')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('open-current-track')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('volume-slider')).hitTestable(), findsOneWidget);
    return (audio, player, settings);
  }

  testWidgets(
    'wheel over speaker or slider changes live volume, clamps and ignores sideways scrolling',
    (tester) async {
      final (audio, player, settings) = await mount(tester);
      Future<void> wheel(Offset position, Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: position, scrollDelta: delta),
        );
        await tester.pump();
      }

      await wheel(
        tester.getCenter(find.byIcon(Icons.volume_up_rounded)),
        const Offset(0, -120),
      );
      expect(audio.volumes.last, 75);
      expect(settings.volume, 75);
      expect(settings.saves, 1);
      final center = tester.getCenter(
        find.byKey(const ValueKey('volume-slider')),
      );
      await wheel(center, const Offset(0, 120));
      expect(audio.volumes.last, 70);
      await player.setVolume(99);
      await wheel(center, const Offset(0, -120));
      expect(audio.volumes.last, 100);
      await player.setVolume(1);
      await wheel(center, const Offset(0, 120));
      expect(audio.volumes.last, 0);
      final calls = audio.volumes.length;
      await wheel(center, const Offset(120, 0));
      await wheel(
        tester.getCenter(find.byKey(const ValueKey('page-title'))),
        const Offset(0, -120),
      );
      expect(audio.volumes, hasLength(calls));
      expect(audio.playing, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'held slider drag updates sound before release and saves on release',
    (tester) async {
      final (audio, _, settings) = await mount(tester);
      final slider = find.byKey(const ValueKey('volume-slider'));
      final gesture = await tester.startGesture(
        tester.getCenter(slider),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-24, 0));
      await tester.pump();
      expect(audio.volumes, isNotEmpty);
      final lower = audio.volumes.last;
      expect(lower, lessThan(70));
      expect(settings.saves, 0);
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
      expect(audio.volumes.last, greaterThan(lower));
      expect(settings.saves, 0);
      await gesture.up();
      await tester.pump();
      expect(settings.saves, 1);
      expect(audio.playing, isTrue);
      expect(tester.takeException(), isNull);
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
