import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'lyrics.dart';
import 'lyrics_view.dart';
import 'player.dart';
import 'telegram/telegram_service.dart';
import 'telegram/phone_login.dart';
import 'telegram/channel_library.dart';
import 'updater.dart';
import 'update_widgets.dart';
import 'wave_seek_bar.dart';
import 'now_playing_effects.dart';
import 'data_files.dart';
import 'stats_view.dart';
import 'sync/controller.dart';
import 'sync/settings_view.dart';
import 'release_notes.dart';
import 'media_cache.dart';
import 'app_navigation.dart';
import 'setup_view.dart';
import 'settings_view.dart';

const accent = Color(0xFFC7B5FF),
    surface = Color(0xFF19171E),
    muted = Color(0xFFAAA4B5);

class AuralisApp extends StatefulWidget {
  const AuralisApp({
    super.key,
    required this.player,
    required this.telegram,
    this.startupWarning,
    this.sync,
    this.installedVersion,
    this.updater,
    this.dataFiles = const DataFiles(),
    this.showSetup = false,
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final SyncController? sync;
  final String? installedVersion;
  final AppUpdater? updater;
  final DataFiles dataFiles;
  final bool showSetup;
  @override
  State<AuralisApp> createState() => _AuralisAppState();
}

class _AuralisAppState extends State<AuralisApp> {
  static final _fallback = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    primary: accent,
    surface: surface,
  );
  ColorScheme _scheme = _fallback;
  Object? _artworkIdentity;
  int _generation = 0;
  final _palettes = <Uint8List, Future<ColorScheme?>>{};
  late bool _settingUp;

  @override
  void initState() {
    super.initState();
    _settingUp = widget.showSetup;
    widget.player.addListener(_artworkChanged);
    widget.telegram.addListener(_artworkChanged);
    _artworkChanged();
  }

  @override
  void didUpdateWidget(AuralisApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player ||
        oldWidget.telegram != widget.telegram) {
      oldWidget.player.removeListener(_artworkChanged);
      oldWidget.telegram.removeListener(_artworkChanged);
      widget.player.addListener(_artworkChanged);
      widget.telegram.addListener(_artworkChanged);
      _artworkIdentity = null;
      _artworkChanged();
    }
  }

  void _artworkChanged() {
    widget.telegram.keepArtwork = widget.player.settings.keepArtwork;
    final track = widget.player.current;
    final cover = track != null && track.fileId != null && widget.telegram.ready
        ? widget.telegram.cover(track)
        : null;
    final identity = (
      track?.id,
      track?.coverFileId,
      track?.coverPreview,
      cover,
    );
    if (identity == _artworkIdentity) return;
    _artworkIdentity = identity;
    final generation = ++_generation;
    unawaited(_loadPalette(track?.coverPreview, cover, generation));
  }

  Future<ColorScheme?> _extract(Uint8List bytes) async {
    try {
      return await ColorScheme.fromImageProvider(
        provider: MemoryImage(bytes),
        brightness: Brightness.dark,
      );
    } catch (_) {
      return null; // Missing or damaged artwork keeps the fallback theme.
    }
  }

  Future<void> _loadPalette(
    Uint8List? preview,
    Future<Uint8List?>? cover,
    int generation,
  ) async {
    Future<bool> apply(Uint8List? bytes) async {
      if (!mounted || generation != _generation || bytes == null) return false;
      if (_palettes.length >= 8 && !_palettes.containsKey(bytes)) {
        _palettes.remove(_palettes.keys.first);
      }
      final palette = await _palettes.putIfAbsent(bytes, () => _extract(bytes));
      if (mounted && generation == _generation && palette != null) {
        if (_scheme != palette) setState(() => _scheme = palette);
        return true;
      }
      return false;
    }

    var hasPalette = await apply(preview);
    try {
      hasPalette = await apply(await cover) || hasPalette;
    } catch (_) {
      // A failed full-size cover must not discard a usable preview palette.
    }
    if (!hasPalette &&
        mounted &&
        generation == _generation &&
        _scheme != _fallback) {
      setState(() => _scheme = _fallback);
    }
  }

  @override
  void dispose() {
    ++_generation;
    widget.player.removeListener(_artworkChanged);
    widget.telegram.removeListener(_artworkChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Auralis',
    themeAnimationDuration: Duration(
      milliseconds:
          widget.player.settings.reducedMotion ||
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .accessibilityFeatures
                  .disableAnimations
          ? 0
          : 350,
    ),
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Segoe UI',
      scaffoldBackgroundColor: _scheme.surface,
      colorScheme: _scheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      dividerColor: _scheme.outlineVariant,
    ),
    home: _settingUp
        ? SetupView(
            player: widget.player,
            telegram: widget.telegram,
            version: widget.installedVersion ?? currentReleaseVersion,
            files: widget.dataFiles,
            connectBuilder: (_) => PlayerShell(
              player: widget.player,
              telegram: widget.telegram,
              setupMode: true,
            ),
            onFinished: () => setState(() => _settingUp = false),
          )
        : PlayerShell(
            player: widget.player,
            telegram: widget.telegram,
            startupWarning: widget.startupWarning,
            updater: widget.updater,
            sync: widget.sync,
            installedVersion: widget.installedVersion,
            dataFiles: widget.dataFiles,
          ),
  );
}

enum _Page { library, telegram, nowPlaying, settings }

