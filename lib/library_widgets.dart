import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import 'app_popups.dart';

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
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onSelected;
  final bool reducedMotion;

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
                  height: 28,
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

/// The split collection heading shared by Music and Video Library.
class LibraryCollectionMenu<T> extends StatelessWidget {
  const LibraryCollectionMenu({
    super.key,
    required this.title,
    required this.icon,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
    this.titleKey,
  });

  final String title, tooltip;
  final IconData icon;
  final PopupMenuItemBuilder<T> itemBuilder;
  final ValueChanged<T> onSelected;
  final Key? titleKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = colors.primaryContainer;
    final foreground = colors.onPrimaryContainer;
    const outer = Radius.circular(32), inner = Radius.circular(6);
    return AuralisPopupMenu<T>(
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: background,
                borderRadius: const BorderRadiusDirectional.horizontal(
                  start: outer,
                  end: inner,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: foreground, size: 22),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      key: titleKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 25,
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
            width: 48,
            height: 52,
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
  }
}
