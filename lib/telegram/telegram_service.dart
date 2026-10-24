import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../account_backup.dart';
import '../lyrics.dart';
import '../storage.dart';
import 'td_transport.dart';
import 'embedded_cover.dart';

class TelegramService extends ChangeNotifier {
  TelegramService(
    this.directory,
    this.vault, {
    TdTransport? transport,
    TdTransport Function()? createTransport,
  }) : _createTransport = createTransport ?? TdTransport.new,
       _transport = transport ?? (createTransport ?? TdTransport.new)();
  final Directory directory;
  final SecretVault vault;
  TdTransport _transport;
  final TdTransport Function() _createTransport;
  bool _clientClosed = false;
  TdTransport get transport => _transport;
  // Resolve the current client even when the playback proxy keeps this tear-off.
  Future<Json> request(Json json) => _transport.request(json);
  StreamSubscription<Json>? _subscription;
  Json _secrets = {};
  String state = 'disconnected';
  String? error;
  bool busy = false;
  bool credentialRecoveryRequired = false;
  final Map<int, MusicChat> _channels = {};
  List<MusicChat> get channels => _channels.values.toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  bool get ready => state == 'authorizationStateReady';
  String connection = 'Offline';
  final Map<int, Future<String?>> _images = {};
  int _imageGeneration = 0;
  final Map<int, Future<Uint8List?>> _covers = {};
  final Set<int> _coverSuccess = {}, _coverDirty = {};
  final Map<int, int> _coverPending = {};
  int _coverJobs = 0;
  bool Function(int) isStreaming = (_) => false;

  void clearImageCache() {
    ++_imageGeneration;
    _images.clear();
    _covers.clear();
    _coverSuccess.clear();
    _coverDirty.clear();
  }

  Future<Uint8List?> cover(Track track) {
    final id = track.fileId;
    if (!ready || id == null) return Future.value(null);
    if (_covers[id] case final cached?) return cached;
    if (_coverJobs >= 2) return Future.value(null);
    if (_covers.length >= 64) {
      final first = _covers.keys.first;
      _covers.remove(first);
      _coverSuccess.remove(first);
      _coverDirty.remove(first);
    }
    ++_coverJobs;
    final generation = _imageGeneration;
    _coverPending[id] = generation;
    return _covers[id] = _loadCover(track, generation);
  }

  Future<Uint8List?> _loadCover(Track track, int generation) async {
    final id = track.fileId!;
    Uint8List? result;
    bool active() => ready && generation == _imageGeneration;
    try {
      if (track.coverFileId case final thumbnail?) {
        try {
          final path = await image(thumbnail);
          if (path != null && active()) {
            final file = File(path);
            if (await file.length() <= maxCoverBytes) {
              final bytes = await file.readAsBytes();
              if (isCoverImage(bytes)) result = bytes;
            }
          }
        } catch (_) {
          /* Try the original file's embedded picture. */
        }
      }
      if (result == null && track.size > 0 && active()) {
        result = await readEmbeddedCover(
          _metadataSource(id, generation),
          track.size,
        );
      }
      return active() ? result : null;
    } catch (_) {
      return null;
    } finally {
      --_coverJobs;
      if (_coverPending[id] == generation) _coverPending.remove(id);
      if (active()) {
        if (result != null) {
          _coverSuccess.add(id);
          _coverDirty.remove(id);
        } else if (_coverDirty.remove(id)) {
          _covers.remove(id);
        }
      }
      // A size-less cover can finish synchronously while Artwork is building.
      scheduleMicrotask(() {
        if (ready) notifyListeners();
      });
    }
  }

