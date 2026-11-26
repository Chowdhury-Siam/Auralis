import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'models.dart';
import 'channel_metadata.dart';
import 'channel_metadata_view.dart';
import 'library_widgets.dart';
import 'local_media.dart';
import 'discovery_widgets.dart';
import 'app_navigation.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'player.dart';
import 'telegram/stream_proxy.dart';
import 'telegram/telegram_service.dart';
import 'video_playback.dart';
import 'video_playback_data.dart';
import 'video_files.dart';
import 'video_library.dart';

part 'video_home.dart';
part 'video_browse.dart';

class TelegramVideoView extends StatefulWidget {
  const TelegramVideoView({
    super.key,
    required this.telegram,
    required this.music,
    this.onMusic,
    this.channelMetadata,
    this.onSettings,
    this.onConnect,
    this.incoming,
    this.onIncomingConsumed,
  });

  final TelegramService telegram;
  final ChannelMetadataRepository? channelMetadata;
  final PlayerController music;
  final VoidCallback? onMusic, onSettings, onConnect;
  final List<VideoSource>? incoming;
  final ValueChanged<List<VideoSource>>? onIncomingConsumed;

  @override
  State<TelegramVideoView> createState() => _TelegramVideoViewState();
}

class _VideoResults {
  _VideoResults(this.channel);

  final MusicChat channel;
  final videos = <String, Track>{};
  Track? latest;
  final cursors = <bool, int>{false: 0, true: 0};
  List<Track>? sorted;
  LibrarySort? sortOrder;

  List<Track> sortedVideos(VideoPlaybackData data) {
    final order = data.librarySort;
    if (sortOrder != order) {
      sorted = null;
      sortOrder = order;
    }
    if (order != LibrarySort.duration) {
      return sorted ??= sortVideoLibrary(videos.values, order);
    }
    if (sorted case final cached?) return cached;
    final durations = {
      for (final track in videos.values)
        track: data.durationOf(VideoSource.telegram(track)),
    };
    return sorted = videos.values.toList()
      ..sort((a, b) {
        final left = durations[a]!, right = durations[b]!;
        final byDuration = left == Duration.zero || right == Duration.zero
            ? (left == Duration.zero ? 1 : 0).compareTo(
                right == Duration.zero ? 1 : 0,
              )
            : left.compareTo(right);
        return byDuration == 0 ? LibrarySort.title.compare(a, b) : byDuration;
      });
  }

  bool recentPending = true;
  bool get hasMore => recentPending || cursors.isNotEmpty;
  bool loading = false;
  bool failed = false;
}

class _TelegramVideoViewState extends State<TelegramVideoView> {
  TelegramService get _telegram => widget.telegram;
  final _search = TextEditingController();
  final _videoSources = <int>{};
  final _videoCounts = <int, int>{};
  final _durationLookups = <(String, int?, int), Future<Duration?>>{};
  final _durationWorkers = List.generate(2, (_) => Future<void>.value());
  int _nextDurationWorker = 0, _durationSession = 0;
  Timer? _saveDurations;
  late final TelegramStreamProxy _proxy;
  late final bool Function(int) _previousStreaming, _isStreaming;
  late final bool Function(int) _previousPreloading, _isPreloading;
  late final bool Function() _previousActive, _hasActiveStream;
  late bool _ready;
  late final StreamSubscription<({int chatId, Track video})> _postSubscription;
  _VideoResults? _library;
  bool _showSearchChannel = false, _browseChannelsAsList = false;
  bool _browseRecentlyOpened = false;
  int _tab = 0;
  int _libraryCollection = 0;
  static const _collections = [LocalMediaView.videos, LocalMediaView.history];
  bool _openingPlayer = false, _videoMinimized = false;
  List<VideoSource>? _playbackSources;
  int _playbackIndex = 0;
  Future<void> _playbackRelease = Future<void>.value();
  Future<void>? _closingPlayer;

  bool get _showingPlayer => _playbackSources != null && !_videoMinimized;

  List<MusicChat> get _channels => {
    for (final channel in widget.music.settings.selectedChannels)
      channel.id: channel,
    for (final channel in _telegram.channels) channel.id: channel,
  }.values.toList();

