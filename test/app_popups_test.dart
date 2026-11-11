import 'package:auralis/app_popups.dart';
import 'package:auralis/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'shared dialog scrolls above the keyboard with actions in reach',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 560);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final colors = ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: Brightness.dark,
      );
      final theme = auralisTheme(colors);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAuralisDialog<void>(
                  context: context,
                  builder: (context) => AuralisDialog(
                    title: const Text('Choose a channel'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var index = 1; index <= 15; index++)
                          AuralisChoiceTile(
                            title: Text('Channel $index'),
                            selected: index == 15,
                            onTap: () => Navigator.pop(context),
                          ),
                      ],
                    ),
                    actions: [
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();

      final material = find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.card,
        ),
      );
      expect(
        tester.widget<Material>(material).color,
        colors.surfaceContainerHigh,
      );
      expect(
        tester.widget<Material>(material).shape,
        theme.popupMenuTheme.shape,
      );

      final done = find.widgetWithText(FilledButton, 'Done');
      expect(done.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(done).dy, lessThan(380));
      final last = find.widgetWithText(ListTile, 'Channel 15');
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(last).selected, isTrue);
      expect(done.hitTestable(), findsOneWidget);
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
