import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'discovery_widgets.dart';
import 'app_navigation.dart';
import 'player.dart';
import 'telegram/stream_proxy.dart';
import 'telegram/telegram_service.dart';

class TelegramVideoView extends StatefulWidget {
  const TelegramVideoView({
    super.key,
    required this.telegram,
    required this.music,
    this.onMusic,
    this.onSettings,
    this.onConnect,
  });

  final TelegramService telegram;
  final PlayerController music;
  final VoidCallback? onMusic, onSettings, onConnect;

  @override
  State<TelegramVideoView> createState() => _TelegramVideoViewState();
}

AlertDialog _videoDialog(
  BuildContext context, {
  required String title,
  required Widget content,
  required List<Widget> actions,
}) {
  final colors = Theme.of(context).colorScheme;
  return AlertDialog(
    title: Text(title),
    content: content,
    actions: actions,
    scrollable: true,
    constraints: const BoxConstraints(maxWidth: 420),
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
    backgroundColor: colors.surfaceContainerHigh,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
    ),
  );
}

Future<T?> _showVideoChoices<T>(
  BuildContext context, {
  required String title,
  required List<({T value, String label, bool selected})> choices,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<T>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return _videoDialog(
        context,
        title: title,
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (choices.isEmpty) const Text('No options available.'),
              for (final choice in choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    selected: choice.selected,
                    selectedTileColor: colors.primaryContainer,
                    selectedColor: colors.onPrimaryContainer,
                    title: Text(choice.label),
                    trailing: choice.selected
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.pop(context, choice.value),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}

class _VideoResults {
  _VideoResults(this.channel);

  final MusicChat channel;
  final videos = <String, Track>{};
  final cursors = <bool, int>{false: 0, true: 0};
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
  bool _showSearchChannel = false;
  int _tab = 0;
  final _recent = <Track>[];
  int _generation = 0;
  bool _openingLink = false, _playingVideo = false;

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
    if (state == AppLifecycleState.resumed && !_playingVideo) {
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
      if (showPost) library.videos[post.video.id] = post.video;
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
    void append(List<Track> tracks) {
      for (final video in tracks) {
        results.videos.putIfAbsent(video.id, () => video);
      }
      if (tracks.isNotEmpty) _videoSources.add(results.channel.id);
    }

    await Future.wait([
      if (results.recentPending)
        () async {
          try {
            final latest = await _telegram.recentVideos(results.channel);
            if (!current()) return;
            setState(() {
              results.recentPending = false;
              append(latest);
            });
          } catch (_) {
            if (current()) results.failed = true;
          }
        }(),
      for (final MapEntry(:key, :value) in results.cursors.entries.toList())
        () async {
          try {
            final page = await _telegram.videos(
              results.channel,
              before: value,
              documents: key,
            );
            if (!current()) return;
            setState(() {
              append(page.tracks);
              final next = page.nextMessageId;
              if (next == 0 || (value != 0 && next >= value)) {
                results.cursors.remove(key);
              } else {
                results.cursors[key] = next;
              }
            });
          } catch (_) {
            if (current()) results.failed = true;
          }
        }(),
    ]);
    if (current()) setState(() => results.loading = false);
  }

  Future<void> _play(Track video) async {
    if (!_ready || _playingVideo) return;
    _playingVideo = true;
    setState(() {
      _recent.removeWhere((item) => item.id == video.id);
      _recent.insert(0, video);
      if (_recent.length > 12) _recent.removeLast();
    });
    try {
      final route = MaterialPageRoute<void>(
        builder: (context) => _VideoPlayback(
          video: video,
          telegram: _telegram,
          music: widget.music,
          proxy: _proxy,
        ),
      );
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _playingVideo = false;
    }
  }

  Future<void> _openLink() async {
    if (_openingLink || !_ready) return;
    final generation = _generation;
    setState(() => _openingLink = true);
    String value = '';
    try {
      final link = await showDialog<String>(
        context: context,
        builder: (context) => _videoDialog(
          context,
          title: 'Open Telegram link',
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
    final channel = _library?.channel;
    if (channel != null && !(_library?.loading ?? false)) {
      _browseChannel(channel);
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

  void _notice(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );

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
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab == 1 && _showSearchChannel) {
          _showChannelSearch();
        } else {
          _selectTab(0);
        }
      },
      child: Scaffold(
        // Floating navigation leaves its gaps open to the page, just as in Music.
        extendBody:
            (_tab == 0 || (_tab == 1 && !_showSearchChannel)) &&
            settings.navigationStyle != AppNavigationStyle.fullWidth,
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
  }

  double get _bottomPadding =>
      (_tab == 0 || (_tab == 1 && !_showSearchChannel)) &&
          MediaQuery.sizeOf(context).width < 900 &&
          widget.music.settings.navigationStyle != AppNavigationStyle.fullWidth
      ? 100
      : 20;

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
    return ListView(
      key: const PageStorageKey('video-home-scroll'),
      padding: EdgeInsets.only(bottom: _bottomPadding),
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
        if (_recent.isEmpty)
          Text(
            'Your recent videos will appear here.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        for (final video in _recent)
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
              video.source,
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
    return Column(
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
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
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
            if (_ready) _openLinkButton(),
            if (widget.onSettings != null &&
                MediaQuery.sizeOf(context).width < 900)
              IconButton(
                tooltip: 'Settings',
                onPressed: widget.onSettings,
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            key: ValueKey(query),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: _bottomPadding),
            itemCount: channels.isEmpty ? 1 : channels.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              if (!_ready) return _connectState(context);
              if (channels.isEmpty) {
                return query.isNotEmpty
                    ? _emptyState(context, title: 'No matching channels')
                    : _emptyState(
                        context,
                        title: 'No Telegram channels available',
                        action: TextButton(
                          onPressed: () => _refreshChannels(reportError: true),
                          child: const Text('Refresh channels'),
                        ),
                      );
              }
              final channel = channels[index];
              return _VideoListRow(
                key: ValueKey(channel.id),
                title: channel.title,
                artwork: _VideoArtwork(
                  telegram: _telegram,
                  fileId: channel.photoFileId,
                  preview: channel.photoPreview,
                  placeholderIcon: Icons.video_library_outlined,
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 30),
                onTap: () => _openChannelFromSearch(channel),
              );
            },
          ),
        ),
      ],
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
    final videos = results?.videos.values.toList() ?? <Track>[];
    videos.sort(widget.music.settings.librarySort.compare);
    final loading = results?.loading ?? false;
    final hasMore = results?.hasMore ?? false;
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
                              : hasMore
                              ? 'No videos on this page'
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
              if (!loading && hasMore && results != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () => _load(results),
                        icon: Icon(
                          failed
                              ? Icons.refresh_rounded
                              : Icons.expand_more_rounded,
                        ),
                        label: Text(
                          failed ? 'Retry loading videos' : 'Load older videos',
                        ),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: _bottomPadding)),
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
    required this.artwork,
    required this.trailing,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
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
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
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
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
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

enum _PlaybackOption {
  speed('Playback speed'),
  audio('Audio track'),
  subtitles('Subtitles');

  const _PlaybackOption(this.label);
  final String label;
}

class _VideoPlayback extends StatefulWidget {
  const _VideoPlayback({
    required this.video,
    required this.telegram,
    required this.music,
    required this.proxy,
  });

  final Track video;
  final TelegramService telegram;
  final PlayerController music;
  final TelegramStreamProxy proxy;

  @override
  State<_VideoPlayback> createState() => _VideoPlaybackState();
}

class _VideoPlaybackState extends State<_VideoPlayback>
    with WidgetsBindingObserver {
  final _error = ValueNotifier<String?>(null);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  mpv.Player? _player;
  VideoController? _video;
  AudioSession? _session;
  bool _loading = false, _invalidated = false;
  bool get _canPlay => mounted && !_invalidated && widget.telegram.ready;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.telegram.addListener(_authorizationChanged);
    widget.music.audio.addListener(_musicChanged);
    unawaited(_open());
  }

  void _authorizationChanged() {
    if (!widget.telegram.ready && !_invalidated) {
      _invalidated = true;
      unawaited(_player?.stop());
      unawaited(widget.proxy.stop());
      _error.value =
          'The Telegram session changed. Return to the video browser.';
    }
  }

  void _musicChanged() {
    if (widget.music.audio.playing && _player?.state.playing == true) {
      unawaited(_player?.pause());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_player?.pause());
  }

  Future<void> _open() async {
    if (_loading || !_canPlay) return;
    _loading = true;
    _error.value = null;
    try {
      if (_player == null) {
        mpv.MediaKit.ensureInitialized();
        final player = _player = mpv.Player(
          configuration: const mpv.PlayerConfiguration(
            title: 'Auralis Video',
            bufferSize: 16 * 1024 * 1024,
          ),
        );
        _video = VideoController(player);
        _subscriptions.addAll([
          player.stream.error.listen((_) {
            if (_canPlay) {
              _error.value = 'The video could not be played. Try again.';
            }
          }),
          widget.proxy.errors.listen((_) {
            if (_canPlay) {
              _error.value = 'Telegram could not load the video. Try again.';
            }
          }),
        ]);
      } else {
        await _player!.stop();
      }
      if (!_canPlay) return;
      final player = _player!;
      final platform = player.platform as mpv.NativePlayer;
      await _video!.platform.future;
      if (!_canPlay) return;
      await platform.setProperty('network-timeout', '60');
      if (!_canPlay) return;
      if (widget.music.audio.playing) await widget.music.audio.toggle();
      if (!_canPlay) return;
      if (Platform.isAndroid && _session == null) {
        final session = await AudioSession.instance;
        if (!_canPlay) return;
        _session = session;
        _subscriptions.add(
          session.interruptionEventStream.listen((event) {
            if (event.begin) unawaited(player.pause());
          }),
        );
      }
      final uri = await widget.proxy.uri(widget.video);
      if (!_canPlay) return;
      if (await _session?.setActive(true) == false) {
        throw StateError('Audio focus unavailable');
      }
      if (!_canPlay) return;
      await player.open(mpv.Media(uri.toString()));
    } catch (_) {
      if (_canPlay) {
        unawaited(widget.proxy.stop());
        _error.value = 'Could not start the video. Try again.';
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _release() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _player?.dispose();
    } finally {
      if (!widget.music.audio.playing && !widget.proxy.hasActiveSource) {
        await _session?.setActive(false);
      }
    }
  }

  @override
  void dispose() {
    widget.music.audio.removeListener(_musicChanged);
    widget.telegram.removeListener(_authorizationChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.proxy.stop());
    unawaited(_release());
    _error.dispose();
    super.dispose();
  }

  Widget _status(Widget child) => ValueListenableBuilder(
    valueListenable: _error,
    child: child,
    builder: (context, error, child) {
      if (error == null) return child!;
      return ColoredBox(
        color: const Color(0xDC000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              if (_canPlay)
                FilledButton(onPressed: _open, child: const Text('Retry')),
              if (isFullscreen(context))
                TextButton(
                  onPressed: () => unawaited(exitFullscreen(context)),
                  child: const Text('Exit fullscreen'),
                ),
            ],
          ),
        ),
      );
    },
  );

  String _trackName(String id, String? title, String? language) {
    if (id == 'auto') return 'Automatic';
    if (id == 'no') return 'Off';
    final parts = [
      title,
      language,
    ].whereType<String>().where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }

  Future<void> _options(BuildContext context, _PlaybackOption option) async {
    final player = _player!;
    final options = switch (option) {
      _PlaybackOption.speed => [
        for (final rate in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
          (
            label: '${rate.toString().replaceFirst(RegExp(r'\.0$'), '')}×',
            selected: rate == player.state.rate,
            apply: () => player.setRate(rate),
          ),
      ],
      _PlaybackOption.audio => [
        for (final track in player.state.tracks.audio)
          (
            label: _trackName(track.id, track.title, track.language),
            selected: track == player.state.track.audio,
            apply: () => player.setAudioTrack(track),
          ),
      ],
      _PlaybackOption.subtitles => [
        for (final track in player.state.tracks.subtitle)
          (
            label: _trackName(track.id, track.title, track.language),
            selected: track == player.state.track.subtitle,
            apply: () => player.setSubtitleTrack(track),
          ),
      ],
    };
    final apply = await _showVideoChoices<Future<void> Function()>(
      context,
      title: option.label,
      choices: [
        for (final choice in options)
          (value: choice.apply, label: choice.label, selected: choice.selected),
      ],
    );
    if (_canPlay && apply != null) await apply();
  }

  Future<void> _openOptions(BuildContext context) async {
    final option = await _showVideoChoices<_PlaybackOption>(
      context,
      title: 'Video playback options',
      choices: [
        for (final option in _PlaybackOption.values)
          (value: option, label: option.label, selected: false),
      ],
    );
    if (_canPlay && context.mounted && option != null) {
      await _options(context, option);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final desktop = theme.platform == TargetPlatform.windows;
    final menu = Builder(
      builder: (context) => IconButton(
        tooltip: 'Video playback options',
        icon: const Icon(Icons.tune_rounded, color: Colors.white),
        onPressed: () => unawaited(_openOptions(context)),
      ),
    );
    final mobileTheme = MaterialVideoControlsThemeData(
      visibleOnMount: true,
      seekOnDoubleTap: true,
      seekGesture: true,
      speedUpOnLongPress: true,
      seekBarPositionColor: color,
      seekBarThumbColor: color,
      topButtonBar: [const Spacer(), menu],
    );
    final desktopTheme = MaterialDesktopVideoControlsThemeData(
      visibleOnMount: true,
      seekBarPositionColor: color,
      seekBarThumbColor: color,
      topButtonBar: [const Spacer(), menu],
    );
    final controller = _video;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.video.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: controller == null
            ? _status(const Center(child: CircularProgressIndicator()))
            : MaterialVideoControlsTheme(
                normal: mobileTheme,
                fullscreen: mobileTheme,
                child: MaterialDesktopVideoControlsTheme(
                  normal: desktopTheme,
                  fullscreen: desktopTheme,
                  child: Video(
                    controller: controller,
                    controls: (state) => _status(
                      desktop
                          ? MaterialDesktopVideoControls(state)
                          : MaterialVideoControls(state),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
