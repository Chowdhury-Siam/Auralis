import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';

(Color, Color) discoveryColors(int index, ColorScheme colors) =>
    switch (index % 5) {
      0 => (colors.primaryContainer, colors.onPrimaryContainer),
      1 => (colors.tertiaryContainer, colors.onTertiaryContainer),
      2 => (const Color(0xFF17474A), const Color(0xFFB3F3EE)),
      3 => (colors.secondaryContainer, colors.onSecondaryContainer),
      _ => (const Color(0xFF55354A), const Color(0xFFFFDBEE)),
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
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
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

class DiscoveryTile extends StatelessWidget {
  const DiscoveryTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.index,
    required this.onTap,
    this.list = false,
  });
  final String title, subtitle;
  final IconData icon;
  final int index;
  final VoidCallback onTap;
  final bool list;
  @override
  Widget build(BuildContext context) {
    final (background, foreground) = discoveryColors(
      index,
      Theme.of(context).colorScheme,
    );
    final open = onTap;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(list ? 16 : 22),
      clipBehavior: Clip.antiAlias,
      child: list
          ? ListTile(
              leading: Icon(icon, color: foreground),
              title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(subtitle),
              textColor: foreground,
              trailing: Icon(Icons.chevron_right_rounded, color: foreground),
              onTap: open,
            )
          : InkWell(
              onTap: open,
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
                  Padding(
                    padding: const EdgeInsets.all(12),
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
                        const SizedBox(height: 5),
                        Text(
                          subtitle,
                          style: TextStyle(color: foreground, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
