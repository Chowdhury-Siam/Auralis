import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../media_cache.dart';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../account_backup.dart';
import '../lyrics.dart';
import '../storage.dart';
import 'td_transport.dart';
import 'embedded_cover.dart';
import 'phone_login.dart';

class TelegramService extends ChangeNotifier {
  TelegramService(
    this.directory,
    this.vault, {
    TdTransport? transport,
    TdTransport Function()? createTransport,
    this.applicationApiId = const int.fromEnvironment('TELEGRAM_API_ID'),
    this.applicationApiHash = const String.fromEnvironment('TELEGRAM_API_HASH'),
  }) : _createTransport = createTransport ?? TdTransport.new,
       _transport = transport ?? (createTransport ?? TdTransport.new)();
  final Directory directory;
  final SecretVault vault;
  MediaCache get mediaCache {
    final key = _secrets['databaseKey'];
    return MediaCache(
      key is String && key.isNotEmpty
          ? Directory(
              p.join(
                directory.path,
                'media-cache',
                sha256.convert(utf8.encode(key)).toString(),
              ),
            )
          : null,
    );
  }

  final int applicationApiId;
  final String applicationApiHash;
  bool get hasApplicationCredentials =>
      applicationApiId > 0 &&
      RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(applicationApiHash);
  TdTransport _transport;
  final TdTransport Function() _createTransport;
  bool _clientClosed = false;
  TdTransport get transport => _transport;
  // Resolve the current client even when the playback proxy keeps this tear-off.
  Future<Json> request(Json json) async {
    if (json['@type'] == 'downloadFile' && json['priority'] == 32) {
      // Metadata cleanup or startup migration may still own this disk file.
      await _audioSweep;
      await _audioDeletes[json['file_id']];
    }
    return _transport.request(json);
  }

  StreamSubscription<Json>? _subscription;
  Json _secrets = {};
  String state = 'disconnected';
  String? error;
  String? authenticationPhoneNumber;
  String? authenticationLink;
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
  final Map<int, Uint8List> _coverBytes = {};
  Uint8List? cachedCover(Track track) =>
      ready ? _coverBytes[track.fileId] : null;
  final Set<int> _coverSuccess = {}, _coverDirty = {};
  final Map<int, int> _coverPending = {};
  int _coverJobs = 0;
  bool Function(int) isStreaming = (_) => false;
  bool Function() hasActiveStream = () => false;
  Future<void>? _audioSweep;
  final Map<int, int> _metadataUsers = {};
  final Map<int, Future<void>> _audioDeletes = {};

  Future<void> _purgeOldAudio() async {
    try {
      await transport.request({
        '@type': 'optimizeStorage',
        'size': 0,
        'ttl': 0,
        'count': 0,
        'immunity_delay': 0,
        'file_types': [
          {'@type': 'fileTypeAudio'},
          {'@type': 'fileTypeDocument'},
        ],
        'chat_ids': <int>[],
        'exclude_chat_ids': <int>[],
        'return_deleted_file_statistics': false,
        'chat_limit': 0,
      });
    } catch (_) {
      // Offline cleanup must not prevent sign-in or streaming. Retry next login.
    }
  }

  /// Removes only the local audio copy; Telegram messages and images stay intact.
  Future<void> releaseAudio(int fileId) async {
    if (!ready || isStreaming(fileId) || _metadataUsers.containsKey(fileId)) {
      return;
    }
    if (_audioDeletes[fileId] case final pending?) return pending;
    final client = transport;
    final cleanup = () async {
      try {
        await client.request({
          '@type': 'cancelDownloadFile',
          'file_id': fileId,
          'only_if_pending': false,
        });
      } catch (_) {
        /* The download may already have ended. Still try to delete its copy. */
      }
      if (isStreaming(fileId) || _metadataUsers.containsKey(fileId)) return;
      try {
        await client.request({'@type': 'deleteFile', 'file_id': fileId});
      } catch (_) {
        /* A reconnect will sweep any leftover audio files. */
      }
    }();
    _audioDeletes[fileId] = cleanup;
    try {
      await cleanup;
    } finally {
      if (identical(_audioDeletes[fileId], cleanup)) {
        _audioDeletes.remove(fileId);
      }
    }
  }

