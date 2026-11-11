import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
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

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final content = SafeArea(
      top: false,
      child: !_ready
          ? Center(
              child: FilledButton.icon(
                onPressed:
                    widget.onConnect ?? () => Navigator.pop(context, true),
                icon: const Icon(Icons.send_rounded),
                label: const Text('Connect Telegram'),
              ),
            )
          : ListenableBuilder(
              listenable: _telegram,
              builder: (context, child) =>
                  _tab == 0 ? _home(context) : _browser(context, child),
            ),
    );
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Auralis Video'),
          actions: [
            IconButton(
              tooltip: 'Switch to Music',
              onPressed: widget.onMusic ?? () => Navigator.pop(context),
              icon: const Icon(Icons.music_note_rounded),
            ),
            if (widget.onSettings != null)
              IconButton(
                tooltip: 'Settings',
                onPressed: widget.onSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            if (_ready) ...[
              IconButton(
                tooltip: 'Open Telegram link',
                onPressed: _openingLink ? null : _openLink,
                icon: const Icon(Icons.link_rounded),
              ),
              IconButton(
                tooltip: 'Refresh videos',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (tab) => setState(() => _tab = tab),
                destinations: [
                  HomeHold(
                    onHold: widget.onMusic ?? () => Navigator.pop(context),
                    child: const NavigationDestination(
                      icon: Icon(Icons.home_rounded),
                      label: 'Home',
                      tooltip: '',
                    ),
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.search_rounded),
                    label: 'Search',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.video_library_outlined),
                    label: 'Library',
                  ),
                ],
              ),
        body: wide
            ? Row(
                children: [
                  NavigationRail(
                    extended: MediaQuery.sizeOf(context).width >= 1180,
                    selectedIndex: _tab,
                    onDestinationSelected: (tab) => setState(() => _tab = tab),
                    destinations: [
                      NavigationRailDestination(
                        icon: HomeHold(
                          onHold:
                              widget.onMusic ?? () => Navigator.pop(context),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.home_rounded),
                          ),
                        ),
                        label: HomeHold(
                          onHold:
                              widget.onMusic ?? () => Navigator.pop(context),
                          child: const Text('Home'),
                        ),
                      ),
                      const NavigationRailDestination(
                        icon: Icon(Icons.search_rounded),
                        label: Text('Search'),
                      ),
                      const NavigationRailDestination(
                        icon: Icon(Icons.video_library_outlined),
                        label: Text('Library'),
                      ),
                    ],
                  ),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
    );
  }

  Widget _home(BuildContext context) {
    final channels = _channels;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Your cinema', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text('Videos from your Telegram channels'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => setState(() => _tab = 2),
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('Browse videos'),
        ),
        const SizedBox(height: 24),
        Text('Channels', style: Theme.of(context).textTheme.titleLarge),
        if (channels.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Open a Telegram video link or refresh your channels.'),
          ),
        for (final channel in channels)
          Card(
            child: ListTile(
              leading: const Icon(Icons.live_tv_rounded),
              title: Text(channel.title),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                _search.clear();
                _restart(channel, '');
                setState(() => _tab = 2);
              },
            ),
          ),
        if (_recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'Recently opened',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          for (final video in _recent)
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: Text(video.title),
              subtitle: Text(video.source),
              onTap: () => unawaited(_play(video)),
            ),
        ],
      ],
    );
  }

  Widget _browser(BuildContext context, Widget? child) {
    final colors = Theme.of(context).colorScheme;
    final channels = _channels;
    final videos = _videos.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Channel',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.video_library_outlined),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      isDense: true,
                      value:
                          channels.any((channel) => channel.id == _channel?.id)
                          ? _channel!.id
                          : null,
                      hint: Text(
                        channels.isEmpty
                            ? 'No channels available'
                            : 'Choose a channel',
                      ),
                      items: [
                        for (final channel in channels)
                          DropdownMenuItem(
                            value: channel.id,
                            child: Text(
                              channel.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: channels.isEmpty
                          ? null
                          : (id) {
                              _search.clear();
                              _restart(
                                channels.firstWhere((c) => c.id == id),
                                '',
                              );
                            },
                    ),
                  ),
                ),
                if (_channel case final channel?) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (query) => _restart(channel, query),
                    decoration: InputDecoration(
                      hintText: 'Search videos in this channel',
                      filled: true,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                        tooltip: 'Clear video search',
                        onPressed: () {
                          _search.clear();
                          _restart(channel, '');
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
                    ),
                  ),
                ],
                if (_loading) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        if (videos.isEmpty && !_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: Column(
                children: [
                  Icon(Icons.movie_outlined, size: 38, color: colors.primary),
                  const SizedBox(height: 12),
                  Text(
                    _channel == null
                        ? 'Choose a channel or open a Telegram link'
                        : _failed
                        ? 'Could not load videos'
                        : _cursors.isEmpty
                        ? 'No playable videos found'
                        : 'No videos on this page',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              mainAxisExtent: 190,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: videos.length,
            itemBuilder: (context, index) {
              final video = videos[index];
              return _VideoCard(
                key: ValueKey(video.id),
                video: video,
                telegram: _telegram,
                onTap: () => unawaited(_play(video)),
              );
            },
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
                    _failed ? Icons.refresh_rounded : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _failed ? 'Retry loading videos' : 'Load older videos',
                  ),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
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
                  if (thumbnail == null)
                    fallback
                  else
                    FutureBuilder<String?>(
                      future: telegram.image(thumbnail),
                      builder: (context, snapshot) => snapshot.data == null
                          ? fallback
                          : Image.file(
                              File(snapshot.data!),
                              fit: BoxFit.cover,
                              cacheWidth: 480,
                              errorBuilder: (_, _, _) => fallback,
                            ),
                    ),
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
