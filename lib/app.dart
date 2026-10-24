import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'lyrics.dart';
import 'lyrics_view.dart';
import 'player.dart';
import 'telegram/telegram_service.dart';
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
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final SyncController? sync;
  final String? installedVersion;
  final AppUpdater? updater;
  final DataFiles dataFiles;
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

  @override
  void initState() {
    super.initState();
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
    if (!hasPalette && mounted && generation == _generation &&
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
      milliseconds: widget.player.settings.reducedMotion ||
          WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations
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
    home: PlayerShell(
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
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final SyncController? sync;
  final String? installedVersion;
  final AppUpdater? updater;
  final DataFiles dataFiles;
  @override
  State<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends State<PlayerShell>
    with SingleTickerProviderStateMixin {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  _Page destination = _Page.library;
  bool showLyrics = false;
  String collection = 'All songs';
  String? selectedPlaylist;
  final lyrics = LyricsRepository();
  final search = TextEditingController();
  late final ChannelLibrary library;
  late final Listenable _shellUpdates;
  late final AnimationController _dismissPlayer;
  late final Animation<Offset> _dismissOffset;
  bool _closingPlayer = false;
  PlayerController get player => widget.player;
  TelegramService get telegram => widget.telegram;
  @override
  void initState() {
    super.initState();
    _dismissPlayer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _dismissOffset = _dismissPlayer
        .drive(CurveTween(curve: Curves.easeInCubic))
        .drive(Tween<Offset>(begin: Offset.zero, end: const Offset(0, 1.05)));
    library = ChannelLibrary(telegram, player.settings);
    _shellUpdates = Listenable.merge([player, telegram, library]);
    search.addListener(_changed);
    _syncedChannels = player.settings.selectedChannels.map((c) => c.id).join(',');
    widget.sync?.addListener(_syncChanged);
    if (widget.installedVersion != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(maybeShowWhatsNew(context, player.settings, widget.installedVersion!));
      });
    }
  }

  String _syncedChannels = '';
  void _syncChanged() {
    final channels = player.settings.selectedChannels.map((c) => c.id).join(',');
    if (channels != _syncedChannels) {
      _syncedChannels = channels;
      if (telegram.ready && !player.restoringData) unawaited(library.refresh());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _navigate(_Page page) {
    setState(() {
      destination = page;
      showLyrics = false;
      search.clear();
    });
  }

  void _back() {
    if (destination == _Page.nowPlaying) {
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
    _dismissPlayer.dispose();
    lyrics.close();
    library.dispose();
    widget.sync?.removeListener(_syncChanged);
    search.dispose();
    super.dispose();
  }

  Future<void> _closeNowPlaying() async {
    if (_closingPlayer || destination != _Page.nowPlaying) return;
    final reduced =
        player.settings.reducedMotion ||
        MediaQuery.disableAnimationsOf(context);
    setState(() => _closingPlayer = true);
    if (!reduced) {
      try {
        await _dismissPlayer.forward(from: 0).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      // A sidebar navigation during dismissal takes precedence.
      if (destination == _Page.nowPlaying) {
        destination = _Page.library;
        showLyrics = false;
      }
      _closingPlayer = false;
      _dismissPlayer.reset();
    });
  }

  Widget _playerSurface({required Widget child}) => ClipRect(
    child: SlideTransition(
      key: const ValueKey('now-playing-dismiss'),
      position: destination == _Page.nowPlaying
          ? _dismissOffset
          : const AlwaysStoppedAnimation(Offset.zero),
      child: AbsorbPointer(
        absorbing: _closingPlayer && destination == _Page.nowPlaying,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (destination == _Page.nowPlaying)
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
            child,
          ],
        ),
      ),
    ),
  );

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
        final immersiveLyrics = destination == _Page.nowPlaying && showLyrics;
        final compact = box.maxWidth < 900;
        final narrow = box.maxWidth < 1180;
        final short = box.maxHeight < 560;
        final wide = box.maxWidth >= 1220 && box.maxHeight >= 620;
        return PopScope<Object?>(
          canPop: destination == _Page.library,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _back,
              const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
                  player.restoringData ? null : unawaited(player.audio.toggle()),
              const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
                  unawaited(player.next()),
              const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
                  unawaited(player.previous()),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: immersiveLyrics ? _colors.surface : null,
                bottomNavigationBar: compact && destination != _Page.nowPlaying
                    ? _bottomNavigation()
                    : null,
                body: SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            if (!compact && !immersiveLyrics)
                              _navigation(narrow, short: short),
                            Expanded(
                              child: _playerSurface(
                                child: Padding(
                                  padding: immersiveLyrics
                                      ? EdgeInsets.zero
                                      : EdgeInsets.fromLTRB(
                                          narrow ? 16 : 30,
                                          short ? 12 : 26,
                                          narrow ? 16 : 26,
                                          0,
                                        ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (!(destination == _Page.nowPlaying && showLyrics)) ...[
                                        _header(narrow, short: short),
                                        SizedBox(height: short ? 10 : 22),
                                      ],
                                      if (widget.updater != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 12,
                                          ),
                                          child: UpdateBanner(
                                            updater: widget.updater!,
                                          ),
                                        ),
                                      if (widget.startupWarning != null)
                                        _banner(widget.startupWarning!),
                                      if (player.error ?? player.audio.error
                                          case final String error)
                                        _banner(error),
                                      Expanded(
                                        child: AnimatedSwitcher(
                                          // The dock/nav reappear on exit. Fade in the
                                          // new page without squeezing an outgoing
                                          // full player into its smaller viewport.
                                          layoutBuilder: (current, _) =>
                                              current ?? const SizedBox.shrink(),
                                          duration: Duration(
                                            milliseconds:
                                                player.settings.reducedMotion ||
                                                    MediaQuery.disableAnimationsOf(
                                                      context,
                                                    )
                                                ? 0
                                                : 180,
                                          ),
                                          child: KeyedSubtree(
                                            key: ValueKey((
                                              destination,
                                              showLyrics,
                                            )),
                                            child: switch (destination) {
                                              _Page.library => _library(),
                                              _Page.telegram => _telegram(),
                                              _Page.settings => _settingsPage(),
                                              _Page.nowPlaying =>
                                                showLyrics
                                                    ? LyricsView(
                                                        backgroundColor:
                                                            Colors.transparent,
                                                        player: player,
                                                        repository: lyrics,
                                                        files: widget.dataFiles,
                                                        loadEmbedded: telegram
                                                            .embeddedLyrics,
                                                        artwork: Artwork(
                                                          seed:
                                                              player
                                                                  .current
                                                                  ?.title ??
                                                              'Auralis',
                                                          telegram: telegram,
                                                          track: player.current,
                                                        ),
                                                        onBack: () =>
                                                            setState(() {
                                                              showLyrics = false;
                                                            }),
                                                      )
                                                    : _nowPlaying(),
                                            },
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (wide &&
                                (destination == _Page.library ||
                                    destination == _Page.telegram))
                              Container(
                                width: (box.maxWidth * .23).clamp(280, 360),
                                margin: const EdgeInsets.fromLTRB(0, 20, 20, 20),
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
                      if (destination != _Page.nowPlaying && player.current != null)
                        _transport(box.maxWidth < 600, short: short),
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

  Widget _bottomNavigation() => NavigationBar(
    key: const ValueKey('app-navigation'),
    height: 80,
    backgroundColor: _colors.surfaceContainerLowest,
    selectedIndex: destination.index,
    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    onDestinationSelected: (i) => _navigate(_Page.values[i]),
    destinations: const [
      NavigationDestination(
        icon: Icon(Icons.library_music_rounded),
        label: 'Library',
        tooltip: 'Library',
      ),
      NavigationDestination(
        icon: Icon(Icons.send_rounded),
        label: 'Telegram',
        tooltip: 'Telegram',
      ),
      NavigationDestination(
        icon: Icon(Icons.album_rounded),
        label: 'Now playing',
        tooltip: 'Now playing',
      ),
      NavigationDestination(
        icon: Icon(Icons.tune_rounded),
        label: 'Settings',
        tooltip: 'Settings',
      ),
    ],
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
            style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 8, letterSpacing: 1.4),
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
                          color: destination == i ? _colors.primary : _colors.onSurfaceVariant,
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
                                color: destination == i ? _colors.primary : _colors.onSurfaceVariant,
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
              style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 10, height: 1.4),
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

  Widget _header(bool narrow, {bool short = false}) => LayoutBuilder(
    builder: (context, box) {
      final inlineCounts =
          box.maxWidth >= 560 &&
          MediaQuery.textScalerOf(context).scale(12) <= 16;
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
                            telegram.clearImageCache();
                            unawaited(library.refresh());
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
      message: label,
      child: Text(
        label,
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (track.duration > Duration.zero)
                Text(
                  clockText(track.duration),
                  style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
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
                      style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 12),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${channels.length} channels · ${telegram.connection}',
                          style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
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
                      style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _signIn() => SingleChildScrollView(
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
              style: TextStyle(color: _colors.onSurfaceVariant, height: 1.6, fontSize: 12),
            ),
            const SizedBox(height: 24),
            AuthForm(telegram: telegram),
            const SizedBox(height: 18),
            Text(
              'Credentials are encrypted on this device.\nLogin codes and passwords are never saved.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 10, height: 1.6),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  );

  Widget _artworkSwitcher({required Widget child}) => ArtworkTrackSwitcher(
    key: const ValueKey('artwork-track-switcher'),
    identity: (player.current?.id, player.index),
    reducedMotion: player.settings.reducedMotion,
    onNext: !player.restoringData && player.current != null &&
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
          style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 10, letterSpacing: 1.5),
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
                      key: const ValueKey('now-playing-artwork'),
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
          key: const ValueKey('now-playing-title'),
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
          key: const ValueKey('now-playing-actions'),
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: track == null
                    ? null
                    : () => setState(() {
                        destination = _Page.nowPlaying;
                        showLyrics = true;
                        search.clear();
                      }),
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
        key: const ValueKey('now-playing-layout'),
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
            Key? key,
          }) => IconButton(
              key: key,
              tooltip: tooltip,
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
              final peek = hasNext && !tight && !horizontal ? 40.0 : 0.0;
              final size = math.max(
                0.0,
                math.min(
                  horizontal ? 410.0 : 380.0,
                  math.min(
                    artBox.maxHeight,
                    artBox.maxWidth - peek - (peek > 0 ? 12 : 0),
                  ),
                ),
              );
              return Center(
                child: _artworkSwitcher(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: size,
                        child: ArtworkMotion(
                          reducedMotion: player.settings.reducedMotion,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _colors.surfaceContainer,
                              borderRadius: BorderRadius.circular(
                                tight ? 26 : 34,
                              ),
                              border: Border.all(
                                color: _colors.primary.withValues(alpha: .14),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  tight ? 21 : 29,
                                ),
                                child: Artwork(
                                  key: const ValueKey('now-playing-artwork'),
                                  seed: track?.title ?? 'Auralis',
                                  telegram: telegram,
                                  track: track,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (peek > 0) ...[
                        const SizedBox(width: 12),
                        SizedBox(
                          width: peek,
                          height: size,
                          child: Tooltip(
                            message: 'Play next track',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: Material(
                                child: InkWell(
                                  key: const ValueKey('now-playing-next-cover'),
                                  onTap: () => player.playAt(nextIndex),
                                  child: ExcludeSemantics(
                                    child: OverflowBox(
                                      maxWidth: size,
                                      maxHeight: size,
                                      alignment: Alignment.centerLeft,
                                      child: SizedBox.square(
                                        dimension: size,
                                        child: Artwork(
                                          seed: player.queue[nextIndex].title,
                                          telegram: telegram,
                                          track: player.queue[nextIndex],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
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
                    style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Text(
                    clockText(audio.duration),
                    style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
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
                    tooltip: 'Shuffle upcoming tracks',
                    icon: Icons.shuffle_rounded,
                    onPressed: hasNext ? player.shuffle : null,
                    background: Colors.transparent,
                  ),
                  const SizedBox(width: 20),
                  pill(
                    key: const ValueKey('now-playing-repeat'),
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
                    foreground: player.repeat ? _colors.primary : _colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 20),
                  pill(
                    key: const ValueKey('now-playing-favorite'),
                    tooltip: favorite
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                    icon: favorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    background: favorite
                        ? _colors.primary.withValues(alpha: .12)
                        : Colors.transparent,
                    foreground: favorite ? _colors.primary : _colors.onSurfaceVariant,
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
                  const Spacer(),
                  _volumeControl(true, tight: true),
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
                    Expanded(
                      flex: 6,
                      child: controls,
                    ),
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
                          color: _colors.surfaceContainerLow.withValues(alpha: .72),
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
            style: TextStyle(color: _colors.onSurfaceVariant, height: 1.8, fontSize: 12),
          ),
          if (action != null) ...[const SizedBox(height: 24), action],
        ],
      ),
    ),
  );

  Widget _volumeControl(bool narrow, {bool tight = false}) => Listener(
    key: const ValueKey('volume-control'),
    onPointerSignal: (event) {
      if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          unawaited(
            player.setVolume(
              player.settings.volume + (event.scrollDelta.dy < 0 ? 5 : -5),
            ),
          );
        });
      }
    },
    child: Tooltip(
      message: 'Volume: ${player.settings.volume.round()}% (scroll to adjust)',
      child: SizedBox(
        height: tight ? 36 : 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_up_rounded, size: 16, color: _colors.onSurfaceVariant),
            const SizedBox(width: 4),
            SizedBox(
              width: narrow ? 84 : 100,
              child: Semantics(
                label: 'Volume',
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: _colors.primary,
                    inactiveTrackColor: _colors.primary.withValues(alpha: .18),
                    thumbColor: _colors.primary,
                    overlayColor: _colors.primary.withValues(alpha: .12),
                    trackShape: const RoundedRectSliderTrackShape(),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                      disabledThumbRadius: 4,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    trackGap: 0,
                  ),
                  child: Slider(
                    key: const ValueKey('volume-slider'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    value: player.settings.volume,
                    max: 100,
                    label: '${player.settings.volume.round()}%',
                    onChanged: (v) =>
                        unawaited(player.setVolume(v, persist: false)),
                    onChangeEnd: player.setVolume,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _transport(bool narrow, {bool short = false}) {
    final audio = player.audio, duration = player.audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final preview = Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('open-current-track'),
        borderRadius: BorderRadius.circular(20),
        onTap: player.current == null
            ? null
            : () => _navigate(_Page.nowPlaying),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: narrow ? 44 : 54,
                  height: narrow ? 44 : 54,
                  child: Artwork(
                    seed: player.current?.title ?? 'Auralis',
                    small: true,
                    telegram: telegram,
                    track: player.current,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      player.current?.title ?? 'Nothing playing',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      player.current?.artist ?? 'Choose a track to get started',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (player.current != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: 16,
                    color: _colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

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
        key: const ValueKey('open-current-track'),
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
                    style: TextStyle(fontSize: 10, color: _colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final reduced = player.settings.reducedMotion ||
        MediaQuery.disableAnimationsOf(context);
    final track = player.current!;
    Widget stopBackground(Alignment alignment) => Material(
      color: _colors.errorContainer,
      borderRadius: BorderRadius.circular(28),
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Icon(Icons.stop_circle_rounded, color: _colors.onErrorContainer),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Semantics(
        hint: 'Swipe left or right to stop playback',
        onDismiss: () => unawaited(_stopDock(track)),
        child: Dismissible(
          key: ValueKey(('dismiss-player', track.id)),
          direction: player.restoringData
              ? DismissDirection.none
              : DismissDirection.horizontal,
          movementDuration: Duration(milliseconds: reduced ? 0 : 220),
          resizeDuration: null,
          background: stopBackground(Alignment.centerLeft),
          secondaryBackground: stopBackground(Alignment.centerRight),
          confirmDismiss: (_) async {
            await _stopDock(track);
            // clear() removes this dock after stopping audio and its stream.
            // No dismissed child is left in the tree while that work awaits.
            return false;
          },
          child: Material(
            key: const ValueKey('player-bar'),
            color: _colors.surfaceContainerLow,
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
                            Expanded(flex: 3, child: preview),
                            const SizedBox(width: 24),
                            Expanded(
                              flex: 5,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [transportButtons, progressBar],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _stopDock(Track track) async {
    if (player.restoringData || !identical(player.current, track)) return;
    try {
      await player.clear();
    } catch (_) {
      _notice('Could not stop playback. Please try again.');
    }
  }

  Widget _settingsPage() => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        key: const ValueKey('settings-page'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bar_chart_rounded),
            title: const Text('Listening stats'),
            subtitle: const Text('Listening time, rankings and data export'),
            onTap: () => _stats(),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Backup & Restore'),
            subtitle: const Text('Stats, collections and preferences'),
            onTap: () => _stats(backup: true),
          ),
          if (widget.sync != null) SyncSettings(controller: widget.sync!),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.new_releases_outlined),
            title: const Text('What’s new'),
            onTap: () => showInstalledChanges(context, widget.installedVersion ?? widget.updater?.currentVersion ?? currentReleaseVersion),
          ),
          const Divider(),
          if (widget.updater != null) ...[
            UpdateSettings(updater: widget.updater!),
            const Divider(),
          ],
          const SizedBox(height: 12),
          Text(
            'Auralis ${widget.updater?.currentVersion ?? '0.1.66'} · AGPL-3.0-or-later\nIndependent Flutter interface. Playback by libmpv. Telegram connectivity by TDLib.',
            style: TextStyle(
              color: _colors.onSurfaceVariant,
              fontSize: 12,
              height: 1.6,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Auralis',
                applicationVersion: widget.updater?.currentVersion ?? '0.1.66',
              ),
              child: const Text('Licenses'),
            ),
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
      value = TextEditingController();
  String? _lastState;
  @override
  void dispose() {
    apiId.dispose();
    apiHash.dispose();
    value.dispose();
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
      }
      _lastState = td.state;
    }
    final initial = td.state == 'disconnected';
    final label = switch (td.state) {
      'authorizationStateWaitPhoneNumber' =>
        'Phone number, including country code',
      'authorizationStateWaitCode' => 'Login code from Telegram',
      'authorizationStateWaitPassword' => 'Two-step verification password',
      'authorizationStateWaitEmailAddress' =>
        'Email address requested by Telegram',
      'authorizationStateWaitEmailCode' => 'Email verification code',
      _ => null,
    };
    Future<void> submit() async {
      if (initial) {
        await td.start(
          apiId: int.tryParse(apiId.text.trim()) ?? 0,
          apiHash: apiHash.text.trim(),
        );
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
        if (initial) ...[
          Text(
            'Create an API application at my.telegram.org, then enter its details here.',
            style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant, height: 1.6),
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
        ] else if (label != null)
          TextField(
            key: ValueKey(td.state),
            controller: value,
            obscureText: td.state == 'authorizationStateWaitPassword',
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: label),
            onSubmitted: td.busy ? null : (_) => submit(),
          )
        else
          Text(switch (td.state) {
            'authorizationStateWaitRegistration' => 'Create your Telegram account in the official app first, then restart Auralis.',
            'authorizationStateClosed' =>
              'Telegram was closed. Restart Auralis to reconnect.',
            'authorizationStateLoggingOut' => 'Signing out of Telegram… Keep your internet connection available. The API ID and hash form will appear when sign-out finishes.',
            'authorizationStateWaitPremiumPurchase' => 'Telegram requires a Premium verification step. Complete it in the official app.',
            'authorizationStateWaitOtherDeviceConfirmation' =>
              'Confirm this sign-in in your Telegram application.',
            _ => 'Connecting securely to Telegram…',
          }, style: TextStyle(color: _colors.onSurfaceVariant, height: 1.6)),
        if (td.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              td.error!,
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
                          content: const Text(
                            'Your music and app settings stay. The unreadable local Telegram files will be set aside. You will need your API details and Telegram verification to sign in again. To keep the old sign-in, restore a password-protected account backup instead.',
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
                  : Text(initial ? 'Connect Telegram' : 'Continue'),
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
        builder: (context, snapshot) =>
            snapshot.connectionState == ConnectionState.done &&
                snapshot.data != null
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
