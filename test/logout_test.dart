import 'dart:async';
import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const oldHash = 'abcdef0123456789abcdef0123456789';
const newHash = '0123456789abcdef0123456789abcdef';

class ClosingTd extends FakeTd {
  int starts = 0, closes = 0;
  @override
  Future<void> start(String libraryPath) async {
    starts++;
  }

  @override
  Future<void> close() async {
    closes++;
    await super.close();
  }
}

class FailingVault extends MemoryVault {
  bool fail = false;
  @override
  Future<void> write(Json secrets) async {
    if (fail) throw const FileSystemException('simulated vault failure');
    await super.write(secrets);
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('auralis-logout-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  testWidgets('configured builds hide API fields and use phone, code and password sign-in', (tester) async {
    final td = FakeTd(), vault = MemoryVault();
    final service = TelegramService(directory, vault, transport: td,
      applicationApiId: 12345, applicationApiHash: oldHash,
    );
    addTearDown(service.shutdown);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
      listenable: service,
      builder: (_, _) => AuthForm(telegram: service),
    ))));
    expect(find.text('Telegram API ID'), findsNothing);
    expect(find.text('Telegram API hash'), findsNothing);
    expect(find.text('Connect Telegram'), findsOneWidget);
    await tester.runAsync(() => service.start());
    td.auth('authorizationStateWaitPhoneNumber');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '+12025550123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(td.requests.last['@type'], 'setAuthenticationPhoneNumber');
    td.auth('authorizationStateWaitCode');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12345');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(td.requests.last['@type'], 'checkAuthenticationCode');
    td.auth('authorizationStateWaitPassword');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    expect(vault.data.keys.toSet(), {'apiId', 'apiHash', 'databaseKey'});
    expect(find.text('Telegram API ID'), findsNothing);
    expect(find.text('Telegram API hash'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('logout forgets API details, waits for close, and next account gets a fresh client', () async {
    final first = ClosingTd(), next = ClosingTd(), vault = MemoryVault();
    final service = TelegramService(
      directory,
      vault,
      transport: first,
      createTransport: () => next,
    );
    addTearDown(service.shutdown);
    await service.start(apiId: 12345, apiHash: oldHash);
    final key = vault.data['databaseKey'];
    final heldRequest = service.request;
    first.auth('authorizationStateReady');
    await Future<void>.delayed(Duration.zero);
    final file = File('${directory.path}/keep.txt');
    await file.writeAsString(
      'App must not recursively delete session folders.',
    );
    await service.logout();
    expect(service.state, 'authorizationStateLoggingOut');
    expect(vault.data, {'databaseKey': key});
    expect(next.starts, 0);
    await service.start(apiId: 99999, apiHash: newHash);
    expect(service.error, contains('Finish signing out'));
    expect(vault.data, {'databaseKey': key});
    first.auth('authorizationStateClosed');
    expect(service.state, 'disconnected');
    await service.start(apiId: 99999, apiHash: newHash);
    expect(service.error, isNull);
    expect(first.closes, 1);
    expect(next.starts, 1);
    final parameters = next.requests.singleWhere(
      (r) => r['@type'] == 'setTdlibParameters',
    );
    expect(parameters['api_id'], 99999);
    expect(parameters['api_hash'], newHash);
    expect(parameters['database_encryption_key'], key);
    await heldRequest({'@type': 'getFile', 'file_id': 42});
    expect(next.requests.last['@type'], 'getFile');
    expect(first.requests.where((r) => r['@type'] == 'getFile'), isEmpty);
    next.auth('authorizationStateWaitPhoneNumber');
    await service.submit('+12025550124');
    next.auth('authorizationStateWaitCode');
    await service.submit('54321');
    next.auth('authorizationStateWaitPassword');
    await service.submit('new sample password');
    expect(vault.data, {
      'databaseKey': key,
      'apiId': 99999,
      'apiHash': newHash,
    });
    expect(await file.exists(), isTrue);
  });

  test(
    'rejected logout preserves API details and the active account',
    () async {
      final td = ClosingTd(), vault = MemoryVault();
      final service = TelegramService(directory, vault, transport: td);
      addTearDown(service.shutdown);
      await service.start(apiId: 12345, apiHash: oldHash);
      td.auth('authorizationStateReady');
      await Future<void>.delayed(Duration.zero);
      final before = {...vault.data};
      td.onRequest = (r) async {
        if (r['@type'] == 'logOut') throw TdException(429, 'simulated retry');
        return null;
      };
      await service.logout();
      expect(service.ready, isTrue);
      expect(service.error, contains('429'));
      expect(vault.data, before);
      expect(td.closes, 0);
    },
  );

  test(
    'vault-only database key does not reconnect automatically after restarting',
    () async {
      final td = ClosingTd();
      final vault = MemoryVault()..data = {'databaseKey': 'retained-key'};
      final service = TelegramService(directory, vault, transport: td);
      addTearDown(service.shutdown);
      await service.start();
      expect(service.state, 'disconnected');
      expect(service.error, isNull);
      expect(td.starts, 0);
      expect(td.requests, isEmpty);
      expect(vault.data, {'databaseKey': 'retained-key'});
    },
  );

  test('close before logout reply is safe; failed vault clearing is visible and recoverable', () async {
    final td = ClosingTd(), next = ClosingTd(), vault = FailingVault();
    final service = TelegramService(
      directory,
      vault,
      transport: td,
      createTransport: () => next,
    );
    addTearDown(service.shutdown);
    await service.start(apiId: 12345, apiHash: oldHash);
    td.onRequest = (r) async {
      if (r['@type'] == 'logOut') td.auth('authorizationStateClosed');
      return null;
    };
    vault.fail = true;
    await service.logout();
    expect(service.state, 'disconnected');
    expect(service.error, contains('saved API details could not be cleared'));
    vault.fail = false;
    await service.start(apiId: 99999, apiHash: newHash);
    expect(service.error, isNull);
    expect(vault.data['apiId'], 99999);
    expect(vault.data['apiHash'], newHash);
  });

  test(
    'a late channel response cannot restore the previous account’s channels',
    () async {
      final td = ClosingTd();
      final service = TelegramService(directory, MemoryVault(), transport: td);
      addTearDown(service.shutdown);
      await service.start(apiId: 12345, apiHash: oldHash);
      td.auth('authorizationStateReady');
      await Future<void>.delayed(Duration.zero);
      final response = Completer<Json>();
      td.onRequest = (r) =>
          r['@type'] == 'getChat' ? response.future : Future.value(null);
      final pending = service.channel(-1);
      await service.logout();
      td.auth('authorizationStateClosed');
      response.complete({
        'id': -1,
        'title': 'Old channel',
        'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
      });
      expect(await pending, isNull);
      expect(service.channels, isEmpty);
    },
  );

  testWidgets(
    'sign out clears old channel selection and shows a blank API form',
    (tester) async {
      final td = ClosingTd(), vault = MemoryVault();
      final service = TelegramService(directory, vault, transport: td);
      await tester.runAsync(
        () => service.start(apiId: 12345, apiHash: oldHash),
      );
      td.auth('authorizationStateReady');
      final settings = MemorySettings()
        ..selectedChannels = [const MusicChat(-1, 'Old channel')];
      final player =
          PlayerController(
              FakeAudio(),
              TelegramStreamProxy(service.request),
              settings,
            )
            ..queue.add(
              const Track(
                id: 'old',
                title: 'Old song',
                artist: 'Test artist',
                source: 'Old channel',
              ),
            )
            ..index = 0;
      addTearDown(player.shutdown);
      addTearDown(service.shutdown);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(AuralisApp(player: player, telegram: service));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      td.onRequest = (r) async {
        if (r['@type'] == 'logOut') throw TdException(429, 'simulated retry');
        return null;
      };
      await tester.tap(find.text('Sign out of Telegram'));
      await tester.pumpAndSettle();
      expect(service.ready, isTrue);
      expect(settings.selectedChannels.single.id, -1);
      expect(vault.data['apiHash'], oldHash);
      expect(
        find.textContaining('Telegram rejected the request'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-bar')), findsNothing);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      td.onRequest = null;
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out of Telegram'));
      await tester.pumpAndSettle();
      expect(settings.selectedChannels, isEmpty);
      expect(player.queue, isEmpty);
      expect(find.byKey(const ValueKey('player-bar')), findsNothing);
      expect(find.textContaining('Signing out of Telegram'), findsOneWidget);
      expect(find.text('Telegram API ID'), findsNothing);
      td.auth('authorizationStateClosed');
      await tester.pumpAndSettle();
      expect(find.text('Telegram API ID'), findsOneWidget);
      expect(find.text('Telegram API hash'), findsOneWidget);
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.controller!.text, isEmpty);
      }
      expect(vault.data.keys, ['databaseKey']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
