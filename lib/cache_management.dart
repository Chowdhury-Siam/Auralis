import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_popups.dart';
import 'media_cache.dart';
import 'models.dart';
import 'preference_widgets.dart';

enum CacheCategory {
  artwork('Cover artwork', Icons.album_outlined),
  lyrics('Lyrics', Icons.lyrics_outlined),
  translations('Automatic translations', Icons.translate_rounded),
  videoThumbnails('Video thumbnails', Icons.image_outlined),
  playback('Telegram playback files', Icons.video_file_outlined);

  const CacheCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

class CacheEntry {
  const CacheEntry({
    required this.id,
    required this.category,
    required this.title,
    required this.bytes,
    required this.remove,
    this.detail,
    this.inUse = false,
  });

  final String id, title;
  final String? detail;
  final int bytes;
  final CacheCategory category;
  final bool inUse;
  final Future<void> Function() remove;
}

/// Reads only Auralis-owned cache entries and groups old and current copies
/// together so that deleting a song's cache cannot restore it from an old key.
Future<List<CacheEntry>> musicCacheEntries(
  MediaCache cache,
  Iterable<Track> tracks,
  bool Function() isCurrent,
) async {
  final directory = cache.directory;
  if (directory == null || !await directory.exists()) return [];
  final byKey = {
    for (final track in tracks)
      for (final key in cache.keys(track)) key: track,
  };
  final pattern = RegExp(
    r'^([a-f0-9]{64})\.(art(?:-checked)?|lyrics|translation-[a-z]+-[a-f0-9]{64})(?:\.\d+\.tmp)?$',
  );
  final groups = <(CacheCategory, String), (Track?, List<File>, int)>{};
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final match = pattern.firstMatch(p.basename(entity.path));
    if (match == null) continue;
    final key = match[1]!, kind = match[2]!;
    final category = switch (kind) {
      'art' || 'art-checked' => CacheCategory.artwork,
      'lyrics' => CacheCategory.lyrics,
      _ => CacheCategory.translations,
    };
    final track = byKey[key];
    // Translation variants remain independently selectable.
    final id =
        '${track == null ? key : cache.key(track)}:${category == CacheCategory.translations ? kind : ''}';
    final stat = await entity.stat();
    if (stat.type != FileSystemEntityType.file) continue;
    final group = (category, id);
    final (_, files, bytes) = groups[group] ?? (track, <File>[], 0);
    files.add(entity);
    groups[group] = (track, files, bytes + stat.size);
  }
  return [
    for (final MapEntry(key: (category, id), value: (track, files, bytes))
        in groups.entries)
      CacheEntry(
        id: '${category.name}:$id',
        category: category,
        title: track?.title ?? 'Cached item ${id.substring(0, 8)}',
        detail: [
          if (track?.artist case final String artist when artist.isNotEmpty)
            artist,
          if (category == CacheCategory.translations)
            'Target ${id.split(':').last.split('-')[1].toUpperCase()}',
        ].join(' · '),
        bytes: bytes,
        remove: () async {
          if (!isCurrent()) throw StateError('Cache account changed.');
          for (final file in files) {
            final type = await FileSystemEntity.type(
              file.path,
              followLinks: false,
            );
            if (type == FileSystemEntityType.file) await file.delete();
          }
        },
      ),
  ];
}

class CacheManagement extends StatefulWidget {
  const CacheManagement({
    super.key,
    required this.video,
    required this.load,
    required this.prepareRemoval,
    required this.bottomPadding,
  });

  final bool video;
  final Future<({List<CacheEntry> entries, String? message})> Function() load;
  final Future<void> Function(Set<CacheCategory>) prepareRemoval;
  final double bottomPadding;

  @override
  State<CacheManagement> createState() => _CacheManagementState();
}

class _CacheManagementState extends State<CacheManagement> {
  final _selected = <String>{};
  final _expanded = <CacheCategory>{};
  List<CacheEntry> _entries = const [];
  bool _busy = true;
  String? _message;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload({String? status}) async {
    try {
      final result = await widget.load();
      if (!mounted) return;
      setState(() {
        _entries = result.entries
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        _selected.clear();
        _message = [status, result.message].whereType<String>().join('\n');
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _selected.clear();
        _message = status == null
            ? 'Could not read cache usage. Use Refresh to try again.'
            : '$status\nCould not refresh cache usage.';
        _busy = false;
      });
    }
  }

