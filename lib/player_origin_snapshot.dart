import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Freeze the *existing* origin page during the player transition. Do not mount
/// another Home/Library tree (and its artwork, scrollables and subscriptions)
/// on the frame that begins opening.
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
  late final _controller = SnapshotController(
    allowSnapshotting: widget.enabled && widget.dismissal.value > 0,
  );
  late _OriginPainter _painter = _OriginPainter(widget.dismissal);

  @override
  void initState() {
    super.initState();
    widget.dismissal.addListener(_syncSnapshot);
  }

  void _syncSnapshot() {
    final active = widget.enabled && widget.dismissal.value > 0;
    _controller.allowSnapshotting = active;
    // The origin is offstage with a fully expanded player. Do not retain its
    // full-size texture (or the blur) for the duration of an entire song.
    if (!active) _painter.clear();
  }

  @override
  void didUpdateWidget(covariant PlayerOriginSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dismissal != widget.dismissal) {
      oldWidget.dismissal.removeListener(_syncSnapshot);
      _painter.dispose();
      _painter = _OriginPainter(widget.dismissal);
      widget.dismissal.addListener(_syncSnapshot);
    }
    _syncSnapshot();
  }

  @override
  void dispose() {
    widget.dismissal.removeListener(_syncSnapshot);
    _painter.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    key: const ValueKey('player-cached-blur'),
    controller: _controller,
    painter: _painter,
    mode: SnapshotMode.permissive,
    autoresize: true,
    child: widget.child,
  );
}

class _OriginPainter extends SnapshotPainter {
  _OriginPainter(this.dismissal) {
    dismissal.addListener(notifyListeners);
  }

  final Animation<double> dismissal;
  ui.Image? _source, _blurred;
  Size? _sourceSize, _size;
  static final _filter = ui.ImageFilter.blur(
    sigmaX: 8,
    sigmaY: 8,
    tileMode: ui.TileMode.clamp,
  );

  double get _opacity => const Interval(
    .025,
    .24,
    curve: Curves.easeOut,
  ).transform(1 - dismissal.value);

  void clear() {
    _blurred?.dispose();
    _blurred = null;
    _source = null;
    _size = _sourceSize = null;
  }

  ui.Image _blur(ui.Image image, Size sourceSize, Size size) {
    if (!identical(image, _source) ||
        size != _size ||
        sourceSize != _sourceSize) {
      clear();
      // Blur needs no full-resolution texture. Bound both dimensions while
      // retaining the same eight-logical-pixel filter radius when scaled back.
      final scale = math.min(1.0, 1280 / math.max(size.width, size.height));
      final width = math.max(1, (size.width * scale).ceil());
      final height = math.max(1, (size.height * scale).ceil());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(scale);
      canvas.drawImageRect(
        image,
        Offset.zero & sourceSize,
        Offset.zero & size,
        Paint()
          ..imageFilter = _filter
          ..filterQuality = FilterQuality.low,
      );
      final picture = recorder.endRecording();
      try {
        _blurred = picture.toImageSync(width, height);
      } finally {
        picture.dispose();
      }
      _source = image;
      _sourceSize = sourceSize;
      _size = size;
    }
    return _blurred!;
  }

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final opacity = _opacity;
    final destination = offset & size;
    if (opacity < 1) {
      context.canvas.drawImageRect(
        image,
        Offset.zero & sourceSize,
        destination,
        Paint(),
      );
    }
    if (opacity > 0) {
      final blurred = _blur(image, sourceSize, size);
      context.canvas.drawImageRect(
        blurred,
        Offset.zero & Size(blurred.width.toDouble(), blurred.height.toDouble()),
        destination,
        Paint()
          ..color = Colors.white.withValues(alpha: opacity)
          ..filterQuality = FilterQuality.low,
      );
    }
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    // Platform views cannot be snapshotted. Keep them live and unobstructed
    // rather than duplicating the widget subtree or blocking player opening.
    painter(context, offset);
  }

  @override
  bool shouldRepaint(covariant _OriginPainter oldPainter) =>
      oldPainter.dismissal != dismissal;

  @override
  void dispose() {
    dismissal.removeListener(notifyListeners);
    clear();
    super.dispose();
  }
}
