import 'dart:convert';
import 'dart:io';

import 'package:auralis/sync/controller.dart';
import 'package:auralis/sync/document.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_accounts_test.dart'
    show AccountClient, AccountSettings, AccountVault;
import 'updater_test.dart' show Response;

void main() {
  test('idle sync keeps live polling without reapplying data; remote edits still apply', () async {
    final client = AccountClient();
    var cursor = 0;
    final remote = <String, dynamic>{};
    client.syncReply = (_, body) {
      final sent = Map<String, dynamic>.from(body['ops'] as Map);
      final updates = {...sent, ...remote};
      remote.clear();
      if (updates.isNotEmpty) cursor++;
      return Response(
        utf8.encode(
          jsonEncode({
            'cursor': cursor,
            'more': false,
            'records': updates,
            'videoActivity': true,
          }),
        ),
      );
    };
    await HttpOverrides.runZoned(() async {
      final settings = AccountSettings();
      var applied = 0;
      final sync = SyncController(
        settings,
        AccountVault(),
        onApplied: () => applied++,
        paused: () => false,
      );
      try {
        await sync.signIn('https://sync.example', 'alice', 'test-password');
        await sync.flush();
        final priorApplications = applied, revision = sync.revision;
        final stats = settings.listening;
        final favorites = settings.favoriteIds;
        final requests = client.requests
            .where((r) => r.uri.path == '/v1/sync')
            .length;
        await sync.sync();
        expect(
          client.requests.where((r) => r.uri.path == '/v1/sync').length,
          requests + 1,
        );
        expect(applied, priorApplications);
        expect(sync.revision, revision);
        expect(settings.listening, same(stats));
        expect(settings.favoriteIds, same(favorites));
        remote[SyncDocument.key(['favorite', 'remote-song'])] = {
          'clock': 9999,
          'device': 'b' * 32,
          'value': true,
        };
        await sync.sync();
        expect(settings.favoriteIds, contains('remote-song'));
        expect(applied, priorApplications + 1);
        expect(sync.error, isNull);
      } finally {
        await sync.close();
      }
    }, createHttpClient: (_) => client);
  });
}
