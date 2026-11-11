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
    this.libraryIcon = Icons.library_music_rounded,
    this.homeHoldHint = 'Open Telegram Video',
  });
  final AppNavigationStyle style;
  final double radius;
  final int selected;
  final bool reducedMotion;
  final ValueChanged<int> onSelected;
  final VoidCallback? onHomeHold;
  final IconData libraryIcon;
  final String homeHoldHint;
  static const labels = ['Home', 'Search', 'Library'];
  static const icons = [
    Icons.home_rounded,
    Icons.search_rounded,
    Icons.library_music_rounded,
  ];

  Widget _destination(int index, Widget child) =>
      index == 0 && onHomeHold != null
      ? HomeHold(onHold: onHomeHold!, hint: homeHoldHint, child: child)
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
                icon: Icon(i == 2 ? libraryIcon : icons[i]),
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
                                      (reducedMotion ||
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          ))
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
                                    i == 2 ? libraryIcon : icons[i],
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
  const HomeHold({
    super.key,
    required this.onHold,
    required this.child,
    this.hint = 'Open Telegram Video',
  });

  final VoidCallback onHold;
  final String hint;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    onLongPress: onHold,
    onLongPressHint: hint,
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

/// Shared desktop navigation for the Music and Video interfaces.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.narrow,
    required this.short,
    required this.selected,
    required this.onSelected,
    required this.onHomeHold,
    this.homeHoldHint = 'Open Telegram Video',
    this.libraryIcon = Icons.library_music_rounded,
    this.icon = Icons.graphic_eq_rounded,
    this.tagline = 'A LITTLE CLOSER TO MUSIC',
    this.caption = 'YOUR MUSIC. YOUR SPACE.\n\nIndependent. Open source.',
    this.onTelegram,
    this.onSettings,
    this.telegramSelected = false,
    this.settingsSelected = false,
  });
  final bool narrow, short, telegramSelected, settingsSelected;
  final int selected;
  final ValueChanged<int> onSelected;
  final VoidCallback onHomeHold;
  final VoidCallback? onTelegram, onSettings;
  final IconData libraryIcon, icon;
  final String tagline, caption, homeHoldHint;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget item(
      int index,
      IconData icon,
      String label,
      VoidCallback open,
      bool active,
    ) {
      Widget child = Tooltip(
        message: label,
        triggerMode: index == 0 ? TooltipTriggerMode.manual : null,
        child: Material(
          color: active ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: open,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: short ? 10 : 16,
              ),
              child: Row(
                mainAxisAlignment: narrow
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Icon(
                    icon,
                    size: 23,
                    color: active ? colors.primary : colors.onSurfaceVariant,
                  ),
                  if (!narrow) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: active
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      if (index == 0) {
        child = HomeHold(onHold: onHomeHold, hint: homeHoldHint, child: child);
      }
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: child);
    }

    return Container(
      width: narrow ? 72 : 202,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border(right: BorderSide(color: colors.surfaceContainerHigh)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: narrow ? 8 : 14,
        vertical: short ? 8 : 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!short)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: colors.primary, size: 30),
                if (!narrow) ...[
                  const SizedBox(width: 10),
                  const Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Auralis',
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.3,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          if (!short) const SizedBox(height: 8),
          if (!narrow && !short)
            Text(
              tagline,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 8,
                letterSpacing: 1.4,
              ),
            ),
          SizedBox(
            height: short
                ? 0
                : narrow
                ? 20
                : 32,
          ),
          Flexible(
            fit: FlexFit.tight,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < AppNavigation.labels.length; i++)
                  item(
                    i,
                    i == 2 ? libraryIcon : AppNavigation.icons[i],
                    AppNavigation.labels[i],
                    () => onSelected(i),
                    selected == i,
                  ),
                if (onTelegram != null)
                  item(
                    3,
                    Icons.send_rounded,
                    'Telegram',
                    onTelegram!,
                    telegramSelected,
                  ),
              ],
            ),
          ),
          if (!narrow && !short)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                caption,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ),
          if (onSettings != null)
            IconButton(
              tooltip: 'Settings',
              onPressed: onSettings,
              style: IconButton.styleFrom(
                backgroundColor: settingsSelected
                    ? colors.primaryContainer
                    : Colors.transparent,
              ),
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
    );
  }
}
