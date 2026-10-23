import 'dart:io';
import 'dart:ui' as ui;

import 'package:auralis/data_files.dart';
import 'package:auralis/player.dart';
import 'package:auralis/stats_view.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class Files extends DataFiles {
  int writes = 0;
  @override
  Future<String?> savePath(String name, String extension) async =>
      testExportPath('backup.json');
  @override
  Future<void> write(String path, String text) async {
    writes++;
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
    'account option and password validation fit phone and desktop; cancellation preserves sign-in',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('auralis-backup-view-'),
      ))!;
      final td = FakeTd();
      final service = TelegramService(directory, MemoryVault(), transport: td);
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        MemorySettings(),
      );
      final files = Files();
      final boundary = GlobalKey();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Segoe UI'),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: StatsDataDialog(
                player: player,
                telegram: service,
                files: files,
                openBackupSection: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      // A dialog opened during reconnect must include the account by default
      // once Telegram becomes ready, without reopening the dialog.
      await tester.runAsync(
        () => service.start(
          apiId: 12345,
          apiHash: 'abcdef0123456789abcdef0123456789',
        ),
      );
      td.auth('authorizationStateReady');
      await tester.pumpAndSettle();
      for (final size in [const Size(1280, 800), const Size(360, 640)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/screenshots/backup-account-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      td.requests.clear();
      final create = find.text('Create backup');
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.text('Protect your Telegram backup'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).first, 'short');
      await tester.enterText(find.byType(TextField).last, 'different');
      await tester.tap(create.last);
      await tester.pumpAndSettle();
      expect(
        find.text('Use at least 10 characters and matching passwords.'),
        findsOneWidget,
      );
      expect(files.writes, 0);
      expect(td.requests, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(service.ready, isTrue);
      expect(files.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await player.shutdown();
        await service.shutdown();
        await directory.delete(recursive: true);
      });
      service.dispose();
    },
  );
}