  CoverRange _metadataSource(int id, int generation) {
    bool active() => ready && generation == _imageGeneration;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    Future<Json> metadataRequest(Json request) {
      final remaining = deadline.difference(DateTime.now());
      if (!active() || remaining <= Duration.zero) {
        throw TimeoutException('Metadata timed out');
      }
      return transport.request(
        request,
        timeout: remaining > const Duration(seconds: 12)
            ? const Duration(seconds: 12)
            : remaining,
      );
    }

    return (offset, count) async {
      if (!active()) return null;
      var prefix = await metadataRequest({
        '@type': 'getFileDownloadedPrefixSize',
        'file_id': id,
        'offset': offset,
      });
      if (!active()) return null;
      if ((prefix['size'] as num? ?? 0) < count) {
        // TDLib has one download offset per file; never move a playing stream.
        if (isStreaming(id)) return null;
        await metadataRequest({
          '@type': 'downloadFile',
          'file_id': id,
          'priority': 1,
          'offset': offset,
          'limit': count,
          'synchronous': true,
        });
        if (!active()) return null;
        prefix = await metadataRequest({
          '@type': 'getFileDownloadedPrefixSize',
          'file_id': id,
          'offset': offset,
        });
        if ((prefix['size'] as num? ?? 0) < count) return null;
      }
      final bytes = BytesBuilder(copy: false);
      while (bytes.length < count && active()) {
        final length = min(128 * 1024, count - bytes.length);
        final part = await metadataRequest({
          '@type': 'readFilePart',
          'file_id': id,
          'offset': offset + bytes.length,
          'count': length,
        });
        final data = base64Decode(part['data'] as String);
        if (data.length != length) return null;
        bytes.add(data);
      }
      return active() ? bytes.takeBytes() : null;
    };
  }

  Future<Lyrics?> embeddedLyrics(Track track) async {
    final id = track.fileId, generation = _imageGeneration;
    if (!ready || id == null || track.size <= 0) return null;
    try {
      final text = await readEmbeddedLyrics(
        _metadataSource(id, generation),
        track.size,
      );
      if (text == null || !ready || generation != _imageGeneration) return null;
      final lyrics = Lyrics.parse(text, embedded: true);
      return lyrics.plain.isEmpty && lyrics.lines.isEmpty ? null : lyrics;
    } catch (_) {
      return null;
    }
  }

  Future<String?> image(int fileId) {
    if (!ready) return Future.value(null);
    if (_images[fileId] case final cached?) return cached;
    if (_images.length >= 128) _images.remove(_images.keys.first);
    return _images[fileId] = _downloadImage(fileId, _imageGeneration);
  }

  Future<String?> _downloadImage(int fileId, int generation) async {
    try {
      final result = await transport.request({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 1,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      }, timeout: const Duration(seconds: 20));
      final local = result['local'] as Json?;
      final path = local?['path'] as String?;
      if (local?['is_downloading_completed'] == true &&
          path != null &&
          path.isNotEmpty &&
          await File(path).exists() &&
          generation == _imageGeneration &&
          ready) {
        return path;
      }
    } catch (_) {
      // Artwork failure must not interrupt music playback or channel selection.
    }
    return null;
  }

  Future<void> start({int? apiId, String? apiHash}) async {
    await action(() async {
      if (state != 'disconnected') {
        throw StateError('Finish signing out before entering new API details.');
      }
      try {
        _secrets = await vault.read();
        credentialRecoveryRequired = false;
      } catch (_) {
        credentialRecoveryRequired = true;
        throw const FormatException(
          'Saved Telegram credentials cannot be unlocked on this device. Restore a password-protected account backup to recover your sign-in, or choose Sign in again to create a new local session.',
        );
      }
      if (apiId == null &&
          apiHash == null &&
          !_secrets.containsKey('apiId') &&
          !_secrets.containsKey('apiHash')) {
        state = 'disconnected';
        return;
      }
      if (apiId != null) _secrets['apiId'] = apiId;
      if (apiHash != null) _secrets['apiHash'] = apiHash;
      if ((_secrets['apiId'] as int? ?? 0) <= 0 ||
          !RegExp(r'^[a-fA-F0-9]{32}$')
              .hasMatch(_secrets['apiHash'] as String? ?? '')) {
        throw const FormatException(
          'Enter your Telegram API ID and 32-character API hash from my.telegram.org.',
        );
      }
      _secrets.putIfAbsent('databaseKey', SecretVault.newDatabaseKey);
      await vault.write(_secrets);
      await directory.create(recursive: true);
      await _subscription?.cancel();
      if (_clientClosed) {
        await _transport.close();
        _transport = _createTransport();
        _clientClosed = false;
        _parametersRequest = null;
      }
      _subscription = transport.updates.listen(_onUpdate);
      final native = Platform.isAndroid
          ? 'libtdjson.so'
          : p.join(
              p.dirname(Platform.resolvedExecutable),
              'native',
              'tdjson.dll',
            );
      try {
        await transport.start(native);
        state = 'connecting';
        final auth = await transport.request({
          '@type': 'getAuthorizationState',
        });
        await _onAuthorization(auth);
      } catch (_) {
        // A retry must create a fresh client, including after partial startup.
        try {
          await shutdown();
        } catch (_) {
          /* Preserve the original initialization error. */
        }
        rethrow;
      }
    });
  }

