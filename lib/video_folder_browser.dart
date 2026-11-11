import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'video_playback_data.dart';

const videoFileChannel = MethodChannel('app.auralis/video');
const videoIntentChannel = MethodChannel('app.auralis/video_intents');

List<VideoSource> videosFromAndroid(List<Map<Object?, Object?>>? rows) => [
  for (final row in rows ?? const [])
    if (row['uri'] case final String raw)
      if (Uri.tryParse(raw) case final Uri uri when uri.scheme == 'content')
        VideoSource.file(
          uri,
          row['name'] is String ? row['name'] as String : 'Video',
        ),
];

const videoFileExtensions = [
  'mp4',
  'mkv',
  'webm',
  'mov',
  'avi',
  'm4v',
  'mpg',
  'mpeg',
  'ts',
  'm2ts',
  'wmv',
  'flv',
  'ogv',
  '3gp',
];

class _VideoFolderEntry {
  const _VideoFolderEntry(
    this.uri,
    this.name, {
    this.folder = true,
    this.modified = 0,
    this.size = 0,
  });
  final String uri, name;
  final bool folder;
  final int modified, size;

  VideoSource get source => VideoSource.file(Uri.parse(uri), name);
}

class VideoFolderBrowser extends StatefulWidget {
  const VideoFolderBrowser({super.key, required this.data, required this.save});
  final VideoPlaybackData data;
  final Future<void> Function() save;

  @override
  State<VideoFolderBrowser> createState() => _VideoFolderBrowserState();
}

class _VideoFolderBrowserState extends State<VideoFolderBrowser> {
  final _path = <_VideoFolderEntry>[];
  List<_VideoFolderEntry> _entries = const [];
  final _selection = <String>{};
  final _list = ScrollController();
  static const _rowHeight = 82.0;
  bool _grid = false, _loading = false;
  String? _error;
  int _generation = 0;
  bool _newest = false;

