import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'models.dart';

class LibraryRefresh extends StatefulWidget {
  const LibraryRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<LibraryRefresh> createState() => _LibraryRefreshState();
}

class _LibraryRefreshState extends State<LibraryRefresh> {
  ScrollPhysics? _basePhysics;
  late ScrollPhysics _refreshPhysics;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    final physics = behavior.getScrollPhysics(context);
    // A different physics instance makes Scrollable replace its position.
    // Keep it stable when rows, dock padding or refresh state change.
    if (!identical(_basePhysics, physics)) {
      _basePhysics = physics;
      _refreshPhysics = const AlwaysScrollableScrollPhysics().applyTo(physics);
    }
    return ScrollConfiguration(
      behavior: behavior.copyWith(
        physics: _refreshPhysics,
        dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
      ),
      child: RefreshIndicator(
        notificationPredicate: (notification) =>
            notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical,
        onRefresh: widget.onRefresh,
        child: widget.child,
      ),
    );
  }
}

class LibraryLayout extends StatelessWidget {
  const LibraryLayout({
    super.key,
    required this.collections,
    required this.index,
    required this.onSelected,
    required this.body,
    this.sourceButton,
    this.collectionAction,
    this.moreActions,
    this.onSettings,
    this.menuKey,
    this.titleKey,
    this.indicatorKey,
    this.reducedMotion = false,
    this.keyboardOpen = false,
    this.compactCollection = false,
  });

  final List<(String, IconData)> collections;
  final int index;
  final ValueChanged<int> onSelected;
  final Widget body;
  final Widget? sourceButton, collectionAction, moreActions;
  final VoidCallback? onSettings;
  final Key? menuKey, titleKey, indicatorKey;
  final bool reducedMotion, keyboardOpen, compactCollection;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = collections[index];
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!keyboardOpen && MediaQuery.viewInsetsOf(context).bottom == 0) ...[
          LibraryToolbar(
            collection: LibraryCollectionMenu<int>(
              key: menuKey,
              titleKey: titleKey,
              title: label,
              compact: compactCollection,
              icon: icon,
              tooltip: 'Library collection: $label',
              onSelected: onSelected,
              itemBuilder: (_) => [
                for (final (i, (name, symbol)) in collections.indexed)
                  PopupMenuItem<int>(
                    value: i,
                    padding: EdgeInsets.zero,
                    child: AuralisMenuRow(
                      title: name,
                      icon: symbol,
                      selected: i == index,
                    ),
                  ),
              ],
            ),
            actions: [
              ?sourceButton,
              ?collectionAction,
              if (onSettings != null) ...[
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: 'Settings',
                  style: IconButton.styleFrom(
                    backgroundColor: colors.primaryContainer,
                    foregroundColor: colors.onPrimaryContainer,
                  ),
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                ),
              ],
              ?moreActions,
            ],
          ),
          LibraryPageIndicator(
            key: indicatorKey,
            labels: [for (final (name, _) in collections) name],
            index: index,
            onSelected: onSelected,
            reducedMotion: reducedMotion,
            compact: compactCollection,
          ),
        ],
        Expanded(child: body),
      ],
    );
  }
}

class LibraryToolbar extends StatelessWidget {
  const LibraryToolbar({
    super.key,
    required this.collection,
    required this.actions,
  });

  final Widget collection;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: collection,
        ),
      ),
      ...actions,
    ],
  );
}

typedef LibraryAction = ({
  String label,
  IconData icon,
  VoidCallback? onSelected,
});

class LibraryActionsMenu extends StatelessWidget {
  const LibraryActionsMenu({super.key, required this.actions});

  final List<LibraryAction> actions;

  @override
  Widget build(BuildContext context) => AuralisPopupMenu<int>(
    tooltip: 'Library actions',
    icon: const Icon(Icons.more_vert_rounded, size: 20),
    onSelected: (index) => actions[index].onSelected?.call(),
    itemBuilder: (_) => [
      for (final (index, action) in actions.indexed)
        PopupMenuItem<int>(
          value: index,
          enabled: action.onSelected != null,
          padding: EdgeInsets.zero,
          child: AuralisMenuRow(
            title: action.label,
            icon: action.icon,
            enabled: action.onSelected != null,
          ),
        ),
    ],
  );
}

class LibraryPanel extends StatelessWidget {
  const LibraryPanel({super.key, this.panelKey, required this.child});

  final Key? panelKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    key: panelKey,
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: child,
    ),
  );
}

