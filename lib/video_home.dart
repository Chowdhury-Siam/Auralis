part of 'telegram_video_view.dart';

extension _VideoHome on _TelegramVideoViewState {
  Widget _home(BuildContext context) {
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
    final resumeAt = resume == null ? null : data.positions[resume.source.id];
    final recentSources = recent
        .where((entry) => entry.source.id != resume?.source.id)
        .take(5)
        .map((entry) => entry.source);
    final channels = [
      if (library != null) library.channel,
      ..._channels.where(
        (channel) =>
            _videoSources.contains(channel.id) &&
            channel.id != library?.channel.id,
      ),
    ].take(5);

    return ListView(
      key: const PageStorageKey('video-home-scroll'),
      padding: EdgeInsets.only(bottom: _bottomPadding(context)),
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Auralis Video',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.55,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.outlined(
              tooltip: 'Watch history',
              onPressed: _openHomeHistory,
              icon: const Icon(Icons.history_rounded),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _VideoSpotlight(
          key: const ValueKey('video-home-hero'),
          featured: featured,
          resumeAt: resumeAt,
          runtime: featured == null ? Duration.zero : data.durationOf(featured),
          connected: _ready,
          artwork: _spotlightArtwork(featured),
          onPressed: featured != null
              ? () => unawaited(_playHomeSource(featured))
              : _ready
              ? _showChannelSearch
              : widget.onConnect,
        ),
        if (recentSources.isNotEmpty) ...[
          const SizedBox(height: 26),
          _VideoHomeShelf(
            title: 'Recently opened',
            cardWidth: 225,
            children: [
              for (final source in recentSources) _homeRecentCard(source, data),
            ],
          ),
        ],
        if (channels.isNotEmpty) ...[
          const SizedBox(height: 26),
          _VideoHomeShelf(
            title: 'Your channels',
            cardWidth: 208,
            action: TextButton(
              onPressed: _showChannelSearch,
              child: const Text('All channels'),
            ),
            children: [
              for (final channel in channels)
                _homeChannel(
                  channel,
                  selected: channel.id == library?.channel.id,
                ),
            ],
          ),
        ] else if (featured != null && _ready) ...[
          const SizedBox(height: 14),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _showChannelSearch,
              icon: const Icon(Icons.explore_outlined),
              label: const Text('Browse channels'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _spotlightArtwork(VideoSource? source) {
    const cinema = Image(
      image: AssetImage('assets/branding/video-home-cinema.webp'),
      fit: BoxFit.cover,
      alignment: Alignment(.35, -.35),
      excludeFromSemantics: true,
    );
    if (source == null) return cinema;
    final artwork = _historyArtwork(source, fallback: cinema) ?? cinema;
    final library = _library;
    final repository = widget.channelMetadata;
    if (repository == null ||
        library?.channel.id.toString() != source.channelId) {
      return artwork;
    }
    return FutureBuilder<MetadataMatch>(
      future: library?.metadata,
      builder: (context, snapshot) {
        final cover = snapshot.data?.selected?.cover;
        if (cover == null) return artwork;
        return MetadataArtwork(
          key: ValueKey(cover),
          repository: repository,
          url: cover,
          fallback: artwork,
        );
      },
    );
  }

  Future<void> _playHomeSource(VideoSource source) {
    if (source.telegram case final Track video) return _play(video);
    return _launchPlayer([source], 0);
  }

  Widget _homeChannel(MusicChat channel, {required bool selected}) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return Material(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerLow,
          shape: auralisSurfaceShape(colors, radius: 16, borderOpacity: .65),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            selected: selected,
            button: true,
            child: InkWell(
              onTap: () => _openHomeChannel(channel),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 11, 8, 11),
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: ClipOval(
                        child: SizedBox.square(
                          dimension: 40,
                          child: _VideoArtwork(
                            telegram: _telegram,
                            title: channel.title,
                            fileId: channel.photoFileId,
                            preview: channel.photoPreview,
                            placeholderIcon: Icons.video_library_outlined,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        channel.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      selected
                          ? Icons.check_rounded
                          : Icons.chevron_right_rounded,
                      color: selected
                          ? colors.onPrimaryContainer
                          : colors.onSurfaceVariant,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _homeRecentCard(VideoSource source, VideoPlaybackData data) {
    final video = source.telegram;
    final watched = data.isWatched(source);
    const placeholder = _VideoArtworkPlaceholder(Icons.movie_outlined);
    final artwork =
        _historyArtwork(source, fallback: placeholder) ?? placeholder;
    return Builder(
      key: ValueKey(('home-recent', source.id)),
      builder: (context) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return Material(
          color: colors.surfaceContainerLow,
          shape: auralisSurfaceShape(colors, radius: 18, borderOpacity: .5),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(_playHomeSource(source)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ExcludeSemantics(child: artwork),
                      const PositionedDirectional(
                        end: 8,
                        bottom: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xC719141F),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      if (video != null)
                        PositionedDirectional(
                          start: 0,
                          end: 0,
                          bottom: 0,
                          child: _homeDownloadStatus(video),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 5, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              source.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            DefaultTextStyle(
                              style:
                                  (theme.textTheme.labelMedium ??
                                          const TextStyle())
                                      .copyWith(color: colors.onSurfaceVariant),
                              child: VideoRuntimeLabel(
                                duration: data.durationOf(source),
                                lookup: _lookupVideoDuration(source),
                                status: watched
                                    ? 'Watched'
                                    : video?.source ?? 'On your device',
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (video != null) _videoActions(video),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _homeDownloadStatus(Track video) {
    final offline = _telegram.offline;
    return ListenableBuilder(
      listenable: offline,
      builder: (context, _) {
        if (offline.contains(video.id, video: true)) {
          return const Padding(
            padding: EdgeInsetsDirectional.only(start: 10, bottom: 9),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Icon(
                Icons.offline_pin_rounded,
                size: 19,
                color: Colors.white,
                semanticLabel: 'Available offline',
                shadows: [Shadow(blurRadius: 5, color: Colors.black)],
              ),
            ),
          );
        }
        final progress = offline.downloadProgress(video.id, video: true);
        if (progress == null) return const SizedBox.shrink();
        return ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (context, fraction, _) => LinearProgressIndicator(
            value: fraction,
            minHeight: 3,
            semanticsLabel: 'Downloading video',
          ),
        );
      },
    );
  }
}

class _VideoSpotlight extends StatelessWidget {
  const _VideoSpotlight({
    super.key,
    required this.featured,
    required this.resumeAt,
    required this.runtime,
    required this.connected,
    required this.artwork,
    required this.onPressed,
  });

  final VideoSource? featured;
  final Duration? resumeAt;
  final Duration runtime;
  final bool connected;
  final Widget artwork;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final source = featured;
    final position = resumeAt;
    final progress = position == null || runtime <= Duration.zero
        ? null
        : (position.inMicroseconds / runtime.inMicroseconds).clamp(0.0, 1.0);
    final detail = position != null
        ? 'Resume at ${clockText(position)}'
        : source != null
        ? source.telegram?.source ?? 'On your device'
        : connected
        ? 'Discover videos in your Telegram channels.'
        : 'Connect Telegram to start watching.';
    final label = source != null
        ? (position == null ? 'Play video' : 'Resume')
        : connected
        ? 'Browse videos'
        : 'Connect Telegram';
    final icon = source != null
        ? Icons.play_arrow_rounded
        : connected
        ? Icons.explore_outlined
        : Icons.send_rounded;

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: ColoredBox(
        color: const Color(0xFF17111E),
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 670;
            return ConstrainedBox(
              constraints: BoxConstraints(minHeight: wide ? 358 : 308),
              child: Stack(
                alignment: AlignmentDirectional.bottomStart,
                children: [
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: wide && source != null
                          ? Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: FractionallySizedBox(
                                widthFactor: .67,
                                heightFactor: 1,
                                child: artwork,
                              ),
                            )
                          : artwork,
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: wide
                              ? AlignmentDirectional.centerStart
                              : Alignment.topCenter,
                          end: wide
                              ? AlignmentDirectional.centerEnd
                              : Alignment.bottomCenter,
                          colors: wide
                              ? const [
                                  Color(0xFF17111E),
                                  Color(0xF217111E),
                                  Color(0x4017111E),
                                ]
                              : const [
                                  Color(0x2017111E),
                                  Color(0xC717111E),
                                  Color(0xFF17111E),
                                ],
                          stops: wide ? const [0, .52, 1] : const [0, .52, .94],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      wide ? 38 : 20,
                      wide ? 48 : 106,
                      wide ? 38 : 20,
                      wide ? 32 : 20,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: wide
                            ? math.min(550, box.maxWidth * .50)
                            : 440,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (source != null) ...[
                            Text(
                              position == null
                                  ? 'Latest from your channel'
                                  : 'Continue watching',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colors.primaryFixed,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                          ],
                          Semantics(
                            header: true,
                            child: Text(
                              source?.title ?? 'Find your next watch',
                              maxLines: source == null ? null : 3,
                              overflow: source == null
                                  ? null
                                  : TextOverflow.ellipsis,
                              style:
                                  (wide
                                          ? theme.textTheme.displaySmall
                                          : theme.textTheme.headlineMedium)
                                      ?.copyWith(
                                        color: Colors.white,
                                        height: 1.08,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: wide ? -1.15 : -.65,
                                      ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            detail,
                            maxLines: source == null ? null : 2,
                            overflow: source == null
                                ? null
                                : TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFFE0D7E7),
                            ),
                          ),
                          if (progress != null) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              width: 220,
                              child: LinearProgressIndicator(
                                key: const ValueKey(
                                  'video-home-resume-progress',
                                ),
                                value: progress,
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(4),
                                color: colors.primaryFixed,
                                backgroundColor: Colors.white24,
                                trackGap: 0,
                                stopIndicatorRadius: 0,
                                semanticsLabel: 'Playback progress',
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: onPressed,
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.primaryFixed,
                              foregroundColor: colors.onPrimaryFixed,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                            ),
                            icon: Icon(icon, size: 20),
                            label: Text(label),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VideoHomeShelf extends StatelessWidget {
  const _VideoHomeShelf({
    required this.title,
    required this.cardWidth,
    required this.children,
    this.action,
  });

  final String title;
  final double cardWidth;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                ),
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 12.0;
            final wide = constraints.maxWidth >= 680;
            final width = math.min(cardWidth, constraints.maxWidth * .79);
            final items = [
              for (final child in children)
                SizedBox(width: width, child: child),
            ];
            return wide
                ? Wrap(spacing: gap, runSpacing: gap, children: items)
                : SingleChildScrollView(
                    key: PageStorageKey(title),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      spacing: gap,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: items,
                    ),
                  );
          },
        ),
      ],
    );
  }
}
