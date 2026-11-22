import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_popups.dart';
import 'app_theme.dart';
import 'library_widgets.dart';
import 'local_media.dart';
import 'models.dart';
import 'storage.dart';
import 'video_library.dart';

class LibrarySourceSwitch extends StatelessWidget {
  const LibrarySourceSwitch({
    super.key,
    required this.local,
    required this.onChanged,
  });

  final bool local;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: false, label: Text('Telegram')),
          ButtonSegment(value: true, label: Text('On this device')),
        ],
        selected: {local},
        onSelectionChanged: (value) {
          FocusManager.instance.primaryFocus?.unfocus();
          if (value.single != local) onChanged(value.single);
        },
      ),
    ),
  );
}

typedef LocalMediaPlay = void Function(List<LocalMedia> rows, int index);

class LocalMediaViewPane extends StatefulWidget {
  const LocalMediaViewPane({
    super.key,
    required this.settings,
    required this.video,
    required this.bottomPadding,
    required this.onPlay,
    required this.onOpenFiles,
    this.onSettings,
    this.platform = const LocalMediaPlatform(),
  });

  final AppSettings settings;
  final bool video;
  final double bottomPadding;
  final LocalMediaPlay onPlay;
  final VoidCallback onOpenFiles;
  final VoidCallback? onSettings;
  final LocalMediaPlatform platform;

  @override
  State<LocalMediaViewPane> createState() => LocalMediaViewPaneState();
}

