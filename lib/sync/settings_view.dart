import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../external_links.dart';
import 'controller.dart';
import 'deployment_view.dart';

class SyncSettings extends StatelessWidget {
  const SyncSettings({super.key, required this.controller});
  final SyncController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Card(
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const Icon(Icons.cloud_sync_rounded),
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
    ),
  );
}

class SyncAccountPage extends StatefulWidget {
  const SyncAccountPage({super.key, required this.sync});
  final SyncController sync;
  @override
  State<SyncAccountPage> createState() => _SyncAccountPageState();
}

class _SyncAccountPageState extends State<SyncAccountPage> {
  SyncController get sync => widget.sync;
  late final _url = TextEditingController(text: sync.serviceUrl);
  final _username = TextEditingController(),
      _password = TextEditingController(),
      _claim = TextEditingController();
  bool _working = false, _register = false, _obscure = true, _adding = false;
  bool? _ownerCreated;
  String? _error;
  Future<void> _run(Future<void> Function() action) async {
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

  Future<void> _validate() => _run(() async {
    final h = await sync.validateWorker(_url.text);
    await sync.rememberService(_url.text);
    if (mounted) setState(() => _ownerCreated = h['ownerCreated'] == true);
  });
  Future<void> _showCode(String code) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save your recovery code'),
        content: SingleChildScrollView(
          child: Column(
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
    final code = await sync.signIn(
      _url.text,
      _username.text,
      _password.text,
      register: _register,
      claimKey: _claim.text,
    );
    if (!mounted) return;
    _password.clear();
    _claim.clear();
    setState(() => _adding = false);
    if (code != null) await _showCode(code);
  });
  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _restore() async {
    if (await _confirm(
      'Restore cloud copy?',
      'Replace shared local fields with this account’s cloud copy. A protected local snapshot is retained.',
    )) {
      await _run(sync.restoreCloudCopy);
    }
  }

  Future<void> _signOut() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
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
    final pass = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
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
          TextButton(
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
    final selected = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Switch account'),
        children: [
          for (final user in sync.savedAccounts)
            ListTile(
              leading: Icon(
                user.identity == sync.account?.identity
                    ? Icons.check_circle_rounded
                    : Icons.person_rounded,
              ),
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
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'add'),
            child: const Text('Add account'),
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
    if (mounted) _url.text = sync.serviceUrl;
  }

  Future<void> _recover() async {
    final username = TextEditingController(text: _username.text),
        code = TextEditingController(),
        password = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Recover account'),
        content: SingleChildScrollView(
          child: Column(
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
    if (values != null) {
      await _run(() async {
        final result = await sync.recoverAccount(
          _url.text,
          values[0],
          values[1],
          values[2],
        );
        if (mounted) {
          setState(() => _adding = false);
          await _showCode(result);
        }
      });
    }
  }

  Widget _card(List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _claim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      final disabled = _working || sync.busy;
      return PopScope<Object?>(
        canPop: !disabled,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Account & sync'),
                if (sync.signedIn)
                  Text(
                    sync.account!.username,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _card([
                      const Text(
                        'Self-hosted Sync Worker',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('sync-worker-url'),
                        controller: _url,
                        enabled: !disabled && (!sync.signedIn || _adding),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Cloudflare Worker URL',
                          prefixIcon: Icon(Icons.link_rounded),
                          hintText: 'https://auralis-sync.example.workers.dev',
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: disabled ? null : _validate,
                        icon: const Icon(Icons.verified_rounded),
                        label: const Text('Validate and use Worker'),
                      ),
                      if (sync.deploymentVault != null &&
                          (!sync.signedIn || sync.account!.admin)) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: disabled
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        SyncDeploymentPage(sync: sync),
                                  ),
                                ),
                          icon: const Icon(Icons.rocket_launch_rounded),
                          label: const Text('Deploy Database'),
                        ),
                      ],
                    ]),
                    if (sync.signedIn && !_adding) ...[
                      _card([
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.cloud_done_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 36,
                          ),
                          title: Text(
                            sync.workerName,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(sync.status),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          key: ValueKey(('signed-sync-user', sync.account!.id)),
                          readOnly: true,
                          initialValue: sync.account!.username,
                          decoration: InputDecoration(
                            labelText:
                                'Username${sync.account!.admin ? ' · Administrator' : ''}',
                            prefixIcon: const Icon(Icons.person_rounded),
                          ),
                        ),
                      ]),
                      LayoutBuilder(
                        builder: (context, box) {
                          final buttons = [
                            FilledButton.tonalIcon(
                              onPressed: disabled ? null : _restore,
                              icon: const Icon(Icons.cloud_download_rounded),
                              label: const Text('Restore cloud copy'),
                            ),
                            OutlinedButton.icon(
                              onPressed: disabled
                                  ? null
                                  : () => _run(sync.uploadLocalChanges),
                              icon: const Icon(Icons.cloud_upload_rounded),
                              label: const Text('Upload local changes'),
                            ),
                          ];
                          return box.maxWidth < 340
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    buttons[0],
                                    const SizedBox(height: 8),
                                    buttons[1],
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(child: buttons[0]),
                                    const SizedBox(width: 8),
                                    Expanded(child: buttons[1]),
                                  ],
                                );
                        },
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: disabled ? null : _switch,
                        icon: const Icon(Icons.swap_horiz_rounded),
                        label: const Text('Switch account'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: disabled ? null : _signOut,
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Sign out'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: disabled ? null : _delete,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        icon: const Icon(Icons.delete_forever_rounded),
                        label: const Text('Delete account'),
                      ),
                    ] else
                      _card([
                        Text(
                          _register ? 'Create account' : 'Sign in',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('sync-username'),
                          controller: _username,
                          enabled: !disabled,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            prefixIcon: Icon(Icons.person_rounded),
                          ),
                          onSubmitted: (_) => disabled ? null : _login(),
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
                            helperText: _register
                                ? 'At least 10 characters'
                                : null,
                            prefixIcon: const Icon(Icons.lock_rounded),
                            suffixIcon: IconButton(
                              tooltip: _obscure
                                  ? 'Show password'
                                  : 'Hide password',
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_rounded
                                    : Icons.visibility_off_rounded,
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
                              labelText:
                                  'Existing sync key / owner setup secret',
                              helperText: 'Filled automatically on the deploying device.',
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: disabled ? null : _login,
                          child: Text(_register ? 'Create account' : 'Sign in'),
                        ),
                        TextButton(
                          onPressed: disabled
                              ? null
                              : () => setState(() => _register = !_register),
                          child: Text(
                            _register
                                ? 'Already have an account? Sign in'
                                : 'Create an account',
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
                                : () => setState(() => _adding = false),
                            child: const Text('Cancel'),
                          ),
                      ]),
                    if (disabled || sync.syncing)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (_error ?? sync.error ?? sync.deploymentError
                        case final String error)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Favorites, playlists, recent music, listening statistics, channels and shared preferences sync. Telegram sign-in, music, volume and playback stay on this device.',
                    ),
                    if (sync.serviceUrl.isNotEmpty)
                      TextButton.icon(
                        onPressed: disabled
                            ? null
                            : () => _run(
                                () => openExternalLink(
                                  '${SyncController.normalize(_url.text)}/profile',
                                ),
                              ),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Account recovery & administration'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
