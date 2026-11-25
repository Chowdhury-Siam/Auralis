import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Decorative playback motion, not an analysis of the track's audio samples.
class WaveSeekBar extends StatefulWidget {
  const WaveSeekBar({
    super.key,
    required this.value,
    required this.playing,
    required this.reducedMotion,
    required this.format,
    this.onChanged,
  });
  final double value;
  final bool playing, reducedMotion;
  final String Function(double) format;
  final ValueChanged<double>? onChanged;

  @override
  State<WaveSeekBar> createState() => _WaveSeekBarState();
}

class _WaveSeekBarState extends State<WaveSeekBar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncMotion();
  }

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
        _foreground &&
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
    WidgetsBinding.instance.removeObserver(this);
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: _WaveRepaint(
      animation: motion,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          trackShape: WaveTrack(
            motion: motion,
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
            semanticFormatterCallback: widget.format,
            onChanged: widget.onChanged,
          ),
        ),
      ),
    ),
  );
}

class WaveTrack extends SliderTrackShape with BaseSliderTrackShape {
  const WaveTrack({double phase = 0, required this.amplitude, this.motion})
    : _initialPhase = phase;
  final double _initialPhase, amplitude;
  final Animation<double>? motion;
  double get phase => motion?.value ?? _initialPhase;
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
    final phase = this.phase;
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

/// Animate the existing slider's paint, without rebuilding its widgets, theme,
/// semantics or gesture recognizers at the display refresh rate.
class _WaveRepaint extends SingleChildRenderObjectWidget {
  const _WaveRepaint({required this.animation, required super.child});
  final Animation<double> animation;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _WaveRenderRepaint(animation);

  @override
  void updateRenderObject(
    BuildContext context,
    _WaveRenderRepaint renderObject,
  ) {
    renderObject.animation = animation;
  }
}

class _WaveRenderRepaint extends RenderProxyBox {
  _WaveRenderRepaint(this._animation);
  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }
}
