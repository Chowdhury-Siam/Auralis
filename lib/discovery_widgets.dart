import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'app_motion.dart';
import 'models.dart';

(Color, Color) discoveryColors(int index, ColorScheme colors) =>
    switch (index % 5) {
      0 => (colors.primaryContainer, colors.onPrimaryContainer),
      1 => (colors.tertiaryContainer, colors.onTertiaryContainer),
      2 => (colors.tertiaryFixedDim, colors.onTertiaryFixed),
      3 => (colors.secondaryContainer, colors.onSecondaryContainer),
      _ => (colors.secondaryFixedDim, colors.onSecondaryFixed),
    };

({List<MusicChat> channels, bool checking}) matchingBrowseChannels(
  Iterable<MusicChat> candidates,
  String query,
  bool? Function(MusicChat) hasMedia,
) {
  final channels = <MusicChat>[];
  var checking = false;
  for (final channel in candidates) {
    if (!channel.title.toLowerCase().contains(query)) continue;
    final matches = hasMedia(channel);
    if (matches == null) checking = true;
    if (matches == true) channels.add(channel);
  }
  channels.sort(
    (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
  );
  return (channels: channels, checking: checking);
}

class BrowseChannelsHeader extends StatelessWidget {
  const BrowseChannelsHeader({super.key, required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: colors.primaryContainer,
          ),
          child: Icon(
            Icons.tag_rounded,
            size: 21,
            color: colors.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            MediaQuery.textScalerOf(context).scale(20) > 30
                ? 'Browse'
                : 'Browse channels',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -.35,
            ),
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'Search channels',
          icon: const Icon(Icons.search_rounded, size: 20),
          onPressed: onSearch,
        ),
      ],
    );
  }
}

class InlineSearchField extends StatelessWidget {
  const InlineSearchField({
    super.key,
    this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.onClose,
    this.hint = 'Search channels',
    this.clearTooltip = 'Clear channel search',
    this.onChanged,
    this.onSubmitted,
    this.onCleared,
  });

  final Key? fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClose;
  final String hint, clearTooltip;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onCleared;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            enabledBorder: auralisFieldBorder(radius: 24),
            focusedBorder: auralisFieldBorder(
              radius: 24,
              side: BorderSide(color: Theme.of(context).colorScheme.primary),
            ),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: clearTooltip,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      controller.clear();
                      onCleared?.call();
                    },
                  ),
          ),
        ),
      ),
      const SizedBox(width: 4),
      TextButton(onPressed: onClose, child: const Text('Cancel')),
    ],
  );
}

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

class ChannelMediaCount extends StatelessWidget {
  const ChannelMediaCount({
    super.key,
    required this.count,
    required this.estimate,
    required this.unit,
    required this.selected,
    required this.builder,
  });

  final int? count;
  final Future<int?> Function() estimate;
  final String unit;
  final bool selected;
  final Widget Function(String? subtitle) builder;

  String _label(int count) => '$count ${count == 1 ? unit : '${unit}s'}';

  @override
  Widget build(BuildContext context) {
    final exact = count;
    if (exact != null) return builder(_label(exact));
    return FutureBuilder<int?>(
      future: estimate(),
      builder: (context, snapshot) {
        final approximate = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        return builder(
          approximate != null && approximate > 0
              ? '≈ ${_label(approximate)}'
              : selected
              ? 'Selected in Library'
              : null,
        );
      },
    );
  }
}

class DiscoveryTile extends StatelessWidget {
  const DiscoveryTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.index,
    required this.onTap,
    this.onLongPress,
    this.selected,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final int index;
  final VoidCallback? onTap, onLongPress;
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
      child: AuralisPressFeedback(
        builder: (context, states) => Material(
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: isSelected ? BorderSide(color: foreground) : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            statesController: states,
            onTap: onTap,
            onLongPress: onLongPress,
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
      ),
    );
  }
}
