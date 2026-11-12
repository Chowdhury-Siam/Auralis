import 'package:flutter/material.dart';

import 'app_popups.dart';

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
