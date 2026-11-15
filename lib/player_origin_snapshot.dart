import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Retained-layer blur for the existing origin page during player transitions.
/// The legacy name is kept for callers. No page bitmap is captured, read back
/// or synchronously re-rasterized when opening/closing the player.
class PlayerOriginSnapshot extends StatelessWidget {
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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: dismissal,
    // Reuse one real page and its retained display list. Animation changes only
    // the filter layer, not library layout, artwork decoding or scroll state.
    child: RepaintBoundary(child: child),
    builder: (context, child) {
      final active = enabled && dismissal.value > 0 && dismissal.value < 1;
      final amount = active
          ? const Interval(
              .025,
              .24,
              curve: Curves.easeOut,
            ).transform(1 - dismissal.value)
          : 0.0;
      return ImageFiltered(
        key: const ValueKey('player-cached-blur'),
        enabled: amount > 0,
        imageFilter: ui.ImageFilter.blur(
          sigmaX: 8 * amount,
          sigmaY: 8 * amount,
          tileMode: ui.TileMode.clamp,
        ),
        child: child,
      );
    },
  );
}
