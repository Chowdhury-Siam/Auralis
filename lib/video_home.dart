part of 'telegram_video_view.dart';

extension _VideoHome on _TelegramVideoViewState {
  Widget _home(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final data = widget.music.settings.videoPlayback;
    final recent =
        data.history.values
            .where((entry) => _ready || entry.source.telegram == null)
            .toList()
          ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final resume = recent.where((entry) {
      final position = data.positions[entry.source.id];
      if (position == null) return false;
      final runtime = data.durationOf(entry.source);
      return runtime == Duration.zero ||
          runtime - position > const Duration(seconds: 1);
    }).firstOrNull;
    final library = _library;
    final latest = library?.latest;
    final featured =
        resume?.source ??
        (latest == null ? null : VideoSource.telegram(latest));
    final channels = [
      if (library != null) library.channel,
      ..._channels.where(
        (channel) =>
            _videoSources.contains(channel.id) &&
            channel.id != library?.channel.id,
      ),
    ].take(5).toList();
    final recentRows = [
      for (final entry
          in recent
              .where((entry) => entry.source.id != resume?.source.id)
              .take(5))
        entry.source,
    ];

    final recentPanel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Recently opened'),
        const SizedBox(height: 8),
        for (final source in recentRows) ...[
          _homeRecentRow(source, data),
          const SizedBox(height: 6),
        ],
      ],
    );
    final channelPanel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          'Video channels',
          action: TextButton(
            onPressed: _showChannelSearch,
            child: const Text('All channels'),
          ),
        ),
        for (final channel in channels)
          Material(
            color: colors.surfaceContainerLow,
            child: ListTile(
              dense: true,
              minTileHeight: 52,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox.square(
                  dimension: 34,
                  child: _VideoArtwork(
                    telegram: _telegram,
                    title: channel.title,
                    fileId: channel.photoFileId,
                    preview: channel.photoPreview,
                    placeholderIcon: Icons.video_library_outlined,
                  ),
                ),
              ),
              title: Text(
                channel.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(
                channel.id == library?.channel.id
                    ? Icons.check_circle_outline_rounded
                    : Icons.chevron_right_rounded,
                size: 19,
              ),
              onTap: () => _openHomeChannel(channel),
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, box) => ListView(
        key: const PageStorageKey('video-home-scroll'),
        padding: EdgeInsets.only(bottom: _bottomPadding(context)),
        children: [
          Text(
            'Auralis Video',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          _videoHomeHero(
            context,
            featured: featured,
            resumeAt: resume == null ? null : data.positions[resume.source.id],
          ),
          if (featured != null && _ready && channels.isEmpty) ...[
            const SizedBox(height: 5),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _showChannelSearch,
                icon: const Icon(Icons.explore_outlined, size: 19),
                label: const Text('Browse channels'),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (box.maxWidth >= 760 &&
              recentRows.isNotEmpty &&
              channels.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: recentPanel),
                const SizedBox(width: 18),
                Expanded(flex: 2, child: channelPanel),
              ],
            )
          else ...[
            if (recentRows.isNotEmpty) recentPanel,
            if (recentRows.isNotEmpty && channels.isNotEmpty)
              const SizedBox(height: 12),
            if (channels.isNotEmpty) channelPanel,
          ],
        ],
      ),
    );
  }

  Widget _videoHomeHero(
    BuildContext context, {
    required VideoSource? featured,
    required Duration? resumeAt,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final destination = featured != null
        ? (resumeAt == null ? 'Play video' : 'Resume')
        : _ready
        ? 'Browse videos'
        : 'Connect Telegram';
    return DecoratedBox(
      key: const ValueKey('video-home-hero'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [colors.primaryContainer, colors.surfaceContainerHigh],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, box) {
            final showArtwork =
                box.maxWidth >= 245 &&
                MediaQuery.textScalerOf(context).scale(16) < 26;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (showArtwork) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox.square(
                      dimension: box.maxWidth >= 600 ? 124 : 79,
                      child:
                          (featured == null
                              ? null
                              : _historyArtwork(featured)) ??
                          ColoredBox(
                            color: colors.surfaceContainer,
                            child: Icon(
                              Icons.movie_outlined,
                              color: colors.primary,
                              size: 33,
                            ),
                          ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (resumeAt != null)
                        Text(
                          'Continue watching',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      Text(
                        featured?.title ?? 'Your videos',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: colors.onPrimaryContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (featured != null && resumeAt != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Resume at ${clockText(resumeAt)}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: featured != null
                            ? () => unawaited(_playHomeSource(featured))
                            : _ready
                            ? _showChannelSearch
                            : widget.onConnect,
                        icon: Icon(
                          featured != null
                              ? Icons.play_arrow_rounded
                              : _ready
                              ? Icons.explore_outlined
                              : Icons.send_rounded,
                          size: 18,
                        ),
                        label: Text(destination),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _playHomeSource(VideoSource source) {
    if (source.telegram case final Track video) return _play(video);
    return _launchPlayer([source], 0);
  }

  Widget _homeRecentRow(VideoSource source, VideoPlaybackData data) {
    final video = source.telegram;
    final watch = data.isWatched(source);
    return VideoLibraryRow(
      key: ValueKey(('home-recent', source.id)),
      title: source.title,
      watched: watch,
      artwork: _historyArtwork(source) ?? const Icon(Icons.movie_outlined),
      subtitle: VideoRuntimeLabel(
        duration: data.durationOf(source),
        lookup: _lookupVideoDuration(source),
        status: watch ? 'Watched' : video?.source ?? 'On your device',
      ),
      offline: video == null ? null : (media: _telegram.offline, id: video.id),
      trailing: video == null ? null : _videoActions(video),
      onTap: () => unawaited(_playHomeSource(source)),
    );
  }
}