class LibraryContentPanel extends StatelessWidget {
  const LibraryContentPanel({
    super.key,
    this.panelKey,
    this.search,
    this.details = const [],
    this.loading = false,
    required this.body,
  });

  final Key? panelKey;
  final Widget? search;
  final List<Widget> details;
  final bool loading;
  final Widget body;

  @override
  Widget build(BuildContext context) => LibraryPanel(
    panelKey: panelKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?search,
        ...details,
        if (search != null || details.isNotEmpty) const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: body),
      ],
    ),
  );
}

class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.fieldKey,
    this.onChanged,
    this.onCleared,
    this.autocorrect = true,
  });

  final TextEditingController controller;
  final Key? fieldKey;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onCleared;
  final bool autocorrect;

  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    autocorrect: autocorrect,
    textInputAction: TextInputAction.search,
    onChanged: onChanged,
    onSubmitted: (_) => FocusScope.of(context).unfocus(),
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      suffixIcon: controller.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear search',
              onPressed: () {
                controller.clear();
                onCleared?.call();
              },
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
    ),
  );
}

class LibrarySortMenu extends StatelessWidget {
  const LibrarySortMenu({
    super.key,
    required this.selected,
    required this.options,
    required this.onSelected,
  });

  final LibrarySort selected;
  final Iterable<LibrarySort> options;
  final ValueChanged<LibrarySort> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AuralisPopupMenu<LibrarySort>(
      tooltip: 'Sort Library',
      itemBuilder: (_) => [
        for (final sort in options)
          PopupMenuItem<LibrarySort>(
            value: sort,
            padding: EdgeInsets.zero,
            child: AuralisMenuRow(
              title: sort.label,
              selected: selected == sort,
            ),
          ),
      ],
      onSelected: onSelected,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Ink(
          width: 48,
          height: 40,
          decoration: BoxDecoration(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.sort_rounded,
            color: colors.onSecondaryContainer,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class LibrarySortButton extends StatelessWidget {
  const LibrarySortButton({
    super.key,
    required this.selected,
    required this.options,
    required this.onSelected,
  });

  final LibrarySort selected;
  final Iterable<LibrarySort> options;
  final ValueChanged<LibrarySort> onSelected;

  Future<void> choose(BuildContext context) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final sort = await showAuralisDialog<LibrarySort>(
      context: context,
      builder: (context) => AuralisDialog(
        title: const Text('Library sort order'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final option in options)
              AuralisChoiceTile(
                selected: option == selected,
                title: Text(option.label),
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (context.mounted && sort != null && sort != selected) onSelected(sort);
  }

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    tooltip: 'Sort Library',
    onPressed: () => choose(context),
    icon: const Icon(Icons.sort_rounded, size: 20),
  );
}

class MusicLibraryRow extends StatelessWidget {
  const MusicLibraryRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.artwork,
    required this.onTap,
    this.titleKey,
    this.trailing,
    this.active = false,
  });

  final String title, subtitle;
  final Widget artwork;
  final VoidCallback onTap;
  final Key? titleKey;
  final Widget? trailing;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: active ? colors.surfaceContainerHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onTap: onTap,
        leading: SizedBox.square(dimension: 42, child: artwork),
        title: Text(
          title,
          key: titleKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? colors.primary : null,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
        trailing: trailing,
      ),
    );
  }
}

/// Shared paging behavior for the existing Music and Video collections.
class LibraryCollectionPager extends StatefulWidget {
  const LibraryCollectionPager({
    super.key,
    required this.index,
    required this.count,
    required this.onChanged,
    required this.itemBuilder,
    this.reducedMotion = false,
  });

  final int index, count;
  final ValueChanged<int> onChanged;
  final IndexedWidgetBuilder itemBuilder;
  final bool reducedMotion;

  @override
  State<LibraryCollectionPager> createState() => _LibraryCollectionPagerState();
}

class _LibraryCollectionPagerState extends State<LibraryCollectionPager> {
  late final _controller = PageController(initialPage: widget.index);
  int? _target;
  int? _reported;

  @override
  void didUpdateWidget(covariant LibraryCollectionPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index) return;
    if (_reported == widget.index) {
      _reported = null;
      return;
    }
    final target = widget.index;
    _target = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_controller.hasClients ||
          widget.index != target ||
          _target != target) {
        return;
      }
      if (widget.reducedMotion || MediaQuery.disableAnimationsOf(context)) {
        _controller.jumpToPage(target);
      } else {
        _controller.animateToPage(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollStartNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 && notification.dragDetails != null) {
            _target = null;
          }
          return false;
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
          ),
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.count,
            onPageChanged: (index) {
              if (_target != null) {
                if (_target == index) _target = null;
                return;
              }
              if (widget.index != index) {
                _reported = index;
                widget.onChanged(index);
              }
            },
            itemBuilder: (context, index) => _LibraryCollectionPage(
              child: _LibraryPageVisibility(
                controller: _controller,
                index: index,
                fallback: widget.index,
                child: widget.itemBuilder(context, index),
              ),
            ),
          ),
        ),
      );
}