  @override
  void initState() {
    super.initState();
    _proxy = TelegramStreamProxy(
      _telegram.request,
      releaseAudio: _telegram.releaseAudio,
    );
    _previousStreaming = _telegram.isStreaming;
    _previousPreloading = _telegram.isPreloading;
    _isPreloading = (id) => _proxy.isPreloading(id) || _previousPreloading(id);
    _telegram.isPreloading = _isPreloading;
    _previousActive = _telegram.hasActiveStream;
    _isStreaming = (id) => _proxy.isStreaming(id) || _previousStreaming(id);
    _hasActiveStream = () =>
        _proxy.hasActiveSource || _proxy.hasPreload || _previousActive();
    _telegram.isStreaming = _isStreaming;
    _telegram.hasActiveStream = _hasActiveStream;
    _ready = _telegram.ready;
    _telegram.addListener(_authorizationChanged);
    _postSubscription = _telegram.videoPosts.listen(_onVideoPost);
    _restoreLibraryChannel();
    if (_ready) unawaited(_refreshChannels());
    _acceptIncoming();
  }

  @override
  void didUpdateWidget(covariant TelegramVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.incoming, oldWidget.incoming)) _acceptIncoming();
  }

  void _acceptIncoming() {
    final sources = widget.incoming;
    if (sources == null || sources.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !identical(widget.incoming, sources)) return;
      widget.onIncomingConsumed?.call(sources);
      await _launchPlayer(sources, 0);
    });
  }

  void _restoreLibraryChannel() {
    if (!_ready || _library != null) return;
    final savedId = widget.music.settings.videoChannelId;
    if (savedId == null) return;
    final channel = _channels
        .where((channel) => channel.id == savedId)
        .firstOrNull;
    if (channel != null) unawaited(_browseChannel(channel));
  }

  void _authorizationChanged() {
    if (_telegram.ready != _ready) {
      setState(() {
        _ready = _telegram.ready;
        _library = null;
        _showSearchChannel = false;
        _browseRecentlyOpened = false;
        _search.clear();
        _videoSources.clear();
        _videoCounts.clear();
        ++_durationSession;
        _durationLookups.clear();
      });
      if (_ready) unawaited(_refreshChannels());
    }
    _restoreLibraryChannel();
  }

  void _onVideoPost(({int chatId, Track video}) post) {
    if (!mounted || !_ready) return;
    final library = _library;
    final known = _videoSources.contains(post.chatId);
    final showPost =
        library != null &&
        library.channel.id == post.chatId &&
        !library.videos.containsKey(post.video.id);
    final invalidateCount =
        library?.channel.id != post.chatId &&
        _videoCounts.containsKey(post.chatId);
    if (known && !showPost && !invalidateCount) return;
    setState(() {
      _videoSources.add(post.chatId);
      if (invalidateCount) _videoCounts.remove(post.chatId);
      if (showPost) _addVideos(library, [post.video]);
    });
  }

  Future<void> _browseChannel(MusicChat channel) {
    final results = _VideoResults(channel);
    unawaited(widget.channelMetadata?.identify(channel.id, channel.title));
    setState(() {
      _library = results;
    });
    final settings = widget.music.settings;
    if (settings.videoChannelId != channel.id) {
      settings.videoChannelId = channel.id;
      unawaited(
        settings.save().catchError((Object _) {
          if (mounted) _notice('Could not save the video channel.');
        }),
      );
    }
    return _load(results);
  }

  Future<void> _load(_VideoResults results) async {
    if (!_ready || results.loading) return;
    bool current() => mounted && _ready && identical(results, _library);
    setState(() {
      results.loading = true;
      results.failed = false;
    });
    await Future.wait([
      if (results.recentPending) _loadRecent(results),
      for (final documents in results.cursors.keys.toList())
        () async {
          try {
            while (current() && results.cursors.containsKey(documents)) {
              final before = results.cursors[documents]!;
              final page = await _telegram.videos(
                results.channel,
                before: before,
                documents: documents,
              );
              if (!current()) return;
              setState(() {
                _addVideos(results, page.tracks);
                final next = page.nextMessageId;
                if (next == 0 || (before != 0 && next >= before)) {
                  results.cursors.remove(documents);
                } else {
                  results.cursors[documents] = next;
                }
              });
              // Yield between pages so scrolling and a new channel selection
              // can run even when TDLib serves pages from its local cache.
              if (results.cursors.containsKey(documents)) {
                await Future<void>.delayed(Duration.zero);
              }
            }
          } catch (_) {
            if (current()) results.failed = true;
          }
        }(),
    ]);
    if (current()) {
      setState(() {
        results.loading = false;
        if (!results.hasMore && !results.failed) {
          _videoCounts[results.channel.id] = results.videos.length;
        }
      });
    }
  }

  void _addVideos(_VideoResults results, Iterable<Track> videos) {
    for (final video in videos) {
      if (results.videos.containsKey(video.id)) continue;
      results.videos[video.id] = video;
      if (results.latest == null || video.date > results.latest!.date) {
        results.latest = video;
      }
      results.sorted = null;
      _videoSources.add(results.channel.id);
    }
    if (_videoCounts.containsKey(results.channel.id) && !results.hasMore) {
      _videoCounts[results.channel.id] = results.videos.length;
    }
  }

  Future<void> _loadRecent(_VideoResults results) async {
    try {
      final videos = await _telegram.recentVideos(results.channel);
      if (!mounted || !_ready || !identical(results, _library)) return;
      setState(() {
        results.recentPending = false;
        _addVideos(results, videos);
      });
    } catch (_) {
      if (mounted && identical(results, _library)) {
        results.failed = true;
      }
    }
  }

  Future<Duration?>? _lookupVideoDuration(VideoSource source) {
    final settings = widget.music.settings;
    final data = settings.videoPlayback;
    if (data.durationOf(source) > Duration.zero || !source.canPlay) return null;
    final reference = source.telegram;
    if (reference != null && !_ready) return null;
    final key = (source.id, reference?.fileId, reference?.size ?? 0);
    if (_durationLookups[key] case final pending?) return pending;
    final generation = _durationSession;
    final slot = _nextDurationWorker++ % _durationWorkers.length;
    bool current() =>
        mounted &&
        identical(settings.videoPlayback, data) &&
        (reference == null || _ready && generation == _durationSession);
    final work = _durationWorkers[slot].then<Duration?>((_) async {
      if (!current()) return null;
      try {
        final Duration? runtime;
        var resolved = source;
        if (reference == null) {
          runtime = await readLocalVideoDuration(source);
        } else {
          final video = reference.fileId != null
              ? reference
              : await _telegram.videoArtworkTrack(reference);
          if (video == null || !current()) return null;
          resolved = VideoSource.telegram(video);
          runtime = await _telegram.readVideoRuntime(video);
        }
        if (runtime == null || !current()) return null;
        if (data.rememberDuration(resolved, runtime)) {
          if (_library?.sortOrder == LibrarySort.duration &&
              _library?.videos.containsKey(resolved.telegram?.id) == true) {
            setState(() => _library?.sorted = null);
          }
          _saveDurations?.cancel();
          _saveDurations = Timer(
            const Duration(milliseconds: 450),
            _flushDurations,
          );
        }
        return runtime;
      } catch (_) {
        return null;
      }
    });
    _durationWorkers[slot] = work.then<void>((_) {});
    if (_durationLookups.length >= 256) {
      _durationLookups.remove(_durationLookups.keys.first);
    }
    return _durationLookups[key] = work;
  }

  void _flushDurations() {
    if (_saveDurations == null) return;
    _saveDurations!.cancel();
    _saveDurations = null;
    unawaited(widget.music.settings.save().catchError((Object _) {}));
  }

  void _recordVideo(VideoSource source) {
    final settings = widget.music.settings;
    settings.videoPlayback.recordVideo(source);
    if (_library?.sortOrder == LibrarySort.duration) _library?.sorted = null;
    unawaited(settings.save().catchError((Object _) {}));
    if (mounted) setState(() {});
  }

  void _toggleWatched(Track episode) {
    final settings = widget.music.settings;
    final source = VideoSource.telegram(episode);
    final data = settings.videoPlayback;
    setState(() => data.setWatched(source, !data.isWatched(source)));
    unawaited(
      settings.save().catchError((Object _) {
        if (mounted) _notice('Could not save the watched status.');
      }),
    );
  }

  bool _isWatched(Track episode) => widget.music.settings.videoPlayback
      .isWatched(VideoSource.telegram(episode));

  String _episodeStatus(Track episode, bool watched) {
    if (watched) return 'Watched';
    final data = widget.music.settings.videoPlayback;
    final source = VideoSource.telegram(episode);
    final position = data.positions[source.id];
    return position == null ? '' : 'Resume at ${clockText(position)}';
  }

  Widget _watchButton(Track episode, bool watched) => VideoWatchButton(
    watched: watched,
    onPressed: () => _toggleWatched(episode),
  );

  Widget _videoActions(Track video) => IconButton.filledTonal(
    tooltip: 'Video actions for ${video.title}',
    icon: const Icon(Icons.more_vert_rounded, size: 20),
    onPressed: () async {
      final source = VideoSource.telegram(video);
      final data = widget.music.settings.videoPlayback;
      final action = await showVideoItemSheet(
        context: context,
        source: source,
        data: data,
        artwork: _videoArtwork(video),
        telegram: _telegram,
        lookupDuration: _lookupVideoDuration,
      );
      if (!mounted || action == null) return;
      switch (action) {
        case 'play':
          await _play(video);
        case 'watched':
          _toggleWatched(video);
      }
    },
  );

  bool _available(VideoSource source) =>
      source.telegram == null ||
      _ready ||
      _telegram.offline.contains(source.telegram!.id, video: true);

  Future<void> _play(Track video) async {
    if (!_ready) return;
    final library = _library;
    final videos = library != null && library.videos.containsKey(video.id)
        ? library.sortedVideos(widget.music.settings.videoPlayback)
        : [video];
    await _launchPlayer(
      videos.map(VideoSource.telegram).toList(),
      videos.indexWhere((item) => item.id == video.id),
    );
  }

  Future<void> _launchPlayer(List<VideoSource> videos, int index) async {
    if (!mounted || _openingPlayer || index < 0 || index >= videos.length) {
      return;
    }
    _openingPlayer = true;
    try {
      if (_playbackSources != null) await _closePlayer();
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      await _playbackRelease;
      if (!mounted) return;
      await widget.music.releaseVideo?.call();
      if (!mounted || !_available(videos[index])) return;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _playbackSources = videos;
        _playbackIndex = index;
        _videoMinimized = false;
      });
    } finally {
      _openingPlayer = false;
    }
  }

  Future<void> _closePlayer() => _closingPlayer ??= _finishClosingPlayer()
      .whenComplete(() => _closingPlayer = null);

  Future<void> _finishClosingPlayer() async {
    if (!mounted || _playbackSources == null) return;
    try {
      await widget.music.releaseVideo?.call();
    } finally {
      if (mounted) {
        setState(() {
          _playbackSources = null;
          _videoMinimized = false;
        });
      }
    }
  }

  void _minimizePlayer() => setState(() => _videoMinimized = true);

  Future<void> _playLibrarySelection(VideoSelection selected) async {
    if (!_available(selected.$1[selected.$2])) {
      _notice('Reconnect Telegram to play this video.');
    } else {
      await _launchPlayer(selected.$1, selected.$2);
    }
  }

  Future<void> _refresh() async {
    if (!_ready) return;
    _telegram.clearChannelMediaCounts(video: true);
    setState(_videoCounts.clear);
    final results = _library;
    await Future.wait([
      if (results != null && !results.loading) _browseChannel(results.channel),
      _refreshChannels(reportError: true),
    ]);
  }

  Future<void> _refreshChannels({bool reportError = false}) async {
    try {
      await _telegram.refreshChats();
    } catch (_) {
      if (mounted && _ready && reportError) {
        _notice('Could not refresh your Telegram channels.');
      }
    }
  }

  void _notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    _flushDurations();
    unawaited(_postSubscription.cancel());
    _telegram.removeListener(_authorizationChanged);
    if (identical(_telegram.isStreaming, _isStreaming)) {
      _telegram.isStreaming = _previousStreaming;
    }
    if (identical(_telegram.isPreloading, _isPreloading)) {
      _telegram.isPreloading = _previousPreloading;
    }
    if (identical(_telegram.hasActiveStream, _hasActiveStream)) {
      _telegram.hasActiveStream = _previousActive;
    }
    unawaited(_playbackRelease.whenComplete(_proxy.close));
    _search.dispose();
    super.dispose();
  }

  void _selectTab(int tab) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _tab = tab);
  }

  void _showChannelSearch() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _showSearchChannel = false;
      _tab = 1;
    });
  }

  void _updateBrowse(VoidCallback update) => setState(update);

  void _chooseChannel(MusicChat channel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _showSearchChannel = _search.text.trim().isNotEmpty);
    if (_library?.channel.id != channel.id) unawaited(_browseChannel(channel));
  }

  Future<void> _setVideoSort(LibrarySort sort) async {
    final settings = widget.music.settings;
    if (!mounted || sort == settings.videoPlayback.librarySort) return;
    setState(() => settings.videoPlayback.librarySort = sort);
    widget.music.refreshSettings();
    try {
      await settings.save();
    } catch (_) {
      if (mounted) _notice('Could not save the Library sort order.');
    }
  }

  VoidCallback get _switchMusic =>
      widget.onMusic ?? () => Navigator.pop(context);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900;
    final settings = widget.music.settings;
    final content = SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          size.width < 1180 ? 16 : 30,
          size.height < 560 ? 12 : 26,
          size.width < 1180 ? 16 : 26,
          0,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1150),
            child: ListenableBuilder(
              listenable: Listenable.merge([
                _telegram,
                widget.music.viewChanges,
              ]),
              builder: (context, _) => switch (_tab) {
                0 => _home(context),
                1 when !_showSearchChannel || _library == null =>
                  _channelSearch(context),
                1 => _browser(context),
                _ => _videoLibrary(context),
              },
            ),
          ),
        ),
      ),
    );
    final browser = PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _showingPlayer) return;
        if (_tab == 2 && _libraryCollection != 0) {
          _selectVideoCollection(0);
          return;
        }
        if (_tab == 1 && _showSearchChannel) {
          _showChannelSearch();
        } else {
          _selectTab(0);
        }
      },
      child: Scaffold(
        extendBody:
            !wide && settings.navigationStyle != AppNavigationStyle.fullWidth,
        bottomNavigationBar: wide
            ? null
            : AppNavigation(
                key: const ValueKey('video-navigation'),
                style: settings.navigationStyle,
                radius: settings.navigationRadius,
                reducedMotion: settings.reducedMotion,
                selected: _tab,
                onSelected: _selectTab,
                onHomeHold: _switchMusic,
                homeHoldHint: 'Switch to Music',
                libraryIcon: Icons.video_library_rounded,
              ),
        body: wide
            ? Row(
                children: [
                  SafeArea(
                    bottom: false,
                    right: false,
                    child: AppSidebar(
                      narrow: size.width < 1180,
                      short: size.height < 560,
                      icon: Icons.movie_rounded,
                      tagline: 'A LITTLE CLOSER TO CINEMA',
                      caption: 'YOUR VIDEOS. YOUR SPACE.\n\nIndependent. Open source.',
                      selected: _tab,
                      onSelected: _selectTab,
                      onHomeHold: _switchMusic,
                      homeHoldHint: 'Switch to Music',
                      libraryIcon: Icons.video_library_rounded,
                      onSettings: widget.onSettings,
                    ),
                  ),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
    );
    final sources = _playbackSources;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: _showingPlayer,
          child: TickerMode(enabled: !_showingPlayer, child: browser),
        ),
        if (sources != null)
          VideoPlayback(
            sources: sources,
            initialIndex: _playbackIndex,
            telegram: _telegram,
            music: widget.music,
            proxy: _proxy,
            onOpened: _recordVideo,
            onWatched: () {
              if (mounted) setState(() {});
            },
            minimized: _videoMinimized,
            miniBottomInset: wide ? 0 : 80,
            onBack: () {
              if (settings.videoPlayback.background) {
                _minimizePlayer();
              } else {
                unawaited(_closePlayer());
              }
            },
            onMinimize: _minimizePlayer,
            onExpand: () {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _videoMinimized = false);
            },
            onClose: () => unawaited(_closePlayer()),
            onRelease: (release) => _playbackRelease = release,
          ),
      ],
    );
  }

  // Scaffold reports the floating bar's height in the body padding.
  double _bottomPadding(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + (_videoMinimized ? 92 : 20);

  void _selectVideoCollection(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _libraryCollection = index;
    });
  }

  Widget _sortButton() => LibrarySortButton(
    selected: widget.music.settings.videoPlayback.librarySort,
    options: LibrarySort.videoValues,
    onSelected: _setVideoSort,
  );

  Widget _videoLibrary(BuildContext context) => _telegramVideoLibrary(context);

  Widget _telegramVideoLibrary(BuildContext context) {
    final settings = widget.music.settings;
    return LibraryLayout(
      // Scaffold consumes body insets; read them above the Scaffold.
      keyboardOpen: MediaQuery.viewInsetsOf(this.context).bottom > 0,
      compactCollection: true,
      collections: [for (final view in _collections) (view.label, view.icon)],
      index: _libraryCollection,
      onSelected: _selectVideoCollection,
      collectionAction: _libraryCollection == 0 ? _sortButton() : null,
      onSettings: MediaQuery.sizeOf(context).width < 900
          ? widget.onSettings
          : null,
      menuKey: const ValueKey('video-library-collection-menu'),
      titleKey: const ValueKey('video-library-title'),
      indicatorKey: const ValueKey('video-library-indicator'),
      reducedMotion: settings.reducedMotion,
      body: LibraryCollectionPager(
        key: const ValueKey('video-library-pager'),
        index: _libraryCollection,
        count: _collections.length,
        reducedMotion: settings.reducedMotion,
        onChanged: _selectVideoCollection,
        itemBuilder: (context, index) => switch (_collections[index]) {
          LocalMediaView.history => _videoHistory(
            context,
            active: index == _libraryCollection,
          ),
          _ => _browser(context),
        },
      ),
    );
  }

  Widget _videoHistory(BuildContext context, {required bool active}) {
    final settings = widget.music.settings;
    return _libraryBrowser(
      context,
      list: VideoLibraryPage(
        data: settings.videoPlayback,
        save: settings.save,
        telegram: _telegram,
        historyArtwork: _historyArtwork,
        channelMetadata: widget.channelMetadata,
        lookupDuration: _lookupVideoDuration,
        embedded: true,
        active: active,
        changes: widget.music.viewChanges,
        bottomPadding: _bottomPadding(context),
        onPlay: (selected) => unawaited(_playLibrarySelection(selected)),
      ),
      panelKey: const ValueKey(('video-library-panel', 1)),
    );
  }

  Widget _libraryBrowser(
    BuildContext context, {
    bool loading = false,
    required Widget list,
    Key panelKey = const ValueKey(('video-library-panel', 0)),
  }) => LibraryContentPanel(panelKey: panelKey, loading: loading, body: list);

  Widget _heading(String title, {Widget? action}) => Row(
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

  void _openHomeChannel(MusicChat channel) {
    _showSearchChannel = false;
    if (_library?.channel.id != channel.id) unawaited(_browseChannel(channel));
    _selectTab(2);
  }

  Widget _emptyState(
    BuildContext context, {
    required String title,
    String? description,
    Widget? action,
  }) => DiscoveryCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(description),
        ],
        ?action,
      ],
    ),
  );

  Widget _connectState(BuildContext context) => _emptyState(
    context,
    title: 'Connect Telegram',
    description: 'Connect your account to access your videos.',
    action: TextButton.icon(
      onPressed: widget.onConnect,
      icon: const Icon(Icons.send_rounded),
      label: const Text('Connect Telegram'),
    ),
  );

  Widget? _historyArtwork(VideoSource source) {
    final reference = source.telegram;
    if (!_telegram.ready || reference == null) return null;
    final video = _library?.videos[reference.id] ?? reference;
    if (video.fileId != null || video.coverFileId != null) {
      return _videoArtwork(video);
    }
    return FutureBuilder<Track?>(
      future: _telegram.videoArtworkTrack(video),
      builder: (context, snapshot) => _videoArtwork(snapshot.data ?? video),
    );
  }

  Widget _videoArtwork(Track video, {bool watched = false}) {
    final artwork = _VideoArtwork(
      telegram: _telegram,
      title: video.title,
      fileId: video.coverFileId,
      preview: video.coverPreview,
    );
    if (!watched) return artwork;
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation),
      child: artwork,
    );
  }

  Widget _browser(BuildContext context) {
    final searching = _tab == 1;
    final results = _library;
    final videos =
        results?.sortedVideos(widget.music.settings.videoPlayback) ??
        const <Track>[];
    final loading = results?.loading ?? false;
    final failed = results?.failed ?? false;
    final list = LibraryRefresh(
      onRefresh: _refresh,
      child: CustomScrollView(
        key: ValueKey((searching, results)),
        slivers: [
          if (!searching && results != null && widget.channelMetadata != null)
            SliverToBoxAdapter(
              child: ChannelMetadataHeader(
                key: ValueKey(('channel-metadata', results.channel.id)),
                channelId: results.channel.id,
                channelName: results.channel.title,
                repository: widget.channelMetadata!,
                onPlay: videos.isEmpty
                    ? null
                    : () => unawaited(_play(videos.first)),
              ),
            ),
          if (videos.isEmpty && !loading)
            SliverToBoxAdapter(
              child: !_ready
                  ? _connectState(context)
                  : results == null
                  ? _emptyState(
                      context,
                      title: 'Browse channel videos',
                      action: TextButton(
                        onPressed: _showChannelSearch,
                        child: const Text('Find a channel'),
                      ),
                    )
                  : _emptyState(
                      context,
                      title: failed
                          ? 'Could not load videos'
                          : 'No playable videos found',
                      description: failed
                          ? 'Check your Telegram connection and pull down to refresh.'
                          : null,
                    ),
            ),
          SliverList.separated(
            itemCount: videos.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final video = videos[index];
              final watched = _isWatched(video);
              final status = _episodeStatus(video, watched);
              final source = VideoSource.telegram(video);
              return VideoLibraryRow(
                key: ValueKey(video.id),
                title: video.title,
                watched: watched,
                subtitle: VideoRuntimeLabel(
                  duration: widget.music.settings.videoPlayback.durationOf(
                    source,
                  ),
                  lookup: _lookupVideoDuration(source),
                  status: status,
                ),
                artwork: _videoArtwork(video, watched: watched),
                offline: (media: _telegram.offline, id: video.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _watchButton(video, watched),
                    _videoActions(video),
                  ],
                ),
                onTap: () => unawaited(_play(video)),
              );
            },
          ),
          if (!searching && !loading && failed)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: OutlinedButton.icon(
                    onPressed: _showChannelSearch,
                    icon: const Icon(Icons.explore_outlined),
                    label: const Text('Open Browse'),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: _bottomPadding(context))),
        ],
      ),
    );
    if (!searching) {
      return _libraryBrowser(context, loading: loading, list: list);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back to channels',
              onPressed: _showChannelSearch,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(
                results!.channel.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _sortButton(),
          ],
        ),
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: list),
      ],
    );
  }
}

class _VideoArtwork extends StatelessWidget {
  const _VideoArtwork({
    required this.telegram,
    required this.title,
    required this.fileId,
    required this.preview,
    this.placeholderIcon = Icons.movie_outlined,
  });

  final TelegramService telegram;
  final String title;
  final int? fileId;
  final Uint8List? preview;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.secondaryContainer,
      child: Center(
        child: Icon(placeholderIcon, color: colors.onSecondaryContainer),
      ),
    );
    final preview = this.preview;
    final thumbnail = fileId;
    final fallback = preview == null
        ? placeholder
        : Image.memory(
            preview,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          );
    return thumbnail == null
        ? fallback
        : FutureBuilder<Uint8List?>(
            future: telegram.videoThumbnail(thumbnail, title),
            builder: (context, snapshot) => snapshot.data == null
                ? fallback
                : Image.memory(
                    snapshot.data!,
                    fit: BoxFit.cover,
                    cacheWidth: 480,
                    errorBuilder: (_, _, _) => fallback,
                  ),
          );
  }
}
