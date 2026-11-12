import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_popups.dart';

import 'models.dart';
import 'library_widgets.dart';
import 'discovery_widgets.dart';
import 'app_navigation.dart';
import 'app_theme.dart';
import 'player.dart';
import 'telegram/stream_proxy.dart';
import 'telegram/telegram_service.dart';
import 'video_playback.dart';
import 'video_playback_data.dart';
import 'video_files.dart';
import 'video_library.dart';

class TelegramVideoView extends StatefulWidget {
  const TelegramVideoView({
    super.key,
    required this.telegram,
    required this.music,
    this.onMusic,
    this.onSettings,
    this.onConnect,
    this.incoming,
    this.onIncomingConsumed,
  });

  final TelegramService telegram;
  final PlayerController music;
  final VoidCallback? onMusic, onSettings, onConnect;
  final List<VideoSource>? incoming;
  final ValueChanged<List<VideoSource>>? onIncomingConsumed;

  @override
  State<TelegramVideoView> createState() => _TelegramVideoViewState();
}

Future<T?> _showVideoChoices<T>(
  BuildContext context, {
  required String title,
  required List<({T value, String label, bool selected})> choices,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showAuralisDialog<T>(
    context: context,
    builder: (context) => AuralisDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (choices.isEmpty) const Text('No options available.'),
          for (final choice in choices)
            AuralisChoiceTile(
              selected: choice.selected,
              title: Text(choice.label),
              onTap: () => Navigator.pop(context, choice.value),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

class _VideoResults {
  _VideoResults(this.channel);

  final MusicChat channel;
  final videos = <String, Track>{};
  final cursors = <bool, int>{false: 0, true: 0};
  List<Track>? sorted;
  LibrarySort? sortOrder;

  List<Track> sortedVideos(LibrarySort order) {
    if (sortOrder != order) {
      sorted = null;
      sortOrder = order;
    }
    return sorted ??= (videos.values.toList()..sort(order.compare));
  }

  bool recentPending = true;
  bool get hasMore => recentPending || cursors.isNotEmpty;
  bool loading = false;
  bool failed = false;
}

class _TelegramVideoViewState extends State<TelegramVideoView>
    with WidgetsBindingObserver {
  TelegramService get _telegram => widget.telegram;
  final _search = TextEditingController();
  final _librarySearch = TextEditingController();
  final _videoSources = <int>{};
  late final TelegramStreamProxy _proxy;
  late final bool Function(int) _previousStreaming, _isStreaming;
  late final bool Function() _previousActive, _hasActiveStream;
  late bool _ready;
  late final StreamSubscription<({int chatId, Track video})> _postSubscription;
  _VideoResults? _library;
  bool _showSearchChannel = false, _browseChannelsAsList = false;
  int _tab = 0;
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
    _previousActive = _telegram.hasActiveStream;
    _isStreaming = (id) => _proxy.isStreaming(id) || _previousStreaming(id);
    _hasActiveStream = () => _proxy.hasActiveSource || _previousActive();
    _telegram.isStreaming = _isStreaming;
    _telegram.hasActiveStream = _hasActiveStream;
    _ready = _telegram.ready;
    _telegram.addListener(_authorizationChanged);
    _postSubscription = _telegram.videoPosts.listen(_onVideoPost);
    WidgetsBinding.instance.addObserver(this);
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
    if (channel != null) _browseChannel(channel);
  }

  void _authorizationChanged() {
    if (_telegram.ready != _ready) {
      setState(() {
        _ready = _telegram.ready;
        _library = null;
        _showSearchChannel = false;
        _search.clear();
        _librarySearch.clear();
        _videoSources.clear();
      });
      if (_ready) unawaited(_refreshChannels());
    }
    _restoreLibraryChannel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_showingPlayer) {
      unawaited(_refresh(silent: true));
    }
  }

  void _onVideoPost(({int chatId, Track video}) post) {
    if (!mounted || !_ready) return;
    final library = _library;
    final known = _videoSources.contains(post.chatId);
    final showPost =
        library != null &&
        library.channel.id == post.chatId &&
        !library.videos.containsKey(post.video.id);
    if (known && !showPost) return;
    setState(() {
      _videoSources.add(post.chatId);
      if (showPost) _addVideos(library, [post.video]);
    });
  }

  void _browseChannel(MusicChat channel) {
    final results = _VideoResults(channel);
    setState(() {
      _library = results;
      _librarySearch.clear();
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
    unawaited(_load(results));
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
    if (current()) setState(() => results.loading = false);
  }

  void _addVideos(_VideoResults results, Iterable<Track> videos) {
    for (final video in videos) {
      if (results.videos.containsKey(video.id)) continue;
      results.videos[video.id] = video;
      results.sorted = null;
      _videoSources.add(results.channel.id);
    }
  }

  Future<void> _loadRecent(_VideoResults results, {bool silent = false}) async {
    try {
      final videos = await _telegram.recentVideos(results.channel);
      if (!mounted || !_ready || !identical(results, _library)) return;
      setState(() {
        results.recentPending = false;
        _addVideos(results, videos);
      });
    } catch (_) {
      if (!silent && mounted && identical(results, _library)) {
        results.failed = true;
      }
    }
  }

  void _recordVideo(VideoSource source) {
    final settings = widget.music.settings;
    settings.videoPlayback.recordVideo(source);
    unawaited(settings.save().catchError((Object _) {}));
    if (mounted) setState(() {});
  }

  void _toggleWatched(Track episode) {
    final settings = widget.music.settings;
    final source = VideoSource.telegram(episode);
    final data = settings.videoPlayback;
    setState(() => data.setWatched(source, !data.isWatched(source)));
    unawaited(settings.save().catchError((Object _) {
      if (mounted) _notice('Could not save the watched status.');
    }));
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

  Widget _watchButton(Track episode, bool watched) =>
      VideoWatchButton(watched: watched, onPressed: () => _toggleWatched(episode));

  Future<void> _play(Track video) async {
    if (!_ready) return;
    final library = _library;
    final videos = library != null && library.videos.containsKey(video.id)
        ? library.sortedVideos(widget.music.settings.librarySort)
        : [video];
    await _launchPlayer(
      videos.map(VideoSource.telegram).toList(),
      videos.indexWhere((item) => item.id == video.id),
    );
  }

  Future<void> _launchPlayer(List<VideoSource> videos, int index) async {
    if (!mounted || _openingPlayer || videos.isEmpty || index < 0) return;
    _openingPlayer = true;
    try {
      if (_playbackSources != null) await _closePlayer();
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      await _playbackRelease;
      if (!mounted) return;
      await widget.music.releaseVideo?.call();
      if (!mounted || (videos[index].telegram != null && !_ready)) return;
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

  Future<void> _closePlayer() => _closingPlayer ??=
      _finishClosingPlayer().whenComplete(() => _closingPlayer = null);

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

  Future<void> _openVideoLibrary({required bool playlists}) async {
    final settings = widget.music.settings;
    final selected = await Navigator.of(context).push<VideoSelection>(
      MaterialPageRoute(
        builder: (_) => VideoLibraryPage(
          data: settings.videoPlayback,
          save: settings.save,
          pickFiles: pickVideoFiles,
          playlists: playlists,
          changes: widget.music,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
    if (selected != null) {
      if (selected.$1[selected.$2].telegram != null && !_ready) {
        _notice('Reconnect Telegram to play this video.');
      } else {
        await _launchPlayer(selected.$1, selected.$2);
      }
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!_ready) return;
    final results = _library;
    if (results != null && !results.loading) {
      if (!silent) {
        _browseChannel(results.channel);
      } else if (results.hasMore) {
        unawaited(_load(results));
      } else {
        unawaited(_loadRecent(results, silent: true));
      }
    }
    await _refreshChannels(reportError: !silent);
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
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_postSubscription.cancel());
    _telegram.removeListener(_authorizationChanged);
    if (identical(_telegram.isStreaming, _isStreaming)) {
      _telegram.isStreaming = _previousStreaming;
    }
    if (identical(_telegram.hasActiveStream, _hasActiveStream)) {
      _telegram.hasActiveStream = _previousActive;
    }
    unawaited(_playbackRelease.whenComplete(_proxy.close));
    _search.dispose();
    _librarySearch.dispose();
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

  void _chooseChannel(MusicChat channel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _showSearchChannel = _search.text.trim().isNotEmpty);
    if (_library?.channel.id != channel.id) _browseChannel(channel);
  }

  Future<void> _chooseSort() async {
    final settings = widget.music.settings;
    final sort = await _showVideoChoices<LibrarySort>(
      context,
      title: 'Library sort order',
      choices: [
        for (final option in LibrarySort.values)
          (
            value: option,
            label: option.label,
            selected: settings.librarySort == option,
          ),
      ],
    );
    if (!mounted || sort == null || sort == settings.librarySort) return;
    setState(() => settings.librarySort = sort);
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
              listenable: Listenable.merge([_telegram, widget.music]),
              builder: (context, _) => switch (_tab) {
                0 => _home(context),
                1 when !_showSearchChannel || _library == null =>
                  _channelSearch(context),
                _ => _browser(context),
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
        ExcludeFocus(
          excluding: _showingPlayer,
          child: ExcludeSemantics(
            excluding: _showingPlayer,
            child: IgnorePointer(ignoring: _showingPlayer, child: browser),
          ),
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

  Widget _refreshButton() => IconButton(
    tooltip: 'Refresh videos',
    onPressed: _refresh,
    icon: const Icon(Icons.refresh_rounded, size: 20),
  );

  Widget _libraryMenu(BuildContext context) => LibraryCollectionMenu<int>(
    key: const ValueKey('video-library-collection-menu'),
    title: 'All videos',
    titleKey: const ValueKey('video-library-title'),
    icon: Icons.video_library_rounded,
    tooltip: 'Library collection: All videos',
    onSelected: (index) {
      switch (index) {
        case 0:
          setState(_librarySearch.clear);
        case 1:
          unawaited(_openVideoLibrary(playlists: true));
        case 2:
          unawaited(_openVideoLibrary(playlists: false));
        case 3:
          unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const VideoSnapshotsPage()),
            ),
          );
      }
    },
    itemBuilder: (_) => [
      for (final (index, (title, icon)) in const [
        ('All videos', Icons.video_library_rounded),
        ('Playlists', Icons.playlist_play_rounded),
        ('History', Icons.history_rounded),
        ('Snapshots', Icons.photo_library_outlined),
      ].indexed)
        PopupMenuItem<int>(
          value: index,
          padding: EdgeInsets.zero,
          child: AuralisMenuRow(title: title, icon: icon, selected: index == 0),
        ),
    ],
  );

  Widget _libraryToolbar(List<Track> videos, Widget sortButton) {
    final colors = Theme.of(context).colorScheme;
    final VoidCallback? shuffle = !_ready || videos.isEmpty
        ? null
        : () {
            final queue = videos.map(VideoSource.telegram).toList()..shuffle();
            unawaited(_launchPlayer(queue, 0));
          };
    return LayoutBuilder(
      builder: (context, box) {
        final showLabel =
            box.maxWidth >= 330 &&
            MediaQuery.textScalerOf(context).scale(14) <= 18;
        return Row(
          children: [
            Tooltip(
              message: 'Shuffle collection',
              child: showLabel
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.tertiaryContainer,
                        foregroundColor: colors.onTertiaryContainer,
                        minimumSize: const Size(48, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: const StadiumBorder(),
                      ),
                      onPressed: shuffle,
                      icon: const Icon(Icons.shuffle_rounded, size: 20),
                      label: const Text('Shuffle'),
                    )
                  : IconButton.filledTonal(
                      style: IconButton.styleFrom(
                        backgroundColor: colors.tertiaryContainer,
                        foregroundColor: colors.onTertiaryContainer,
                      ),
                      onPressed: shuffle,
                      icon: const Icon(Icons.shuffle_rounded, size: 20),
                    ),
            ),
            const Spacer(),
            sortButton,
          ],
        );
      },
    );
  }

  Widget _libraryBrowser(
    BuildContext context, {
    required List<Track> videos,
    required int total,
    required bool loading,
    required Widget sortButton,
    required Widget list,
  }) {
    final colors = Theme.of(context).colorScheme;
    final showHeader = MediaQuery.viewInsetsOf(this.context).bottom == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _libraryMenu(context),
                ),
              ),
              if (widget.onSettings != null &&
                  MediaQuery.sizeOf(context).width < 900)
                IconButton.filledTonal(
                  tooltip: 'Settings',
                  style: IconButton.styleFrom(
                    backgroundColor: colors.primaryContainer,
                    foregroundColor: colors.onPrimaryContainer,
                  ),
                  onPressed: widget.onSettings,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3, bottom: 8),
            child: Text(
              '$total ${total == 1 ? 'video' : 'videos'} · ${_library?.channel.title ?? 'No channel selected'}',
              key: const ValueKey('video-library-counts'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          ),
        ],
        Expanded(
          child: Material(
            color: colors.surfaceContainerLowest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showHeader) ...[
                    _libraryToolbar(videos, sortButton),
                    const SizedBox(height: 5),
                  ],
                  TextField(
                    key: const ValueKey('video-library-search'),
                    controller: _librarySearch,
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    decoration: InputDecoration(
                      hintText: 'Search your videos',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      suffixIcon: _librarySearch.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () => setState(_librarySearch.clear),
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (loading) const LinearProgressIndicator(minHeight: 2),
                  Expanded(child: list),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

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

  Widget _home(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final channels = _channels
        .where((channel) => _videoSources.contains(channel.id))
        .toList();
    final videos = _library?.videos.values.take(4).toList() ?? const <Track>[];
    final history = widget.music.settings.videoPlayback.history;
    final recent = _ready
        ? (history.values.where((entry) => entry.source.telegram != null).toList()
          ..sort((a, b) => b.playedAt.compareTo(a.playedAt)))
        : const <VideoHistoryEntry>[];

    return ListView(
      key: const PageStorageKey('video-home-scroll'),
      padding: EdgeInsets.only(bottom: _bottomPadding(context)),
      children: [
        Text(
          'Auralis Video',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.primary,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        DiscoveryHero(
          title: 'Your Cinema',
          emptyIcon: Icons.movie_rounded,
          tracks: videos,
          artwork: _videoArtwork,
          description: _ready
              ? 'A world of video from your Telegram library.'
              : 'Connect Telegram to bring your videos into Auralis.',
          action: videos.isNotEmpty
              ? IconButton.filled(
                  tooltip: 'Browse videos',
                  onPressed: () => _selectTab(2),
                  style: IconButton.styleFrom(minimumSize: const Size(60, 60)),
                  icon: const Icon(Icons.play_arrow_rounded, size: 26),
                )
              : FilledButton.tonalIcon(
                  onPressed: !_ready
                      ? widget.onConnect
                      : _library == null
                      ? _showChannelSearch
                      : () => _selectTab(2),
                  icon: Icon(
                    _ready ? Icons.video_library_rounded : Icons.send_rounded,
                  ),
                  label: Text(_ready ? 'Browse videos' : 'Connect Telegram'),
                ),
        ),
        const SizedBox(height: 16),
        DiscoveryCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: colors.secondaryContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: _heading(
                  'Video channels',
                  action: IconButton.filledTonal(
                    tooltip: 'Browse channels',
                    onPressed: _ready ? _showChannelSearch : null,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                  ),
                ),
              ),
              if (channels.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _ready
                        ? 'Find a Telegram channel in Browse.'
                        : 'Your video channels will appear here.',
                  ),
                ),
              for (final channel in channels.take(6))
                ListTile(
                  leading: const Icon(Icons.campaign_rounded),
                  title: Text(
                    channel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    _showSearchChannel = false;
                    if (_library?.channel.id != channel.id) {
                      _browseChannel(channel);
                    }
                    _selectTab(2);
                  },
                ),
              if (channels.length > 6)
                TextButton(
                  onPressed: _showChannelSearch,
                  child: const Text('Show all channels'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _heading('Recently opened'),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          Text(
            'Your recent videos will appear here.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        for (final entry in recent.take(12))
          if (entry.source.telegram case final Track video)
            _recentVideoRow(video, colors),
      ],
    );
  }

  Widget _recentVideoRow(Track video, ColorScheme colors) {
    final watched = _isWatched(video);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 64,
          height: 44,
          child: _videoArtwork(
            _library?.videos[video.id] ?? video,
            watched: watched,
          ),
        ),
      ),
      title: Text(
        video.title,
        style: watched ? TextStyle(color: colors.onSurfaceVariant) : null,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [_episodeStatus(video, watched), video.source]
            .where((text) => text.isNotEmpty)
            .join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _watchButton(video, watched),
      onTap: () => unawaited(_play(video)),
    );
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

  Iterable<MusicChat> _matchingChannels(String query) =>
      _channels.where((channel) => channel.title.toLowerCase().contains(query));

  Widget _channelSearch(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final channels = _ready
        ? (_matchingChannels(query).toList()..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          ))
        : const <MusicChat>[];
    final padding = EdgeInsets.only(bottom: _bottomPadding(context));
    final showHeader = MediaQuery.viewInsetsOf(this.context).bottom == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          enabled: _ready,
          textInputAction: TextInputAction.search,
          onChanged: (_) => setState(() {}),
          onSubmitted: (text) {
            final matches = _matchingChannels(text.trim().toLowerCase());
            if (_ready && matches.length == 1) {
              _chooseChannel(matches.single);
            }
          },
          decoration: InputDecoration(
            hintText: 'Search channels',
            enabledBorder: auralisFieldBorder(radius: 28),
            focusedBorder: auralisFieldBorder(
              radius: 28,
              side: BorderSide(color: Theme.of(context).colorScheme.primary),
            ),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear channel search',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _search.clear();
                      setState(() {});
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
        if (_ready && showHeader) ...[
          _heading(
            query.isEmpty ? 'Browse channels' : 'Matching channels',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _refreshButton(),
                if (channels.isNotEmpty)
                  discoveryLayoutButton(
                    list: _browseChannelsAsList,
                    onPressed: () => setState(
                      () => _browseChannelsAsList = !_browseChannelsAsList,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: channels.isEmpty
              ? ListView(
                  padding: padding,
                  children: [
                    if (!_ready)
                      _connectState(context)
                    else if (query.isNotEmpty)
                      _emptyState(context, title: 'No matching channels')
                    else
                      _emptyState(
                        context,
                        title: 'No Telegram channels available',
                      ),
                  ],
                )
              : _browseChannelsAsList
              ? ListView.separated(
                  key: ValueKey(query),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: padding,
                  itemCount: channels.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, index) => _channelRow(channels[index]),
                )
              : GridView.builder(
                  key: ValueKey(query),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: padding,
                  gridDelegate: discoveryGridDelegate(context),
                  itemCount: channels.length,
                  itemBuilder: (_, index) {
                    final channel = channels[index];
                    final selected = channel.id == _library?.channel.id;
                    return DiscoveryTile(
                      key: ValueKey(channel.id),
                      title: channel.title,
                      subtitle: selected ? 'Selected in Library' : null,
                      icon: Icons.campaign_rounded,
                      index: index,
                      selected: selected,
                      onTap: () => _chooseChannel(channel),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _channelRow(MusicChat channel) {
    final selected = channel.id == _library?.channel.id;
    return _VideoListRow(
      key: ValueKey(channel.id),
      title: channel.title,
      subtitle: selected ? 'Selected in Library' : null,
      selected: selected,
      artwork: _VideoArtwork(
        telegram: _telegram,
        fileId: channel.photoFileId,
        preview: channel.photoPreview,
        placeholderIcon: Icons.video_library_outlined,
      ),
      trailing: selected
          ? Icon(
              Icons.check_circle_rounded,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              size: 24,
            )
          : null,
      onTap: () => _chooseChannel(channel),
    );
  }

  Widget _videoArtwork(Track video, {bool watched = false}) {
    final artwork = _VideoArtwork(
      telegram: _telegram,
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
    final allVideos =
        results?.sortedVideos(widget.music.settings.librarySort) ??
        const <Track>[];
    final query = searching ? '' : _librarySearch.text.trim().toLowerCase();
    final videos = query.isEmpty
        ? allVideos
        : allVideos
              .where((video) => video.title.toLowerCase().contains(query))
              .toList();
    final loading = results?.loading ?? false;
    final failed = results?.failed ?? false;
    final colors = Theme.of(context).colorScheme;
    final sortButton = IconButton.filledTonal(
      tooltip: 'Sort Library',
      onPressed: _chooseSort,
      style: searching
          ? null
          : IconButton.styleFrom(
              backgroundColor: colors.secondaryContainer,
              foregroundColor: colors.onSecondaryContainer,
              minimumSize: const Size(48, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
      icon: const Icon(Icons.sort_rounded, size: 20),
    );
    final list = CustomScrollView(
      key: ValueKey((searching, results)),
      slivers: [
        if (videos.isEmpty && !loading)
          SliverToBoxAdapter(
            child: !_ready
                ? _connectState(context)
                : query.isNotEmpty && allVideos.isNotEmpty
                ? _emptyState(context, title: 'No matching videos')
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
                    description: !failed
                        ? null
                        : searching
                        ? 'Check your Telegram connection and refresh.'
                        : 'Check your Telegram connection and refresh in Browse.',
                  ),
          ),
        SliverList.separated(
          itemCount: videos.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final video = videos[index];
            final watched = _isWatched(video);
            final status = _episodeStatus(video, watched);
            return _VideoListRow(
              key: ValueKey(video.id),
              title: video.title,
              watched: watched,
              subtitle: [
                if (video.duration > Duration.zero) clockText(video.duration),
                if (status.isNotEmpty) status,
              ].join(' · '),
              artwork: _videoArtwork(video, watched: watched),
              trailing: _watchButton(video, watched),
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
    );
    if (!searching) {
      return _libraryBrowser(
        context,
        videos: videos,
        total: allVideos.length,
        loading: loading,
        sortButton: sortButton,
        list: list,
      );
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
            _refreshButton(),
            sortButton,
          ],
        ),
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: list),
      ],
    );
  }
}

class _VideoListRow extends StatelessWidget {
  const _VideoListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.watched = false,
    required this.artwork,
    this.trailing,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final bool selected, watched;
  final Widget artwork;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
              child: Padding(
                padding: const EdgeInsets.all(8),
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
                            Text(
                              subtitle!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: selected
                                    ? colors.onPrimaryContainer
                                    : colors.onSurfaceVariant,
                              ),
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
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoArtwork extends StatelessWidget {
  const _VideoArtwork({
    required this.telegram,
    required this.fileId,
    required this.preview,
    this.placeholderIcon = Icons.movie_outlined,
  });

  final TelegramService telegram;
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
        : FutureBuilder<String?>(
            future: telegram.image(thumbnail),
            builder: (context, snapshot) => snapshot.data == null
                ? fallback
                : Image.file(
                    File(snapshot.data!),
                    fit: BoxFit.cover,
                    cacheWidth: 480,
                    errorBuilder: (_, _, _) => fallback,
                  ),
          );
  }
}
