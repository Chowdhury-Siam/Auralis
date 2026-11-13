import 'dart:ui' as ui;

import 'package:auralis/player_origin_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _PaintCounter extends CustomPainter {
  _PaintCounter(this.onPaint, this.color);
  final VoidCallback onPaint;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
    canvas.drawRect(
      Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _PaintCounter oldDelegate) =>
      color != oldDelegate.color;
}

void main() {
  for (final pixelRatio in [1.0, 2.0]) {
    testWidgets(
      'origin is painted once per snapshot, not each blur frame: DPR $pixelRatio',
      (tester) async {
        tester.view.devicePixelRatio = pixelRatio;
        tester.view.physicalSize = Size(400 * pixelRatio, 300 * pixelRatio);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final dismissal = AnimationController(vsync: tester, value: 1);
        addTearDown(dismissal.dispose);
        var enabled = false, paints = 0, builds = 0;
        var color = Colors.black;
        var width = 160.0;
        final boundary = GlobalKey();
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return Center(
                  child: RepaintBoundary(
                    key: boundary,
                    child: SizedBox(
                      width: width,
                      height: 100,
                      child: PlayerOriginSnapshot(
                        enabled: enabled,
                        dismissal: dismissal,
                        child: Builder(
                          builder: (_) {
                            builds++;
                            return CustomPaint(
                              painter: _PaintCounter(() => paints++, color),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        Future<int> redAt(int x) async => (await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return bytes!.getUint8((50 * image.width + x) * 4);
          } finally {
            image.dispose();
          }
        }))!;

        expect(await redAt(77), 0);
        update(() => enabled = true);
        await tester.pump();
        final snapshot = tester.widget<SnapshotWidget>(
          find.byKey(const ValueKey('player-cached-blur')),
        );
        final frozenPaints = paints, frozenBuilds = builds;
        for (var frame = 1; frame < 20; frame++) {
          dismissal.value = 1 - frame / 20;
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            paints,
            frozenPaints,
            reason: 'Blur frames must use the cached raster',
          );
          expect(
            builds,
            frozenBuilds,
            reason: 'No rebuilds during the blur animation',
          );
        }
        expect(
          await redAt(77),
          inExclusiveRange(0, 255),
          reason: 'The sharp black/white edge is blurred in the cached image',
        );
        expect(
          identical(
            tester
                .widget<SnapshotWidget>(
                  find.byKey(const ValueKey('player-cached-blur')),
                )
                .painter,
            snapshot.painter,
          ),
          isTrue,
        );

        // Geometry changes regenerate the raster once instead of stretching a
        // stale-sized page, including at high device pixel ratios.
        update(() => width = 200);
        await tester.pump();
        expect(paints, frozenPaints + 1);
        final resizedPaints = paints;
        dismissal.value = .5;
        await tester.pump();
        expect(paints, resizedPaints);

        dismissal.value = 0;
        await tester.pump();
        expect(
          tester
              .widget<SnapshotWidget>(
                find.byKey(const ValueKey('player-cached-blur')),
              )
              .controller
              .allowSnapshotting,
          isFalse,
          reason:
              'Do not retain origin textures while the full player is settled',
        );

        // Returning to the origin discards both snapshots and paints fresh state.
        update(() {
          enabled = false;
          color = const Color(0xFFFF0000);
        });
        await tester.pump();
        expect(await redAt(10), 255);
        expect(
          tester
              .widget<SnapshotWidget>(
                find.byKey(const ValueKey('player-cached-blur')),
              )
              .controller
              .allowSnapshotting,
          isFalse,
        );
        update(() => enabled = true);
        dismissal.value = 1;
        await tester.pump();
        expect(await redAt(10), 255);
        await tester.pumpWidget(const SizedBox.shrink());
        dismissal.value = .2;
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
