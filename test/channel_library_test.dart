import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/models.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/channel_library.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/telegram_service.dart';

import 'fakes.dart';

Json message(
  int channel,
  int id, {
  String name = 'song.mp3',
  bool document = false,
}) => {
  'id': id,
  'chat_id': channel,
  'content': document
      ? {
          '@type': 'messageDocument',
          'document': {
            'file_name': name,
            'document': {'id': id, 'size': 100},
          },
        }
      : {
          '@type': 'messageAudio',
          'audio': {
            'title': 'Song $id',
            'file_name': name,
            'audio': {'id': id, 'size': 100},
          },
        },
};

void main() {
  late Directory dir;
  late FakeTd td;
  late TelegramService telegram;
  late AppSettings settings;
  late ChannelLibrary library;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auralis-library-');
    td = FakeTd();
    td.onRequest = (request) async {
      if (request['@type'] == 'getChat') {
        final id = request['chat_id'];
        return {
          'id': id,
          'title': 'Channel $id',
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        };
      }
      if (request['@type'] == 'searchChatMessages') {
        return {'messages': [], 'next_from_message_id': 0};
      }
      return null;
    };
    telegram = TelegramService(dir, MemoryVault(), transport: td);
    await telegram.start(
      apiId: 12345,
      apiHash: 'abcdef0123456789abcdef0123456789',
    );
    telegram.state = 'authorizationStateReady';
    settings = AppSettings(File('${dir.path}/settings.json'));
    library = ChannelLibrary(telegram, settings);
  });
  tearDown(() async {
    library.dispose();
    await telegram.shutdown();
    await dir.delete(recursive: true);
  });

  test('selected channels combine every audio/document page, deduplicate and persist', () async {
    final fallback = td.onRequest!;
    td.onRequest = (r) async {
      if (r['@type'] != 'searchChatMessages') return fallback(r);
      final id = r['chat_id'] as int;
      final before = r['from_message_id'];
      if (r['filter']['@type'] == 'searchMessagesFilterAudio') {
        return before == 0
            ? {
                'messages': [message(id, 30)],
                'next_from_message_id': 20,
              }
            : {
                'messages': [message(id, 30), message(id, 10)],
                'next_from_message_id': 0,
              };
      }
      // A page containing no audio still has an older document page to fetch.
      return before == 0
          ? {
              'messages': [message(id, 8, name: 'notes.pdf', document: true)],
              'next_from_message_id': 7,
            }
          : {
              'messages': [message(id, 6, name: 'album.FLAC', document: true)],
              'next_from_message_id': 0,
            };
    };
    await library.select(const MusicChat(-1, 'One'), true);
    await library.select(const MusicChat(-2, 'Two'), true);
    expect(library.tracks.map((t) => t.id), [
      '-1:30',
      '-1:10',
      '-1:6',
      '-2:30',
      '-2:10',
      '-2:6',
    ]);
    expect(library.tracks.last.source, 'Channel -2');
    expect(library.loading, isFalse);
    expect(library.error, isNull);
    final restored = AppSettings(settings.file);
    await restored.load();
    expect(restored.selectedChannels.map((c) => c.id), [-1, -2]);
    await library.select(const MusicChat(-1, 'One'), false);
    expect(library.tracks.every((t) => t.id.startsWith('-2:')), isTrue);
    expect(library.tracks.length, 3);
  });

  test(
    'deselection cancels a pending response and cannot resurrect removed music',
    () async {
      final pending = Completer<Json>();
      final started = Completer<void>();
      final fallback = td.onRequest!;
      td.onRequest = (r) async {
        if (r['@type'] == 'searchChatMessages') {
          if (!started.isCompleted) started.complete();
          return pending.future;
        }
        return fallback(r);
      };
      final first = library.select(const MusicChat(-1, 'One'), true);
      await started.future;
      await library.select(const MusicChat(-1, 'One'), false);
      pending.complete({
        'messages': [message(-1, 1)],
        'next_from_message_id': 99,
      });
      await first;
      expect(library.tracks, isEmpty);
      expect(settings.selectedChannels, isEmpty);
      expect(library.loading, isFalse);
      expect(
        td.requests.where((r) => r['@type'] == 'searchChatMessages'),
        hasLength(1),
      );
    },
  );

  test('an inaccessible saved channel does not stop other channels or bypass the channel filter', () async {
    final fallback = td.onRequest!;
    td.onRequest = (r) async {
      if (r['@type'] == 'getChat' && r['chat_id'] == -1) {
        return {
          'id': -1,
          'title': 'Private',
          'type': {'@type': 'chatTypePrivate'},
        };
      }
      if (r['@type'] == 'searchChatMessages' &&
          r['filter']['@type'] == 'searchMessagesFilterAudio') {
        return {
          'messages': [message(-2, 3)],
          'next_from_message_id': 0,
        };
      }
      return fallback(r);
    };
    settings.selectedChannels = [
      const MusicChat(-1, 'Old'),
      const MusicChat(-2, 'Two'),
    ];
    await library.refresh();
    expect(library.tracks.single.id, '-2:3');
    expect(library.error, contains('Old'));
    expect(
      td.requests.any(
        (r) => r['@type'] == 'searchChatMessages' && r['chat_id'] == -1,
      ),
      isFalse,
    );
  });

  test(
    'a repeated cursor stops with a partial error and Refresh can recover',
    () async {
      final fallback = td.onRequest!;
      td.onRequest = (r) async {
        if (r['@type'] == 'searchChatMessages') {
          return {
            'messages': [message(-1, 1)],
            'next_from_message_id': 5,
          };
        }
        return fallback(r);
      };
      await library.select(const MusicChat(-1, 'One'), true);
      expect(library.tracks, hasLength(1));
      expect(library.error, contains('Could not load all music'));
      expect(library.loading, isFalse);
      td.onRequest = fallback;
      await library.refresh();
      expect(library.error, isNull);
    },
  );

  test(
    'a failed selection save rolls back without making music requests',
    () async {
      await Directory(settings.file.path).create();
      await library.select(const MusicChat(-1, 'One'), true);
      expect(settings.selectedChannels, isEmpty);
      expect(library.error, contains('Could not save'));
      expect(library.saving, isFalse);
      expect(
        td.requests.any((r) => r['@type'] == 'searchChatMessages'),
        isFalse,
      );
    },
  );

  test('sign-out invalidates pending music responses', () async {
    final pending = Completer<Json>();
    final started = Completer<void>();
    final fallback = td.onRequest!;
    td.onRequest = (r) async {
      if (r['@type'] == 'searchChatMessages') {
        started.complete();
        return pending.future;
      }
      return fallback(r);
    };
    final first = library.select(const MusicChat(-1, 'One'), true);
    await started.future;
    td.auth('authorizationStateLoggingOut');
    expect(library.tracks, isEmpty);
    expect(library.loading, isFalse);
    pending.complete({
      'messages': [message(-1, 1)],
      'next_from_message_id': 0,
    });
    await first;
    expect(library.tracks, isEmpty);
    expect(settings.selectedChannels.single.id, -1);
  });

  test(
    'saved selection automatically reloads music on a new Library instance',
    () async {
      await library.select(const MusicChat(-1, 'One'), true);
      final restored = AppSettings(settings.file);
      await restored.load();
      final fallback = td.onRequest!;
      td.onRequest = (r) async {
        if (r['@type'] == 'searchChatMessages') {
          return {
            'messages': [message(-1, 9)],
            'next_from_message_id': 0,
          };
        }
        return fallback(r);
      };
      final reloaded = ChannelLibrary(telegram, restored);
      addTearDown(reloaded.dispose);
      final complete = Completer<void>();
      reloaded.addListener(() {
        if (!reloaded.loading && !complete.isCompleted) complete.complete();
      });
      await complete.future.timeout(const Duration(seconds: 2));
      expect(reloaded.tracks.single.id, '-1:9');
      expect(reloaded.error, isNull);
    },
  );

  test('disposing a Library ignores late results without notifying disposed listeners', () async {
    final pending = Completer<Json>();
    final started = Completer<void>();
    final fallback = td.onRequest!;
    td.onRequest = (r) async {
      if (r['@type'] == 'searchChatMessages') {
        started.complete();
        return pending.future;
      }
      return fallback(r);
    };
    final other = ChannelLibrary(telegram, MemorySettings());
    final request = other.select(const MusicChat(-1, 'One'), true);
    await started.future;
    other.dispose();
    pending.complete({
      'messages': [message(-1, 1)],
      'next_from_message_id': 0,
    });
    await request;
    expect(other.tracks, isEmpty);
  });
}
