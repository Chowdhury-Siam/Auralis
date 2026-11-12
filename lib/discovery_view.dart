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
        : settings.selectedChannels.isEmpty
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
        DiscoveryCard(
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
                  stats.topTracks.first.value.title,
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
              ListeningBars(points: listeningDays(stats, now, 7), height: 48),
            ],
          ),
        ),
      ],
    );
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1150),
        child: ListView(
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
                      style: IconButton.styleFrom(
                        minimumSize: const Size(60, 60),
                      ),
                      icon: const Icon(Icons.shuffle_rounded, size: 26),
                    )
                  : FilledButton.tonalIcon(
                      onPressed:
                          !telegram.ready
                          ? _openTelegram
                          : settings.selectedChannels.isEmpty
                          ? _openMusicChannels
                          : library.loading
                          ? null
                          : _refreshLibrary,
                      icon: Icon(
                        !telegram.ready
                            ? Icons.send_rounded
                            : Icons.library_music_rounded,
                      ),
                      label: Text(
                        !telegram.ready
                            ? 'Connect Telegram'
                            : settings.selectedChannels.isEmpty
                            ? 'Choose channels'
                            : 'Refresh library',
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
        ),
      ),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _discover() {
    final query = search.text.trim().toLowerCase();
    final channels = telegram.ready
        ? _matchingMusicChannels(query)
        : const <MusicChat>[];
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1150),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _search('Search your Channel', discover: true),
            const SizedBox(height: 12),
            if (telegram.ready && telegram.error != null)
              _banner(telegram.error!),
            if (library.error != null) _banner(library.error!),
            if (!_keyboardOpen) ...[
              _sectionHeading(
                MediaQuery.textScalerOf(context).scale(20) > 30
                    ? 'Browse'
                    : 'Browse channels',
                action: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (telegram.ready)
                      IconButton(
                        tooltip: 'Load more channels',
                        onPressed: telegram.busy
                            ? null
                            : () => telegram.action(telegram.refreshChats),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    if (channels.isNotEmpty)
                      discoveryLayoutButton(
                        list: _browseAsList,
                        onPressed: () =>
                            setState(() => _browseAsList = !_browseAsList),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: channels.isEmpty
                  ? ListView(
                      padding: EdgeInsets.only(bottom: _dockPadding),
                      children: [_musicBrowseEmpty(query)],
                    )
                  : _discoveryTiles(
                      page: 'channels',
                      list: _browseAsList,
                      count: channels.length,
                      itemBuilder: (_, index) =>
                          _musicChannelTile(channels[index], index),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _discoveryTiles({
    required String page,
    required bool list,
    required int count,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    final key = PageStorageKey((page, list));
    final padding = EdgeInsets.only(bottom: _dockPadding);
    return list
        ? ListView.separated(
            key: key,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: padding,
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: itemBuilder,
          )
        : GridView.builder(
            key: key,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: padding,
            gridDelegate: discoveryGridDelegate(context),
            itemCount: count,
            itemBuilder: itemBuilder,
          );
  }

  List<MusicChat> _matchingMusicChannels(String query) {
    final channels = {
      for (final channel in player.settings.selectedChannels) channel.id: channel,
      for (final channel in telegram.channels) channel.id: channel,
    };
    return channels.values
        .where((channel) => channel.title.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Widget _musicBrowseEmpty(String query) {
    return DiscoveryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            !telegram.ready
                ? 'Connect Telegram for your music'
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
          else if (query.isEmpty)
            const Text('Join a channel in Telegram, then load more channels.'),
        ],
      ),
    );
  }

  Widget _musicChannelTile(MusicChat channel, int index) {
    final selected = library.selected(channel.id);
    return DiscoveryTile(
      key: ValueKey(channel.id),
      title: channel.title,
      subtitle: selected ? 'Selected in Library' : null,
      icon: Icons.campaign_rounded,
      index: index,
      list: _browseAsList,
      selected: selected,
      leading: _browseAsList
          ? SizedBox.square(
              dimension: 40,
              child: ClipOval(
                child: Artwork(
                  seed: channel.title,
                  small: true,
                  telegram: telegram,
                  fileId: channel.photoFileId,
                  preview: channel.photoPreview,
                ),
              ),
            )
          : null,
      onTap: library.saving
          ? null
          : () => unawaited(library.select(channel, !selected)),
    );
  }

  String _artistName(Track track) {
    final name = track.artist.trim();
    return name.isEmpty ? 'Unknown artist' : name;
  }

  Widget _musicArtists(List<Track> tracks) {
    final query = search.text.trim().toLowerCase();
    final artists = <String, ({String name, int count})>{};
    for (final track in tracks) {
      final name = _artistName(track);
      final key = name.toLowerCase();
      if (key.contains(query)) {
        final previous = artists[key];
        artists[key] = (
          name: previous?.name ?? name,
          count: (previous?.count ?? 0) + 1,
        );
      }
    }
    final keys = artists.keys.toList()..sort();
    if (keys.isEmpty) {
      return _empty(
        Icons.person_search_rounded,
        'No matching artists',
        'Try another artist name.',
      );
    }
    return _discoveryTiles(
      page: 'artists',
      list: _artistsAsList,
      count: keys.length,
      itemBuilder: (_, index) {
        final artist = artists[keys[index]]!;
        final count = artist.count;
        return DiscoveryTile(
          key: ValueKey(keys[index]),
          title: artist.name,
          subtitle: '$count ${count == 1 ? 'track' : 'tracks'}',
          icon: Icons.person_rounded,
          index: index,
          list: _artistsAsList,
          onTap: () => _selectArtist(artist.name),
        );
      },
    );
  }
}
