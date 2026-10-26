import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/sync/controller.dart';
import 'package:auralis/sync/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'sync_accounts_test.dart'
    show AccountClient, AccountRequest, AccountSettings, AccountVault;
import 'updater_test.dart' show Response;

const profile = {
  'userId': 123456,
  'name': 'Telegram user',
  'apiId': 12345,
  'apiHash': 'ffffffffffffffffffffffffffffffff',
};
const requestId =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const loginLink =
    'tg://login?token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Response response(Map<String, dynamic> data, [int status = 200]) =>
    Response(utf8.encode(jsonEncode(data)), statusCode: status);

class CloudTelegram extends TelegramService {
  CloudTelegram({bool connected = true})
    : super(Directory('unused'), AccountVault(), transport: FakeTd()) {
    state = connected
        ? 'authorizationStateReady'
        : 'authorizationStateWaitPhoneNumber';
  }
  int identity = 123456, qrRequests = 0, approvals = 0, cancellations = 0;
  String? enteredPassword;
  @override
  Future<Map<String, dynamic>> cloudIdentity() async => {
    ...profile,
    'userId': identity,
  };
  @override
  Future<void> requestCloudLogin() async {
    qrRequests++;
    state = 'authorizationStateWaitOtherDeviceConfirmation';
    authenticationLink = loginLink;
    notifyListeners();
  }

  @override
  Future<void> confirmCloudLogin(String link, int userId) async {
    expect(link, loginLink);
    expect(userId, identity);
    approvals++;
  }

  @override
  Future<void> cancelCloudLogin() async {
    cancellations++;
    state = 'authorizationStateWaitPhoneNumber';
    authenticationLink = null;
    notifyListeners();
  }

  @override
  Future<void> submit(String value) async {
    enteredPassword = value;
    state = 'authorizationStateReady';
    notifyListeners();
  }
}

class TelegramClient extends AccountClient {
  final profiles = <String, Map<String, dynamic>>{};
  final disabled = <String>{};
  bool pending = false;
  Completer<void>? holdGet, getStarted;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    if (!uri.path.startsWith('/v1/account/telegram')) {
      return super.openUrl(method, uri);
    }
    final r = AccountRequest(method, uri, _telegram);
    requests.add(r);
    if (method == 'GET' &&
        uri.path == '/v1/account/telegram' &&
        holdGet != null) {
      final old = {...profile};
      getStarted?.complete();
      await holdGet!.future;
      return AccountRequest(
        method,
        uri,
        (_) => response({'enabled': true, 'profile': old}),
      );
    }
    return r;
  }

  Response _telegram(AccountRequest r) {
    final name = (r.headers.value('authorization') ?? '')
        .replaceFirst('Bearer ', '')
        .split('-')
        .first;
    final data = r.bytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bytes)) as Map<String, dynamic>;
    final path = r.uri.path;
    if (path == '/v1/account/telegram') {
      if (r.method == 'PUT') {
        profiles[name] = {for (final k in profile.keys) k: data[k]};
        disabled.remove(name);
      }
      if (r.method == 'DELETE') {
        disabled.add(name);
        profiles.remove(name);
        pending = false;
      }
      return response({
        'enabled': !disabled.contains(name),
        'profile': profiles[name],
      });
    }
    if (path.endsWith('/requests')) {
      if (r.method == 'POST') {
        pending = true;
        expect(data['link'], loginLink);
        return response({
          'id': requestId,
          'code': '123456',
          'expires': 2000000000,
        });
      }
      return response({
        'requests': pending
            ? [
                {'id': requestId, 'expires': 2000000000},
              ]
            : [],
      });
    }
    if (path.endsWith('/claim')) {
      if (data['code'] != '123456') {
        return response({'error': 'Code does not match'}, 400);
      }
      return response({'link': loginLink, 'userId': 123456});
    }
    if (path.endsWith('/complete')) {
      pending = false;
      return response({'ok': true});
    }
    if (r.method == 'DELETE') {
      pending = false;
      return response({'ok': true});
    }
    return response({'state': 'pending'});
  }
}

