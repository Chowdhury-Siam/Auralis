part of 'video_library.dart';

class _VideoHistoryLayout extends StatelessWidget {
  const _VideoHistoryLayout({
    required this.content,
    required this.trailing,
    required this.embedded,
    required this.bottomPadding,
  });

  final Widget content;
  final Widget? trailing;
  final bool embedded;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final horizontal = embedded ? 8.0 : 16.0;
    final scroll = CustomScrollView(
      key: const ValueKey('video-collection-scroll'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontal,
            embedded ? 4 : 12,
            horizontal,
            8,
          ),
          sliver: SliverToBoxAdapter(
            child: Row(
              key: const ValueKey('video-collection-header'),
              children: [
                if (!embedded) const BackButton(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'Video history',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          sliver: content,
        ),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
    if (embedded) return scroll;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: scroll,
          ),
        ),
      ),
    );
  }
}

class _EmptyVideoHistory extends StatelessWidget {
  const _EmptyVideoHistory();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('video-collection-empty'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 24, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A fresh start',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Videos you open will appear here, with watched status and saved resume points.',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VideoSourcePreview extends StatelessWidget {
  const VideoSourcePreview(this.source, {super.key});
  final VideoSource? source;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.primaryContainer, colors.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.play_arrow_rounded,
          size: 32,
          color: colors.onPrimaryContainer,
        ),
      ),
    );
    final preview = source?.telegram?.coverPreview;
    return preview == null
        ? fallback
        : Image.memory(
            preview,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
  }
}

class _VideoHistoryDate extends StatelessWidget {
  const _VideoHistoryDate(this.day);
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Compare calendar days so daylight-saving changes do not shift groups.
    final days = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
    final label = switch (days) {
      0 => 'Today',
      1 => 'Yesterday',
      >= 2 && < 7 => '$days days ago',
      _ => MaterialLocalizations.of(context).formatShortDate(day),
    };
    return Padding(
      key: ValueKey(('video-history-date', day)),
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String? _historyEpisode(String title) {
  final season = RegExp(
    r'\bs(\d{1,2})[ ._-]*e(\d{1,4})\b',
    caseSensitive: false,
  ).firstMatch(title.replaceAll('_', ' '));
  if (season != null) {
    return 'S${int.parse(season[1]!)} · Ep. ${int.parse(season[2]!)}';
  }
  final episode = RegExp(
    r'\b(?:episode|ep)\.?\s*(\d{1,4})\b',
    caseSensitive: false,
  ).firstMatch(title);
  final numbered = RegExp(
    r'\s[-–]\s*(\d{1,3})(?:v\d+)?(?=\s|\[|\.|$)',
    caseSensitive: false,
  ).firstMatch(title);
  final number = episode?[1] ?? numbered?[1];
  return number == null ? null : 'Ep. ${int.parse(number)}';
}

class _VideoHistoryRow extends StatelessWidget {
  const _VideoHistoryRow({
    super.key,
    required this.entry,
    required this.runtime,
    required this.position,
    required this.watched,
    required this.onTap,
    required this.onWatch,
    required this.onRemove,
    required this.onActions,
    this.lookupDuration,
    this.artwork,
    this.metadata,
    this.repository,
  });

  final VideoHistoryEntry entry;
  final Duration runtime;
  final Duration? position;
  final bool watched;
  final VoidCallback onTap, onWatch, onRemove, onActions;
  final Future<Duration?>? lookupDuration;
  final Widget? artwork;
  final Future<MetadataMatch>? metadata;
  final ChannelMetadataRepository? repository;

  Widget _details(BuildContext context, Duration duration) {
    final local = entry.playedAt.toLocal();
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final episode = _historyEpisode(entry.source.title);
    final resume = position == null || position == Duration.zero
        ? null
        : '${clockText(position!)} / ${duration > Duration.zero ? clockText(duration) : '—:—'}';
    return Text(
      [?episode, time, ?resume].join(' · '),
      semanticsLabel: [
        ?episode,
        time,
        if (resume != null) 'Resume at ${clockText(position!)}',
        if (watched) 'Watched',
      ].join(', '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  Widget _row(BuildContext context, ChannelTitle? title) {
    final source = entry.source;
    final colors = Theme.of(context).colorScheme;
    final poster = title?.cover != null && repository != null
        ? MetadataArtwork(
            repository: repository!,
            url: title!.cover,
            poster: true,
          )
        : artwork ?? VideoSourcePreview(source);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onActions,
        onSecondaryTap: onActions,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(width: 52, height: 78, child: poster),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title?.title ?? source.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    if (runtime > Duration.zero || lookupDuration == null)
                      _details(context, runtime)
                    else
                      FutureBuilder<Duration?>(
                        future: lookupDuration,
                        builder: (context, snapshot) =>
                            _details(context, snapshot.data ?? Duration.zero),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
                isSelected: watched,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
                padding: const EdgeInsets.all(8),
                icon: const Icon(
                  Icons.radio_button_unchecked_rounded,
                  size: 22,
                ),
                selectedIcon: Icon(
                  Icons.check_circle_rounded,
                  size: 22,
                  color: colors.primary,
                ),
                onPressed: onWatch,
              ),
              IconButton(
                tooltip: 'Remove from history',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
                padding: const EdgeInsets.all(8),
                icon: const Icon(Icons.delete_outline_rounded, size: 22),
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => metadata == null
      ? _row(context, null)
      : FutureBuilder<MetadataMatch>(
          future: metadata,
          builder: (context, snapshot) =>
              _row(context, snapshot.data?.selected),
        );
}
