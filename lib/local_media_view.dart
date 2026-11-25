import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'discovery_widgets.dart';
import 'library_widgets.dart';
import 'local_media.dart';
import 'models.dart';
import 'storage.dart';
import 'video_library.dart';
import 'video_playback_data.dart';

typedef LocalMediaPlay = void Function(List<LocalMedia> rows, int index);

extension LocalMediaViewIcon on LocalMediaView {
  IconData get icon => switch (this) {
    LocalMediaView.songs => Icons.library_music_rounded,
    LocalMediaView.albums => Icons.album_outlined,
    LocalMediaView.artists => Icons.person_rounded,
    LocalMediaView.genres => Icons.category_outlined,
    LocalMediaView.videos => Icons.video_library_rounded,
    LocalMediaView.playlists => Icons.playlist_play_rounded,
    LocalMediaView.history => Icons.history_rounded,
    LocalMediaView.snapshots => Icons.photo_library_outlined,
    LocalMediaView.offline => Icons.download_done_rounded,
    LocalMediaView.favorites => Icons.favorite_rounded,
    LocalMediaView.folders => Icons.folder_outlined,
  };
}

class LocalMediaViewPane extends StatefulWidget {
  const LocalMediaViewPane({
    super.key,
    required this.settings,
    required this.video,
    required this.bottomPadding,
    required this.onPlay,
    required this.onOpenFiles,
    this.sourceButton,
    this.savedVideoCollection,
    this.offlineCollection,
    this.videoPlaylistsController,
    this.playingTrackId,
    this.musicActions,
    this.onSettings,
    this.platform = const LocalMediaPlatform(),
  });

  final AppSettings settings;
  final bool video;
  final double bottomPadding;
  final LocalMediaPlay onPlay;
  final VoidCallback onOpenFiles;
  final Widget? sourceButton;
  final Widget Function(LocalMediaView)? savedVideoCollection;
  final Widget Function(String query)? offlineCollection;
  final VideoLibraryPageController? videoPlaylistsController;
  final String? playingTrackId;
  final Widget Function(Track, VoidCallback, Widget)? musicActions;
  final VoidCallback? onSettings;
  final LocalMediaPlatform platform;

  @override
  State<LocalMediaViewPane> createState() => LocalMediaViewPaneState();
}

class LocalMediaViewPaneState extends State<LocalMediaViewPane> {
  LocalMediaPlatform get _platform => widget.platform;
  List<LocalMediaView> get _views => widget.video
      ? [
          LocalMediaView.videos,
          if (widget.savedVideoCollection != null) ...[
            LocalMediaView.playlists,
            LocalMediaView.history,
            LocalMediaView.snapshots,
          ],
          if (widget.offlineCollection != null) LocalMediaView.offline,
          LocalMediaView.folders,
        ]
      : [
          LocalMediaView.songs,
          LocalMediaView.artists,
          LocalMediaView.favorites,
          if (widget.offlineCollection != null) LocalMediaView.offline,
          LocalMediaView.albums,
          LocalMediaView.genres,
          LocalMediaView.folders,
        ];
  late LocalMediaView _view = _views.first;
  bool get _isMediaView =>
      !_view.isSavedVideoCollection && _view != LocalMediaView.offline;
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
  bool _choosingFolder = false;
  bool _artistsAsList = false;
  bool get _artistOverview => _view == LocalMediaView.artists && _group == null;
  Future<void>? _scan;
  bool get _scanning => _scan != null;
  bool _failed = false;
  Set<String> _favorites = const {};
  bool _projecting = false, _indexing = false;
  int _unavailable = 0, _projection = 0, _metadataGeneration = 0;
  int _metadataWorkers = 0;
  final _metadataQueue = <Future<void> Function()>[];
  Timer? _searchTimer, _metadataTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void didUpdateWidget(covariant LocalMediaViewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_view == LocalMediaView.favorites &&
        !setEquals(_favorites, widget.settings.favoriteIds)) {
      unawaited(_project());
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _metadataTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    _metadataQueue.clear();
    super.dispose();
  }

