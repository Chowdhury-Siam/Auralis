import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_popups.dart';
import 'app_theme.dart';
import 'models.dart';
import 'media_item_sheet.dart';
import 'video_playback_data.dart';

part 'video_library_widgets.dart';

typedef VideoSelection = (List<VideoSource>, int);

Future<String?> _playlistName(BuildContext context, String initial) =>
    showAuralisDialog<String>(
      context: context,
      builder: (_) => _PlaylistName(initial),
    );

class _PlaylistName extends StatefulWidget {
  const _PlaylistName(this.initial);
  final String initial;

  @override
  State<_PlaylistName> createState() => _PlaylistNameState();
}

class _PlaylistNameState extends State<_PlaylistName> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AuralisDialog(
    title: const Text('Playlist name'),
    content: TextField(controller: _name, autofocus: true, maxLength: 80),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final name = _name.text.trim();
          if (name.isNotEmpty) Navigator.pop(context, name);
        },
        child: const Text('Save'),
      ),
    ],
  );
}

Future<void> saveVideoPlaylist(
  BuildContext context,
  VideoPlaybackData data,
  Future<void> Function() save,
  List<VideoSource> sources, {
  String suggestedName = '',
}) async {
  final name = await _playlistName(context, suggestedName);
  if (!context.mounted || name == null) return;
  try {
    data.putPlaylist(name, [...?data.playlists[name], ...sources]);
    await save();
    if (context.mounted) _message(context, 'Saved to $name.');
  } catch (_) {
    if (context.mounted) _message(context, 'Could not save the playlist.');
  }
}

void _message(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await confirmAuralisAction(
      context,
      title: title,
      message: message,
      confirmLabel: 'Remove',
      destructive: true,
    ) ==
    true;

Future<String?> showVideoItemSheet({
  required BuildContext context,
  required VideoSource source,
  required VideoPlaybackData data,
  Widget? artwork,
  String? removeLabel,
  bool playNext = false,
}) {
  final watched = data.isWatched(source);
  final position = data.positions[source.id];
  return showMediaItemSheet(
    context: context,
    title: source.title,
    subtitle: source.telegram?.source ?? 'On your device',
    artwork: artwork ?? _VideoSourcePreview(source),
    details: [
      if (source.telegram case final Track track)
        ...mediaItemDetails(track, video: true)
      else ...[
        ('Mode', 'Video'),
        ('Source', 'On your device'),
      ],
      (
        'Status',
        watched
            ? 'Watched'
            : position == null
            ? 'Not watched'
            : 'Resume at ${clockText(position)}',
      ),
    ],
    actions: [
      const MediaItemAction(
        'play',
        'Play',
        Icons.play_arrow_rounded,
        primary: true,
      ),
      if (playNext)
        const MediaItemAction('next', 'Play next', Icons.playlist_play_rounded),
      const MediaItemAction(
        'playlist',
        'Add to playlist',
        Icons.playlist_add_rounded,
      ),
      if (source.telegram != null)
        MediaItemAction(
          'watched',
          watched ? 'Mark as unwatched' : 'Mark as watched',
          watched
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          selected: watched,
        ),
      if (removeLabel != null)
        MediaItemAction(
          'remove',
          removeLabel,
          Icons.remove_circle_outline_rounded,
          destructive: true,
        ),
    ],
  );
}

class VideoWatchButton extends StatelessWidget {
  const VideoWatchButton({
    super.key,
    required this.watched,
    required this.onPressed,
  });

  final bool watched;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
    isSelected: watched,
    icon: const Icon(Icons.radio_button_unchecked_rounded),
    selectedIcon: Icon(
      Icons.check_circle_rounded,
      color: Theme.of(context).colorScheme.primary,
    ),
    onPressed: onPressed,
  );
}

class VideoLibraryPageController {
  bool Function()? _back;
  bool backToOverview() => _back?.call() ?? false;
}