class LocalMediaViewPaneState extends State<LocalMediaViewPane>
    with WidgetsBindingObserver {
  static const _music = [
    LocalMediaView.songs,
    LocalMediaView.albums,
    LocalMediaView.artists,
    LocalMediaView.genres,
    LocalMediaView.folders,
  ];
  static const _videos = [LocalMediaView.videos, LocalMediaView.folders];

  LocalMediaPlatform get _platform => widget.platform;
  List<LocalMediaView> get _views => widget.video ? _videos : _music;
  late LocalMediaView _view = _views.first;
  late LibrarySort _sort = !widget.video && _platform.windows
      ? LibrarySort.newest
      : LibrarySort.title;
  late final _artwork = _platform.runtimeType == LocalMediaPlatform
      ? localLibraryArtwork
      : LocalArtworkCache(_platform);
  final _search = TextEditingController();
  final _scroll = ScrollController();
  LocalMediaSelection _selection = const LocalMediaSelection([], []);
  final _metadata = <(Uri, int, int), LocalMedia>{};
  final _inFlight = <(Uri, int, int), Future<LocalMedia>>{};
  List<LocalMedia> _index = const [];
  String? _group, _groupLabel;
  LocalMediaAccess? _access;
  bool _scanning = false, _scanAgain = false, _failed = false;
  bool _projecting = false, _indexing = false;
  int _unavailable = 0, _projection = 0, _metadataGeneration = 0;
  int _metadataWorkers = 0;
  final _metadataQueue = <Future<void> Function()>[];
  Timer? _changesTimer, _searchTimer, _metadataTimer;
  StreamSubscription<void>? _observer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_platform.android) {
      _observer = _platform.changes.listen(
        (_) => _scheduleRefresh(),
        onError: (Object _) {},
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh(request: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_observer?.cancel());
    _changesTimer?.cancel();
    _searchTimer?.cancel();
    _metadataTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    _metadataQueue.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_platform.android && state == AppLifecycleState.resumed) {
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    _changesTimer?.cancel();
    _changesTimer = Timer(const Duration(milliseconds: 350), _refresh);
  }

  Future<void> _refresh({bool request = false}) async {
    if (_scanning) {
      _scanAgain = true;
      return;
    }
    setState(() {
      _scanning = true;
      _failed = false;
    });
    try {
      final access = await _platform.access(widget.video);
      if (!mounted) return;
      final effective = request && access == LocalMediaAccess.denied
          ? await _platform.access(widget.video, request: true)
          : access;
      if (!mounted) return;
      if (_access != effective || effective == LocalMediaAccess.limited) {
        _metadata.clear();
        _inFlight.clear();
        _index = const [];
        _selection = const LocalMediaSelection([], []);
        _projection++;
        _metadataGeneration++;
      }
      setState(() => _access = effective);
      if (effective == LocalMediaAccess.denied) return;
      final scan = await _platform.scan(
        widget.video,
        List.of(widget.settings.localMediaFolders),
      );
      if (!mounted || _scanAgain) return;
      final keys = scan.entries.map((item) => item.revision).toSet();
      _metadata.removeWhere((key, _) => !keys.contains(key));
      _index = scan.entries;
      _unavailable = scan.unavailable;
      await _project();
      if (mounted) _indexTagsIfNeeded();
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
        if (_scanAgain) {
          _scanAgain = false;
          unawaited(_refresh());
        }
      }
    }
  }

  Future<void> _changeAccess() async {
    try {
      await _platform.access(widget.video, request: true);
      if (mounted) await _refresh();
    } on Exception {
      if (mounted) _notice('Could not request media access.');
    }
  }

  void _notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _accessSettings() async {
    try {
      await _platform.settings();
    } on Exception {
      if (mounted) _notice('Could not open Android settings.');
    }
  }

  bool backToGroups() {
    if (_group == null) return false;
    _changeView(_view);
    return true;
  }

  void _changeView(LocalMediaView view, {LocalMediaGroup? group}) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _view = view;
      _group = group?.key;
      _groupLabel = group?.label;
    });
    _refreshSelection();
  }

  void _refreshSelection() {
    _searchTimer?.cancel();
    unawaited(_project());
    _indexTagsIfNeeded();
  }

  Future<void> _project() async {
    final generation = ++_projection;
    final entries = _index;
    final metadata = Map.of(_metadata);
    final view = _view;
    final group = _group;
    final query = _search.text.trim().toLowerCase();
    final sort = _sort;
    _projecting = true;
    final result = entries.isEmpty
        ? const LocalMediaSelection([], [])
        : await compute(_select, (entries, metadata, view, group, query, sort));
    if (!mounted || generation != _projection) return;
    setState(() {
      _selection = result;
      _projecting = false;
    });
  }

  Future<LocalMedia> _readMetadata(LocalMedia item, {bool visible = false}) {
    if (_metadata[item.revision] case final cached?) {
      return Future.value(cached);
    }
    if (_inFlight[item.revision] case final pending?) return pending;
    if (!_platform.windows &&
        (!item.isVideo || item.duration > Duration.zero)) {
      return Future.value(item);
    }
    final result = Completer<LocalMedia>();
    final revision = _metadataGeneration;
    _inFlight[item.revision] = result.future;
    Future<void> task() async {
      final updated = mounted && revision == _metadataGeneration
          ? await _platform.metadata(item)
          : item;
      if (mounted && revision == _metadataGeneration) {
        _metadata[item.revision] = updated;
        _inFlight.remove(item.revision);
        if (_indexing || _requiresIndex) {
          _metadataTimer ??= Timer(const Duration(milliseconds: 240), () {
            _metadataTimer = null;
            if (mounted) unawaited(_project());
          });
        }
      }
      result.complete(updated);
    }

    if (visible) {
      _metadataQueue.insert(0, task);
    } else {
      _metadataQueue.add(task);
    }
    _drainMetadata();
    return result.future;
  }

  void _drainMetadata() {
    while (mounted && _metadataWorkers < 3 && _metadataQueue.isNotEmpty) {
      _metadataWorkers++;
      unawaited(
        _metadataQueue.removeAt(0)().whenComplete(() {
          _metadataWorkers--;
          _drainMetadata();
        }),
      );
    }
  }

  bool get _requiresIndex =>
      _sort == LibrarySort.duration ||
      _platform.windows &&
          (_search.text.trim().isNotEmpty ||
              (!widget.video &&
                  (_sort == LibrarySort.title ||
                      _sort == LibrarySort.artist ||
                      _view == LocalMediaView.albums ||
                      _view == LocalMediaView.artists ||
                      _view == LocalMediaView.genres)));

  void _indexTagsIfNeeded() {
    if (_indexing || !_requiresIndex || _index.isEmpty) return;
    // Let the initial viewport request its rows before reading the rest of
    // the tags needed for an explicit search, grouping or metadata sort.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_indexing && _requiresIndex) unawaited(_indexTags());
    });
  }

  Future<void> _indexTags() async {
    setState(() => _indexing = true);
    final entries = _index;
    for (var start = 0; start < entries.length; start += 12) {
      if (!mounted || !_requiresIndex || !identical(entries, _index)) break;
      final missing = entries
          .skip(start)
          .take(12)
          .where((item) => !_metadata.containsKey(item.revision));
      await Future.wait(missing.map((item) => _readMetadata(item)));
    }
    if (mounted) {
      setState(() => _indexing = false);
      if (!identical(entries, _index)) _indexTagsIfNeeded();
    }
  }

  Future<void> _manageFolders() async {
    final folders = List<String>.of(widget.settings.localMediaFolders);
    await showAuralisDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AuralisDialog(
          title: const Text('Media folders'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (folders.isEmpty)
                const Text('Add a folder to include its subfolders.'),
              for (final folder in folders)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(
                    folder,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove ${p.basename(folder)} from library',
                    onPressed: () => update(() => folders.remove(folder)),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                try {
                  final path = await _platform.chooseFolder();
                  if (!context.mounted || path == null) return;
                  final normalized = p.normalize(path);
                  if (folders.any(
                    (folder) =>
                        folder.toLowerCase() == normalized.toLowerCase(),
                  )) {
                    return;
                  }
                  update(() => folders.add(normalized));
                } on Exception {
                  if (mounted) _notice('Could not open the folder picker.');
                }
              },
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || listEquals(folders, widget.settings.localMediaFolders)) {
      return;
    }
    final previous = widget.settings.localMediaFolders;
    widget.settings.localMediaFolders = folders;
    try {
      await widget.settings.save();
    } on Exception {
      widget.settings.localMediaFolders = previous;
      if (mounted) _notice('Could not save the media folders.');
    }
    if (mounted) await _refresh();
  }

  void _play(List<LocalMedia> rows, int index) => widget.onPlay([
    for (final row in rows) _metadata[row.revision] ?? row,
  ], index);

  Future<void> _videoInfo(
    LocalMedia item,
    List<LocalMedia> rows,
    int index,
  ) async {
    final data = widget.settings.videoPlayback;
    final action = await showVideoItemSheet(
      context: context,
      source: item.video,
      data: data,
      artwork: _LocalArtwork(item: item, cache: _artwork),
      lookupDuration: (_) =>
          _readMetadata(item, visible: true).then((media) => media.duration),
    );
    if (!mounted) return;
    switch (action) {
      case 'play':
        _play(rows, index);
      case 'watched':
        setState(
          () => data.setWatched(item.video, !data.isWatched(item.video)),
        );
        await _saveVideo();
      case 'playlist':
        await saveVideoPlaylist(context, data, widget.settings.save, [
          item.video,
        ]);
    }
  }

  Future<void> _saveVideo() async {
    try {
      await widget.settings.save();
    } on Exception {
      if (mounted) _notice('Could not save the watched status.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final denied = _access == LocalMediaAccess.denied;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!keyboard)
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: LibraryCollectionMenu<LocalMediaView>(
                    tooltip: 'Local library view',
                    title: _view.label,
                    icon: _view == LocalMediaView.folders
                        ? Icons.folder_outlined
                        : widget.video
                        ? Icons.video_library_outlined
                        : Icons.library_music_outlined,
                    itemBuilder: (_) => [
                      for (final view in _views)
                        PopupMenuItem(value: view, child: Text(view.label)),
                    ],
                    onSelected: _changeView,
                  ),
                ),
              ),
              if (!denied)
                IconButton(
                  tooltip: 'Refresh local library',
                  onPressed: _scanning ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              if (widget.onSettings != null)
                IconButton(
                  tooltip: 'Settings',
                  onPressed: widget.onSettings,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                ),
              AuralisPopupMenu<String>(
                tooltip: 'Local library actions',
                onSelected: (value) {
                  switch (value) {
                    case 'files':
                      widget.onOpenFiles();
                    case 'folders':
                      unawaited(_manageFolders());
                    case 'settings':
                      unawaited(_accessSettings());
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'files',
                    child: Text('Open files'),
                  ),
                  if (_platform.windows)
                    const PopupMenuItem(
                      value: 'folders',
                      child: Text('Manage folders'),
                    ),
                  if (_platform.android)
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Access settings'),
                    ),
                ],
                child: const Icon(Icons.more_vert_rounded, size: 20),
              ),
            ],
          ),
        if (!denied) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey(('local-search', widget.video)),
                  controller: _search,
                  autocorrect: false,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.video
                        ? 'Search local videos'
                        : 'Search local music',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _search.clear();
                              _refreshSelection();
                            },
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    _searchTimer?.cancel();
                    _searchTimer = Timer(
                      const Duration(milliseconds: 160),
                      _refreshSelection,
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              AuralisPopupMenu<LibrarySort>(
                tooltip: 'Sort local library',
                onSelected: (sort) {
                  setState(() => _sort = sort);
                  _refreshSelection();
                },
                itemBuilder: (_) => [
                  for (final sort in LibrarySort.values)
                    if (sort != LibrarySort.mostPlayed &&
                        (!widget.video || sort != LibrarySort.artist))
                      PopupMenuItem(value: sort, child: Text(sort.label)),
                ],
                child: const Icon(Icons.sort_rounded, size: 20),
              ),
            ],
          ),
          if (_groupLabel case final label?)
            Row(
              children: [
                IconButton(
                  tooltip: 'Back to ${_view.label}',
                  onPressed: backToGroups,
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
        ],
        if (_access == LocalMediaAccess.limited)
          _accessBanner('Showing the videos you allowed.', limited: true),
        if (_failed && !denied)
          _message('Could not refresh the local library.'),
        if (_unavailable != 0) _message('Some folders could not be read.'),
        if (_scanning || _indexing) const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 6),
        Expanded(
          child: Material(
            color: colors.surfaceContainerLowest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: denied
                ? _accessBanner(
                    widget.video
                        ? 'Allow access to browse videos on this device.'
                        : 'Allow access to browse music on this device.',
                  )
                : _buildRows(),
          ),
        ),
      ],
    );
  }

  Widget _accessBanner(String text, {bool limited = false}) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
    child: Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(text),
        TextButton(
          onPressed: _changeAccess,
          child: Text(limited ? 'Manage access' : 'Allow access'),
        ),
        TextButton(
          onPressed: _accessSettings,
          child: const Text('Open settings'),
        ),
      ],
    ),
  );

  Widget _message(String text) => Padding(
    padding: const EdgeInsets.all(12),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _buildRows() {
    final LocalMediaSelection(:rows, :groups) = _selection;
    final grouped = _group == null && _view != _views.first;
    final count = grouped ? groups.length : rows.length;
    if (count == 0) {
      if (_scanning || _projecting || _indexing) return const SizedBox.shrink();
      if (_platform.windows && widget.settings.localMediaFolders.isEmpty) {
        return Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.tonalIcon(
              onPressed: _manageFolders,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add media folders'),
            ),
          ),
        );
      }
      return _message(
        _search.text.trim().isNotEmpty
            ? 'No matching media.'
            : widget.video
            ? 'No local videos found.'
            : 'No local music found.',
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(6, 6, 6, widget.bottomPadding),
      itemCount: count,
      itemBuilder: (context, index) {
        if (grouped) {
          final group = groups[index];
          return _LocalRow(
            title: group.label,
            subtitle: [
              if (group.detail.isNotEmpty) group.detail,
              '${group.count} ${widget.video ? 'videos' : 'songs'}',
            ].join(' · '),
            icon: switch (_view) {
              LocalMediaView.albums => Icons.album_outlined,
              LocalMediaView.artists => Icons.person_outline_rounded,
              LocalMediaView.genres => Icons.category_outlined,
              _ => Icons.folder_outlined,
            },
            onTap: () => _changeView(_view, group: group),
          );
        }
        final item = rows[index];
        final data = widget.settings.videoPlayback;
        return FutureBuilder<LocalMedia>(
          key: ValueKey(item.revision),
          future: _readMetadata(item, visible: true),
          initialData: item,
          builder: (context, snapshot) {
            final media = snapshot.data ?? item;
            final source = media.video;
            final duration = widget.video
                ? data.durationOf(source)
                : media.duration;
            final resume = widget.video ? data.positions[source.id] : null;
            final watched = widget.video && data.isWatched(source);
            return _LocalRow(
              title: media.title,
              subtitle: [
                if (!widget.video) media.artist,
                duration > Duration.zero ? videoDurationText(duration) : '—:—',
                if (watched) 'Watched',
                if (resume != null) 'Resume at ${videoDurationText(resume)}',
              ].join(' · '),
              artwork: _LocalArtwork(item: media, cache: _artwork),
              trailing: widget.video
                  ? IconButton(
                      tooltip: 'Info for ${media.title}',
                      icon: const Icon(Icons.more_vert_rounded, size: 20),
                      onPressed: () => _videoInfo(media, rows, index),
                    )
                  : null,
              onTap: () => _play(rows, index),
            );
          },
        );
      },
    );
  }
}

