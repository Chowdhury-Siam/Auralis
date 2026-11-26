part of 'telegram_video_view.dart';

extension _VideoBrowse on _TelegramVideoViewState {
  List<MusicChat> _matchingChannels(String query) {
    if (!_ready) return const [];
    final opened = <int, DateTime>{};
    if (_browseRecentlyOpened) {
      for (final entry in widget.music.settings.videoPlayback.history.values) {
        final id = int.tryParse(entry.source.channelId ?? '');
        if (id == null) continue;
        final previous = opened[id];
        if (previous == null || entry.playedAt.isAfter(previous)) {
          opened[id] = entry.playedAt;
        }
      }
    }
    return _channels.where((channel) {
      return (!_browseRecentlyOpened || opened.containsKey(channel.id)) &&
          channel.title.toLowerCase().contains(query);
    }).toList()..sort((a, b) {
      if (_browseRecentlyOpened) {
        final newest = opened[b.id]!.compareTo(opened[a.id]!);
        if (newest != 0) return newest;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }

  Widget _channelSearch(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final channels = _matchingChannels(query);
    final padding = EdgeInsets.only(bottom: _bottomPadding(context));
    final showHeader = MediaQuery.viewInsetsOf(this.context).bottom == 0;
    final collectionKey = ValueKey((query, _browseRecentlyOpened));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_ready && showHeader) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  query.isEmpty ? 'Browse channels' : 'Matching channels',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (channels.isNotEmpty)
                discoveryLayoutButton(
                  list: _browseChannelsAsList,
                  onPressed: () => _updateBrowse(
                    () => _browseChannelsAsList = !_browseChannelsAsList,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _search,
          enabled: _ready,
          textInputAction: TextInputAction.search,
          onChanged: (_) => _updateBrowse(() {}),
          onSubmitted: (text) {
            final matches = _matchingChannels(text.trim().toLowerCase());
            if (matches.length == 1) _chooseChannel(matches.single);
          },
          decoration: InputDecoration(
            hintText: 'Search channels',
            enabledBorder: auralisFieldBorder(radius: 24),
            focusedBorder: auralisFieldBorder(
              radius: 24,
              side: BorderSide(color: Theme.of(context).colorScheme.primary),
            ),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear channel search',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => _updateBrowse(_search.clear),
                  ),
          ),
        ),
        if (_ready && showHeader)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All channels'),
                  selected: !_browseRecentlyOpened,
                  showCheckmark: false,
                  onSelected: (_) =>
                      _updateBrowse(() => _browseRecentlyOpened = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Recently opened'),
                  selected: _browseRecentlyOpened,
                  showCheckmark: false,
                  onSelected: (_) =>
                      _updateBrowse(() => _browseRecentlyOpened = true),
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 8),
        Expanded(
          child: LibraryRefresh(
            onRefresh: _refresh,
            child: channels.isEmpty
                ? ListView(
                    key: collectionKey,
                    padding: padding,
                    children: [
                      if (!_ready)
                        _connectState(context)
                      else if (query.isNotEmpty)
                        _emptyState(context, title: 'No matching channels')
                      else if (_browseRecentlyOpened)
                        _emptyState(
                          context,
                          title: 'No recently opened channels',
                          description:
                              'Channels appear here after you play a video.',
                        )
                      else
                        _emptyState(
                          context,
                          title: 'No Telegram channels available',
                        ),
                    ],
                  )
                : _browseChannelsAsList
                ? ListView.separated(
                    key: collectionKey,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: padding,
                    itemCount: channels.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) =>
                        _browseChannelTile(channels[index]),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = 10.0;
                      final width = constraints.maxWidth;
                      final columns = width < 210
                          ? 1
                          : ((width + gap) / 178).floor().clamp(2, 6);
                      final tileWidth = (width - gap * (columns - 1)) / columns;
                      final visibleHeight =
                          constraints.maxHeight - padding.bottom;
                      return GridView.builder(
                        key: collectionKey,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: padding,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: gap,
                          crossAxisSpacing: gap,
                          mainAxisExtent: math.min(
                            tileWidth * 1.5,
                            math.max(128.0, visibleHeight),
                          ),
                        ),
                        itemCount: channels.length,
                        itemBuilder: (_, index) =>
                            _browseChannelTile(channels[index]),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _browseChannelTile(MusicChat channel) {
    final selected = channel.id == _library?.channel.id;
    final artwork = _BrowseChannelArtwork(
      channel: channel,
      telegram: _telegram,
      repository: widget.channelMetadata,
      selected: selected,
    );
    return ChannelMediaCount(
      key: ValueKey(channel.id),
      count: _videoCounts[channel.id],
      estimate: () => _telegram.channelMediaCount(channel.id, video: true),
      unit: 'video',
      selected: selected,
      builder: (subtitle) => _browseChannelsAsList
          ? VideoLibraryRow(
              title: channel.title,
              subtitle: subtitle == null ? null : Text(subtitle),
              selected: selected,
              artwork: artwork,
              trailing: selected
                  ? const Icon(Icons.check_circle_rounded, size: 24)
                  : null,
              onTap: () => _chooseChannel(channel),
            )
          : _BrowsePoster(
              title: channel.title,
              subtitle: subtitle,
              selected: selected,
              artwork: artwork,
              onTap: () => _chooseChannel(channel),
            ),
    );
  }
}

class _BrowsePoster extends StatelessWidget {
  const _BrowsePoster({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.artwork,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final Widget artwork;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: AuralisPressFeedback(
        builder: (context, states) => Material(
          color: colors.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: selected
                ? BorderSide(color: colors.primary, width: 2)
                : BorderSide.none,
          ),
          child: InkWell(
            statesController: states,
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ExcludeSemantics(child: artwork),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .88),
                        ],
                        stops: const [0, .56],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 44, 10, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                          ),
                          if (subtitle case final detail?) ...[
                            const SizedBox(height: 4),
                            Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (selected)
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowseChannelArtwork extends StatefulWidget {
  const _BrowseChannelArtwork({
    required this.channel,
    required this.telegram,
    required this.repository,
    required this.selected,
  });

  final MusicChat channel;
  final TelegramService telegram;
  final ChannelMetadataRepository? repository;
  final bool selected;

  @override
  State<_BrowseChannelArtwork> createState() => _BrowseChannelArtworkState();
}

class _BrowseChannelArtworkState extends State<_BrowseChannelArtwork> {
  Future<MetadataMatch>? _match;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _BrowseChannelArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.channel.id != oldWidget.channel.id ||
        widget.channel.title != oldWidget.channel.title ||
        widget.repository != oldWidget.repository ||
        widget.selected != oldWidget.selected) {
      _load();
    }
  }

  void _load() {
    final repository = widget.repository;
    final channel = widget.channel;
    _match = widget.selected
        ? repository?.identify(channel.id, channel.title)
        : repository?.identifySaved(channel.id);
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = discoveryColors(channel.id.abs(), colors);
    final fallback = channel.photoFileId != null || channel.photoPreview != null
        ? _VideoArtwork(
            telegram: widget.telegram,
            title: channel.title,
            fileId: channel.photoFileId,
            preview: channel.photoPreview,
            placeholderIcon: Icons.video_library_outlined,
          )
        : ColoredBox(
            color: background,
            child: Center(
              child: Text(
                channel.title.trim().characters.firstOrNull?.toUpperCase() ??
                    '?',
                maxLines: 1,
                style: TextStyle(
                  color: foreground,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          );
    final repository = widget.repository;
    if (repository == null) return fallback;
    return FutureBuilder<MetadataMatch>(
      future: _match,
      builder: (context, snapshot) {
        final cover = snapshot.data?.selected?.cover;
        if (cover == null) return fallback;
        return MetadataArtwork(
          key: ValueKey(cover),
          repository: repository,
          url: cover,
          poster: true,
          fallback: fallback,
        );
      },
    );
  }
}
