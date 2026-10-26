import 'dart:convert';
import 'dart:io';

import 'package:auralis/sync/controller.dart';
import 'package:auralis/sync/document.dart';
import 'package:auralis/sync/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'updater_test.dart' show Headers, Response;

class AccountVault extends MemoryVault {
  @override
  Future<Map<String, dynamic>> read() async => detached(data);
  @override
  Future<void> write(Map<String, dynamic> value) async {
    data = detached(value);
  }
}

class AccountSettings extends MemorySettings {
  int writes = 0;
  int? failAt;
  @override
  Future<void> save() async {
    captureSync?.call(toJson());
    if (++writes == failAt) throw const FileSystemException('injected failure');
    onSaved?.call();
  }
}

class AccountHeaders extends Headers {
  ContentType? _type;
  @override
  ContentType? get contentType => _type;
  @override
  set contentType(ContentType? value) => _type = value;
}

class AccountRequest extends Fake implements HttpClientRequest {
  AccountRequest(this.method, this.uri, this.reply);
  @override
  final String method;
  @override
  final Uri uri;
  final Response Function(AccountRequest) reply;
  final bytes = <int>[];
  @override
  final headers = AccountHeaders();
  @override
  bool followRedirects = true;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async => reply(this);
}

class AccountClient extends Fake implements HttpClient {
  bool owner = false;
  @override
  Duration? connectionTimeout;
  final requests = <AccountRequest>[];
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    final r = AccountRequest(method, uri, _reply);
    requests.add(r);
    return r;
  }

  @override
  Future<HttpClientRequest> postUrl(Uri uri) => openUrl('POST', uri);
  Response _reply(AccountRequest r) {
    Response response(Map<String, dynamic> v, [int code = 200]) =>
        Response(utf8.encode(jsonEncode(v)), statusCode: code);
    final data = r.bytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bytes)) as Map<String, dynamic>;
    if (r.uri.path == '/health') {
      return response({
        'service': 'auralis-sync',
        'configured': true,
        'accounts': true,
        'ownerCreated': true,
        'version': '0.1.76',
      });
    }
    if ([
      '/v1/auth/login',
      '/v1/auth/register',
      '/v1/auth/recover',
    ].contains(r.uri.path)) {
      if ((data['password'] ?? data['newPassword']) != 'test-password') {
        return response({'error': 'Invalid username or password'}, 401);
      }
      final name = data['username'] as String;
      return response({
        'user': {
          'id': (name == 'alice' ? 'a' : 'b') * 32,
          'username': name,
          'admin': owner && name == 'alice',
        },
        'token': r.uri.path.endsWith('recover')
            ? '$name-recovered-session'
            : '$name-session',
        'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
        if (!r.uri.path.endsWith('login')) 'recoveryCode': 'c' * 64,
      });
    }
    if (r.uri.path == '/v1/account') {
      final name = (r.headers.value('authorization') ?? '')
          .replaceFirst('Bearer ', '')
          .split('-')
          .first;
      return response({
        'user': {'id': (name == 'alice' ? 'a' : 'b') * 32, 'username': name},
      });
    }
    if (r.uri.path == '/v1/account/deployment') {
      return response({'deployment': null});
    }
    if (r.uri.path == '/v1/auth/logout') return response({'ok': true});
    if (r.uri.path == '/v1/sync') {
      return response({
        'cursor': 0,
        'more': false,
        'records': <String, dynamic>{},
      });
    }
    return response({'error': 'Not found'}, 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'switching isolates libraries, preserves offline edits and device volume',
    () async {
      final client = AccountClient();
      await HttpOverrides.runZoned(() async {
        final settings = AccountSettings()
          ..favoriteIds = {'local-alice'}
          ..volume = 17;
        final sync = SyncController(
          settings,
          AccountVault(),
          onApplied: () {},
          paused: () => true,
        );
        try {
          await sync.signIn('https://sync.example', 'alice', 'test-password');
          settings.favoriteIds.add('offline-alice');
          await settings.save();
          await sync.signIn('https://sync.example', 'bob', 'test-password');
          expect(settings.favoriteIds, isEmpty);
          expect(settings.volume, 17);
          settings.favoriteIds.add('offline-bob');
          await settings.save();
          await sync.switchAccount(
            sync.savedAccounts.firstWhere((u) => u.username == 'alice'),
          );
          expect(settings.favoriteIds, {'local-alice', 'offline-alice'});
          expect(
            settings.syncState['dirty'],
            contains(SyncDocument.key(['favorite', 'offline-alice'])),
          );
          await expectLater(
            sync.signIn('https://sync.example', 'bob', 'wrong'),
            throwsFormatException,
          );
          expect(sync.account!.username, 'alice');
          await sync.signOut(keepLocal: false);
          expect(settings.favoriteIds, isEmpty);
          await sync.switchAccount(
            sync.savedAccounts.firstWhere((u) => u.username == 'bob'),
          );
          expect(settings.favoriteIds, {'offline-bob'});
        } finally {
          await sync.close();
        }
      }, createHttpClient: (_) => client);
    },
  );
  test(
    'failed account commit rolls back without mixing local libraries',
    () async {
      final client = AccountClient();
      await HttpOverrides.runZoned(() async {
        final settings = AccountSettings()..favoriteIds = {'alice'};
        final sync = SyncController(
          settings,
          AccountVault(),
          onApplied: () {},
          paused: () => true,
        );
        try {
          await sync.signIn('https://sync.example', 'alice', 'test-password');
          settings.failAt = settings.writes + 2;
          await expectLater(
            sync.signIn('https://sync.example', 'bob', 'test-password'),
            throwsA(isA<FileSystemException>()),
          );
          expect(sync.account!.username, 'alice');
          expect(settings.favoriteIds, {'alice'});
          expect(sync.savedAccounts.map((u) => u.username), ['alice']);
        } finally {
          await sync.close();
        }
      }, createHttpClient: (_) => client);
    },
  );
  test('startup recovers the committed account journal after interrupted settings write', () async {
    final client = AccountClient();
    await HttpOverrides.runZoned(() async {
      final vault = AccountVault(),
          settings = AccountSettings()..favoriteIds = {'alice'};
      final sync = SyncController(
        settings,
        vault,
        onApplied: () {},
        paused: () => true,
      );
      await sync.signIn('https://sync.example', 'alice', 'test-password');
      await sync.signIn('https://sync.example', 'bob', 'test-password');
      await sync.close();
      final stale = AccountSettings()..favoriteIds = {'stale-alice'};
      final restarted = SyncController(
        stale,
        vault,
        onApplied: () {},
        paused: () => true,
      );
      try {
        await restarted.start();
        expect(restarted.account!.username, 'bob');
        expect(stale.favoriteIds, isEmpty);
      } finally {
        await restarted.close();
      }
    }, createHttpClient: (_) => client);
  });
  test('saved owner deployment values are locked after sign-out and for another user', () async {
    final client = AccountClient()..owner = true;
    await HttpOverrides.runZoned(() async {
      final deployment = AccountVault()
        ..data = {
          'url': 'https://sync.example',
          'worker': 'sync',
          'ownerId': 'a' * 32,
          'cloudflareToken': 'private-token',
          'automatic': false,
        };
      final sync = SyncController(
        AccountSettings(),
        AccountVault(),
        onApplied: () {},
        paused: () => true,
        deploymentVault: deployment,
      );
      try {
        await sync.signIn('https://sync.example', 'alice', 'test-password');
        while (sync.busy) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          (await sync.deploymentProfile())['cloudflareToken'],
          'private-token',
        );
        await sync.signOut();
        expect((await sync.deploymentProfile())['locked'], true);
        await sync.signIn('https://sync.example', 'bob', 'test-password');
        expect((await sync.deploymentProfile())['locked'], true);
        expect(
          (await sync.deploymentProfile()).containsKey('cloudflareToken'),
          false,
        );
      } finally {
        await sync.close();
      }
    }, createHttpClient: (_) => client);
  });
  test(
    'registration saves recovery code and recovery replaces the session',
    () async {
      final client = AccountClient();
      await HttpOverrides.runZoned(() async {
        final settings = AccountSettings()..favoriteIds = {'local'};
        final sync = SyncController(
          settings,
          AccountVault(),
          onApplied: () {},
          paused: () => true,
        );
        try {
          final code = await sync.signIn(
            'https://sync.example',
            'alice',
            'test-password',
            register: true,
            claimKey: 'd' * 64,
          );
          expect(code, 'c' * 64);
          expect(
            await sync.recoverAccount(
              'https://sync.example',
              'alice',
              code!,
              'test-password',
            ),
            'c' * 64,
          );
          expect(sync.account!.token, 'alice-recovered-session');
          expect(sync.savedAccounts, hasLength(1));
          expect(settings.favoriteIds, {'local'});
        } finally {
          await sync.close();
        }
      }, createHttpClient: (_) => client);
    },
  );
  test(
    'automatic checks target active Worker and respect manual deployment lock',
    () async {
      final client = AccountClient()..owner = true;
      await HttpOverrides.runZoned(() async {
        final deployment = AccountVault()
          ..data = {
            'url': 'https://sync.example',
            'worker': 'sync',
            'account': 'a' * 32,
            'cloudflareToken': 'cf-token',
            'database': 'libsql://test.turso.io',
            'databaseToken': 'db-token',
            'key': 'd' * 64,
            'automatic': true,
          };
        final sync = SyncController(
          AccountSettings(),
          AccountVault(),
          onApplied: () {},
          paused: () => true,
          deploymentVault: deployment,
        );
        try {
          await sync.signIn('https://sync.example', 'alice', 'test-password');
          while (sync.busy) {
            await Future<void>.delayed(Duration.zero);
          }
          await sync.validateWorker('https://other.example');
          await sync.checkWorkerUpdates();
          expect(client.requests.last.uri.host, 'sync.example');
          expect(client.requests.last.uri.path, '/health');
          expect(sync.beginWorkerOperation(), true);
          expect(sync.beginWorkerOperation(), false);
          final count = client.requests.length;
          await sync.checkWorkerUpdates();
          expect(client.requests.length, count);
          await expectLater(
            sync.signIn('https://sync.example', 'bob', 'test-password'),
            throwsFormatException,
          );
          sync.endWorkerOperation();
        } finally {
          await sync.close();
        }
        expect(sync.beginWorkerOperation(), false);
      }, createHttpClient: (_) => client);
    },
  );
  testWidgets('account screens fit phone, landscape and desktop', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final client = AccountClient()..owner = true;
    final sync = await tester.runAsync(
      () => HttpOverrides.runZoned(() async {
        final s = SyncController(
          AccountSettings(),
          AccountVault(),
          onApplied: () {},
          paused: () => true,
        );
        await s.signIn('https://sync.example', 'alice', 'test-password');
        return s;
      }, createHttpClient: (_) => client),
    );
    addTearDown(sync!.close);
    for (final size in [
      const Size(360, 480),
      const Size(844, 390),
      const Size(1280, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(home: SyncAccountPage(sync: sync)));
      await tester.pumpAndSettle();
      expect(find.text('Account & sync'), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-worker-url')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
