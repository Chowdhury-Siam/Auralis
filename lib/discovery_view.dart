part of 'app.dart';

enum _BrowseBy {
  channel('Channels', 'channel', Icons.campaign_rounded),
  artist('Artists', 'artist', Icons.person_rounded);

  const _BrowseBy(this.label, this.singular, this.icon);
  final String label, singular;
  final IconData icon;

  String name(Track track) {
    final value = (this == channel ? track.source : track.artist).trim();
    return value.isEmpty ? 'Unknown $singular' : value;
  }

  String group(Track track) {
    final separator = track.id.indexOf(':');
    return this == channel && separator > 0
        ? track.id.substring(0, separator)
        : name(track).toLowerCase();
  }
}

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
    final sync = widget.sync;
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    'AURALIS',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: _colors.primary,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (!_mobileNavigation && sync != null)
                  IconButton.filledTonal(
                    tooltip: 'Account & sync',
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => SyncAccountPage(sync: sync),
                      ),
                    ),
                    icon: const Icon(Icons.cloud_outlined, size: 20),
                  ),
              ],
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
                          telegram.ready && settings.selectedChannels.isNotEmpty
                          ? library.loading
                                ? null
                                : _refreshLibrary
                          : _openTelegram,
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
    final groupId = _browseGroup;
    final group = groupId == null
        ? const <Track>[]
        : library.tracks
              .where((track) => _browseBy.group(track) == groupId)
              .toList();
    final groupName = group.isEmpty ? null : _browseBy.name(group.first);
    final results = groupName != null || search.text.trim().isNotEmpty;
    final groups = <String, List<Track>>{};
    if (!results) {
      for (final track in library.tracks) {
        groups.putIfAbsent(_browseBy.group(track), () => []).add(track);
      }
    }
    final entries = groups.entries.toList()
      ..sort(
        (a, b) => _browseBy
            .name(a.value.first)
            .toLowerCase()
            .compareTo(_browseBy.name(b.value.first).toLowerCase()),
      );
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1150),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _search('Search your music', discover: true),
            const SizedBox(height: 12),
            if (library.loading) const LinearProgressIndicator(minHeight: 2),
            if (library.error != null) _banner(library.error!),
            if (!results && !_keyboardOpen) ...[
              _sectionHeading(
                MediaQuery.textScalerOf(context).scale(20) > 30
                    ? 'Browse'
                    : 'Browse ${_browseBy.label.toLowerCase()}',
                action: discoveryLayoutButton(
                  list: _browseAsList,
                  onPressed: _toggleBrowseLayout,
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final type in _BrowseBy.values)
                    ChoiceChip(
                      label: Text(type.label),
                      selected: type == _browseBy,
                      onSelected: (_) => _setBrowseBy(type),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ] else if (results && (groupName != null || !_keyboardOpen))
              Row(
                children: [
                  if (groupName != null)
                    IconButton(
                      tooltip: 'Back to browse',
                      onPressed: () {
                        search.clear();
                        _selectBrowseGroup(null);
                      },
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  Expanded(
                    child: Text(
                      groupName ?? 'Search results',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            Expanded(
              child: results
                  ? _trackList(
                      _visibleTracks(group.isEmpty ? library.tracks : group),
                    )
                  : groups.isEmpty
                  ? ListView(
                      padding: EdgeInsets.only(bottom: _dockPadding),
                      children: [
                        DiscoveryCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                library.loading
                                    ? 'Finding your music'
                                    : 'Your library is empty',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Add music channels in Telegram to browse songs and artists.',
                              ),
                              if (!library.loading)
                                TextButton.icon(
                                  onPressed: _openTelegram,
                                  icon: const Icon(Icons.send_rounded),
                                  label: const Text('Open Telegram'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : _browseAsList
                  ? ListView.separated(
                      key: const PageStorageKey('browse-list'),
                      padding: EdgeInsets.only(bottom: _dockPadding),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) =>
                          _browseTile(entries[index], index, list: true),
                    )
                  : GridView.builder(
                      key: const PageStorageKey('browse-grid'),
                      padding: EdgeInsets.only(bottom: _dockPadding),
                      gridDelegate: discoveryGridDelegate(context),
                      itemCount: entries.length,
                      itemBuilder: (context, index) =>
                          _browseTile(entries[index], index),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _browseTile(
    MapEntry<String, List<Track>> entry,
    int index, {
    bool list = false,
  }) {
    final name = _browseBy.name(entry.value.first);
    final count =
        '${entry.value.length} ${entry.value.length == 1 ? 'track' : 'tracks'}';
    void open() {
      FocusManager.instance.primaryFocus?.unfocus();
      _selectBrowseGroup(entry.key);
    }

    return DiscoveryTile(
      title: name,
      subtitle: count,
      icon: _browseBy.icon,
      index: index,
      list: list,
      onTap: open,
    );
  }
}
