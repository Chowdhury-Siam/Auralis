import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
                      Theme.of(context).colorScheme.surface.withValues(alpha: .60),
                      Theme.of(context).colorScheme.surface.withValues(alpha: .70),
                      Theme.of(context).colorScheme.surface.withValues(alpha: .92),
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

/// Subtle pointer-following depth, with no perpetual animation or touch gesture.
class ArtworkMotion extends StatefulWidget {
  const ArtworkMotion({
    super.key,
    required this.child,
    required this.reducedMotion,
  });

  final Widget child;
  final bool reducedMotion;

  @override
  State<ArtworkMotion> createState() => _ArtworkMotionState();
}

class _ArtworkMotionState extends State<ArtworkMotion> {
  bool _hovered = false;
  Offset _pointer = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final reduced =
        widget.reducedMotion || MediaQuery.disableAnimationsOf(context);
    final active = _hovered && !reduced;
    final duration = Duration(milliseconds: reduced ? 0 : 240);
    return LayoutBuilder(
      builder: (context, box) {
        void follow(Offset position) {
          if (reduced || box.maxWidth <= 0 || box.maxHeight <= 0) return;
          setState(() {
            _hovered = true;
            _pointer = Offset(
              (position.dx / box.maxWidth * 2 - 1).clamp(-1.0, 1.0),
              (position.dy / box.maxHeight * 2 - 1).clamp(-1.0, 1.0),
            );
          });
        }

        return MouseRegion(
          onEnter: (event) => follow(event.localPosition),
          onHover: (event) => follow(event.localPosition),
          onExit: (_) => setState(() {
            _hovered = false;
            _pointer = Offset.zero;
          }),
          child: AnimatedScale(
            key: const ValueKey('artwork-hover-scale'),
            scale: active ? 1.025 : 1,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: active ? const Offset(0, -.012) : Offset.zero,
              duration: duration,
              curve: Curves.easeOutCubic,
              child: TweenAnimationBuilder<Offset>(
                tween: Tween<Offset>(
                  begin: Offset.zero,
                  end: active ? _pointer : Offset.zero,
                ),
                duration: duration,
                curve: Curves.easeOutCubic,
                builder: (context, pointer, child) => Transform(
                  key: const ValueKey('artwork-hover-tilt'),
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, .001)
                    ..rotateX(-pointer.dy * .035)
                    ..rotateY(pointer.dx * .035),
                  child: child,
                ),
                child: RepaintBoundary(child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}
