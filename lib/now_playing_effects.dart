import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';

/// Artwork-local navigation: one swipe or one wheel burst changes one song.
class ArtworkTrackSwitcher extends StatefulWidget {
  const ArtworkTrackSwitcher({
    super.key,
    required this.child,
    required this.identity,
    required this.reducedMotion,
    this.paged = false,
    this.onNext,
    this.onPrevious,
  });

  final Widget child;
  final Object identity;
  final bool reducedMotion;
  final bool paged;
  final VoidCallback? onNext, onPrevious;

  @override
  State<ArtworkTrackSwitcher> createState() => _ArtworkTrackSwitcherState();
}

class _ArtworkTrackSwitcherState extends State<ArtworkTrackSwitcher> {
  double _drag = 0, _wheelDistance = 0;
  bool _dragging = false, _wheelHandled = false;
  Duration? _lastWheel;

  void _resetDrag() => setState(() {
    _drag = 0;
    _dragging = false;
  });

  void _scroll(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    final delta = signal.scrollDelta.dx.abs() > signal.scrollDelta.dy.abs()
        ? signal.scrollDelta.dx
        : signal.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      final newBurst =
          _lastWheel == null ||
          signal.timeStamp - _lastWheel! > const Duration(milliseconds: 220) ||
          _wheelDistance.sign != delta.sign;
      _lastWheel = signal.timeStamp;
      if (newBurst) {
        _wheelDistance = 0;
        _wheelHandled = false;
      }
      if (_wheelHandled) return;
      _wheelDistance += delta;
      if (_wheelDistance.abs() < 48) return;
      _wheelHandled = true;
      (delta > 0 ? widget.onNext : widget.onPrevious)?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduced =
        widget.reducedMotion || MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(1.0, box.maxWidth);
        final canDrag = widget.onNext != null || widget.onPrevious != null;
        return Semantics(
          label: 'Album artwork',
          hint: canDrag ? 'Swipe artwork to change songs' : null,
          onIncrease: widget.onNext,
          onDecrease: widget.onPrevious,
          child: Listener(
            onPointerSignal: canDrag ? _scroll : null,
            child: widget.paged
                ? widget.child
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: canDrag
                        ? (_) {
                            setState(() {
                              _drag = 0;
                              _dragging = true;
                            });
                          }
                        : null,
                    onHorizontalDragUpdate: canDrag
                        ? (event) => setState(() {
                            _drag = (_drag + event.delta.dx).clamp(
                              -width * .35,
                              width * .35,
                            );
                          })
                        : null,
                    onHorizontalDragCancel: canDrag ? _resetDrag : null,
                    onHorizontalDragEnd: canDrag
                        ? (event) {
                            final velocity = event.primaryVelocity ?? 0;
                            final committed =
                                _drag.abs() >= math.min(80, width * .18) ||
                                (_drag.abs() >= 12 && velocity.abs() >= 600);
                            final direction = velocity.abs() >= 600
                                ? velocity
                                : _drag;
                            _resetDrag();
                            if (committed) {
                              (direction < 0
                                      ? widget.onNext
                                      : widget.onPrevious)
                                  ?.call();
                            }
                          }
                        : null,
                    child: AnimatedSlide(
                      key: const ValueKey('artwork-drag-feedback'),
                      offset: reduced ? Offset.zero : Offset(_drag / width, 0),
                      duration: Duration(
                        milliseconds: reduced || _dragging ? 0 : 220,
                      ),
                      curve: Curves.easeOutCubic,
                      child: AnimatedSwitcher(
                        duration: Duration(milliseconds: reduced ? 0 : 240),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.center,
                          children: [
                            for (final oldChild in previous)
                              IgnorePointer(
                                child: ExcludeSemantics(child: oldChild),
                              ),
                            ?current,
                          ],
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(widget.identity),
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

/// Full-size covers follow the finger and snap into place using native paging.
class ArtworkPager extends StatefulWidget {
  const ArtworkPager({
    super.key,
    required this.index,
    required this.itemCount,
    required this.itemBuilder,
    this.onSelected,
  });

  final int index, itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<int>? onSelected;

  @override
  State<ArtworkPager> createState() => _ArtworkPagerState();
}

class _ArtworkPagerState extends State<ArtworkPager> {
  late final _pages = PageController(
    initialPage: widget.index,
    keepPage: false,
  );
  int? _swipedPage;

  @override
  void didUpdateWidget(ArtworkPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index || widget.index == _swipedPage) return;
    // Transport controls and automatic track changes also update the cover.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      _pages.jumpToPage(widget.index);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView.builder(
    key: const ValueKey('artwork-pages'),
    controller: _pages,
    itemCount: widget.itemCount,
    itemBuilder: widget.itemBuilder,
    physics: widget.onSelected == null
        ? const NeverScrollableScrollPhysics()
        : const ClampingScrollPhysics(),
    onPageChanged: (index) {
      _swipedPage = index;
      if (index != widget.index) {
        widget.onSelected?.call(index);
      }
    },
  );
}

/// A decorative music pulse; only its small canvas repaints, never the backdrop.
class LyricsWaitingIndicator extends StatefulWidget {
  const LyricsWaitingIndicator({
    super.key,
    required this.playing,
    required this.reducedMotion,
    required this.label,
  });
  final bool playing, reducedMotion;
  final String label;

  @override
  State<LyricsWaitingIndicator> createState() => _LyricsWaitingIndicatorState();
}

class _LyricsWaitingIndicatorState extends State<LyricsWaitingIndicator>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  void _sync() {
    final animate =
        widget.playing &&
        _foreground &&
        !widget.reducedMotion &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate && !_motion.isAnimating) _motion.repeat();
    if (!animate && _motion.isAnimating) _motion.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(LyricsWaitingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Semantics(
      label: widget.label,
      child: ExcludeSemantics(
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: 220,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      key: const ValueKey('lyrics-waiting-pulse'),
                      size: const Size(140, 64),
                      painter: _MusicPulsePainter(
                        _motion,
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _MusicPulsePainter extends CustomPainter {
  _MusicPulsePainter(this.motion, this.color) : super(repaint: motion);
  final Animation<double> motion;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: .8);
    for (var bar = 0; bar < 7; bar++) {
      final wave = .5 + .5 * math.sin(motion.value * math.pi * 2 + bar * .85);
      final envelope = 1 - (bar - 3).abs() * .18;
      final height = 8 + 44 * envelope * (.35 + wave * .65);
      final x = size.width / 2 + (bar - 3) * 12;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, size.height / 2),
            width: 5,
            height: height,
          ),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MusicPulsePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.motion != motion;
}

/// A quiet, artwork-colored backdrop that never intercepts player input.
class NowPlayingBackdrop extends StatefulWidget {
  const NowPlayingBackdrop({
    super.key,
    required this.artwork,
    required this.identity,
    required this.reducedMotion,
    this.artworkUpdates,
  });

  final Widget artwork;
  final Object identity;
  final bool reducedMotion;
  final Listenable? artworkUpdates;

  @override
  State<NowPlayingBackdrop> createState() => _NowPlayingBackdropState();
}

class _NowPlayingBackdropState extends State<NowPlayingBackdrop> {
  Widget? _cachedBackdrop;

  @override
  void initState() {
    super.initState();
    widget.artworkUpdates?.addListener(_invalidate);
  }

  void _invalidate() {
    setState(() => _cachedBackdrop = null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedBackdrop = null;
  }

  @override
  void didUpdateWidget(NowPlayingBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUpdates != widget.artworkUpdates) {
      oldWidget.artworkUpdates?.removeListener(_invalidate);
      widget.artworkUpdates?.addListener(_invalidate);
    }
    if (oldWidget.identity != widget.identity ||
        oldWidget.reducedMotion != widget.reducedMotion ||
        oldWidget.artworkUpdates != widget.artworkUpdates) {
      _cachedBackdrop = null;
    }
  }

  @override
  void dispose() {
    widget.artworkUpdates?.removeListener(_invalidate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _cachedBackdrop ??= IgnorePointer(
    child: ExcludeSemantics(
      child: ClipRect(
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 48,
                  sigmaY: 48,
                  tileMode: ui.TileMode.clamp,
                ),
                child: Transform.scale(
                  scale: 1.16,
                  child: AnimatedSwitcher(
                    duration: Duration(
                      milliseconds:
                          widget.reducedMotion ||
                              MediaQuery.disableAnimationsOf(context)
                          ? 0
                          : 420,
                    ),
                    child: SizedBox.expand(
                      key: ValueKey(widget.identity),
                      child: widget.artwork,
                    ),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Theme.of(context).colorScheme.surface
                          .withValues(alpha: .60),
                      Theme.of(context).colorScheme.surface
                          .withValues(alpha: .70),
                      Theme.of(context).colorScheme.surface
                          .withValues(alpha: .92),
                    ],
                    stops: [0, .55, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The whole mini-player follows a sideways drag, then returns to its place.
/// Seeking and buttons retain their own gesture recognizers inside the card.
class PlayerDockMotion extends StatefulWidget {
  const PlayerDockMotion({
    super.key,
    required this.child,
    required this.reducedMotion,
    required this.enabled,
    required this.onExpandStart,
    required this.onExpandUpdate,
    required this.onExpandEnd,
    required this.onExpandCancel,
  });
  final Widget child;
  final bool reducedMotion, enabled;
  final GestureDragStartCallback onExpandStart;
  final GestureDragUpdateCallback onExpandUpdate;
  final GestureDragEndCallback onExpandEnd;
  final GestureDragCancelCallback onExpandCancel;
  @override
  State<PlayerDockMotion> createState() => _PlayerDockMotionState();
}

class _PlayerDockMotionState extends State<PlayerDockMotion>
    with SingleTickerProviderStateMixin {
  late final _offset = AnimationController.unbounded(vsync: this);

  void _returnToRest([double velocity = 0]) {
    if (widget.reducedMotion) {
      _offset.value = 0;
    } else {
      _offset.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 280, damping: 28),
          _offset.value,
          0,
          velocity.clamp(-1800.0, 1800.0),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(PlayerDockMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.reducedMotion != oldWidget.reducedMotion) {
      _offset.stop();
      _offset.value = 0;
    }
  }

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: widget.enabled ? (_) => _offset.stop() : null,
      onHorizontalDragUpdate: widget.enabled
          ? (details) {
              _offset.value = (_offset.value + details.delta.dx).clamp(
                -box.maxWidth * .92,
                box.maxWidth * .92,
              );
            }
          : null,
      onHorizontalDragEnd: widget.enabled
          ? (details) => _returnToRest(details.primaryVelocity ?? 0)
          : null,
      onHorizontalDragCancel: widget.enabled ? _returnToRest : null,
      onVerticalDragStart: widget.enabled ? widget.onExpandStart : null,
      onVerticalDragUpdate: widget.enabled ? widget.onExpandUpdate : null,
      onVerticalDragEnd: widget.enabled ? widget.onExpandEnd : null,
      onVerticalDragCancel: widget.enabled ? widget.onExpandCancel : null,
      child: AnimatedBuilder(
        animation: _offset,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          key: const ValueKey('mini-player-drag'),
          offset: Offset(_offset.value, 0),
          child: child,
        ),
      ),
    ),
  );
}