class VideoLibraryPage extends StatefulWidget {
  const VideoLibraryPage({
    super.key,
    required this.data,
    required this.save,
    required this.pickFiles,
    required this.playlists,
    this.changes,
    this.embedded = false,
    this.onPlay,
    this.controller,
    this.bottomPadding = 28,
  });

  final VideoPlaybackData data;
  final Future<void> Function() save;
  final Future<List<VideoSource>> Function() pickFiles;
  final bool playlists;
  final Listenable? changes;
  final bool embedded;
  final ValueChanged<VideoSelection>? onPlay;
  final VideoLibraryPageController? controller;
  final double bottomPadding;

  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  String? _selected;
  VideoPlaybackData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    widget.controller?._back = _backToOverview;
  }

  @override
  void didUpdateWidget(covariant VideoLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._back == _backToOverview) {
        oldWidget.controller?._back = null;
      }
      widget.controller?._back = _backToOverview;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._back == _backToOverview) {
      widget.controller?._back = null;
    }
    super.dispose();
  }

  bool _backToOverview() {
    if (!mounted || _selected == null) return false;
    setState(() => _selected = null);
    return true;
  }

  Future<void> _change(VoidCallback update) async {
    try {
      setState(update);
      await widget.save();
    } catch (_) {
      if (mounted) _message(context, 'Could not save changes.');
    }
  }

  Future<void> _rename(String? old) async {
    final name = await _playlistName(context, old ?? '');
    if (!mounted || name == null || name == old) return;
    if (_data.playlists.containsKey(name)) {
      _message(context, 'A playlist already has that name.');
      return;
    }
    await _change(() {
      if (old != null) {
        final items = _data.playlists.remove(old);
        if (items != null) _data.putPlaylist(name, items);
        if (_selected == old) _selected = name;
      } else {
        _data.putPlaylist(name, const []);
        _selected = name;
      }
    });
  }

  Future<void> _add(String name) async {
    try {
      final videos = await widget.pickFiles();
      if (!mounted || videos.isEmpty || !_data.playlists.containsKey(name)) {
        return;
      }
      await _change(
        () => _data.putPlaylist(name, [..._data.playlists[name]!, ...videos]),
      );
    } catch (_) {
      if (mounted) _message(context, 'Could not add files.');
    }
  }

  Future<void> _removePlaylist(String name) async {
    if (!await _confirm(
          context,
          'Remove “$name”?',
          'The video files will stay on your device.',
        ) ||
        !mounted) {
      return;
    }
    await _change(() {
      _data.playlists.remove(name);
      if (_selected == name) _selected = null;
    });
  }

  void _play(List<VideoSource> sources, int index) {
    final selection = (List<VideoSource>.of(sources), index);
    if (widget.onPlay case final callback?) {
      callback(selection);
    } else {
      Navigator.pop(context, selection);
    }
  }

  Widget _itemActions(
    VideoSource source, {
    required VoidCallback play,
    required VoidCallback remove,
    required String removeLabel,
  }) => IconButton.filledTonal(
    tooltip: 'Video actions for ${source.title}',
    icon: const Icon(Icons.more_vert_rounded),
    onPressed: () async {
      final action = await showVideoItemSheet(
        context: context,
        source: source,
        data: _data,
        removeLabel: removeLabel,
      );
      if (!mounted || action == null) return;
      switch (action) {
        case 'play':
          play();
        case 'playlist':
          await saveVideoPlaylist(context, _data, widget.save, [source]);
          if (mounted) setState(() {});
        case 'watched':
          await _change(
            () => _data.setWatched(source, !_data.isWatched(source)),
          );
        case 'remove':
          await _change(remove);
      }
    },
  );

  @override
  Widget build(BuildContext context) {
    final changes = widget.changes;
    return changes == null
        ? _build()
        : ListenableBuilder(listenable: changes, builder: (_, _) => _build());
  }

  Widget _build() {
    final name = _selected;
    final list = _data.playlists[name] ?? const <VideoSource>[];
    final history = _data.history.values.toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final inPlaylist =
        widget.playlists && name != null && _data.playlists.containsKey(name);
    final entries = _data.playlists.entries.toList();
    final watchedCount = history
        .where((entry) => _data.isWatched(entry.source))
        .length;
    final resumeCount = history
        .where(
          (entry) =>
              !_data.isWatched(entry.source) &&
              _data.positions.containsKey(entry.source.id),
        )
        .length;
    void back() =>
        inPlaylist ? setState(() => _selected = null) : Navigator.pop(context);
    String status(VideoSource source) {
      if (_data.isWatched(source)) return 'Watched';
      final position = _data.positions[source.id];
      return position == null
          ? 'Ready to play'
          : 'Resume at ${clockText(position)}';
    }

    double? progress(VideoSource source) {
      if (_data.isWatched(source)) return 1;
      final position = _data.positions[source.id];
      return position == null || source.duration <= Duration.zero
          ? null
          : (position.inMilliseconds / source.duration.inMilliseconds)
                .clamp(0, 1)
                .toDouble();
    }

    final page = _VideoCollectionPage(
      embedded: widget.embedded,
      bottomPadding: widget.bottomPadding,
      onBack: widget.embedded && !inPlaylist ? null : back,
      title: widget.playlists
          ? inPlaylist
                ? name
                : 'Video playlists'
          : 'Video history',
      icon: widget.playlists
          ? Icons.playlist_play_rounded
          : Icons.history_rounded,
      summary: widget.playlists
          ? inPlaylist
                ? '${list.length} ${list.length == 1 ? 'video' : 'videos'}'
                : '${entries.length} ${entries.length == 1 ? 'playlist' : 'playlists'} · ${entries.fold<int>(0, (count, entry) => count + entry.value.length)} videos'
          : '${history.length} ${history.length == 1 ? 'video' : 'videos'} · $resumeCount to resume · $watchedCount watched',
      description: widget.playlists
          ? inPlaylist
                ? 'Your next viewing session, in your order. Drag the handles to rearrange videos.'
                : 'Keep favorite episodes and movie nights together. Your files stay where they are.'
          : 'Pick up where you left off, or revisit something you loved.',
      actions: [
        if (widget.playlists)
          FilledButton.icon(
            onPressed: inPlaylist
                ? () => _add(_selected!)
                : () => _rename(null),
            icon: Icon(
              inPlaylist ? Icons.playlist_add_rounded : Icons.add_rounded,
            ),
            label: Text(inPlaylist ? 'Add video files' : 'Create playlist'),
          ),
        if (inPlaylist && list.isNotEmpty)
          FilledButton.tonalIcon(
            onPressed: () => _play(list, 0),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play playlist'),
          ),
        if (!widget.playlists &&
            (history.isNotEmpty || _data.positions.isNotEmpty))
          OutlinedButton.icon(
            onPressed: () async {
              if (await _confirm(
                    context,
                    'Clear video history?',
                    'This also clears saved resume positions.',
                  ) &&
                  mounted) {
                await _change(_data.clearHistory);
              }
            },
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Clear history'),
          ),
      ],
      slivers: [
        if (inPlaylist)
          if (list.isEmpty)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'Your playlist starts here',
                'Add video files, or save videos from the player queue to this playlist.',
                Icons.playlist_add_rounded,
              ),
            )
          else
            SliverReorderableList(
              itemCount: list.length,
              onReorderItem: (from, to) =>
                  _change(() => list.insert(to, list.removeAt(from))),
              itemBuilder: (_, index) {
                final item = list[index];
                final watched = _data.isWatched(item);
                return _VideoEntryCard(
                  key: ValueKey(item.id),
                  source: item,
                  status: status(item),
                  progress: progress(item),
                  onTap: () => _play(list, index),
                  actions: [
                    if (item.telegram != null)
                      VideoWatchButton(
                        watched: watched,
                        onPressed: () =>
                            _change(() => _data.setWatched(item, !watched)),
                      ),
                    IconButton(
                      tooltip: 'Remove video',
                      icon: const Icon(Icons.close),
                      onPressed: () => _change(() => list.remove(item)),
                    ),
                    _itemActions(
                      item,
                      play: () => _play(list, index),
                      remove: () => list.remove(item),
                      removeLabel: 'Remove from playlist',
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: const Tooltip(
                        message: 'Reorder video',
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.drag_handle_rounded),
                        ),
                      ),
                    ),
                  ],
                );
              },
            )
        else if (widget.playlists)
          if (entries.isEmpty)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'Make room for your favorites',
                'Create your first playlist to collect videos for later.',
                Icons.video_library_outlined,
              ),
            )
          else
            _collectionGrid(context, entries.length, (_, index) {
              final entry = entries[index];
              return _VideoPlaylistCard(
                name: entry.key,
                sources: entry.value,
                onOpen: () => setState(() => _selected = entry.key),
                onRename: () => _rename(entry.key),
                onRemove: () => _removePlaylist(entry.key),
              );
            })
        else if (history.isEmpty)
          const SliverToBoxAdapter(
            child: _VideoEmptyCollection(
              'A fresh start',
              'Videos you open will appear here, with watched status and saved resume points.',
              Icons.history_rounded,
            ),
          )
        else
          SliverList.builder(
            itemCount: history.length,
            itemBuilder: (context, index) {
              final entry = history[index];
              final source = entry.source;
              final date = MaterialLocalizations.of(context)
                  .formatCompactDate(entry.playedAt.toLocal());
              final watched = _data.isWatched(source);
              return _VideoEntryCard(
                key: ValueKey(source.id),
                source: source,
                date: date,
                status: status(source),
                progress: progress(source),
                onTap: () => _play([source], 0),
                actions: [
                  if (source.telegram != null)
                    VideoWatchButton(
                      watched: watched,
                      onPressed: () =>
                          _change(() => _data.setWatched(source, !watched)),
                    ),
                  IconButton(
                    tooltip: 'Remove from history',
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        _change(() => _data.removeHistory(source.id)),
                  ),
                  _itemActions(
                    source,
                    play: () => _play([source], 0),
                    remove: () => _data.removeHistory(source.id),
                    removeLabel: 'Remove from history',
                  ),
                ],
              );
            },
          ),
      ],
    );
    return widget.embedded
        ? page
        : PopScope(
            canPop: !inPlaylist,
            onPopInvokedWithResult: (popped, _) {
              if (!popped && inPlaylist) _backToOverview();
            },
            child: page,
          );
  }
}

