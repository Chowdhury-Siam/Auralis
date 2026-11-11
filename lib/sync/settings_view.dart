import 'package:flutter/material.dart';

import '../app_popups.dart';

import 'package:flutter/services.dart';

import '../external_links.dart';
import '../preference_widgets.dart';
import 'controller.dart';
import 'deployment_view.dart';

class SyncSettings extends StatelessWidget {
  const SyncSettings({super.key, required this.controller});
  final SyncController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const PreferenceIcon(Icons.cloud_sync_rounded),
      title: const Text('Account & sync'),
      subtitle: Text(
        controller.signedIn
            ? '${controller.account!.username} · ${controller.status}'
            : 'Sign in to sync your library across devices',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SyncAccountPage(sync: controller),
        ),
      ),
    ),
  );
}

enum SyncAccountEntry { settings, signIn, register }

class SyncAccountPage extends StatefulWidget {
  const SyncAccountPage({
    super.key,
    required this.sync,
    this.entry = SyncAccountEntry.settings,
  });
  final SyncController sync;
  final SyncAccountEntry entry;
  @override
  State<SyncAccountPage> createState() => _SyncAccountPageState();
}

class _SyncAccountPageState extends State<SyncAccountPage> {
  SyncController get sync => widget.sync;
  late final _url = TextEditingController(text: sync.serviceUrl);
  final _telegramPassword = TextEditingController();
  final _username = TextEditingController(),
      _password = TextEditingController(),
      _claim = TextEditingController();
  bool _working = false, _obscure = true, _adding = false;
  late bool _register = widget.entry == SyncAccountEntry.register;
  bool get _fromSetup => widget.entry != SyncAccountEntry.settings;
  bool? _ownerCreated;
  String? _error;
  late String _knownServiceUrl;

  @override
  void initState() {
    super.initState();
    _knownServiceUrl = sync.serviceUrl;
    sync.addListener(_serviceChanged);
  }

