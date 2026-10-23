import 'dart:async';
import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class DelayedCoverTelegram extends TelegramService {
  DelayedCoverTelegram()
      : super(Directory('unused'), MemoryVault(), transport: FakeTd());
  final pending = Completer<Uint8List?>();
  @override
  bool get ready => true;
  @override
  Future<Uint8List?> cover(Track track) => pending.future;
}

ColorScheme scheme(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!.colorScheme;

Future<void> waitForPrimary(WidgetTester tester, Color primary) async {
  // Image decoding/toByteData runs outside the fake widget-test clock.
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump();
    if (scheme(tester).primary == primary) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Artwork palette did not finish updating.');
}

void main() {
  testWidgets('artwork themes the whole app, follows rapid track changes and resets without covers', (
    tester,
  ) async {
    final teal = File('test/fixtures/theme-teal.png').readAsBytesSync();
    final orange = File('test/fixtures/theme-orange.png').readAsBytesSync();
    final expected = (await tester.runAsync(() => ColorScheme.fromImageProvider(
      provider: MemoryImage(orange),
      brightness: Brightness.dark,
    )))!;
    final player = PlayerController(
      FakeAudio(),
      TelegramStreamProxy((_) async => {}),
      MemorySettings()..reducedMotion = true,
    )..queue.addAll([
        Track(id: 'teal', title: 'Teal', artist: '', source: '', coverPreview: teal),
        Track(id: 'orange', title: 'Orange', artist: '', source: '', coverPreview: orange),
        const Track(id: 'missing', title: 'Missing cover', artist: '', source: ''),
      ])
      ..index = 0;
    final telegram = TelegramService(
      Directory('unused'), MemoryVault(), transport: FakeTd(),
    );
    addTearDown(player.shutdown);
    addTearDown(telegram.shutdown);
    await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
    // Switch while the first image is still resolving; it cannot win later.
    player.index = 1;
    player.notifyListeners();
    await waitForPrimary(tester, expected.primary);
    expect(scheme(tester), expected);
    final shellTheme = Theme.of(tester.element(find.byType(PlayerShell)));
    expect(shellTheme.colorScheme, expected);
    expect(shellTheme.scaffoldBackgroundColor, expected.surface);
    final palette = scheme(tester);
    for (var tick = 0; tick < 5; tick++) {
      player.notifyListeners();
      await tester.pump();
    }
    expect(identical(scheme(tester), palette), isTrue);
    await tester.tap(find.byTooltip('Settings').first);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Backup & Restore'))).colorScheme, expected);
    player.index = 2;
    player.notifyListeners();
    await waitForPrimary(tester, accent);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late full artwork cannot recolor a different current track', (
    tester,
  ) async {
    final telegram = DelayedCoverTelegram();
    final player = PlayerController(
      FakeAudio(),
      TelegramStreamProxy((_) async => {}),
      MemorySettings()..reducedMotion = true,
    )..queue.addAll([
        const Track(id: 'old', title: 'Old', artist: '', source: '', fileId: 1),
        const Track(id: 'current', title: 'Current', artist: '', source: ''),
      ])
      ..index = 0;
    addTearDown(player.shutdown);
    addTearDown(telegram.shutdown);
    await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
    player.index = 1;
    player.notifyListeners();
    await tester.pumpAndSettle();
    telegram.pending.complete(File('test/fixtures/theme-teal.png').readAsBytesSync());
    await tester.pumpAndSettle();
    expect(scheme(tester).primary, accent);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