/// Only the visible/offstage crossing changes widgets, not every scroll pixel.
/// PageView still lays out and animates each frame with the original timing.
class _LibraryPageVisibility extends StatefulWidget {
  const _LibraryPageVisibility({
    required this.controller,
    required this.index,
    required this.fallback,
    required this.child,
  });
  final PageController controller;
  final int index, fallback;
  final Widget child;

  @override
  State<_LibraryPageVisibility> createState() => _LibraryPageVisibilityState();
}

class _LibraryPageVisibilityState extends State<_LibraryPageVisibility> {
  late bool _visible;
  bool get _isVisible {
    final controller = widget.controller;
    final page =
        controller.hasClients && controller.position.hasContentDimensions
        ? controller.page ?? widget.fallback.toDouble()
        : widget.fallback.toDouble();
    return (page - widget.index).abs() < .9999;
  }

  @override
  void initState() {
    super.initState();
    _visible = _isVisible;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(_LibraryPageVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _visible = _isVisible;
  }

  void _changed() {
    final visible = _isVisible;
    if (_visible != visible) setState(() => _visible = visible);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !_visible,
    child: TickerMode(enabled: _visible, child: widget.child),
  );
}

class _LibraryCollectionPage extends StatefulWidget {
  const _LibraryCollectionPage({required this.child});
  final Widget child;

  @override
  State<_LibraryCollectionPage> createState() => _LibraryCollectionPageState();
}

class _LibraryCollectionPageState extends State<_LibraryCollectionPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class LibraryPageIndicator extends StatelessWidget {
  const LibraryPageIndicator({
    super.key,
    required this.labels,
    required this.index,
    required this.onSelected,
    this.reducedMotion = false,
    this.compact = false,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onSelected;
  final bool reducedMotion;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (page, label) in labels.indexed)
          Tooltip(
            message: 'Show $label',
            child: Semantics(
              button: true,
              selected: index == page,
              label: '$label, collection ${page + 1} of ${labels.length}',
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onSelected(page),
                child: SizedBox(
                  width: 32,
                  height: compact ? 24 : 28,
                  child: Center(
                    child: AnimatedContainer(
                      duration:
                          reducedMotion ||
                              MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      width: index == page ? 22 : 8,
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: index == page
                            ? colors.primary
                            : colors.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The collection selector shared by Music and Video Library.
class LibraryCollectionMenu<T> extends StatelessWidget {
  const LibraryCollectionMenu({
    super.key,
    required this.title,
    required this.icon,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
    this.titleKey,
    this.compact = false,
  });

  final String title, tooltip;
  final IconData icon;
  final PopupMenuItemBuilder<T> itemBuilder;
  final ValueChanged<T> onSelected;
  final Key? titleKey;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = colors.primaryContainer;
    final foreground = colors.onPrimaryContainer;
    const outer = Radius.circular(32), inner = Radius.circular(6);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 160;
        const height = 52.0;
        return AuralisPopupMenu<T>(
          tooltip: tooltip,
          constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
          itemBuilder: itemBuilder,
          onSelected: onSelected,
          child: compact
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 32),
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 7, 4),
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            key: titleKey,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: foreground,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 16,
                          color: foreground,
                        ),
                      ],
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Container(
                        constraints: BoxConstraints(minHeight: height),
                        padding: EdgeInsets.symmetric(
                          horizontal: narrow ? 10 : 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: background,
                          borderRadius:
                              const BorderRadiusDirectional.horizontal(
                                start: outer,
                                end: inner,
                              ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!narrow) ...[
                              Icon(icon, color: foreground, size: 22),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                title,
                                key: titleKey,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: foreground,
                                  fontSize: narrow ? 19 : 25,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: narrow ? 36 : 48,
                      height: height,
                      decoration: BoxDecoration(
                        color: background,
                        borderRadius: const BorderRadiusDirectional.horizontal(
                          start: inner,
                          end: outer,
                        ),
                      ),
                      child: Icon(Icons.expand_more_rounded, color: foreground),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