  Future<T?> _withAudioMetadata<T>(
    int fileId,
    int generation,
    Future<T?> Function(CoverRange source) read,
  ) async {
    final client = transport;
    _metadataUsers.update(fileId, (count) => count + 1, ifAbsent: () => 1);
    try {
      await _audioSweep;
      await _audioDeletes[fileId];
      if (!ready || generation != _imageGeneration) return null;
      return await read(_metadataSource(fileId, generation));
    } finally {
      final remaining = _metadataUsers[fileId]! - 1;
      if (remaining == 0) {
        _metadataUsers.remove(fileId);
      } else {
        _metadataUsers[fileId] = remaining;
      }
      if (identical(client, transport)) {
        await releaseAudio(fileId);
      }
    }
  }

  void clearImageCache() {
    ++_imageGeneration;
    _images.clear();
    _covers.clear();
    _coverBytes.clear();
    _coverSuccess.clear();
    _coverDirty.clear();
  }

  Future<bool> _validCover(Uint8List bytes) async {
    if (!isCoverImage(bytes)) return false;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (descriptor.width <= 0 ||
              descriptor.height <= 0 ||
              descriptor.width * descriptor.height > 16777216) {
            return false;
          }
          final codec = await descriptor.instantiateCodec(
            targetWidth: min(640, descriptor.width),
          );
          try {
            final frame = await codec.getNextFrame();
            frame.image.dispose();
            return true;
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> _savedCover(Track track, MediaCache disk) async {
    final bytes = await disk.read(track, 'art', maxCoverBytes);
    return bytes != null && await _validCover(bytes) ? bytes : null;
  }

  Future<bool> hasCachedCover(Track track) async {
    if (!ready) return false;
    final disk = mediaCache, generation = _imageGeneration;
    final saved = await _savedCover(track, disk);
    return ready &&
        generation == _imageGeneration &&
        mediaCache.directory?.path == disk.directory?.path &&
        saved != null;
  }

  Future<Uint8List?> savedCover(
    Track track, {
    required bool Function() active,
  }) async {
    if (!ready || !active() || track.fileId == null) return null;
    final disk = mediaCache, generation = _imageGeneration;
    bool current() =>
        ready &&
        active() &&
        generation == _imageGeneration &&
        mediaCache.directory?.path == disk.directory?.path;
    // Explicit warming must see disk entries added after a prior clean miss.
    final saved = await _savedCover(track, disk);
    if (saved != null && current()) {
      if (track.fileId case final id?) {
        _covers.remove(id);
        _trimCovers();
        _covers[id] = Future.value(saved);
        _coverBytes[id] = saved;
        _coverSuccess.add(id);
        _coverDirty.remove(id);
      }
      return saved;
    }
    return null;
  }

  Future<Uint8List?> cacheCover(
    Track track, {
    required bool Function() active,
  }) async {
    if (!ready || !active()) return null;
    final disk = mediaCache, generation = _imageGeneration;
    bool current() =>
        ready &&
        active() &&
        generation == _imageGeneration &&
        mediaCache.directory?.path == disk.directory?.path;
    final saved = await savedCover(track, active: active);
    if (saved != null) return saved;
    if (!current()) return null;
    if (track.fileId case final id?) {
      if (!_coverSuccess.contains(id) && !_coverPending.containsKey(id)) {
        _covers.remove(id);
      }
    }
    final bytes = await cover(track);
    // Aliases of one Telegram file need their own key, but never rewrite saved art.
    if (current() &&
        bytes != null &&
        await _savedCover(track, disk) == null &&
        current()) {
      await disk.write(track, 'art', bytes);
    }
    return current() ? bytes : null;
  }

  void _trimCovers() {
    if (_covers.length >= 64) {
      final first = _covers.keys.first;
      _covers.remove(first);
      _coverBytes.remove(first);
      _coverSuccess.remove(first);
      _coverDirty.remove(first);
    }
  }

  Future<Uint8List?> cover(Track track) {
    final id = track.fileId;
    if (!ready || id == null) return Future.value(null);
    if (_covers[id] case final cached?) return cached;
    _trimCovers();
    final generation = _imageGeneration;
    _coverPending[id] = generation;
    return _covers[id] = _loadCover(track, generation);
  }

  Future<Uint8List?> _loadCover(Track track, int generation) async {
    final id = track.fileId!;
    Uint8List? result;
    var metadataJob = false;
    bool active() => ready && generation == _imageGeneration;
    final disk = mediaCache;
    try {
      final saved = await _savedCover(track, disk);
      if (saved != null && active()) {
        result = saved;
        return result;
      }
      // Saved covers are independent of the bounded network/metadata work.
      while (_coverJobs >= 2 && active()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!active()) return null;
      ++_coverJobs;
      metadataJob = true;
      if (track.coverFileId case final thumbnail?) {
        try {
          final path = await image(thumbnail);
          if (path != null && active()) {
            final file = File(path);
            if (await file.length() <= maxCoverBytes) {
              final bytes = await file.readAsBytes();
              if (await _validCover(bytes)) result = bytes;
            }
          }
        } catch (_) {
          /* Try the original file's embedded picture. */
        }
      }
      if (result == null && track.size > 0 && active()) {
        final embedded = await _withAudioMetadata(
          id,
          generation,
          (source) => readEmbeddedCover(source, track.size),
        );
        if (embedded != null && await _validCover(embedded)) result = embedded;
      }
      if (result == null &&
          track.coverPreview != null &&
          await _validCover(track.coverPreview!)) {
        result = track.coverPreview;
      }
      if (active() && result != null) {
        await disk.write(track, 'art', result);
      }
      return active() ? result : null;
    } catch (_) {
      return null;
    } finally {
      if (metadataJob) --_coverJobs;
      if (_coverPending[id] == generation) _coverPending.remove(id);
      if (active()) {
        if (result != null && _covers.containsKey(id)) {
          _coverBytes[id] = result;
          _coverSuccess.add(id);
          _coverDirty.remove(id);
        } else if (_coverDirty.remove(id) && isStreaming(id)) {
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
      final text = await _withAudioMetadata(
        id,
        generation,
        (source) => readEmbeddedLyrics(source, track.size),
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

  Future<void> start({
    int? apiId,
    String? apiHash,
    bool preferSavedIdentity = false,
  }) async {
    await action(() async {
      if (state != 'disconnected') {
        throw StateError('Finish signing out before connecting again.');
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
      if (preferSavedIdentity &&
          _secrets['apiId'] is int &&
          _secrets['apiHash'] is String) {
        apiId = null;
        apiHash = null;
      }
      // Retain the application identity of existing/restored sessions. Use the
      // build identity only for a fresh sign-in with no saved API details.
      if (apiId == null &&
          apiHash == null &&
          !_secrets.containsKey('apiId') &&
          !_secrets.containsKey('apiHash') &&
          hasApplicationCredentials) {
        _secrets['apiId'] = applicationApiId;
        _secrets['apiHash'] = applicationApiHash;
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
        final file = json['file'] as Json;
        final id = file['id'] as int;
        // Deleting a temporary audio copy isn't new artwork becoming available.
        // Don't turn cleanup into an endless metadata download/retry cycle.
        if (_audioDeletes.containsKey(id) ||
            file['local']?['downloaded_size'] == 0) {
          return;
        }
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
    authenticationLink =
        state == 'authorizationStateWaitOtherDeviceConfirmation'
        ? auth['link'] as String?
        : null;
    if (state == 'authorizationStateWaitCode') {
      final info = auth['code_info'];
      if (info is Map && info['phone_number'] is String) {
        final reported = (info['phone_number'] as String).trim();
        try {
          authenticationPhoneNumber = internationalLoginNumber(
            reported.startsWith('+') || reported.startsWith('00')
                ? reported
                : '+$reported',
          );
        } on FormatException {
          /* Keep the last known number if Telegram omits it. */
        }
      }
    } else if (state == 'authorizationStateReady' ||
        state == 'authorizationStateClosed') {
      authenticationPhoneNumber = null;
    }
    if (state == 'authorizationStateClosed') {
      _clientClosed = true;
      _audioSweep = null;
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
    if (ready && !hasActiveStream()) {
      _audioSweep ??= _purgeOldAudio();
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
          'application_version': '0.1.104',
        }));
      } on TdException catch (e) {
        throw FormatException(
          'Telegram could not open the saved session (TDLib ${e.code}). Restore a valid account backup or retry connecting.',
        );
      }
    } else if (ready) {
      await _audioSweep;
      await refreshChats();
    }
  }

  Future<void> submit(String value) => action(() async {
    if (state == 'authorizationStateWaitPhoneNumber') {
      await _sendLoginPhoneNumber(value);
      return;
    }
    final request = switch (state) {
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

  Future<List<PhoneCountry>> loginCountries() async =>
      PhoneCountry.fromResponse(await request({'@type': 'getCountries'}));

  Future<void> _sendLoginPhoneNumber(String input) async {
    final number = internationalLoginNumber(input),
        previous = authenticationPhoneNumber;
    authenticationPhoneNumber = number;
    try {
      await transport.request({
        '@type': 'setAuthenticationPhoneNumber',
        'phone_number': number,
      });
      if (ready || state == 'disconnected') authenticationPhoneNumber = null;
    } catch (_) {
      authenticationPhoneNumber = previous;
      rethrow;
    }
  }

  Future<void> changeLoginPhoneNumber(String number) => action(() async {
    if (state != 'authorizationStateWaitCode') {
      throw StateError(
        'The number can be edited while waiting for a login code.',
      );
    }
    await _sendLoginPhoneNumber(number);
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

  /// Only account identity and application API details are shared, never the
  /// TDLib database/auth key: each device must obtain its own Telegram session.
  Future<Map<String, dynamic>> cloudIdentity() async {
    if (!ready || busy) {
      throw const FormatException('Wait for Telegram to connect.');
    }
    final me = await transport.request({'@type': 'getMe'});
    final id = me['id'];
    if (id is! int ||
        id <= 0 ||
        _secrets['apiId'] is! int ||
        _secrets['apiHash'] is! String) {
      throw const FormatException(
        'Could not read the connected Telegram account.',
      );
    }
    final name = [
      me['first_name'],
      me['last_name'],
    ].whereType<String>().where((v) => v.isNotEmpty).join(' ');
    return {
      'userId': id,
      'name': name.isEmpty
          ? 'Telegram account'
          : name.substring(0, name.length > 160 ? 160 : name.length),
      'apiId': _secrets['apiId'],
      'apiHash': _secrets['apiHash'],
    };
  }

  Future<void> requestCloudLogin() async {
    if (busy || state != 'authorizationStateWaitPhoneNumber') {
      throw const FormatException('Wait for Telegram sign-in to become ready.');
    }
    await transport.request({
      '@type': 'requestQrCodeAuthentication',
      'other_user_ids': <int>[],
    });
  }

  Future<void> cancelCloudLogin() async {
    if (busy || state != 'authorizationStateWaitOtherDeviceConfirmation') {
      throw const FormatException(
        'Telegram is not waiting for device approval.',
      );
    }
    // TDLib explicitly supports logOut before authorization; it destroys only
    // this unapproved device's temporary keys, not another device's session.
    await transport.request({'@type': 'logOut'});
    await shutdown();
    await start();
  }

  Future<void> confirmCloudLogin(String link, int userId) async {
    if (!RegExp(r'^tg://login\?token=[A-Za-z0-9_-]{20,256}$').hasMatch(link)) {
      throw const FormatException('Invalid Telegram device request.');
    }
    final current = await cloudIdentity();
    if (current['userId'] != userId) {
      throw const FormatException(
        'This device is signed in to a different Telegram account.',
      );
    }
    final session = await transport.request({
      '@type': 'confirmQrCodeAuthentication',
      'link': link,
    });
    if (session['@type'] != 'session') {
      throw const FormatException(
        'Telegram did not confirm the new device. Retry there.',
      );
    }
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
    authenticationPhoneNumber = null;
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
        hasApplicationCredentials
            ? 'Signed out, but saved connection details could not be cleared. Restart Auralis and try connecting again.'
            : 'Signed out, but saved API details could not be cleared. Enter your API ID and hash again before connecting.',
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
    authenticationLink = null;
    authenticationPhoneNumber = null;
    clearImageCache();
    await _subscription?.cancel();
    try {
      await transport.close();
    } finally {
      await MediaCache.drain(directory);
      _clientClosed = true;
      _audioSweep = null;
      _parametersRequest = null;
      connection = 'Offline';
      notifyListeners();
    }
  }
}
