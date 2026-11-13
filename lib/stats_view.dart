import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'preference_widgets.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'data_backup.dart';
import 'account_backup.dart';
import 'backup_export_view.dart';
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
  late ListeningStats _stats, _sourceStats;
  bool _busy = false, _error = false, _confirming = false;
  bool _showArtists = false, _chartPlays = false;
  _StatsRange _range = _StatsRange.all;
  String? _status;
  PlayerController get player => widget.player;
  String get _recovery =>
      p.join(player.settings.file.parent.path, 'auralis-before-restore.json');
  @override
  void initState() {
    super.initState();
    _snapshot();
    player.addListener(_refreshSyncedStats);
  }

  @override
  void didUpdateWidget(covariant StatsDataDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != player) {
      oldWidget.player.removeListener(_refreshSyncedStats);
      player.addListener(_refreshSyncedStats);
      _snapshot();
    }
  }

  @override
  void dispose() {
    player.removeListener(_refreshSyncedStats);
    super.dispose();
  }

  void _refreshSyncedStats() {
    if (!widget.openBackupSection &&
        !identical(_sourceStats, player.settings.listening)) {
      setState(_snapshot);
    }
  }

  void _snapshot() {
    _sourceStats = player.settings.listening;
    _stats = ListeningStats.fromJson(_sourceStats.toJson());
  }

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

  Future<String?> _destination(String name) async {
    final path = await widget.files.savePath(name);
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

  Future<String?> _password({required bool creating}) async {
    final password = TextEditingController();
    final repeat = TextEditingController();
    String? error;
    setState(() => _confirming = true);
    try {
      return await showAuralisDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AuralisDialog(
            title: Text(
              creating ? 'Protect your Telegram backup' : 'Unlock backup',
            ),
            content: Column(
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

  Future<void> _chooseBackup() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => BackupExportPage(
        showTelegram: widget.telegram != null,
        telegramAvailable: widget.telegram?.ready == true,
        onExport: _backup,
      ),
    ),
  );

  Future<({bool saved, String? error})> _backup(
    Set<BackupSection> sections,
    bool includeTelegram,
  ) async {
    var saved = false;
    await _run(() async {
      final telegram = widget.telegram;
      if (includeTelegram && telegram?.ready != true) {
        throw const FormatException(
          'Telegram is disconnected. Reconnect or turn off the Telegram account section.',
        );
      }
      final path = await _destination(
        'auralis-backup-${listeningDate(DateTime.now())}.json',
      );
      if (path == null || !mounted) return;
      await player.flushListeningStats(failOnError: true);
      final data = DataBackup.create(
        player.settings,
        DateTime.now(),
        sections: sections,
      );
      final plain = data.encode();
      DataBackup.parse(plain);
      var text = plain;
      if (includeTelegram) {
        if (!mounted) return;
        final password = await _password(creating: true);
        if (password == null) return;
        // Pause streaming before closing TDLib to take a consistent snapshot.
        await player.setPlayback(false);
        final account = await telegram!.backupAccount();
        text = await encryptAccountBackup(data, account, password);
      }
      await widget.files.write(path, text);
      saved = true;
      if (mounted) {
        setState(
          () => _status = includeTelegram
              ? 'Backup saved with your Telegram sign-in. Keep the backup password.'
              : 'Backup saved.',
        );
      }
    }, operation: 'Export');
    return (saved: saved, error: _error ? _status : null);
  }

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
    if (backup.snapshot.isEmpty && account == null) {
      throw const FormatException('This backup has no sections to restore.');
    }
    final stats = ListeningStats.fromJson(backup.snapshot['listening']);
    final sections = backup.sections.map((section) => section.label).join(', ');
    final summary = backup.isPartial
        ? (sections.isEmpty
              ? 'Sections: Telegram account only.'
              : 'Sections: $sections.')
        : '${(backup.snapshot['favoriteIds'] as List).length} favorites · ${(backup.snapshot['playlists'] as Map).length} playlists\n'
              '${listeningTime(stats.milliseconds)} listened · ${stats.plays} qualified plays';
    final restoreScope = backup.isPartial
        ? 'The included sections replace their local copies. Other sections are kept.'
        : 'This replaces local stats, collections and preferences.';
    if (!mounted) return;
    setState(() => _confirming = true);
    final confirmed = await showAuralisDialog<bool>(
      context: context,
      builder: (context) => AuralisDialog(
        title: const Text('Restore this backup?'),
        content: Text(
          'Created ${backup.createdAt.toLocal()}\n\n'
          '$summary\n\n'
          '$restoreScope Playback and the queue will stop. '
          'Your current settings are saved as a recovery copy first. Music files are kept. '
          '${account != null ? 'Telegram sign-in: included. This replaces the local account with the saved session. Telegram may require reauthentication if that session has expired or been revoked.' : 'Telegram sign-in: not included. Your current sign-in is kept.'}',
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
            ? (backup.isPartial
                  ? 'Selected sections restored. Your Telegram sign-in is kept.'
                  : 'Settings restored. This backup has no Telegram sign-in; connect Telegram or restore a password-protected account backup.')
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
    final foreground = colors.onSurface;
    final accent = second ? colors.tertiary : colors.primary;
    return _StatsPanel(
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
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
          const SizedBox(height: 16),
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
          const SizedBox(height: 20),
          if (points.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Your listening timeline will appear here.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ListeningBars(points: points, plays: _chartPlays, showValues: true),
          if (peak != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: .4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.trending_up_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Peak · ${peak.label} · ${_chartPlays ? '${amount(peak)} plays' : listeningTime(amount(peak))}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
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
              dense: false,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              subtitle: Text(
                value,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
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
            'Your most played',
            subtitle: 'All-time ranking by listening time',
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
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: _StatsPanel(
                radius: 16,
                color: index == 0
                    ? colors.primaryContainer.withValues(alpha: .4)
                    : colors.surfaceContainer,
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: index == 0
                              ? colors.primary
                              : colors.surfaceContainerHighest,
                          foregroundColor: index == 0
                              ? colors.onPrimary
                              : colors.onSurfaceVariant,
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
                        minHeight: 3,
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
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.headphones_rounded,
                    size: 36,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  _section(
                    'Your story starts with a song',
                    subtitle: 'Play some music to build your listening stats.',
                  ),
                ],
              ),
            ),
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
        Container(
          key: const ValueKey('stats-intro'),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer
                .withValues(alpha: .4),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YOUR LISTENING',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Your music, in numbers.',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Listening time, favorite tracks and everyday rhythms.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          key: const ValueKey('stats-range-tabs'),
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
        const SizedBox(height: 16),
        _overview(milliseconds, plays),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, box) =>
              box.maxWidth >= 730 &&
                  MediaQuery.textScalerOf(context).scale(14) < 21
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
                    const SizedBox(width: 20),
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

  Widget _backupAction({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = primary ? colors.onPrimaryContainer : colors.onSurface;
    return Material(
      color: primary ? colors.primaryContainer : colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        enabled: !_busy,
        onTap: _busy ? null : onTap,
        contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 8),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: primary
                ? colors.primary.withValues(alpha: 0.16)
                : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            size: 21,
            color: primary ? foreground : colors.primary,
          ),
        ),
        title: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: primary ? foreground : colors.onSurfaceVariant,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: foreground,
          size: 20,
        ),
      ),
    );
  }

  Widget _backupControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _backupAction(
        icon: Icons.upload_file_rounded,
        title: 'Export backup',
        description: 'Choose what to include and save a copy.',
        primary: true,
        onTap: _chooseBackup,
      ),
      const SizedBox(height: 8),
      _backupAction(
        icon: Icons.folder_open_rounded,
        title: 'Restore backup',
        description: 'Open a backup file and review its contents.',
        onTap: _restore,
      ),
      if (File(_recovery).existsSync()) ...[
        const SizedBox(height: 8),
        _backupAction(
          icon: Icons.history_rounded,
          title: 'Restore recovery copy',
          description: 'Use the copy saved before your last restore.',
          onTap: () => _restore(recovery: true),
        ),
      ],
    ],
  );

  Widget _backupDialog(Widget close) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope<void>(
      canPop: !_busy,
      child: AuralisDialog(
        width: 420,
        title: AuralisDialogTitle(
          'Backup & Restore',
          leading: const PreferenceIcon(Icons.shield_outlined),
          actions: [close],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Backups can include your listening stats, collections, and preferences.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_busy && !_confirming) ...[
              const LinearProgressIndicator(minHeight: 3),
              const SizedBox(height: 12),
            ],
            if (_status case final status?) ...[
              Semantics(
                liveRegion: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _error
                        ? colors.errorContainer
                        : colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      status,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _error
                            ? colors.onErrorContainer
                            : colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _backupControls(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const title = 'Listening stats';
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
    if (widget.openBackupSection) return _backupDialog(close);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_busy && !_confirming) const LinearProgressIndicator(minHeight: 2),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('stats-content-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
                _dashboard(),
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
                constraints: const BoxConstraints(maxWidth: 1120),
                child: SizedBox.expand(child: content),
              ),
            ),
          ),
        ),
      );
    }
    return PopScope<Object?>(
      canPop: !_busy,
      child: AuralisDialog(
        width: 960,
        maxWidth: 1000,
        scrollable: false,
        title: AuralisDialogTitle(title, actions: [refresh, close]),
        content: content,
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
    this.showValues = false,
    this.height = 104,
  });
  final List<ListeningPoint> points;
  final bool plays, showValues;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    int value(ListeningPoint point) =>
        plays ? point.day.plays : point.day.milliseconds;
    final maximum = points.fold(1, (max, point) => math.max(max, value(point)));
    final scaler = MediaQuery.textScalerOf(context);
    final scale = scaler.scale(10);
    final labelStyle = (theme.textTheme.labelSmall ?? const TextStyle())
        .copyWith(fontSize: 10, color: colors.onSurfaceVariant);
    final valueStyle = labelStyle.copyWith(
      color: colors.onSurface,
      fontWeight: FontWeight.w700,
    );
    String valueLabel(int amount) => plays ? '$amount' : listeningTime(amount);
    var minimumWidth = math.max(28.0, scale * 3.2);
    if (showValues) {
      final direction = Directionality.of(context);
      for (final point in points) {
        for (final (text, style) in [
          (point.label, labelStyle),
          (listeningTime(point.day.milliseconds), valueStyle),
          ('${point.day.plays}', valueStyle),
        ]) {
          final measured = TextPainter.computeWidth(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
          );
          minimumWidth = math.max(minimumWidth, measured + 12);
        }
      }
    }
    return LayoutBuilder(
      builder: (context, box) {
        final wraps = showValues && points.length <= 12;
        final columns = math.max(1, (box.maxWidth / minimumWidth).floor());
        final width = wraps
            ? (box.maxWidth / math.max(1, math.min(columns, points.length)))
                  .floorToDouble()
            : math.max(minimumWidth, box.maxWidth / math.max(1, points.length));
        final barHeight = wraps && columns < points.length
            ? height * .72
            : height;

        Widget period(int index) {
          final point = points[index];
          final amount = value(point);
          final label = valueLabel(amount);
          return Tooltip(
            message: '${point.label} · ${plays ? '$label plays' : label}',
            child: Column(
              children: [
                SizedBox(
                  height: barHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      height: math.max(3.0, barHeight * amount / maximum),
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
                  style: labelStyle,
                ),
                if (showValues)
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: valueStyle,
                  ),
              ],
            ),
          );
        }

        if (wraps) {
          return Wrap(
            runSpacing: 12,
            children: [
              for (var index = 0; index < points.length; index++)
                SizedBox(width: width, child: period(index)),
            ],
          );
        }
        return SizedBox(
          height: barHeight + scale * (showValues ? 4.2 : 2.8),
          child: ListView.builder(
            primary: false,
            scrollDirection: Axis.horizontal,
            itemExtent: width,
            itemCount: points.length,
            itemBuilder: (context, index) => period(index),
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
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: Theme.of(context).colorScheme.outlineVariant
            .withValues(alpha: .3),
      ),
    ),
    child: Padding(padding: padding, child: child),
  );
}
