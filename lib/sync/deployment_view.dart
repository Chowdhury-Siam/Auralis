import 'dart:convert';

import 'package:flutter/material.dart';

import '../external_links.dart';
import 'controller.dart';
import 'deployment.dart';
import 'document.dart';

class SyncDeploymentPage extends StatefulWidget {
  const SyncDeploymentPage({super.key, required this.sync});
  final SyncController sync;
  @override
  State<SyncDeploymentPage> createState() => _SyncDeploymentPageState();
}

class _SyncDeploymentPageState extends State<SyncDeploymentPage> {
  final _fields = {
    for (final key in [
      'worker',
      'account',
      'cloudflareToken',
      'database',
      'databaseToken',
      'key',
    ])
      key: TextEditingController(),
  };
  final _visible = <String>{};
  final _deployment = SyncDeployment();
  bool _busy = true, _loaded = false, _automatic = true;
  String? _error, _savedVersion;
  String _status = 'Loading saved deployment…';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final profile = await widget.sync.deploymentProfile();
      if (!mounted) return;
      if (profile['locked'] == true) {
        setState(() {
          _loaded = false;
          _error = 'Sign in as the Worker owner to view saved deployment credentials.';
        });
        return;
      }
      for (final entry in _fields.entries) {
        entry.value.text = profile[entry.key] is String
            ? profile[entry.key] as String
            : '';
      }
      if (_fields['worker']!.text.isEmpty) {
        _fields['worker']!.text = 'auralis-sync';
      }
      if (_fields['key']!.text.isEmpty && widget.sync.legacyConnection) {
        final connection =
            jsonDecode(await widget.sync.connectionDetails()) as Map;
        if (!mounted) return;
        _fields['key']!.text = connection['key'] as String;
      }
      if (_fields['key']!.text.isEmpty && widget.sync.serviceUrl.isEmpty) {
        _fields['key']!.text = newSyncKey();
      }
      _savedVersion = profile['version'] as String?;
      _automatic = profile['automatic'] != false;
      setState(() {
        _loaded = true;
        _error = null;
        _status = _savedVersion == null
            ? 'Ready to deploy your Auralis Worker.'
            : 'Saved Worker $_savedVersion · bundled Worker $currentSyncWorkerVersion';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not unlock saved deployment values. Retry, or sign in as owner to recover them.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _begin() {
    if (widget.sync.beginWorkerOperation()) return true;
    setState(
      () => _error = 'Wait for the current account or Worker operation.',
    );
    return false;
  }

  Future<void> _deploy() async {
    if (!_begin()) return;
    final config = SyncDeploymentConfig(
      worker: _fields['worker']!.text,
      account: _fields['account']!.text,
      cloudflareToken: _fields['cloudflareToken']!.text,
      database: _fields['database']!.text,
      databaseToken: _fields['databaseToken']!.text,
      key: _fields['key']!.text,
      automatic: _automatic,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      config.validate();
      await widget.sync.saveDeploymentProfile({
        ...config.toJson(),
        'version': _savedVersion,
      });
      final url = await _deployment.deploy(config, (s) {
            if (mounted) setState(() => _status = s);
          }),
          profile = {
            ...config.toJson(),
            'url': url,
            'version': currentSyncWorkerVersion,
          };
      await widget.sync.saveDeploymentProfile(profile);
      await widget.sync.rememberService(url);
      await widget.sync.saveRecoveryDeployment(profile);
      if (mounted) {
        setState(() {
          _savedVersion = currentSyncWorkerVersion;
          _status = widget.sync.signedIn && widget.sync.url == url
              ? 'Worker updated. Your account remains signed in.'
              : 'Deployed. Return to Account & sync to create the owner account or sign in.';
        });
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Deployment did not finish. Check Cloudflare permissions, Turso write token and your connection. Retry with the same JWT secret; saved values and cloud data are kept.',
        );
      }
    } finally {
      widget.sync.endWorkerOperation();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAutomatic(bool value) async {
    if (!_begin()) return;
    var localSaved = false;
    setState(() {
      _busy = true;
      _automatic = value;
      _error = null;
    });
    try {
      final profile = await widget.sync.deploymentProfile(),
          saved = {...profile, 'automatic': value};
      await widget.sync.saveDeploymentProfile(saved);
      localSaved = true;
      await widget.sync.saveRecoveryDeployment(saved);
    } catch (_) {
      if (mounted) {
        setState(() {
          if (!localSaved) _automatic = !value;
          _error = localSaved
              ? 'Saved on this device. The recovery copy could not be updated; retry when connected.'
              : 'Could not save the preference. Retry.';
        });
      }
    } finally {
      widget.sync.endWorkerOperation();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Forget deployment credentials?'),
        content: const Text(
          'Remove deployment values from this device and, when signed in as owner, from its recovery vault. Automatic updates will need these values again. Your account and library are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Forget credentials'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted || !_begin()) return;
    setState(() => _busy = true);
    try {
      await widget.sync.forgetDeploymentCredentials();
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not forget credentials. Check your connection and retry.',
        );
      }
    } finally {
      widget.sync.endWorkerOperation();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recover() async {
    if (!_begin()) return;
    setState(() => _busy = true);
    try {
      await widget.sync.recoverDeploymentCredentials();
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not recover saved values. Check your connection and retry.',
        );
      }
    } finally {
      widget.sync.endWorkerOperation();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link(String url) async {
    try {
      await openExternalLink(url);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not open the browser. Visit $url to continue.',
        );
      }
    }
  }

  Widget _field(
    String key,
    String label,
    IconData icon, {
    bool secret = false,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey('deploy-$key'),
      controller: _fields[key],
      enabled: !_busy,
      obscureText: secret && !_visible.contains(key),
      autocorrect: false,
      enableSuggestions: false,
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: secret
            ? IconButton(
                tooltip: _visible.contains(key) ? 'Hide $label' : 'Show $label',
                onPressed: _busy
                    ? null
                    : () => setState(
                        () => _visible.contains(key)
                            ? _visible.remove(key)
                            : _visible.add(key),
                      ),
                icon: Icon(
                  _visible.contains(key)
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
              )
            : null,
      ),
    ),
  );
  Widget _step(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  @override
  void dispose() {
    _deployment.close();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Deploy Database'),
            Text(
              'Deploy the Auralis Worker from this app',
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
                _step('1. Get your Cloudflare values', [
                  const Text(
                    'Copy your Cloudflare Account ID and create an API token with Workers Scripts Edit permission. Your account must already have a workers.dev subdomain.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _link('https://dash.cloudflare.com/'),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open Cloudflare'),
                  ),
                ]),
                _step('2. Get your Turso values', [
                  const Text(
                    'Create or open a Turso database. Copy its libsql://…turso.io URL and a read/write database authentication token. Auralis prepares the required tables during deployment.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _link('https://app.turso.tech/'),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open Turso'),
                  ),
                ]),
                _step('3. Enter deployment values', [
                  const Text(
                    'Auralis can protect deployment credentials on this device so your Worker updates automatically when an app update includes a newer Worker.',
                  ),
                  const SizedBox(height: 16),
                  _field(
                    'worker',
                    'Cloudflare Worker name',
                    Icons.cloud_rounded,
                  ),
                  _field(
                    'account',
                    'Cloudflare Account ID',
                    Icons.badge_rounded,
                  ),
                  _field(
                    'cloudflareToken',
                    'Cloudflare API token',
                    Icons.key_rounded,
                    secret: true,
                  ),
                  _field(
                    'database',
                    'Turso Database URL',
                    Icons.storage_rounded,
                    hint: 'libsql://auralis-yourname.turso.io',
                  ),
                  _field(
                    'databaseToken',
                    'Turso auth token',
                    Icons.key_rounded,
                    secret: true,
                  ),
                  _field(
                    'key',
                    'JWT secret',
                    Icons.shield_rounded,
                    secret: true,
                  ),
                  TextButton.icon(
                    onPressed:
                        _busy ||
                            _savedVersion != null ||
                            widget.sync.serviceUrl.isNotEmpty
                        ? null
                        : () => setState(
                            () => _fields['key']!.text = newSyncKey(),
                          ),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('Generate secure JWT secret'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Keep the same secret, Worker name and database when redeploying. For an existing private-key Worker, use its existing sync key as the JWT secret.',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'The first account becomes the administrator. Signing in as that owner after reinstalling recovers the saved deployment values from its encrypted Worker recovery vault.',
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Automatic Worker updates'),
                    subtitle: const Text(
                      'Keep deployment credentials on this device and redeploy when this app contains a newer Worker.',
                    ),
                    value: _automatic,
                    onChanged: _busy ? null : _setAutomatic,
                  ),
                  if (widget.sync.account?.admin == true)
                    TextButton.icon(
                      onPressed: _busy ? null : _recover,
                      icon: const Icon(Icons.cloud_download_rounded),
                      label: const Text('Recover saved deployment values'),
                    ),
                  TextButton.icon(
                    onPressed: _busy ? null : _forget,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Forget saved deployment credentials'),
                  ),
                ]),
                if (_busy) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(_status),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy || !_loaded ? null : _deploy,
                  icon: const Icon(Icons.rocket_launch_rounded),
                  label: const Text('Deploy Worker'),
                ),
                if (!_loaded)
                  TextButton(
                    onPressed: _busy ? null : _load,
                    child: const Text('Retry loading'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
