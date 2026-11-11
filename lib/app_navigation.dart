import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'storage.dart';
import 'preference_widgets.dart';

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.style,
    required this.radius,
    required this.selected,
    this.reducedMotion = false,
    required this.onSelected,
    this.onHomeHold,
  });
  final AppNavigationStyle style;
  final double radius;
  final int selected;
  final bool reducedMotion;
  final ValueChanged<int> onSelected;
  final VoidCallback? onHomeHold;
  static const labels = ['Home', 'Search', 'Library'];
  static const icons = [
    Icons.home_rounded,
    Icons.search_rounded,
    Icons.library_music_rounded,
  ];

  Widget _destination(int index, Widget child) =>
      index == 0 && onHomeHold != null
      ? HomeHold(onHold: onHomeHold!, child: child)
      : child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (style == AppNavigationStyle.fullWidth) {
      return NavigationBar(
        height: 80,
        backgroundColor: colors.surfaceContainerLowest,
        selectedIndex: selected,
        onDestinationSelected: onSelected,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          for (var i = 0; i < labels.length; i++)
            _destination(
              i,
              NavigationDestination(
                icon: Icon(icons[i]),
                label: labels[i],
                tooltip: i == 0 && onHomeHold != null ? '' : labels[i],
              ),
            ),
        ],
      );
    }
    final expressive = style == AppNavigationStyle.expressive;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 80,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Material(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: _destination(
                      i,
                      Semantics(
                        selected: selected == i,
                        button: true,
                        child: Tooltip(
                          message: labels[i],
                          triggerMode: i == 0 && onHomeHold != null
                              ? TooltipTriggerMode.manual
                              : null,
                          child: InkWell(
                            onTap: () => onSelected(i),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                AnimatedContainer(
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 200),
                                  width: selected == i ? 56 : 42,
                                  height: expressive ? 28 : 40,
                                  decoration: BoxDecoration(
                                    color: selected == i
                                        ? colors.primaryContainer
                                        : null,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Icon(
                                    icons[i],
                                    size: 21,
                                    color: selected == i
                                        ? colors.onPrimaryContainer
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                                if (expressive)
                                  Text(
                                    labels[i],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: selected == i
                                              ? colors.primary
                                              : colors.onSurfaceVariant,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                        ),
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
}

class HomeHold extends StatelessWidget {
  const HomeHold({super.key, required this.onHold, required this.child});

  final VoidCallback onHold;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    onLongPress: onHold,
    onLongPressHint: 'Open Telegram Video',
    child: RawGestureDetector(
      excludeFromSemantics: true,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 900),
              ),
              (recognizer) => recognizer.onLongPress = onHold,
            ),
      },
      child: child,
    ),
  );
}

class DefaultInterfacePreference extends StatelessWidget {
  const DefaultInterfacePreference({
    super.key,
    required this.value,
    required this.onSelected,
  });
  final AppInterface value;
  final ValueChanged<AppInterface> onSelected;

  @override
  Widget build(BuildContext context) => PreferenceChoice<AppInterface>(
    title: 'Open on startup',
    value: value,
    values: AppInterface.values,
    label: (mode) => mode.label,
    onSelected: onSelected,
  );
}

class AppearancePreferences extends StatelessWidget {
  const AppearancePreferences({
    super.key,
    required this.settings,
    required this.onChanged,
  });
  final AppSettings settings;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Compact library navigation'),
        subtitle: const Text('Choose collections from a single menu.'),
        value: settings.compactLibrary,
        onChanged: (v) {
          settings.compactLibrary = v;
          onChanged();
        },
      ),
      PreferenceChoice<AppNavigationStyle>(
        title: 'App navigation',
        value: settings.navigationStyle,
        values: AppNavigationStyle.values,
        label: (style) => style.label,
        onSelected: (style) {
          settings.navigationStyle = style;
          onChanged();
        },
      ),
      if (settings.navigationStyle != AppNavigationStyle.fullWidth) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              flex: 2,
              child: Text('Corner radius', style: TextStyle(fontSize: 13)),
            ),
            Expanded(
              flex: 3,
              child: Slider(
                value: settings.navigationRadius,
                min: 0,
                max: 40,
                divisions: 8,
                label: settings.navigationRadius.round().toString(),
                onChanged: (v) {
                  settings.navigationRadius = v;
                  onChanged();
                },
              ),
            ),
          ],
        ),
      ],
    ],
  );
}
