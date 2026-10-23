import 'dart:convert';
import 'dart:io';

import 'package:auralis/account_backup.dart';
import 'package:auralis/data_backup.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final credentials = <String, dynamic>{
  'apiId': 12345,
  'apiHash': 'abcdef0123456789abcdef0123456789',
  'databaseKey': base64Encode(List.filled(32, 7)),
};
TelegramAccount account([String contents = 'encrypted TDLib fixture']) =>
    TelegramAccount.fromJson({
      'credentials': credentials,
      'files': {
        'td.binlog': base64Encode(utf8.encode(contents)),
        'nested/td.sqlite': base64Encode([1, 2, 3]),
      },
    });

class SnapshotTd extends FakeTd {
  SnapshotTd(this.onClose);
  final Future<void> Function() onClose;
  @override
  Future<void> close() async {
    await onClose();
    await super.close();
  }
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auralis-account-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('encrypted portable account round trip rejects wrong password and tampering', () async {
    final data = DataBackup.create(
      AppSettings(File('${dir.path}/settings.json')),
      DateTime.utc(2026),
    );
    final bundle = AccountBackup(data, account());
    final text = await encryptAccountBackup(
      bundle.data,
      bundle.account!,
      'a strong backup password',
    );
    expect(text, isNot(contains(credentials['apiHash'])));
    expect(text, isNot(contains('td.binlog')));
    final restored = await decryptAccountBackup(
      text,
      'a strong backup password',
    );
    expect(restored.account!.credentials, credentials);
    expect(restored.account!.files, account().files);
    expect(restored.data.snapshot, data.snapshot);
    await expectLater(
      AccountBackup.decrypt(text, 'incorrect password'),
      throwsFormatException,
    );
    final damaged = jsonDecode(text) as Map<String, dynamic>;
    final bytes = base64Decode(damaged['box'] as String);
    bytes[15] ^= 1;
    damaged['box'] = base64Encode(bytes);
    await expectLater(
      AccountBackup.decrypt(jsonEncode(damaged), 'a strong backup password'),
      throwsFormatException,
    );
    expect(DataBackup.parse(data.encode()).snapshot, data.snapshot);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('account rejects traversal, Windows device names, collisions and invalid credentials', () {
    for (final path in [
      '../credentials.dpapi',
      '/td.binlog',
      r'C:\td.binlog',
      'nested/../../escape',
      'NUL',
      'td.binlog.',
    ]) {
      expect(
        () => TelegramAccount.fromJson({
          'credentials': credentials,
          'files': {path: 'AQ=='},
        }),
        throwsFormatException,
      );
    }
    expect(
      () => TelegramAccount.fromJson({
        'credentials': credentials,
        'files': {'TD.binlog': 'AQ==', 'td.binlog': 'Ag=='},
      }),
      throwsFormatException,
    );
    expect(
      () => TelegramAccount.fromJson({
        'credentials': {...credentials, 'databaseKey': 'AQ=='},
        'files': {'td.binlog': 'AQ=='},
      }),
      throwsFormatException,
    );
  });

  test(
    'snapshot waits for database close and reconnects without logging out',
    () async {
      final db = Directory('${dir.path}/database');
      await db.create();
      final file = File('${db.path}/td.binlog');
      await file.writeAsString('before flush');
      final td = SnapshotTd(() => file.writeAsString('after flush'));
      final next = FakeTd();
      final vault = MemoryVault()..data = {...credentials};
      final service = TelegramService(
        dir,
        vault,
        transport: td,
        createTransport: () => next,
      );
      await service.start();
      td.auth('authorizationStateReady');
      await Future<void>.delayed(Duration.zero);
      final snapshot = await service.backupAccount();
      expect(
        utf8.decode(base64Decode(snapshot.files['td.binlog']!)),
        'after flush',
      );
      expect(vault.data, credentials);
      expect(td.requests.any((r) => r['@type'] == 'logOut'), isFalse);
      expect(
        next.requests.any((r) => r['@type'] == 'setTdlibParameters'),
        isTrue,
      );
      await service.shutdown();
    },
  );

  test('restore re-protects portable credentials and rolls database back on failure', () async {
    for (final fail in [true, false]) {
      final root = Directory('${dir.path}/$fail');
      await root.create();
      final db = Directory('${root.path}/database');
      await db.create();
      await File('${db.path}/td.binlog').writeAsString('previous database');
      final cache = File('${root.path}/cache/keep.mp3');
      await cache.parent.create();
      await cache.writeAsString('keep music');
      final oldCredentials = {...credentials, 'apiId': 98765};
      final vault = MemoryVault()..data = oldCredentials;
      final next = FakeTd();
      final service = TelegramService(
        root,
        vault,
        transport: FakeTd(),
        createTransport: () => next,
      );
      await service.start();
      Future<void> restore() =>
          service.restoreAccount(account('new database'), () async {
            expect(vault.data, credentials);
            if (fail) throw const FileSystemException('settings disk failure');
          });
      if (fail) {
        await expectLater(restore(), throwsA(isA<FileSystemException>()));
      } else {
        await restore();
      }
      expect(
        await File('${db.path}/td.binlog').readAsString(),
        fail ? 'previous database' : 'new database',
      );
      expect(vault.data, fail ? oldCredentials : credentials);
      expect(await cache.readAsString(), 'keep music');
      expect(service.busy, isFalse);
      expect(
        await root.list().any(
          (entry) => entry.path.split('/').last.startsWith('restore-'),
        ),
        isFalse,
      );
      await service.shutdown();
    }
  });
}
