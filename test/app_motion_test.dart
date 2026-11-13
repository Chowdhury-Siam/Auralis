import 'dart:io';

import 'package:auralis/app.dart';
import 'package:auralis/app_motion.dart';
import 'package:auralis/app_theme.dart';
import 'package:auralis/player.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

FixedScrollMetrics metrics({
  double pixels = 0,
  bool horizontal = false,
  bool short = false,
}) => FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: short ? 0 : 1000,
  pixels: pixels,
  viewportDimension: 300,
  devicePixelRatio: 1,
  axisDirection: horizontal ? AxisDirection.right : AxisDirection.down,
);

double scaleOf(WidgetTester tester, Finder root) => tester
    .widget<Transform>(
      find.descendant(of: root, matching: find.byType(Transform)).first,
    )
    .transform
    .entry(0, 0);

bool elastic(ScrollPhysics physics) {
  if (physics is AuralisElasticScrollPhysics) return true;
  return physics.parent != null && elastic(physics.parent!);
}

void main() {
  test(
    'elasticity is vertical, resisted, finite and absent on short pages',
    () {
      const physics = AuralisElasticScrollPhysics();
      expect(physics.applyBoundaryConditions(metrics(), -50), 0);
      expect(
        physics.applyBoundaryConditions(metrics(horizontal: true), -50),
        -50,
      );
      final resisted = physics.applyPhysicsToUserOffset(
        metrics(pixels: -50),
        20,
      );
      expect(resisted, greaterThan(0));
      expect(resisted, lessThan(20));
      final rebound = physics.createBallisticSimulation(
        metrics(pixels: -50),
        0,
      )!;
      expect(rebound.x(3), closeTo(0, .5));
      expect(rebound.isDone(3), isTrue);
      expect(physics.shouldAcceptUserOffset(metrics(short: true)), isFalse);
      expect(
        physics.applyTo(const AlwaysScrollableScrollPhysics()),
        isA<AuralisElasticScrollPhysics>(),
      );
    },
  );

  testWidgets(
    'touch scrolling rebounds, but mouse-wheel movement stays in bounds',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AuralisScrollBehavior(),
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: 40,
              itemBuilder: (_, index) =>
                  SizedBox(height: 60, child: Text('Row $index')),
            ),
          ),
        ),
      );
      final list = find.byType(ListView);
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 140));
      await tester.pump();
      expect(controller.offset, lessThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(0, .5));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, -500),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'spring feedback preserves layout and stops for reduced motion or hidden pages',
    (tester) async {
      var pressed = false, reduced = false, system = false, visible = true;
      late StateSetter update;
      const key = ValueKey('spring');
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AuralisMotion(
                disabled: reduced,
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: system),
                  child: Scaffold(
                    body: Center(
                      child: TickerMode(
                        enabled: visible,
                        child: AuralisSpringScale(
                          key: key,
                          pressed: pressed,
                          child: const SizedBox(width: 120, height: 80),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final spring = find.byKey(key);
      final size = tester.getSize(spring);
      update(() => pressed = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(scaleOf(tester, spring), lessThan(1));
      expect(tester.getSize(spring), size);
      update(() => pressed = false);
      await tester.pumpAndSettle();
      expect(scaleOf(tester, spring), closeTo(1, .0001));
      update(() {
        pressed = true;
        reduced = true;
      });
      await tester.pumpAndSettle();
      expect(scaleOf(tester, spring), 1);
      update(() {
        reduced = false;
        system = true;
      });
      await tester.pumpAndSettle();
      expect(scaleOf(tester, spring), 1);
      update(() {
        system = false;
        visible = false;
      });
      await tester.pumpAndSettle();
      expect(scaleOf(tester, spring), 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final type in ['filled', 'outlined', 'text', 'icon']) {
    testWidgets(
      '$type button press springs once without changing its touch target',
      (tester) async {
        var calls = 0;
        const key = ValueKey('button');
        void callback() {
          calls++;
        }

        final button = switch (type) {
          'filled' => FilledButton(
            key: key,
            onPressed: callback,
            child: const Text('Action'),
          ),
          'outlined' => OutlinedButton(
            key: key,
            onPressed: callback,
            child: const Text('Action'),
          ),
          'text' => TextButton(
            key: key,
            onPressed: callback,
            child: const Text('Action'),
          ),
          _ => IconButton(
            key: key,
            onPressed: callback,
            icon: const Icon(Icons.add),
          ),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
            home: Scaffold(body: Center(child: button)),
          ),
        );
        final target = find.byKey(key);
        final feedback = find.descendant(
          of: target,
          matching: find.byType(AuralisSpringScale),
        );
        expect(feedback, findsOneWidget);
        final before = tester.getSize(target);
        final gesture = await tester.startGesture(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 90));
        expect(scaleOf(tester, feedback), lessThan(1));
        expect(tester.getSize(target), before);
        expect(calls, 0);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(scaleOf(tester, feedback), closeTo(1, .0001));
        final cancelled = await tester.startGesture(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 120));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'disabled buttons and keyboard activation keep native semantics',
    (tester) async {
      var calls = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
          home: Scaffold(
            body: Column(
              children: [
                FilledButton(onPressed: null, child: const Text('Disabled')),
                FilledButton(
                  focusNode: focus,
                  autofocus: true,
                  onPressed: () => calls++,
                  child: const Text('Keyboard'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'card scrolling cancels presses and nested actions do not open the card',
    (tester) async {
      var opens = 0, actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: auralisTheme(ColorScheme.fromSeed(seedColor: Colors.purple)),
          scrollBehavior: const AuralisScrollBehavior(),
          home: Scaffold(
            body: ListView(
              children: [
                AuralisPressFeedback(
                  builder: (_, states) => Material(
                    child: InkWell(
                      statesController: states,
                      onTap: () => opens++,
                      child: SizedBox(
                        height: 120,
                        child: Column(
                          children: [
                            const Text('Open card'),
                            TextButton(
                              onPressed: () => actions++,
                              child: const Text('Nested action'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                for (var index = 0; index < 30; index++)
                  const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Nested action'));
      await tester.pumpAndSettle();
      expect(actions, 1);
      expect(opens, 0);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Open card')),
      );
      await tester.pump(const Duration(milliseconds: 120));
      await gesture.moveBy(const Offset(0, -150));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(actions, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'app-wide physics follows live app and system motion preferences',
    (tester) async {
      final settings = MemorySettings();
      final player = PlayerController(
        FakeAudio(),
        TelegramStreamProxy((_) async => {}),
        settings,
      );
      final telegram = TelegramService(
        Directory('unused'),
        MemoryVault(),
        transport: FakeTd(),
      );
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.shutdown();
        await telegram.shutdown();
      });
      await tester.pumpWidget(AuralisApp(player: player, telegram: telegram));
      await tester.pumpAndSettle();
      ScrollPhysics physics() => tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const PageStorageKey('home-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .physics;
      expect(elastic(physics()), isTrue);
      settings.reducedMotion = true;
      player.refreshSettings();
      await tester.pumpAndSettle();
      expect(elastic(physics()), isFalse);
      settings.reducedMotion = false;
      player.refreshSettings();
      await tester.pumpAndSettle();
      expect(elastic(physics()), isTrue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();
      expect(elastic(physics()), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
