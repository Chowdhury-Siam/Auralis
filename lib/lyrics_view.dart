import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'lyrics.dart';
import 'data_files.dart';
import 'models.dart';
import 'player.dart';
import 'wave_seek_bar.dart';

const lyricsBackground = Color(0xFF111015);
const lyricsHighlight = Color(0xFFC7B5FF);

class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.player,
    required this.repository,
    required this.artwork,
    required this.onBack,
    this.backgroundColor,
    this.loadEmbedded,
    this.files = const DataFiles(),
  });
  final DataFiles files;
  final PlayerController player;
  final LyricsRepository repository;
  final Widget artwork;
  final VoidCallback onBack;
  // The player shell supplies the artwork backdrop behind immersive lyrics.
  final Color? backgroundColor;
  final Future<Lyrics?> Function(Track)? loadEmbedded;
  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  Track? _track;
  Lyrics? _lyrics;
  String? _error;
  bool _importing = false;
  bool _loading = false, _synced = true, _looked = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.player.current, _track)) _reset();
  }

  void _reset() {
    _generation++;
    _track = widget.player.current;
    _lyrics = _track == null ? null : widget.repository.cached(_track!);
    _looked = _track != null && widget.repository.contains(_track!);
    _loading = false;
    _error = null;
    _synced = _lyrics == null || _lyrics!.lines.isNotEmpty;
    if (_lyrics == null && widget.loadEmbedded != null) unawaited(_embedded());
  }

  Future<void> _embedded() async {
    final track = _track, load = widget.loadEmbedded;
    if (track == null || load == null || _loading) return;
    final generation = ++_generation;
    _loading = true;
    try {
      final lyrics = await load(track);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (lyrics != null) {
          _lyrics = lyrics;
          widget.repository.save(track, lyrics);
          _synced = lyrics.lines.isNotEmpty;
          _error = null;
        }
      });
    } catch (_) {
      // Missing or unavailable tags leave lookup and paste available.
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _find() async {
    final track = _track;
    if (track == null || _loading) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lyrics = await widget.repository.find(track);
      if (!mounted || generation != _generation) return;
      setState(() {
        _lyrics = lyrics;
        _looked = true;
        _synced = lyrics != null && lyrics.lines.isNotEmpty;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = 'Could not load lyrics. Check your connection and try again, or paste lyrics.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _import() async {
    final track = _track;
    if (track == null || _importing) return;
    final generation = _generation;
    setState(() => _importing = true);
    try {
      final path = await widget.files.openLyrics();
      if (path == null || !mounted || generation != _generation) return;
      final bytes = await widget.files.readBytes(
        path,
        maxBytes: Lyrics.maxFileBytes,
      );
      final lyrics = Lyrics.fromFileBytes(bytes);
      if (!mounted || generation != _generation || !identical(track, _track)) {
        return;
      }
      _useLyrics(track, lyrics);
    } catch (_) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not import lyrics. Choose a UTF-8 or UTF-16 .lrc file up to 256 KiB with at most 2000 lines.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _paste() async {
    final track = _track;
    if (track == null) return;
    var text = '';
    final lyrics = await showDialog<Lyrics>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Paste lyrics'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Use plain text or LRC with [mm:ss.xx] timestamps. Kept only for this app session.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) => text = value,
                      minLines: 4,
                      maxLines: 9,
                      maxLength: 256 * 1024,
                      decoration: InputDecoration(
                        hintText: '[00:12.50] A lyric line',
                        errorText: error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    final result = Lyrics.parse(text);
                    if (result.plain.isEmpty && result.lines.isEmpty) {
                      throw const FormatException('Paste some lyrics first.');
                    }
                    Navigator.pop(context, result);
                  } on FormatException catch (e) {
                    update(() {
                      error = e.message;
                    });
                  }
                },
                child: const Text('Use lyrics'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || !identical(track, _track) || lyrics == null) return;
    _useLyrics(track, lyrics);
  }

  void _useLyrics(Track track, Lyrics lyrics) {
    _generation++;
    widget.repository.save(track, lyrics);
    setState(() {
      _lyrics = lyrics;
      _looked = true;
      _loading = false;
      _error = null;
      _synced = lyrics.lines.isNotEmpty;
    });
  }

  Widget _message(String text) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 16, height: 1.6),
      ),
    ),
  );

  PopupMenuItem<String> _menuAction({
    required String value,
    required bool enabled,
    required IconData icon,
    required String title,
    required String subtitle,
  }) => PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: _LyricsMenuEntry(
      icon: icon,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
    ),
  );

  Widget _options({bool vertical = false}) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        popupMenuTheme: PopupMenuThemeData(
          color: _colors.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.black.withValues(alpha: .42),
          elevation: 16,
          menuPadding: const EdgeInsets.all(8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: _colors.outlineVariant),
          ),
        ),
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Lyrics options',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 300),
        offset: Offset(vertical ? -6 : 0, vertical ? -10 : 10),
        icon: Icon(
          vertical ? Icons.more_vert_rounded : Icons.more_horiz_rounded,
        ),
        onSelected: (value) {
          if (value == 'import') {
            unawaited(_import());
          } else if (value == 'embedded') {
            setState(() => unawaited(_embedded()));
          } else {
            unawaited(value == 'paste' ? _paste() : _find());
          }
        },
        itemBuilder: (_) => [
          _menuAction(
            value: 'import',
            enabled: _track != null && !_importing,
            icon: Icons.file_open_rounded,
            title: 'Import .lrc file',
            subtitle: 'Use a local synced-lyrics file.',
          ),
          if (widget.loadEmbedded != null)
            _menuAction(
              value: 'embedded',
              enabled: _track != null && !_loading,
              icon: Icons.music_note_rounded,
              title: 'Read lyrics from music file',
              subtitle: 'Try embedded lyrics from this track.',
            ),
          _menuAction(
            value: 'find',
            enabled: _track != null && !_loading,
            icon: Icons.search_rounded,
            title: 'Find lyrics on LRCLIB',
            subtitle: 'Search online using song details.',
          ),
          _menuAction(
            value: 'paste',
            enabled: _track != null,
            icon: Icons.content_paste_rounded,
            title: 'Paste lyrics',
            subtitle: 'Enter plain text or timestamped LRC.',
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final lyrics = _lyrics;
    if (_track == null) return _message('Choose a track to see its lyrics.');
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _message(_error!);
    if (lyrics?.instrumental == true) {
      return _message('Instrumental · no lyrics');
    }
    if (lyrics == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_rounded,
                size: 44,
                color: _colors.primary,
              ),
              const SizedBox(height: 12),
              Text(
                _looked
                    ? 'No lyrics found for this song.'
                    : 'Bring the words into focus.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: const Text(
                  'Embedded lyrics are read from the music file first. Find lyrics sends this song’s title, artist and duration to LRCLIB. Your Telegram account and channel details stay private.',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _find,
                icon: const Icon(Icons.search),
                label: const Text('Find lyrics'),
              ),
              TextButton.icon(
                onPressed: _importing ? null : _import,
                icon: const Icon(Icons.file_open_outlined, size: 18),
                label: const Text('Import .lrc file'),
              ),
              TextButton(
                onPressed: _paste,
                child: const Text('Paste lyrics instead'),
              ),
            ],
          ),
        ),
      );
    }
    if (_synced && lyrics.lines.isNotEmpty) {
      return _SyncedLyrics(
        key: ObjectKey(lyrics),
        lyrics: lyrics,
        player: widget.player,
      );
    }
    return SingleChildScrollView(
      key: ObjectKey(lyrics),
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: SelectableText(
          lyrics.plain,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            height: 1.7,
          ),
        ),
      ),
    );
  }

  Widget _mode(bool synced) {
    final selected = _synced == synced;
    final label = synced ? 'Synced' : 'Static';
    final icon = synced ? Icons.graphic_eq_rounded : Icons.article_rounded;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.4;
    return Expanded(
      child: Semantics(
        selected: selected,
        child: TextButton(
          key: ValueKey(synced ? 'lyrics-synced-mode' : 'lyrics-static-mode'),
          style: TextButton.styleFrom(
            backgroundColor: selected
                ? _colors.primary
                : _colors.surfaceContainer,
            foregroundColor: selected
                ? _colors.onPrimary
                : _colors.onSurface,
            disabledBackgroundColor: _colors.surfaceContainerLowest,
            disabledForegroundColor: _colors.onSurfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: selected ? Colors.transparent : _colors.outlineVariant,
              ),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: largeText ? 6 : 12,
              vertical: 8,
            ),
            textStyle: Theme.of(context).textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          onPressed: synced && _lyrics!.lines.isEmpty
              ? null
              : () => setState(() => _synced = synced),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!largeText) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _sourceText(Lyrics lyrics) => lyrics.online
      ? 'Lyrics: LRCLIB · timings may vary by recording'
      : lyrics.embedded
      ? 'Lyrics from music file'
      : lyrics.imported
      ? 'Imported LRC · session only'
      : 'Pasted lyrics · session only';

  Widget _surfaceCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    double radius = 30,
  }) => Material(
    color: _colors.surfaceContainerLow,
    elevation: 0,
    borderRadius: BorderRadius.circular(radius),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      key: const ValueKey('lyrics-song-pill'),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(dimension: 48, child: widget.artwork),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _track?.title ?? 'Nothing playing',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _track?.artist ?? 'Choose a track first',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _options(),
      ],
    ),
  );

  Widget _playback(bool reduced) {
    final player = widget.player, audio = player.audio;
    final duration = audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    const size = 44.0;
    return Row(
      children: [
        SizedBox(
          width: size,
          height: size,
          child: IconButton.filled(
            key: const ValueKey('lyrics-play-pause'),
            tooltip: audio.playing ? 'Pause' : 'Play',
            style:
                IconButton.styleFrom(
                  backgroundColor: _colors.primary,
                  foregroundColor: _colors.onPrimary,
                  disabledBackgroundColor: _colors.primary.withValues(alpha: .35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      audio.playing ? 20 : size / 2,
                    ),
                  ),
                ).copyWith(
                  animationDuration: Duration(milliseconds: reduced ? 0 : 220),
                ),
            onPressed: _track == null || player.loading
                ? null
                : () async {
                    try {
                      await audio.toggle();
                    } catch (_) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not change playback.'),
                          ),
                        );
                      }
                    }
                  },
            icon: AnimatedSwitcher(
              duration: Duration(milliseconds: reduced ? 0 : 180),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: player.loading || audio.buffering
                  ? const SizedBox(
                      key: ValueKey('lyrics-buffering'),
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      audio.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      key: ValueKey(audio.playing),
                      size: 28,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 32,
          child: Text(
            clockText(audio.position),
            maxLines: 1,
            style: TextStyle(fontSize: 10, color: _colors.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: DecoratedBox(
            key: const ValueKey('lyrics-seek-pill'),
            decoration: BoxDecoration(
              color: _colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(40),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: WaveSeekBar(
                value: progress,
                playing: audio.playing && !audio.buffering && _track != null,
                reducedMotion: reduced,
                format: (value) => clockText(
                  Duration(milliseconds: (value * duration).round()),
                ),
                onChanged: duration <= 0
                    ? null
                    : (value) async {
                        try {
                          await player.seek(
                            Duration(milliseconds: (value * duration).round()),
                          );
                        } catch (_) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not seek to this position.',
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
            ),
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            clockText(audio.duration),
            maxLines: 1,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10, color: _colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _transportDock({
    required bool reduced,
    required bool showModeSelector,
  }) => _surfaceCard(
    radius: 16,
    padding: const EdgeInsets.all(12),
    child: LayoutBuilder(
      builder: (context, box) {
        final modes = showModeSelector
            ? Row(
                children: [_mode(true), const SizedBox(width: 8), _mode(false)],
              )
            : const SizedBox.shrink();
        if (box.maxWidth >= 700) {
          return Row(
            children: [
              Expanded(child: _playback(reduced)),
              if (showModeSelector) ...[
                const SizedBox(width: 24),
                SizedBox(width: 240, child: modes),
              ],
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _playback(reduced),
            if (showModeSelector) ...[const SizedBox(height: 8), modes],
          ],
        );
      },
    ),
  );

  Widget _footerMetaRow({required bool compact}) {
    final lyrics = _lyrics;
    final source = lyrics == null
        ? 'Lyrics source will appear here'
        : _sourceText(lyrics);
    return Row(
      children: [
        IconButton.filled(
          onPressed: widget.onBack,
          tooltip: 'Back to cover',
          style: IconButton.styleFrom(
            backgroundColor: _colors.surfaceContainerLow,
            foregroundColor: _colors.onSurface,
          ),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            source,
            textAlign: compact ? TextAlign.center : TextAlign.left,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: _colors.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Material(
          color: _colors.surfaceContainerLow,
          shape: const CircleBorder(),
          child: _options(vertical: true),
        ),
      ],
    );
  }

  Widget _layout({required bool short, required bool reduced}) => Column(
    children: [
      _header(),
      const SizedBox(height: 8),
      Expanded(child: _body()),
      const SizedBox(height: 8),
      _transportDock(
        reduced: reduced,
        showModeSelector: _lyrics != null && !_lyrics!.instrumental,
      ),
      const SizedBox(height: 8),
      _footerMetaRow(compact: short),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final reduced =
        widget.player.settings.reducedMotion ||
        MediaQuery.disableAnimationsOf(context);
    return Material(
        key: const ValueKey('lyrics-immersive'),
        color: widget.backgroundColor ?? _colors.surface,
        child: LayoutBuilder(
          builder: (context, box) {
            final short = box.maxHeight < 620;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    short ? 8 : 16,
                    16,
                    short ? 8 : 16,
                  ),
                  child: _layout(short: short, reduced: reduced),
                ),
              ),
            );
          },
        ),
    );
  }
}

class _LyricsMenuEntry extends StatelessWidget {
  const _LyricsMenuEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = enabled
        ? colors.onSurface
        : colors.onSurfaceVariant;
    final secondary = colors.onSurfaceVariant.withValues(
      alpha: enabled ? 1 : .48,
    );
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: enabled
                  ? colors.primary.withValues(alpha: .14)
                  : Colors.white.withValues(alpha: .05),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: foreground, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 12.2,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncedLyrics extends StatefulWidget {
  const _SyncedLyrics({super.key, required this.lyrics, required this.player});
  final Lyrics lyrics;
  final PlayerController player;
  @override
  State<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<_SyncedLyrics>
    with SingleTickerProviderStateMixin {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  late final _lineMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
    value: 1,
  );
  final _scroll = ScrollController();
  bool _follow = true;
  int? _lastActive;
  double? _width, _height;
  TextScaler? _scaler;
  TextStyle? _style;
  TextDirection? _direction;
  final _heights = <double>[], _offsets = <double>[];
  @override
  void dispose() {
    _lineMotion.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final active = widget.lyrics.activeAt(widget.player.audio.position);
      final scaler = MediaQuery.textScalerOf(context);
      final reduced =
          widget.player.settings.reducedMotion ||
          MediaQuery.disableAnimationsOf(context);
      if (reduced && _lineMotion.isAnimating) _lineMotion.stop();
      final direction = Directionality.of(context);
      final style = TextStyle(
        fontSize: box.maxWidth < 500 ? 23 : 32,
        height: 1.35,
        fontWeight: FontWeight.w700,
        fontFamily: Theme.of(context).textTheme.bodyLarge?.fontFamily,
      );
      final changed =
          _width != box.maxWidth ||
          _scaler != scaler ||
          _height != box.maxHeight ||
          _style != style ||
          _direction != direction;
      if (changed) {
        _width = box.maxWidth;
        _height = box.maxHeight;
        _scaler = scaler;
        _style = style;
        _direction = direction;
        _heights.clear();
        _offsets.clear();
        var offset = 0.0;
        for (final line in widget.lyrics.lines) {
          final painter = TextPainter(
            text: TextSpan(
              text: line.text.isEmpty ? '♪' : line.text,
              style: style,
            ),
            textDirection: direction,
            textScaler: scaler,
          )..layout(maxWidth: math.max(1, box.maxWidth - 48));
          final height = math.max(64.0, painter.height + 28);
          painter.dispose();
          _offsets.add(offset);
          _heights.add(height);
          offset += height;
        }
      }
      if (_follow && (_lastActive != active || changed)) {
        final advancing = _lastActive != null && _lastActive != active;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !_follow ||
              !_scroll.hasClients ||
              _lastActive != active) {
            return;
          }
          final target =
              (active < 0 ? 0.0 : _offsets[active] + _heights[active] / 2)
                  .clamp(0.0, _scroll.position.maxScrollExtent);
          if (reduced || !advancing) {
            _lineMotion.stop();
            _lineMotion.value = 1;
            _scroll.jumpTo(target);
          } else {
            if ((target - _scroll.offset).abs() > .5) {
              _lineMotion.forward(from: 0);
            }
            unawaited(
              _scroll.animateTo(
                target,
                duration: const Duration(milliseconds: 480),
                curve: Curves.easeOutCubic,
              ),
            );
          }
        });
      }
      _lastActive = active;
      return Stack(
        children: [
          NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.direction != ScrollDirection.idle && _follow) {
                setState(() {
                  _follow = false;
                  _lineMotion.stop();
                  _lineMotion.value = 1;
                });
              }
              return false;
            },
            // Reuse the lazy viewport during blur ticks; never filter the toolbar.
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _lineMotion,
                builder: (context, child) {
                  final moving = !reduced && _follow && _lineMotion.isAnimating;
                  final blur = moving
                      ? math.sin(math.pi * _lineMotion.value) * 3.5
                      : 0.0;
                  return ImageFiltered(
                    key: const ValueKey('lyrics-motion-blur'),
                    enabled: moving,
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: blur * .12,
                      sigmaY: blur,
                    ),
                    child: child,
                  );
                },
                child: RepaintBoundary(
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                      ],
                      stops: [0, .12, .86, 1],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: ListView.builder(
                      key: const ValueKey('synced-lyrics'),
                      controller: _scroll,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
                      padding: EdgeInsets.symmetric(
                        vertical: box.maxHeight * .5,
                      ),
                      itemCount: widget.lyrics.lines.length,
                      itemExtentBuilder: (index, _) => _heights[index],
                      itemBuilder: (context, index) {
                        final line = widget.lyrics.lines[index];
                        final current = active == index;
                        final distance = (index - active).abs();
                        return Semantics(
                          selected: current,
                          button: true,
                          label: 'Seek to ${clockText(line.time)}',
                          child: InkWell(
                            key: ValueKey('lyric-$index'),
                            onTap: () async {
                              try {
                                final duration = widget.player.audio.duration;
                                final target =
                                    duration > Duration.zero &&
                                        line.time > duration
                                    ? duration
                                    : line.time;
                                await widget.player.seek(target);
                                if (mounted) {
                                  setState(() {
                                    _follow = true;
                                    _lastActive = null;
                                  });
                                }
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Could not seek to this lyric.',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 14,
                              ),
                              child: ImageFiltered(
                                key: ValueKey('lyric-focus-$index'),
                                enabled: active >= 0 && !current,
                                imageFilter: ui.ImageFilter.blur(
                                  sigmaX: 2.2,
                                  sigmaY: 2.2,
                                ),
                                child: AnimatedDefaultTextStyle(
                                  duration: Duration(
                                    milliseconds: reduced ? 0 : 240,
                                  ),
                                  curve: Curves.easeOutCubic,
                                  style: style.copyWith(
                                    color: current
                                        ? _colors.primary
                                        : Colors.white.withValues(
                                            alpha: !_follow
                                                ? .72
                                                : (distance <= 1 ? .56 : .32),
                                          ),
                                  ),
                                  child: Text(
                                    line.text.isEmpty ? '♪' : line.text,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!_follow)
            Positioned(
              bottom: 6,
              right: 12,
              child: FilledButton.tonalIcon(
                onPressed: () => setState(() {
                  _follow = true;
                  _lastActive = null;
                }),
                icon: const Icon(Icons.my_location_rounded, size: 16),
                label: const Text('Follow song'),
              ),
            ),
        ],
      );
    },
  );
}
