part of 'controller.dart';

// These fields live with the protected Auralis account journal. Telegram auth
// keys and databases remain on their own devices. A recent password sign-in
// can authorize the Worker to relay an independent TDLib login automatically.
extension TelegramAccountSync on SyncController {
  bool get telegramSyncAvailable => telegram != null && signedIn;
  bool get telegramIncluded => _telegramIncluded;
  bool get telegramWorking => _telegramPolling || _telegramOperating;
  Map<String, dynamic>? get linkedTelegram => _telegramProfile == null
      ? null
      : {
          'userId': _telegramProfile!['userId'],
          'name': _telegramProfile!['name'],
        };
  List<Map<String, dynamic>> get telegramDeviceRequests =>
      List.unmodifiable(_telegramRequests);
  String? get telegramPairCode => _telegramCode;
  String get telegramSyncStatus => _telegramStatus;
  String? get telegramSyncError => _telegramError;
  bool get telegramNeedsPassword =>
      telegram?.state == 'authorizationStateWaitPassword';

  void _resetTelegramSync() {
    _telegramEpoch++;
    _telegramPhoneFallback = false;
    _telegramProfile = null;
    _telegramLoginGrant = null;
    _telegramIncluded = true;
    _telegramRequests = [];
    _telegramCode = null;
    _telegramRequestId = null;
    _telegramPublishedLink = null;
    _telegramStatus = 'Checking linked Telegram account…';
    _telegramError = null;
  }

