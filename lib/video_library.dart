import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_popups.dart';
import 'models.dart';
import 'video_playback_data.dart';

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
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
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

Future<bool> _confirm(BuildContext context, String title, String message) async =>
    await confirmAuralisAction(
      context,
      title: title,
      message: message,
      confirmLabel: 'Remove',
      destructive: true,
    ) == true;

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

class VideoLibraryPage extends StatefulWidget {
  const VideoLibraryPage({
    super.key,
    required this.data,
    required this.save,
    required this.pickFiles,
    required this.playlists,
    this.changes,
  });

  final VideoPlaybackData data;
  final Future<void> Function() save;
  final Future<List<VideoSource>> Function() pickFiles;
  final bool playlists;
  final Listenable? changes;

  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  String? _selected;
  VideoPlaybackData get _data => widget.data;

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
      if (!mounted || videos.isEmpty || !_data.playlists.containsKey(name)) return;
      await _change(() => _data.putPlaylist(name, [..._data.playlists[name]!, ...videos]));
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

  void _play(List<VideoSource> sources, int index) =>
      Navigator.pop(context, (List<VideoSource>.of(sources), index));

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
    final inPlaylist = widget.playlists && name != null && _data.playlists.containsKey(name);
    return PopScope(
      canPop: !inPlaylist,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && inPlaylist) setState(() => _selected = null);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: inPlaylist
              ? () => setState(() => _selected = null)
              : () => Navigator.pop(context)),
          title: Text(widget.playlists ? name ?? 'Video playlists' : 'Video history'),
          actions: [
            if (widget.playlists)
              IconButton(
                tooltip: inPlaylist ? 'Add video files' : 'Create playlist',
                onPressed: inPlaylist ? () => _add(_selected!) : () => _rename(null),
                icon: Icon(inPlaylist ? Icons.playlist_add : Icons.add),
              )
            else if (history.isNotEmpty || _data.positions.isNotEmpty)
              IconButton(
                tooltip: 'Clear video history and resume positions',
                onPressed: () async {
                  if (await _confirm(context, 'Clear video history?',
                      'This also clears saved resume positions.') && mounted) {
                    await _change(_data.clearHistory);
                  }
                },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ),
        body: SafeArea(
          child: inPlaylist
              ? list.isEmpty
                  ? const Center(child: Text('Add videos to this playlist.'))
                  : ReorderableListView.builder(
                      itemCount: list.length,
                      onReorderItem: (from, to) =>
                          _change(() => list.insert(to, list.removeAt(from))),
                      itemBuilder: (_, index) {
                        final item = list[index];
                        final watched = _data.isWatched(item);
                        return ListTile(
                          key: ValueKey(item.id),
                          title: Text(item.title),
                          subtitle: watched ? const Text('Watched') : null,
                          onTap: () => _play(list, index),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (item.telegram != null)
                                VideoWatchButton(
                                  watched: watched,
                                  onPressed: () => _change(() => _data.setWatched(item, !watched)),
                                ),
                              IconButton(
                                tooltip: 'Remove video',
                                icon: const Icon(Icons.close),
                                onPressed: () => _change(() => list.remove(item)),
                              ),
                            ],
                          ),
                        );
                      },
                    )
              : widget.playlists
              ? _data.playlists.isEmpty
                  ? const Center(child: Text('No saved video playlists.'))
                  : ListView(children: [
                      for (final entry in _data.playlists.entries)
                        ListTile(
                          leading: const Icon(Icons.playlist_play),
                          title: Text(entry.key),
                          subtitle: Text('${entry.value.length} videos'),
                          onTap: () => setState(() => _selected = entry.key),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) => action == 'rename'
                                ? _rename(entry.key) : _removePlaylist(entry.key),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'rename', child: Text('Rename')),
                              PopupMenuItem(value: 'remove', child: Text('Remove')),
                            ],
                          ),
                        ),
                    ])
              : history.isEmpty
              ? const Center(child: Text('No videos in history.'))
              : ListView.builder(
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    final entry = history[index];
                    final source = entry.source;
                    final date = MaterialLocalizations.of(context)
                        .formatCompactDate(entry.playedAt.toLocal());
                    final position = _data.positions[source.id];
                    final watched = _data.isWatched(source);
                    return ListTile(
                      leading: const Icon(Icons.history),
                      title: Text(source.title),
                      subtitle: Text(watched
                          ? '$date · Watched'
                          : position == null ? date : '$date · Resume at ${clockText(position)}'),
                      onTap: () => _play([source], 0),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (source.telegram != null)
                            VideoWatchButton(
                              watched: watched,
                              onPressed: () => _change(() => _data.setWatched(source, !watched)),
                            ),
                          IconButton(
                            tooltip: 'Remove from history',
                            icon: const Icon(Icons.close),
                            onPressed: () => _change(() => _data.removeHistory(source.id)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
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
  final file = File('${root.path}${Platform.pathSeparator}'
      '${DateTime.now().microsecondsSinceEpoch}-$filename');
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
  return (await root.list(followLinks: false)
      .where((entry) => entry is File && entry.path.endsWith('.png'))
      .cast<File>().toList())
    ..sort((a, b) => b.path.compareTo(a.path));
}

String _snapshotName(File file) =>
    file.uri.pathSegments.last.replaceFirst(RegExp(r'^\d+-'), '');

class VideoSnapshotsPage extends StatefulWidget {
  const VideoSnapshotsPage({super.key});

  @override
  State<VideoSnapshotsPage> createState() => _VideoSnapshotsPageState();
}

class _VideoSnapshotsPageState extends State<VideoSnapshotsPage> {
  Future<List<File>> _files = _snapshots();

  Future<void> _export(File file) async {
    try {
      final name = _snapshotName(file);
      if (Platform.isAndroid) {
        const platform = MethodChannel('app.auralis/platform');
        final uri = await platform.invokeMethod<String>('createDocument', {
          'name': name, 'mime': 'image/png',
        });
        if (uri == null) return;
        await platform.invokeMethod<void>('writeDocument', {
          'uri': uri, 'bytes': await file.readAsBytes(),
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
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(dialog).height * .55),
        child: Image.file(file, fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Text('Could not open this snapshot.')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close')),
        FilledButton(onPressed: () => _export(file), child: const Text('Export PNG')),
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
      if (mounted) setState(() => _files = _snapshots());
    } catch (_) {
      if (mounted) _message(context, 'Could not delete the snapshot.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Video snapshots')),
    body: SafeArea(
      child: FutureBuilder<List<File>>(
        future: _files,
        builder: (_, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Could not load snapshots.'));
          final files = snapshot.data;
          if (files == null) return const Center(child: CircularProgressIndicator());
          if (files.isEmpty) return const Center(child: Text('Save a frame from the video player.'));
          return ListView.builder(
            itemCount: files.length,
            itemBuilder: (_, index) {
              final file = files[index];
              return ListTile(
                leading: Image.file(file, width: 64, height: 48, cacheWidth: 128, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
                title: Text(_snapshotName(file), maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _preview(file),
                trailing: IconButton(
                  tooltip: 'Delete snapshot',
                  onPressed: () => _delete(file),
                  icon: const Icon(Icons.delete_outline),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}
