import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_popups.dart';
import 'app_theme.dart';
import 'app_motion.dart';
import 'music_playlist_widgets.dart';
import 'playlist_photos.dart';
import 'models.dart';
import 'media_item_sheet.dart';
import 'offline_media.dart';
import 'offline_media_actions.dart';
import 'telegram/telegram_service.dart';
import 'video_playback_data.dart';

part 'video_library_widgets.dart';

typedef VideoSelection = (List<VideoSource>, int);
typedef VideoDurationLookup = Future<Duration?>? Function(VideoSource);

class VideoRuntimeLabel extends StatelessWidget {
  const VideoRuntimeLabel({
    super.key,
    required this.duration,
    this.lookup,
    this.status = '',
    this.style,
    this.detail = false,
  });

  final Duration duration;
  final Future<Duration?>? lookup;
  final String status;
  final TextStyle? style;
  final bool detail;

  @override
  Widget build(BuildContext context) {
    Widget label(Duration value, {bool loading = false}) {
      if (detail) {
        return SelectableText(
          loading ? 'Reading duration…' : videoDurationText(value),
        );
      }
      final time = value > Duration.zero ? videoDurationText(value) : '—:—';
      final description = value > Duration.zero
          ? 'Duration $time'
          : loading
          ? 'Reading duration'
          : 'Duration unavailable';
      return Text(
        status.isEmpty ? time : '$time · $status',
        semanticsLabel: status.isEmpty ? description : '$description, $status',
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    if (duration > Duration.zero || lookup == null) return label(duration);
    return FutureBuilder<Duration?>(
      future: lookup,
      builder: (context, snapshot) => label(
        snapshot.data ?? Duration.zero,
        loading: snapshot.connectionState == ConnectionState.waiting,
      ),
    );
  }
}

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
  } on FormatException catch (error) {
    if (context.mounted) _message(context, error.message);
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
  VideoDurationLookup? lookupDuration,
  TelegramService? telegram,
}) async {
  final watched = data.isWatched(source);
  final position = data.positions[source.id];
  final duration = data.durationOf(source);
  final track = source.telegram;
  final offline = track == null || telegram == null
      ? null
      : offlineMediaAction(telegram, track, video: true);
  final selected = await showMediaItemSheet(
    context: context,
    title: source.title,
    subtitle: source.telegram?.source ?? 'On your device',
    artwork: artwork ?? _VideoSourcePreview(source),
    details: [
      if (source.telegram case final Track track)
        ...mediaItemDetails(track, video: true, videoDuration: duration)
      else ...[
        ('Mode', 'Video'),
        ('Source', 'On your device'),
        ('Duration', videoDurationText(duration)),
      ],
      ('Status', watched ? 'Watched' : 'Not watched'),
      if (position != null) ('Resume at', clockText(position)),
    ],
    detailValues: {
      if (duration <= Duration.zero && lookupDuration != null)
        'Duration': VideoRuntimeLabel(
          duration: duration,
          lookup: lookupDuration(source),
          detail: true,
        ),
    },
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
      MediaItemAction(
        'watched',
        watched ? 'Mark as unwatched' : 'Mark as watched',
        watched
            ? Icons.check_circle_rounded
            : Icons.radio_button_unchecked_rounded,
        selected: watched,
      ),
      ?offline,
      if (removeLabel != null)
        MediaItemAction(
          'remove',
          removeLabel,
          Icons.remove_circle_outline_rounded,
          destructive: true,
        ),
    ],
  );
  if (selected == 'offline' &&
      context.mounted &&
      telegram != null &&
      track != null) {
    await changeOfflineMedia(context, telegram, track, video: true);
    return null;
  }
  return selected;
}

class VideoLibraryRow extends StatelessWidget {
  const VideoLibraryRow({
    super.key,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.watched = false,
    required this.artwork,
    this.trailing,
    this.offline,
    required this.onTap,
  });

