import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The origin stays mounted, with a small blurred image used only while the
/// player moves over it. Capture never blocks input or the spring animation.
class PlayerOriginSnapshot extends StatefulWidget {
  const PlayerOriginSnapshot({
    super.key,
    required this.enabled,
    required this.dismissal,
    required this.child,
  });

  final bool enabled;
  final Animation<double> dismissal;
  final Widget child;

  @override
  State<PlayerOriginSnapshot> createState() => _PlayerOriginSnapshotState();
}

class _PlayerOriginSnapshotState extends State<PlayerOriginSnapshot> {
  final _boundary = GlobalKey();
  ui.Image? _blurred;
  Size? _size;
  bool _requested = false;
  bool _capturing = false;
  int _generation = 0;

  bool get _active =>
      widget.enabled &&
      widget.dismissal.value > 0 &&
      widget.dismissal.value < 1;

  void _reset(Size size) {
    _generation++;
    _requested = false;
    _size = size;
    _blurred?.dispose();
    _blurred = null;
  }

  Future<void> _prepareBlur(int generation, Size size) async {
    if (!mounted || generation != _generation || !_active) return;
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    // Capture the already-filtered layer. The smaller raster preserves the
    // logical 8 dp blur and avoids a full-window filter on subsequent frames.
    final scale = math.min(.5, 640 / size.longestSide);
    _capturing = true;
    try {
      final image = await boundary.toImage(pixelRatio: scale);
      if (!mounted || generation != _generation || !_active) {
        image.dispose();
        return;
      }
      setState(() => _blurred = image);
    } catch (_) {
      // Keep the live filter if this renderer cannot capture an image.
    } finally {
      _capturing = false;
    }
  }

  @override
  void dispose() {
    _blurred?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: widget.dismissal,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        final size = constraints.biggest;
        if (_size != size || (!_active && _requested)) _reset(size);
        final amount = _active
            ? const Interval(
                .025,
                .24,
                curve: Curves.easeOut,
              ).transform(1 - widget.dismissal.value)
            : 0.0;
        if (amount == 1 &&
            !_requested &&
            !_capturing &&
            size.isFinite &&
            !size.isEmpty) {
          _requested = true;
          final generation = _generation;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(_prepareBlur(generation, size));
          });
        }
        // Only substitute the cached image at full blur. The short ramp near
        // the dock keeps the exact live blur radius and transparent edges.
        final blurred = amount == 1 ? _blurred : null;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            Opacity(
              opacity: blurred == null ? 1 : 0,
              child: RepaintBoundary(
                key: _boundary,
                child: ImageFiltered(
                  key: const ValueKey('player-cached-blur'),
                  enabled: blurred == null && amount > 0,
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: 8 * amount,
                    sigmaY: 8 * amount,
                    tileMode: ui.TileMode.clamp,
                  ),
                  child: child,
                ),
              ),
            ),
            if (blurred != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: RawImage(
                    key: const ValueKey('player-origin-blurred-image'),
                    image: blurred,
                    fit: BoxFit.fill,
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
