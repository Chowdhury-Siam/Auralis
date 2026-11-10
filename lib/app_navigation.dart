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
  });
  final AppNavigationStyle style;
  final double radius;
  final int selected;
  final bool reducedMotion;
  final ValueChanged<int> onSelected;
  static const labels = ['Home', 'Search', 'Library'];
  static const icons = [
    Icons.home_rounded,
    Icons.search_rounded,
    Icons.library_music_rounded,
  ];

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
            NavigationDestination(
              icon: Icon(icons[i]),
              label: labels[i],
              tooltip: labels[i],
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
                    child: Semantics(
                      selected: selected == i,
                      button: true,
                      child: Tooltip(
                        message: labels[i],
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
                                  style: Theme.of(context).textTheme.labelSmall
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
              ],
            ),
          ),
        ),
      ),
    );
  }
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
