import 'dart:async';
import 'dart:io';

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

class _TelegramVideoViewState extends State<TelegramVideoView> {
  TelegramService get _telegram => widget.telegram;
  final _search = TextEditingController();
  final _videos = <String, Track>{};
  final _cursors = <bool, int>{false: 0, true: 0};
  late final TelegramStreamProxy _proxy;
  late final bool Function(int) _previousStreaming, _isStreaming;
  late final bool Function() _previousActive, _hasActiveStream;
  late bool _ready;
  MusicChat? _channel;
  String _query = '';
  int _tab = 0;
  final _recent = <Track>[];
  int _generation = 0;
  bool _loading = false,
      _failed = false,
      _openingLink = false,
      _playingVideo = false;

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
    final channels = _channels;
    final saved = channels.where(
      (channel) => channel.id == widget.music.settings.videoChannelId,
    );
    if (_ready && saved.isNotEmpty) {
      _channel = saved.first;
      unawaited(_load());
    }
  }

  void _authorizationChanged() {
    if (_telegram.ready == _ready) return;
    setState(() {
      _ready = _telegram.ready;
      _generation++;
      _channel = null;
      _search.clear();
      _query = '';
      _videos.clear();
      _recent.clear();
      _loading = false;
      _failed = false;
    });
  }

  void _restart(MusicChat channel, String query) {
    _generation++;
    setState(() {
      _channel = channel;
      _query = query.trim();
      _videos.clear();
      _cursors
        ..clear()
        ..addAll({false: 0, true: 0});
    });
    widget.music.settings.videoChannelId = channel.id;
    unawaited(
      widget.music.settings.save().catchError((Object _) {
        if (mounted) _notice('Could not save the video channel.');
      }),
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    final channel = _channel;
    if (channel == null || !_ready) return;
    final generation = _generation;
    final query = _query;
    bool current() => mounted && generation == _generation && _ready;
    setState(() {
      _loading = true;
      _failed = false;
    });
    await Future.wait([
      for (final MapEntry(:key, :value) in _cursors.entries.toList())
        () async {
          try {
            final page = await _telegram.videos(
              channel,
              before: value,
              query: query,
              documents: key,
            );
            if (!current()) return;
            for (final video in page.tracks) {
              _videos[video.id] = video;
            }
            final next = page.nextMessageId;
            if (next == 0 || (value != 0 && next >= value)) {
              _cursors.remove(key);
            } else {
              _cursors[key] = next;
            }
          } catch (_) {
            if (current()) _failed = true;
          }
        }(),
    ]);
    if (current()) setState(() => _loading = false);
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
        builder: (context) => AlertDialog(
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

  Future<void> _refresh() async {
    if (_loading) return;
    final channel = _channel;
    if (channel != null) {
      _restart(channel, _query);
      return;
    }
    try {
      await _telegram.refreshChats();
    } catch (_) {
      if (mounted) _notice('Could not refresh your Telegram channels.');
    }
  }

  void _notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
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

  void _openChannel(MusicChat channel, {int tab = 2}) {
    if (!_ready) {
      widget.onConnect?.call();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _search.clear();
    _restart(channel, '');
    _selectTab(tab);
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
              builder: (context, _) =>
                  _tab == 0 ? _home(context) : _browser(context),
            ),
          ),
        ),
      ),
    );
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectTab(0);
      },
      child: Scaffold(
        // Floating navigation leaves its gaps open to the page, just as in Music.
        extendBody: settings.navigationStyle != AppNavigationStyle.fullWidth,
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
      MediaQuery.sizeOf(context).width < 900 &&
          widget.music.settings.navigationStyle != AppNavigationStyle.fullWidth
      ? 100
      : 20;

  Widget _actions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Switch to Music',
        onPressed: _switchMusic,
        icon: const Icon(Icons.music_note_rounded, size: 20),
      ),
      if (_ready)
        IconButton(
          tooltip: 'Open Telegram link',
          onPressed: _openingLink ? null : _openLink,
          icon: const Icon(Icons.link_rounded, size: 20),
        ),
      if (_ready)
        IconButton(
          tooltip: 'Refresh videos',
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
        ),
      if (widget.onSettings != null && MediaQuery.sizeOf(context).width < 900)
        IconButton(
          tooltip: 'Settings',
          onPressed: widget.onSettings,
          icon: const Icon(Icons.settings_outlined, size: 20),
        ),
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
    final channels = _channels;
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
          tracks: _videos.values.take(4).toList(),
          artwork: (track) => _VideoArtwork(video: track, telegram: _telegram),
          description: _ready
              ? 'A world of video from your Telegram library.'
              : 'Connect Telegram to bring your videos into Auralis.',
          action: _videos.isNotEmpty
              ? IconButton.filled(
                  tooltip: 'Browse videos',
                  onPressed: () => _selectTab(2),
                  style: IconButton.styleFrom(minimumSize: const Size(60, 60)),
                  icon: const Icon(Icons.play_arrow_rounded, size: 26),
                )
              : FilledButton.tonalIcon(
                  onPressed: _ready ? () => _selectTab(2) : widget.onConnect,
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
                  'Your channels',
                  action: IconButton.filledTonal(
                    tooltip: 'Browse channels',
                    onPressed: () => _selectTab(1),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                  ),
                ),
              ),
              if (channels.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _ready
                        ? 'Open a Telegram video link or refresh your channels.'
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
                  onTap: () => _openChannel(channel),
                ),
              if (channels.length > 6)
                TextButton(
                  onPressed: () => _selectTab(1),
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
                child: _VideoArtwork(video: video, telegram: _telegram),
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

  Widget _channelMenu() => PopupMenuButton<int>(
    tooltip: 'Choose video channel',
    initialValue: _channel?.id,
    onSelected: (id) =>
        _openChannel(_channels.firstWhere((c) => c.id == id), tab: _tab),
    itemBuilder: (_) => [
      for (final c in _channels)
        PopupMenuItem(value: c.id, child: Text(c.title)),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              _channel?.title ?? 'All channels',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 20),
        ],
      ),
    ),
  );

  Widget _browser(BuildContext context) {
    final channels = _channels
        .where(
          (c) =>
              _channel != null ||
              c.title.toLowerCase().contains(_search.text.trim().toLowerCase()),
        )
        .toList();
    final videos = _videos.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final scale = MediaQuery.textScalerOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_tab == 1)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (query) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    if (_channel case final channel?) _restart(channel, query);
                  },
                  decoration: InputDecoration(
                    hintText: 'Search your videos',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear video search',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _search.clear();
                              if (_channel case final c?) {
                                _restart(c, '');
                              } else {
                                setState(() {});
                              }
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
                  icon: const Icon(Icons.settings_outlined, size: 20),
                ),
              ],
            ],
          )
        else
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Library',
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              _actions(),
            ],
          ),
        const SizedBox(height: 12),
        _heading(
          _channel == null
              ? 'Browse your library'
              : _tab == 1
              ? 'Search in channel'
              : 'Your videos',
          action: _channel == null
              ? null
              : IconButton(
                  tooltip: 'Back to browse',
                  onPressed: () {
                    _generation++;
                    setState(() {
                      _channel = null;
                      _videos.clear();
                      _search.clear();
                      _query = '';
                      _loading = false;
                    });
                  },
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_channel == null)
              const Chip(
                label: Text('Channels'),
                avatar: Icon(Icons.campaign_rounded, size: 18),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: _channelMenu(),
              ),
            if (_tab == 1)
              IconButton(
                tooltip: 'Open Telegram link',
                onPressed: _ready && !_openingLink ? _openLink : null,
                icon: const Icon(Icons.link_rounded, size: 20),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (_channel == null && channels.isNotEmpty)
                SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    mainAxisExtent:
                        108 + (scale.scale(18) - 18).clamp(0, 100) * 3,
                  ),
                  itemCount: channels.length,
                  itemBuilder: (_, i) => DiscoveryTile(
                    title: channels[i].title,
                    subtitle: 'Browse videos',
                    icon: Icons.campaign_rounded,
                    index: i,
                    onTap: () => _openChannel(channels[i], tab: _tab),
                  ),
                ),
              if ((_channel == null && channels.isEmpty) ||
                  (_channel != null && videos.isEmpty && !_loading))
                SliverToBoxAdapter(
                  child: DiscoveryCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          !_ready
                              ? 'Your library is empty'
                              : _channel == null
                              ? 'No channels found'
                              : _failed
                              ? 'Could not load videos'
                              : _cursors.isEmpty
                              ? 'No playable videos found'
                              : 'No videos on this page',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          !_ready
                              ? 'Connect Telegram to browse your video channels.'
                              : _channel == null
                              ? 'Refresh your channels or open a Telegram video link.'
                              : _tab == 1 && _query.isNotEmpty
                              ? 'Try another title or search a different channel.'
                              : 'Try loading older videos or choose another channel.',
                        ),
                        if (!_ready)
                          TextButton.icon(
                            onPressed: widget.onConnect,
                            icon: const Icon(Icons.send_rounded),
                            label: const Text('Connect Telegram'),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_channel != null)
                SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 360,
                    mainAxisExtent:
                        190 + (scale.scale(14) - 14).clamp(0, 100) * 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: videos.length,
                  itemBuilder: (_, i) => _VideoCard(
                    key: ValueKey(videos[i].id),
                    video: videos[i],
                    telegram: _telegram,
                    onTap: () => unawaited(_play(videos[i])),
                  ),
                ),
              if (!_loading && _channel != null && _cursors.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: _load,
                        icon: Icon(
                          _failed
                              ? Icons.refresh_rounded
                              : Icons.expand_more_rounded,
                        ),
                        label: Text(
                          _failed
                              ? 'Retry loading videos'
                              : 'Load older videos',
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

class _VideoCard extends StatelessWidget {
  const _VideoCard({
    super.key,
    required this.video,
    required this.telegram,
    required this.onTap,
  });

  final Track video;
  final TelegramService telegram;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final duration = video.duration;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _VideoArtwork(video: video, telegram: telegram),
                  const Center(
                    child: CircleAvatar(
                      backgroundColor: Color(0xB3000000),
                      foregroundColor: Colors.white,
                      child: Icon(Icons.play_arrow_rounded),
                    ),
                  ),
                  if (duration > Duration.zero)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            clockText(duration),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoArtwork extends StatelessWidget {
  const _VideoArtwork({required this.video, required this.telegram});
  final Track video;
  final TelegramService telegram;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.secondaryContainer,
      child: Center(
        child: Icon(Icons.movie_outlined, color: colors.onSecondaryContainer),
      ),
    );
    final preview = video.coverPreview;
    final thumbnail = video.coverFileId;
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

enum _PlaybackOption { speed, audio, subtitles }

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
    final apply = await showDialog<Future<void> Function()>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(switch (option) {
          _PlaybackOption.speed => 'Playback speed',
          _PlaybackOption.audio => 'Audio track',
          _PlaybackOption.subtitles => 'Subtitles',
        }),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option.apply),
              child: Row(
                children: [
                  Icon(
                    option.selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(option.label)),
                ],
              ),
            ),
        ],
      ),
    );
    if (mounted && apply != null) await apply();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final desktop = theme.platform == TargetPlatform.windows;
    final menu = Builder(
      builder: (context) => PopupMenuButton<_PlaybackOption>(
        tooltip: 'Video playback options',
        icon: const Icon(Icons.tune_rounded, color: Colors.white),
        onSelected: (option) => unawaited(_options(context, option)),
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _PlaybackOption.speed,
            child: Text('Playback speed'),
          ),
          PopupMenuItem(
            value: _PlaybackOption.audio,
            child: Text('Audio track'),
          ),
          PopupMenuItem(
            value: _PlaybackOption.subtitles,
            child: Text('Subtitles'),
          ),
        ],
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