  final String title;
  final Widget? subtitle;
  final bool selected, watched;
  final Widget artwork;
  final Widget? trailing;
  final ({OfflineMedia media, String id})? offline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (offline case (media: final media, id: final id)) {
      return ListenableBuilder(
        listenable: media,
        builder: (context, _) => _row(
          context,
          saved: media.contains(id, video: true),
          download: media.downloadProgress(id, video: true),
        ),
      );
    }
    return _row(context);
  }

  Widget _row(
    BuildContext context, {
    bool saved = false,
    ValueListenable<double?>? download,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final progress = saved ? null : download;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Material(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerLow,
          shape: auralisSurfaceShape(colors, radius: 18, borderOpacity: .35),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            selected: selected,
            child: InkWell(
              onTap: onTap,
              child: Stack(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      8,
                      8,
                      8,
                      progress == null ? 8 : 12,
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox.square(
                            dimension: 64,
                            child: artwork,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: selected
                                      ? colors.onPrimaryContainer
                                      : watched
                                      ? colors.onSurfaceVariant
                                      : null,
                                ),
                              ),
                              if (subtitle != null)
                                DefaultTextStyle(
                                  style:
                                      (theme.textTheme.labelSmall ??
                                              const TextStyle())
                                          .copyWith(
                                            color: selected
                                                ? colors.onPrimaryContainer
                                                : colors.onSurfaceVariant,
                                          ),
                                  child: subtitle!,
                                ),
                              if (saved)
                                _VideoOfflineBadge(
                                  color: selected
                                      ? colors.onPrimaryContainer
                                      : colors.primary,
                                ),
                            ],
                          ),
                        ),
                        if (trailing case final action?) ...[
                          const SizedBox(width: 8),
                          action,
                        ],
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  if (progress != null)
                    PositionedDirectional(
                      start: 76,
                      end: 10,
                      bottom: 5,
                      child: _VideoDownloadProgress(progress: progress),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoDownloadProgress extends StatelessWidget {
  const _VideoDownloadProgress({required this.progress});

  final ValueListenable<double?> progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double?>(
      valueListenable: progress,
      builder: (context, fraction, _) => LinearProgressIndicator(
        value: fraction,
        minHeight: 4,
        borderRadius: BorderRadius.circular(4),
        color: colors.primary,
        backgroundColor: colors.primary.withValues(alpha: .18),
        trackGap: 0,
        stopIndicatorRadius: 0,
        semanticsLabel: 'Video download progress',
        semanticsValue: fraction == null
            ? 'Downloading'
            : '${(fraction * 100).floor()}%',
      ),
    );
  }
}

class _VideoOfflineBadge extends StatelessWidget {
  const _VideoOfflineBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_done_rounded, size: 13, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                'Offline',
                semanticsLabel: 'Saved for offline playback',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
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
    this.historyArtwork,
    this.telegram,
    this.lookupDuration,
    this.changes,
    this.embedded = false,
    this.onPlay,
    this.controller,
    this.bottomPadding = 28,
    this.query = '',
    this.playlistPhotos,
  });

  final VideoPlaybackData data;
  final Future<void> Function() save;
  final Future<List<VideoSource>> Function() pickFiles;
  final bool playlists;
  final Widget? Function(VideoSource)? historyArtwork;
  final TelegramService? telegram;
  final VideoDurationLookup? lookupDuration;
  final Listenable? changes;
  final bool embedded;
  final ValueChanged<VideoSelection>? onPlay;
  final VideoLibraryPageController? controller;
  final double bottomPadding;
  final String query;
  final PlaylistPhotos? playlistPhotos;

  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  String? _selected;
  late final _localPhotos = PlaylistPhotos();
  PlaylistPhotos get _photos => widget.playlistPhotos ?? _localPhotos;
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
    } on FormatException catch (error) {
      if (mounted) _message(context, error.message);
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
        _photos.rename('video', 'device', old, name);
        if (_selected == old) _selected = name;
      } else {
        _photos.remove('video', 'device', name);
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
      _photos.remove('video', 'device', name);
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

  Future<void> _changePhoto(String name, {required bool reset}) async {
    final list = _data.playlists[name];
    if (list == null) return;
    await editPlaylistPhoto(
      context: context,
      photos: _photos,
      mode: 'video',
      scope: 'device',
      name: name,
      reset: reset,
      valid: () => identical(_data.playlists[name], list),
      save: widget.save,
      refresh: () {
        if (mounted) setState(() {});
      },
    );
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
        lookupDuration: widget.lookupDuration,
        telegram: widget.telegram,
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
    final query = widget.query.trim().toLowerCase();
    bool matches(VideoSource source) =>
        '${source.title} ${source.telegram?.source ?? ''}'
            .toLowerCase()
            .contains(query);
    final list = _data.playlists[name] ?? const <VideoSource>[];
    final visibleIndices = [
      for (var index = 0; index < list.length; index++)
        if ((name?.toLowerCase().contains(query) ?? false) ||
            matches(list[index]))
          index,
    ];
    final history = _data.history.values.toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final inPlaylist =
        widget.playlists && name != null && _data.playlists.containsKey(name);
    final entries = _data.playlists.entries
        .where(
          (entry) =>
              entry.key.toLowerCase().contains(query) ||
              entry.value.any(matches),
        )
        .toList();
    final watchedCount = history
        .where((entry) => _data.isWatched(entry.source))
        .length;
    final resumeCount = history
        .where((entry) => _data.positions.containsKey(entry.source.id))
        .length;
    void back() =>
        inPlaylist ? setState(() => _selected = null) : Navigator.pop(context);
    String status(VideoSource source) {
      final watched = _data.isWatched(source);
      final position = _data.positions[source.id];
      if (position == null) return watched ? 'Watched' : 'Ready to play';
      final resume = 'Resume at ${clockText(position)}';
      return watched ? 'Watched · $resume' : resume;
    }

    double? progress(VideoSource source) {
      final position = _data.positions[source.id];
      final duration = _data.durationOf(source);
      return position == null || duration <= Duration.zero
          ? null
          : (position.inMicroseconds / duration.inMicroseconds)
                .clamp(0, 1)
                .toDouble();
    }

    Widget playlistItem(int index, {required bool reorder}) {
      final item = list[index];
      final watched = _data.isWatched(item);
      return _VideoEntryCard(
        key: ValueKey(item.id),
        source: item,
        runtime: _data.durationOf(item),
        lookupDuration: widget.lookupDuration?.call(item),
        status: status(item),
        progress: progress(item),
        onTap: () => _play(list, index),
        actions: [
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
          _itemActions(
            item,
            play: () => _play(list, index),
            remove: () => list.remove(item),
            removeLabel: 'Remove from playlist',
          ),
          if (reorder)
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
    }

    if (widget.playlists && !inPlaylist) {
      final overview = MusicPlaylistsView(
        video: true,
        playlists: [
          for (final entry in entries)
            MusicPlaylistPreview(
              name: entry.key,
              songCount: entry.value.length,
              tracks: entry.value
                  .map((source) => source.telegram)
                  .whereType<Track>()
                  .toList(),
              photo: _photos.photo('video', 'device', entry.key),
            ),
        ],
        artwork: (track) => _VideoSourcePreview(VideoSource.telegram(track)),
        onCreate: () => _rename(null),
        onOpen: (name) => setState(() => _selected = name),
        searching: query.isNotEmpty,
        bottomPadding: widget.bottomPadding,
        actionsBuilder: (playlist) => PlaylistCardMenu(
          name: playlist.name,
          hasPhoto: playlist.photo != null,
          onChangePhoto: () => _changePhoto(playlist.name, reset: false),
          onResetPhoto: () => _changePhoto(playlist.name, reset: true),
          onRename: () => _rename(playlist.name),
          onRemove: () => _removePlaylist(playlist.name),
        ),
      );
      return widget.embedded
          ? overview
          : Scaffold(
              body: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: BackButton(
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                    Expanded(child: overview),
                  ],
                ),
              ),
            );
    }
    final page = _VideoCollectionPage(
      compact: !widget.playlists,
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
      summary: widget.embedded
          ? null
          : widget.playlists
          ? inPlaylist
                ? '${list.length} ${list.length == 1 ? 'video' : 'videos'}'
                : '${entries.length} ${entries.length == 1 ? 'playlist' : 'playlists'} · ${entries.fold<int>(0, (count, entry) => count + entry.value.length)} videos'
          : '${history.length} ${history.length == 1 ? 'video' : 'videos'} · $resumeCount to resume · $watchedCount watched',
      description: widget.playlists
          ? inPlaylist
                ? 'Your next viewing session, in your order. Drag the handles to rearrange videos.'
                : 'Keep favorite episodes and movie nights together. Your files stay where they are.'
          : null,
      trailing:
          !widget.playlists &&
              (_data.history.isNotEmpty || _data.positions.isNotEmpty)
          ? IconButton(
              tooltip: 'Clear history',
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
            )
          : null,
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
      ],
      slivers: [
        if (inPlaylist)
          if (list.isNotEmpty && visibleIndices.isEmpty)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'No videos found',
                'Try another title or clear your search.',
                Icons.search_off_rounded,
              ),
            )
          else if (list.isEmpty)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'Your playlist starts here',
                'Add video files, or save videos from the player queue to this playlist.',
                Icons.playlist_add_rounded,
              ),
            )
          else if (query.isNotEmpty)
            SliverList.builder(
              itemCount: visibleIndices.length,
              itemBuilder: (_, index) =>
                  playlistItem(visibleIndices[index], reorder: false),
            )
          else
            SliverReorderableList(
              itemCount: list.length,
              onReorderItem: (from, to) =>
                  _change(() => list.insert(to, list.removeAt(from))),
              itemBuilder: (_, index) => playlistItem(index, reorder: true),
            )
        else if (history.isEmpty)
          const SliverToBoxAdapter(
            child: _VideoEmptyCollection(
              'A fresh start',
              'Videos you open will appear here, with watched status and saved resume points.',
              Icons.history_rounded,
              compact: true,
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
                compact: true,
                source: source,
                runtime: _data.durationOf(source),
                lookupDuration: widget.lookupDuration?.call(source),
                date: date,
                artwork: widget.historyArtwork?.call(source),
                status: status(source),
                progress: progress(source),
                onTap: () => _play([source], 0),
                actions: [
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
        compact: true,
        embedded: widget.embedded,
        bottomPadding: widget.bottomPadding,
        title: 'Video snapshots',
        icon: Icons.photo_library_outlined,
        summary: snapshot.hasError
            ? 'Saved on this device'
            : files == null
            ? 'Loading saved frames…'
            : '${files.length} ${files.length == 1 ? 'snapshot' : 'snapshots'} · Saved on this device',
        trailing: snapshot.hasError
            ? IconButton(
                tooltip: 'Try again',
                onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded),
              )
            : null,
        slivers: [
          if (snapshot.hasError)
            const SliverToBoxAdapter(
              child: _VideoEmptyCollection(
                'Could not load snapshots',
                'Your saved frames have not been removed. Try loading them again.',
                Icons.broken_image_outlined,
                compact: true,
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
                compact: true,
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