class PlayerShell extends StatefulWidget {
  const PlayerShell({
    super.key,
    required this.player,
    required this.telegram,
    this.startupWarning,
    this.sync,
    this.installedVersion,
    this.updater,
    this.dataFiles = const DataFiles(),
    this.setupMode = false,
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final SyncController? sync;
  final String? installedVersion;
  final AppUpdater? updater;
  final DataFiles dataFiles;
  final bool setupMode;
  @override
  State<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends State<PlayerShell>
    with SingleTickerProviderStateMixin {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  _Page destination = _Page.library;
  _Page _playerOrigin = _Page.library;
  bool showLyrics = false;
  String collection = 'All songs';
  String? selectedPlaylist;
  late final LyricsRepository lyrics;
  int _cacheGeneration = 0, _cachedTracks = 0, _cacheTotal = 0;
  bool _cachingLibrary = false;
  final search = TextEditingController();
  final settingsSearch = TextEditingController();
  SettingsSection? _settingsSection;
  late final ChannelLibrary library;
  late final Listenable _shellUpdates;
  late final AnimationController _dismissPlayer;
  final _dockKey = GlobalKey();
  final _surfaceKey = GlobalKey();
  Rect? _dockBounds;
  Size? _dockViewport;
  double _playerDragStart = 0;
  double _playerTravel = 1;
  bool _closingPlayer = false;
  Timer? _volumeTimer;
  bool _showVolume = false;
  Object? _artworkWindow, _lyricRequest;
  Track? _metadataTrack;
  bool _metadataPlaybackStarted = false;
  int _artworkGeneration = 0, _lyricGeneration = 0;
  PlayerController get player => widget.player;
  TelegramService get telegram => widget.telegram;
  @override
  void initState() {
    super.initState();
    _dismissPlayer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 440),
      reverseDuration: const Duration(milliseconds: 500),
    );
    lyrics = LyricsRepository(
      cache: () => telegram.mediaCache,
      preferences: player.settings,
    );
    library = ChannelLibrary(telegram, player.settings);
    _shellUpdates = Listenable.merge([player, telegram, library]);
    player.addListener(_prepareMedia);
    telegram.addListener(_prepareMedia);
    library.addListener(_prepareMedia);
    HardwareKeyboard.instance.addHandler(_volumeKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prepareMedia();
    });
    search.addListener(_changed);
    _syncedChannels = player.settings.selectedChannels
        .map((c) => c.id)
        .join(',');
    widget.sync?.addListener(_syncChanged);
    if (widget.installedVersion != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            maybeShowWhatsNew(
              context,
              player.settings,
              widget.installedVersion!,
            ),
          );
        }
      });
    }
  }

  bool _volumeKey(KeyEvent event) {
    if (!mounted ||
        player.restoringData ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        ![
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        ].contains(Theme.of(context).platform) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final editing = FocusManager.instance.primaryFocus?.context;
    if (editing?.widget is EditableText ||
        editing?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    final step = event.logicalKey == LogicalKeyboardKey.arrowUp
        ? 5
        : event.logicalKey == LogicalKeyboardKey.arrowDown
        ? -5
        : 0;
    if (step == 0) return false;
    unawaited(player.setVolume(player.settings.volume + step));
    _volumeTimer?.cancel();
    setState(() => _showVolume = true);
    _volumeTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _showVolume = false);
    });
    return true;
  }

  void _prepareMedia() {
    if (!mounted) return;
    final settings = player.settings;
    telegram.keepArtwork = settings.keepArtwork;
    final scope = telegram.mediaCache.directory?.path;
    final track = player.current;
    if (!identical(track, _metadataTrack)) {
      _metadataTrack = track;
      _metadataPlaybackStarted = false;
    }
    _metadataPlaybackStarted =
        _metadataPlaybackStarted || player.loading || player.audio.playing;
    final source = player.queue.isNotEmpty ? player.queue : library.tracks;
    final start = player.queue.isNotEmpty ? math.max(0, player.index) : 0;
    final count = math.min(
      source.length,
      settings.artworkPreload + (track == null ? 0 : 1),
    );
    final window = <Track>[
      for (var offset = 0; offset < count; offset++)
        if (start + offset < source.length || player.repeat)
          source[(start + offset) % source.length],
    ];
    final artworkKey = (
      telegram.ready,
      scope,
      settings.keepArtwork,
      settings.artworkPreload,
      window.map((t) => (t.id, t.fileId, t.coverFileId, t.size)).join('|'),
    );
    if (artworkKey != _artworkWindow) {
      _artworkWindow = artworkKey;
      final generation = ++_artworkGeneration;
      bool active() =>
          mounted &&
          generation == _artworkGeneration &&
          telegram.ready &&
          scope == telegram.mediaCache.directory?.path;
      if (active()) unawaited(_warmArtwork(window, active));
    }
    final lyricKey = (
      telegram.ready,
      scope,
      track,
      _metadataPlaybackStarted,
      settings.automaticLyrics,
      settings.automaticTranslation,
      settings.lyricsFirst,
      settings.lyricsFallback,
      settings.translationFirst,
      settings.translationFallback,
      settings.translationDirection,
    );
    if (lyricKey != _lyricRequest) {
      _lyricRequest = lyricKey;
      final generation = ++_lyricGeneration;
      bool active() =>
          mounted &&
          generation == _lyricGeneration &&
          telegram.ready &&
          identical(player.current, track) &&
          scope == telegram.mediaCache.directory?.path;
      if (track != null &&
          _metadataPlaybackStarted &&
          settings.automaticLyrics &&
          active()) {
        unawaited(
          lyrics
              .prepare(
                track,
                active: active,
                loadEmbedded: telegram.embeddedLyrics,
              )
              .catchError((Object _) => null),
        );
      }
    }
  }

  Future<void> _warmArtwork(List<Track> tracks, bool Function() active) async {
    for (final track in tracks) {
      if (!active()) return;
      final bytes = await telegram.cacheCover(track, active: active);
      if (!mounted || !active()) return;
      if (bytes == null) continue;
      for (final width in [96, 640]) {
        if (!mounted || !active()) return;
        await precacheImage(
          ResizeImage(MemoryImage(bytes), width: width),
          context,
          onError: (_, _) {},
        );
        if (!active()) return;
      }
    }
  }

  double get _dockPadding {
    if (player.current == null) return 16;
    final size = MediaQuery.sizeOf(context);
    final width =
        size.width -
        (size.width >= 1180
            ? 202
            : size.width >= 900
            ? 72
            : 0);
    return (size.height < 560 || width >= 1020 ? 96 : 128) +
        math.max(0, MediaQuery.textScalerOf(context).scale(1) - 1) * 48;
  }

  String _syncedChannels = '';
  void _syncChanged() {
    final channels = player.settings.selectedChannels
        .map((c) => c.id)
        .join(',');
    if (channels != _syncedChannels) {
      _syncedChannels = channels;
      if (telegram.ready && !player.restoringData) unawaited(library.refresh());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _navigate(
    _Page page, {
    bool openLyrics = false,
    bool draggingDock = false,
  }) {
    final opening =
        page == _Page.nowPlaying && (destination != page || _closingPlayer);
    final reduced =
        player.settings.reducedMotion ||
        MediaQuery.disableAnimationsOf(context);
    if (page != _Page.nowPlaying) {
      // Cancel a pending close before another page (or a new open) takes over.
      _dismissPlayer.reset();
    } else if (opening) {
      if (destination != page) {
        _playerOrigin = destination;
        _dockViewport = MediaQuery.sizeOf(context);
        final dock = _dockKey.currentContext?.findRenderObject();
        final surface = _surfaceKey.currentContext?.findRenderObject();
        if (dock is RenderBox && surface is RenderBox && dock.hasSize) {
          _dockBounds =
              surface.globalToLocal(dock.localToGlobal(Offset.zero)) &
              dock.size;
        } else {
          _dockBounds = null;
        }
        // A second pointer event can arrive before the first expanded frame.
        _playerTravel = math.max(
          1,
          _dockBounds?.top ??
              (surface is RenderBox && surface.hasSize
                  ? surface.size.height
                  : 1),
        );
      }
      if (reduced) {
        _dismissPlayer.reset();
      } else {
        if (draggingDock) {
          _dismissPlayer.value = 1;
        } else {
          if (destination != page) _dismissPlayer.value = 1;
          _movePlayer(0);
        }
      }
    }
    if (page == _Page.settings) {
      _settingsSection = null;
      settingsSearch.clear();
    }
    setState(() {
      destination = page;
      _closingPlayer = false;
      showLyrics = openLyrics;
      search.clear();
    });
  }

  void _back() {
    if (destination == _Page.settings && _settingsSection != null) {
      setState(() => _settingsSection = null);
    } else if (destination == _Page.nowPlaying) {
      if (showLyrics) {
        setState(() => showLyrics = false);
      } else {
        unawaited(_closeNowPlaying());
      }
    } else if (destination != _Page.library) {
      _navigate(_Page.library);
    }
  }

  @override
  void dispose() {
    ++_cacheGeneration;
    ++_artworkGeneration;
    ++_lyricGeneration;
    _volumeTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_volumeKey);
    player.removeListener(_prepareMedia);
    telegram.removeListener(_prepareMedia);
    library.removeListener(_prepareMedia);
    _dismissPlayer.dispose();
    lyrics.close();
    library.dispose();
    widget.sync?.removeListener(_syncChanged);
    search.dispose();
    settingsSearch.dispose();
    super.dispose();
  }

  Future<void> _closeNowPlaying({double? velocity}) async {
    if (_closingPlayer || destination != _Page.nowPlaying) return;
    final reduced =
        player.settings.reducedMotion ||
        MediaQuery.disableAnimationsOf(context);
    setState(() => _closingPlayer = true);
    if (!reduced) {
      try {
        // Continue from the current position if Back interrupts opening.
        await _movePlayer(1, velocity: velocity).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      // A sidebar navigation during dismissal takes precedence.
      if (destination == _Page.nowPlaying) {
        destination = _playerOrigin;
        showLyrics = false;
      }
      _closingPlayer = false;
      _dismissPlayer.reset();
    });
  }

  Widget _pageContent(_Page page, {required bool narrow, bool short = false}) {
    final immersiveLyrics = page == _Page.nowPlaying && showLyrics;
    return Padding(
      padding: immersiveLyrics
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(
              narrow ? 16 : 30,
              short ? 12 : 26,
              narrow ? 16 : 26,
              0,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!immersiveLyrics) ...[
            _header(narrow, short: short, page: page),
            SizedBox(height: short ? 10 : 22),
          ],
          if (widget.updater != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: UpdateBanner(updater: widget.updater!),
            ),
          if (widget.startupWarning != null) _banner(widget.startupWarning!),
          if (player.error ?? player.audio.error case final String error)
            _banner(error),
          Expanded(
            child: AnimatedSwitcher(
              layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
              duration: Duration(
                milliseconds: page == _Page.nowPlaying || _reducedPlayerMotion
                    ? 0
                    : 180,
              ),
              child: KeyedSubtree(
                key: ValueKey((page, immersiveLyrics)),
                child: switch (page) {
                  _Page.library => _library(),
                  _Page.telegram => _telegram(),
                  _Page.settings => _settingsPage(),
                  _Page.nowPlaying =>
                    immersiveLyrics
                        ? LyricsView(
                            backgroundColor: Colors.transparent,
                            player: player,
                            repository: lyrics,
                            files: widget.dataFiles,
                            loadEmbedded: telegram.embeddedLyrics,
                            artwork: Artwork(
                              seed: player.current?.title ?? 'Auralis',
                              telegram: telegram,
                              track: player.current,
                            ),
                            onBack: () => setState(() => showLyrics = false),
                          )
                        : _nowPlaying(),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _originContent({bool transitionCopy = false}) => LayoutBuilder(
    builder: (context, box) {
      final viewport = MediaQuery.sizeOf(context);
      final page = destination == _Page.nowPlaying
          ? _playerOrigin
          : destination;
      final compact = viewport.width < 900;
      final narrow = viewport.width < 1180;
      final short = viewport.height < 560;
      final wide = viewport.width >= 1220 && viewport.height >= 620;
      return Stack(
        key: const ValueKey('floating-player-layer'),
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _pageContent(page, narrow: narrow, short: short),
                    ),
                    if (wide &&
                        (page == _Page.library || page == _Page.telegram))
                      Container(
                        width: (viewport.width * .23).clamp(280, 360),
                        margin: EdgeInsets.fromLTRB(0, 20, 20, _dockPadding),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: _nowPlaying(compact: true),
                      ),
                  ],
                ),
              ),
              if (compact)
                _bottomNavigation(page: page, transitionCopy: transitionCopy),
            ],
          ),
          if (player.current != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: compact ? 80 + MediaQuery.paddingOf(context).bottom : 0,
              child: _transport(
                viewport.width < 600,
                short: short,
                transitionCopy: transitionCopy,
              ),
            ),
        ],
      );
    },
  );

  bool get _reducedPlayerMotion =>
      player.settings.reducedMotion || MediaQuery.disableAnimationsOf(context);

  void _dragPlayer(DragUpdateDetails details) {
    if (_reducedPlayerMotion) return;
    _dismissPlayer.value =
        (_dismissPlayer.value + details.delta.dy / _playerTravel).clamp(
          0.0,
          1.0,
        );
  }

  TickerFuture _movePlayer(double target, {double? velocity}) {
    return _dismissPlayer.animateWith(
      SpringSimulation(
        SpringDescription.withDurationAndBounce(
          duration: const Duration(milliseconds: 440),
        ),
        _dismissPlayer.value,
        target,
        (velocity ?? _dismissPlayer.velocity).clamp(-6.0, 6.0),
        // Stop once the remaining motion is below a logical pixel, rather than
        // keeping the finished-looking card locked for a long spring tail.
        tolerance: Tolerance(
          distance: 1 / _playerTravel,
          velocity: 10 / _playerTravel,
        ),
        snapToEnd: true,
      ),
    );
  }

  void _settlePlayer(DragEndDetails details) {
    final speed = details.primaryVelocity ?? 0;
    final closing = speed.abs() > 500 ? speed > 0 : _dismissPlayer.value > .18;
    if (closing) {
      unawaited(_closeNowPlaying(velocity: speed / _playerTravel));
    } else if (_reducedPlayerMotion) {
      _dismissPlayer.reset();
    } else {
      _movePlayer(0, velocity: speed / _playerTravel);
    }
  }

  void _settleDock(DragEndDetails details) {
    if (_reducedPlayerMotion) return;
    final speed = details.primaryVelocity ?? 0;
    final opening = speed.abs() > 500 ? speed < 0 : _dismissPlayer.value < .82;
    if (opening) {
      _movePlayer(0, velocity: speed / _playerTravel);
    } else {
      unawaited(_closeNowPlaying(velocity: speed / _playerTravel));
    }
  }

  Widget _playerSurface({required Widget child}) => LayoutBuilder(
    key: _surfaceKey,
    builder: (context, box) {
      final expanded = destination == _Page.nowPlaying;
      final full = Offset.zero & box.biggest;
      final viewport = MediaQuery.sizeOf(context);
      final previousViewport = _dockViewport ?? viewport;
      final saved = _dockBounds?.shift(
        Offset(0, viewport.height - previousViewport.height),
      );
      final mini = saved == null
          ? Rect.fromLTWH(
              12,
              math.max(0, full.height - 120),
              math.max(0, full.width - 24),
              100,
            )
          : Rect.fromLTRB(
              saved.left.clamp(0.0, full.width),
              saved.top.clamp(0.0, math.max(0, full.height - 1)),
              (saved.right + viewport.width - previousViewport.width).clamp(
                1.0,
                full.width,
              ),
              saved.bottom.clamp(1.0, full.height),
            );
      _playerTravel = math.max(1, mini.top);
      final content = expanded
          ? RepaintBoundary(
              child: GestureDetector(
                // The artwork pager keeps horizontal gestures; lyrics keeps scrolling.
                onVerticalDragStart: showLyrics || _closingPlayer
                    ? null
                    : (_) {
                        _playerDragStart = _dismissPlayer.value;
                        _dismissPlayer.stop();
                      },
                onVerticalDragUpdate: showLyrics || _closingPlayer
                    ? null
                    : _dragPlayer,
                onVerticalDragEnd: showLyrics || _closingPlayer
                    ? null
                    : _settlePlayer,
                onVerticalDragCancel: showLyrics || _closingPlayer
                    ? null
                    : () {
                        if (_reducedPlayerMotion) {
                          _dismissPlayer.reset();
                        } else if (_playerDragStart < .18) {
                          _movePlayer(0);
                        }
                      },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NowPlayingBackdrop(
                      key: const ValueKey('now-playing-backdrop'),
                      identity: (
                        player.current?.id,
                        player.current?.fileId,
                        player.current?.coverFileId,
                        player.current?.coverPreview,
                        player.current?.title,
                        player.current?.size,
                      ),
                      artworkUpdates: telegram,
                      reducedMotion: player.settings.reducedMotion,
                      artwork: Artwork(
                        seed: player.current?.title ?? 'Auralis',
                        telegram: telegram,
                        track: player.current,
                        small: true,
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: _pageContent(
                        _Page.nowPlaying,
                        narrow: viewport.width < 1180,
                        short: viewport.height < 560,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null;
      // Fade a fixed, cached blur over the retained page. The real dock stays
      // underneath the card, so landing never swaps in a different mini-player.
      final background = expanded
          ? RepaintBoundary(
              key: const ValueKey('player-cached-blur'),
              child: ImageFiltered(
                key: const ValueKey('player-transition-blur'),
                imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: TickerMode(
                  enabled: false,
                  child: ExcludeFocus(
                    child: ExcludeSemantics(
                      child: IgnorePointer(
                        child: Material(
                          key: const ValueKey('player-collapse-background'),
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: _originContent(transitionCopy: true),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : null;
      return AnimatedBuilder(
        animation: _dismissPlayer,
        child: RepaintBoundary(
          key: const ValueKey('player-origin-page'),
          child: child,
        ),
        builder: (context, origin) {
          final progress = 1 - _dismissPlayer.value;
          // Geometry follows the controller directly, including during a drag.
          // The release simulation supplies the easing exactly once.
          final bounds = Rect.lerp(mini, full, progress)!;
          final contentOpacity = const Interval(.08, .7).transform(progress);
          final blurOpacity = const Interval(.08, .55).transform(progress);
          final cardOpacity = const Interval(0, .3).transform(progress);
          final transitioning =
              expanded && (_dismissPlayer.value > 0 || _closingPlayer);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Offstage(
                  offstage: expanded && !transitioning,
                  child: TickerMode(
                    enabled: !expanded,
                    child: ExcludeFocus(
                      excluding: expanded,
                      child: ExcludeSemantics(
                        excluding: expanded,
                        child: IgnorePointer(ignoring: expanded, child: origin),
                      ),
                    ),
                  ),
                ),
                if (transitioning)
                  Opacity(
                    key: const ValueKey('player-transition-blur-opacity'),
                    opacity: blurOpacity,
                    child: background,
                  ),
                if (expanded)
                  Positioned.fromRect(
                    rect: bounds,
                    child: Opacity(
                      key: const ValueKey('player-transition-card-opacity'),
                      opacity: cardOpacity,
                      child: ClipRRect(
                        key: const ValueKey('now-playing-container'),
                        borderRadius: BorderRadius.circular(
                          28 * (1 - progress),
                        ),
                        child: ColoredBox(
                          color: _colors.surfaceContainerLow,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              OverflowBox(
                                alignment: Alignment.topCenter,
                                minWidth: full.width,
                                maxWidth: full.width,
                                minHeight: full.height,
                                maxHeight: full.height,
                                child: Opacity(
                                  key: const ValueKey(
                                    'now-playing-content-opacity',
                                  ),
                                  opacity: contentOpacity,
                                  child: IgnorePointer(
                                    ignoring:
                                        _closingPlayer ||
                                        _dismissPlayer.isAnimating,
                                    child: TickerMode(
                                      enabled: !transitioning,
                                      child: SizedBox.fromSize(
                                        size: full.size,
                                        child: content,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );

  Future<void> _refreshLibrary() async {
    final generation = ++_cacheGeneration;
    setState(() {
      _cachingLibrary = false;
      _cachedTracks = 0;
    });
    telegram.clearImageCache();
    await library.refresh();
    if (!mounted || generation != _cacheGeneration || !telegram.ready) return;
    final tracks = List<Track>.of(library.tracks);
    final scope = telegram.mediaCache.directory?.path;
    final channels = player.settings.selectedChannels
        .map((c) => c.id)
        .join(',');
    bool active() =>
        mounted &&
        generation == _cacheGeneration &&
        telegram.ready &&
        telegram.mediaCache.directory?.path == scope &&
        player.settings.selectedChannels.map((c) => c.id).join(',') ==
            channels &&
        !player.restoringData;
    final pending = <({Track track, bool artwork, bool lyrics})>[];
    for (final track in tracks) {
      if (!active()) return;
      final artwork = !await telegram.hasCachedCover(track);
      if (!active()) return;
      final missingLyrics = await lyrics.loadCached(track) == null;
      if (!active()) return;
      if (artwork || missingLyrics) {
        pending.add((track: track, artwork: artwork, lyrics: missingLyrics));
      }
    }
    setState(() {
      _cachingLibrary = pending.isNotEmpty;
      _cacheTotal = pending.length;
    });
    for (final work in pending) {
      final track = work.track;
      if (!active()) break;
      try {
        if (work.artwork && !await telegram.hasCachedCover(track) && active()) {
          await telegram.cacheCover(track, active: active);
        }
      } catch (_) {
        /* Continue other tracks. */
      }
      if (!active()) break;
      try {
        if (work.lyrics && await lyrics.loadCached(track) == null && active()) {
          Lyrics? value;
          try {
            value = await telegram.embeddedLyrics(track);
          } catch (_) {
            // An unreadable embedded tag must not block online fallbacks.
          }
          if (!active()) break;
          // An import or playback lookup completed while reading the tag.
          value = lyrics.cached(track) ?? value;
          value ??= await lyrics.find(track);
          if (active() &&
              value != null &&
              !identical(lyrics.cached(track), value)) {
            lyrics.save(track, value);
          }
        }
      } catch (_) {
        /* Unavailable lyrics do not stop the remaining library. */
      }
      if (!active()) break;
      setState(() => _cachedTracks++);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (mounted && generation == _cacheGeneration) {
      setState(() => _cachingLibrary = false);
    }
  }

  Future<void> _stats({bool backup = false}) async {
    await player.flushListeningStats();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => StatsDataDialog(
        player: player,
        telegram: telegram,
        files: widget.dataFiles,
        openBackupSection: backup,
        onRestored: () async {
          setState(() {
            selectedPlaylist = null;
            collection = 'All songs';
          });
          await library.refresh();
        },
      ),
    );
  }

  Future<void> _openSetup() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => SetupView(
        player: player,
        telegram: telegram,
        version: widget.installedVersion ?? currentReleaseVersion,
        files: widget.dataFiles,
        connectBuilder: (_) =>
            PlayerShell(player: player, telegram: telegram, setupMode: true),
        onFinished: () => Navigator.of(context).pop(),
      ),
    ),
  );

  Future<void> _searchLibrary() async {
    _navigate(_Page.library);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Search library'),
        content: TextField(
          controller: search,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Song, artist or channel',
          ),
          onSubmitted: (_) => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _openTelegram() => _navigate(_Page.telegram);

  void _notice(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _shellUpdates,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        if (widget.setupMode) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Connect Telegram'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: _telegram(),
              ),
            ),
          );
        }
        final immersiveLyrics = destination == _Page.nowPlaying && showLyrics;
        final compact = box.maxWidth < 900;
        final narrow = box.maxWidth < 1180;
        final short = box.maxHeight < 560;
        return PopScope<Object?>(
          canPop: destination == _Page.library,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _back,
              const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
                  player.restoringData
                  ? null
                  : unawaited(player.audio.toggle()),
              const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
                  unawaited(player.next()),
              const SingleActivator(
                LogicalKeyboardKey.mediaTrackPrevious,
              ): () =>
                  unawaited(player.previous()),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: immersiveLyrics ? _colors.surface : null,
                body: SafeArea(
                  bottom: !compact,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Row(
                        children: [
                          if (!compact && !immersiveLyrics)
                            _navigation(narrow, short: short),
                          Expanded(
                            child: _playerSurface(child: _originContent()),
                          ),
                        ],
                      ),
                      if (_showVolume)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: IgnorePointer(
                            child: Semantics(
                              liveRegion: true,
                              label:
                                  'Volume ${player.settings.volume.round()} percent',
                              child: Material(
                                key: const ValueKey('volume-osd'),
                                elevation: 6,
                                color: _colors.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(18),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        player.settings.volume == 0
                                            ? Icons.volume_off_rounded
                                            : Icons.volume_up_rounded,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        '${player.settings.volume.round()}%',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _bottomNavigation({_Page? page, bool transitionCopy = false}) =>
      AppNavigation(
        key: transitionCopy ? null : const ValueKey('app-navigation'),
        style: player.settings.navigationStyle,
        radius: player.settings.navigationRadius,
        selected: (page ?? destination).index,
        onSelected: (i) => _navigate(_Page.values[i]),
        onSearch: _searchLibrary,
      );

  Widget _navigation(bool narrow, {bool short = false}) => Container(
    width: narrow ? 72 : 202,
    decoration: BoxDecoration(
      color: _colors.surfaceContainerLowest,
      border: Border(right: BorderSide(color: _colors.surfaceContainerHigh)),
    ),
    padding: EdgeInsets.symmetric(
      horizontal: narrow ? 8 : 14,
      vertical: short ? 8 : 16,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!short)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.graphic_eq_rounded, color: _colors.primary, size: 30),
              if (!narrow) ...[
                const SizedBox(width: 10),
                const Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Auralis',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.3,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        if (!short) const SizedBox(height: 8),
        if (!narrow && !short)
          Text(
            'A LITTLE CLOSER TO MUSIC',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _colors.onSurfaceVariant,
              fontSize: 8,
              letterSpacing: 1.4,
            ),
          ),
        SizedBox(
          height: short
              ? 0
              : narrow
              ? 20
              : 32,
        ),
        for (final (i, icon, label) in [
          (_Page.library, Icons.library_music_rounded, 'Library'),
          (_Page.telegram, Icons.send_rounded, 'Telegram'),
          (_Page.nowPlaying, Icons.album_rounded, 'Now playing'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Tooltip(
              message: label,
              child: Material(
                color: destination == i
                    ? _colors.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _navigate(i),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: short ? 10 : 16,
                    ),
                    child: Row(
                      mainAxisAlignment: narrow
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Icon(
                          icon,
                          color: destination == i
                              ? _colors.primary
                              : _colors.onSurfaceVariant,
                          size: 23,
                        ),
                        if (!narrow) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: destination == i
                                    ? _colors.primary
                                    : _colors.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        if (!narrow && !short)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'YOUR MUSIC. YOUR SPACE.\n\nIndependent. Open source.',
              style: TextStyle(
                color: _colors.onSurfaceVariant,
                fontSize: 10,
                height: 1.4,
              ),
            ),
          ),
        IconButton(
          onPressed: () => _navigate(_Page.settings),
          tooltip: 'Settings',
          style: IconButton.styleFrom(
            backgroundColor: destination == _Page.settings
                ? _colors.primaryContainer
                : Colors.transparent,
          ),
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    ),
  );

  Widget _header(
    bool narrow, {
    bool short = false,
    _Page? page,
  }) => LayoutBuilder(
    builder: (context, box) {
      final destination = page ?? this.destination;
      final inlineCounts =
          box.maxWidth >= 560 &&
          MediaQuery.textScalerOf(context).scale(12) <= 16;
      if (destination == _Page.settings) {
        return Row(
          children: [
            IconButton.filledTonal(
              tooltip: _settingsSection == null
                  ? 'Back to Library'
                  : 'Back to Settings',
              style: IconButton.styleFrom(
                backgroundColor: _colors.primaryContainer,
                foregroundColor: _colors.onPrimaryContainer,
              ),
              onPressed: _back,
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!short) ...[
                    Text(
                      _settingsSection == null ? 'MAKE IT YOURS' : 'SETTINGS',
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 1.7,
                        color: _colors.primary,
                      ),
                    ),
                    const SizedBox(height: 7),
                  ],
                  Text(
                    _settingsSection?.title ?? 'Settings',
                    key: const ValueKey('page-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: short
                          ? 24
                          : narrow
                          ? 28
                          : 36,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }
      return destination == _Page.nowPlaying
          ? Row(
              children: [
                IconButton.filledTonal(
                  key: const ValueKey('close-now-playing'),
                  tooltip: 'Back to Library',
                  onPressed: _closingPlayer ? null : _closeNowPlaying,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Now playing',
                    key: ValueKey('page-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                ),
                // Full-screen phones need these routes while navigation is hidden.
                if (MediaQuery.sizeOf(context).width < 900)
                  IconButton(
                    onPressed: () => _navigate(_Page.settings),
                    tooltip: 'Settings',
                    icon: const Icon(Icons.tune_rounded),
                  ),
              ],
            )
          : Row(
              children: [
                if (destination == _Page.settings) ...[
                  IconButton(
                    tooltip: 'Back to Library',
                    onPressed: _back,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!short)
                        Text(
                          switch (destination) {
                            _Page.library => 'YOUR COLLECTION',
                            _Page.telegram => 'MUSIC IN YOUR CHANNELS',
                            _Page.settings => 'MAKE IT YOURS',
                            _Page.nowPlaying => 'IN THE MOMENT',
                          },
                          style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 1.7,
                            color: _colors.primary,
                          ),
                        ),
                      if (!short) const SizedBox(height: 7),
                      Text(
                        key: const ValueKey('page-title'),
                        switch (destination) {
                          _Page.library => 'Library',
                          _Page.telegram => 'Telegram',
                          _Page.settings => 'Settings',
                          _Page.nowPlaying => 'Now playing',
                        },
                        style: TextStyle(
                          fontSize: short
                              ? 24
                              : narrow
                              ? 28
                              : 36,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -1.4,
                        ),
                      ),
                      if (destination == _Page.library && !inlineCounts) ...[
                        const SizedBox(height: 3),
                        _libraryCounts(),
                      ],
                    ],
                  ),
                ),
                if (destination == _Page.library) ...[
                  if (inlineCounts)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 230),
                        child: _libraryCounts(),
                      ),
                    ),
                  IconButton(
                    key: const ValueKey('library-refresh'),
                    tooltip: 'Refresh library',
                    onPressed:
                        !telegram.ready || library.saving || library.loading
                        ? null
                        : () {
                            unawaited(_refreshLibrary());
                          },
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                  PopupMenuButton<LibrarySort>(
                    tooltip: 'Sort Library',
                    icon: const Icon(Icons.sort_rounded),
                    position: PopupMenuPosition.under,
                    offset: const Offset(0, 6),
                    color: _colors.surfaceContainerLow,
                    surfaceTintColor: Colors.transparent,
                    elevation: 4,
                    shadowColor: const Color(0x40000000),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: _colors.outlineVariant),
                    ),
                    clipBehavior: Clip.antiAlias,
                    itemBuilder: (context) => [
                      for (final sort in LibrarySort.values)
                        CheckedPopupMenuItem(
                          value: sort,
                          checked: player.settings.librarySort == sort,
                          child: Text(
                            sort.label,
                            style: TextStyle(
                              color: player.settings.librarySort == sort
                                  ? _colors.primary
                                  : null,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                    onSelected: (sort) async {
                      setState(() => player.settings.librarySort = sort);
                      try {
                        await player.settings.save();
                      } catch (_) {
                        _notice(
                          'Sort changed for this session. Could not save your preference.',
                        );
                      }
                    },
                  ),
                ],
              ],
            );
    },
  );
  Widget _banner(String text) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _colors.errorContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: TextStyle(color: _colors.onErrorContainer, fontSize: 12),
    ),
  );
  Widget _search(String hint) => TextField(
    controller: search,
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      suffixIcon: search.text.isEmpty
          ? null
          : IconButton(
              onPressed: search.clear,
              tooltip: 'Clear search',
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
    ),
  );

  Future<String?> _editPlaylist({String? previous}) => showDialog<String>(
    context: context,
    builder: (dialogContext) {
      var name = previous ?? '';
      String? error;
      var busy = false;
      return StatefulBuilder(
        builder: (context, update) {
          Future<void> submit() async {
            if (busy) return;
            update(() {
              busy = true;
              error = null;
            });
            try {
              final saved = previous == null
                  ? await player.createPlaylist(name)
                  : await player.renamePlaylist(previous, name);
              if (dialogContext.mounted) Navigator.pop(dialogContext, saved);
            } catch (e) {
              if (dialogContext.mounted) {
                update(() {
                  busy = false;
                  error = e is ArgumentError
                      ? '${e.message}'
                      : e is StateError
                      ? e.message
                      : 'Could not save this playlist.';
                });
              }
            }
          }

          return AlertDialog(
            title: Text(
              previous == null ? 'Create playlist' : 'Rename playlist',
            ),
            content: SizedBox(
              width: 360,
              child: TextFormField(
                initialValue: previous,
                autofocus: true,
                maxLength: 60,
                enabled: !busy,
                onChanged: (value) => name = value,
                onFieldSubmitted: (_) => unawaited(submit()),
                decoration: InputDecoration(
                  labelText: 'Playlist name',
                  errorText: error,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(previous == null ? 'Create' : 'Rename'),
              ),
            ],
          );
        },
      );
    },
  );

  Future<void> _choosePlaylist(Track track) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist'),
        children: [
          for (final entry in player.settings.playlists.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(
                '${entry.key} · ${entry.value.length}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(
              'Create playlist',
              style: TextStyle(color: _colors.primary),
            ),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    final name = selected.isEmpty ? await _editPlaylist() : selected;
    if (!mounted || name == null) return;
    try {
      await player.addToPlaylist(name, track);
      _notice('Added to $name');
    } on StateError catch (e) {
      _notice(e.message);
    }
  }

  Future<void> _deletePlaylist(String name) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Remove “$name” from this device? The music in Telegram is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    await player.deletePlaylist(name);
    if (mounted) setState(() => selectedPlaylist = null);
  }

  Widget _sleepControl({Key? key}) => IconButton(
    key: key,
    tooltip: player.sleepActive ? 'Sleep timer active' : 'Sleep timer',
    onPressed: _sleepTimer,
    icon: Icon(
      Icons.bedtime_outlined,
      color: player.sleepActive ? _colors.primary : _colors.onSurfaceVariant,
    ),
  );

  Future<void> _sleepTimer() => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: player,
      builder: (context, _) => AlertDialog(
        title: const Text('Sleep timer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                player.sleepAfterTrack
                    ? 'Pauses at the end of the current track.'
                    : player.sleepUntil != null
                    ? 'Pauses at ${TimeOfDay.fromDateTime(player.sleepUntil!).format(context)}.'
                    : 'Pause playback after a duration or when the track ends.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final minutes in [15, 30, 45, 60, 90])
                    ActionChip(
                      label: Text('$minutes min'),
                      onPressed: () {
                        player.setSleepTimer(Duration(minutes: minutes));
                        Navigator.pop(context);
                      },
                    ),
                ],
              ),
              TextButton.icon(
                onPressed: player.current == null
                    ? null
                    : () {
                        player.sleepAtTrackEnd();
                        Navigator.pop(context);
                      },
                icon: const Icon(Icons.music_note_rounded),
                label: const Text('End of current track'),
              ),
            ],
          ),
        ),
        actions: [
          if (player.sleepActive)
            TextButton(
              onPressed: () {
                player.cancelSleepTimer();
                Navigator.pop(context);
              },
              child: const Text('Cancel timer'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );

  Widget _trackActions(Track track) => PopupMenuButton<String>(
    tooltip: 'Track actions for ${track.title}',
    icon: const Icon(Icons.playlist_play_rounded, size: 22),
    onSelected: (value) async {
      try {
        switch (value) {
          case 'favorite':
            await player.toggleFavorite(track);
          case 'next':
            player.playNext(track);
            _notice('Playing next');
          case 'playlist':
            await _choosePlaylist(track);
          case 'remove':
            final name = selectedPlaylist;
            if (name != null) await player.removeFromPlaylist(name, track);
        }
      } on StateError catch (e) {
        _notice(e.message);
      }
    },
    itemBuilder: (_) => [
      for (final (value, icon, label) in [
        (
          'favorite',
          player.settings.favoriteIds.contains(track.id)
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          player.settings.favoriteIds.contains(track.id)
              ? 'Remove from favorites'
              : 'Add to favorites',
        ),
        ('next', Icons.play_arrow_rounded, 'Play next'),
        ('playlist', Icons.playlist_add_rounded, 'Add to playlist'),
        if (collection == 'Playlists' && selectedPlaylist != null)
          (
            'remove',
            Icons.remove_circle_outline_rounded,
            'Remove from playlist',
          ),
      ])
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        ),
    ],
  );

  List<Track> _collectionTracks() {
    final tracks = library.tracks;
    if (collection == 'Favorites') {
      return tracks
          .where((t) => player.settings.favoriteIds.contains(t.id))
          .toList();
    }
    final ids = collection == 'Recently played'
        ? player.settings.recentIds
        : collection == 'Playlists'
        ? player.settings.playlists[selectedPlaylist] ?? <String>[]
        : null;
    if (ids == null) return tracks;
    final byId = {for (final track in tracks) track.id: track};
    return [
      for (final id in ids)
        if (byId[id] case final Track track) track,
    ];
  }

  Widget _playlists() {
    final entries = player.settings.playlists.entries
        .where(
          (entry) =>
              entry.key.toLowerCase().contains(search.text.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final name = await _editPlaylist();
              if (mounted && name != null) {
                setState(() {
                  selectedPlaylist = name;
                  search.clear();
                });
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create playlist'),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _empty(
                  Icons.playlist_play_rounded,
                  'Your playlists live here',
                  search.text.isEmpty
                      ? 'Create a playlist, then add music using a track’s actions.'
                      : 'No playlists match this search.',
                )
              : ListView.builder(
                  padding: EdgeInsets.only(bottom: _dockPadding),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => ListTile(
                    leading: Icon(
                      Icons.playlist_play_rounded,
                      color: _colors.primary,
                    ),
                    title: Text(
                      entries[i].key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${entries[i].value.length} saved tracks · on this device',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => setState(() {
                      selectedPlaylist = entries[i].key;
                      search.clear();
                    }),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _libraryCounts() {
    final tracks = _collectionTracks();
    final savedCount = collection == 'Favorites'
        ? player.settings.favoriteIds.length
        : collection == 'Recently played'
        ? player.settings.recentIds.length
        : selectedPlaylist != null
        ? player.settings.playlists[selectedPlaylist]?.length ?? 0
        : tracks.length;
    final trackText = collection == 'Playlists' && selectedPlaylist == null
        ? '${player.settings.playlists.length} playlists'
        : collection == 'All songs'
        ? '${tracks.length} ${tracks.length == 1 ? 'track' : 'tracks'}'
        : '${tracks.length} of $savedCount loaded';
    final channels = player.settings.selectedChannels.length;
    final label =
        '$trackText · $channels ${channels == 1 ? 'channel' : 'channels'}';
    return Tooltip(
      message: _cachingLibrary
          ? 'Caching artwork and lyrics: $_cachedTracks / $_cacheTotal'
          : label,
      child: Text(
        _cachingLibrary ? 'Caching $_cachedTracks / $_cacheTotal' : label,
        key: const ValueKey('library-counts'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 11),
      ),
    );
  }

  Widget _library() => LayoutBuilder(
    builder: (context, box) {
      final compact = box.maxHeight < 330;
      final tracks = _collectionTracks();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _search(
            collection == 'Playlists' && selectedPlaylist == null
                ? 'Search playlists'
                : 'Search your music',
          ),
          const SizedBox(height: 8),
          if (!compact || selectedPlaylist == null)
            if (player.settings.compactLibrary)
              Align(
                alignment: Alignment.centerLeft,
                child: IntrinsicWidth(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: _colors.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: const ValueKey('library-collection-menu'),
                        isExpanded: true,
                        value: collection,
                        items: [
                          for (final label in [
                            'All songs',
                            'Favorites',
                            'Playlists',
                            'Recently played',
                          ])
                            DropdownMenuItem(
                              value: label,
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              collection = value;
                              selectedPlaylist = null;
                              search.clear();
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final label in [
                      'All songs',
                      'Favorites',
                      'Playlists',
                      'Recently played',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: collection == label,
                          onSelected: (_) => setState(() {
                            collection = label;
                            selectedPlaylist = null;
                            search.clear();
                          }),
                        ),
                      ),
                    if (collection == 'Recently played' &&
                        player.settings.recentIds.isNotEmpty)
                      TextButton(
                        onPressed: player.clearRecent,
                        child: const Text('Clear history'),
                      ),
                  ],
                ),
              ),
          if (player.settings.compactLibrary &&
              collection == 'Recently played' &&
              player.settings.recentIds.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: player.clearRecent,
                child: const Text('Clear history'),
              ),
            ),
          if (collection == 'Playlists' && selectedPlaylist != null)
            Row(
              children: [
                IconButton(
                  tooltip: 'Back to playlists',
                  onPressed: () => setState(() {
                    selectedPlaylist = null;
                    search.clear();
                  }),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    selectedPlaylist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Rename playlist',
                  onPressed: () async {
                    final name = await _editPlaylist(
                      previous: selectedPlaylist,
                    );
                    if (mounted && name != null) {
                      setState(() => selectedPlaylist = name);
                    }
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete playlist',
                  onPressed: () => _deletePlaylist(selectedPlaylist!),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          if (library.error != null) _banner(library.error!),
          if (library.loading) ...[
            const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Loading music from your channels…',
                style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 11),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: collection == 'Playlists' && selectedPlaylist == null
                ? _playlists()
                : !telegram.ready
                ? _empty(
                    Icons.send_rounded,
                    'Connect Telegram for your music',
                    'Sign in and choose channels to fill your Library.',
                    action: FilledButton.tonalIcon(
                      onPressed: _openTelegram,
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Connect Telegram'),
                    ),
                  )
                : player.settings.selectedChannels.isEmpty
                ? _empty(
                    Icons.campaign_rounded,
                    'Choose your music channels',
                    'Select channels in Telegram. Their music appears here together.',
                    action: FilledButton.tonalIcon(
                      onPressed: _openTelegram,
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Choose channels'),
                    ),
                  )
                : library.tracks.isEmpty
                ? _empty(
                    Icons.library_music_rounded,
                    library.loading ? 'Finding your music' : 'No music loaded',
                    library.loading
                        ? 'Tracks appear here as your channels load.'
                        : 'Refresh to try again, or choose different channels.',
                  )
                : tracks.isEmpty && collection != 'All songs'
                ? _empty(
                    Icons.music_note_rounded,
                    'No loaded tracks in this collection',
                    'Add music using track actions. Saved entries appear when their Telegram channels are selected and loaded.',
                  )
                : _trackList(
                    tracks,
                    preserveOrder:
                        collection == 'Recently played' ||
                        collection == 'Playlists',
                  ),
          ),
        ],
      );
    },
  );
  Widget _trackList(List<Track> tracks, {bool preserveOrder = false}) {
    final query = search.text.toLowerCase();
    final visible = tracks
        .where(
          (t) => '${t.title} ${t.artist} ${t.source}'.toLowerCase().contains(
            query,
          ),
        )
        .toList();
    if (!preserveOrder) visible.sort(player.settings.librarySort.compare);
    if (visible.isEmpty) {
      return _empty(
        Icons.search_off_rounded,
        'No tracks found',
        'Try another search or choose a different source.',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(bottom: _dockPadding),
      itemCount: visible.length,
      itemBuilder: (context, i) => _trackTile(
        visible[i],
        onPlay: () => player.play(visible[i], from: visible),
      ),
    );
  }

  Widget _trackTile(Track track, {required VoidCallback onPlay}) {
    final active = player.current?.id == track.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active ? _colors.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          onTap: onPlay,
          leading: SizedBox(
            width: 42,
            height: 42,
            child: Artwork(
              seed: track.title,
              small: true,
              telegram: telegram,
              track: track,
            ),
          ),
          title: Text(
            key: ValueKey('track-title-${track.id}'),
            track.title.isEmpty ? 'Untitled audio' : track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active ? _colors.primary : null,
            ),
          ),
          subtitle: Text(
            '${track.artist} · ${track.source}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (track.duration > Duration.zero)
                Text(
                  clockText(track.duration),
                  style: TextStyle(
                    fontSize: 11,
                    color: _colors.onSurfaceVariant,
                  ),
                ),
              IconButton(
                tooltip: 'Add ${track.title} to queue',
                onPressed: () {
                  player.enqueue(track);
                  _notice('Added to queue');
                },
                icon: const Icon(Icons.playlist_add_rounded, size: 20),
              ),
              _trackActions(track),
            ],
          ),
        ),
      ),
    );
  }

  Widget _telegram() {
    if (!telegram.ready) return _signIn();
    final query = search.text.toLowerCase();
    final selected = player.settings.selectedChannels.map((c) => c.id).toSet();
    final channels =
        {
            for (final c in player.settings.selectedChannels) c.id: c,
            for (final c in telegram.channels) c.id: c,
          }.values.where((c) => c.title.toLowerCase().contains(query)).toList()
          ..sort((a, b) {
            if (selected.contains(a.id) != selected.contains(b.id)) {
              return selected.contains(a.id) ? -1 : 1;
            }
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _search('Find an accessible channel'),
        const SizedBox(height: 8),
        Expanded(
          child: CustomScrollView(
            key: const ValueKey('telegram-channels'),
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Select channels to combine their music in Library.',
                      style: TextStyle(
                        color: _colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${channels.length} channels · ${telegram.connection}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _colors.onSurfaceVariant,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: telegram.busy
                              ? null
                              : () => telegram.action(telegram.refreshChats),
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('Load more'),
                        ),
                        TextButton.icon(
                          onPressed: () => setState(() {
                            search.clear();
                            destination = _Page.library;
                          }),
                          icon: const Icon(
                            Icons.library_music_rounded,
                            size: 17,
                          ),
                          label: Text(
                            'Open Library (${player.settings.selectedChannels.length})',
                          ),
                        ),
                      ],
                    ),
                    if (telegram.error != null) _banner(telegram.error!),
                    if (library.error != null) _banner(library.error!),
                  ],
                ),
              ),
              if (channels.isEmpty)
                SliverToBoxAdapter(
                  child: _empty(
                    Icons.campaign_outlined,
                    'No channels to show',
                    'Join a channel in Telegram, then load your channels here.',
                  ),
                )
              else
                SliverList.builder(
                  itemCount: channels.length,
                  itemBuilder: (context, i) => CheckboxListTile(
                    value: library.selected(channels[i].id),
                    onChanged: library.saving
                        ? null
                        : (value) => unawaited(
                            library.select(channels[i], value ?? false),
                          ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    secondary: SizedBox(
                      width: 40,
                      height: 40,
                      child: ClipOval(
                        child: Artwork(
                          seed: channels[i].title,
                          small: true,
                          telegram: telegram,
                          fileId: channels[i].photoFileId,
                          preview: channels[i].photoPreview,
                        ),
                      ),
                    ),
                    title: Text(
                      channels[i].title,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      library.selected(channels[i].id)
                          ? 'Selected for Library'
                          : 'Add music to Library',
                      style: TextStyle(
                        color: _colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: _dockPadding)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _signIn() => SingleChildScrollView(
    padding: EdgeInsets.only(bottom: _dockPadding),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _colors.primaryContainer,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Icon(Icons.send_rounded, color: _colors.primary, size: 36),
            ),
            const SizedBox(height: 22),
            const Text(
              'Your channels. Your soundtrack.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -.6,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Connect Telegram to browse music shared in channels you can access. Audio stays on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _colors.onSurfaceVariant,
                height: 1.6,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 24),
            AuthForm(telegram: telegram),
            const SizedBox(height: 18),
            Text(
              'Credentials are encrypted on this device.\nLogin codes and passwords are never saved.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _colors.onSurfaceVariant,
                fontSize: 10,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  );

  Widget _artworkSwitcher({required Widget child, bool paged = false}) =>
      ArtworkTrackSwitcher(
        key: const ValueKey('artwork-track-switcher'),
        paged: paged,
        identity: (player.current?.id, player.index),
        reducedMotion: player.settings.reducedMotion,
        onNext:
            !player.restoringData &&
                player.current != null &&
                player.queue.length > 1 &&
                (player.index + 1 < player.queue.length || player.repeat)
            ? () => unawaited(player.next())
            : null,
        onPrevious: !player.restoringData && player.index > 0
            ? () => unawaited(player.playAt(player.index - 1))
            : null,
        child: child,
      );

  Widget _miniNowPlaying(BoxConstraints box, Track? track) {
    final coverSize = math.min(
      200.0,
      math.min(box.maxWidth - 18, box.maxHeight * .36),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'NOW PLAYING',
          style: TextStyle(
            color: _colors.onSurfaceVariant,
            fontSize: 10,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: coverSize,
                maxHeight: coverSize,
              ),
              child: AspectRatio(
                aspectRatio: 1,
                child: _artworkSwitcher(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Artwork(
                      key: const ValueKey('mini-now-playing-artwork'),
                      seed: track?.title ?? 'Auralis',
                      telegram: telegram,
                      track: track,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          track?.title ?? 'Find your next favorite',
          key: const ValueKey('mini-now-playing-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          track?.artist ?? 'A space for the music you love',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 12),
        ),
        const SizedBox(height: 14),
        Row(
          key: const ValueKey('mini-now-playing-actions'),
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: track == null
                    ? null
                    : () => _navigate(_Page.nowPlaying, openLyrics: true),
                icon: const Icon(Icons.lyrics_rounded, size: 17),
                label: const Text('Lyrics'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _nowPlaying({bool compact = false}) {
    final track = player.current;
    final audio = player.audio;
    final duration = audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final nextIndex = player.index + 1;
    final hasNext = player.index >= 0 && nextIndex < player.queue.length;
    final favorite = player.settings.favoriteIds.contains(track?.id);

    return Material(
      color: Colors.transparent,
      child: LayoutBuilder(
        key: ValueKey(
          compact ? 'mini-now-playing-layout' : 'now-playing-layout',
        ),
        builder: (context, box) {
          if (compact) return _miniNowPlaying(box, track);
          final scale = MediaQuery.textScalerOf(context)
              .scale(1)
              .clamp(1.0, 2.0);
          final horizontal = box.maxWidth >= 700;
          final preview =
              hasNext && box.maxWidth >= 680 && box.maxHeight >= 440 * scale;
          final previewHeight = 40.0 + 52 * scale;
          final heroHeight =
              box.maxHeight - 12 - (preview ? previewHeight + 12 : 0);
          final tight = heroHeight < (horizontal ? 550 : 520) * scale;
          final veryShort = horizontal && heroHeight < 360;
          final comfortable = horizontal && heroHeight >= 420 * scale;
          final spacious = heroHeight >= 580 * scale;
          final gap = veryShort
              ? 4.0
              : spacious
              ? 10.0
              : 6.0;
          final transportHeight = veryShort
              ? 48.0
              : horizontal
              ? (spacious
                    ? 72.0
                    : comfortable
                    ? 56.0
                    : 52.0)
              : tight
              ? 52.0
              : 72.0;

          Widget pill({
            required String tooltip,
            required IconData icon,
            required VoidCallback? onPressed,
            Color background = Colors.transparent,
            Color? foreground,
            bool selected = false,
            Key? key,
          }) => IconButton(
            key: key,
            tooltip: tooltip,
            isSelected: selected,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: background,
              foregroundColor: foreground ?? _colors.primary,
              disabledBackgroundColor: Colors.transparent,
              shape: const CircleBorder(),
            ),
            icon: Icon(icon, size: 24),
          );

          Widget artwork() => LayoutBuilder(
            builder: (context, artBox) {
              final size = math.max(
                0.0,
                math.min(
                  horizontal ? 410.0 : 380.0,
                  math.min(artBox.maxHeight, artBox.maxWidth),
                ),
              );
              Widget cover(Track? item, {Key? key}) => ArtworkMotion(
                reducedMotion: player.settings.reducedMotion,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(tight ? 26 : 34),
                    border: Border.all(
                      color: _colors.primary.withValues(alpha: .14),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(tight ? 21 : 29),
                      child: Artwork(
                        key: key,
                        seed: item?.title ?? 'Auralis',
                        telegram: telegram,
                        track: item,
                      ),
                    ),
                  ),
                ),
              );
              return Center(
                child: SizedBox.square(
                  dimension: size,
                  child: track == null
                      ? cover(null, key: const ValueKey('now-playing-artwork'))
                      : _artworkSwitcher(
                          paged: true,
                          child: ArtworkPager(
                            index: player.index,
                            itemCount:
                                player.queue.length +
                                (player.repeat && player.queue.length > 1
                                    ? 1
                                    : 0),
                            onSelected: player.restoringData
                                ? null
                                : (index) => unawaited(
                                    player.playAt(index % player.queue.length),
                                  ),
                            itemBuilder: (context, index) => cover(
                              player.queue[index % player.queue.length],
                              key: index == player.index
                                  ? const ValueKey('now-playing-artwork')
                                  : ValueKey(('artwork-page', index)),
                            ),
                          ),
                        ),
                ),
              );
            },
          );

          Widget details() => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (horizontal && comfortable && track != null) ...[
                Text(
                  'PLAYING FROM  ·  ${track.source.isEmpty ? 'YOUR LIBRARY' : track.source}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _colors.primary,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                track?.title ?? 'Find your next favorite',
                key: const ValueKey('now-playing-title'),
                maxLines: horizontal
                    ? (comfortable ? 2 : 1)
                    : tight
                    ? 1
                    : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: horizontal
                      ? (veryShort
                            ? 20
                            : spacious
                            ? 34
                            : comfortable
                            ? 28
                            : 24)
                      : tight
                      ? 22
                      : 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.7,
                  height: 1.18,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                track?.artist ?? 'Choose a song from your Library',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _colors.onSurfaceVariant,
                  fontSize: veryShort
                      ? 12
                      : tight
                      ? 14
                      : 16,
                ),
              ),
            ],
          );

          final seek = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              WaveSeekBar(
                value: progress,
                playing: audio.playing && !audio.buffering && track != null,
                reducedMotion: player.settings.reducedMotion,
                format: (v) =>
                    clockText(Duration(milliseconds: (v * duration).round())),
                onChanged: duration <= 0
                    ? null
                    : (v) => player.seek(
                        Duration(milliseconds: (v * duration).round()),
                      ),
              ),
              Row(
                children: [
                  Text(
                    clockText(audio.position),
                    style: TextStyle(
                      fontSize: 11,
                      color: _colors.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    clockText(audio.duration),
                    style: TextStyle(
                      fontSize: 11,
                      color: _colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          );

          final transport = SizedBox(
            key: const ValueKey('now-playing-transport'),
            height: transportHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Previous track',
                  onPressed: track == null
                      ? null
                      : () => unawaited(player.previous()),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(48),
                    foregroundColor: _colors.primary,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.skip_previous_rounded, size: 30),
                ),
                SizedBox(width: tight ? 18 : 26),
                SizedBox.square(
                  dimension: math.min(transportHeight, 64.0),
                  child: IconButton.filled(
                    key: const ValueKey('now-playing-play-pause'),
                    tooltip: audio.playing ? 'Pause' : 'Play',
                    onPressed: track == null || player.loading
                        ? null
                        : audio.toggle,
                    style: IconButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: _colors.primary,
                      foregroundColor: _colors.onPrimary,
                      shape: const CircleBorder(),
                    ),
                    icon: player.loading || audio.buffering
                        ? SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _colors.onPrimary,
                            ),
                          )
                        : Icon(
                            audio.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: tight ? 32 : 38,
                          ),
                  ),
                ),
                SizedBox(width: tight ? 18 : 26),
                IconButton(
                  tooltip: 'Next track',
                  onPressed: track == null
                      ? null
                      : () => unawaited(player.next()),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(48),
                    foregroundColor: _colors.primary,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.skip_next_rounded, size: 30),
                ),
              ],
            ),
          );

          final modes = SizedBox(
            key: const ValueKey('now-playing-modes'),
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                pill(
                  key: const ValueKey('now-playing-shuffle'),
                  tooltip: player.shuffleEnabled
                      ? 'Shuffle: on'
                      : 'Shuffle: off',
                  icon: Icons.shuffle_rounded,
                  selected: player.shuffleEnabled,
                  onPressed: player.queue.length > 1 || player.shuffleEnabled
                      ? player.shuffle
                      : null,
                  background: player.shuffleEnabled
                      ? _colors.primaryContainer
                      : Colors.transparent,
                  foreground: player.shuffleEnabled
                      ? _colors.onPrimaryContainer
                      : _colors.onSurfaceVariant,
                ),
                const SizedBox(width: 20),
                pill(
                  key: const ValueKey('now-playing-repeat'),
                  selected: player.repeat,
                  tooltip: switch (player.repeatMode) {
                    PlaybackRepeat.off => 'Repeat: off',
                    PlaybackRepeat.all => 'Repeat: queue',
                    PlaybackRepeat.one => 'Repeat: one track',
                  },
                  icon: player.repeatMode == PlaybackRepeat.one
                      ? Icons.repeat_one_rounded
                      : Icons.repeat_rounded,
                  onPressed: player.toggleRepeat,
                  background: player.repeat
                      ? _colors.primary.withValues(alpha: .16)
                      : Colors.transparent,
                  foreground: player.repeat
                      ? _colors.primary
                      : _colors.onSurfaceVariant,
                ),
                const SizedBox(width: 20),
                pill(
                  key: const ValueKey('now-playing-favorite'),
                  selected: favorite,
                  tooltip: favorite
                      ? 'Remove from favorites'
                      : 'Add to favorites',
                  icon: favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  background: favorite
                      ? _colors.primary.withValues(alpha: .12)
                      : Colors.transparent,
                  foreground: favorite
                      ? _colors.primary
                      : _colors.onSurfaceVariant,
                  onPressed: track == null
                      ? null
                      : () async {
                          try {
                            await player.toggleFavorite(track);
                          } on StateError catch (e) {
                            _notice(e.message);
                          }
                        },
                ),
              ],
            ),
          );

          final actions = LayoutBuilder(
            builder: (context, actionBox) {
              final labels = actionBox.maxWidth >= 400 * scale;
              return Row(
                key: const ValueKey('now-playing-actions'),
                children: [
                  Tooltip(
                    message: 'Lyrics',
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: EdgeInsets.symmetric(
                          horizontal: labels ? 12 : 8,
                        ),
                        backgroundColor: labels
                            ? _colors.primary.withValues(alpha: .09)
                            : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: track == null
                          ? null
                          : () => setState(() {
                              showLyrics = true;
                              search.clear();
                            }),
                      icon: const Icon(Icons.lyrics_rounded, size: 21),
                      label: labels
                          ? const Text('Lyrics')
                          : const SizedBox.shrink(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add to playlist',
                    onPressed: track == null
                        ? null
                        : () => _choosePlaylist(track),
                    icon: const Icon(Icons.playlist_add_rounded),
                  ),
                  _sleepControl(key: const ValueKey('sleep-timer-control')),
                ],
              );
            },
          );

          final controls = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (horizontal) ...[details(), SizedBox(height: gap)],
              seek,
              SizedBox(height: gap),
              transport,
              SizedBox(height: gap),
              modes,
              SizedBox(height: gap),
              actions,
            ],
          );

          final hero = horizontal
              ? Row(
                  children: [
                    Expanded(flex: 5, child: artwork()),
                    const SizedBox(width: 28),
                    Expanded(flex: 6, child: controls),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: tight
                          ? Row(
                              children: [
                                SizedBox(
                                  width: math.min(116, box.maxWidth * .32),
                                  child: artwork(),
                                ),
                                const SizedBox(width: 16),
                                Expanded(child: details()),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: artwork()),
                                SizedBox(height: gap),
                                details(),
                              ],
                            ),
                    ),
                    SizedBox(height: gap),
                    controls,
                  ],
                );

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1140),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: hero),
                    if (preview) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        height: previewHeight,
                        child: Material(
                          color: _colors.surfaceContainerLow.withValues(
                            alpha: .72,
                          ),
                          borderRadius: BorderRadius.circular(22),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: const ValueKey('now-playing-next-0'),
                            onTap: () => player.playAt(nextIndex),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: SizedBox.square(
                                      dimension: 48,
                                      child: Artwork(
                                        seed: player.queue[nextIndex].title,
                                        telegram: telegram,
                                        track: player.queue[nextIndex],
                                        small: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'UP NEXT · ${player.queue.length - nextIndex} tracks',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _colors.primary,
                                            fontSize: 10,
                                            letterSpacing: 1,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          player.queue[nextIndex].title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          player.queue[nextIndex].artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _colors.onSurfaceVariant,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Icon(
                                    Icons.play_circle_fill_rounded,
                                    size: 32,
                                    color: _colors.primary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(
    IconData icon,
    String title,
    String description, {
    Widget? action,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: _colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(34),
            ),
            child: Icon(icon, size: 38, color: _colors.primary),
          ),
          const SizedBox(height: 22),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _colors.onSurfaceVariant,
              height: 1.8,
              fontSize: 12,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 24), action],
        ],
      ),
    ),
  );

  Widget _transport(
    bool narrow, {
    bool short = false,
    bool transitionCopy = false,
  }) {
    final audio = player.audio, duration = player.audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final transportButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (player.loading || audio.buffering)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        IconButton(
          onPressed: player.current == null ? null : player.previous,
          tooltip: 'Previous track',
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 2),
        IconButton.filled(
          onPressed: player.current == null || player.loading
              ? null
              : audio.toggle,
          tooltip: audio.playing ? 'Pause' : 'Play',
          style: IconButton.styleFrom(
            backgroundColor: _colors.primary,
            foregroundColor: _colors.onPrimary,
          ),
          icon: Icon(
            audio.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        const SizedBox(width: 2),
        IconButton(
          onPressed: player.current == null ? null : player.next,
          tooltip: 'Next track',
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );

    final progressBar = Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(
            clockText(audio.position),
            style: TextStyle(fontSize: 10, color: _colors.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: WaveSeekBar(
            value: progress,
            playing:
                audio.playing && !audio.buffering && player.current != null,
            reducedMotion: player.settings.reducedMotion,
            format: (v) =>
                clockText(Duration(milliseconds: (v * duration).round())),
            onChanged: duration <= 0
                ? null
                : (v) => player.seek(
                    Duration(milliseconds: (v * duration).round()),
                  ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            clockText(audio.duration),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10, color: _colors.onSurfaceVariant),
          ),
        ),
      ],
    );

    final compactPreview = Material(
      color: Colors.transparent,
      child: InkWell(
        key: transitionCopy ? null : const ValueKey('open-current-track'),
        borderRadius: BorderRadius.circular(14),
        onTap: player.current == null
            ? null
            : () => _navigate(_Page.nowPlaying),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.square(
                dimension: 36,
                child: Artwork(
                  seed: player.current?.title ?? 'Auralis',
                  small: true,
                  telegram: telegram,
                  track: player.current,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    player.current?.title ?? 'Nothing playing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    player.current?.artist ?? 'Choose a track',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: _colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final reduced =
        player.settings.reducedMotion ||
        MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: PlayerDockMotion(
        key: transitionCopy ? null : _dockKey,
        reducedMotion: reduced,
        enabled: !player.restoringData,
        onExpandStart: (_) => _navigate(_Page.nowPlaying, draggingDock: true),
        onExpandUpdate: _dragPlayer,
        onExpandEnd: _settleDock,
        onExpandCancel: () {
          if (!_reducedPlayerMotion && destination == _Page.nowPlaying) {
            unawaited(_closeNowPlaying());
          }
        },
        child: Material(
          key: transitionCopy ? null : const ValueKey('player-bar'),
          color: _colors.surfaceContainerLow,
          elevation: 4,
          shadowColor: Colors.black38,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              narrow ? 12 : 18,
              narrow ? 4 : 10,
              narrow ? 12 : 18,
              narrow ? 8 : 12,
            ),
            child: narrow
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      progressBar,
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(child: compactPreview),
                          const SizedBox(width: 4),
                          transportButtons,
                        ],
                      ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      if (short) {
                        return Row(
                          children: [
                            Expanded(child: compactPreview),
                            const SizedBox(width: 12),
                            Expanded(child: progressBar),
                            const SizedBox(width: 12),
                            transportButtons,
                          ],
                        );
                      }
                      if (box.maxWidth < 960) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(child: compactPreview),
                                transportButtons,
                              ],
                            ),
                            progressBar,
                          ],
                        );
                      }
                      return Row(
                        children: [
                          SizedBox(width: 220, child: compactPreview),
                          const SizedBox(width: 12),
                          transportButtons,
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 5,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [progressBar],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _savePreferences(VoidCallback update) async {
    setState(update);
    player.refreshSettings();
    try {
      await player.settings.save();
    } catch (_) {
      if (mounted) _notice('Preferences are active, but could not be saved.');
    }
  }

  Widget _preferenceChoice<T>(
    String title,
    T? value,
    List<T> values,
    String Function(T) label,
    ValueChanged<T?> onChanged, {
    bool allowNone = false,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(title, style: const TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: DropdownButtonHideUnderline(
            child: SizedBox(
              height: 48,
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                items: [
                  if (allowNone)
                    DropdownMenuItem<T>(
                      value: null,
                      child: const Text('None', style: TextStyle(fontSize: 12)),
                    ),
                  for (final item in values)
                    DropdownMenuItem<T>(
                      value: item,
                      child: Text(
                        label(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _lyricPreferences() {
    final prefs = player.settings;
    return ExpansionTile(
      key: const ValueKey('lyrics-preferences'),
      tilePadding: EdgeInsets.zero,
      title: const Text('Lyrics & translation'),
      subtitle: Text(
        '${prefs.automaticLyrics ? 'Automatic' : 'Manual'} · ${prefs.lyricsFirst.label}',
      ),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Find lyrics automatically'),
          value: prefs.automaticLyrics,
          onChanged: (v) => _savePreferences(() => prefs.automaticLyrics = v),
        ),
        _preferenceChoice(
          'Lyrics first',
          prefs.lyricsFirst,
          LyricsSource.values,
          (v) => v.label,
          (v) {
            if (v == null) return;
            unawaited(
              _savePreferences(() {
                final old = prefs.lyricsFirst;
                prefs.lyricsFirst = v;
                if (prefs.lyricsFallback == v) prefs.lyricsFallback = old;
              }),
            );
          },
        ),
        _preferenceChoice(
          'Lyrics fallback',
          prefs.lyricsFallback,
          LyricsSource.values.where((v) => v != prefs.lyricsFirst).toList(),
          (v) => v.label,
          (v) => _savePreferences(() => prefs.lyricsFallback = v),
          allowNone: true,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Translate automatically'),
          subtitle: const Text('Sends lyric text to the selected translator'),
          value: prefs.automaticTranslation,
          onChanged: (v) =>
              _savePreferences(() => prefs.automaticTranslation = v),
        ),
        _preferenceChoice(
          'Direction',
          prefs.translationDirection,
          TranslationDirection.values,
          (v) => v.label,
          (v) {
            if (v != null) {
              unawaited(_savePreferences(() => prefs.translationDirection = v));
            }
          },
        ),
        _preferenceChoice(
          'Translate first',
          prefs.translationFirst,
          TranslationSource.values,
          (v) => v.label,
          (v) {
            if (v == null) return;
            unawaited(
              _savePreferences(() {
                final old = prefs.translationFirst;
                prefs.translationFirst = v;
                if (prefs.translationFallback == v) {
                  prefs.translationFallback = old;
                }
              }),
            );
          },
        ),
        _preferenceChoice(
          'Translate fallback',
          prefs.translationFallback,
          TranslationSource.values
              .where((v) => v != prefs.translationFirst)
              .toList(),
          (v) => v.label,
          (v) => _savePreferences(() => prefs.translationFallback = v),
          allowNone: true,
        ),
      ],
    );
  }

  Widget _artworkPreferences() {
    final prefs = player.settings;
    final counts = {0, 5, 10, 20, 50, prefs.artworkPreload}.toList()..sort();
    return ExpansionTile(
      key: const ValueKey('artwork-preferences'),
      tilePadding: EdgeInsets.zero,
      title: const Text('Artwork'),
      subtitle: Text(
        '${prefs.artworkPreload} upcoming · ${prefs.keepArtwork ? 'Kept on device' : 'Temporary'}',
      ),
      children: [
        _preferenceChoice(
          'Preload artwork',
          prefs.artworkPreload,
          counts,
          (v) => v == 0 ? 'Current song only' : '$v upcoming songs',
          (v) {
            if (v != null) {
              unawaited(_savePreferences(() => prefs.artworkPreload = v));
            }
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep saved artwork'),
          subtitle: const Text(
            'On: keep covers. Off: remove saved covers and use temporary artwork.',
          ),
          value: prefs.keepArtwork,
          onChanged: (v) async {
            await _savePreferences(() => prefs.keepArtwork = v);
            if (!v && !prefs.keepArtwork) {
              final disk = telegram.mediaCache;
              if (disk.directory != null) {
                await MediaCache.drain(disk.directory!);
              }
              if (!prefs.keepArtwork) await disk.clearArtwork();
            }
          },
        ),
      ],
    );
  }

  List<Widget> _settingsContent(SettingsSection section) => switch (section) {
    SettingsSection.general => [
      ListTile(
        leading: const Icon(Icons.auto_awesome_rounded),
        title: const Text('Set up Auralis'),
        subtitle: const Text('Connection, appearance and playback preferences'),
        onTap: _openSetup,
      ),
      ListTile(
        leading: const Icon(Icons.volume_up_outlined),
        title: const Text('Volume controls'),
        subtitle: Text(
          Theme.of(context).platform == TargetPlatform.android
              ? 'Use your phone’s volume buttons.'
              : '↑ / ↓ changes volume and shows the level on screen.',
        ),
      ),
      const ListTile(
        leading: Icon(Icons.bedtime_outlined),
        title: Text('Sleep timer'),
        subtitle: Text(
          'Use the clock control in Now Playing to stop after a duration or at the end of a song.',
        ),
      ),
    ],
    SettingsSection.appearance => [
      AppearancePreferences(
        settings: player.settings,
        onChanged: () {
          player.refreshSettings();
          unawaited(
            player.settings.save().catchError((Object _) {
              _notice('Could not save appearance. Please try again.');
            }),
          );
        },
      ),
    ],
    SettingsSection.media => [_lyricPreferences(), _artworkPreferences()],
    SettingsSection.data => [
      ListTile(
        leading: const Icon(Icons.bar_chart_rounded),
        title: const Text('Listening stats'),
        subtitle: const Text('Listening time & export'),
        onTap: () => _stats(),
      ),
      ListTile(
        leading: const Icon(Icons.backup_outlined),
        title: const Text('Backup & Restore'),
        subtitle: const Text('Stats, collections and preferences'),
        onTap: () => _stats(backup: true),
      ),
      if (widget.sync != null) SyncSettings(controller: widget.sync!),
    ],
    SettingsSection.privacy => [
      const ListTile(
        leading: Icon(Icons.shield_outlined),
        title: Text('Protected on this device'),
        subtitle: Text(
          'Telegram credentials are encrypted with Android Keystore or Windows DPAPI. Login codes and two-step verification passwords are never saved.',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.send_rounded),
        title: Text(telegram.ready ? 'Telegram connected' : 'Connect Telegram'),
        subtitle: const Text('Manage your sign-in and selected channels'),
        onTap: _openTelegram,
      ),
      if (telegram.ready)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: telegram.busy
                ? null
                : () async {
                    await player.clear();
                    await telegram.logout();
                    if (telegram.ready && telegram.error != null) {
                      _notice(telegram.error!);
                    }
                    if (!telegram.ready) {
                      player.settings.selectedChannels = [];
                      try {
                        await player.settings.save();
                      } catch (_) {
                        _notice(
                          'Signed out, but the old channel selection could not be removed from settings.',
                        );
                      }
                      if (mounted) _openTelegram();
                    }
                  },
            child: const Text('Sign out of Telegram'),
          ),
        ),
    ],
    SettingsSection.updates => [
      if (widget.updater != null)
        UpdateSettings(updater: widget.updater!, showHeading: false),
    ],
    SettingsSection.about => [
      ListTile(
        leading: const Icon(Icons.graphic_eq_rounded),
        title: const Text('Auralis'),
        subtitle: Text(
          '${widget.updater?.currentVersion ?? currentReleaseVersion} · AGPL-3.0-or-later\nlibmpv · TDLib',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.new_releases_outlined),
        title: const Text('What’s new'),
        onTap: () => showInstalledChanges(
          context,
          widget.installedVersion ??
              widget.updater?.currentVersion ??
              currentReleaseVersion,
        ),
      ),
      ListTile(
        leading: const Icon(Icons.description_outlined),
        title: const Text('Licenses'),
        onTap: () => showLicensePage(
          context: context,
          applicationName: 'Auralis',
          applicationVersion:
              widget.updater?.currentVersion ?? currentReleaseVersion,
        ),
      ),
    ],
  };

  Widget _settingsPage() => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: KeyedSubtree(
        key: const ValueKey('settings-page'),
        child: _settingsSection == null
            ? SettingsDirectory(
                search: settingsSearch,
                sections: [
                  for (final section in SettingsSection.values)
                    if (section != SettingsSection.updates ||
                        widget.updater != null)
                      section,
                ],
                onSelected: (section) =>
                    setState(() => _settingsSection = section),
                bottomPadding: _dockPadding,
              )
            : ListTileTheme(
                data: ListTileThemeData(
                  iconColor: _colors.primary,
                  dense: true,
                  minVerticalPadding: 8,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  titleTextStyle: Theme.of(context).textTheme.titleSmall!
                      .copyWith(color: _colors.onSurface),
                  subtitleTextStyle: Theme.of(context).textTheme.bodySmall!
                      .copyWith(color: _colors.onSurfaceVariant),
                ),
                child: ListView(
                  key: PageStorageKey(
                    'settings-${_settingsSection!.name}-content',
                  ),
                  padding: EdgeInsets.only(bottom: _dockPadding),
                  children: _settingsContent(_settingsSection!),
                ),
              ),
      ),
    ),
  );
}

class AuthForm extends StatefulWidget {
  const AuthForm({super.key, required this.telegram});
  final TelegramService telegram;
  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  final apiId = TextEditingController(),
      apiHash = TextEditingController(),
      value = TextEditingController(),
      phone = TextEditingController();
  String? _lastState;
  PhoneCountry? _country;
  bool _editingNumber = false;
  String? _phoneError;
  @override
  void dispose() {
    apiId.dispose();
    apiHash.dispose();
    value.dispose();
    phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final td = widget.telegram;
    if (_lastState != td.state) {
      value.clear();
      if (td.state == 'disconnected') {
        apiId.clear();
        apiHash.clear();
        phone.clear();
        _country = null;
      }
      if (td.state != 'authorizationStateWaitCode') _editingNumber = false;
      _phoneError = null;
      _lastState = td.state;
    }
    final initial = td.state == 'disconnected';
    final enteringPhone =
        td.state == 'authorizationStateWaitPhoneNumber' || _editingNumber;
    final label = switch (td.state) {
      'authorizationStateWaitPhoneNumber' => 'Phone number',
      'authorizationStateWaitCode' => 'Login code from Telegram',
      'authorizationStateWaitPassword' => 'Two-step verification password',
      'authorizationStateWaitEmailAddress' =>
        'Email address requested by Telegram',
      'authorizationStateWaitEmailCode' => 'Email verification code',
      _ => null,
    };
    Future<void> submit() async {
      if (enteringPhone) {
        try {
          final number = internationalLoginNumber(
            phone.text,
            country: _country,
          );
          setState(() => _phoneError = null);
          if (_editingNumber) {
            await td.changeLoginPhoneNumber(number);
            if (mounted && td.error == null) {
              setState(() {
                _editingNumber = false;
                value.clear();
              });
            }
          } else {
            await td.submit(number);
          }
        } on FormatException catch (e) {
          if (mounted) setState(() => _phoneError = e.message);
        }
      } else if (initial) {
        if (td.hasApplicationCredentials) {
          await td.start();
        } else {
          await td.start(
            apiId: int.tryParse(apiId.text.trim()) ?? 0,
            apiHash: apiHash.text.trim(),
          );
        }
        apiHash.clear();
      } else {
        final input = value.text;
        value.clear();
        await td.submit(input);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (initial && td.hasApplicationCredentials)
          const Text(
            'Sign in with your Telegram account to access your music channels.',
          )
        else if (initial) ...[
          Text(
            'Create an API application at my.telegram.org, then enter its details here.',
            style: TextStyle(
              fontSize: 12,
              color: _colors.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: apiId,
            decoration: const InputDecoration(labelText: 'Telegram API ID'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: apiHash,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Telegram API hash'),
          ),
        ] else if (enteringPhone) ...[
          PhoneNumberInput(
            controller: phone,
            country: _country,
            enabled: !td.busy,
            loadCountries: td.loginCountries,
            onCountryChanged: (country) => setState(() {
              _country = country;
              _phoneError = null;
            }),
            onSubmitted: submit,
          ),
          if (_editingNumber)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: td.busy
                    ? null
                    : () => setState(() {
                        _editingNumber = false;
                        _phoneError = null;
                        value.clear();
                      }),
                child: const Text('Cancel number change'),
              ),
            ),
        ] else if (td.state ==
            'authorizationStateWaitOtherDeviceConfirmation') ...[
          const Text(
            'Open Settings → Data & sync → Account & sync to see this device’s sign-in code and approve it on a connected device, or choose phone sign-in there.',
          ),
        ] else if (label != null) ...[
          if (td.state == 'authorizationStateWaitCode') ...[
            Text(
              td.authenticationPhoneNumber == null
                  ? 'Enter the code sent by Telegram.'
                  : 'Code sent to ${td.authenticationPhoneNumber}',
              key: const ValueKey('login-code-number'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('change-login-number'),
                onPressed: td.busy
                    ? null
                    : () => setState(() {
                        final sent = td.authenticationPhoneNumber;
                        if (sent != null) {
                          final prefix = _country == null
                              ? null
                              : '+${_country!.callingCode}';
                          phone.text = prefix != null && sent.startsWith(prefix)
                              ? sent.substring(prefix.length)
                              : sent;
                        }
                        _editingNumber = true;
                        _phoneError = null;
                        value.clear();
                      }),
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Change number'),
              ),
            ),
          ],
          TextField(
            key: ValueKey(td.state),
            controller: value,
            obscureText: td.state == 'authorizationStateWaitPassword',
            autocorrect: false,
            enableSuggestions: false,
            enabled: !td.busy,
            keyboardType:
                td.state == 'authorizationStateWaitCode' ||
                    td.state == 'authorizationStateWaitEmailCode'
                ? TextInputType.number
                : TextInputType.text,
            autofillHints:
                td.state == 'authorizationStateWaitCode' ||
                    td.state == 'authorizationStateWaitEmailCode'
                ? const [AutofillHints.oneTimeCode]
                : null,
            decoration: InputDecoration(labelText: label),
            onSubmitted: td.busy ? null : (_) => submit(),
          ),
        ] else
          Text(switch (td.state) {
            'authorizationStateWaitRegistration' => 'Create your Telegram account in the official app first, then restart Auralis.',
            'authorizationStateClosed' =>
              'Telegram was closed. Restart Auralis to reconnect.',
            'authorizationStateLoggingOut' => 'Signing out of Telegram… Keep your internet connection available. You can sign in again when sign-out finishes.',
            'authorizationStateWaitPremiumPurchase' => 'Telegram requires a Premium verification step. Complete it in the official app.',
            'authorizationStateWaitOtherDeviceConfirmation' =>
              'Confirm this sign-in in your Telegram application.',
            _ => 'Connecting securely to Telegram…',
          }, style: TextStyle(color: _colors.onSurfaceVariant, height: 1.6)),
        if (_phoneError ?? td.error case final String error)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              error,
              style: TextStyle(color: _colors.error, fontSize: 12),
            ),
          ),
        if (td.credentialRecoveryRequired)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.login_rounded),
              label: const Text('Sign in again'),
              onPressed: td.busy
                  ? null
                  : () async {
                      final accepted = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Start a new Telegram sign-in?'),
                          content: Text(
                            'Your music and app settings stay. The unreadable local Telegram files will be set aside. ${td.hasApplicationCredentials ? 'You will need Telegram verification to sign in again.' : 'You will need your API details and Telegram verification to sign in again.'} To keep the old sign-in, restore a password-protected account backup instead.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('Sign in again'),
                            ),
                          ],
                        ),
                      );
                      if (accepted == true) {
                        await td.recoverLocalSession();
                        if (mounted && td.error == null) {
                          apiId.clear();
                          apiHash.clear();
                        }
                      }
                    },
            ),
          ),
        const SizedBox(height: 18),
        if (initial || label != null)
          FilledButton(
            onPressed: td.busy ? null : submit,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: td.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      initial
                          ? 'Connect Telegram'
                          : _editingNumber
                          ? 'Send new code'
                          : 'Continue',
                    ),
            ),
          ),
      ],
    );
  }
}

/// Telegram images, tiny previews and embedded covers with a visible fallback.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.seed,
    this.small = false,
    this.telegram,
    this.fileId,
    this.track,
    this.preview,
  });
  final String seed;
  final bool small;
  final TelegramService? telegram;
  final int? fileId;
  final Track? track;
  final Uint8List? preview;

  @override
  Widget build(BuildContext context) {
    final placeholder = Tooltip(
      message: track == null ? 'Artwork unavailable' : 'No cover available yet',
      child: CustomPaint(
        painter: _RecordPainter(seed),
        child: const SizedBox.expand(),
      ),
    );
    Widget image(ImageProvider provider, Widget fallback) => Image(
      image: ResizeImage(provider, width: small ? 96 : 640),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (context, error, stack) => fallback,
      frameBuilder: (context, child, frame, synchronous) =>
          frame == null ? fallback : child,
    );
    final mini = track?.coverPreview ?? preview;
    final fallback = mini == null
        ? placeholder
        : image(MemoryImage(mini), placeholder);
    Widget child = fallback;
    if (telegram != null && track != null) {
      child = FutureBuilder<Uint8List?>(
        key: ValueKey((track!.fileId, track!.coverFileId)),
        future: telegram!.cover(track!),
        initialData: telegram!.cachedCover(track!),
        builder: (context, snapshot) => snapshot.data != null
            ? image(MemoryImage(snapshot.data!), fallback)
            : fallback,
      );
    } else if (telegram != null && fileId != null) {
      child = FutureBuilder<String?>(
        key: ValueKey(fileId),
        future: telegram!.image(fileId!),
        builder: (context, snapshot) =>
            snapshot.connectionState == ConnectionState.done &&
                snapshot.data != null
            ? image(FileImage(File(snapshot.data!)), fallback)
            : fallback,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(small ? 12 : 30),
      child: child,
    );
  }
}

class _RecordPainter extends CustomPainter {
  _RecordPainter(this.seed);
  final String seed;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = 240.0 + seed.codeUnits.fold(0, (a, b) => a + b) % 80;
    final dark = HSLColor.fromAHSL(1, hue, .25, .2).toColor(),
        light = HSLColor.fromAHSL(1, hue, .5, .72).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [light, dark],
        ).createShader(rect),
    );
    final center = Offset(size.width * .62, size.height * .57);
    for (var i = 1; i < 11; i++) {
      canvas.drawCircle(
        center,
        size.width * (.08 + i * .034),
        Paint()
          ..color = Colors.black.withValues(alpha: .13)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * .012,
      );
    }
    canvas.drawCircle(
      center,
      size.width * .085,
      Paint()..color = const Color(0xFFDAD0E9),
    );
    canvas.drawCircle(center, size.width * .018, Paint()..color = dark);
    final path = Path()
      ..moveTo(0, size.height * .7)
      ..cubicTo(
        size.width * .2,
        size.height * .3,
        size.width * .3,
        size.height * .9,
        size.width,
        size.height * .2,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: .12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * .11,
    );
  }

  @override
  bool shouldRepaint(_RecordPainter oldDelegate) => seed != oldDelegate.seed;
}
