import 'package:flutter/material.dart';

import 'models.dart';
import 'storage.dart';

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.style,
    required this.radius,
    required this.selected,
    required this.onSelected,
    required this.onSearch,
  });
  final AppNavigationStyle style;
  final double radius;
  final int selected;
  final ValueChanged<int> onSelected;
  final VoidCallback onSearch;
  static const labels = ['Library', 'Telegram', 'Now playing', 'Settings'];
  static const icons = [
    Icons.library_music_rounded,
    Icons.send_rounded,
    Icons.album_rounded,
    Icons.tune_rounded,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final showLabels = constraints.maxWidth >= 340;
        return SafeArea(
          top: false,
          child: SizedBox(
            height: 80,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Material(
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(radius),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          children: [
                            for (var i = 0; i < labels.length; i++)
                              Expanded(
                                flex:
                                    style == AppNavigationStyle.expressive &&
                                        showLabels &&
                                        selected == i
                                    ? 3
                                    : 1,
                                child: Semantics(
                                  selected: selected == i,
                                  child: Tooltip(
                                    message: labels[i],
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(
                                        radius,
                                      ),
                                      onTap: () => onSelected(i),
                                      child: Container(
                                        height: 52,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            radius,
                                          ),
                                          color: selected == i
                                              ? colors.primaryContainer
                                              : null,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              icons[i],
                                              size: 22,
                                              color: selected == i
                                                  ? colors.onPrimaryContainer
                                                  : colors.onSurfaceVariant,
                                            ),
                                            if (style ==
                                                    AppNavigationStyle
                                                        .expressive &&
                                                showLabels &&
                                                selected == i) ...[
                                              const SizedBox(width: 6),
                                              Flexible(
                                                child: Text(
                                                  labels[i],
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: colors
                                                        .onPrimaryContainer,
                                                  ),
                                                ),
                                              ),
                                            ],
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
                  if (style == AppNavigationStyle.expressive) ...[
                    const SizedBox(width: 8),
                    Material(
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(radius),
                      child: IconButton(
                        tooltip: 'Search library',
                        onPressed: onSearch,
                        constraints: const BoxConstraints.tightFor(
                          width: 52,
                          height: 64,
                        ),
                        icon: const Icon(Icons.search_rounded),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
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
      DropdownButtonFormField<AppNavigationStyle>(
        initialValue: settings.navigationStyle,
        key: ValueKey(settings.navigationStyle),
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'App navigation'),
        items: [
          for (final style in AppNavigationStyle.values)
            DropdownMenuItem(value: style, child: Text(style.label)),
        ],
        onChanged: (v) {
          if (v != null) {
            settings.navigationStyle = v;
            onChanged();
          }
        },
      ),
      if (settings.navigationStyle != AppNavigationStyle.fullWidth) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Corner radius'),
            Expanded(
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