Future<Directory> _snapshotDirectory() async {
  final root = await getApplicationSupportDirectory();
  return Directory('${root.path}${Platform.pathSeparator}video-snapshots')
      .create(recursive: true);
}

Future<void> storeVideoSnapshot(Uint8List bytes, String filename) async {
  final root = await _snapshotDirectory();
  final file = File(
    '${root.path}${Platform.pathSeparator}'
    '${DateTime.now().microsecondsSinceEpoch}-$filename',
  );
  final temporary = File('${file.path}.partial');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<List<File>> _snapshots() async {
  final root = await _snapshotDirectory();
  return (await root
        .list(followLinks: false)
        .where((entry) => entry is File && entry.path.endsWith('.png'))
        .cast<File>()
        .toList())
    ..sort((a, b) => b.path.compareTo(a.path));
}

String _snapshotName(File file) =>
    file.uri.pathSegments.last.replaceFirst(RegExp(r'^\d+-'), '');

String _snapshotTitle(File file) =>
    _snapshotName(file)
        .replaceFirst(RegExp(r'-\d+ms\.png$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\.png$', caseSensitive: false), '')
        .replaceAll('_', ' ')
        .trim();

Duration? _snapshotPosition(File file) {
  final match = RegExp(
    r'-(\d+)ms\.png$',
    caseSensitive: false,
  ).firstMatch(file.path);
  final milliseconds = match == null ? null : int.tryParse(match[1]!);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

class VideoSnapshotsPage extends StatefulWidget {
  const VideoSnapshotsPage({
    super.key,
    this.loadSnapshots,
    this.embedded = false,
    this.active = true,
    this.bottomPadding = 28,
  });

  final bool embedded;
  final bool active;
  final double bottomPadding;

  @visibleForTesting
  final Future<List<File>> Function()? loadSnapshots;

  @override
  State<VideoSnapshotsPage> createState() => _VideoSnapshotsPageState();
}

class _VideoSnapshotsPageState extends State<VideoSnapshotsPage> {
  late Future<List<File>> _files = _load();

  Future<List<File>> _load() => widget.loadSnapshots?.call() ?? _snapshots();

  @override
  void didUpdateWidget(covariant VideoSnapshotsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _files = _load();
  }

  void _reload() {
    final files = _load();
    setState(() {
      _files = files;
    });
  }

  Future<void> _export(File file) async {
    try {
      final name = _snapshotName(file);
      if (Platform.isAndroid) {
        const platform = MethodChannel('app.auralis/platform');
        final uri = await platform.invokeMethod<String>('createDocument', {
          'name': name,
          'mime': 'image/png',
        });
        if (uri == null) return;
        await platform.invokeMethod<void>('writeDocument', {
          'uri': uri,
          'bytes': await file.readAsBytes(),
        });
      } else {
        final target = await getSaveLocation(suggestedName: name);
        if (target == null) return;
        await file.copy(target.path);
      }
      if (mounted) _message(context, 'Snapshot exported.');
    } catch (_) {
      if (mounted) _message(context, 'Could not export the snapshot.');
    }
  }

  Future<void> _preview(File file) => showAuralisDialog<void>(
    context: context,
    builder: (dialog) => AuralisDialog(
      title: Text(_snapshotName(file)),
      width: 780,
      maxWidth: 900,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(dialog).height * .55,
        ),
        child: Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              const Text('Could not open this snapshot.'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () => _export(file),
          child: const Text('Export PNG'),
        ),
      ],
    ),
  );

  Future<void> _delete(File file) async {
    if (!await _confirm(
          context,
          'Delete this snapshot?',
          'The saved frame will be removed from the snapshot library.',
        ) ||
        !mounted) {
      return;
    }
    try {
      await file.delete();
      if (mounted) _reload();
    } catch (_) {
      if (mounted) _message(context, 'Could not delete the snapshot.');
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<File>>(
    future: _files,
    builder: (_, snapshot) {
      final files = snapshot.data;
      return _VideoCollectionPage(
        embedded: widget.embedded,
        bottomPadding: widget.bottomPadding,
        title: 'Video snapshots',
        icon: Icons.photo_library_outlined,
        summary: snapshot.hasError
            ? 'Saved on this device'
            : files == null
            ? 'Loading saved frames…'
            : '${files.length} ${files.length == 1 ? 'snapshot' : 'snapshots'} · Saved on this device',
        description: 'Little moments worth keeping. Open a frame to see it full size or export the original PNG.',
        actions: [
          if (snapshot.hasError)
            OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
        ],
        slivers: [
          if (snapshot.hasError)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'Could not load snapshots',
                'Your saved frames have not been removed. Try loading them again.',
                Icons.broken_image_outlined,
              ),
            )
          else if (files == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (files.isEmpty)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'Keep a favorite frame',
                'Use Snapshot in the video player to build your own gallery.',
                Icons.add_photo_alternate_outlined,
              ),
            )
          else
            _collectionGrid(context, files.length, (_, index) {
              final file = files[index];
              return _VideoSnapshotCard(
                key: ValueKey(file.path),
                file: file,
                onOpen: () => _preview(file),
                onDelete: () => _delete(file),
              );
            }, frames: true),
        ],
      );
    },
  );
}
