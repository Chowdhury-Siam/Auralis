import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Decorative playback motion, not an analysis of the track's audio samples.
class WaveSeekBar extends StatefulWidget {
  const WaveSeekBar({
    super.key,
    required this.value,
    required this.buffered,
    required this.playing,
    required this.reducedMotion,
    required this.format,
    this.onChanged,
  });
  final double value, buffered;
  final bool playing, reducedMotion;
  final String Function(double) format;
  final ValueChanged<double>? onChanged;

  @override
  State<WaveSeekBar> createState() => _WaveSeekBarState();
}

class _WaveSeekBarState extends State<WaveSeekBar>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(WaveSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    final moving =
        widget.playing &&
        widget.onChanged != null &&
        !widget.reducedMotion &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (moving && !motion.isAnimating) motion.repeat();
    if (!moving && motion.isAnimating) motion.stop();
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: motion,
      builder: (context, _) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          trackShape: WaveTrack(
            phase: motion.value,
            amplitude:
                widget.reducedMotion || MediaQuery.disableAnimationsOf(context)
                ? 0
                : 3,
          ),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        ),
        child: Semantics(
          label: 'Playback position',
          child: Slider(
            key: const ValueKey('playback-seek'),
            value: widget.value,
            secondaryTrackValue: math.max(widget.value, widget.buffered),
            semanticFormatterCallback: widget.format,
            onChanged: widget.onChanged,
          ),
        ),
      ),
    ),
  );
}

class WaveTrack extends SliderTrackShape with BaseSliderTrackShape {
  const WaveTrack({required this.phase, required this.amplitude});
  final double phase, amplitude;
  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0) return;
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final canvas = context.canvas;
    paint.color = sliderTheme.inactiveTrackColor!;
    canvas.drawLine(
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
      paint,
    );
    final start = textDirection == TextDirection.ltr ? rect.left : rect.right;
    if (secondaryOffset != null) {
      paint.color = sliderTheme.secondaryActiveTrackColor!;
      canvas.drawLine(
        Offset(start, rect.center.dy),
        Offset(secondaryOffset.dx.clamp(rect.left, rect.right), rect.center.dy),
        paint,
      );
    }
    paint.color = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    final end = thumbCenter.dx.clamp(rect.left, rect.right);
    final length = (end - start).abs();
    if (length == 0) return;
    final direction = end >= start ? 1 : -1;
    final path = Path()..moveTo(start, rect.center.dy);
    for (double distance = 2; distance < length; distance += 2) {
      final taper = math.min(
        1.0,
        math.min(distance / 12, (length - distance) / 12),
      );
      path.lineTo(
        start + direction * distance,
        rect.center.dy +
            math.sin(distance / 24 * math.pi * 2 - phase * math.pi * 2) *
                amplitude *
                taper,
      );
    }
    path.lineTo(end, rect.center.dy);
    canvas.drawPath(path, paint);
  }
}
