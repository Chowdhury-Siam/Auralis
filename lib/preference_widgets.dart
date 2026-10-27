import 'package:flutter/material.dart';

class PreferenceIcon extends StatelessWidget {
  const PreferenceIcon(this.icon, {super.key});
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 20, color: colors.primary),
    );
  }
}

class PreferenceCard extends StatelessWidget {
  const PreferenceCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: child,
      ),
    );
  }
}

/// An anchored, bounded choice menu shared by Library and preferences.
class ChoiceMenu<T> extends StatelessWidget {
  const ChoiceMenu({
    super.key,
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onSelected,
    this.tonal = false,
  });
  final String title;
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final bool tonal;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Integer menu results keep nullable choices distinct from dismissal.
    return PopupMenuButton<int>(
      tooltip: '$title: ${label(value)}',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
      color: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: const Color(0x40000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      clipBehavior: Clip.antiAlias,
      menuPadding: const EdgeInsets.all(6),
      onSelected: (index) => onSelected(values[index]),
      itemBuilder: (_) => [
        for (var i = 0; i < values.length; i++)
          PopupMenuItem<int>(
            value: i,
            padding: EdgeInsets.zero,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: values[i] == value
                    ? colors.primary.withValues(alpha: .12)
                    : null,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: values[i] == value
                        ? Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: colors.primary,
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label(values[i]),
                      style: TextStyle(
                        fontSize: 14,
                        color: values[i] == value
                            ? colors.primary
                            : colors.onSurface,
                        fontWeight: values[i] == value
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tonal ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: tonal ? colors.onPrimaryContainer : colors.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.expand_more_rounded,
              size: 18,
              color: tonal ? colors.onPrimaryContainer : colors.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class PreferenceChoice<T> extends StatelessWidget {
  const PreferenceChoice({
    super.key,
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onSelected,
  });
  final String title;
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(title, style: const TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: ChoiceMenu<T>(
            title: title,
            value: value,
            values: values,
            label: label,
            onSelected: onSelected,
          ),
        ),
      ],
    ),
  );
}
