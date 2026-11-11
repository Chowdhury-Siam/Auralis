import 'package:flutter/material.dart';

import 'app_theme.dart';

Future<T?> showAuralisDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final theme = Theme.of(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor:
        theme.dialogTheme.barrierColor ??
        auralisDialogTheme(theme.colorScheme).barrierColor,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: builder,
  );
}

/// The common layout for messages, confirmations, forms and compact lists.
class AuralisDialog extends StatelessWidget {
  const AuralisDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.width = 440,
    this.maxWidth,
    this.scrollable = true,
  });

  final Widget title, content;
  final List<Widget> actions;
  final double width;
  final double? maxWidth;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact =
        MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).vertical <
        360;
    return DialogTheme(
      data: theme.dialogTheme.shape != null
          ? theme.dialogTheme
          : auralisDialogTheme(theme.colorScheme),
      child: AlertDialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: compact
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
            : null,
        constraints: maxWidth == null
            ? null
            : BoxConstraints(maxWidth: maxWidth!),
        title: title,
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        titlePadding: EdgeInsets.fromLTRB(
          20,
          compact ? 8 : 18,
          20,
          compact ? 4 : 12,
        ),
        content: SizedBox(width: width, child: content),
        contentPadding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          compact
              ? 8
              : actions.isEmpty
              ? 20
              : 12,
        ),
        actions: actions,
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, compact ? 8 : 16),
        actionsOverflowButtonSpacing: 6,
        scrollable: scrollable,
      ),
    );
  }
}

class AuralisDialogTitle extends StatelessWidget {
  const AuralisDialogTitle(
    this.text, {
    super.key,
    this.leading,
    this.actions = const [],
  });

  final String text;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (leading case final icon?) ...[icon, const SizedBox(width: 10)],
      Expanded(child: Text(text)),
      ...actions,
    ],
  );
}

class AuralisChoiceTile extends StatelessWidget {
  const AuralisChoiceTile({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.enabled = true,
  });

  final Widget title;
  final Widget? subtitle, leading, trailing;
  final VoidCallback? onTap;
  final bool selected, enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      selected: selected,
      selectedTileColor: colors.primaryContainer,
      selectedColor: colors.onPrimaryContainer,
      enabled: enabled,
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing ?? (selected ? const Icon(Icons.check_rounded) : null),
      onTap: onTap,
    );
  }
}

Future<bool?> confirmAuralisAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) => showAuralisDialog<bool>(
  context: context,
  builder: (context) {
    final colors = Theme.of(context).colorScheme;
    return AuralisDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    );
  },
);

class AuralisPopupMenu<T> extends StatelessWidget {
  const AuralisPopupMenu({
    super.key,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
    this.constraints = const BoxConstraints(minWidth: 180, maxWidth: 300),
    this.icon,
    this.child,
    this.enabled = true,
  });

  final String tooltip;
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;
  final BoxConstraints constraints;
  final Widget? icon, child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final popup = auralisPopupMenuTheme(theme.colorScheme);
    return PopupMenuButton<T>(
      tooltip: tooltip,
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      enabled: enabled,
      constraints: constraints,
      color: popup.color,
      shape: popup.shape,
      elevation: popup.elevation,
      shadowColor: popup.shadowColor,
      surfaceTintColor: popup.surfaceTintColor,
      menuPadding: popup.menuPadding,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      clipBehavior: Clip.antiAlias,
      icon: icon,
      child: child,
    );
  }
}

/// Shared content for command and choice rows in anchored menus.
class AuralisMenuRow extends StatelessWidget {
  const AuralisMenuRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.selected,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final bool? selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = selected == true;
    final foreground = !enabled
        ? colors.onSurface.withValues(alpha: .45)
        : active
        ? colors.onPrimaryContainer
        : colors.onSurface;
    return Semantics(
      selected: selected,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? colors.primaryContainer : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            if (selected != null || icon != null) ...[
              SizedBox.square(
                dimension: 26,
                child: active || icon != null
                    ? Icon(
                        active ? Icons.check_rounded : icon,
                        size: 20,
                        color: !enabled
                            ? foreground
                            : active
                            ? colors.onPrimaryContainer
                            : colors.primary,
                      )
                    : null,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (subtitle case final text?) ...[
                    const SizedBox(height: 2),
                    Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: !enabled || active
                            ? foreground
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
