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
    this.fullscreen = false,
  });
  final PlayerController player;
  final TelegramService? telegram;
  final DataFiles files;
  final Future<void> Function()? onRestored;
  final bool openBackupSection, fullscreen;
  @override
  State<StatsDataDialog> createState() => _StatsDataDialogState();
}

class _StatsDataDialogState extends State<StatsDataDialog> {
  late ListeningStats _stats;
  bool _busy = false, _error = false, _confirming = false;
  bool _showArtists = false, _chartPlays = false;
  _StatsRange _range = _StatsRange.all;
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
          _status =
              '$operation failed (${e.code}). '
              '${e.message ?? 'Choose the file again and retry.'}';
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _error = true;
          _status =
              '$operation failed. Restart Auralis after installing the '
              'latest update so Android file access is available.';
        });
      }
    } on FileSystemException catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status =
              '$operation failed while accessing local storage '
              '(OS error ${e.osError?.errorCode ?? 'unknown'}). '
              'Check available storage and choose the file again.';
        });
      }
    } on UnsupportedError catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = '$operation failed: ${e.message}';
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

  Widget _metricCard(
    String label,
    String value,
    IconData icon, {
    bool second = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = second
        ? colors.onTertiaryContainer
        : colors.onPrimaryContainer;
    return _StatsPanel(
      color: second ? colors.tertiaryContainer : colors.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(height: 6),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: foreground),
          ),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _overview(int milliseconds, int plays) => LayoutBuilder(
    key: const ValueKey('stats-summary'),
    builder: (context, box) {
      final time = _metricCard(
        'Listened',
        listeningTime(milliseconds),
        Icons.headphones_rounded,
      );
      final count = Tooltip(
        message: 'A play counts after 30 seconds, or half of a shorter track.',
        child: _metricCard(
          'Plays',
          '$plays',
          Icons.play_circle_outline_rounded,
          second: true,
        ),
      );
      return box.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(16) > 28
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [time, const SizedBox(height: 8), count],
            )
          : Row(
              children: [
                Expanded(child: time),
                const SizedBox(width: 10),
                Expanded(child: count),
              ],
            );
    },
  );

  Widget _section(String title, {String? subtitle}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Widget _timeline(List<ListeningPoint> points) {
    int amount(ListeningPoint point) =>
        _chartPlays ? point.day.plays : point.day.milliseconds;
    ListeningPoint? peak;
    for (final point in points) {
      if (amount(point) > (peak == null ? 0 : amount(peak))) peak = point;
    }
    return _StatsPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section('Listening timeline', subtitle: _range.description),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Listening time'),
                selected: !_chartPlays,
                onSelected: (_) => setState(() => _chartPlays = false),
              ),
              ChoiceChip(
                label: const Text('Play count'),
                selected: _chartPlays,
                onSelected: (_) => setState(() => _chartPlays = true),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (points.isEmpty)
            const Text('Your listening timeline will appear here.')
          else
            ListeningBars(points: points, plays: _chartPlays),
          if (peak != null) ...[
            const Divider(height: 20),
            Text(
              'Peak · ${peak.label} · ${_chartPlays ? '${amount(peak)} plays' : listeningTime(amount(peak))}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ],
      ),
    );
  }

  Widget _habits(Map<String, ListeningDay> days) {
    final activeDays = days.values
        .where((day) => day.milliseconds > 0 || day.plays > 0)
        .length;
    final total = days.values.fold(0, (sum, day) => sum + day.milliseconds);
    final byWeekday = List<int>.filled(7, 0);
    for (final entry in days.entries) {
      byWeekday[DateTime.parse(entry.key).weekday - 1] +=
          entry.value.milliseconds;
    }
    final peak = byWeekday.reduce(math.max);
    final weekday = const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][byWeekday.indexOf(peak)];
    return _StatsPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section('Listening habits', subtitle: _range.label),
          const SizedBox(height: 6),
          for (final (icon, label, value) in [
            (Icons.calendar_today_outlined, 'Active days', '$activeDays'),
            (
              Icons.timelapse_rounded,
              'Average per active day',
              listeningTime(activeDays == 0 ? 0 : total ~/ activeDays),
            ),
            if (peak > 0)
              (
                Icons.bolt_rounded,
                'Most active weekday',
                '$weekday · ${listeningTime(peak)}',
              ),
          ])
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(label),
              subtitle: Text(value),
            ),
        ],
      ),
    );
  }

  Widget _ranking(
    List<MapEntry<String, ListeningTrack>> tracks,
    List<MapEntry<String, int>> artists,
  ) {
    final colors = Theme.of(context).colorScheme;
    final rows = _showArtists
        ? [
            for (final artist in artists.take(10))
              (artist.key, '', artist.value),
          ]
        : [
            for (final track in tracks.take(10))
              (
                track.value.title,
                '${track.value.artist} · ${track.value.plays} plays',
                track.value.milliseconds,
              ),
          ];
    return _StatsPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section(
            'Top categories',
            subtitle: 'All-time listening by track or artist',
          ),
          const SizedBox(height: 8),
          Wrap(
            key: const ValueKey('stats-ranking-tabs'),
            spacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Tracks'),
                selected: !_showArtists,
                onSelected: (_) => setState(() => _showArtists = false),
              ),
              ChoiceChip(
                label: const Text('Artists'),
                selected: _showArtists,
                onSelected: (_) => setState(() => _showArtists = true),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final (index, (name, detail, time)) in rows.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _StatsPanel(
                radius: 16,
                color: index == 0
                    ? colors.secondaryContainer
                    : colors.surfaceContainerHigh,
                padding: const EdgeInsets.all(9),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: colors.primaryContainer,
                          foregroundColor: colors.onPrimaryContainer,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 4,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (detail.isNotEmpty)
                                Text(
                                  detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 2,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              listeningTime(time),
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: time / math.max(1, rows.first.$3),
                        minHeight: 4,
                        backgroundColor: colors.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _concentration(
    List<MapEntry<String, ListeningTrack>> tracks,
    int total,
  ) {
    final time = tracks
        .take(3)
        .fold(0, (sum, track) => sum + track.value.milliseconds);
    final fraction = total == 0 ? 0.0 : time / total;
    final colors = Theme.of(context).colorScheme;
    return _StatsPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section(
            'Track concentration',
            subtitle: 'Share of all-time listening',
          ),
          const SizedBox(height: 14),
          Center(
            child: SizedBox.square(
              dimension: 114,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: fraction,
                    backgroundColor: colors.surfaceContainerHighest,
                    strokeWidth: 9,
                    strokeCap: StrokeCap.round,
                    semanticsLabel:
                        'Share of listening across the top three tracks',
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${(fraction * 100).round()}%',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('Top 3 tracks · ${listeningTime(time)}'),
          Text('${tracks.length} unique tracks'),
        ],
      ),
    );
  }

  Widget _dashboard() {
    final tracks = _stats.topTracks;
    final now = DateTime.now();
    final days = _range.days(_stats, now);
    final points = _range.points(_stats, days, now);
    final milliseconds = _range == _StatsRange.all
        ? _stats.milliseconds
        : days.values.fold(0, (sum, day) => sum + day.milliseconds);
    final plays = _range == _StatsRange.all
        ? _stats.plays
        : days.values.fold(0, (sum, day) => sum + day.plays);
    final ranking = tracks.isEmpty
        ? _StatsPanel(
            child: const Text('Play some music to build your listening stats.'),
          )
        : _ranking(tracks, _stats.topArtists);
    final timeline = _timeline(points);
    final habits = _habits(days);
    final concentration = tracks.isEmpty
        ? null
        : _concentration(tracks, _stats.milliseconds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final range in _StatsRange.values)
              ChoiceChip(
                label: Text(range.label),
                selected: range == _range,
                onSelected: (_) => setState(() => _range = range),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _overview(milliseconds, plays),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 730
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          timeline,
                          const SizedBox(height: 12),
                          habits,
                          if (concentration != null) ...[
                            const SizedBox(height: 12),
                            concentration,
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: ranking),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    timeline,
                    const SizedBox(height: 12),
                    ranking,
                    const SizedBox(height: 12),
                    habits,
                    if (concentration != null) ...[
                      const SizedBox(height: 12),
                      concentration,
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _backupControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
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
              : (value) => setState(() => _includeAccount = value),
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
              onPressed: _busy ? null : () => _restore(recovery: true),
              child: const Text('Restore recovery copy'),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final exportStyle = OutlinedButton.styleFrom(
      textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      minimumSize: const Size(0, 36),
    );
    final title = widget.openBackupSection
        ? 'Backup & Restore'
        : 'Listening stats';
    final refresh = IconButton(
      tooltip: 'Refresh listening stats',
      onPressed: _busy
          ? null
          : () => _run(() => player.flushListeningStats(failOnError: true)),
      icon: const Icon(Icons.refresh_rounded, size: 20),
    );
    final close = IconButton(
      tooltip: 'Close',
      onPressed: _busy ? null : () => Navigator.pop(context),
      icon: const Icon(Icons.close_rounded, size: 20),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_busy && !_confirming) const LinearProgressIndicator(minHeight: 2),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _status!,
                        style: TextStyle(
                          color: _error ? colors.error : colors.primary,
                        ),
                      ),
                    ),
                  ),
                if (!widget.openBackupSection) ...[
                  _dashboard(),
                  const Divider(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilledButton.tonalIcon(
                        style: exportStyle,
                        onPressed: _busy ? null : () => _export('csv'),
                        icon: const Icon(Icons.table_chart_outlined, size: 16),
                        label: const Text('Export CSV'),
                      ),
                      OutlinedButton.icon(
                        style: exportStyle,
                        onPressed: _busy ? null : () => _export('json'),
                        icon: const Icon(
                          Icons.file_download_outlined,
                          size: 16,
                        ),
                        label: const Text('Export JSON'),
                      ),
                    ],
                  ),
                  ExpansionTile(
                    key: const ValueKey('stats-backup-section'),
                    tilePadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    title: const Text(
                      'Backup & Restore',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [_backupControls()],
                  ),
                ] else
                  _backupControls(),
              ],
            ),
          ),
        ),
      ],
    );
    if (widget.fullscreen) {
      return PopScope<Object?>(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(
            title: Text(title),
            leading: close,
            actions: [refresh],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: SizedBox.expand(child: content),
              ),
            ),
          ),
        ),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (!widget.openBackupSection) refresh,
                  close,
                ],
              ),
            ),
            Flexible(child: content),
          ],
        ),
      ),
    );
  }
}

