import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/telegram_service.dart';

import 'fakes.dart';

void main() {
  test('build credentials initialize a fresh sign-in without user API input', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-build-auth-');
    addTearDown(() => dir.delete(recursive: true));
    final td = FakeTd(), vault = MemoryVault();
    final service = TelegramService(dir, vault, transport: td,
      applicationApiId: 12345,
      applicationApiHash: 'abcdef0123456789abcdef0123456789',
    );
    addTearDown(service.shutdown);
    expect(service.hasApplicationCredentials, isTrue);
    await service.start();
    expect(service.error, isNull);
    final parameters = td.requests.firstWhere((r) => r['@type'] == 'setTdlibParameters');
    expect(parameters['api_id'], 12345);
    expect(parameters['api_hash'], 'abcdef0123456789abcdef0123456789');
    expect(vault.data.keys.toSet(), {'apiId', 'apiHash', 'databaseKey'});
  });

  test('existing and restored sessions keep their API identity across build changes', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-saved-auth-');
    addTearDown(() => dir.delete(recursive: true));
    final td = FakeTd(), vault = MemoryVault();
    vault.data = {'apiId': 22222, 'apiHash': '11111111111111111111111111111111', 'databaseKey': 'saved-key'};
    final service = TelegramService(dir, vault, transport: td,
      applicationApiId: 12345,
      applicationApiHash: 'abcdef0123456789abcdef0123456789',
    );
    addTearDown(service.shutdown);
    await service.start();
    expect(service.error, isNull);
    final parameters = td.requests.firstWhere((r) => r['@type'] == 'setTdlibParameters');
    expect(parameters['api_id'], 22222);
    expect(parameters['api_hash'], '11111111111111111111111111111111');
    expect(parameters['database_encryption_key'], 'saved-key');
  });

  test('a fresh sign-in after logout reuses build credentials with a new native client', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-build-logout-');
    addTearDown(() => dir.delete(recursive: true));
    final first = FakeTd(), second = FakeTd(), vault = MemoryVault();
    final service = TelegramService(dir, vault, transport: first, createTransport: () => second,
      applicationApiId: 12345,
      applicationApiHash: 'abcdef0123456789abcdef0123456789',
    );
    addTearDown(service.shutdown);
    await service.start();
    final key = vault.data['databaseKey'];
    await service.logout();
    expect(vault.data.containsKey('apiId'), isFalse);
    first.auth('authorizationStateClosed');
    await Future<void>.delayed(Duration.zero);
    await service.start();
    expect(service.error, isNull);
    expect(second.requests.any((r) => r['@type'] == 'setTdlibParameters' && r['api_id'] == 12345), isTrue);
    expect(vault.data['databaseKey'], key);
  });

  test('auth drives phone, code and 2FA with encrypted database parameters; codes are not stored', () async {
    final dir = await Directory.systemTemp.createTemp('auralis-auth-');
    addTearDown(() => dir.delete(recursive: true));
    final td = FakeTd(), vault = MemoryVault();
    final service = TelegramService(dir, vault, transport: td);
    addTearDown(service.shutdown);
    await service.start(
      apiId: 12345,
      apiHash: 'abcdef0123456789abcdef0123456789',
    );
    final parameters = td.requests.firstWhere(
      (r) => r['@type'] == 'setTdlibParameters',
    );
    expect(parameters['database_encryption_key'], isNotEmpty);
    expect(parameters['use_secret_chats'], isFalse);
    td.auth('authorizationStateWaitPhoneNumber');
    await service.submit('+12025550123');
    expect(td.requests.last['@type'], 'setAuthenticationPhoneNumber');
    td.auth('authorizationStateWaitCode');
    await service.submit('12345');
    expect(td.requests.last, {
      '@type': 'checkAuthenticationCode',
      'code': '12345',
    });
    td.auth('authorizationStateWaitPassword');
    await service.submit('sample-password');
    expect(td.requests.last['@type'], 'checkAuthenticationPassword');
    expect(vault.data.keys.toSet(), {'apiId', 'apiHash', 'databaseKey'});
    td.auth('authorizationStateReady');
    await Future<void>.delayed(Duration.zero);
    expect(td.requests.where((r) => r['@type'] == 'loadChats').length, 2);
    td.events.add({
      '@type': 'updateNewChat',
      'chat': {
        'id': 1,
        'title': 'Music',
        'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
      },
    });
    expect(service.channels.single.title, 'Music');
    final page = await service.music(1, 'Music', documents: true, before: 123);
    expect(td.requests.last['filter']['@type'], 'searchMessagesFilterDocument');
    expect(td.requests.last['from_message_id'], 123);
    expect(page.nextMessageId, 777);
  });
  test(
    'only channels are listed, including after title and load-more updates',
    () async {
      final dir = await Directory.systemTemp.createTemp('auralis-channels-');
      addTearDown(() => dir.delete(recursive: true));
      final td = FakeTd();
      final service = TelegramService(dir, MemoryVault(), transport: td);
      addTearDown(service.shutdown);
      await service.start(
        apiId: 12345,
        apiHash: 'abcdef0123456789abcdef0123456789',
      );

      final types = <Json>[
        {'@type': 'chatTypePrivate', 'user_id': 1},
        {
          '@type': 'chatTypePrivate',
          'user_id': 2,
        }, // Bot conversations use this type too.
        {'@type': 'chatTypeBasicGroup', 'basic_group_id': 3},
        {'@type': 'chatTypeSupergroup', 'is_channel': false},
        {'@type': 'chatTypeSecret', 'secret_chat_id': 5},
        {'@type': 'chatTypeSupergroup'},
        {'@type': 'chatTypeSupergroup', 'is_channel': true},
      ];
      for (var i = 0; i < types.length; i++) {
        td.events.add({
          '@type': 'updateNewChat',
          'chat': {'id': i + 1, 'title': 'Chat ${i + 1}', 'type': types[i]},
        });
      }
      td.events.add({
        '@type': 'updateNewChat',
        'chat': {'id': 8, 'title': 'Unknown type'},
      });
      expect(service.channels.map((c) => c.id), [7]);
      for (var id = 1; id <= 9; id++) {
        td.events.add({
          '@type': 'updateChatTitle',
          'chat_id': id,
          'title': 'Renamed $id',
        });
      }
      expect(service.channels.single.id, 7);
      expect(service.channels.single.title, 'Renamed 7');

      await service.refreshChats();
      expect(
        td.requests
            .where((r) => r['@type'] == 'loadChats')
            .map((r) => r['chat_list']['@type']),
        ['chatListMain', 'chatListArchive'],
      );
      td.events.add({
        '@type': 'updateNewChat',
        'chat': {
          'id': 10,
          'title': 'Archived music',
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        },
      });
      td.events.add({
        '@type': 'updateNewChat',
        'chat': {
          'id': 11,
          'title': 'New group',
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': false},
        },
      });
      expect(service.channels.map((c) => c.id), [10, 7]);
      // A replacement without channel metadata must not keep an old entry visible.
      td.events.add({
        '@type': 'updateNewChat',
        'chat': {'id': 7, 'title': 'No longer a channel', 'type': types[0]},
      });
      td.events.add({
        '@type': 'updateChatTitle',
        'chat_id': 7,
        'title': 'Still hidden',
      });
      expect(service.channels.map((c) => c.id), [10]);
      await service.logout();
      expect(service.channels, isEmpty);
    },
  );
  test(
    'invalid credentials fail before any native client is started',
    () async {
      final td = FakeTd();
      final service = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: td,
      );
      addTearDown(service.shutdown);
      await service.start(apiId: -1, apiHash: 'invalid');
      expect(service.error, contains('API ID'));
      expect(td.requests, isEmpty);
    },
  );
}
