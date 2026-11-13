import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import 'app_popups.dart';

import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'media_item_sheet.dart';
import 'music_playlist_widgets.dart';
import 'playlist_photos.dart';
import 'library_widgets.dart';
import 'lyrics.dart';
import 'lyrics_view.dart';
import 'player.dart';
import 'telegram/telegram_service.dart';
import 'telegram/phone_login.dart';
import 'telegram/channel_library.dart';
import 'telegram_video_view.dart';
import 'video_files.dart';
import 'video_playback_data.dart';
import 'video_settings.dart';
import 'updater.dart';
import 'update_widgets.dart';
import 'wave_seek_bar.dart';
import 'now_playing_effects.dart';
import 'player_origin_snapshot.dart';
import 'data_files.dart';
import 'stats_view.dart';
import 'listening.dart';
import 'sync/controller.dart';
import 'sync/settings_view.dart';
import 'release_notes.dart';
import 'app_navigation.dart';
import 'app_theme.dart';
import 'app_motion.dart';
import 'setup_view.dart';
import 'settings_view.dart';
import 'preference_widgets.dart';

import 'discovery_widgets.dart';

part 'discovery_view.dart';

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
    final cached = track == null ? null : widget.telegram.cachedCover(track);
    unawaited(_loadPalette(cached ?? track?.coverPreview, cover, generation));
  }

  Future<ColorScheme?> _extract(Uint8List bytes) async {
    try {
      return await ColorScheme.fromImageProvider(
        provider: ResizeImage(MemoryImage(bytes), width: 96),
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
      final full = await cover;
      if (!identical(preview, full)) {
        hasPalette = await apply(full) || hasPalette;
      }
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
    theme: auralisTheme(_scheme),
    scrollBehavior: const AuralisScrollBehavior(),
    builder: (context, child) => ListenableBuilder(
      listenable: widget.player,
      builder: (_, _) => AuralisMotion(
        disabled: widget.player.settings.reducedMotion,
        child: child!,
      ),
    ),
    home: _settingUp
        ? SetupView(
            player: widget.player,
            telegram: widget.telegram,
            version: widget.installedVersion ?? currentReleaseVersion,
            sync: widget.sync,
            files: widget.dataFiles,
            connectBuilder: (_) => PlayerShell(
              player: widget.player,
              telegram: widget.telegram,
              setupMode: true,
            ),
            onFinished: () => setState(() => _settingUp = false),
          )
        : PlayerShell(
            startOnHome: true,
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

enum _Page { home, browse, library, telegram, nowPlaying, settings }

const _mainPages = [_Page.home, _Page.browse, _Page.library];

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
    this.startOnHome = false,
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final SyncController? sync;
  final String? installedVersion;
  final AppUpdater? updater;
  final DataFiles dataFiles;
  final bool setupMode, startOnHome;
  @override
  State<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends State<PlayerShell>
    with SingleTickerProviderStateMixin {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  _Page get _rootPage => widget.startOnHome ? _Page.home : _Page.library;
  late _Page destination = _rootPage;
  late _Page _primaryPage = _rootPage;
  bool _browseAsList = false, _artistsAsList = false, _mixExpanded = false;
  late bool _videoMode;
  List<VideoSource>? _incomingVideos;
  void _toggleMixExpanded() => setState(() => _mixExpanded = !_mixExpanded);
  void _toggleBrowseLayout() => setState(() => _browseAsList = !_browseAsList);
  void _openRecent() {
    _navigate(_Page.library);
    _selectLibraryCollection('Recently played');
  }

  void _openMusicChannels() => _navigate(_Page.browse);

  void _selectArtist(String? artist) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selectedArtist = artist;
      search.clear();
    });
  }

  _Page _playerOrigin = _Page.library;
  bool showLyrics = false;
  String collection = 'All songs';
  String? selectedPlaylist, _selectedArtist;
  late final LyricsRepository lyrics;
  int _cacheGeneration = 0, _cachedTracks = 0, _cacheTotal = 0;
  bool _cachingLibrary = false;
  ({
    String summary,
    (String?, String) scope,
    List<({Track track, String details})> issues,
  })?
  _cacheReport;
  final search = TextEditingController();
  final _discoveryFocus = FocusNode();
  SettingsSection? _settingsSection;
  late final ChannelLibrary library;
  late final Listenable _shellUpdates;
  late final AnimationController _dismissPlayer;
  late final _playerHeaderOpacity = ReverseAnimation(_dismissPlayer).drive(
    CurveTween(curve: const Interval(.32, .83)),
  );
  final _dockKey = GlobalKey();
  final _surfaceKey = GlobalKey();
  static const _miniPlayerRadius = 24.0;
  Rect? _dockBounds;
  Size? _dockViewport;
  double _playerTravel = 1;
  bool _draggingPlayerSurface = false;
  bool _closingPlayer = false;
  Timer? _volumeTimer;
  bool _showVolume = false;
  List<Track> _artworkWindow = const [];
  Object? _artworkContext, _lyricRequest;
  Track? _metadataTrack;
  bool _metadataPlaybackStarted = false;
  int _artworkGeneration = 0, _lyricGeneration = 0;
  PlayerController get player => widget.player;
  TelegramService get telegram => widget.telegram;
  @override
  void initState() {
    super.initState();
    _videoMode =
        widget.startOnHome &&
        player.settings.defaultInterface == AppInterface.video;
    if (Platform.isAndroid && widget.startOnHome) {
      videoIntentChannel.setMethodCallHandler((call) async {
        if (call.method == 'incomingVideos') await _takeIncomingVideos();
      });
      unawaited(_takeIncomingVideos());
    }
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
    final scope = telegram.mediaCache.directory?.path;
    final track = player.current;
    if (!identical(track, _metadataTrack)) {
      _metadataTrack = track;
      _metadataPlaybackStarted = false;
    }
    _metadataPlaybackStarted =
        _metadataPlaybackStarted || player.loading || player.audio.playing;
    final source = player.queue;
    final start = math.max(0, player.index);
    final count = track == null ? 0 : math.min(source.length, 11);
    final window = <Track>[
      if (count > 0) source[start],
      if (count > 1 && (start + 1 < source.length || player.repeat))
        source[(start + 1) % source.length],
      if (count > 0 && start > 0 && (!player.repeat || source.length > count))
        source[start - 1],
      for (var offset = 2; offset < count; offset++)
        if (start + offset < source.length || player.repeat)
          source[(start + offset) % source.length],
    ];
    final view = View.maybeOf(context);
    final devicePixelRatio = view?.devicePixelRatio ?? 1;
    final artworkKey = (telegram.ready, scope, devicePixelRatio);
    if (artworkKey != _artworkContext || !listEquals(window, _artworkWindow)) {
      _artworkContext = artworkKey;
      _artworkWindow = window;
      final generation = ++_artworkGeneration;
      bool active() =>
          mounted &&
          generation == _artworkGeneration &&
          telegram.ready &&
          scope == telegram.mediaCache.directory?.path;
      if (active()) {
        unawaited(_warmArtwork(window, devicePixelRatio, active));
      }
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

  Future<void> _warmArtwork(
    List<Track> tracks,
    double devicePixelRatio,
    bool Function() active,
  ) async {
    for (var index = 0; index < tracks.length; index++) {
      if (!active()) return;
      final track = tracks[index];
      final bytes =
          telegram.cachedCover(track) ??
          await telegram.savedCover(track, active: active);
      if (!mounted || !active()) return;
      if (bytes == null) continue;
      final neighboring =
          index < 2 ||
          (player.index > 0 &&
              identical(track, player.queue[player.index - 1]));
      final widths = {
        96,
        640,
        if (neighboring) ...[
          _playerDecodeWidth(380, devicePixelRatio),
          _playerDecodeWidth(410, devicePixelRatio),
        ],
      };
      for (final width in widths) {
        if (!mounted || !active()) return;
        final image = ResizeImage(MemoryImage(bytes), width: width);
        if (PaintingBinding.instance.imageCache.containsKey(
          await image.obtainKey(ImageConfiguration.empty),
        )) {
          continue;
        }
        if (!mounted || !active()) return;
        await precacheImage(image, context, onError: (_, _) {});
      }
    }
  }

  bool get _keyboardOpen => MediaQuery.viewInsetsOf(context).bottom > 0;

  double get _dockPadding {
    if (_keyboardOpen) return 16;
    final size = MediaQuery.sizeOf(context);
    final navigation =
        !widget.setupMode &&
            size.width < 900 &&
            player.settings.navigationStyle != AppNavigationStyle.fullWidth
        ? 80 + MediaQuery.paddingOf(context).bottom
        : 0;
    if (player.current == null) return navigation + 16;
    final width =
        size.width -
        (size.width >= 1180
            ? 202
            : size.width >= 900
            ? 72
            : 0);
    return navigation +
        (width >= 600 ? 92 : 108) +
        math.max(0, MediaQuery.textScalerOf(context).scale(1) - 1) * 40;
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
    final reduced = _reducedPlayerMotion;
    if (page != _Page.nowPlaying) {
      // Cancel a pending close before another page (or a new open) takes over.
      _draggingPlayerSurface = false;
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
      } else if (draggingDock) {
        _dismissPlayer.value = 1;
      } else {
        if (destination != page) _dismissPlayer.value = 1;
        unawaited(_movePlayer(0));
      }
    }
    if (page == _Page.settings) {
      _settingsSection = null;
    }
    if (page != destination && page != _Page.nowPlaying) {
      FocusManager.instance.primaryFocus?.unfocus();
      search.clear();
    }
    setState(() {
      if (_mainPages.contains(page)) _primaryPage = page;
      destination = page;
      _closingPlayer = false;
      showLyrics = openLyrics;
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
    } else if (destination == _Page.library && _selectedArtist != null) {
      _selectArtist(null);
    } else if (destination == _Page.settings || destination == _Page.telegram) {
      _navigate(_primaryPage);
    } else if (destination != _rootPage) {
      _navigate(_rootPage);
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid && widget.startOnHome) {
      videoIntentChannel.setMethodCallHandler(null);
    }
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
    _discoveryFocus.dispose();
    super.dispose();
  }

  Future<void> _closeNowPlaying({double? velocity}) async {
    if (_closingPlayer || destination != _Page.nowPlaying) return;
    final reduced = _reducedPlayerMotion;
    setState(() => _closingPlayer = true);
    _draggingPlayerSurface = false;
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
    final body = AnimatedSwitcher(
      layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
      duration: Duration(
        milliseconds: page == _Page.nowPlaying || _reducedPlayerMotion
            ? 0
            : 180,
      ),
      child: KeyedSubtree(
        key: ValueKey((page, immersiveLyrics)),
        child: switch (page) {
          _Page.home => _home(),
          _Page.browse => _discover(),
          _Page.library => _library(),
          _Page.telegram => _telegramSignIn(),
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
    );
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
          if (!immersiveLyrics &&
              page != _Page.home &&
              page != _Page.browse &&
              page != _Page.library) ...[
            if (page == _Page.nowPlaying)
              FadeTransition(
                opacity: _playerHeaderOpacity,
                child: _header(narrow, short: short, page: page),
              )
            else
              _header(narrow, short: short, page: page),
            SizedBox(height: short ? 10 : 22),
          ],
          if (widget.startupWarning != null) _banner(widget.startupWarning!),
          if (player.error ?? player.audio.error case final String error)
            _banner(error),
          Expanded(
            child: page == _Page.nowPlaying
                ? _fadePlayerBody(
                    body,
                    key: const ValueKey('now-playing-content-opacity'),
                  )
                : body,
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
      final compact = viewport.width < 900 && !_keyboardOpen;
      final floatingNavigation =
          compact &&
          player.settings.navigationStyle != AppNavigationStyle.fullWidth;
      final narrow = viewport.width < 1180;
      final short = viewport.height < 560;
      return Stack(
        key: const ValueKey('floating-player-layer'),
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              Expanded(
                child: _pageContent(page, narrow: narrow, short: short),
              ),
              if (compact && !floatingNavigation)
                _bottomNavigation(page: page, transitionCopy: transitionCopy),
            ],
          ),
          if (floatingNavigation)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _bottomNavigation(
                page: page,
                transitionCopy: transitionCopy,
              ),
            ),
          if (!transitionCopy && !_keyboardOpen && player.current != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: compact ? 80 + MediaQuery.paddingOf(context).bottom : 0,
              child: Opacity(
                opacity: destination == _Page.nowPlaying ? 0 : 1,
                child: _transport(),
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

  Widget _fadePlayerBody(Widget body, {Key? key}) => AnimatedBuilder(
    animation: _dismissPlayer,
    child: body,
    builder: (context, child) {
      final opacity = const Interval(.28, .90).transform(
        1 - _dismissPlayer.value,
      );
      return IgnorePointer(
        ignoring: opacity == 0,
        child: Opacity(key: key, opacity: opacity, child: child),
      );
    },
  );

  void _settlePlayer(DragEndDetails details) {
    _draggingPlayerSurface = false;
    final speed = details.primaryVelocity ?? 0;
    final closing = speed.abs() > 500 ? speed > 0 : _dismissPlayer.value > .18;
    if (closing) {
      unawaited(_closeNowPlaying(velocity: speed / _playerTravel));
    } else if (_reducedPlayerMotion) {
      _dismissPlayer.reset();
    } else {
      unawaited(_movePlayer(0, velocity: speed / _playerTravel));
    }
  }

  void _settleDock(DragEndDetails details) {
    if (_reducedPlayerMotion) return;
    final speed = details.primaryVelocity ?? 0;
    final opening = speed.abs() > 500 ? speed < 0 : _dismissPlayer.value < .82;
    if (opening) {
      unawaited(_movePlayer(0, velocity: speed / _playerTravel));
    } else {
      unawaited(_closeNowPlaying(velocity: speed / _playerTravel));
    }
  }

  Widget _playerSurface({required Widget child}) => LayoutBuilder(
    key: _surfaceKey,
    builder: (context, box) {
      final expanded = destination == _Page.nowPlaying;
      final track = player.current;
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
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onVerticalDragStart: showLyrics || _closingPlayer
                    ? null
                    : (_) {
                        _draggingPlayerSurface = true;
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
                        if (!_draggingPlayerSurface) return;
                        _draggingPlayerSurface = false;
                        if (_reducedPlayerMotion) {
                          _dismissPlayer.reset();
                        } else {
                          unawaited(_movePlayer(0));
                        }
                      },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _fadePlayerBody(
                      ColoredBox(
                        color: _colors.surfaceContainerLow,
                        child: NowPlayingBackdrop(
                          key: const ValueKey('now-playing-backdrop'),
                          identity: (
                            track?.id,
                            track?.fileId,
                            track?.coverFileId,
                            track?.coverPreview,
                            track?.title,
                            track?.size,
                            track == null ? null : telegram.cachedCover(track),
                          ),
                          reducedMotion: player.settings.reducedMotion,
                          artwork: Artwork(
                            seed: track?.title ?? 'Auralis',
                            telegram: telegram,
                            track: track,
                            small: true,
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
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
      final dockPreview = expanded && track != null
          ? TickerMode(
              enabled: false,
              child: ExcludeSemantics(
                child: IgnorePointer(child: _dockContent(transitionCopy: true)),
              ),
            )
          : null;
      return AnimatedBuilder(
        animation: _dismissPlayer,
        child: RepaintBoundary(
          key: const ValueKey('player-origin-page'),
          child: PlayerOriginSnapshot(
            enabled: expanded && !_reducedPlayerMotion,
            dismissal: _dismissPlayer,
            child: child,
          ),
        ),
        builder: (context, origin) {
          final progress = 1 - _dismissPlayer.value;
          // Geometry follows the controller directly, including during a drag.
          // The release simulation supplies the easing exactly once.
          final bounds = Rect.lerp(mini, full, progress)!;
          final dockOpacity = 1 - const Interval(.12, .48).transform(progress);
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
                if (expanded)
                  Positioned.fromRect(
                    rect: bounds,
                    child: ClipRRect(
                      key: const ValueKey('now-playing-container'),
                      borderRadius: BorderRadius.circular(
                        _miniPlayerRadius * (1 - progress),
                      ),
                      child: ColoredBox(
                        color: _colors.primaryContainer,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            OverflowBox(
                              alignment: Alignment.topCenter,
                              minWidth: full.width,
                              maxWidth: full.width,
                              minHeight: full.height,
                              maxHeight: full.height,
                              child: IgnorePointer(
                                ignoring:
                                    _closingPlayer ||
                                    _dismissPlayer.isAnimating,
                                child: TickerMode(
                                  enabled: !transitioning,
                                  child: content!,
                                ),
                              ),
                            ),
                            if (dockPreview != null && dockOpacity > 0)
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: Opacity(
                                  key: const ValueKey('player-dock-preview'),
                                  opacity: dockOpacity,
                                  child: dockPreview,
                                ),
                              ),
                          ],
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

  (String?, String) get _libraryCacheScope => (
    telegram.mediaCache.directory?.path,
    player.settings.selectedChannels.map((channel) => channel.id).join(','),
  );

  Future<void> _refreshLibrary() async {
    final generation = ++_cacheGeneration;
    setState(() {
      _cachingLibrary = false;
      _cachedTracks = 0;
      _cacheReport = null;
    });
    telegram.clearImageCache();
    await library.refresh();
    if (!mounted || generation != _cacheGeneration || !telegram.ready) return;
    final tracks = List<Track>.of(library.tracks);
    final scope = _libraryCacheScope;
    bool active() =>
        mounted &&
        generation == _cacheGeneration &&
        telegram.ready &&
        _libraryCacheScope == scope &&
        !player.restoringData;
    var savedArtwork = 0, savedLyrics = 0;
    final pending = <({Track track, bool artwork, bool lyrics})>[];
    final issues = <({Track track, String details})>[];
    for (final track in tracks) {
      if (!active()) return;
      final artwork = !await telegram.hasCachedCover(track);
      if (!active()) return;
      final missingLyrics = !await lyrics.hasSavedLyrics(track);
      if (!active()) return;
      if (!artwork) savedArtwork++;
      if (!missingLyrics) savedLyrics++;
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
      final details = <String>[];
      if (work.artwork) {
        try {
          final cover = await telegram.cacheCover(track, active: active);
          if (!active()) break;
          if (await telegram.hasCachedCover(track)) {
            savedArtwork++;
          } else {
            details.add(
              cover == null ? 'Artwork unavailable' : 'Couldn’t save artwork',
            );
          }
        } catch (_) {
          details.add('Artwork lookup failed');
        }
      }
      if (!active()) break;
      if (work.lyrics) {
        var failure = 'No matching lyrics';
        try {
          if (!await lyrics.hasSavedLyrics(track) && active()) {
            var value = lyrics.cached(track);
            if (value == null) {
              try {
                value = await telegram.embeddedLyrics(track);
              } catch (_) {
                // An unreadable embedded tag must not block online fallbacks.
              }
              if (!active()) break;
              value = lyrics.cached(track) ?? value;
            }
            if (value != null) {
              await lyrics.save(track, value);
            } else {
              value = await lyrics.find(track);
            }
            if (value != null) failure = 'Couldn’t save lyrics';
          }
        } on FormatException {
          failure = 'Song name or artist needed for lyrics lookup';
        } catch (_) {
          failure = 'Lyrics lookup failed';
        }
        if (!active()) break;
        if (await lyrics.hasSavedLyrics(track)) {
          savedLyrics++;
        } else {
          details.add(failure);
        }
      }
      if (!active()) break;
      if (details.isNotEmpty) {
        issues.add((track: track, details: details.join(' · ')));
      }
      setState(() => _cachedTracks++);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (mounted && generation == _cacheGeneration) {
      setState(() {
        _cachingLibrary = false;
        if (active()) {
          _cacheReport = (
            summary:
                'Artwork $savedArtwork/${tracks.length} · Lyrics $savedLyrics/${tracks.length}',
            scope: scope,
            issues: issues,
          );
        }
      });
    }
  }

  Future<void> _stats({bool backup = false}) async {
    await player.flushListeningStats();
    if (!mounted) return;
    Widget buildStats(BuildContext context) => StatsDataDialog(
      player: player,
      telegram: telegram,
      files: widget.dataFiles,
      fullscreen: !backup,
      openBackupSection: backup,
      onRestored: () async {
        setState(() {
          selectedPlaylist = null;
          _selectedArtist = null;
          collection = 'All songs';
        });
        await library.refresh();
      },
    );
    if (backup) {
      await showAuralisDialog<void>(context: context, builder: buildStats);
    } else {
      await Navigator.of(context)
          .push<void>(MaterialPageRoute(builder: buildStats));
    }
  }

  Future<void> _openSetup() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => SetupView(
        player: player,
        telegram: telegram,
        version: widget.installedVersion ?? currentReleaseVersion,
        sync: widget.sync,
        files: widget.dataFiles,
        connectBuilder: (_) =>
            PlayerShell(player: player, telegram: telegram, setupMode: true),
        onFinished: () => Navigator.of(context).pop(),
      ),
    ),
  );

  void _openTelegram() => _navigate(_Page.telegram);

  void _focusDiscovery() {
    _navigate(_Page.browse);
    _discoveryFocus.requestFocus();
  }

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
        if (widget.setupMode || (_videoMode && destination == _Page.telegram)) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Connect Telegram'),
              actions: [
                TextButton(
                  onPressed: widget.setupMode
                      ? () => Navigator.of(context).pop()
                      : _back,
                  child: const Text('Done'),
                ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: _telegramSignIn(),
              ),
            ),
          );
        }
        if (_videoMode && destination == _Page.settings) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _back();
            },
            child: Scaffold(
              appBar: AppBar(
                leading: BackButton(onPressed: _back),
                title: Text(_settingsSection?.title ?? 'Settings'),
              ),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _settingsPage(),
                ),
              ),
            ),
          );
        }
        if (_videoMode &&
            destination != _Page.settings &&
            destination != _Page.telegram) {
          return TelegramVideoView(
            telegram: telegram,
            music: player,
            onMusic: _openVideos,
            onSettings: () => _navigate(_Page.settings),
            onConnect: () => _navigate(_Page.telegram),
            incoming: _incomingVideos,
            onIncomingConsumed: (sources) {
              if (identical(_incomingVideos, sources)) {
                setState(() => _incomingVideos = null);
              }
            },
          );
        }
        final immersiveLyrics = destination == _Page.nowPlaying && showLyrics;
        final compact = box.maxWidth < 900;
        final narrow = box.maxWidth < 1180;
        final short = box.maxHeight < 560;
        // Leave room for the two-line player header at larger text sizes.
        final updateTop =
            MediaQuery.paddingOf(context).top +
            (destination == _Page.nowPlaying
                ? 32 +
                      math.max(
                        48,
                        MediaQuery.textScalerOf(context).scale(16) * 3,
                      )
                : 12);
        return PopScope<Object?>(
          canPop:
              destination == _rootPage &&
              !(destination == _Page.library && _selectedArtist != null),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _back,
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  _focusDiscovery,
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
                // Paint the player through the top inset; content stays safe inside.
                body: SafeArea(
                  top: false,
                  bottom: !compact,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Row(
                        children: [
                          if (!compact && !immersiveLyrics)
                            SafeArea(
                              bottom: false,
                              child: _navigation(narrow, short: short),
                            ),
                          Expanded(
                            child: _playerSurface(
                              child: SafeArea(
                                bottom: false,
                                child: _originContent(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (widget.updater case final updater?)
                        Positioned(
                          top: updateTop,
                          left: 12,
                          right: 12,
                          child: UpdateBanner(
                            key: ObjectKey(updater),
                            updater: updater,
                          ),
                        ),
                      if (_showVolume)
                        Positioned(
                          top: MediaQuery.paddingOf(context).top + 12,
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

  Widget _bottomNavigation({required _Page page, bool transitionCopy = false}) {
    return AppNavigation(
      key: transitionCopy ? null : const ValueKey('app-navigation'),
      style: player.settings.navigationStyle,
      radius: player.settings.navigationRadius,
      reducedMotion: _reducedPlayerMotion,
      selected: _mainPages.indexOf(
        _mainPages.contains(page) ? page : _primaryPage,
      ),
      onSelected: (i) => _navigate(_mainPages[i]),
      onHomeHold: transitionCopy ? null : _openVideos,
    );
  }

  void _openVideos() => setState(() {
    _videoMode = !_videoMode;
    destination = _Page.home;
    _primaryPage = _Page.home;
  });

  Future<void> _takeIncomingVideos() async {
    try {
      final rows = await videoIntentChannel
          .invokeListMethod<Map<Object?, Object?>>('takeIncomingVideos');
      final sources = videosFromAndroid(rows);
      if (!mounted || sources.isEmpty) return;
      setState(() {
        _incomingVideos = sources;
        _videoMode = true;
        destination = _primaryPage = _Page.home;
      });
    } on PlatformException {
      // The sender can revoke access before the app reads its video.
    } on MissingPluginException {
      // No external Android video intents in this runtime.
    }
  }

  Widget _navigation(bool narrow, {bool short = false}) => AppSidebar(
    narrow: narrow,
    short: short,
    selected: _mainPages.indexOf(destination),
    onSelected: (i) => _navigate(_mainPages[i]),
    onHomeHold: _openVideos,
    onSettings: () => _navigate(_Page.settings),
    settingsSelected: destination == _Page.settings,
  );

  String get _backToPrimary =>
      'Back to ${AppNavigation.labels[_mainPages.indexOf(_primaryPage)]}';

  bool get _mobileNavigation => MediaQuery.sizeOf(context).width < 900;

  Widget _header(
    bool narrow, {
    bool short = false,
    _Page? page,
  }) => LayoutBuilder(
    builder: (context, box) {
      final destination = page ?? this.destination;
      if (destination == _Page.settings) {
        return Row(
          children: [
            IconButton.filledTonal(
              tooltip: _settingsSection == null
                  ? _backToPrimary
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
                  tooltip:
                      'Back to ${AppNavigation.labels[_mainPages.indexOf(_mainPages.contains(_playerOrigin) ? _playerOrigin : _primaryPage)]}',
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
              ],
            )
          : Row(
              children: [
                BackButton(onPressed: _back),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!short)
                        Text(
                          switch (destination) {
                            _Page.library => 'YOUR COLLECTION',
                            _Page.telegram => 'YOUR TELEGRAM ACCOUNT',
                            _Page.settings => 'MAKE IT YOURS',
                            _Page.nowPlaying => 'IN THE MOMENT',
                            _Page.home || _Page.browse => '',
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
                          _Page.telegram => 'Connect Telegram',
                          _Page.settings => 'Settings',
                          _Page.nowPlaying => 'Now playing',
                          _Page.home => 'Home',
                          _Page.browse => 'Browse',
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
                    ],
                  ),
                ),
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
  Widget _search(String hint, {bool discover = false}) => TextField(
    controller: search,
    focusNode: discover ? _discoveryFocus : null,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: hint,
      enabledBorder: discover ? auralisFieldBorder(radius: 28) : null,
      focusedBorder: discover
          ? auralisFieldBorder(
              radius: 28,
              side: BorderSide(color: _colors.primary),
            )
          : null,
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

  Future<String?> _editPlaylist({String? previous}) =>
      showAuralisDialog<String>(
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
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, saved);
                  }
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

              return AuralisDialog(
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
    final selected = await showAuralisDialog<String>(
      context: context,
      builder: (context) => AuralisDialog(
        title: const Text('Add to playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in player.settings.playlists.entries)
              AuralisChoiceTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(
                  entry.key,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${entry.value.length} tracks'),
                onTap: () => Navigator.pop(context, entry.key),
              ),
            if (player.settings.playlists.isEmpty)
              const Text('Create a playlist to save this track.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, ''),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create playlist'),
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
    final remove = await confirmAuralisAction(
      context,
      title: 'Delete playlist?',
      message:
          'Remove “$name” from this device? The music in Telegram is kept.',
      confirmLabel: 'Delete',
      destructive: true,
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

  Future<void> _sleepTimer() => showAuralisDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: player,
      builder: (context, _) => AuralisDialog(
        title: const Text('Sleep timer'),
        content: Column(
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
        actions: [
          if (player.sleepActive)
            TextButton(
              onPressed: () {
                player.cancelSleepTimer();
                Navigator.pop(context);
              },
              child: const Text('Cancel timer'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );

  Widget _trackActions(Track track, {VoidCallback? onPlay}) => IconButton.filledTonal(
    tooltip: 'Track actions for ${track.title}',
    icon: const Icon(Icons.more_vert_rounded, size: 22),
    style: IconButton.styleFrom(backgroundColor: _colors.surfaceContainerHigh,
        foregroundColor: _colors.onSurface),
    onPressed: () async {
      final playlist = destination == _Page.library && collection == 'Playlists' ? selectedPlaylist : null;
      final favorite = player.settings.favoriteIds.contains(track.id);
      final value = await showMediaItemSheet(
        context: context,
        title: track.title,
        subtitle: [track.artist, track.source].where((text) => text.isNotEmpty).join(' · '),
        artwork: Artwork(seed: track.title, telegram: telegram, track: track, small: true),
        details: mediaItemDetails(track, video: false),
        actions: [
          const MediaItemAction('play', 'Play', Icons.play_arrow_rounded, primary: true),
          MediaItemAction('favorite', favorite ? 'Remove from favorites' : 'Add to favorites',
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded, selected: favorite),
          const MediaItemAction('queue', 'Add to queue', Icons.queue_music_rounded),
          const MediaItemAction('next', 'Play next', Icons.playlist_play_rounded),
          const MediaItemAction('playlist', 'Add to playlist', Icons.playlist_add_rounded),
          if (playlist != null)
            const MediaItemAction('remove', 'Remove from playlist', Icons.remove_circle_outline_rounded, destructive: true),
        ],
      );
      if (!mounted || value == null) return;
      try {
        switch (value) {
          case 'play':
            if (onPlay != null) { onPlay(); } else { await player.play(track); }
          case 'favorite':
            await player.toggleFavorite(track);
          case 'queue':
            player.enqueue(track);
            _notice('Added to queue');
          case 'next':
            player.playNext(track);
            _notice('Playing next');
          case 'playlist':
            await _choosePlaylist(track);
          case 'remove':
            if (playlist != null) await player.removeFromPlaylist(playlist, track);
        }
      } on StateError catch (e) {
        _notice(e.message);
      }
    },
  );

  List<Track> _collectionTracks([String? scope]) {
    final selectedCollection = scope ?? collection;
    final tracks = library.tracks;
    final artist = selectedCollection == 'Artists' && selectedCollection == collection
        ? _selectedArtist?.toLowerCase() : null;
    if (artist != null) {
      return tracks
          .where((track) => _artistName(track).toLowerCase() == artist)
          .toList();
    }
    if (selectedCollection == 'Favorites') {
      return tracks
          .where((t) => player.settings.favoriteIds.contains(t.id))
          .toList();
    }
    final ids = selectedCollection == 'Recently played'
        ? player.settings.recentIds
        : selectedCollection == 'Playlists'
        ? player.settings.playlists[selectedCollection == collection ? selectedPlaylist : null] ?? <String>[]
        : null;
    return ids == null ? tracks : _tracksForIds(ids);
  }

  List<Track> _tracksForIds(Iterable<String> ids) {
    final byId = {for (final track in library.tracks) track.id: track};
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
    final byId = {for (final track in library.tracks) track.id: track};
    return MusicPlaylistsView(
      playlists: [
        for (final entry in entries)
          MusicPlaylistPreview(
            name: entry.key,
            songCount: entry.value.length,
            photo: player.settings.playlistPhotos.photo(
                'music', player.settings.musicPhotoScope, entry.key),
            tracks: [
              for (final id in entry.value)
                if (byId[id] case final Track track) track,
            ],
          ),
      ],
      searching: search.text.isNotEmpty,
      bottomPadding: _dockPadding,
      actionsBuilder: (playlist) => PlaylistCardMenu(
        name: playlist.name, hasPhoto: playlist.photo != null,
        onChangePhoto: () => _changeMusicPlaylistPhoto(playlist.name, reset: false),
        onResetPhoto: () => _changeMusicPlaylistPhoto(playlist.name, reset: true),
        onRename: () async {
          final name = await _editPlaylist(previous: playlist.name);
          if (mounted && name != null) {
            setState(() {
              if (selectedPlaylist == playlist.name) selectedPlaylist = name;
            });
          }
        },
        onRemove: () => _deletePlaylist(playlist.name),
      ),
      artwork: (track) => Artwork(
        seed: track.title,
        small: true,
        telegram: telegram,
        track: track,
      ),
      onCreate: () async {
        final name = await _editPlaylist();
        if (mounted && name != null) {
          setState(() {
            selectedPlaylist = name;
            search.clear();
          });
        }
      },
      onOpen: (name) => setState(() {
        selectedPlaylist = name;
        search.clear();
      }),
    );
  }

  Future<void> _changeMusicPlaylistPhoto(String name, {required bool reset}) async {
    final settings = player.settings;
    final scope = settings.musicPhotoScope;
    final list = settings.playlists[name];
    if (list == null) return;
    await editPlaylistPhoto(context: context, photos: settings.playlistPhotos,
      mode: 'music', scope: scope, name: name, reset: reset,
      valid: () => settings.musicPhotoScope == scope &&
          identical(settings.playlists[name], list),
      save: settings.save,
      refresh: () { if (mounted) setState(() {}); });
  }

  Widget _libraryCacheStatus() {
    final report = _cacheReport;
    final summary = telegram.ready && report?.scope == _libraryCacheScope
        ? report?.summary
        : null;
    final label = _cachingLibrary
        ? 'Caching $_cachedTracks / $_cacheTotal'
        : summary;
    if (label == null) return const SizedBox.shrink();
    final text = Text(
      label,
      key: const ValueKey('browse-cache-status'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: summary == null ? _colors.onSurfaceVariant : _colors.primary,
        fontSize: 11,
      ),
    );
    if (report == null || summary == null) return text;
    final issues = report.issues;
    return InkWell(
      onTap: () => unawaited(
        showAuralisDialog<void>(
          context: context,
          builder: (context) => AuralisDialog(
            title: const Text('Library cache'),
            scrollable: issues.isEmpty,
            content: issues.isEmpty
                ? Text(
                    '$summary\nAll artwork and lyrics are saved on this device.',
                  )
                : SizedBox(
                    width: 380,
                    height: math.min(
                      360.0,
                      MediaQuery.sizeOf(context).height * 0.45,
                    ),
                    child: ListView.builder(
                      itemCount: issues.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Text(
                            '$summary\nUncached tracks from the last refresh',
                          );
                        }
                        final issue = issues[index - 1];
                        final artist = issue.track.artist.trim();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(issue.track.title),
                          subtitle: Text(
                            artist.isEmpty
                                ? issue.details
                                : '$artist\n${issue.details}',
                          ),
                        );
                      },
                    ),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: text),
          const SizedBox(width: 4),
          Icon(Icons.info_outline_rounded, color: _colors.primary, size: 13),
        ],
      ),
    );
  }

  static const _libraryCollections = [
    ('All songs', Icons.library_music_rounded),
    ('Artists', Icons.person_rounded),
    ('Favorites', Icons.favorite_rounded),
    ('Playlists', Icons.playlist_play_rounded),
    ('Recently played', Icons.history_rounded),
  ];

  void _selectLibraryCollection(String value) => setState(() {
    collection = value;
    selectedPlaylist = null;
    _selectedArtist = null;
    search.clear();
  });

  Widget _libraryCollectionMenu() {
    final collectionIcon = _libraryCollections
        .firstWhere((entry) => entry.$1 == collection)
        .$2;
    return LibraryCollectionMenu<int>(
      key: const ValueKey('library-collection-menu'),
      title: collection,
      titleKey: const ValueKey('page-title'),
      icon: collectionIcon,
      tooltip: 'Library collection: $collection',
      onSelected: (index) =>
          _selectLibraryCollection(_libraryCollections[index].$1),
      itemBuilder: (_) => [
        for (final (index, (label, icon)) in _libraryCollections.indexed)
          PopupMenuItem<int>(
            value: index,
            padding: EdgeInsets.zero,
            child: AuralisMenuRow(
              title: label,
              icon: icon,
              selected: collection == label,
            ),
          ),
      ],
    );
  }

  Widget _librarySortButton() => AuralisPopupMenu<LibrarySort>(
      tooltip: 'Sort Library',
      itemBuilder: (_) => [
        for (final sort in LibrarySort.values)
          PopupMenuItem<LibrarySort>(
            value: sort,
            padding: EdgeInsets.zero,
            child: AuralisMenuRow(
              title: sort.label,
              selected: player.settings.librarySort == sort,
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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Ink(
          width: 48,
          height: 40,
          decoration: BoxDecoration(
            color: _colors.secondaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.sort_rounded,
            color: _colors.onSecondaryContainer,
            size: 20,
          ),
        ),
      ),
    );

  Widget _library() {
    final playlistOverview =
        collection == 'Playlists' && selectedPlaylist == null;
    final artist = _selectedArtist;
    final artistOverview = collection == 'Artists' && artist == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_keyboardOpen) ...[
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _libraryCollectionMenu(),
                ),
              ),
              if (artistOverview)
                discoveryLayoutButton(
                  list: _artistsAsList,
                  onPressed: () =>
                      setState(() => _artistsAsList = !_artistsAsList),
                )
              else
                _librarySortButton(),
              if (_mobileNavigation) const SizedBox(width: 4),
              if (_mobileNavigation)
                IconButton.filledTonal(
                  tooltip: 'Settings',
                  style: IconButton.styleFrom(
                    backgroundColor: _colors.primaryContainer,
                    foregroundColor: _colors.onPrimaryContainer,
                  ),
                  onPressed: () => _navigate(_Page.settings),
                  icon: const Icon(Icons.settings_outlined, size: 20),
              ),
            ],
          ),
          LibraryPageIndicator(
            key: const ValueKey('music-library-indicator'),
            labels: _libraryCollections.map((entry) => entry.$1).toList(),
            index: _libraryCollections.indexWhere((entry) => entry.$1 == collection),
            onSelected: (index) => _selectLibraryCollection(_libraryCollections[index].$1),
            reducedMotion: player.settings.reducedMotion,
          ),
        ],
        Expanded(
          child: Material(
            color: _colors.surfaceContainerLowest,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(26),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _search(
                    playlistOverview
                        ? 'Search playlists'
                        : artistOverview
                        ? 'Search your Artists'
                        : 'Search your music',
                  ),
                  if (artist != null)
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to artists',
                          onPressed: () => _selectArtist(null),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        Expanded(
                          child: Text(
                            artist,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ],
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
                        style: TextStyle(
                          color: _colors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Expanded(
                    child: LibraryCollectionPager(
                      key: const ValueKey('music-library-pager'),
                      index: _libraryCollections.indexWhere((entry) => entry.$1 == collection),
                      count: _libraryCollections.length,
                      reducedMotion: player.settings.reducedMotion,
                      onChanged: (index) => _selectLibraryCollection(_libraryCollections[index].$1),
                      itemBuilder: (_, index) => _libraryCollectionBody(_libraryCollections[index].$1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _libraryCollectionBody(String scope) {
    final tracks = _collectionTracks(scope);
    final active = scope == collection;
    if (scope == 'Playlists' && (!active || selectedPlaylist == null)) return _playlists();
    if (!telegram.ready) {
      return _empty(Icons.send_rounded, 'Connect Telegram for your music',
        bottomPadding: _dockPadding,
        'Sign in and choose channels to fill your Library.',
        action: FilledButton.tonalIcon(onPressed: _openTelegram,
          icon: const Icon(Icons.send_rounded), label: const Text('Connect Telegram')));
    }
    if (player.settings.selectedChannels.isEmpty) {
      return _empty(Icons.campaign_rounded, 'Choose your music channels',
        bottomPadding: _dockPadding,
        'Select channels in Browse. Their music appears here together.',
        action: FilledButton.tonalIcon(onPressed: _openMusicChannels,
          icon: const Icon(Icons.playlist_add_rounded), label: const Text('Choose channels')));
    }
    if (library.tracks.isEmpty) {
      return _empty(Icons.library_music_rounded,
        library.loading ? 'Finding your music' : 'No music loaded',
        library.loading ? 'Tracks appear here as your channels load.'
            : 'Refresh in Browse or choose different channels.');
    }
    if (scope == 'Artists' && (!active || _selectedArtist == null)) return _musicArtists(tracks);
    if (tracks.isEmpty && scope != 'All songs' && scope != 'Artists') {
      return _empty(Icons.music_note_rounded, 'No loaded tracks in this collection',
        'Add music using track actions. Saved entries appear when their Telegram channels are selected and loaded.');
    }
    return _trackList(_visibleTracks(tracks,
        preserveOrder: scope == 'Recently played' || scope == 'Playlists'),
        key: PageStorageKey(('music-collection', scope)));
  }

  List<Track> _visibleTracks(List<Track> tracks, {bool preserveOrder = false}) {
    final query = search.text.trim().toLowerCase();
    final visible = tracks
        .where(
          (t) => '${t.title} ${t.artist} ${t.source}'.toLowerCase().contains(
            query,
          ),
        )
        .toList();
    if (!preserveOrder) visible.sort(player.settings.librarySort.compare);
    return visible;
  }

  Widget _trackList(List<Track> visible, {Key? key}) {
    if (visible.isEmpty) {
      return _empty(
        Icons.search_off_rounded,
        'No tracks found',
        'Try another search or choose a different source.',
      );
    }
    return ListView.builder(
      key: key,
      padding: EdgeInsets.only(bottom: _dockPadding),
      itemCount: visible.length,
      itemBuilder: (context, i) => _trackTile(
        visible[i],
        onPlay: () => player.play(visible[i], from: visible),
      ),
    );
  }

  Widget _trackTile(
    Track track, {
    required VoidCallback onPlay,
  }) {
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
          trailing: _trackActions(track, onPlay: onPlay),
        ),
      ),
    );
  }

  Widget _telegramSignIn() => !telegram.ready
      ? _signIn()
      : _empty(
          Icons.check_circle_outline_rounded,
          'Telegram connected',
          'Your account is ready to use.',
          action: widget.setupMode || _videoMode
              ? null
              : TextButton(
                  onPressed: _openMusicChannels,
                  child: const Text('Choose channels'),
                ),
        );

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

  static int _playerDecodeWidth(double logicalWidth, double pixelRatio) {
    final pixels = logicalWidth * pixelRatio * 1.025;
    return pixels <= 640
        ? 640
        : pixels <= 1024
        ? 1024
        : 1280;
  }

  Widget _playerCover(
    Track? track, {
    Key? key,
    Key? artworkKey,
    required double radius,
    int? decodeWidth,
    double inset = 5,
    Widget? artwork,
  }) => RepaintBoundary(
    key: key,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: _colors.surfaceContainer,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: _colors.primary.withValues(alpha: .14)),
      ),
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(math.max(0, radius - inset)),
          child:
              artwork ??
              Artwork(
                key: artworkKey,
                seed: track?.title ?? 'Auralis',
                telegram: telegram,
                track: track,
                decodeWidth: decodeWidth,
              ),
        ),
      ),
    ),
  );

  Widget _nowPlaying() {
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
        key: const ValueKey('now-playing-layout'),
        builder: (context, box) {
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
              ? 3.0
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
            bool selected = false,
            Key? key,
          }) => IconButton(
            key: key,
            tooltip: tooltip,
            isSelected: selected,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: selected
                  ? _colors.primary.withValues(alpha: .12)
                  : Colors.transparent,
              foregroundColor: selected
                  ? _colors.primary
                  : _colors.onSurfaceVariant,
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
              final radius = tight ? 26.0 : 34.0;
              final decodeWidth = _playerDecodeWidth(
                size,
                MediaQuery.devicePixelRatioOf(context),
              );
              Widget cover(Track? item, {Key? key}) => _playerCover(
                item,
                key: key,
                radius: radius,
                decodeWidth: decodeWidth,
              );
              return Center(
                child: SizedBox.square(
                  key: const ValueKey('now-playing-artwork-frame'),
                  dimension: size,
                  child: ArtworkMotion(
                    key: const ValueKey('now-playing-artwork'),
                    reducedMotion: player.settings.reducedMotion,
                    child: track == null
                        ? cover(null)
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
                                      player.playAt(
                                        index % player.queue.length,
                                      ),
                                    ),
                              itemBuilder: (context, index) => cover(
                                player.queue[index % player.queue.length],
                                key: ValueKey((
                                  'artwork-page',
                                  player
                                      .queue[index % player.queue.length]
                                      .id,
                                  index,
                                )),
                              ),
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
                                  _trackActions(player.queue[nextIndex]),
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
    double bottomPadding = 0,
  }) => Center(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(0, 22, 0, 22 + bottomPadding),
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

  Widget _transport() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: PlayerDockMotion(
      key: _dockKey,
      reducedMotion: _reducedPlayerMotion,
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
        key: const ValueKey('player-bar'),
        color: _colors.primaryContainer,
        elevation: 4,
        shadowColor: _colors.shadow.withValues(alpha: .38),
        borderRadius: BorderRadius.circular(_miniPlayerRadius),
        clipBehavior: Clip.antiAlias,
        child: _dockContent(),
      ),
    ),
  );

  Widget _dockContent({bool transitionCopy = false}) {
    final audio = player.audio;
    final track = player.current!;
    final duration = audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final colors = _colors;
    final titleColor = colors.onPrimaryContainer;
    final detailColor = titleColor.withValues(alpha: .80);
    final buttonSurface = Color.alphaBlend(
      colors.shadow.withValues(alpha: .25),
      colors.primaryContainer,
    );
    final waiting = player.loading || audio.buffering;

    Widget skip({
      required String label,
      required IconData icon,
      required VoidCallback onPressed,
    }) => IconButton.filledTonal(
      onPressed: onPressed,
      tooltip: label,
      style: IconButton.styleFrom(
        backgroundColor: buttonSurface,
        foregroundColor: titleColor,
      ),
      icon: Icon(icon),
    );

    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        skip(
          label: 'Previous track',
          icon: Icons.skip_previous_rounded,
          onPressed: player.previous,
        ),
        const SizedBox(width: 3),
        IconButton.filled(
          onPressed: player.loading ? null : audio.toggle,
          tooltip: audio.playing ? 'Pause' : 'Play',
          style: IconButton.styleFrom(
            backgroundColor: colors.primary,
            foregroundColor: colors.onPrimary,
          ),
          icon: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(
                audio.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              if (waiting)
                Positioned(
                  top: -5,
                  bottom: -5,
                  left: -5,
                  right: -5,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: player.loading ? titleColor : colors.onPrimary,
                    semanticsLabel: player.loading
                        ? 'Loading track'
                        : 'Buffering',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 3),
        skip(
          label: 'Next track',
          icon: Icons.skip_next_rounded,
          onPressed: player.next,
        ),
      ],
    );

    Widget timeline({required bool showTimes}) => Row(
      children: [
        if (showTimes)
          Text(
            clockText(audio.position),
            style: TextStyle(fontSize: 11, color: detailColor),
          ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: titleColor,
              inactiveTrackColor: titleColor.withValues(alpha: .24),
              thumbColor: titleColor,
              overlayColor: titleColor.withValues(alpha: .12),
            ),
            child: SizedBox(
              height: showTimes ? 44 : 22,
              child: WaveSeekBar(
                value: progress,
                playing: audio.playing && !audio.buffering,
                reducedMotion: player.settings.reducedMotion,
                format: (value) => clockText(
                  Duration(milliseconds: (value * duration).round()),
                ),
                onChanged: duration <= 0
                    ? null
                    : (value) => player.seek(
                        Duration(milliseconds: (value * duration).round()),
                      ),
              ),
            ),
          ),
        ),
        if (showTimes)
          Text(
            clockText(audio.duration),
            style: TextStyle(fontSize: 11, color: detailColor),
          ),
      ],
    );

    final preview = Material(
      color: Colors.transparent,
      child: InkWell(
        key: transitionCopy ? null : const ValueKey('open-current-track'),
        borderRadius: BorderRadius.circular(22),
        onTap: () => _navigate(_Page.nowPlaying),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox.square(
                dimension: 44,
                child: Artwork(
                  seed: track.title,
                  small: true,
                  telegram: telegram,
                  track: track,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: detailColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        final inline = box.maxWidth >= 576;
        return Padding(
          padding: EdgeInsets.fromLTRB(10, 6, 10, inline ? 6 : 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (inline) ...[
                    SizedBox(
                      width: math.min(252, box.maxWidth * .30),
                      child: preview,
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: timeline(showTimes: true)),
                  ] else
                    Expanded(child: preview),
                  const SizedBox(width: 8),
                  controls,
                ],
              ),
              if (!inline) timeline(showTimes: false),
            ],
          ),
        );
      },
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
  }) => PreferenceChoice<T?>(
    title: title,
    value: value,
    values: [if (allowNone) null, ...values],
    label: (value) => value == null ? 'None' : label(value),
    onSelected: onChanged,
  );

  Widget _lyricPreferences() {
    final prefs = player.settings;
    return Column(
      key: const ValueKey('lyrics-preferences'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const ListTile(
          leading: PreferenceIcon(Icons.lyrics_rounded),
          title: Text('Lyrics & translation'),
        ),
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

  List<Widget> _settingsContent(SettingsSection section) => switch (section) {
    SettingsSection.general => [
      DefaultInterfacePreference(
        value: player.settings.defaultInterface,
        onSelected: (mode) =>
            _savePreferences(() => player.settings.defaultInterface = mode),
      ),
      TextButton.icon(
        onPressed: _openVideos,
        icon: Icon(_videoMode ? Icons.music_note_rounded : Icons.movie_rounded),
        label: Text(_videoMode ? 'Switch to Music' : 'Switch to Video'),
      ),
      PreferenceChoice<PlaybackRepeat>(
        title: 'Playback repeat',
        value: player.repeatMode,
        values: PlaybackRepeat.values,
        label: (mode) => switch (mode) {
          PlaybackRepeat.off => 'Off',
          PlaybackRepeat.all => 'Repeat queue',
          PlaybackRepeat.one => 'Repeat one track',
        },
        onSelected: (mode) =>
            _savePreferences(() => player.settings.repeatMode = mode),
      ),
      PreferenceChoice<LibrarySort>(
        key: ValueKey(_videoMode ? 'video-sort-preference' : 'music-sort-preference'),
        title: 'Library sort order',
        value: _videoMode
            ? player.settings.videoPlayback.librarySort
            : player.settings.librarySort,
        values: LibrarySort.values,
        label: (sort) => sort.label,
        onSelected: (sort) => _savePreferences(() {
          if (_videoMode) {
            player.settings.videoPlayback.librarySort = sort;
          } else {
            player.settings.librarySort = sort;
          }
        }),
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
    SettingsSection.media => [_lyricPreferences()],
    SettingsSection.video => [
      VideoSettingsOptions(settings: player.settings),
    ],
    SettingsSection.data => [
      ListTile(
        leading: const PreferenceIcon(Icons.bar_chart_rounded),
        title: const Text('Listening stats'),
        subtitle: const Text('Listening time & play counts'),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: () => _stats(),
      ),
      ListTile(
        leading: const PreferenceIcon(Icons.backup_outlined),
        title: const Text('Backup & Restore'),
        subtitle: const Text('Stats, collections and preferences'),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: () => _stats(backup: true),
      ),
      if (widget.sync != null) SyncSettings(controller: widget.sync!),
    ],
    SettingsSection.privacy => [
      const ListTile(
        leading: PreferenceIcon(Icons.shield_outlined),
        title: Text('Protected on this device'),
        subtitle: Text(
          'Telegram credentials are encrypted with Android Keystore or Windows DPAPI. Login codes and two-step verification passwords are never saved.',
        ),
      ),
      ListTile(
        leading: const PreferenceIcon(Icons.send_rounded),
        title: Text(telegram.ready ? 'Telegram connected' : 'Connect Telegram'),
        trailing: telegram.ready
            ? null
            : const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: telegram.ready ? null : _openTelegram,
      ),
      if (telegram.ready)
        ListTile(
          leading: const PreferenceIcon(Icons.logout_rounded),
          title: const Text('Sign out of Telegram'),
          textColor: _colors.error,
          onTap: telegram.busy
              ? null
              : () async {
                  await player.clear();
                  await telegram.logout();
                  if (telegram.ready && telegram.error != null) {
                    _notice(telegram.error!);
                  }
                  if (!telegram.ready) {
                    player.settings.selectedChannels = [];
                    player.settings.videoPlayback.clearTelegram(
                      keepActivity: widget.sync?.connected == true,
                    );
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
        ),
    ],
    SettingsSection.updates => [
      if (widget.updater != null)
        UpdateSettings(updater: widget.updater!, showHeading: false),
    ],
    SettingsSection.about => [
      ListTile(
        leading: const PreferenceIcon(Icons.graphic_eq_rounded),
        title: const Text('Auralis'),
        subtitle: Text(
          '${widget.updater?.currentVersion ?? currentReleaseVersion} · AGPL-3.0-or-later\nlibmpv · TDLib',
        ),
      ),
      ListTile(
        leading: const PreferenceIcon(Icons.new_releases_outlined),
        title: const Text('What’s new'),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: () => showInstalledChanges(
          context,
          widget.installedVersion ??
              widget.updater?.currentVersion ??
              currentReleaseVersion,
        ),
      ),
      ListTile(
        leading: const PreferenceIcon(Icons.auto_awesome_rounded),
        title: const Text('Set up Auralis'),
        subtitle: const Text('Reopen the setup wizard'),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: _openSetup,
      ),
      ListTile(
        leading: const PreferenceIcon(Icons.description_outlined),
        title: const Text('Licenses'),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
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
                sections: [
                  for (final section in SettingsSection.values)
                    if (switch (section) {
                      SettingsSection.updates => widget.updater != null,
                      SettingsSection.media => !_videoMode,
                      SettingsSection.video => _videoMode,
                      _ => true,
                    })
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
                  contentPadding: EdgeInsets.zero,
                  horizontalTitleGap: 12,
                  minTileHeight: 56,
                  titleTextStyle: Theme.of(context).textTheme.titleSmall!
                      .copyWith(
                        color: _colors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                  subtitleTextStyle: Theme.of(context).textTheme.bodySmall!
                      .copyWith(color: _colors.onSurfaceVariant),
                ),
                child: ListView(
                  key: PageStorageKey(
                    'settings-${_settingsSection!.name}-content',
                  ),
                  padding: EdgeInsets.only(bottom: _dockPadding),
                  children: [
                    for (final child in _settingsContent(_settingsSection!))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _settingsSection == SettingsSection.video
                            ? child : PreferenceCard(child: child),
                      ),
                  ],
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
                      final accepted = await confirmAuralisAction(
                        context,
                        title: 'Start a new Telegram sign-in?',
                        message:
                            'Your music and app settings stay. The unreadable local Telegram files will be set aside. ${td.hasApplicationCredentials ? 'You will need Telegram verification to sign in again.' : 'You will need your API details and Telegram verification to sign in again.'} To keep the old sign-in, restore a password-protected account backup instead.',
                        confirmLabel: 'Sign in again',
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
    this.decodeWidth,
    this.telegram,
    this.fileId,
    this.track,
    this.preview,
  });
  final String seed;
  final bool small;
  final int? decodeWidth;
  final TelegramService? telegram;
  final int? fileId;
  final Track? track;
  final Uint8List? preview;

  @override
  Widget build(BuildContext context) {
    final placeholder = Tooltip(
      message: 'Artwork not loaded yet',
      child: CustomPaint(
        painter: _RecordPainter(seed, Theme.of(context).colorScheme),
        child: const SizedBox.expand(),
      ),
    );
    Widget image(ImageProvider provider, Widget fallback) => Image(
      image: ResizeImage(provider, width: decodeWidth ?? (small ? 96 : 640)),
      gaplessPlayback: true,
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
        key: ValueKey((track!.id, track!.fileId, track!.coverFileId)),
        future: telegram!.cover(track!),
        initialData: telegram!.cachedCover(track!),
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? telegram!.cachedCover(track!);
          return bytes == null ? fallback : image(MemoryImage(bytes), fallback);
        },
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
  _RecordPainter(this.seed, this.colors);
  final String seed;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final dark = colors.surfaceContainerHighest;
    final light = seed.hashCode.isEven
        ? colors.primaryContainer
        : colors.tertiaryContainer;
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
          ..color = colors.shadow.withValues(alpha: .13)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * .012,
      );
    }
    canvas.drawCircle(
      center,
      size.width * .085,
      Paint()..color = colors.onPrimaryContainer,
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
        ..color = colors.onSurface.withValues(alpha: .12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * .11,
    );
  }

  @override
  bool shouldRepaint(_RecordPainter oldDelegate) =>
      seed != oldDelegate.seed || colors != oldDelegate.colors;
}