enum _StatsRange {
  week('7 days', 'Daily activity in the last 7 days'),
  month('30 days', 'Daily activity in the last 30 days'),
  year('This year', 'Monthly activity this year'),
  all('All time', 'Listening history grouped by year');

  const _StatsRange(this.label, this.description);
  final String label, description;

  Map<String, ListeningDay> days(ListeningStats stats, DateTime now) {
    if (this == all) return stats.days;
    final start = listeningDate(switch (this) {
      week => DateTime(now.year, now.month, now.day - 6),
      month => DateTime(now.year, now.month, now.day - 29),
      _ => DateTime(now.year),
    });
    final end = listeningDate(now);
    return {
      for (final entry in stats.days.entries)
        if (entry.key.compareTo(start) >= 0 && entry.key.compareTo(end) <= 0)
          entry.key: entry.value,
    };
  }

  List<ListeningPoint> points(
    ListeningStats stats,
    Map<String, ListeningDay> days,
    DateTime now,
  ) {
    if (this == week || this == month) {
      return listeningDays(stats, now, this == week ? 7 : 30);
    }
    final grouped = <String, ListeningDay>{};
    for (final entry in days.entries) {
      final key = entry.key.substring(0, this == year ? 7 : 4);
      final day = grouped.putIfAbsent(key, ListeningDay.new);
      day.milliseconds += entry.value.milliseconds;
      day.plays += entry.value.plays;
    }
    if (this == year) {
      const labels = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return [
        for (var month = 1; month <= now.month; month++)
          (
            label: labels[month - 1],
            day:
                grouped[listeningDate(DateTime(now.year, month))
                    .substring(0, 7)] ??
                ListeningDay(),
          ),
      ];
    }
    return [
      for (final key in grouped.keys.toList()..sort())
        (label: key, day: grouped[key]!),
    ];
  }
}

