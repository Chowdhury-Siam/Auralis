part of 'video_playback.dart';

Future<T?> _showPlaybackSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black45,
  constraints: BoxConstraints(
    maxWidth: 620,
    maxHeight: MediaQuery.sizeOf(context).height * .9,
  ),
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (context) => SafeArea(top: false, child: builder(context)),
);

class _VideoPanel extends StatelessWidget {
  const _VideoPanel({
    required this.title,
    required this.content,
    this.icon,
    this.detail,
    this.onBack,
    this.actions = const [],
    this.width = 440,
    this.maxHeight = 580,
    this.scrollable = true,
    this.embedded = false,
  });

  final String title;
  final String? detail;
  final IconData? icon;
  final Widget content;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final double width, maxHeight;
  final bool scrollable, embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final short = MediaQuery.sizeOf(context).height < 380;
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: BorderSide(color: colors.outlineVariant),
    );
    final constraints = BoxConstraints(maxWidth: width, maxHeight: maxHeight);
    final body = SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              short ? 4 : 12,
              10,
              short ? 4 : 12,
            ),
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    onPressed: onBack,
                    tooltip: 'Back to player controls',
                    icon: const Icon(Icons.arrow_back_rounded),
                  )
                else if (icon != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(9),
                      child: Icon(
                        icon,
                        size: 20,
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                if (onBack != null || icon != null) const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!short && detail != null)
                        Text(
                          detail!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close panel',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: scrollable
                ? SingleChildScrollView(
                    key: ValueKey(title),
                    primary: false,
                    padding: padding,
                    child: content,
                  )
                : Padding(padding: padding, child: content),
          ),
          if (actions.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 6,
                overflowSpacing: 4,
                children: actions,
              ),
            ),
          ],
        ],
      ),
    );
    if (embedded) {
      return ConstrainedBox(
        constraints: constraints,
        child: Material(
          color: colors.surfaceContainerHigh.withValues(alpha: .98),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: body,
        ),
      );
    }
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: short ? 8 : 24,
      ),
      backgroundColor: colors.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      shape: shape,
      constraints: constraints,
      child: body,
    );
  }
}

class _VideoMenuRow extends StatelessWidget {
  const _VideoMenuRow({
    required this.label,
    required this.icon,
    required this.onTap,
    this.detail,
    this.selected,
    this.trailing,
  });

  final String label;
  final String? detail;
  final IconData icon;
  final VoidCallback onTap;
  final bool? selected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        child: AuralisChoiceTile(
          title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: detail == null
              ? null
              : Text(detail!, maxLines: 2, overflow: TextOverflow.ellipsis),
          leading: Icon(icon, size: 21),
          selected: selected ?? false,
          trailing:
              trailing ??
              Icon(
                switch (selected) {
                  true => Icons.check_circle_outline_rounded,
                  false => Icons.radio_button_unchecked_rounded,
                  null => Icons.chevron_right_rounded,
                },
                size: 19,
                color: selected == true
                    ? colors.onPrimaryContainer
                    : colors.onSurfaceVariant,
              ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _VideoSectionLabel extends StatelessWidget {
  const _VideoSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

class _VideoOption<T> {
  const _VideoOption(
    this.value,
    this.label,
    this.icon, {
    this.detail,
    this.selected,
  });

  final T value;
  final String label;
  final IconData icon;
  final String? detail;
  final bool? selected;

  Widget row(ValueChanged<T> select) => _VideoMenuRow(
    label: label,
    icon: icon,
    detail: detail,
    selected: selected,
    onTap: () => select(value),
  );
}

class _VideoMenuGroup {
  const _VideoMenuGroup(this.title, this.detail, this.icon, this.items);

  final String title, detail;
  final IconData icon;
  final List<_VideoOption<_PanelAction>> items;
}