  void _serviceChanged() {
    final endpoint = sync.serviceUrl;
    if (endpoint == _knownServiceUrl) return;
    _knownServiceUrl = endpoint;
    _url.text = endpoint;
    setState(() {
      _ownerCreated = null;
      _error = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not finish. Check your connection and retry. Your local library is kept.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _validate({bool connected = false}) => _run(() async {
    final endpoint = connected ? sync.serviceUrl : _url.text;
    final h = await sync.validateWorker(endpoint);
    if (!connected) await sync.rememberService(endpoint);
    if (!mounted) return;
    if (connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync Worker is reachable.')),
      );
    } else {
      setState(() {
        _ownerCreated = h['ownerCreated'] as bool?;
        if (_ownerCreated == false && !sync.signedIn) _register = true;
      });
    }
  });
  Future<void> _showCode(String code) async {
    if (!mounted) return;
    await showAuralisDialog<void>(
      context: context,
      builder: (c) => AuralisDialog(
        title: const Text('Save your recovery code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Keep this code somewhere private. It resets your password and is replaced after use.',
            ),
            const SizedBox(height: 12),
            SelectableText(code),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            child: const Text('Copy code'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _login() => _run(() async {
    FocusScope.of(context).unfocus();
    final code = await sync.signIn(
      _url.text,
      _username.text,
      _password.text,
      register: _register,
      claimKey: _claim.text,
    );
    await _finishSignIn(code);
  });

  Future<void> _finishSignIn(String? code) async {
    if (!mounted) return;
    _password.clear();
    _claim.clear();
    setState(() => _adding = false);
    if (code != null) await _showCode(code);
    if (mounted && _fromSetup) Navigator.of(context).pop();
  }

  Future<bool> _confirm(String title, String text) async =>
      await confirmAuralisAction(
        context,
        title: title,
        message: text,
        confirmLabel: 'Continue',
      ) ==
      true;

  Future<void> _signOut() async {
    final clear = await showAuralisDialog<bool>(
      context: context,
      builder: (c) => AuralisDialog(
        title: const Text('Sign out'),
        content: const Text(
          'Keep or clear the visible local library? Your account’s saved snapshot and cloud data are kept. Telegram sign-in stays on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Clear local'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep local'),
          ),
        ],
      ),
    );
    if (clear != null) await _run(() => sync.signOut(keepLocal: !clear));
  }

  Future<void> _delete() async {
    final field = TextEditingController();
    final pass = await showAuralisDialog<String>(
      context: context,
      builder: (c) => AuralisDialog(
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Permanently delete this account and its cloud library. Other users and Telegram sign-in are kept. Enter your password to confirm.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, field.text),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    field.dispose();
    if (pass != null) await _run(() => sync.deleteAccount(pass));
  }

  Future<void> _switch() async {
    final selected = await showAuralisDialog<String>(
      context: context,
      builder: (c) => AuralisDialog(
        title: const Text('Switch account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final user in sync.savedAccounts)
              AuralisChoiceTile(
                selected: user.identity == sync.account?.identity,
                leading: const Icon(Icons.person_rounded),
                title: Text(user.username),
                subtitle: Text(
                  '${Uri.parse(user.url).host}${user.expired ? ' · Sign in again' : ''}',
                ),
                onTap: () => Navigator.pop(c, user.identity),
                trailing: user.identity == sync.account?.identity
                    ? null
                    : IconButton(
                        tooltip: 'Forget saved account',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () =>
                            Navigator.pop(c, 'forget:${user.identity}'),
                      ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, 'add'),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Add account'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == 'add') {
      setState(() {
        _adding = true;
        _register = false;
        _username.clear();
        _password.clear();
      });
      return;
    }
    final forgetting = selected.startsWith('forget:'),
        id = forgetting ? selected.substring(7) : selected,
        user = sync.savedAccounts.where((p) => p.identity == id).firstOrNull;
    if (user == null) return;
    if (forgetting) {
      if (await _confirm(
        'Forget saved account?',
        'Remove this saved sign-in and synced snapshot from this device?',
      )) {
        await _run(() => sync.forgetAccount(user));
      }
      return;
    }
    if (user.identity == sync.account?.identity) return;
    if (user.expired || user.token.isEmpty) {
      setState(() {
        _adding = true;
        _register = false;
        _url.text = user.url;
        _username.text = user.username;
        _password.clear();
      });
      return;
    }
    await _run(() => sync.switchAccount(user));
    if (mounted) {
      _url.text = sync.serviceUrl;
      if (_fromSetup &&
          sync.account?.identity == user.identity &&
          sync.signedIn) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _recover() async {
    final username = TextEditingController(text: _username.text),
        code = TextEditingController(),
        password = TextEditingController();
    final values = await showAuralisDialog<List<String>>(
      context: context,
      builder: (c) => AuralisDialog(
        title: const Text('Recover account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Use your latest recovery code. All earlier sign-ins will be revoked.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: username,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: code,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Recovery code'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'New password',
                helperText: 'At least 10 characters',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(c, [username.text, code.text, password.text]),
            child: const Text('Recover'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    username.dispose();
    code.dispose();
    password.dispose();
    if (mounted && values != null) {
      await _run(() async {
        final result = await sync.recoverAccount(
          _url.text,
          values[0],
          values[1],
          values[2],
        );
        await _finishSignIn(result);
      });
    }
  }

  Widget _card(List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  Future<void> _approveTelegram(String id) async {
    final code = TextEditingController();
    final entered = await showAuralisDialog<String>(
      context: context,
      builder: (c) => AuralisDialog(
        title: const Text('Approve your new device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the six-digit code shown in Account & sync on your new device. Only approve a sign-in you started.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'New device code'),
              onSubmitted: (value) => Navigator.pop(c, value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, code.text),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), code.dispose);
    if (entered != null) {
      await _run(() => sync.approveTelegramDevice(id, entered.trim()));
    }
  }

  Widget _telegramCard(bool disabled) => _card([
    _sectionTitle(Icons.send_rounded, 'Telegram on your devices'),
    const SizedBox(height: 4),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Include Telegram account'),
      subtitle: const Text(
        'Connect the same Telegram account on your other devices with device approval.',
      ),
      value: sync.telegramIncluded,
      onChanged: disabled
          ? null
          : (value) => _run(() => sync.setTelegramIncluded(value)),
    ),
    if (sync.linkedTelegram case final profile?)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          profile['name'] as String,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    Text(sync.telegramSyncStatus),
    if (sync.telegramPairCode case final code?)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SelectableText(
            code,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: 7,
            ),
          ),
        ),
      ),
    if (sync.telegram?.state == 'authorizationStateWaitOtherDeviceConfirmation')
      TextButton(
        onPressed: disabled ? null : () => _run(sync.useTelegramPhoneSignIn),
        child: const Text('Use phone sign-in instead'),
      ),
    if (sync.telegramNeedsPassword) ...[
      const SizedBox(height: 12),
      TextField(
        controller: _telegramPassword,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !disabled,
        decoration: const InputDecoration(
          labelText: 'Telegram two-step password',
        ),
        onSubmitted: (value) => disabled
            ? null
            : _run(() async {
                await sync.submitTelegramPassword(value);
                if (mounted) _telegramPassword.clear();
              }),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: disabled
            ? null
            : () => _run(() async {
                await sync.submitTelegramPassword(_telegramPassword.text);
                if (mounted) _telegramPassword.clear();
              }),
        child: const Text('Finish Telegram sign-in'),
      ),
    ],
    for (final request in sync.telegramDeviceRequests)
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: OutlinedButton.icon(
          onPressed: disabled
              ? null
              : () => _approveTelegram(request['id'] as String),
          icon: const Icon(Icons.phonelink_lock_rounded),
          label: const Text('Approve new Telegram device'),
        ),
      ),
    if (sync.telegramSyncError case final error?)
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton.icon(
          onPressed: disabled ? null : () => _run(sync.syncTelegramAccount),
          icon: const Icon(Icons.sync_rounded),
          label: const Text('Check Telegram sync'),
        ),
        if (sync.linkedTelegram == null && sync.telegram?.ready == true)
          TextButton(
            onPressed: disabled
                ? null
                : () => _run(() => sync.setTelegramIncluded(true)),
            child: const Text('Link this Telegram account'),
          ),
      ],
    ),
    if (sync.telegramIncluded)
      const Text(
        'Keep Auralis open on a connected device to approve a new sign-in, or use phone sign-in.',
      ),
  ]);
  @override
  void dispose() {
    sync.removeListener(_serviceChanged);
    _telegramPassword.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _claim.dispose();
    super.dispose();
  }

  Widget _sectionTitle(IconData icon, String title) => Row(
    children: [
      Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 10),
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    ],
  );

  Widget _workerCard(bool disabled, {required bool connected}) => _card([
    _sectionTitle(
      Icons.dns_outlined,
      _fromSetup ? 'Your Sync Worker' : 'Self-hosted Sync Worker',
    ),
    const SizedBox(height: 12),
    if (connected) ...[
      Text(
        'Cloudflare Worker URL',
        style: Theme.of(context).textTheme.labelMedium,
      ),
      const SizedBox(height: 4),
      SelectableText(sync.serviceUrl),
      const SizedBox(height: 8),
    ] else ...[
      if (_fromSetup) ...[
        const Text('Use the Worker URL for your Auralis account.'),
        const SizedBox(height: 12),
      ],
      TextField(
        key: const ValueKey('sync-worker-url'),
        controller: _url,
        enabled: !disabled && (!sync.signedIn || _adding),
        keyboardType: TextInputType.url,
        onChanged: (_) {
          if (_ownerCreated != null) {
            setState(() => _ownerCreated = null);
          }
        },
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Cloudflare Worker URL',
          prefixIcon: Icon(Icons.link_rounded),
          hintText: 'https://auralis-sync.example.workers.dev',
        ),
      ),

      const SizedBox(height: 12),
    ],
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        OutlinedButton.icon(
          onPressed: disabled ? null : () => _validate(connected: connected),
          icon: const Icon(Icons.verified_outlined),
          label: Text(
            connected ? 'Check connection' : 'Validate and use Worker',
          ),
        ),
        if (sync.deploymentVault != null &&
            (!sync.signedIn || sync.account!.admin)) ...[
          TextButton.icon(
            onPressed: disabled
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SyncDeploymentPage(sync: sync),
                    ),
                  ),
            icon: const Icon(Icons.rocket_launch_rounded),
            label: const Text('Deploy Database'),
          ),
        ],
      ],
    ),
  ]);

  Widget _profileLink(bool disabled, String endpoint) => TextButton.icon(
    onPressed: disabled
        ? null
        : () => _run(
            () => openExternalLink(
              '${SyncController.normalize(endpoint)}/profile',
            ),
          ),
    icon: const Icon(Icons.open_in_new_rounded),
    label: const Text('Account recovery & administration'),
  );

  Widget _accountActions(bool disabled) => _card([
    _sectionTitle(Icons.manage_accounts_outlined, 'Manage account'),
    const SizedBox(height: 8),
    Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        TextButton.icon(
          onPressed: disabled ? null : _switch,
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text('Switch account'),
        ),
        TextButton.icon(
          onPressed: disabled ? null : _signOut,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Sign out'),
        ),
      ],
    ),
    if (sync.serviceUrl.isNotEmpty)
      Align(
        alignment: Alignment.centerLeft,
        child: _profileLink(disabled, sync.serviceUrl),
      ),
    const Divider(height: 16),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: disabled ? null : _delete,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        icon: const Icon(Icons.delete_outline_rounded),
        label: const Text('Delete account'),
      ),
    ),
  ]);