  void _onUpdate(Json json) {
    switch (json['@type']) {
      case 'updateAuthorizationState':
        unawaited(
          _onAuthorization(json['authorization_state'] as Json)
              .catchError((Object e) {
                error = e is FormatException ? e.message : 'Telegram initialization failed. Check your API credentials and network.';
                notifyListeners();
              }),
        );
      case 'updateNewChat':
        final chat = json['chat'] as Json;
        final id = chat['id'] as int;
        final channel = MusicChat.fromChat(chat);
        if (channel != null) {
          _channels[id] = channel;
        } else {
          _channels.remove(id);
        }
        notifyListeners();
      case 'updateChatTitle':
        final id = json['chat_id'] as int;
        if (_channels.containsKey(id)) {
          _channels[id] = MusicChat(
            id,
            json['title'] as String,
            photoFileId: _channels[id]!.photoFileId,
            photoPreview: _channels[id]!.photoPreview,
          );
          notifyListeners();
        }
      case 'updateChatPhoto':
        final id = json['chat_id'] as int;
        if (_channels[id] case final channel?) {
          _channels[id] = MusicChat(
            id,
            channel.title,
            photoFileId: json['photo']?['small']?['id'] as int?,
            photoPreview: decodePreview(
              json['photo']?['minithumbnail']?['data'],
            ),
          );
          notifyListeners();
        }
      case 'updateConnectionState':
        connection = switch (json['state']?['@type']) {
          'connectionStateReady' => 'Connected',
          'connectionStateUpdating' => 'Syncing',
          'connectionStateWaitingForNetwork' => 'Waiting for network',
          _ => 'Connecting',
        };
        notifyListeners();
      case 'updateFile':
        final id = (json['file'] as Json)['id'] as int;
        if (_covers.containsKey(id) && !_coverSuccess.contains(id)) {
          if (_coverPending[id] == _imageGeneration) {
            _coverDirty.add(id);
          } else {
            _covers.remove(id);
            notifyListeners();
          }
        }
    }
  }

  Future<Json>? _parametersRequest;
  Future<void> _onAuthorization(Json auth) async {
    state = auth['@type'] as String;
    if (state == 'authorizationStateClosed') {
      _clientClosed = true;
      _parametersRequest = null;
      connection = 'Offline';
      _channels.clear();
      state = 'disconnected';
    }
    if (!ready) {
      clearImageCache();
      if (state == 'authorizationStateLoggingOut' ||
          state == 'authorizationStateClosed') {
        _channels.clear();
      }
    }
    error = null;
    notifyListeners();
    if (state == 'authorizationStateWaitTdlibParameters') {
      try {
        // The update and getAuthorizationState response can arrive together.
        // Both callers must await the same initialization result.
        await (_parametersRequest ??= transport.request({
          '@type': 'setTdlibParameters',
          'use_test_dc': false,
          'database_directory': p.join(directory.path, 'database'),
          'files_directory': p.join(directory.path, 'cache'),
          'database_encryption_key': _secrets['databaseKey'],
          'use_file_database': true,
          'use_chat_info_database': true,
          'use_message_database': true,
          'use_secret_chats': false,
          'api_id': _secrets['apiId'],
          'api_hash': _secrets['apiHash'],
          'system_language_code': 'en',
          'device_model': Platform.isAndroid
              ? 'Auralis Android'
              : 'Auralis Windows x64',
          'system_version': Platform.operatingSystem,
          'application_version': '0.1.63',
        }));
      } on TdException catch (e) {
        throw FormatException(
          'Telegram could not open the saved session (TDLib ${e.code}). Restore a valid account backup or retry connecting.',
        );
      }
    } else if (ready) {
      await refreshChats();
    }
  }