Future<void> withSync(
  TelegramClient client,
  CloudTelegram td,
  Future<void> Function(SyncController) body,
) async {
  await HttpOverrides.runZoned(() async {
    final sync = SyncController(
      AccountSettings(),
      AccountVault(),
      onApplied: () {},
      paused: () => false,
      telegram: td,
    );
    try {
      await sync.signIn('https://sync.example', 'alice', 'test-password');
      await body(sync);
    } finally {
      await sync.close();
      await td.shutdown();
      td.dispose();
    }
  }, createHttpClient: (_) => client);
}

void main() {
  test(
    'cloud linking preserves an existing local Telegram application identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'auralis-cloud-identity-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final td = FakeTd(),
          vault = AccountVault()
            ..data = {
              'apiId': 777,
              'apiHash': 'a' * 32,
              'databaseKey': base64Encode(List.filled(32, 1)),
            };
      final service = TelegramService(directory, vault, transport: td);
      addTearDown(service.shutdown);
      await service.start(
        apiId: 12345,
        apiHash: 'f' * 32,
        preferSavedIdentity: true,
      );
      final parameters = td.requests.firstWhere(
        (r) => r['@type'] == 'setTdlibParameters',
      );
      expect(parameters['api_id'], 777);
      expect(parameters['api_hash'], 'a' * 32);
    },
  );

  test('TDLib linking uses native QR authorization without exporting a session database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'auralis-telegram-link-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final td = FakeTd();
    td.onRequest = (request) async {
      if (request['@type'] == 'getMe') {
        return {
          '@type': 'user',
          'id': 123456,
          'first_name': 'Telegram',
          'last_name': 'user',
        };
      }
      if (request['@type'] == 'confirmQrCodeAuthentication') {
        return {'@type': 'session', 'id': '42'};
      }
      return null;
    };
    final service = TelegramService(directory, AccountVault(), transport: td);
    addTearDown(service.shutdown);
    await service.start(apiId: 12345, apiHash: 'f' * 32);
    service.state = 'authorizationStateReady';
    final identity = await service.cloudIdentity();
    expect(identity, profile);
    await service.confirmCloudLogin(loginLink, 123456);
    expect(td.requests.last['@type'], 'confirmQrCodeAuthentication');
    await expectLater(
      service.confirmCloudLogin(loginLink, 999),
      throwsFormatException,
    );
    service.state = 'authorizationStateWaitPhoneNumber';
    await service.requestCloudLogin();
    expect(td.requests.last, {
      '@type': 'requestQrCodeAuthentication',
      'other_user_ids': <int>[],
    });
    expect(td.requests.any((r) => r['@type'] == 'readFilePart'), false);
  });
  testWidgets(
    'Telegram account card and approval controls fit phone, landscape and desktop',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final client = TelegramClient()
        ..profiles['alice'] = {...profile}
        ..pending = true;
      final td = CloudTelegram();
      SyncController? controller;
      await tester.runAsync(
        () => HttpOverrides.runZoned(() async {
          controller = SyncController(
            AccountSettings(),
            AccountVault(),
            onApplied: () {},
            paused: () => false,
            telegram: td,
          );
          await controller!.signIn(
            'https://sync.example',
            'alice',
            'test-password',
          );
          await controller!.syncTelegramAccount();
        }, createHttpClient: (_) => client),
      );
      final sync = controller!;
      addTearDown(() async {
        await sync.close();
        await td.shutdown();
        td.dispose();
      });
      for (final size in [
        const Size(360, 480),
        const Size(844, 390),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(MaterialApp(home: SyncAccountPage(sync: sync)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Include Telegram account'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Include Telegram account'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  test('Telegram sync publishes only identity and API connection fields, not the session database', () async {
    final client = TelegramClient(), td = CloudTelegram();
    await withSync(client, td, (sync) async {
      await sync.syncTelegramAccount();
      expect(sync.linkedTelegram!['userId'], 123456);
      final upload = client.requests.firstWhere(
        (r) => r.method == 'PUT' && r.uri.path == '/v1/account/telegram',
      );
      final payload = jsonDecode(utf8.decode(upload.bytes)) as Map;
      expect(payload.keys.toSet(), {...profile.keys, 'automatic'});
      expect(payload.containsKey('databaseKey'), false);
      expect(payload.containsKey('files'), false);
      await sync.setTelegramIncluded(false);
      await sync.syncTelegramAccount();
      expect(sync.telegramIncluded, false);
      expect(client.profiles, isEmpty);
    });
  });
  test('new device creates a fresh Telegram login and exposes only its approval code', () async {
    final client = TelegramClient()..profiles['alice'] = {...profile};
    final td = CloudTelegram(connected: false);
    await withSync(client, td, (sync) async {
      await sync.syncTelegramAccount();
      expect(td.qrRequests, 1);
      expect(sync.telegramPairCode, '123456');
      expect(sync.telegramSyncStatus, contains('already connected device'));
      await sync.useTelegramPhoneSignIn();
      expect(td.cancellations, 1);
      expect(sync.telegramPairCode, isNull);
      await sync.syncTelegramAccount();
      expect(td.qrRequests, 1);
    });
  });
  test('approval checks account identity and code before creating an independent session', () async {
    final client = TelegramClient()
      ..profiles['alice'] = {...profile}
      ..pending = true;
    final td = CloudTelegram();
    await withSync(client, td, (sync) async {
      await sync.syncTelegramAccount();
      expect(sync.telegramDeviceRequests, hasLength(1));
      await expectLater(
        sync.approveTelegramDevice(requestId, '000000'),
        throwsFormatException,
      );
      expect(td.approvals, 0);
      td.identity = 999;
      await expectLater(
        sync.approveTelegramDevice(requestId, '123456'),
        throwsFormatException,
      );
      expect(td.approvals, 0);
      td.identity = 123456;
      await sync.approveTelegramDevice(requestId, '123456');
      expect(td.approvals, 1);
      expect(client.pending, false);
    });
  });
  test('switching Auralis accounts does not silently upload the previous Telegram identity', () async {
    final client = TelegramClient(), td = CloudTelegram();
    await withSync(client, td, (sync) async {
      await sync.syncTelegramAccount();
      await sync.signIn('https://sync.example', 'bob', 'test-password');
      await sync.syncTelegramAccount();
      expect(client.profiles['bob'], isNull);
      expect(sync.telegramSyncStatus, contains('another Auralis account'));
      await sync.setTelegramIncluded(true);
      expect(client.profiles['bob']!['userId'], 123456);
    });
  });
  test('Telegram two-step password is submitted locally and never uploaded to the Worker', () async {
    final client = TelegramClient()..profiles['alice'] = {...profile};
    final td = CloudTelegram(connected: false)
      ..state = 'authorizationStateWaitPassword';
    await withSync(client, td, (sync) async {
      await sync.syncTelegramAccount();
      expect(sync.telegramNeedsPassword, true);
      await sync.submitTelegramPassword('telegram-two-step-secret');
      expect(td.enteredPassword, 'telegram-two-step-secret');
      expect(
        client.requests.any(
          (r) => utf8.decode(r.bytes).contains('telegram-two-step-secret'),
        ),
        false,
      );
    });
  });
  test(
    'disabling Telegram sync invalidates an older in-flight profile response',
    () async {
      final client = TelegramClient()..profiles['alice'] = {...profile},
          td = CloudTelegram();
      await withSync(client, td, (sync) async {
        client.holdGet = Completer<void>();
        client.getStarted = Completer<void>();
        final check = sync.syncTelegramAccount();
        await client.getStarted!.future;
        await sync.setTelegramIncluded(false);
        client.holdGet!.complete();
        await check;
        expect(sync.telegramIncluded, false);
        expect(client.disabled, contains('alice'));
        expect(
          client.requests.where(
            (r) => r.method == 'PUT' && r.uri.path == '/v1/account/telegram',
          ),
          isEmpty,
        );
        client.holdGet = null;
      });
    },
  );
}