typedef ListeningPoint = ({String label, ListeningDay day});

List<ListeningPoint> listeningDays(
  ListeningStats stats,
  DateTime now,
  int count,
) => [
  for (var offset = count - 1; offset >= 0; offset--)
    (
      label: listeningDate(DateTime(now.year, now.month, now.day - offset))
          .substring(5),
      day:
          stats.days[listeningDate(
            DateTime(now.year, now.month, now.day - offset),
          )] ??
          ListeningDay(),
    ),
];

class ListeningBars extends StatelessWidget {
  const ListeningBars({
    super.key,
    required this.points,
    this.plays = false,
    this.height = 104,
  });
  final List<ListeningPoint> points;
  final bool plays;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    int value(ListeningPoint point) =>
        plays ? point.day.plays : point.day.milliseconds;
    final maximum = points.fold(1, (max, point) => math.max(max, value(point)));
    final scale = MediaQuery.textScalerOf(context).scale(10);
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(
          math.max(28.0, scale * 3.2),
          box.maxWidth / math.max(1, points.length),
        );
        return SizedBox(
          height: height + scale * 2.8,
          child: ListView.builder(
            primary: false,
            scrollDirection: Axis.horizontal,
            itemExtent: width,
            itemCount: points.length,
            itemBuilder: (context, index) {
              final point = points[index];
              final amount = value(point);
              final label = plays ? '$amount plays' : listeningTime(amount);
              return Tooltip(
                message: '${point.label} · $label',
                child: Column(
                  children: [
                    SizedBox(
                      height: height,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: AnimatedContainer(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 220),
                          height: math.max(3.0, height * amount / maximum),
                          width: math.min(48, width * .68),
                          decoration: BoxDecoration(
                            color: amount == 0
                                ? colors.surfaceContainerHighest
                                : colors.primary,
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      point.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.child,
    this.color,
    this.radius = 24,
    this.padding = const EdgeInsets.all(14),
  });
  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(radius),
    child: Padding(padding: padding, child: child),
  );
}