  Future<void> submit(String value) => action(() async {
    final request = switch (state) {
      'authorizationStateWaitPhoneNumber' => {
        '@type': 'setAuthenticationPhoneNumber',
        'phone_number': value.trim(),
      },
      'authorizationStateWaitCode' => {
        '@type': 'checkAuthenticationCode',
        'code': value.trim(),
      },
      'authorizationStateWaitPassword' => {
        '@type': 'checkAuthenticationPassword',
        'password': value,
      },
      'authorizationStateWaitEmailAddress' => {
        '@type': 'setAuthenticationEmailAddress',
        'email_address': value.trim(),
      },
      'authorizationStateWaitEmailCode' => {
        '@type': 'checkAuthenticationEmailCode',
        'code': {
          '@type': 'emailAddressAuthenticationCode',
          'code': value.trim(),
        },
      },
      _ => throw StateError(
        'Complete this sign-in step in the official Telegram application.',
      ),
    };
    if (value.isEmpty) {
      throw const FormatException('Enter a value to continue.');
    }
    await transport.request(request);
  });

  Future<void> refreshChats() async {
    for (final type in ['chatListMain', 'chatListArchive']) {
      try {
        await transport.request({
          '@type': 'loadChats',
          'chat_list': {'@type': type},
          'limit': 100,
        });
      } on TdException catch (e) {
        if (e.code != 404) rethrow;
      }
    }
  }

  Future<MusicChat?> channel(int id) async {
    if (_channels[id] case final known?) return known;
    final client = transport;
    final channel = MusicChat.fromChat(
      await client.request({'@type': 'getChat', 'chat_id': id}),
    );
    if (!identical(client, transport) || !ready) return null;
    if (channel != null) {
      _channels[id] = channel;
      notifyListeners();
    }
    return channel;
  }

  Future<({List<Track> tracks, int nextMessageId})> music(
    int chatId,
    String title, {
    int before = 0,
    bool documents = false,
  }) async {
    final result = await transport.request({
      '@type': 'searchChatMessages',
      'chat_id': chatId,
      'topic_id': null,
      'query': '',
      'sender_id': null,
      'from_message_id': before,
      'offset': 0,
      'limit': 100,
      'filter': {
        '@type': documents
            ? 'searchMessagesFilterDocument'
            : 'searchMessagesFilterAudio',
      },
    });
    return (
      tracks: (result['messages'] as List)
          .map((m) => Track.fromMessage(m as Json, title))
          .whereType<Track>()
          .toList(),
      nextMessageId: (result['next_from_message_id'] as int?) ?? 0,
    );
  }

  Future<TelegramAccount> backupAccount() async {
    if (!ready || busy) {
      throw const FormatException(
        'Connect Telegram before backing up the account.',
      );
    }
    busy = true;
    notifyListeners();
    try {
      await shutdown(); // close must finish successfully before reading the database.
      _clientClosed = true;
      return await TelegramAccount.capture(
        Directory(p.join(directory.path, 'database')),
        {
          for (final key in ['apiId', 'apiHash', 'databaseKey'])
            key: _secrets[key],
        },
      );
    } finally {
      busy = false;
      await start();
    }
  }