  @override
  void dispose() {
    _generation++;
    _list.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _save() async {
    try {
      await widget.save();
    } catch (_) {
      _message('Could not save video folders.');
    }
  }

  Future<void> _addFolder() async {
    if (_loading) return;
    if (widget.data.folders.length >= 30) {
      _message('Remove a saved folder before adding another.');
      return;
    }
    try {
      late final _VideoFolderEntry entry;
      if (Platform.isAndroid) {
        final folder = await videoFileChannel.invokeMapMethod<String, String>(
          'openFolder',
        );
        if (folder == null) return;
        entry = _VideoFolderEntry(folder['uri']!, folder['name']!);
      } else {
        final path = await getDirectoryPath();
        if (path == null) return;
        final uri = Directory(path).absolute.uri;
        entry = _VideoFolderEntry(
          uri.toString(),
          uri.pathSegments.where((part) => part.isNotEmpty).lastOrNull ?? path,
        );
      }
      if (!mounted) return;
      setState(() => widget.data.folders[entry.uri] = entry.name);
      await _save();
      if (mounted) await _enter(entry);
    } catch (_) {
      _message('Could not open the selected folder.');
    }
  }

  Future<void> _forget(_VideoFolderEntry root) async {
    try {
      if (Platform.isAndroid) {
        await videoFileChannel.invokeMethod<void>('forgetFolder', root.uri);
      }
      if (!mounted) return;
      setState(() => widget.data.folders.remove(root.uri));
      await _save();
    } catch (_) {
      _message('Could not remove access to this folder.');
    }
  }

  Future<void> _enter(_VideoFolderEntry entry) {
    _path.add(entry);
    return _load();
  }

  void _back() {
    if (_selection.isNotEmpty) {
      setState(_selection.clear);
    } else if (_path.isNotEmpty) {
      _path.removeLast();
      _load();
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _selection.clear();
      _error = null;
      _entries = const [];
      _loading = _path.isNotEmpty;
    });
    if (_path.isEmpty) return;
    final directory = _path.last;
    try {
      final entries = Platform.isAndroid
          ? await _androidEntries(directory)
          : await _desktopEntries(directory);
      if (mounted && generation == _generation) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
        if (!_grid) {
          final saved = widget.data.lastLocalVideo;
          if (saved != null) {
            final index = _sorted().indexWhere(
              (entry) => !entry.folder && entry.source.id == saved,
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  generation == _generation &&
                  index > 0 &&
                  _list.hasClients) {
                _list.jumpTo(
                  (index * _rowHeight).clamp(0, _list.position.maxScrollExtent),
                );
              }
            });
          }
        }
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error =
              'This folder is unavailable. Check its storage access and retry.';
          _loading = false;
        });
      }
    }
  }

  Future<List<_VideoFolderEntry>> _androidEntries(
    _VideoFolderEntry directory,
  ) async {
    final rows = await videoFileChannel.invokeListMethod<Map<Object?, Object?>>(
      'listFolder',
      {'root': _path.first.uri, if (_path.length > 1) 'folder': directory.uri},
    );
    return [
      for (final row in rows ?? const [])
        if (row case {'uri': final String uri, 'name': final String name})
          _VideoFolderEntry(
            uri,
            name,
            folder: row['folder'] == true,
            modified: (row['modified'] as int?) ?? 0,
            size: (row['size'] as int?) ?? 0,
          ),
    ];
  }

  Future<List<_VideoFolderEntry>> _desktopEntries(
    _VideoFolderEntry directory,
  ) async {
    final result = <_VideoFolderEntry>[];
    await for (final entity in Directory.fromUri(
      Uri.parse(directory.uri),
    ).list(followLinks: false)) {
      if (entity is! File && entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (entity is File &&
          !videoFileExtensions.contains(name.split('.').last.toLowerCase())) {
        continue;
      }
      final stat = await entity.stat();
      result.add(
        _VideoFolderEntry(
          entity.uri.toString(),
          name,
          folder: entity is Directory,
          modified: stat.modified.millisecondsSinceEpoch,
          size: stat.size,
        ),
      );
    }
    return result;
  }

  List<_VideoFolderEntry> _sorted() => [..._entries]
    ..sort((a, b) {
      if (a.folder != b.folder) return a.folder ? -1 : 1;
      if (_newest && a.modified != b.modified) {
        return b.modified.compareTo(a.modified);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  void _play(_VideoFolderEntry? first) {
    final queue = [
      for (final file in _sorted())
        if (!file.folder &&
            (_selection.isEmpty || _selection.contains(file.uri)))
          file.source,
    ];
    if (queue.isEmpty) return;
    final index = first == null
        ? 0
        : queue.indexWhere((video) => video.uri.toString() == first.uri);
    Navigator.pop(context, (queue, index < 0 ? 0 : index));
  }

  @override
  Widget build(BuildContext context) {
    final root = _path.isEmpty;
    final entries = root
        ? [
            for (final folder in widget.data.folders.entries)
              _VideoFolderEntry(folder.key, folder.value),
          ]
        : _sorted();
    return PopScope(
      canPop: root && _selection.isEmpty,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text(
            root ? 'Video folders' : _path.last.name,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (_selection.isNotEmpty)
              IconButton(
                tooltip: 'Play selected videos',
                onPressed: () => _play(null),
                icon: const Icon(Icons.play_arrow_rounded),
              )
            else if (root)
              IconButton(
                tooltip: 'Add video folder',
                onPressed: _addFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              )
            else ...[
              IconButton(
                tooltip: _newest ? 'Sort by name' : 'Sort by newest',
                onPressed: () => setState(() => _newest = !_newest),
                icon: const Icon(Icons.sort_rounded),
              ),
              IconButton(
                tooltip: _grid ? 'Show list' : 'Show grid',
                onPressed: () => setState(() => _grid = !_grid),
                icon: Icon(
                  _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Refresh folder',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ],
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!),
                  ),
                )
              : entries.isEmpty
              ? Center(
                  child: root
                      ? FilledButton.icon(
                          onPressed: _addFolder,
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('Add video folder'),
                        )
                      : const Text('No videos or subfolders here.'),
                )
              : _grid && !root
              ? GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisExtent: 110,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _entry(entries[index], root),
                )
              : ListView.builder(
                  controller: _list,
                  itemExtent: _rowHeight,
                  padding: const EdgeInsets.all(12),
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _entry(entries[index], root),
                ),
        ),
      ),
    );
  }

  Widget _entry(_VideoFolderEntry entry, bool root) {
    final selected = _selection.contains(entry.uri);
    void choose() => setState(() {
      if (!_selection.remove(entry.uri)) _selection.add(entry.uri);
    });
    final position = entry.folder
        ? null
        : widget.data.positions[entry.source.id];
    final details = position != null
        ? 'Resume at ${clockText(position)}'
        : entry.size > 0
        ? '${(entry.size / (1024 * 1024)).toStringAsFixed(1)} MB'
        : null;
    return Card(
      child: ListTile(
        selected: selected,
        leading: Icon(
          entry.folder
              ? Icons.folder_rounded
              : selected
              ? Icons.check_circle_rounded
              : Icons.video_file_outlined,
        ),
        title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: details == null || _grid
            ? null
            : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: root
            ? IconButton(
                tooltip: 'Remove folder',
                onPressed: () => _forget(entry),
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        onLongPress: entry.folder ? null : choose,
        onTap: entry.folder
            ? () => _enter(entry)
            : _selection.isNotEmpty
            ? choose
            : () => _play(entry),
      ),
    );
  }
}
