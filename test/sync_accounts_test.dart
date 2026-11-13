import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/data_backup.dart';
import 'package:auralis/models.dart';
import 'package:auralis/player.dart';
import 'package:auralis/sync/controller.dart';
import 'package:auralis/sync/document.dart';
import 'package:auralis/sync/deployment.dart';
import 'package:auralis/sync/deployment_view.dart';
import 'package:auralis/sync/settings_view.dart';
import 'package:auralis/telegram/stream_proxy.dart';
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
  AccountClient({this.openLive});
  final Future<HttpClientRequest> Function()? openLive;
  bool owner = false, ownerCreated = true;
  Map<String, dynamic>? deployment;
  Response Function(AccountRequest, Map<String, dynamic>)? syncReply;
  @override
  Duration? connectionTimeout;
  final requests = <AccountRequest>[];
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    final r = AccountRequest(method, uri, _reply);
    requests.add(r);
    if (uri.path == '/v1/live') {
      if (openLive case final open?) return open();
      throw const SocketException('Live transport is offline in account tests');
    }
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
        'ownerCreated': ownerCreated,
        'version': currentSyncWorkerVersion,
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
      if (!(r.headers.value('authorization') ?? '').startsWith(
        'Bearer alice-',
      )) {
        return response({'error': 'Owner required'}, 403);
      }
      if (r.method == 'PUT') deployment = detached(data);
      return response({
        'deployment': deployment,
        'version': currentSyncWorkerVersion,
      });
    }
    if (r.uri.path == '/v1/auth/logout') return response({'ok': true});
    if (r.uri.path == '/v1/sync') {
      if (syncReply case final reply?) return reply(r, data);
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

class LoopbackHttpOverrides extends HttpOverrides {}

class SyncPlaybackAudio extends FakeAudio {
  void advance(Duration amount) {
    position += amount;
    notifyListeners();
  }
}

void main() {
  test('online devices receive play starts, listening progress and qualified plays automatically', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final liveClient = LoopbackHttpOverrides().createHttpClient(null);
    final liveUri = Uri.http('127.0.0.1:${server.port}', '/v1/live');
    final peers = <WebSocket>[];
    final live = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      peers.add(socket);
      socket.listen((_) {}, onDone: () => peers.remove(socket));
      if (peers.length == 2 && !live.isCompleted) live.complete();
    });

    final cloud = SyncDocument({});
    var revision = 0;
    final client = AccountClient(openLive: () => liveClient.getUrl(liveUri))
      ..syncReply = (request, data) {
        final previous = jsonEncode(cloud.records);
        cloud.merge(data['ops'] as Map<String, dynamic>);
        if (jsonEncode(cloud.records) != previous) {
          revision++;
          for (final peer in peers) {
            peer.add('changed');
          }
        }
        return Response(
          utf8.encode(
            jsonEncode({
              'cursor': revision,
              'more': false,
              'records': data['cursor'] == revision ? {} : cloud.records,
            }),
          ),
        );
      };
    try {
      await HttpOverrides.runZoned(() async {
        final sender = AccountSettings(), receiver = AccountSettings();
        void Function()? received;
        var paused = false;
        final a = SyncController(
          sender,
          AccountVault(),
          onApplied: () {},
          paused: () => paused,
        );
        final b = SyncController(
          receiver,
          AccountVault(),
          onApplied: () => received?.call(),
          paused: () => paused,
        );
        final audio = SyncPlaybackAudio()
          ..duration = const Duration(seconds: 16);
        var elapsed = Duration.zero;
        final player = PlayerController(
          audio,
          TelegramStreamProxy((_) async => {}),
          sender,
          elapsed: () => elapsed,
        );
        const track = Track(
          id: '-100:20',
          title: 'Test song',
          artist: 'Test artist',
          source: 'Music',
          fileId: 1,
          size: 100,
          duration: Duration(seconds: 16),
        );

        Future<void> expectRemote(
          bool Function() check,
          Future<void> Function() action,
        ) async {
          final delivered = Completer<void>();
          received = () {
            if (!delivered.isCompleted && check()) delivered.complete();
          };
          try {
            await action();
            received?.call();
            await delivered.future.timeout(
              const Duration(seconds: 4),
              onTimeout: () => throw StateError(
                'Sender: ${sender.recentIds}, ${sender.listening.milliseconds} ms, ${sender.listening.plays} plays (${a.error}); receiver: ${receiver.recentIds}, ${receiver.listening.milliseconds} ms, ${receiver.listening.plays} plays (${b.error})',
              ),
            );
          } finally {
            received = null;
          }
        }

        Future<void> playFor(int seconds) async {
          final amount = Duration(seconds: seconds);
          elapsed += amount;
          audio.advance(amount);
        }

        try {
          for (final sync in [a, b]) {
            await sync.signIn('https://sync.example', 'alice', 'test-password');
          }
          await live.future.timeout(
            const Duration(seconds: 4),
            onTimeout: () => throw StateError(
              'Connected sockets: ${peers.length}; requests: ${client.requests.map((r) => r.uri.path).toList()}',
            ),
          );
          await expectRemote(
            () => receiver.recentIds.firstOrNull == track.id,
            () => player.play(track),
          );
          await expectRemote(
            () => receiver.listening.milliseconds == 1000,
            () => playFor(1),
          );
          expect(receiver.listening.plays, 0);
          await expectRemote(
            () => receiver.listening.milliseconds == 6000,
            () => playFor(5),
          );
          await expectRemote(
            () => receiver.listening.plays == 1,
            () => playFor(2),
          );
          expect(receiver.listening.milliseconds, 8000);
        } finally {
          paused = true;
          await player.shutdown();
          await a.close();
          await b.close();
        }
      }, createHttpClient: (_) => client);
    } finally {
      liveClient.close(force: true);
      for (final peer in peers.toList()) {
        unawaited(peer.close());
      }
      await server.close(force: true);
    }
  });

  test(
    'cloud merge and sync preserve both devices’ edits across pages',
    () async {
      final cloud = SyncDocument({});
      final revisions = <String, int>{};
      var revision = 0;
      var paginated = false, unavailable = false;
      final client = AccountClient()
        ..syncReply = (request, data) {
          expect(
            request.headers.value('authorization'),
            'Bearer alice-session',
          );
          if (unavailable) {
            return Response(
              utf8.encode('<html>Unavailable</html>'),
              statusCode: 503,
            );
          }
          final ops = data['ops'] as Map<String, dynamic>;
          expect(ops.length, lessThanOrEqualTo(100));
          for (final entry in ops.entries) {
            final before = jsonEncode(cloud.records[entry.key]);
            cloud.merge({entry.key: entry.value});
            if (jsonEncode(cloud.records[entry.key]) != before) {
              revisions[entry.key] = ++revision;
            }
          }
          final changed =
              revisions.entries
                  .where((entry) => entry.value > (data['cursor'] as int))
                  .toList()
                ..sort((a, b) => a.value.compareTo(b.value));
          final page = changed.take(200).toList();
          final cursor = page.isEmpty ? revision : page.last.value;
          paginated |= cursor < revision;
          return Response(
            utf8.encode(
              jsonEncode({
                'cursor': cursor,
                'more': cursor < revision,
                'records': {
                  for (final entry in page) entry.key: cloud.records[entry.key],
                },
              }),
            ),
          );
        };
      await HttpOverrides.runZoned(() async {
        final desktop = AccountSettings()..favoriteIds = {'desktop-favorite'};
        final phone = AccountSettings()
          ..playlists = {
            'Phone mix': ['song-0'],
          };
        Track song(int i) => Track(
          id: 'song-$i',
          title: 'Song $i',
          artist: 'Artist',
          source: 'Channel',
        );
        final desktopDay = DateTime(2026, 10, 20, 12);
        final phoneDay = DateTime(2026, 10, 21, 12);
        for (var i = 0; i < 205; i++) {
          desktop.listening.record(song(i), 1000, 1, desktopDay);
        }
        // Independent histories can overlap by song without overlapping by day.
        phone.listening.record(song(0), 2500, 1, phoneDay);
        var paused = true;
        SyncController device(AccountSettings settings) => SyncController(
          settings,
          AccountVault(),
          onApplied: () {},
          paused: () => paused,
        );
        final a = device(desktop), b = device(phone);
        try {
          for (final sync in [a, b]) {
            await sync.signIn('https://sync.example', 'alice', 'test-password');
          }
          paused = false;
          await a.flush();
          await b.flush();
          expect(paginated, isTrue);
          expect(b.error, isNull);
          expect(phone.favoriteIds, {'desktop-favorite'});
          expect(phone.listening.tracks, hasLength(205));
          expect(phone.listening.days['2026-10-20']!.milliseconds, 205000);
          expect(phone.listening.days['2026-10-21']!.milliseconds, 2500);

          phone.favoriteIds.remove('desktop-favorite');
          phone.favoriteIds.add('phone-favorite');
          await phone.save();
          unavailable = true;
          await b.flush();
          expect(b.error, contains('database is unavailable (HTTP 503)'));
          expect(phone.favoriteIds, {'phone-favorite'});
          expect(b.document.dirty, isNotEmpty);
          unavailable = false;
          await b.flush();
          expect(b.error, isNull);
          await a.flush();
          expect(a.error, isNull);
          expect(desktop.favoriteIds, {'phone-favorite'});
          expect(desktop.playlists, phone.playlists);
          expect(desktop.listening.toJson(), phone.listening.toJson());
          expect(a.document.dirty, isEmpty);
          expect(b.document.dirty, isEmpty);
          final total = desktop.listening.milliseconds;
          final plays = desktop.listening.plays;
          desktop.favoriteIds.add('desktop-pending');
          desktop.playlists['Desktop mix'] = ['song-1'];
          desktop.playlists['Phone mix']!.add('song-2');
          desktop.listening.record(song(0), 9000, 1, desktopDay);
          await desktop.save();
          phone.favoriteIds.add('phone-pending');
          phone.playlists['Phone mix']!.add('song-3');
          phone.listening.record(song(0), 4000, 1, phoneDay);
          await phone.save();
          await b.uploadLocalChanges();

          final beforeMerge = client.requests.length;
          await a.restoreCloudCopy();
          expect(a.status, 'Cloud data merged with this device.');
          final requests = client.requests.skip(beforeMerge);
          expect(requests, isNotEmpty);
          for (final request in requests) {
            expect(request.uri.path, '/v1/sync');
            expect(jsonDecode(utf8.decode(request.bytes))['ops'], isEmpty);
          }
          expect(desktop.favoriteIds, {
            'phone-favorite',
            'desktop-pending',
            'phone-pending',
          });
          expect(desktop.playlists['Desktop mix'], ['song-1']);
          expect(
            desktop.playlists['Phone mix'],
            unorderedEquals(['song-0', 'song-2', 'song-3']),
          );
          expect(desktop.listening.milliseconds, total + 13000);
          expect(desktop.listening.plays, plays + 2);
          expect(a.document.dirty, isNotEmpty);

          final merged = desktop.toJson();
          await a.restoreCloudCopy();
          expect(desktop.toJson(), merged);
          await a.uploadLocalChanges();
          await b.uploadLocalChanges();
          expect(phone.toJson(), merged);
          expect(a.document.dirty, isEmpty);
          expect(b.document.dirty, isEmpty);

          final backup = DataBackup.create(desktop, phoneDay);
          expect(DataBackup.parse(backup.encode()).snapshot, merged);
        } finally {
          paused = true;
          await a.close();
          await b.close();
        }
      }, createHttpClient: (_) => client);
    },
  );

  final deploymentValues = SyncDeploymentConfig(
    worker: 'auralis-sync',
    account: 'a' * 32,
    cloudflareToken: 'cloudflare-token',
    database: 'libsql://music.aws-ap-south-1.turso.io',
    databaseToken: 'database-token',
    key: 'd' * 64,
    automatic: false,
  ).toJson();

  test('sync reports a Worker page that claims more without advancing its cursor', () async {
    var syncRequests = 0;
    final client = AccountClient()
      ..syncReply = (_, data) => Response(utf8.encode(jsonEncode({
        'cursor': data['cursor'],
        // Recover on a later request so a regression fails quickly.
        'more': ++syncRequests == 2,
        'records': <String, dynamic>{},
      })));
    await HttpOverrides.runZoned(() async {
      final settings = AccountSettings();
      var paused = false;
      final sync = SyncController(settings, AccountVault(), onApplied: () {}, paused: () => paused);
      try {
        await sync.connect('https://sync.example', 'd' * 64);
        expect(syncRequests, 2);
        expect(sync.error, contains('could not apply the sync data'));
        expect(sync.document.dirty, isNotEmpty);
        await sync.sync();
        expect(sync.error, isNull);
        expect(sync.document.dirty, isEmpty);
      } finally {
        paused = true;
        await sync.close();
      }
    }, createHttpClient: (_) => client);
  });

  test('an unclaimed Worker guides the user to owner registration', () async {
    final client = AccountClient()
      ..owner = true
      ..ownerCreated = false;
    await HttpOverrides.runZoned(() async {
      final sync = SyncController(
        AccountSettings(),
        AccountVault(),
        onApplied: () {},
        paused: () => true,
      );
      addTearDown(sync.close);
      const endpoint = 'https://sync.example';
      await expectLater(
        sync.signIn(endpoint, 'alice', 'test-password'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Create an account'),
          ),
        ),
      );
      expect(client.requests.single.uri.path, '/health');

      final code = await sync.signIn(
        endpoint,
        'alice',
        'test-password',
        register: true,
        claimKey: ' ${'d' * 64} ',
      );
      final registration = client.requests.singleWhere(
        (r) => r.uri.path == '/v1/auth/register',
      );
      expect(jsonDecode(utf8.decode(registration.bytes))['claimKey'], 'd' * 64);
      expect(sync.account?.admin, isTrue);
      expect(code, 'c' * 64);
    }, createHttpClient: (_) => client);
  });

  test('owner login, registration and recovery restore every deployment value on a fresh device', () async {
    for (final action in ['login', 'register', 'recover']) {
      final client = AccountClient()
        ..owner = true
        ..deployment = detached(deploymentValues);
      await HttpOverrides.runZoned(() async {
        final sync = SyncController(
          AccountSettings(),
          AccountVault(),
          onApplied: () {},
          paused: () => true,
          deploymentVault: AccountVault(),
        );
        try {
          if (action == 'recover') {
            await sync.recoverAccount(
              'https://sync.example',
              'alice',
              'c' * 64,
              'test-password',
            );
          } else {
            await sync.signIn(
              'https://sync.example',
              'alice',
              'test-password',
              register: action == 'register',
            );
          }
          final restored = await sync.deploymentProfile();
          for (final entry in deploymentValues.entries) {
            expect(
              restored[entry.key],
              entry.value,
              reason: '$action: ${entry.key}',
            );
          }
          expect(restored['url'], 'https://sync.example');
          expect(restored['version'], currentSyncWorkerVersion);
          expect(restored['ownerId'], 'a' * 32);
          expect(sync.deploymentError, isNull);
          while (sync.busy) {
            await Future<void>.delayed(Duration.zero);
          }
          await sync.signOut();
          final reads = client.requests
              .where((r) => r.uri.path == '/v1/account/deployment')
              .length;
          await sync.signIn('https://sync.example', 'bob', 'test-password');
          expect((await sync.deploymentProfile())['locked'], true);
          expect(
            (await sync.deploymentProfile()).containsKey('cloudflareToken'),
            false,
          );
          expect(
            client.requests.where(
              (r) => r.uri.path == '/v1/account/deployment',
            ),
            hasLength(reads),
          );
        } finally {
          await sync.close();
        }
      }, createHttpClient: (_) => client);
    }
  });

  test(
    'saved owner session restores missing deployment values on app startup',
    () async {
      final client = AccountClient()
        ..owner = true
        ..deployment = detached(deploymentValues);
      await HttpOverrides.runZoned(() async {
        final accounts = AccountVault(), deployment = AccountVault();
        SyncController controller() => SyncController(
          AccountSettings(),
          accounts,
          onApplied: () {},
          paused: () => true,
          deploymentVault: deployment,
        );
        final first = controller();
        await first.signIn('https://sync.example', 'alice', 'test-password');
        await first.close();
        deployment.data = {};
        final restarted = controller();
        try {
          await restarted.start();
          expect(restarted.account!.admin, true);
          final restored = await restarted.deploymentProfile();
          for (final entry in deploymentValues.entries) {
            expect(restored[entry.key], entry.value, reason: entry.key);
          }
          expect(restored['url'], 'https://sync.example');
        } finally {
          await restarted.close();
        }
      }, createHttpClient: (_) => client);
    },
  );

  test('owner login repairs a missing recovery copy from complete local credentials', () async {
    final client = AccountClient()..owner = true;
    await HttpOverrides.runZoned(() async {
      final sync = SyncController(
        AccountSettings(),
        AccountVault(),
        onApplied: () {},
        paused: () => true,
        deploymentVault: AccountVault()
          ..data = {...deploymentValues, 'url': 'https://sync.example'},
      );
      try {
        await sync.signIn('https://sync.example', 'alice', 'test-password');
        expect(client.deployment, deploymentValues);
        expect(
          client.requests.where(
            (r) => r.uri.path == '/v1/account/deployment' && r.method == 'PUT',
          ),
          hasLength(1),
        );
      } finally {
        await sync.close();
      }
    }, createHttpClient: (_) => client);
  });

  testWidgets(
    'deployed Worker URL fills Account & sync after returning without overwriting a draft on other updates',
    (tester) async {
      final sync = SyncController(
        AccountSettings(),
        AccountVault(),
        onApplied: () {},
        paused: () => true,
        deploymentVault: AccountVault(),
      );
      addTearDown(sync.close);
      await tester.pumpWidget(MaterialApp(home: SyncAccountPage(sync: sync)));
      final field = find.byKey(const ValueKey('sync-worker-url'));
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.tap(find.text('Deploy Database'));
      await tester.pumpAndSettle();
      await sync.rememberService(
        'https://auralis-sync.test-account.workers.dev',
      );
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, sync.serviceUrl);
      await tester.enterText(field, 'https://another-worker.example');
      await sync.saveDeploymentProfile({
        ...deploymentValues,
        'url': sync.serviceUrl,
      });
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'https://another-worker.example',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owner sign-in fills all Deploy Database fields from its recovery vault',
    (tester) async {
      final client = AccountClient()
        ..owner = true
        ..deployment = detached(deploymentValues);
      final sync = await tester.runAsync(
        () => HttpOverrides.runZoned(() async {
          final sync = SyncController(
            AccountSettings(),
            AccountVault(),
            onApplied: () {},
            paused: () => true,
            deploymentVault: AccountVault(),
          );
          await sync.signIn('https://sync.example', 'alice', 'test-password');
          while (sync.busy) {
            await Future<void>.delayed(Duration.zero);
          }
          return sync;
        }, createHttpClient: (_) => client),
      );
      addTearDown(sync!.close);
      await tester.pumpWidget(
        MaterialApp(home: SyncDeploymentPage(sync: sync)),
      );
      await tester.pumpAndSettle();
      for (final entry in deploymentValues.entries.where(
        (entry) => entry.key != 'automatic',
      )) {
        final field = find.byKey(ValueKey('deploy-${entry.key}'));
        expect(
          tester.widget<TextField>(field).controller!.text,
          entry.value,
          reason: entry.key,
        );
      }
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('live connections use each account controller HTTP transport', () async {
    for (final client in [AccountClient(), AccountClient()]) {
      await HttpOverrides.runZoned(() async {
        final sync = SyncController(
          AccountSettings(),
          AccountVault(),
          onApplied: () {},
          paused: () => true,
        );
        try {
          await sync.signIn('https://sync.example', 'alice', 'test-password');
          final live = client.requests.where((r) => r.uri.path == '/v1/live');
          expect(live, hasLength(1));
          expect(live.single.method, 'GET');
          expect(live.single.uri.scheme, 'https');
          expect(sync.account!.username, 'alice');
        } finally {
          await sync.close();
        }
      }, createHttpClient: (_) => client);
    }
  });

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
      final syncNow = find.text('Sync now');
      expect(syncNow.hitTestable(), findsOneWidget);
      expect(find.text('Merge cloud copy').hitTestable(), findsOneWidget);
      final firstSync = tester.getTopLeft(syncNow);
      final worker = find.text('Self-hosted Sync Worker');
      await tester.scrollUntilVisible(
        worker,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      final workerOffset = tester.getTopLeft(worker);
      if (size.width >= 820) {
        expect(workerOffset.dx, greaterThan(firstSync.dx));
      } else {
        expect(find.byType(SelectableText), findsOneWidget);
      }
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