LocalMediaSelection _select(
  (
    List<LocalMedia>,
    Map<(Uri, int, int), LocalMedia>,
    LocalMediaView,
    String?,
    String,
    LibrarySort,
  )
  request,
) {
  final (entries, metadata, view, group, query, sort) = request;
  return selectLocalMedia(
    [for (final item in entries) metadata[item.revision] ?? item],
    view,
    group,
    query,
    sort,
  );
}

class _LocalRow extends StatelessWidget {
  const _LocalRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.artwork,
    this.icon,
    this.trailing,
  });

  final String title, subtitle;
  final VoidCallback onTap;
  final Widget? artwork, trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: auralisSurfaceShape(colors, radius: 15, borderOpacity: .3),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox(
                    width: 46,
                    height: 46,
                    child:
                        artwork ??
                        ColoredBox(
                          color: colors.surfaceContainerHighest,
                          child: Icon(icon, size: 21),
                        ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                ?trailing,
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalArtwork extends StatelessWidget {
  const _LocalArtwork({required this.item, required this.cache});

  final LocalMedia item;
  final LocalArtworkCache cache;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          item.isVideo ? Icons.movie_outlined : Icons.music_note_rounded,
          color: colors.onSurfaceVariant,
          size: 21,
        ),
      ),
    );
    return FutureBuilder<Uint8List?>(
      future: cache.load(item),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return bytes == null
            ? fallback
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: 144,
                errorBuilder: (_, _, _) => fallback,
              );
      },
    );
  }
}