  Future<void> _refresh() {
    if (_scan case final pending?) return pending;
    if (widget.settings.localMediaFolders.isEmpty) return Future.value();
    final job = _scanFolders().whenComplete(() {
      _scan = null;
      if (mounted) setState(() {});
    });
    setState(() {
      _scan = job;
      _failed = false;
    });
    return job;
  }

  Future<void> _scanFolders() async {
    while (mounted) {
      final folders = List.of(widget.settings.localMediaFolders);
      if (folders.isEmpty) return;
      try {
        final scan = await _platform.scan(
          widget.video,
          [for (final folder in folders) folder.location],
        );
        if (!mounted) return;
        if (!listEquals(folders, widget.settings.localMediaFolders)) continue;
        final keys = scan.entries.map((item) => item.revision).toSet();
        _metadata.removeWhere((key, _) => !keys.contains(key));
        _index = scan.entries;
        _unavailable = scan.unavailable;
        await _project();
        if (mounted && listEquals(folders, widget.settings.localMediaFolders)) {
          _indexTagsIfNeeded();
          return;
        }
      } on Exception {
        if (!mounted) return;
        if (!listEquals(folders, widget.settings.localMediaFolders)) continue;
        setState(() => _failed = true);
        return;
      }
    }
  }

  void _notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  bool backToGroups() {
    if (_group != null) {
      _changeView(_view);
      return true;
    }
    if (_view == LocalMediaView.playlists &&
        widget.videoPlaylistsController?.backToOverview() == true) {
      return true;
    }
    if ((widget.video || _view == LocalMediaView.offline) &&
        _view != _views.first) {
      _changeView(_views.first);
      return true;
    }
    return false;
  }

