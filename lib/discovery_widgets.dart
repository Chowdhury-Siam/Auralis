import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'models.dart';

(Color, Color) discoveryColors(int index, ColorScheme colors) =>
    switch (index % 5) {
      0 => (colors.primaryContainer, colors.onPrimaryContainer),
      1 => (colors.tertiaryContainer, colors.onTertiaryContainer),
      2 => (colors.tertiaryFixedDim, colors.onTertiaryFixed),
      3 => (colors.secondaryContainer, colors.onSecondaryContainer),
      _ => (colors.secondaryFixedDim, colors.onSecondaryFixed),
    };

class DiscoveryCard extends StatelessWidget {
  const DiscoveryCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: auralisSurfaceShape(colors, borderOpacity: .35),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class DiscoveryHero extends StatelessWidget {
  const DiscoveryHero({
    super.key,
    required this.tracks,
    required this.artwork,
    this.title = 'Your Mix',
    this.emptyIcon = Icons.graphic_eq_rounded,
    required this.description,
    required this.action,
  });
  final List<Track> tracks;
  final Widget Function(Track) artwork;
  final String title;
  final IconData emptyIcon;
  final String description;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(30),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 620;
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                this.title,
                style: TextStyle(
                  fontSize: wide ? 64 : 49,
                  height: 1.02,
                  letterSpacing: -2,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          );
          final intro = Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: tracks.isNotEmpty && !wide
                ? Row(
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 8),
                      action,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 12), action],
                  ),
          );
          final collage = ExcludeSemantics(
            child: SizedBox(
              width: wide ? math.min(420.0, box.maxWidth * .46) : box.maxWidth,
              height: wide ? 205 : 128,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (tracks.isEmpty)
                    Icon(
                      emptyIcon,
                      size: 90,
                      color: colors.primary.withValues(alpha: .32),
                    ),
                  for (var i = tracks.length - 1; i >= 0; i--)
                    Align(
                      alignment: const [
                        Alignment(.04, -.12),
                        Alignment(-.84, .5),
                        Alignment(.88, .47),
                        Alignment(.72, -.8),
                      ][i],
                      child: Transform.rotate(
                        angle: const [-.12, -.20, .19, .26][i],
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(i == 0 ? 30 : 20),
                          child: SizedBox.square(
                            dimension: i == 0
                                ? (wide ? 142 : 102)
                                : (wide ? 78 : 52),
                            child: artwork(tracks[i]),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
          return wide
              ? Row(
                  children: [
                    Expanded(child: intro),
                    collage,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [intro, collage],
                );
        },
      ),
    );
  }
}

SliverGridDelegateWithMaxCrossAxisExtent discoveryGridDelegate(
  BuildContext context,
) => SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 220,
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  mainAxisExtent:
      108 + math.max(0, MediaQuery.textScalerOf(context).scale(18) - 18) * 3,
);

Widget discoveryLayoutButton({
  required bool list,
  required VoidCallback onPressed,
}) => IconButton.filledTonal(
  tooltip: list ? 'Show grid' : 'Show list',
  onPressed: onPressed,
  icon: Icon(list ? Icons.grid_view_rounded : Icons.view_list_rounded),
);

class DiscoveryTile extends StatelessWidget {
  const DiscoveryTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.index,
    required this.onTap,
    this.leading,
    this.list = false,
    this.selected,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final int index;
  final VoidCallback? onTap;
  final Widget? leading;
  final bool list;
  final bool? selected;
  @override
  Widget build(BuildContext context) {
    final (background, foreground) = discoveryColors(
      index,
      Theme.of(context).colorScheme,
    );
    final detail = subtitle;
    final isSelected = selected == true;
    return Semantics(
      selected: selected,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(list ? 16 : 22),
          side: isSelected ? BorderSide(color: foreground) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: list
            ? ListTile(
                leading: leading ?? Icon(icon, color: foreground),
                title: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: detail == null ? null : Text(detail),
                textColor: foreground,
                trailing: selected == false
                    ? null
                    : Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.chevron_right_rounded,
                        color: foreground,
                      ),
                onTap: onTap,
              )
            : InkWell(
                onTap: onTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      right: -10,
                      bottom: -20,
                      child: ExcludeSemantics(
                        child: Transform.rotate(
                          angle: -.18,
                          child: Icon(
                            icon,
                            size: 98,
                            color: foreground.withValues(alpha: .2),
                          ),
                        ),
                      ),
                    ),
                    if (isSelected)
                      PositionedDirectional(
                        top: 10,
                        end: 10,
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: foreground,
                        ),
                      ),
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        12,
                        12,
                        isSelected ? 34 : 12,
                        12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 17,
                                height: 1.12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (detail != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: foreground, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
