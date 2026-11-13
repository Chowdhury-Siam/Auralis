import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Shares the app's motion preference with routes, dialogs and themed controls.
class AuralisMotion extends InheritedWidget {
  const AuralisMotion({
    super.key,
    required this.disabled,
    required super.child,
  });

  final bool disabled;

  static bool disabledOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      (context.dependOnInheritedWidgetOfExactType<AuralisMotion>()?.disabled ??
          false);

  @override
  bool updateShouldNotify(AuralisMotion oldWidget) =>
      disabled != oldWidget.disabled;
}

/// Bounce only for direct vertical scrolling. Paging and horizontal controls
/// retain clamping, and short pages do not become unnecessarily draggable.
class AuralisElasticScrollPhysics extends ClampingScrollPhysics {
  const AuralisElasticScrollPhysics({super.parent});

  static const _bounce = BouncingScrollPhysics(
    decelerationRate: ScrollDecelerationRate.fast,
  );

  @override
  AuralisElasticScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AuralisElasticScrollPhysics(parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      position.axis == Axis.vertical
      ? _bounce.applyPhysicsToUserOffset(position, offset)
      : super.applyPhysicsToUserOffset(position, offset);

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) =>
      position.axis == Axis.vertical
      ? _bounce.applyBoundaryConditions(position, value)
      : super.applyBoundaryConditions(position, value);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => position.axis == Axis.vertical
      ? _bounce.createBallisticSimulation(position, velocity)
      : super.createBallisticSimulation(position, velocity);
}

class AuralisScrollBehavior extends MaterialScrollBehavior {
  const AuralisScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      AuralisMotion.disabledOf(context)
      ? const ClampingScrollPhysics()
      : const AuralisElasticScrollPhysics();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child; // Do not stack Android stretch/glow over the physical bounce.
}

/// Paint-only feedback: the layout and touch/keyboard targets never resize.
class AuralisSpringScale extends StatefulWidget {
  const AuralisSpringScale({
    super.key,
    required this.pressed,
    required this.child,
    this.pressedScale = .96,
  }) : assert(pressedScale > 0 && pressedScale <= 1);

  final bool pressed;
  final double pressedScale;
  final Widget child;

  @override
  State<AuralisSpringScale> createState() => _AuralisSpringScaleState();
}

class _AuralisSpringScaleState extends State<AuralisSpringScale>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController.unbounded(
    vsync: this,
    value: 1,
    animationBehavior: AnimationBehavior.preserve,
  );
  bool? _disabled;
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 600,
    damping: 34,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled =
        AuralisMotion.disabledOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    if (_disabled != disabled) {
      _disabled = disabled;
      _drive();
    }
  }

  @override
  void didUpdateWidget(covariant AuralisSpringScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pressed != oldWidget.pressed ||
        widget.pressedScale != oldWidget.pressedScale) {
      _drive();
    }
  }

  void _drive() {
    if (_disabled == true) {
      _controller.stop();
      _controller.value = 1;
      return;
    }
    final target = widget.pressed ? widget.pressedScale : 1.0;
    if (!_controller.isAnimating &&
        (_controller.value - target).abs() < .0001) {
      return;
    }
    final velocity = _controller.isAnimating
        ? _controller.velocity.clamp(-2.0, 2.0)
        : 0.0;
    _controller.animateWith(
      SpringSimulation(_spring, _controller.value, target, velocity),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (_, child) => Transform.scale(
      scale: _controller.value.clamp(.9, 1.015),
      transformHitTests: false,
      child: child,
    ),
  );
}

/// Connect to the real InkWell/ListTile states instead of adding competing
/// gesture recognizers. Drag cancellation and nested actions stay native.
class AuralisPressFeedback extends StatefulWidget {
  const AuralisPressFeedback({super.key, required this.builder});
  final Widget Function(BuildContext, WidgetStatesController) builder;

  @override
  State<AuralisPressFeedback> createState() => _AuralisPressFeedbackState();
}

class _AuralisPressFeedbackState extends State<AuralisPressFeedback> {
  final _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Set<WidgetState>>(
        valueListenable: _states,
        child: widget.builder(context, _states),
        builder: (_, states, child) => AuralisSpringScale(
          pressed:
              states.contains(WidgetState.pressed) &&
              !states.contains(WidgetState.disabled),
          pressedScale: .985,
          child: child!,
        ),
      );
}

Widget auralisButtonFeedback(
  BuildContext context,
  Set<WidgetState> states,
  Widget? child,
) => AuralisSpringScale(
  pressed:
      states.contains(WidgetState.pressed) &&
      !states.contains(WidgetState.disabled),
  child: child ?? const SizedBox.shrink(),
);