  void _telegramChanged() {
    if (_closed || telegram == null) return;
    _telegramDebounce?.cancel();
    _telegramDebounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(syncTelegramAccount()),
    );
  }

  bool _sameTelegramScope(SyncAccount user) =>
      !_closed &&
      signedIn &&
      _account!.identity == user.identity &&
      _account!.token == user.token;
  Future<Map<String, dynamic>> _telegramRequest(
    SyncAccount user,
    String suffix, {
    Map<String, dynamic>? data,
    String method = 'GET',
  }) => accountRequest(
    '/v1/account/telegram$suffix',
    endpoint: user.url,
    token: user.token,
    data: data,
    method: method,
  );
  Map<String, dynamic>? _checkedTelegramProfile(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map ||
        raw['userId'] is! int ||
        (raw['userId'] as int) <= 0 ||
        raw['apiId'] is! int ||
        (raw['apiId'] as int) <= 0 ||
        raw['apiHash'] is! String ||
        !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(raw['apiHash'] as String) ||
        raw['name'] is! String ||
        (raw['name'] as String).length > 160) {
      throw const FormatException('Invalid linked Telegram account.');
    }
    return {
      for (final key in ['userId', 'name', 'apiId', 'apiHash']) key: raw[key],
    };
  }

  Future<void> syncTelegramAccount() async {
    final td = telegram, user = _account;
    if (td == null ||
        user == null ||
        !signedIn ||
        _closed ||
        busy ||
        _telegramPolling ||
        _telegramOperating ||
        paused() ||
        td.busy) {
      return;
    }
    _telegramPolling = true;
    final epoch = _telegramEpoch;
    bool current() => _sameTelegramScope(user) && epoch == _telegramEpoch;
    try {
      final result = await _telegramRequest(user, '');
      if (!current()) return;
      _telegramIncluded = result['enabled'] != false;
      _telegramProfile = _checkedTelegramProfile(result['profile']);
      final automaticLinking = result['automaticLinking'] == true;
      _telegramError = null;
      if (!_telegramIncluded) {
        _telegramStatus =
            'Telegram account sync is off. Local sign-ins are kept.';
        _telegramCode = null;
        _telegramRequests = [];
        return;
      }
      if (td.ready) {
        _telegramCode = null;
        _telegramRequestId = null;
        _telegramPublishedLink = null;
        final local = await td.cloudIdentity();
        if (!current()) return;
        if (_telegramProfile == null) {
          if (_telegramOwner != null && _telegramOwner != user.identity) {
            _telegramStatus = 'This device’s Telegram belongs to another Auralis account. Use Link this Telegram account to include it here.';
            return;
          }
          if (busy) return;
          accountBusy = true;
          try {
            await _telegramRequest(
              user,
              '',
              method: 'PUT',
              data: {...local, 'automatic': true},
            );
          } finally {
            accountBusy = false;
          }
          if (!current()) return;
          _telegramProfile = local;
        }
        if (local['userId'] != _telegramProfile!['userId']) {
          _telegramStatus = 'This device uses another Telegram account. Sign out of Telegram here to connect the linked account.';
          _telegramRequests = [];
          return;
        }
        _telegramLoginGrant = null;
        if (_telegramOwner != user.identity) {
          _telegramOwner = user.identity;
          await _saveAccounts();
        }
        _telegramCode = null;
        _telegramRequestId = null;
        _telegramPublishedLink = null;
        final pending = await _telegramRequest(
          user,
          automaticLinking ? '/requests/automatic' : '/requests',
        );
        if (!current()) return;
        final requests = [
          for (final item in pending['requests'] as List? ?? [])
            if (item is Map &&
                item['id'] is String &&
                RegExp(r'^[a-f0-9]{64}$').hasMatch(item['id'] as String) &&
                item['expires'] is int)
              Map<String, dynamic>.from(item),
        ];
        _telegramRequests = requests
            .where((request) => request['automatic'] != true)
            .toList();
        _telegramStatus = _telegramRequests.isEmpty
            ? 'Telegram account linked. Each device keeps its own sign-in.'
            : 'A new device is waiting for your approval.';
        final automatic = requests
            .where((request) => request['automatic'] == true)
            .firstOrNull;
        if (automatic != null && !busy && !paused()) {
          accountBusy = true;
          try {
            await _completeTelegramDevice(
              user,
              td,
              _telegramProfile!['userId'] as int,
              automatic['id'] as String,
              active: current,
            );
            if (current()) {
              _telegramStatus = 'Telegram sign-in approved for the new device.';
            }
          } finally {
            accountBusy = false;
          }
        }
      } else if (_telegramProfile == null) {
        _telegramStatus =
            'Connect Telegram on this device to include your account.';
      } else {
        _telegramRequests = [];
        if (_telegramPhoneFallback) {
          _telegramStatus = 'Sign in with your phone number in the Telegram tab. Your linked account is kept.';
          return;
        }
        _telegramStatus = 'Connecting the linked Telegram account…';
        if (td.state == 'disconnected' && !td.credentialRecoveryRequired) {
          // Existing vault identity is preserved by TelegramService.start. No
          // database, saved auth key, 2FA password or login code is downloaded.
          if (!current()) return;
          if (busy) return;
          accountBusy = true;
          _changed();
          try {
            await td.start(
              apiId: _telegramProfile!['apiId'] as int,
              apiHash: _telegramProfile!['apiHash'] as String,
              preferSavedIdentity: true,
            );
          } finally {
            accountBusy = false;
          }
        }
        if (!current()) return;
        if (td.state == 'authorizationStateWaitPhoneNumber') {
          if (busy) return;
          accountBusy = true;
          _changed();
          try {
            await td.requestCloudLogin();
          } finally {
            accountBusy = false;
          }
        }
        if (!current()) return;
        if (td.state == 'authorizationStateWaitPassword') {
          _telegramCode = null;
          _telegramRequestId = null;
          _telegramPublishedLink = null;
          _telegramStatus = 'Enter your Telegram two-step verification password to finish signing in.';
          return;
        }
        final link = td.authenticationLink;
        if (td.state == 'authorizationStateWaitOtherDeviceConfirmation' &&
            link != null) {
          if (link != _telegramPublishedLink) {
            final grant = automaticLinking ? _telegramLoginGrant : null;
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            if (grant != null && grant.expires <= now) {
              _telegramStatus = 'Sign in to Auralis again to connect Telegram automatically, or use phone sign-in.';
              return;
            }
            final request = await _telegramRequest(
              user,
              '/requests',
              method: 'POST',
              data: {'link': link, if (grant != null) 'grant': grant.token},
            );
            if (!current()) return;
            final id = request['id'];
            final code = request['code'];
            if (id is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
                (grant != null
                    ? request['automatic'] != true
                    : code is! String || !RegExp(r'^\d{6}$').hasMatch(code))) {
              throw const FormatException('Invalid device sign-in response.');
            }
            _telegramRequestId = id;
            _telegramCode = grant == null ? code as String : null;
            _telegramPublishedLink = link;
          }
          final state = await _telegramRequest(
            user,
            '/requests/$_telegramRequestId',
          );
          if (!current()) return;
          if (state['state'] == 'failed') {
            _telegramStatus = 'Telegram could not connect. Waiting for a fresh sign-in request.';
          } else if (_telegramCode == null) {
            _telegramStatus = state['state'] == 'approved'
                ? 'Finishing Telegram sign-in…'
                : 'Waiting for Auralis on an already connected device. Telegram will connect automatically.';
          } else {
            _telegramStatus = 'Open Account & sync on an already connected device, tap Approve and enter this device’s six-digit code.';
          }
        } else if (td.error != null) {
          _telegramStatus =
              'Finish Telegram sign-in in the Telegram tab. ${td.error}';
        }
      }
    } on FormatException catch (e) {
      if (current()) _telegramError = e.message;
    } catch (_) {
      if (current()) _telegramError = 'Telegram account sync is pending. Check your connection and update the Worker if needed.';
    } finally {
      _telegramPolling = false;
      _changed();
    }
  }

  Future<void> setTelegramIncluded(bool include) async {
    final user = _account, td = telegram;
    if (user == null || td == null || !signedIn || busy || _telegramOperating) {
      throw const FormatException('Wait for the current operation.');
    }
    _telegramEpoch++;
    accountBusy = true;
    _telegramOperating = true;
    _changed();
    try {
      if (include) {
        if (!td.ready) {
          throw const FormatException(
            'Connect Telegram on this device before linking your account.',
          );
        }
        final profile = await td.cloudIdentity();
        await _telegramRequest(user, '', method: 'PUT', data: profile);
        _telegramOwner = user.identity;
        await _saveAccounts();
        _telegramProfile = profile;
        _telegramIncluded = true;
        _telegramStatus = 'Telegram account included on your devices.';
      } else {
        await _telegramRequest(user, '', method: 'DELETE');
        _resetTelegramSync();
        _telegramIncluded = false;
        _telegramStatus =
            'Telegram account sync is off. Local sign-ins are kept.';
      }
      _telegramError = null;
    } finally {
      accountBusy = false;
      _telegramOperating = false;
      _changed();
      _telegramChanged();
    }
  }

  Future<void> approveTelegramDevice(String id, String code) async {
    final user = _account, td = telegram, profile = _telegramProfile;
    if (user == null ||
        td == null ||
        profile == null ||
        !signedIn ||
        busy ||
        _telegramOperating ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        !RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException(
        'Enter the six-digit code shown on your new device.',
      );
    }
    _telegramEpoch++;
    accountBusy = true;
    _telegramOperating = true;
    _changed();
    final epoch = _telegramEpoch;
    try {
      final userId = profile['userId'] as int;
      final local = await td.cloudIdentity();
      if (local['userId'] != userId) {
        throw const FormatException(
          'Use the device signed in to the linked Telegram account.',
        );
      }
      await _completeTelegramDevice(
        user,
        td,
        userId,
        id,
        code: code,
        active: () => _sameTelegramScope(user) && epoch == _telegramEpoch,
      );
      _telegramRequests.removeWhere((r) => r['id'] == id);
      _telegramStatus = 'New device approved. Telegram may still request its two-step password.';
      _telegramError = null;
    } finally {
      accountBusy = false;
      _telegramOperating = false;
      _changed();
    }
  }

  Future<void> _completeTelegramDevice(
    SyncAccount user,
    TelegramService td,
    int userId,
    String id, {
    String? code,
    required bool Function() active,
  }) async {
    void checkScope() {
      if (!active() || !td.ready) {
        throw const FormatException(
          'The linked account changed. Retry on the new device.',
        );
      }
    }

    var claimed = false;
    try {
      checkScope();
      final result = await _telegramRequest(
        user,
        '/requests/$id/claim',
        method: 'POST',
        data: code == null
            ? {'automatic': true, 'userId': userId}
            : {'code': code},
      );
      claimed = true;
      checkScope();
      if (result['link'] is! String || result['userId'] != userId) {
        throw const FormatException('Invalid Telegram device request.');
      }
      await td.confirmCloudLogin(result['link'] as String, userId);
      await _telegramRequest(
        user,
        '/requests/$id/complete',
        method: 'POST',
        data: {'ok': true},
      );
    } catch (_) {
      if (claimed) {
        try {
          await _telegramRequest(
            user,
            '/requests/$id/complete',
            method: 'POST',
            data: {'ok': false},
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> useTelegramPhoneSignIn() async {
    final td = telegram, user = _account;
    if (td == null ||
        user == null ||
        busy ||
        td.state != 'authorizationStateWaitOtherDeviceConfirmation') {
      throw const FormatException('Wait for the device approval code.');
    }
    _telegramEpoch++;
    accountBusy = true;
    _telegramOperating = true;
    _changed();
    try {
      if (_telegramRequestId != null) {
        try {
          await _telegramRequest(
            user,
            '/requests/$_telegramRequestId',
            method: 'DELETE',
          );
        } catch (_) {}
      }
      _telegramPhoneFallback = true;
      _telegramLoginGrant = null;
      _telegramCode = null;
      _telegramRequestId = null;
      await td.cancelCloudLogin();
      _telegramStatus =
          'Use the Telegram tab to sign in with your phone number.';
    } finally {
      accountBusy = false;
      _telegramOperating = false;
      _changed();
    }
  }

  Future<void> submitTelegramPassword(String password) async {
    final td = telegram;
    if (td == null || !signedIn || busy || !telegramNeedsPassword) {
      throw const FormatException('Telegram is not waiting for a password.');
    }
    _telegramEpoch++;
    accountBusy = true;
    _telegramOperating = true;
    _changed();
    try {
      await td.submit(password);
      if (td.error != null) throw FormatException(td.error!);
    } finally {
      accountBusy = false;
      _telegramOperating = false;
      _changed();
      _telegramChanged();
    }
  }
}