  Future<void> restoreAccount(
    TelegramAccount account,
    Future<void> Function() restoreData,
  ) async {
    // Validate all paths and credentials before closing the current account.
    final checked = TelegramAccount.fromJson(account.toJson());
    if (busy) {
      throw const FormatException(
        'Wait for Telegram to finish its current operation.',
      );
    }
    await directory.create(recursive: true);
    final stage = await directory.createTemp('restore-');
    final database = Directory(p.join(directory.path, 'database'));
    final old = Directory(p.join(stage.path, 'previous'));
    final incoming = Directory(p.join(stage.path, 'incoming'));
    final previousVault = File(p.join(stage.path, 'previous-vault'));
    var savedVault = false;
    var moved = false, installed = false, safeToRestart = true;
    busy = true;
    notifyListeners();
    try {
      await checked.write(incoming);
      // A device-protected recovery copy remains if a filesystem rollback fails.
      if (await vault.file.exists()) {
        await vault.file.copy(previousVault.path);
        savedVault = true;
      }
      await shutdown();
      _clientClosed = true;
      if (await database.exists()) {
        await database.rename(old.path);
        moved = true;
      }
      safeToRestart = false;
      await incoming.rename(database.path);
      installed = true;
      // A confirmed portable restore can replace an unusable device key.
      // Keep healthy keys, and retain the previous vault bytes for rollback.
      if (credentialRecoveryRequired) await vault.resetProtection();
      await vault.write(checked.credentials);
      await restoreData();
      safeToRestart = true;
      _channels.clear();
    } catch (_) {
      if (installed) await database.delete(recursive: true);
      if (moved) await old.rename(database.path);
      // Roll back the original protected bytes. Reading them would prevent
      // recovery when this device cannot decrypt a stale/imported vault.
      if (savedVault) {
        await atomicWrite(vault.file, await previousVault.readAsBytes());
      } else if (installed && await vault.file.exists()) {
        await vault.file.delete();
      }
      safeToRestart = true;
      rethrow;
    } finally {
      // Only this operation's staging folder is removed, never caches/music.
      // Preserve a failed rollback's previous database for manual recovery.
      if (safeToRestart) {
        try {
          await stage.delete(recursive: true);
        } on FileSystemException {
          /* Retry cleanup later. */
        }
      }
      busy = false;
      if (safeToRestart && _clientClosed) await start();
      notifyListeners();
    }
  }

  /// Explicit recovery only: keep unreadable files, then start a new sign-in.
  Future<void> recoverLocalSession() => action(() async {
    if (!credentialRecoveryRequired || state != 'disconnected') {
      throw StateError(
        'A fresh sign-in is only available for an unreadable local session.',
      );
    }
    await shutdown();
    await directory.create(recursive: true);
    final recovery = await directory.createTemp('unreadable-session-');
    final database = Directory(p.join(directory.path, 'database'));
    final savedDatabase = Directory(p.join(recovery.path, 'database'));
    final savedVault = File(p.join(recovery.path, 'credentials.protected'));
    var movedDatabase = false, movedVault = false;
    try {
      if (await database.exists()) {
        await database.rename(savedDatabase.path);
        movedDatabase = true;
      }
      if (await vault.file.exists()) {
        await vault.file.rename(savedVault.path);
        movedVault = true;
      }
      await vault.resetProtection();
    } catch (_) {
      if (movedVault) await savedVault.rename(vault.file.path);
      if (movedDatabase) await savedDatabase.rename(database.path);
      rethrow;
    }
    _secrets = {};
    _channels.clear();
    clearImageCache();
    credentialRecoveryRequired = false;
    state = 'disconnected';
    connection = 'Offline';
  });

  Future<void> logout() => action(() async {
    await transport.request({'@type': 'logOut'});
    state = _clientClosed ? 'disconnected' : 'authorizationStateLoggingOut';
    connection = _clientClosed ? 'Offline' : 'Signing out';
    _channels.clear();
    clearImageCache();
    _secrets = {..._secrets}
      ..remove('apiId')
      ..remove('apiHash');
    try {
      // Keep the database key until TDLib finishes closing its encrypted store.
      await vault.write(_secrets);
    } catch (_) {
      throw StateError(
        'Signed out, but saved API details could not be cleared. Enter your API ID and hash again before connecting.',
      );
    }
  });

  Future<void> action(Future<void> Function() operation) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await operation();
    } catch (e) {
      error = e is FormatException
          ? e.message
          : e is TdException
          ? 'Telegram rejected the request (${e.code}). Check the value and try again; Telegram may require a wait.'
          : e is TimeoutException
          ? 'Telegram did not respond in time. Check your connection and retry.'
          : e is StateError
          ? e.message.toString()
          : 'Could not connect. Check the installed native libraries, credentials, and network.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> shutdown() async {
    state = 'disconnected';
    clearImageCache();
    await _subscription?.cancel();
    try {
      await transport.close();
    } finally {
      _clientClosed = true;
      _parametersRequest = null;
      connection = 'Offline';
      notifyListeners();
    }
  }
}
