part of 'controller.dart';

const _sharedFields = [
  'favoriteIds',
  'playlists',
  'recentIds',
  'selectedChannels',
  'listening',
  'librarySort',
  'repeatMode',
];

class SyncAccount {
  SyncAccount(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get username => data['username'] as String;
  String get url => data['url'] as String;
  String get token => data['token'] as String? ?? '';
  bool get admin => data['admin'] == true;
  bool get expired =>
      (data['expires'] as int? ?? 0) <=
      DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String get identity => '$url|$id';
}

extension AccountSync on SyncController {
  bool get signedIn => _account != null && connected;
  bool get legacyConnection => connected && _account == null;
  SyncAccount? get account => _account;
  bool get busy => accountBusy || workerUpdating;
  String get serviceUrl => _serviceUrl.isNotEmpty ? _serviceUrl : url;
  String get workerName =>
      Uri.tryParse(_account?.url ?? serviceUrl)?.host.split('.').first ??
      'Auralis';
  List<SyncAccount> get savedAccounts =>
      _profiles.map(SyncAccount.new).toList(growable: false);

  Future<Map<String, dynamic>> accountRequest(
    String path, {
    String? endpoint,
    String? token,
    Map<String, dynamic>? data,
    String method = 'POST',
  }) async {
    final request = await _client
        .openUrl(
          method,
          Uri.parse('${SyncController.normalize(endpoint ?? url)}$path'),
        )
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    final credential = token ?? _key;
    if (credential != null && credential.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer $credential');
    }
    if (data != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(data)));
    }
    final response = await request.close().timeout(const Duration(seconds: 20)),
        bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const FormatException('Account response is too large.');
      }
      bytes.addAll(chunk);
    }
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Invalid account response.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        result['error'] is String
            ? result['error'] as String
            : 'Account request failed.',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> validateWorker(String endpoint) async {
    endpoint = SyncController.normalize(endpoint);
    final h = await accountRequest(
      '/health',
      endpoint: endpoint,
      token: '',
      method: 'GET',
    );
    if (h['service'] != 'auralis-sync' || h['configured'] != true) {
      throw const FormatException('Enter a configured Auralis Worker URL.');
    }
    if (h['accounts'] != true) {
      throw const FormatException(
        'Update this Worker in Deploy Database using its existing sync key as the JWT secret.',
      );
    }
    _serviceUrl = endpoint;
    _changed();
    return h;
  }

  Future<void> rememberService(String endpoint) async {
    _serviceUrl = SyncController.normalize(endpoint);
    await _saveAccounts();
    _changed();
  }

  Future<void> _saveAccounts() {
    final snapshot = detached({
      'format': 2,
      'service': serviceUrl,
      'localOwner': _localOwner,
      'telegramOwner': _telegramOwner,
      'profiles': _profiles,
      'active': _account?.identity,
      'legacy': _legacy,
    });
    final write = _accountWrites.then((_) => vault.write(snapshot));
    _accountWrites = write.catchError((Object _) {});
    return write;
  }

  Future<bool> _loadAccounts(Map<String, dynamic> saved) async {
    if (saved['format'] != 2) return false;
    _serviceUrl = saved['service'] as String? ?? '';
    _localOwner = saved['localOwner'] as String?;
    _telegramOwner = saved['telegramOwner'] as String?;
    _legacy = saved['legacy'] is Map
        ? Map<String, dynamic>.from(saved['legacy'] as Map)
        : null;
    for (final item in saved['profiles'] as List? ?? []) {
      if (item is! Map ||
          item['id'] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(item['id'] as String) ||
          item['username'] is! String ||
          item['url'] is! String) {
        continue;
      }
      final p = Map<String, dynamic>.from(item);
      p['url'] = SyncController.normalize(p['url'] as String);
      _profiles.add(p);
    }
    final active = _profiles
        .where((p) => SyncAccount(p).identity == saved['active'])
        .firstOrNull;
    if (active != null) {
      final user = SyncAccount(active), expected = _scope(user);
      if (settings.syncState['scope'] != expected) {
        _applyLibrary(
          active['snapshot'] is Map
              ? Map<String, dynamic>.from(active['snapshot'] as Map)
              : _emptyLibrary(),
        );
        settings.syncState = active['state'] is Map
            ? detached(Map<String, dynamic>.from(active['state'] as Map))
            : {'scope': expected};
        await settings.save();
      }
      if (!user.expired && user.token.isNotEmpty) {
        _account = user;
        _activate(user.url, user.token);
        unawaited(sync());
      } else {
        status =
            'Sign in again to ${user.username}. Your local changes are kept.';
      }
    } else if (_legacy != null) {
      _activate(
        SyncController.normalize(_legacy!['url'] as String),
        _legacy!['key'] as String,
      );
      unawaited(sync());
    }
    return true;
  }

  String _scope(SyncAccount user) =>
      sha256.convert(utf8.encode('${user.url}:${user.id}')).toString();
  Map<String, dynamic> _emptyLibrary() => {
    'favoriteIds': <String>[],
    'playlists': <String, dynamic>{},
    'recentIds': <String>[],
    'selectedChannels': <dynamic>[],
    'listening': {'tracks': <String, dynamic>{}, 'days': <String, dynamic>{}},
    'librarySort': 'newest',
    'repeatMode': 'off',
  };
  void _applyLibrary(Map<String, dynamic> source) {
    final data = settings.toJson();
    for (final key in _sharedFields) {
      if (source.containsKey(key)) data[key] = source[key];
    }
    DataBackup.validateSnapshot(data);
    settings.applyJson(data);
  }

  void _stashCurrent() {
    if (_account == null) return;
    document.capture(settings.toJson());
    _account!.data['snapshot'] = detached(settings.toJson());
    _account!.data['state'] = detached(settings.syncState);
  }

  Future<void> _pauseAccount() async {
    final running = _running;
    _generation++;
    _debounce?.cancel();
    _poll?.cancel();
    _retry?.cancel();
    _client.close(force: true);
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    await _live?.cancel();
    _live = null;
    unawaited(_socket?.close());
    _socket = null;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    _url = null;
    _key = null;
  }

  Map<String, dynamic> _validatedSession(
    Map<String, dynamic> result,
    String endpoint,
    String name,
  ) {
    final user = result['user'],
        token = result['token'],
        expires = result['expires'],
        code = result['recoveryCode'];
    if (user is! Map ||
        user['id'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(user['id'] as String) ||
        user['username'] != name.trim().toLowerCase() ||
        user['admin'] is! bool ||
        token is! String ||
        token.isEmpty ||
        token.length > 2000 ||
        expires is! int ||
        expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000 ||
        code != null &&
            (code is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(code))) {
      throw const FormatException('Invalid sign-in response.');
    }
    return {
      'id': user['id'],
      'username': user['username'],
      'admin': user['admin'],
      'url': endpoint,
      'token': token,
      'expires': expires,
      'recoveryCode': ?code,
    };
  }

  Future<void> _useAccount(Map<String, dynamic> incoming) async {
    await settings.save();
    _stashCurrent();
    await _saveAccounts();
    final old = _account,
        oldUrl = _url,
        oldKey = _key,
        oldOwner = _localOwner,
        oldLegacy = _legacy,
        before = detached(settings.toJson()),
        oldState = detached(settings.syncState);
    final user = SyncAccount(incoming),
        previous = _profiles
            .where((p) => SyncAccount(p).identity == user.identity)
            .firstOrNull,
        target = previous == null
            ? incoming
            : <String, dynamic>{...previous, ...incoming};
    final initialMerge =
        _localOwner == user.identity ||
        (_localOwner == null && previous == null);
    await _pauseAccount();
    _stashCurrent();
    await _saveAccounts();
    _account = null;
    try {
      if (!initialMerge) {
        _applyLibrary(
          target['snapshot'] is Map
              ? Map<String, dynamic>.from(target['snapshot'] as Map)
              : _emptyLibrary(),
        );
        settings.syncState = target['state'] is Map
            ? detached(Map<String, dynamic>.from(target['state'] as Map))
            : <String, dynamic>{};
      }
      _account = SyncAccount(target);
      _localOwner = user.identity;
      _serviceUrl = user.url;
      if (previous != null) _profiles.remove(previous);
      _profiles.add(target);
      if (_legacy?['url'] == user.url) _legacy = null;
      if (settings.syncState['scope'] != _scope(user)) {
        settings.syncState = {'scope': _scope(user)};
        document.capture(settings.toJson());
      }
      target['snapshot'] = detached(settings.toJson());
      target['state'] = detached(settings.syncState);
      // Commit the protected journal first so interrupted settings writes can recover safely.
      await _saveAccounts();
      await settings.save();
      _activate(user.url, user.token);
      await settings.save();
      deploymentError = null;
      _resetTelegramSync();
      revision++;
      onApplied();
    } catch (_) {
      _account = null;
      _applyLibrary(before);
      settings.syncState = oldState;
      _localOwner = oldOwner;
      _legacy = oldLegacy;
      _profiles.remove(target);
      if (previous != null) _profiles.add(previous);
      _account = old;
      await _saveAccounts();
      await settings.save();
      if (oldUrl != null && oldKey != null) _activate(oldUrl, oldKey);
      rethrow;
    }
    await _recoverOwnerDeployment();
  }

  Future<void> _recoverOwnerDeployment() async {
    if (_account?.admin != true) return;
    try {
      await recoverDeploymentCredentials();
    } catch (_) {
      deploymentError = 'Sign-in succeeded. Retry deployment credential recovery in Deploy Database.';
    }
  }

  void _afterAccount() {
    accountBusy = false;
    _changed();
    if (connected) {
      unawaited(sync());
      unawaited(checkWorkerUpdates());
      _telegramChanged();
    }
  }

  Future<String?> signIn(
    String endpoint,
    String username,
    String password, {
    bool register = false,
    String? claimKey,
  }) async {
    if (busy) throw const FormatException('Wait for the current operation.');
    accountBusy = true;
    _changed();
    try {
      endpoint = SyncController.normalize(endpoint);
      final h = await validateWorker(endpoint);
      var proof = claimKey ?? '';
      if (register && h['ownerCreated'] != true && proof.isEmpty) {
        if (_legacy?['url'] == endpoint) {
          proof = _legacy!['key'] as String? ?? '';
        }
        if (legacyConnection && url == endpoint) proof = _key ?? '';
        final p = await deploymentProfile(endpoint);
        if (p['url'] == endpoint && p['key'] is String) {
          proof = p['key'] as String;
        }
      }
      final result = await accountRequest(
            '/v1/auth/${register ? 'register' : 'login'}',
            endpoint: endpoint,
            token: '',
            data: {
              'username': username.trim().toLowerCase(),
              'password': password,
              if (register) 'claimKey': proof,
            },
          ),
          incoming = _validatedSession(result, endpoint, username);
      try {
        await _useAccount(incoming);
      } catch (_) {
        try {
          await accountRequest(
            '/v1/auth/logout',
            endpoint: endpoint,
            token: incoming['token'] as String,
          );
        } catch (_) {}
        if (register) {
          throw const FormatException(
            'Account created, but saving this device did not finish. Sign in with the same username and password to retry.',
          );
        }
        rethrow;
      }
      return result['recoveryCode'] as String?;
    } finally {
      _afterAccount();
    }
  }

  Future<void> switchAccount(SyncAccount target) async {
    if (busy) throw const FormatException('Wait for the current operation.');
    if (target.expired || target.token.isEmpty) {
      throw const FormatException('Sign in again to this saved account.');
    }
    accountBusy = true;
    _changed();
    try {
      final result = await accountRequest(
        '/v1/account',
        endpoint: target.url,
        token: target.token,
        method: 'GET',
      );
      if (result['user'] is! Map ||
          (result['user'] as Map)['id'] != target.id ||
          (result['user'] as Map)['username'] != target.username) {
        throw const FormatException('Sign in again to this saved account.');
      }
      await _useAccount(Map<String, dynamic>.from(target.data));
    } finally {
      _afterAccount();
    }
  }

  Future<void> signOut({bool keepLocal = true}) async {
    if (busy) throw const FormatException('Wait for the current operation.');
    accountBusy = true;
    _changed();
    try {
      await settings.save();
      _stashCurrent();
      await _saveAccounts();
      if (_account != null) {
        try {
          await accountRequest('/v1/auth/logout');
        } catch (_) {
          /* Local sign-out also works offline. */
        }
      }
      await _pauseAccount();
      _stashCurrent();
      _account?.data.remove('token');
      _account?.data.remove('expires');
      _account = null;
      _legacy = null;
      if (!keepLocal) {
        _applyLibrary(_emptyLibrary());
        _localOwner = null;
      }
      settings.syncState = {};
      await settings.save();
      await _saveAccounts();
      revision++;
      onApplied();
      _resetTelegramSync();
      status = 'Signed out. Local library ${keepLocal ? 'kept' : 'cleared'}.';
      error = null;
      deploymentError = null;
    } finally {
      accountBusy = false;
      _changed();
    }
  }

  Future<void> forgetAccount(SyncAccount user) async {
    if (busy || user.identity == _account?.identity) {
      throw const FormatException('Sign out of this account first.');
    }
    if (((user.data['state'] as Map?)?['dirty'] as List? ?? []).isNotEmpty) {
      throw const FormatException(
        'Sign in and sync this account before forgetting its local changes.',
      );
    }
    accountBusy = true;
    _changed();
    try {
      if (user.token.isNotEmpty && !user.expired) {
        await accountRequest(
          '/v1/auth/logout',
          endpoint: user.url,
          token: user.token,
        );
      }
      _profiles.removeWhere((p) => SyncAccount(p).identity == user.identity);
      await _saveAccounts();
    } finally {
      accountBusy = false;
      _changed();
    }
  }

  Future<void> restoreCloudCopy() async {
    if (!connected || busy) return;
    accountBusy = true;
    _changed();
    try {
      _stashCurrent();
      _account?.data['beforeRestore'] = {
        'snapshot': detached(settings.toJson()),
        'state': detached(settings.syncState),
      };
      await _saveAccounts();
      final running = _running;
      if (running != null) await running;
      final remote = <String, dynamic>{};
      var cursor = 0, more = true;
      while (more) {
        final p = await _request(url, _key!, {
          'cursor': cursor,
          'ops': <String, dynamic>{},
        });
        remote.addAll(p['records'] as Map<String, dynamic>);
        cursor = p['cursor'] as int;
        more = p['more'] as bool;
      }
      final merged = SyncDocument({
        'scope': settings.syncState['scope'],
        'bootstrap': false,
      });
      merged.merge(remote);
      merged.state['cursor'] = cursor;
      final snapshot = merged.project({
        ...settings.toJson(),
        ..._emptyLibrary(),
      });
      DataBackup.validateSnapshot(snapshot);
      settings.syncState = merged.state;
      settings.applyJson(snapshot);
      await settings.save();
      _stashCurrent();
      await _saveAccounts();
      revision++;
      onApplied();
      status = 'Cloud copy restored.';
      error = null;
    } finally {
      accountBusy = false;
      _changed();
    }
  }

  Future<void> uploadLocalChanges() => flush();
  Future<void> deleteAccount(String password) async {
    if (!signedIn || busy) return;
    accountBusy = true;
    _changed();
    try {
      final endpoint = url,
          token = _key!,
          identity = _account!.identity,
          owner = _account!.admin;
      _stashCurrent();
      await _saveAccounts();
      await _pauseAccount();
      try {
        await accountRequest(
          '/v1/account',
          endpoint: endpoint,
          token: token,
          method: 'DELETE',
          data: {'password': password},
        );
      } catch (_) {
        _activate(endpoint, token);
        rethrow;
      }
      _profiles.removeWhere((p) => SyncAccount(p).identity == identity);
      _account = null;
      _localOwner = null;
      _applyLibrary(_emptyLibrary());
      settings.syncState = {};
      await settings.save();
      await _saveAccounts();
      if (owner) await _forgetDeploymentLocal(endpoint);
      revision++;
      onApplied();
      _resetTelegramSync();
      status = 'Account deleted. Other accounts and Telegram sign-in are kept.';
      error = null;
    } finally {
      accountBusy = false;
      _changed();
    }
  }

  Future<String> recoverAccount(
    String endpoint,
    String username,
    String code,
    String newPassword,
  ) async {
    if (busy) throw const FormatException('Wait for the current operation.');
    accountBusy = true;
    _changed();
    try {
      final running = _running;
      if (running != null) await running;
      endpoint = SyncController.normalize(endpoint);
      await validateWorker(endpoint);
      final result = await accountRequest(
        '/v1/auth/recover',
        endpoint: endpoint,
        token: '',
        data: {
          'username': username.trim().toLowerCase(),
          'recoveryCode': code.trim(),
          'newPassword': newPassword,
        },
      );
      final incoming = _validatedSession(result, endpoint, username);
      await _useAccount(incoming);
      return result['recoveryCode'] as String;
    } finally {
      _afterAccount();
    }
  }

  Future<Map<String, dynamic>> deploymentProfile([String? endpoint]) async {
    if (deploymentVault == null) return {};
    final stored = await deploymentVault!.read(),
        target = endpoint ?? serviceUrl,
        workers = stored['workers'] as Map?;
    final profile = workers?[target] is Map
        ? Map<String, dynamic>.from(workers![target] as Map)
        : stored;
    final ownerId =
        profile['ownerId'] ??
        _profiles
            .where((p) => p['admin'] == true && p['url'] == profile['url'])
            .firstOrNull?['id'];
    if (ownerId != null && ownerId != _account?.id ||
        _account != null &&
            !_account!.admin &&
            profile['url'] == _account!.url) {
      return {
        'locked': true,
        'url': profile['url'],
        'worker': profile['worker'],
      };
    }
    return profile;
  }

  Future<void> saveDeploymentProfile(Map<String, dynamic> profile) async {
    if (deploymentVault == null) {
      throw const FormatException('Deployment storage is unavailable.');
    }
    final stored = await deploymentVault!.read(),
        workers = Map<String, dynamic>.from(stored['workers'] as Map? ?? {});
    if (_account?.admin == true && profile['url'] == _account!.url) {
      profile = {...profile, 'ownerId': _account!.id};
    }
    if (profile['url'] is String) {
      workers[profile['url'] as String] = {...profile}..remove('workers');
    }
    await deploymentVault!.write({...profile, 'workers': workers});
    _changed();
  }

  Future<void> recoverDeploymentCredentials() async {
    if (_account?.admin != true || deploymentVault == null) return;
    final savedLocal = await deploymentProfile(url);
    if (savedLocal['url'] == url && savedLocal['key'] is String) {
      await saveDeploymentProfile(savedLocal);
    }
    final r = await accountRequest('/v1/account/deployment', method: 'GET');
    if (r['deployment'] is! Map) {
      if (savedLocal['url'] == url &&
          [
            'worker',
            'account',
            'cloudflareToken',
            'database',
            'databaseToken',
            'key',
          ].every(
            (key) =>
                savedLocal[key] is String &&
                (savedLocal[key] as String).isNotEmpty,
          )) {
        SyncDeploymentConfig.fromJson(savedLocal).validate();
        await saveRecoveryDeployment(savedLocal);
      }
      deploymentError = null;
      return;
    }
    final p = Map<String, dynamic>.from(r['deployment'] as Map);
    SyncDeploymentConfig.fromJson(p).validate();
    final local = await deploymentProfile(url);
    await saveDeploymentProfile({
      ...p,
      'url': url,
      'version': r['version'],
      'automatic': local['url'] == url && local.containsKey('automatic')
          ? local['automatic'] != false
          : p['automatic'] != false,
    });
    deploymentError = null;
  }

  Future<void> saveRecoveryDeployment(Map<String, dynamic> profile) async {
    if (_account?.admin == true && profile['url'] == url) {
      await accountRequest(
        '/v1/account/deployment',
        method: 'PUT',
        data: SyncDeploymentConfig.fromJson(profile).toJson(),
      );
    }
  }

  Future<void> _forgetDeploymentLocal(String endpoint) async {
    if (deploymentVault == null) return;
    final stored = await deploymentVault!.read(),
        workers = Map<String, dynamic>.from(stored['workers'] as Map? ?? {});
    workers.remove(endpoint);
    await deploymentVault!.write({'workers': workers});
  }

  Future<void> forgetDeploymentCredentials() async {
    if (_account?.admin == true) {
      await accountRequest('/v1/account/deployment', method: 'DELETE');
    }
    await _forgetDeploymentLocal(serviceUrl);
    _changed();
  }

  bool beginWorkerOperation() {
    if (_closed || busy) return false;
    workerUpdating = true;
    _changed();
    return true;
  }

  void endWorkerOperation() {
    workerUpdating = false;
    _changed();
  }

  Future<void> checkWorkerUpdates() async {
    if (_closed || busy || deploymentVault == null || serviceUrl.isEmpty) {
      return;
    }
    final endpoint = _account?.url ?? serviceUrl;
    workerUpdating = true;
    _changed();
    final deployment = SyncDeployment();
    try {
      final profile = await deploymentProfile(endpoint);
      if (profile['locked'] == true ||
          profile['automatic'] == false ||
          profile['url'] != endpoint) {
        return;
      }
      final config = SyncDeploymentConfig.fromJson(profile);
      config.validate();
      final h = await accountRequest(
        '/health',
        endpoint: endpoint,
        token: '',
        method: 'GET',
      );
      if (h['service'] != 'auralis-sync' ||
          !_newerWorker(
            currentSyncWorkerVersion,
            h['version'] as String? ?? '',
          )) {
        return;
      }
      status = 'Updating your sync Worker…';
      _changed();
      final deployed = await deployment.deploy(config, (_) {}),
          saved = {
            ...profile,
            'url': deployed,
            'version': currentSyncWorkerVersion,
          };
      await saveDeploymentProfile(saved);
      await saveRecoveryDeployment(saved);
      deploymentError = null;
      status = 'Sync Worker updated.';
    } catch (_) {
      deploymentError = 'Automatic Worker update is pending. Retry from Deploy Database. Your library is kept.';
    } finally {
      deployment.close();
      endWorkerOperation();
    }
  }

  bool _newerWorker(String bundled, String remote) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(remote)) return false;
    final a = bundled.split('.').map(int.parse).toList(),
        b = remote.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }
}
