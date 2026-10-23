import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'data_backup.dart';
import 'account_backup.dart';
import 'telegram/telegram_service.dart';
import 'data_files.dart';
import 'listening.dart';
import 'player.dart';

class StatsDataDialog extends StatefulWidget {
  const StatsDataDialog({
    super.key,
    required this.player,
    this.files = const DataFiles(),
    this.onRestored,
    this.telegram,
    this.openBackupSection = false,
  });
  final PlayerController player;
  final TelegramService? telegram;
  final DataFiles files;
  final Future<void> Function()? onRestored;
  final bool openBackupSection;
  @override
  State<StatsDataDialog> createState() => _StatsDataDialogState();
}

class _StatsDataDialogState extends State<StatsDataDialog> {
  late ListeningStats _stats;
  bool _busy = false, _error = false, _confirming = false;
  String? _status;
  bool? _includeAccount;
  bool get _withAccount => _includeAccount ?? widget.telegram?.ready == true;
  PlayerController get player => widget.player;
  String get _recovery =>
      p.join(player.settings.file.parent.path, 'auralis-before-restore.json');
  @override
  void initState() {
    super.initState();
    _snapshot();
    widget.telegram?.addListener(_telegramChanged);
  }

  void _telegramChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.telegram?.removeListener(_telegramChanged);
    super.dispose();
  }

  void _snapshot() =>
      _stats = ListeningStats.fromJson(player.settings.listening.toJson());

  Future<void> _run(
    Future<void> Function() action, {
    String operation = 'Operation',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = false;
      _status = null;
    });
    try {
      await action();
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = e.message;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = '$operation failed (${e.code}). '
              '${e.message ?? 'Choose the file again and retry.'}';
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _error = true;
          _status = '$operation failed. Restart Auralis after installing the '
              'latest update so Android file access is available.';
        });
      }
    } on FileSystemException catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = '$operation failed while accessing local storage '
              '(OS error ${e.osError?.errorCode ?? 'unknown'}). '
              'Check available storage and choose the file again.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = '$operation failed (${e.runtimeType}). Please retry.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _snapshot();
        });
      }
    }
  }

  Future<String?> _destination(String name, String extension) async {
    final path = await widget.files.savePath(name, extension);
    if (path == null) return null;
    String normalized(String value) {
      final result = p.normalize(File(value).absolute.path);
      return Platform.isWindows ? result.toLowerCase() : result;
    }

    final support = normalized(player.settings.file.parent.path);
    final destination = normalized(path);
    if (support == destination || p.isWithin(support, destination)) {
      throw const FormatException(
        'Choose a destination outside Auralis’s internal app-data folder.',
      );
    }
    return path;
  }

  Future<void> _export(String extension) => _run(() async {
    final path = await _destination(
      'auralis-listening-${listeningDate(DateTime.now())}.$extension',
      extension,
    );
    if (path == null) return;
    await player.flushListeningStats(failOnError: true);
    final stats = ListeningStats.fromJson(player.settings.listening.toJson());
    final text = extension == 'csv'
        ? stats.toCsv()
        : const JsonEncoder.withIndent('  ').convert({
            'format': 'auralis-listening-stats',
            'version': 1,
            'exportedAt': DateTime.now().toUtc().toIso8601String(),
            'data': stats.toJson(),
          });
    await widget.files.write(path, text);
    if (mounted) setState(() => _status = 'Listening data exported.');
  });

  Future<String?> _password({required bool creating}) async {
    final password = TextEditingController();
    final repeat = TextEditingController();
    String? error;
    setState(() => _confirming = true);
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(
              creating ? 'Protect your Telegram backup' : 'Unlock backup',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    creating
                        ? 'Choose a password of at least 10 characters. You will need it to restore your Telegram sign-in. Auralis does not save this password.'
                        : 'Enter the password used when this backup was created.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Backup password',
                    ),
                  ),
                  if (creating) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: repeat,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                      ),
                    ),
                  ],
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (password.text.isEmpty ||
                      password.text.length > 1024 ||
                      (creating &&
                          (password.text.length < 10 ||
                              password.text != repeat.text))) {
                    update(
                      () => error = creating
                          ? 'Use at least 10 characters and matching passwords.'
                          : 'Enter your backup password.',
                    );
                    return;
                  }
                  Navigator.pop(context, password.text);
                },
                child: Text(creating ? 'Create backup' : 'Unlock'),
              ),
            ],
          ),
        ),
      );
    } finally {
      // Dispose after the closing route animation no longer uses these fields.
      Future<void>.delayed(const Duration(seconds: 1), () {
        password.dispose();
        repeat.dispose();
      });
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _backup() => _run(() async {
    final path = await _destination(
      'auralis-backup-${listeningDate(DateTime.now())}.json',
      'json',
    );
    if (path == null) return;
    await player.flushListeningStats(failOnError: true);
    final data = DataBackup.create(player.settings, DateTime.now());
    String text;
    if (_withAccount && widget.telegram != null) {
      final password = await _password(creating: true);
      if (password == null) return;
      // Pause streaming before closing TDLib to take a consistent snapshot.
      if (player.audio.playing) await player.audio.toggle();
      final account = await widget.telegram!.backupAccount();
      text = await encryptAccountBackup(data, account, password);
    } else {
      text = data.encode();
      DataBackup.parse(text);
    }
    await widget.files.write(path, text);
    if (mounted) {
      setState(
        () => _status = AccountBackup.isEncrypted(text)
            ? 'Backup saved with your Telegram sign-in. Keep the backup password.'
            : 'Settings backup saved. This file does not contain your Telegram sign-in.',
      );
    }
  });

  Future<void> _restore({bool recovery = false}) => _run(() async {
    final path = recovery ? _recovery : await widget.files.openBackup();
    if (path == null) return;
    final text = await widget.files.read(path);
    TelegramAccount? account;
    DataBackup backup;
    if (AccountBackup.isEncrypted(text)) {
      final password = await _password(creating: false);
      if (password == null) return;
      final bundle = await decryptAccountBackup(text, password);
      backup = bundle.data;
      account = bundle.account;
      if (account != null && widget.telegram == null) {
        throw const FormatException('Telegram account restore is unavailable.');
      }
    } else {
      backup = DataBackup.parse(text);
    }
    final stats = ListeningStats.fromJson(backup.snapshot['listening']);
    if (!mounted) return;
    setState(() => _confirming = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: SingleChildScrollView(
          child: Text(
            'Created ${backup.createdAt.toLocal()}\n\n'
            '${(backup.snapshot['favoriteIds'] as List).length} favorites · ${(backup.snapshot['playlists'] as Map).length} playlists\n'
            '${listeningTime(stats.milliseconds)} listened · ${stats.plays} qualified plays\n\n'
            'This replaces local stats, collections and preferences. Playback and the queue will stop. '
            'Your current settings are saved as a recovery copy first. Music files are kept. '
            '${account != null ? 'Telegram sign-in: included. This replaces the local account with the saved session. Telegram may require reauthentication if that session has expired or been revoked.' : 'Telegram sign-in: not included. This file can only restore settings and collections. Your current sign-in is kept.'}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (mounted) setState(() => _confirming = false);
    if (confirmed != true || !mounted) return;
    if (account != null) {
      await player.clear();
      await widget.telegram!.restoreAccount(
        account,
        () => player.restoreBackup(backup),
      );
    } else {
      await player.restoreBackup(backup);
    }
    var refreshFailed = false;
    try {
      await widget.onRestored?.call();
    } catch (_) {
      // The restore is already committed; a refresh failure must not report
      // that the backup itself failed or encourage a second replacement.
      refreshFailed = true;
    }
    if (mounted) {
      setState(() {
        final telegram = widget.telegram;
        _error = account != null && telegram?.error != null;
        _status = account == null
            ? 'Settings restored. This backup has no Telegram sign-in; connect Telegram or restore a password-protected account backup.'
            : telegram!.error != null
            ? 'Settings and Telegram session restored, but Telegram could not reconnect. ${telegram.error}'
            : telegram.ready
            ? 'Settings and Telegram sign-in restored.'
            : 'Settings and Telegram session restored. Reconnecting; check the Telegram screen for connection or sign-in progress.';
        if (refreshFailed) {
          _status = '$_status Reopen the Library to refresh your music.';
        }
      });
    }
  }, operation: 'Restore');

  @override
  Widget build(BuildContext context) {
    final artists = _stats.topArtists, tracks = _stats.topTracks;
    final today = DateTime.now();
    final dates = [
      for (var i = 6; i >= 0; i--)
        listeningDate(DateTime(today.year, today.month, today.day - i)),
    ];
    final maximum = dates.fold<int>(
      1,
      (value, date) => math.max(value, _stats.days[date]?.milliseconds ?? 0),
    );
    return Dialog(
      child: SizedBox(
        width: 860,
        height: math.min(700, MediaQuery.sizeOf(context).height * .9),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.openBackupSection
                          ? 'Backup & Restore'
                          : 'Listening stats',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh listening stats',
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await player.flushListeningStats(failOnError: true);
                          }),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (_busy && !_confirming)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.openBackupSection) ...[
                      const Text(
                        'All-time snapshot · Refresh to update.',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, box) => Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (label, value) in [
                              ('Listened', listeningTime(_stats.milliseconds)),
                              ('Qualified plays', '${_stats.plays}'),
                              ('Tracks heard', '${_stats.tracks.length}'),
                              ('Artists heard', '${artists.length}'),
                            ])
                              SizedBox(
                                width:
                                    (box.maxWidth -
                                        (box.maxWidth < 560 ? 8 : 24)) /
                                    (box.maxWidth < 560 ? 2 : 4),
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          label,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          value,
                                          style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'A play counts after 30 seconds, or half of a shorter track. Pauses, buffering, seeks and long inactive gaps do not add listening time.',
                        style: TextStyle(fontSize: 11),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Daily activity · last 7 days',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      for (final date in dates)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 48,
                                child: Text(
                                  date.substring(5),
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                              Expanded(
                                child: Semantics(
                                  label:
                                      '$date: ${listeningTime(_stats.days[date]?.milliseconds ?? 0)}',
                                  child: LinearProgressIndicator(
                                    value:
                                        (_stats.days[date]?.milliseconds ?? 0) /
                                        maximum,
                                    minHeight: 8,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  listeningTime(
                                    _stats.days[date]?.milliseconds ?? 0,
                                  ),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (tracks.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Play some music to build your listening stats. Earlier recent history is not estimated.',
                          ),
                        ),
                      if (tracks.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Top tracks · all time',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        for (final entry in tracks.take(10))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              entry.value.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${entry.value.artist} · ${entry.value.plays} plays',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              listeningTime(entry.value.milliseconds),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        const SizedBox(height: 12),
                        const Text(
                          'Top artists · all time',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        for (final artist in artists.take(10))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              artist.key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              listeningTime(artist.value),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      const Divider(height: 28),
                      const Text(
                        'Export listening data',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _busy ? null : () => _export('csv'),
                            icon: const Icon(Icons.table_chart_outlined),
                            label: const Text('Export CSV'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _export('json'),
                            icon: const Icon(Icons.file_download_outlined),
                            label: const Text('Export JSON'),
                          ),
                        ],
                      ),
                      const Divider(height: 28),
                    ],
                    if (!widget.openBackupSection)
                      const Text(
                        'Backup & Restore',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'Includes stats, favorites, playlists, recent music, channels and preferences. Add your Telegram sign-in with a password-protected account backup. Music files and the queue are excluded.',
                      style: TextStyle(fontSize: 12),
                    ),
                    if (widget.telegram != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Include Telegram account'),
                        subtitle: Text(
                          widget.telegram!.ready
                              ? 'Password protected · briefly pauses playback and reconnects Telegram'
                              : 'Connect Telegram to include your sign-in',
                        ),
                        value: _withAccount,
                        onChanged: _busy || !widget.telegram!.ready
                            ? null
                            : (value) =>
                                  setState(() => _includeAccount = value),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : _backup,
                          icon: const Icon(Icons.backup_outlined),
                          label: const Text('Create backup'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _restore(),
                          icon: const Icon(Icons.restore_rounded),
                          label: const Text('Restore backup'),
                        ),
                        if (File(_recovery).existsSync())
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _restore(recovery: true),
                            child: const Text('Restore recovery copy'),
                          ),
                      ],
                    ),
                    if (_status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _status!,
                          style: TextStyle(
                            color: _error
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