  Future<void> _delete() async {
    final selected = _entries
        .where((entry) => _selected.contains(entry.id))
        .toList();
    final categories = selected.map((entry) => entry.category).toSet();
    final approved = await confirmAuralisAction(
      context,
      title: 'Delete selected cache?',
      message: [
        'Remove ${selected.length} selected entries from this device?',
        if (categories.contains(CacheCategory.lyrics)) 'Selected lyrics may include imported lyrics and pasted translations.',
      ].join('\n\n'),
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (approved != true || !mounted || _busy) return;
    setState(() => _busy = true);
    var failures = 0;
    try {
      await widget.prepareRemoval(categories);
      for (final entry in selected) {
        try {
          await entry.remove();
        } catch (_) {
          failures++;
        }
      }
    } catch (_) {
      failures = selected.length;
    }
    if (mounted) {
      await _reload(
        status: failures == 0
            ? 'Deleted ${selected.length} selected entries.'
            : 'Deleted ${selected.length - failures} of ${selected.length} entries. Refresh and try again for the rest.',
      );
    }
  }

  void _select(Iterable<CacheEntry> entries, bool checked) {
    setState(() {
      for (final entry in entries) {
        if (entry.inUse) continue;
        if (checked) {
          _selected.add(entry.id);
        } else {
          _selected.remove(entry.id);
        }
      }
    });
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  int _total(Iterable<CacheEntry> entries) =>
      entries.fold(0, (sum, entry) => sum + entry.bytes);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = widget.video
        ? [CacheCategory.videoThumbnails, CacheCategory.playback]
        : [
            CacheCategory.artwork,
            CacheCategory.lyrics,
            CacheCategory.translations,
            CacheCategory.playback,
          ];
    final all = _entries.where((entry) => !entry.inUse);
    final visible = _entries.where(
      (entry) => '${entry.title} ${entry.detail ?? ''} ${entry.category.label}'
          .toLowerCase()
          .contains(_query),
    );
    final rows = <Object>[];
    for (final category in categories) {
      final items = visible
          .where((entry) => entry.category == category)
          .toList();
      if (_query.isNotEmpty && items.isEmpty) continue;
      rows.add((category, items));
      if (_expanded.contains(category) || _query.isNotEmpty) rows.addAll(items);
    }
    return ListView.builder(
      key: PageStorageKey(
        widget.video ? 'video-cache-list' : 'music-cache-list',
      ),
      padding: EdgeInsets.only(bottom: widget.bottomPadding),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: PreferenceIcon(
                  widget.video
                      ? Icons.movie_outlined
                      : Icons.music_note_rounded,
                ),
                title: Text('${_size(_total(_entries))} used'),
                trailing: IconButton(
                  tooltip: 'Refresh cache',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _busy = true);
                          unawaited(_reload());
                        },
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_message case final String message when message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 12,
                  ),
                  child: Text(message, style: theme.textTheme.bodySmall),
                ),
              if (_entries.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search cache',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                    onChanged: (value) =>
                        setState(() => _query = value.trim().toLowerCase()),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    TextButton(
                      onPressed: !_busy && all.isNotEmpty
                          ? () => _select(all, _selected.length != all.length)
                          : null,
                      child: Text(
                        all.isNotEmpty && _selected.length == all.length
                            ? 'Deselect all'
                            : 'Select all',
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _busy || _selected.isEmpty ? null : _delete,
                      child: Text(
                        _selected.isEmpty
                            ? 'Delete selected'
                            : 'Delete selected (${_size(_total(_entries.where((entry) => _selected.contains(entry.id))))})',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        }
        final row = rows[index - 1];
        if (row is CacheEntry) {
          return CheckboxListTile(
            key: ValueKey(row.id),
            dense: true,
            contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 8),
            value: _selected.contains(row.id),
            onChanged: _busy || row.inUse
                ? null
                : (checked) => _select([row], checked == true),
            title: Text(
              row.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                _size(row.bytes),
                if (row.detail case final String value when value.isNotEmpty)
                  value,
              ].join(' · '),
            ),
          );
        }
        final (category, items) = row as (CacheCategory, List<CacheEntry>);
        final selectable = items.where((entry) => !entry.inUse);
        final count = selectable
            .where((entry) => _selected.contains(entry.id))
            .length;
        final checked = count > 0 && count == selectable.length;
        final expanded = _expanded.contains(category) || _query.isNotEmpty;
        return ListTile(
          key: ValueKey(category),
          leading: Checkbox(
            value: count == 0
                ? false
                : checked
                ? true
                : null,
            tristate: true,
            semanticLabel: 'Select ${category.label}',
            onChanged: _busy || selectable.isEmpty
                ? null
                : (_) => _select(selectable, !checked),
          ),
          title: Text(category.label),
          subtitle: Text('${items.length} · ${_size(_total(items))}'),
          trailing: Icon(
            items.isEmpty
                ? category.icon
                : expanded
                ? Icons.expand_less
                : Icons.expand_more,
          ),
          onTap: items.isEmpty || _query.isNotEmpty
              ? null
              : () => setState(() {
                  if (!_expanded.add(category)) _expanded.remove(category);
                }),
        );
      },
    );
  }
}
