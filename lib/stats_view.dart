import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'data_backup.dart';
import 'data_files.dart';
import 'listening.dart';
import 'player.dart';

class StatsDataDialog extends StatefulWidget {
  const StatsDataDialog({
    super.key,
    required this.player,
    this.files = const DataFiles(),
    this.onRestored,
    this.openBackupSection = false,
  });
  final PlayerController player;
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
  PlayerController get player => widget.player;
  String get _recovery =>
      p.join(player.settings.file.parent.path, 'auralis-before-restore.json');
  @override
  void initState() {
    super.initState();
    _snapshot();
  }

  void _snapshot() =>
      _stats = ListeningStats.fromJson(player.settings.listening.toJson());

  Future<void> _run(Future<void> Function() action) async {
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
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = 'Could not complete the operation. Check the file location and available storage.';
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

    if ([
      player.settings.file.path,
      _recovery,
    ].any((internal) => normalized(internal) == normalized(path))) {
      throw const FormatException(
        'Choose a destination outside Auralis’s internal settings and recovery files.',
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

  Future<void> _backup() => _run(() async {
    final path = await _destination(
      'auralis-backup-${listeningDate(DateTime.now())}.json',
      'json',
    );
    if (path == null) return;
    await player.flushListeningStats(failOnError: true);
    final text = DataBackup.create(player.settings, DateTime.now()).encode();
    DataBackup.parse(text);
    await widget.files.write(path, text);
    if (mounted) setState(() => _status = 'Backup saved.');
  });

  Future<void> _restore({bool recovery = false}) => _run(() async {
    final path = recovery ? _recovery : await widget.files.openBackup();
    if (path == null) return;
    final backup = DataBackup.parse(await widget.files.read(path));
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
            'Your current data is saved as a recovery copy first. Telegram sign-in and music files are kept.',
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
    await player.restoreBackup(backup);
    await widget.onRestored?.call();
    if (mounted) {
      setState(
        () => _status = 'Backup restored. A recovery copy is available below.',
      );
    }
  });

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
                      'Includes listening stats, favorites, playlists, recent music, channel selections and preferences. Telegram credentials, music files and the playback queue are not included.',
                      style: TextStyle(fontSize: 12),
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
