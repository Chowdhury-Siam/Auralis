import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'app_theme.dart';
import 'channel_metadata.dart';
import 'channel_metadata_view.dart';
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
                          child: SizedBox.square(dimension: 64, child: artwork),
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
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: color, fontWeight: FontWeight.w600),
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

class VideoLibraryPage extends StatefulWidget {
  const VideoLibraryPage({
    super.key,
    required this.data,
    required this.save,
    this.historyArtwork,
    this.channelMetadata,
    this.telegram,
    this.lookupDuration,
    this.changes,
    this.embedded = false,
    this.active = true,
    this.onPlay,
    this.bottomPadding = 28,
  });

  final VideoPlaybackData data;
  final Future<void> Function() save;
  final Widget? Function(VideoSource)? historyArtwork;
  final ChannelMetadataRepository? channelMetadata;
  final TelegramService? telegram;
  final VideoDurationLookup? lookupDuration;
  final Listenable? changes;
  final bool embedded, active;
  final ValueChanged<VideoSelection>? onPlay;
  final double bottomPadding;

  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  final _historyTitles = <int, Future<MetadataMatch>>{};
  VideoPlaybackData get _data => widget.data;

  @override
  void didUpdateWidget(covariant VideoLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelMetadata != widget.channelMetadata ||
        widget.active && !oldWidget.active) {
      _historyTitles.clear();
    }
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

  void _play(List<VideoSource> sources, int index) {
    final selection = (List<VideoSource>.of(sources), index);
    if (widget.onPlay case final callback?) {
      callback(selection);
    } else {
      Navigator.pop(context, selection);
    }
  }

  Future<void> _showItemActions(
    VideoSource source, {
    required VoidCallback play,
    required VoidCallback remove,
    required String removeLabel,
  }) async {
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
      case 'watched':
        await _change(() => _data.setWatched(source, !_data.isWatched(source)));
      case 'remove':
        await _change(remove);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changes = widget.changes;
    return changes == null
        ? _build()
        : ListenableBuilder(listenable: changes, builder: (_, _) => _build());
  }

  Widget _build() {
    final history = _data.history.values.toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final historyRows = <(DateTime?, VideoHistoryEntry?)>[];
    DateTime? previousDay;
    for (final entry in history) {
      final local = entry.playedAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (day != previousDay) {
        historyRows.add((day, null));
        previousDay = day;
      }
      historyRows.add((null, entry));
    }
    return _VideoHistoryLayout(
      embedded: widget.embedded,
      bottomPadding: widget.bottomPadding,
      trailing: _data.history.isNotEmpty || _data.positions.isNotEmpty
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
      content: history.isEmpty
          ? const SliverToBoxAdapter(child: _EmptyVideoHistory())
          : SliverList.builder(
              itemCount: historyRows.length,
              itemBuilder: (context, index) {
                final (day, item) = historyRows[index];
                if (day != null) return _VideoHistoryDate(day);
                final entry = item!;
                final source = entry.source;
                final watched = _data.isWatched(source);
                final repository = widget.channelMetadata;
                final channel = int.tryParse(source.channelId ?? '');
                final metadata = repository == null || channel == null
                    ? null
                    : _historyTitles.putIfAbsent(
                        channel,
                        () => repository.identifySaved(channel),
                      );
                return _VideoHistoryRow(
                  key: ValueKey(source.id),
                  entry: entry,
                  runtime: _data.durationOf(source),
                  lookupDuration: widget.lookupDuration?.call(source),
                  metadata: metadata,
                  repository: repository,
                  artwork: widget.historyArtwork?.call(source),
                  position: _data.positions[source.id],
                  watched: watched,
                  onTap: () => _play([source], 0),
                  onWatch: () =>
                      _change(() => _data.setWatched(source, !watched)),
                  onRemove: () => _change(() => _data.removeHistory(source.id)),
                  onActions: () => _showItemActions(
                    source,
                    play: () => _play([source], 0),
                    remove: () => _data.removeHistory(source.id),
                    removeLabel: 'Remove from history',
                  ),
                );
              },
            ),
    );
  }
}
