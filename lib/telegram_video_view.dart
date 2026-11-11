import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_popups.dart';

import 'models.dart';
import 'discovery_widgets.dart';
import 'app_navigation.dart';
import 'app_theme.dart';
import 'player.dart';
import 'telegram/stream_proxy.dart';
import 'telegram/telegram_service.dart';
import 'video_playback.dart';
import 'video_playback_data.dart';
import 'video_folder_browser.dart';

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
  final _videoSources = <int>{};
  late final TelegramStreamProxy _proxy;
  late final bool Function(int) _previousStreaming, _isStreaming;
  late final bool Function() _previousActive, _hasActiveStream;
  late bool _ready;
  late final StreamSubscription<({int chatId, Track video})> _postSubscription;
  _VideoResults? _library;
  bool _showSearchChannel = false, _browseChannelsAsList = false;
  int _tab = 0;
  final _recent = <Track>[];
  int _generation = 0;
  bool _openingLink = false, _openingPlayer = false, _videoMinimized = false;
  List<VideoSource>? _playbackSources;
  int _playbackIndex = 0;
  Future<void> _playbackRelease = Future<void>.value();

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
        _generation++;
        _library = null;
        _showSearchChannel = false;
        _search.clear();
        _videoSources.clear();
        _recent.clear();
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
    setState(() => _library = results);
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
    final video = source.telegram;
    if (video == null &&
        const {'file', 'content'}.contains(source.uri?.scheme)) {
      widget.music.settings.videoPlayback.lastLocalVideo = source.id;
      unawaited(widget.music.settings.save().catchError((Object _) {}));
    }
    if (!mounted || !_ready || video == null) return;
    setState(() {
      _recent.removeWhere((item) => item.id == video.id);
      _recent.insert(0, video);
      if (_recent.length > 12) _recent.removeLast();
    });
  }

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
      if (_playbackSources != null) _closePlayer();
      await WidgetsBinding.instance.endOfFrame;
      await _playbackRelease;
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

  void _closePlayer() => setState(() {
    _playbackSources = null;
    _videoMinimized = false;
  });

  void _minimizePlayer() => setState(() => _videoMinimized = true);

  Future<void> _openVideoFiles() async {
    try {
      await _launchPlayer(await pickVideoFiles(), 0);
    } catch (_) {
      if (mounted) _notice('Could not open the selected files.');
    }
  }

  Future<void> _browseVideoFolders() async {
    final chosen = await Navigator.of(context).push<(List<VideoSource>, int)>(
      MaterialPageRoute(
        builder: (context) => VideoFolderBrowser(
          data: widget.music.settings.videoPlayback,
          save: widget.music.settings.save,
        ),
      ),
    );
    if (chosen != null) await _launchPlayer(chosen.$1, chosen.$2);
  }

  Future<void> _openVideoStream() async {
    final settings = widget.music.settings;
    final source = await showVideoStreamDialog(context, settings.videoPlayback);
    if (source == null || !mounted) return;
    if (source.webOptions != null) {
      unawaited(settings.save().catchError((Object _) {}));
    }
    await _launchPlayer([source], 0);
  }

  Future<void> _openVideoPlaylist() async {
    try {
      final sources = await pickVideoPlaylist();
      if (sources != null) await _launchPlayer(sources, 0);
    } on FormatException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('Could not open the selected playlist.');
    }
  }

  Future<void> _openLink() async {
    if (_openingLink || !_ready) return;
    final generation = _generation;
    setState(() => _openingLink = true);
    String value = '';
    try {
      final link = await showAuralisDialog<String>(
        context: context,
        builder: (context) => AuralisDialog(
          title: const Text('Open Telegram link'),
          content: TextField(
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            decoration: const InputDecoration(hintText: 'https://t.me/…'),
            onChanged: (text) => value = text,
            onSubmitted: (text) => Navigator.pop(context, text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('Open'),
            ),
          ],
        ),
      );
      if (link == null || !mounted || !_ready || generation != _generation) {
        return;
      }
      final video = await _telegram.videoLink(link);
      if (!mounted || !_ready || generation != _generation) return;
      if (video == null) {
        _notice(
          'This Telegram message is unavailable or has no playable video.',
        );
      } else {
        await _play(video);
      }
    } on FormatException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('Telegram could not open this video message.');
    } finally {
      if (mounted) setState(() => _openingLink = false);
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
    unawaited(_proxy.close());
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

  void _openChannelFromSearch(MusicChat channel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _showSearchChannel = true);
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
              listenable: _telegram,
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
                      onTelegram: widget.onConnect,
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
            minimized: _videoMinimized,
            miniBottomInset: wide ? 0 : 80,
            onBack: () {
              if (settings.videoPlayback.background) {
                _minimizePlayer();
              } else {
                _closePlayer();
              }
            },
            onMinimize: _minimizePlayer,
            onExpand: () {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _videoMinimized = false);
            },
            onClose: _closePlayer,
            onRelease: (release) => _playbackRelease = release,
          ),
      ],
    );
  }

  // Scaffold reports the floating bar's height in the body padding.
  double _bottomPadding(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + (_videoMinimized ? 92 : 20);

  Widget _openLinkButton() => IconButton(
    tooltip: 'Open Telegram link',
    onPressed: _openingLink ? null : _openLink,
    icon: const Icon(Icons.link_rounded, size: 20),
  );

  Widget _actions({Widget? sortButton}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Switch to Music',
        onPressed: _switchMusic,
        icon: const Icon(Icons.music_note_rounded, size: 20),
      ),
      if (_ready) _openLinkButton(),
      if (_ready)
        IconButton(
          tooltip: 'Refresh videos',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
        ),
      if (widget.onSettings != null && MediaQuery.sizeOf(context).width < 900)
        IconButton(
          tooltip: 'Settings',
          onPressed: widget.onSettings,
          icon: const Icon(Icons.settings_outlined, size: 20),
        ),
      ?sortButton,
    ],
  );

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
    final positions = widget.music.settings.videoPlayback.positions;
    final recent = {
      for (final item in _recent) item.id: item,
      for (final id in positions.keys.toList().reversed)
        if (_library?.videos[id.replaceFirst('telegram:', '')]
            case final Track item)
          item.id: item,
    };

    return ListView(
      key: const PageStorageKey('video-home-scroll'),
      padding: EdgeInsets.only(bottom: _bottomPadding(context)),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Auralis Video',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colors.primary,
                letterSpacing: 2,
                fontWeight: FontWeight.w800,
              ),
            ),
            _actions(),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            FilledButton.tonalIcon(
              onPressed: _openVideoFiles,
              icon: const Icon(Icons.video_file_outlined),
              label: const Text('Open files'),
            ),
            FilledButton.tonalIcon(
              onPressed: _browseVideoFolders,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Browse folders'),
            ),
            FilledButton.tonalIcon(
              onPressed: _openVideoStream,
              icon: const Icon(Icons.link_rounded),
              label: const Text('Open stream'),
            ),
            FilledButton.tonalIcon(
              onPressed: _openVideoPlaylist,
              icon: const Icon(Icons.playlist_play_rounded),
              label: const Text('Open playlist'),
            ),
          ],
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
                        ? 'Find a Telegram channel in Search or open a video link.'
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
        for (final video in recent.values.take(12))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 64,
                height: 44,
                child: _videoArtwork(video),
              ),
            ),
            title: Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              switch (positions[VideoSource.telegram(video).id]) {
                final Duration position =>
                  'Resume at ${clockText(position)} · ${video.source}',
                _ => video.source,
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => unawaited(_play(video)),
          ),
      ],
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
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                enabled: _ready,
                textInputAction: TextInputAction.search,
                onChanged: (_) => setState(() {}),
                onSubmitted: (text) {
                  final matches = _matchingChannels(text.trim().toLowerCase());
                  if (_ready && matches.length == 1) {
                    _openChannelFromSearch(matches.single);
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Search channels',
                  enabledBorder: auralisFieldBorder(radius: 28),
                  focusedBorder: auralisFieldBorder(
                    radius: 28,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                    ),
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
            ),
            if (widget.onSettings != null &&
                MediaQuery.sizeOf(context).width < 900) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Settings',
                onPressed: widget.onSettings,
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        if (_ready && showHeader) ...[
          _heading(
            query.isEmpty ? 'Browse channels' : 'Matching channels',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _openLinkButton(),
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
                        action: TextButton(
                          onPressed: () => _refreshChannels(reportError: true),
                          child: const Text('Refresh channels'),
                        ),
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
                      onTap: () => _openChannelFromSearch(channel),
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
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
        color: selected
            ? Theme.of(context).colorScheme.onPrimaryContainer
            : null,
        size: selected ? 24 : 30,
      ),
      onTap: () => _openChannelFromSearch(channel),
    );
  }

  Widget _videoArtwork(Track video) => _VideoArtwork(
    telegram: _telegram,
    fileId: video.coverFileId,
    preview: video.coverPreview,
  );

  Widget _browser(BuildContext context) {
    final searching = _tab == 1;
    final results = _library;
    final videos =
        results?.sortedVideos(widget.music.settings.librarySort) ??
        const <Track>[];
    final loading = results?.loading ?? false;
    final failed = results?.failed ?? false;
    final sortButton = IconButton.filledTonal(
      tooltip: 'Sort Library',
      onPressed: _chooseSort,
      icon: const Icon(Icons.sort_rounded, size: 20),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (searching)
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
              _openLinkButton(),
              sortButton,
            ],
          )
        else ...[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Library',
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              _actions(sortButton: sortButton),
            ],
          ),
        ],
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: CustomScrollView(
            key: ValueKey((searching, results)),
            slivers: [
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
                              ? 'Check your Telegram connection and try again.'
                              : null,
                        ),
                ),
              SliverList.separated(
                itemCount: videos.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final video = videos[index];
                  return _VideoListRow(
                    key: ValueKey(video.id),
                    title: video.title,
                    subtitle: video.duration > Duration.zero
                        ? clockText(video.duration)
                        : null,
                    artwork: _videoArtwork(video),
                    trailing: Icon(
                      Icons.play_circle_fill_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 30,
                    ),
                    onTap: () => unawaited(_play(video)),
                  );
                },
              ),
              if (!loading && failed && results != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () => _load(results),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry loading videos'),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: SizedBox(height: _bottomPadding(context)),
              ),
            ],
          ),
        ),
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
    required this.artwork,
    required this.trailing,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final Widget artwork;
  final Widget trailing;
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
                    const SizedBox(width: 8),
                    trailing,
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