  Widget _syncOverview(bool disabled, Widget feedback) {
    final account = sync.account!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _card([
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              Icons.cloud_sync_rounded,
              color: colors.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.username, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  '${sync.workerName}${account.admin ? ' · Administrator' : ''}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Semantics(
        liveRegion: true,
        child: Text(sync.status, style: theme.textTheme.bodyLarge),
      ),
      feedback,
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          FilledButton.icon(
            onPressed: disabled ? null : () => _run(sync.uploadLocalChanges),
            icon: const Icon(Icons.sync_rounded),
            label: const Text('Sync now'),
          ),
          FilledButton.tonalIcon(
            onPressed: disabled ? null : () => _run(sync.restoreCloudCopy),
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('Merge cloud copy'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        'Favorites, playlists, listening history, channels and shared preferences sync across your devices. Music files, volume and playback stay on this device.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    ]);
  }

  Widget _credentials(bool disabled) => _card([
    Text(
      _register
          ? (_ownerCreated == false ? 'Create owner account' : 'Create account')
          : 'Sign in',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('sync-username'),
      controller: _username,
      enabled: !disabled,
      autocorrect: false,
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(
        labelText: 'Username',
        prefixIcon: Icon(Icons.person_rounded),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('sync-password'),
      controller: _password,
      enabled: !disabled,
      obscureText: _obscure,
      autocorrect: false,
      enableSuggestions: false,
      onSubmitted: (_) => disabled ? null : _login(),
      decoration: InputDecoration(
        labelText: 'Password',
        helperText: _register ? 'At least 10 characters' : null,
        prefixIcon: const Icon(Icons.lock_rounded),
        suffixIcon: IconButton(
          tooltip: _obscure ? 'Show password' : 'Hide password',
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          ),
        ),
      ),
    ),
    if (_register && _ownerCreated != true) ...[
      const SizedBox(height: 12),
      TextField(
        controller: _claim,
        enabled: !disabled,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Existing sync key / owner setup secret',
          helperText: 'Filled automatically on the deploying device.',
        ),
      ),
    ],
    const SizedBox(height: 16),
    if (_fromSetup && _error != null)
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Semantics(
          liveRegion: true,
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    FilledButton(
      onPressed: disabled ? null : _login,
      child: Text(_register ? 'Create account' : 'Sign in'),
    ),
    TextButton(
      onPressed: disabled ? null : () => setState(() => _register = !_register),
      child: Text(
        _register ? 'Already have an account? Sign in' : 'Create an account',
      ),
    ),
    TextButton(
      onPressed: disabled ? null : _recover,
      child: const Text('Recover with recovery code'),
    ),
    if (sync.savedAccounts.isNotEmpty)
      TextButton(
        onPressed: disabled ? null : _switch,
        child: const Text('Switch account'),
      ),
    if (_adding)
      TextButton(
        onPressed: disabled
            ? null
            : () => setState(() {
                _adding = false;
                _url.text = sync.serviceUrl;
                _error = null;
                _ownerCreated = null;
              }),
        child: const Text('Cancel'),
      ),
  ]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      final disabled = _working || sync.busy;
      final connected = sync.signedIn && !_adding;
      final error =
          (_fromSetup && !connected ? null : _error) ??
          sync.error ??
          sync.deploymentError ??
          sync.workerUpdateError;
      final feedback = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (disabled || sync.syncing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      );
      return PopScope<Object?>(
        canPop: !disabled,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_fromSetup ? 'Connect Worker Sync' : 'Account & sync'),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: connected ? 1080 : 620),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final worker = _workerCard(disabled, connected: connected);
                    final main = [
                      if (connected) ...[
                        _syncOverview(disabled, feedback),
                        if (sync.telegramSyncAvailable) _telegramCard(disabled),
                      ] else ...[
                        worker,
                        feedback,
                        _credentials(disabled),
                        if (sync.serviceUrl.isNotEmpty)
                          _profileLink(disabled, _url.text),
                      ],
                    ];
                    final secondary = [
                      worker,
                      if (connected) _accountActions(disabled),
                    ];
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      children: [
                        if (connected && box.maxWidth >= 820)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 6, child: Column(children: main)),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 4,
                                child: Column(children: secondary),
                              ),
                            ],
                          )
                        else ...[
                          ...main,
                          if (connected) ...secondary,
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