  void _changeView(LocalMediaView view, {LocalMediaGroup? group}) {
    if (_view == view && _group == group?.key) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _view = view;
      _group = group?.key;
      _groupLabel = group?.label;
      _selection = const LocalMediaSelection([], []);
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
    if (!_isMediaView) {
      _projecting = false;
      return;
    }
    final entries = _index;
    final metadata = Map.of(_metadata);
    final view = _view;
    final group = _group;
    final query = _search.text.trim().toLowerCase();
    final sort = _sort;
    final favorites = view == LocalMediaView.favorites
        ? Set<String>.of(widget.settings.favoriteIds)
        : null;
    _favorites = favorites ?? const {};
    _projecting = true;
    final result = entries.isEmpty
        ? const LocalMediaSelection([], [])
        : await compute(
            _select,
            (entries, metadata, view, group, query, sort, favorites),
          );
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
    if (item.isVideo && item.duration > Duration.zero) {
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
      _isMediaView &&
      (_sort == LibrarySort.duration ||
          !widget.video &&
              (_search.text.trim().isNotEmpty ||
                  _sort == LibrarySort.title ||
                  _sort == LibrarySort.artist ||
                  _view == LocalMediaView.albums ||
                  _view == LocalMediaView.artists ||
                  _view == LocalMediaView.genres));

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

  Future<LocalMediaFolder?> _pickFolder(List<LocalMediaFolder> folders) async {
    if (_choosingFolder) return null;
    _choosingFolder = true;
    try {
      final selected = await _platform.chooseFolder();
      if (selected == null) return null;
      final duplicate = folders.any(
        (folder) => _platform.windows
            ? folder.location.toLowerCase() == selected.location.toLowerCase()
            : folder.location == selected.location,
      );
      return duplicate ? null : selected;
    } on Exception {
      if (mounted) _notice('Could not open the folder picker.');
      return null;
    } finally {
      _choosingFolder = false;
    }
  }

  Future<void> _chooseFirstFolder() async {
    final folder = await _pickFolder(widget.settings.localMediaFolders);
    if (mounted && folder != null) {
      await _saveFolders([...widget.settings.localMediaFolders, folder]);
    }
  }

  Future<void> _manageFolders() async {
    final folders = List<LocalMediaFolder>.of(
      widget.settings.localMediaFolders,
    );
    final updated = await showAuralisDialog<List<LocalMediaFolder>>(
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
                    folder.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: _platform.android ? null : Text(folder.location),
                  trailing: IconButton(
                    tooltip: 'Remove ${folder.name} from library',
                    onPressed: () => update(() => folders.remove(folder)),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                final folder = await _pickFolder(folders);
                if (!context.mounted || folder == null) return;
                update(() => folders.add(folder));
              },
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, folders),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (mounted && updated != null) await _saveFolders(updated);
  }

  Future<void> _saveFolders(List<LocalMediaFolder> folders) async {
    final previous = widget.settings.localMediaFolders;
    if (listEquals(folders, previous)) {
      if (_unavailable != 0) await _refresh();
      return;
    }
    widget.settings.localMediaFolders = folders;
    try {
      await widget.settings.save();
    } on Exception {
      widget.settings.localMediaFolders = previous;
      if (mounted) _notice('Could not save the media folders.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _group = _groupLabel = null;
      _index = const [];
      _selection = const LocalMediaSelection([], []);
      _unavailable = 0;
      _failed = _projecting = false;
      _projection++;
      _metadataGeneration++;
      _metadata.clear();
      _inFlight.clear();
    });
    await _refresh();
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
        await _toggleWatched(item.video);
      case 'playlist':
        await saveVideoPlaylist(context, data, widget.settings.save, [
          item.video,
        ]);
    }
  }

  Future<void> _toggleWatched(VideoSource source) async {
    final data = widget.settings.videoPlayback;
    setState(() => data.setWatched(source, !data.isWatched(source)));
    try {
      await widget.settings.save();
    } on Exception {
      if (mounted) _notice('Could not save the watched status.');
    }
  }

  Widget _actions({required bool hasFolders}) => LibraryActionsMenu(
    actions: [
      (
        label: 'Refresh library',
        icon: Icons.refresh_rounded,
        onSelected: hasFolders && !_scanning
            ? () => unawaited(_refresh())
            : null,
      ),
      if (_artistOverview && hasFolders)
        (
          label: 'Sort Library',
          icon: Icons.sort_rounded,
          onSelected: () => unawaited(_sortDialog().choose(context)),
        ),
      (
        label: 'Open files',
        icon: Icons.folder_open_rounded,
        onSelected: widget.onOpenFiles,
      ),
      (
        label: 'Manage folders',
        icon: Icons.create_new_folder_outlined,
        onSelected: () => unawaited(_manageFolders()),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final views = _views;
    final hasFolders = widget.settings.localMediaFolders.isNotEmpty;
    return LibraryLayout(
      collections: [for (final view in views) (view.label, view.icon)],
      index: views.indexOf(_view),
      onSelected: (index) => _changeView(views[index]),
      sourceButton: widget.sourceButton,
      collectionAction: _artistOverview
          ? discoveryLayoutButton(
              list: _artistsAsList,
              onPressed: () => setState(() => _artistsAsList = !_artistsAsList),
            )
          : _isMediaView
          ? _sortButton()
          : null,
      moreActions: _actions(hasFolders: hasFolders),
      onSettings: widget.onSettings,
      menuKey: ValueKey(
        widget.video ? 'video-library-collection-menu' : 'library-collection-menu',
      ),
      titleKey: ValueKey(widget.video ? 'video-library-title' : 'page-title'),
      indicatorKey: ValueKey(
        widget.video ? 'video-library-indicator' : 'music-library-indicator',
      ),
      reducedMotion: widget.settings.reducedMotion,
      body: _collectionBody(hasFolders: hasFolders),
    );
  }

  Widget _collectionBody({required bool hasFolders}) {
    if (_view.isSavedVideoCollection) return widget.savedVideoCollection!(_view);
    if (_view == LocalMediaView.offline) {
      final offline = widget.offlineCollection!(_search.text);
      return widget.video
          ? offline
          : _mediaPanel(hasFolders: hasFolders, content: offline);
    }
    return _mediaPanel(hasFolders: hasFolders);
  }

  Iterable<LibrarySort> get _sortOptions => widget.video
      ? LibrarySort.videoValues.where((sort) => sort != LibrarySort.artist)
      : LibrarySort.values.where((sort) => sort != LibrarySort.mostPlayed);

  void _selectSort(LibrarySort sort) {
    setState(() => _sort = sort);
    _refreshSelection();
  }

  LibrarySortButton _sortDialog() => LibrarySortButton(
    selected: _sort,
    options: _sortOptions,
    onSelected: _selectSort,
  );

  Widget _sortButton() => widget.video
      ? _sortDialog()
      : LibrarySortMenu(
          selected: _sort,
          options: _sortOptions,
          onSelected: _selectSort,
        );

  Widget _mediaPanel({required bool hasFolders, Widget? content}) {
    return LibraryContentPanel(
      panelKey: widget.video ? const ValueKey(('video-library-panel', 0)) : null,
      search: LibrarySearchField(
        fieldKey: ValueKey(
          widget.video ? 'video-library-search' : 'music-library-search',
        ),
        controller: _search,
        hint: widget.video
            ? 'Search your videos'
            : _artistOverview
            ? 'Search your Artists'
            : 'Search your music',
        onCleared: () {
          setState(() {});
          _refreshSelection();
        },
        onChanged: (_) {
          setState(() {});
          _searchTimer?.cancel();
          _searchTimer = Timer(
            const Duration(milliseconds: 160),
            _refreshSelection,
          );
        },
      ),
      details: [
        if (_groupLabel case final label?)
          Row(
            children: [
              IconButton(
                tooltip: 'Back to ${_view.label}',
                onPressed: backToGroups,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
        if (content == null && _failed)
          _message('Could not refresh the local library.'),
        if (content == null && _unavailable != 0)
          _message(
            'Some folders could not be read. Add them again in Manage folders.',
          ),
      ],
      loading: content == null && (_scanning || _indexing),
      body:
          content ??
          (hasFolders
              ? LibraryRefresh(onRefresh: _refresh, child: _buildRows())
              : Align(
                  alignment: AlignmentDirectional.topStart,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.tonalIcon(
                      onPressed: _chooseFirstFolder,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Choose folder'),
                    ),
                  ),
                )),
    );
  }

  Widget _message(String text) => Padding(
    padding: const EdgeInsets.all(12),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _buildRows() {
    final LocalMediaSelection(:rows, :groups) = _selection;
    final grouped =
        _group == null &&
        _view != _views.first &&
        _view != LocalMediaView.favorites;
    final count = grouped ? groups.length : rows.length;
    if (count == 0) {
      return ListView(
        controller: _scroll,
        children: [
          if (!_scanning && !_projecting && !_indexing)
            _message(
              _search.text.trim().isNotEmpty
                  ? 'No matching media.'
                  : _view == LocalMediaView.favorites
                  ? 'No favorite songs on this device.'
                  : widget.video
                  ? 'No local videos found.'
                  : 'No local music found.',
            ),
        ],
      );
    }
    if (_artistOverview) return _buildArtists(groups);
    return ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.only(bottom: widget.bottomPadding),
      itemCount: count,
      separatorBuilder: (_, _) => SizedBox(height: widget.video ? 8 : 4),
      itemBuilder: (context, index) {
        if (grouped) {
          final group = groups[index];
          final subtitle = [
            if (group.detail.isNotEmpty) group.detail,
            '${group.count} ${widget.video ? 'videos' : 'songs'}',
          ].join(' · ');
          final artwork = _LocalArtworkPlaceholder(icon: _view.icon);
          void open() => _changeView(_view, group: group);
          return widget.video
              ? VideoLibraryRow(
                  title: group.label,
                  subtitle: Text(subtitle),
                  artwork: artwork,
                  onTap: open,
                )
              : MusicLibraryRow(
                  title: group.label,
                  subtitle: subtitle,
                  artwork: artwork,
                  onTap: open,
                );
        }
        final item = rows[index];
        return FutureBuilder<LocalMedia>(
          key: ValueKey(item.revision),
          future: _readMetadata(item, visible: true),
          initialData: item,
          builder: (context, snapshot) {
            final media = snapshot.data ?? item;
            final artwork = _LocalArtwork(item: media, cache: _artwork);
            void play() => _play(rows, index);
            if (!widget.video) {
              final track = media.track;
              final duration = media.duration > Duration.zero
                  ? videoDurationText(media.duration)
                  : '—:—';
              return MusicLibraryRow(
                title: track.title,
                titleKey: ValueKey('track-title-${track.id}'),
                subtitle: '${track.artist} · $duration',
                artwork: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: artwork,
                ),
                active: widget.playingTrackId == track.id,
                trailing: widget.musicActions?.call(track, play, artwork),
                onTap: play,
              );
            }
            final data = widget.settings.videoPlayback;
            final source = media.video;
            final resume = data.positions[source.id];
            final watched = data.isWatched(source);
            return VideoLibraryRow(
              title: media.title,
              watched: watched,
              subtitle: VideoRuntimeLabel(
                duration: data.durationOf(source),
                status: [
                  if (watched) 'Watched',
                  if (resume != null) 'Resume at ${videoDurationText(resume)}',
                ].join(' · '),
              ),
              artwork: watched
                  ? ColorFiltered(
                      colorFilter: const ColorFilter.mode(
                        Colors.grey,
                        BlendMode.saturation,
                      ),
                      child: artwork,
                    )
                  : artwork,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VideoWatchButton(
                    watched: watched,
                    onPressed: () => unawaited(_toggleWatched(source)),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Info for ${media.title}',
                    icon: const Icon(Icons.more_vert_rounded, size: 20),
                    onPressed: () => _videoInfo(media, rows, index),
                  ),
                ],
              ),
              onTap: play,
            );
          },
        );
      },
    );
  }

  Widget _buildArtists(List<LocalMediaGroup> groups) {
    Widget item(BuildContext context, int index) {
      final group = groups[index];
      return DiscoveryTile(
        key: ValueKey(group.key),
        title: group.label,
        subtitle: '${group.count} ${group.count == 1 ? 'song' : 'songs'}',
        icon: Icons.person_rounded,
        index: index,
        list: _artistsAsList,
        onTap: () => _changeView(LocalMediaView.artists, group: group),
      );
    }

    final padding = EdgeInsets.only(bottom: widget.bottomPadding);
    return _artistsAsList
        ? ListView.separated(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: padding,
            itemCount: groups.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: item,
          )
        : GridView.builder(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: padding,
            gridDelegate: discoveryGridDelegate(context),
            itemCount: groups.length,
            itemBuilder: item,
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
    Set<String>?,
  )
  request,
) {
  final (entries, metadata, view, group, query, sort, favorites) = request;
  return selectLocalMedia(
    [
      for (final item in entries)
        if (favorites == null || favorites.contains(item.track.id))
          metadata[item.revision] ?? item,
    ],
    favorites == null ? view : LocalMediaView.songs,
    group,
    query,
    sort,
  );
}

class _LocalArtworkPlaceholder extends StatelessWidget {
  const _LocalArtworkPlaceholder({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.secondaryContainer,
      child: Center(child: Icon(icon, color: colors.onSecondaryContainer)),
    );
  }
}

class _LocalArtwork extends StatelessWidget {
  const _LocalArtwork({required this.item, required this.cache});

  final LocalMedia item;
  final LocalArtworkCache cache;

  @override
  Widget build(BuildContext context) {
    final fallback = _LocalArtworkPlaceholder(
      icon: item.isVideo ? Icons.movie_outlined : Icons.music_note_rounded,
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
