part of 'app.dart';

extension _DiscoveryPages on _PlayerShellState {
  Widget _sectionHeading(String title, {Widget? action}) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      ?action,
    ],
  );

  Widget _home() {
    final recent = _tracksForIds(player.settings.recentIds).take(12).toList();
    final now = DateTime.now();
    final mix = List<Track>.of(library.tracks)
      ..shuffle(math.Random(now.year * 10000 + now.month * 100 + now.day));
    final settings = player.settings;
    final familiar = {
      for (final track in recent) track.artist,
      for (final track in mix)
        if (settings.favoriteIds.contains(track.id)) track.artist,
    }..remove('');
    final picks = mix
        .where((track) => familiar.contains(track.artist))
        .take(8)
        .toSet();
    final daily = [
      ...picks,
      ...mix.where((track) => !picks.contains(track)).take(24 - picks.length),
    ];
    final stats = settings.listening;
    final hasMusic = daily.isNotEmpty;
    final prompt = !telegram.ready
        ? 'Connect Telegram to bring your music into Auralis.'
        : settings.musicChannels.isEmpty
        ? 'Choose the Telegram channels you want in your music library.'
        : library.loading
        ? 'Your mix will be ready when your tracks load.'
        : 'Refresh your library or choose a channel that has music.';
    final mixCard = DiscoveryCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _colors.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: _colors.onSecondaryContainer),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Daily Mix',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          familiar.isEmpty
                              ? 'From your library'
                              : 'Familiar artists and fresh picks',
                        ),
                      ],
                    ),
                  ),
                ),
                if (hasMusic)
                  IconButton.filledTonal(
                    tooltip: 'Play Daily Mix',
                    onPressed: () => player.play(daily.first, from: daily),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
              ],
            ),
          ),
          if (!hasMusic)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Tracks from your library will appear here.'),
            ),
          if (hasMusic) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
              child: Column(
                children: [
                  for (final track in _mixExpanded ? daily : daily.take(4))
                    _trackTile(
                      track,
                      onPlay: () => player.play(track, from: daily),
                    ),
                ],
              ),
            ),
            if (daily.length > 4)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: TextButton.icon(
                  onPressed: _toggleMixExpanded,
                  icon: Icon(
                    _mixExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _mixExpanded
                        ? 'Show fewer tracks'
                        : 'Show full mix (${daily.length})',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading(
          'Recently played',
          action: IconButton.filledTonal(
            onPressed: _openRecent,
            tooltip: 'Open listening history',
            icon: const Icon(Icons.arrow_forward_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          Text(
            'Your recent tracks will appear here.',
            style: TextStyle(color: _colors.onSurfaceVariant),
          )
        else
          LayoutBuilder(
            builder: (context, box) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < math.min(6, recent.length); i++)
                  SizedBox(
                    width: box.maxWidth < 300
                        ? box.maxWidth
                        : (box.maxWidth - 8) / 2,
                    child: _recentPill(recent[i], recent, i),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        ListenableBuilder(
          key: const ValueKey('home-live-listening-stats'),
          listenable: player.statsChanges,
          builder: (context, _) => RepaintBoundary(
            child: DiscoveryCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeading(
                    'Listening stats',
                    action: IconButton.filledTonal(
                      tooltip: 'Open listening stats',
                      onPressed: _stats,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                    ),
                  ),
                  Text(
                    'All time',
                    style: TextStyle(color: _colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    listeningTime(stats.milliseconds),
                    style: Theme.of(context).textTheme.headlineLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  Text('${stats.plays} plays · ${stats.tracks.length} tracks'),
                  if (stats.tracks.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Top track',
                      style: TextStyle(color: _colors.onSurfaceVariant),
                    ),
                    Text(
                      stats.topTrack!.value.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Text(
                    'Last 7 days',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  ListeningBars(
                    points: listeningDays(stats, now, 7),
                    height: 48,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    return ListView(
      key: const PageStorageKey('home-scroll'),
      padding: EdgeInsets.only(bottom: _dockPadding),
      children: [
        Text(
          'AURALIS',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: _colors.primary,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        DiscoveryHero(
          tracks: daily.take(4).toList(),
          artwork: (track) =>
              Artwork(seed: track.title, telegram: telegram, track: track),
          description: hasMusic
              ? 'A daily mix from your music library.'
              : prompt,
          action: hasMusic
              ? IconButton.filled(
                  tooltip: 'Shuffle Daily Mix',
                  onPressed: () {
                    final shuffled = List<Track>.of(daily)..shuffle();
                    player.play(shuffled.first, from: shuffled);
                  },
                  style: IconButton.styleFrom(minimumSize: const Size(60, 60)),
                  icon: const Icon(Icons.shuffle_rounded, size: 26),
                )
              : FilledButton.tonalIcon(
                  onPressed: !telegram.ready
                      ? _openTelegram
                      : _openMusicChannels,
                  icon: Icon(
                    !telegram.ready
                        ? Icons.send_rounded
                        : Icons.library_music_rounded,
                  ),
                  label: Text(
                    !telegram.ready
                        ? 'Connect Telegram'
                        : settings.musicChannels.isEmpty
                        ? 'Choose channels'
                        : 'Open Browse',
                  ),
                ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 760
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: mixCard),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: side),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [mixCard, const SizedBox(height: 18), side],
                ),
        ),
      ],
    );
  }

  Widget _recentPill(Track track, List<Track> queue, int index) {
    final (background, foreground) = discoveryColors(index, _colors);
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => player.play(track, from: queue),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(5, 5, 10, 5),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 35,
                  child: Artwork(
                    seed: track.title,
                    telegram: telegram,
                    track: track,
                    small: true,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: foreground, fontSize: 11),
                    ),
                  ],
                ),
              ),
              _trackActions(
                track,
                onPlay: () => player.play(track, from: queue),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshMusicBrowse() async {
    if (!telegram.ready ||
        telegram.busy ||
        library.saving ||
        library.loading ||
        _cachingLibrary) {
      return;
    }
    telegram.clearChannelMediaCounts(video: false);
    await Future.wait([
      telegram.action(telegram.refreshChats),
      _refreshLibrary(),
    ]);
  }

  Widget _discover() {
    final query = _browseSearchOpen ? search.text.trim().toLowerCase() : '';
    final (:channels, :checking) = _matchingMusicChannels(query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_keyboardOpen && !_browseSearchOpen) ...[
          BrowseChannelsHeader(onSearch: _focusDiscovery),
          const SizedBox(height: 8),
        ],
        if (_browseSearchOpen) ...[
          InlineSearchField(
            key: const ValueKey('music-browse-search'),
            controller: search,
            focusNode: _discoveryFocus,
            onClose: _closeDiscoverySearch,
          ),
          const SizedBox(height: 8),
        ],
        if (telegram.ready && telegram.error != null) _banner(telegram.error!),
        if (library.error != null) _banner(library.error!),
        if (!_keyboardOpen &&
            (_cachingLibrary || _cacheReport?.scope == _libraryCacheScope))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _libraryCacheStatus(),
            ),
          ),
        Expanded(
          child: LibraryRefresh(
            onRefresh: _refreshMusicBrowse,
            child: channels.isEmpty
                ? ListView(
                    padding: EdgeInsets.only(bottom: _dockPadding),
                    children: [_musicBrowseEmpty(query, checking: checking)],
                  )
                : _discoveryGrid(
                    key: const PageStorageKey('music-browse-grid'),
                    count: channels.length,
                    itemBuilder: (_, index) =>
                        _musicChannelTile(channels[index], index),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _discoveryGrid({
    required Key key,
    required int count,
    required IndexedWidgetBuilder itemBuilder,
  }) => GridView.builder(
    key: key,
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: EdgeInsets.only(bottom: _dockPadding),
    gridDelegate: discoveryGridDelegate(context),
    itemCount: count,
    itemBuilder: itemBuilder,
  );

  ({List<MusicChat> channels, bool checking}) _matchingMusicChannels(
    String query,
  ) {
    if (!telegram.ready) return (channels: const [], checking: false);
    final settings = player.settings;
    final channels = {
      for (final channel in settings.selectedChannels) channel.id: channel,
      for (final channel in telegram.channels) channel.id: channel,
    };
    return matchingBrowseChannels(
      channels.values.where(
        (channel) => !settings.hiddenMusicChannelIds.contains(channel.id),
      ),
      query,
      (channel) =>
          telegram.browseChannelMatches(channel, mode: AppInterface.music),
    );
  }

  Widget _musicBrowseEmpty(String query, {required bool checking}) {
    return DiscoveryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            !telegram.ready
                ? 'Connect Telegram for your music'
                : checking
                ? 'Checking channels…'
                : query.isNotEmpty
                ? 'No matching channels'
                : 'No Telegram channels available',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!telegram.ready)
            TextButton(
              onPressed: _openTelegram,
              child: const Text('Connect Telegram'),
            )
          else if (!checking && query.isEmpty)
            const Text(
              'Join a channel in Telegram, then pull down to refresh.',
            ),
        ],
      ),
    );
  }

  Widget _musicChannelTile(MusicChat channel, int index) {
    final selected = library.selected(channel.id);
    return ChannelMediaCount(
      key: ValueKey(channel.id),
      count: library.trackCount(channel.id),
      estimate: () => telegram.channelMediaCount(channel.id, video: false),
      unit: 'track',
      selected: selected,
      builder: (subtitle) => DiscoveryTile(
        title: channel.title,
        subtitle: subtitle,
        icon: Icons.campaign_rounded,
        index: index,
        selected: selected,
        onTap: library.saving
            ? null
            : () => unawaited(library.select(channel, !selected)),
        onLongPress: library.saving ? null : () => _deleteMusicChannel(channel),
      ),
    );
  }

  Future<void> _deleteMusicChannel(MusicChat channel) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final confirmed = await confirmAuralisAction(
      context,
      title: 'Delete channel?',
      message: 'Remove “${channel.title}” from Auralis Music on this device?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!mounted || !telegram.ready || confirmed != true) return;
    await library.hide(channel);
  }

  String _artistName(Track track) {
    final name = track.artist.trim();
    return name.isEmpty ? 'Unknown artist' : name;
  }

  Widget _musicArtists(List<Track> tracks) {
    final query = search.text.trim().toLowerCase();
    final sort = player.settings.librarySort;
    final history = player.settings.listening.tracks;
    final artists = <String, ({String name, int? rank, int songCount})>{};
    for (final track in tracks) {
      final name = _artistName(track);
      final key = name.toLowerCase();
      if (!key.contains(query)) continue;
      final previous = artists[key];
      final previousRank = previous?.rank;
      final rank = switch (sort) {
        LibrarySort.newest =>
          track.date == 0
              ? previousRank
              : math.min(previousRank ?? -track.date, -track.date),
        LibrarySort.oldest =>
          track.date == 0
              ? previousRank
              : math.min(previousRank ?? track.date, track.date),
        LibrarySort.duration =>
          track.duration == Duration.zero
              ? previousRank
              : (previousRank ?? 0) + track.duration.inMilliseconds,
        LibrarySort.mostPlayed =>
          (previousRank ?? 0) - (history[track.id]?.plays ?? 0),
        LibrarySort.title || LibrarySort.artist => 0,
      };
      artists[key] = (
        name: previous?.name ?? name,
        rank: rank,
        songCount: (previous?.songCount ?? 0) + 1,
      );
    }
    if (artists.isEmpty) {
      return _empty(
        Icons.person_search_rounded,
        'No matching artists',
        'Try another artist name.',
      );
    }
    final keys = artists.keys.toList()
      ..sort((a, b) {
        final order = switch ((artists[a]!.rank, artists[b]!.rank)) {
          (final int left, final int right) => left.compareTo(right),
          (null, int()) => 1,
          (int(), null) => -1,
          (null, null) => 0,
        };
        return order == 0 ? a.compareTo(b) : order;
      });
    return _discoveryGrid(
      key: const PageStorageKey('music-artists-grid'),
      count: keys.length,
      itemBuilder: (_, index) {
        final (:name, :songCount, rank: _) = artists[keys[index]]!;
        return DiscoveryTile(
          key: ValueKey(keys[index]),
          title: name,
          subtitle: '$songCount ${songCount == 1 ? 'song' : 'songs'}',
          icon: Icons.person_rounded,
          index: index,
          onTap: () => _selectArtist(name),
        );
      },
    );
  }
}
