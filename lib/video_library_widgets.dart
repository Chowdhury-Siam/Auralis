part of 'video_library.dart';

class _VideoCollectionPage extends StatelessWidget {
  const _VideoCollectionPage({
    required this.title,
    required this.summary,
    this.description,
    required this.icon,
    required this.slivers,
    this.onBack,
    this.actions = const [],
    this.trailing,
    this.compact = false,
    this.embedded = false,
    this.bottomPadding = 28,
  });

  final String title;
  final String? summary, description;
  final IconData icon;
  final VoidCallback? onBack;
  final List<Widget> actions, slivers;
  final Widget? trailing;
  final bool embedded, compact;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget wrap(Widget child) =>
        embedded ? child : Scaffold(body: SafeArea(child: child));
    return wrap(
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: CustomScrollView(
            key: const ValueKey('video-collection-scroll'),
            physics: slivers.any((sliver) => sliver is SliverReorderableList)
                ? const ClampingScrollPhysics()
                : null,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  embedded ? 8 : 16,
                  embedded ? 4 : 12,
                  embedded ? 8 : 16,
                  compact ? 8 : 20,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!embedded || onBack != null) ...[
                        Row(
                          children: [
                            BackButton(onPressed: onBack),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'VIDEO LIBRARY',
                                style: TextStyle(
                                  color: colors.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      Container(
                        key: const ValueKey('video-collection-header'),
                        padding: EdgeInsets.all(compact ? 8 : 20),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            compact ? 16 : 28,
                          ),
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: .35),
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              colors.primaryContainer.withValues(alpha: .45),
                              colors.surfaceContainerLow,
                            ],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: compact
                                  ? CrossAxisAlignment.center
                                  : CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: EdgeInsets.all(compact ? 8 : 14),
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(
                                      compact ? 10 : 20,
                                    ),
                                  ),
                                  child: Icon(
                                    icon,
                                    color: colors.onPrimaryContainer,
                                    size: compact ? 18 : 28,
                                  ),
                                ),
                                SizedBox(width: compact ? 10 : 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        style: TextStyle(
                                          fontSize: compact ? 18 : 28,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -.7,
                                          height: 1.15,
                                        ),
                                      ),
                                      if (summary case final label?) ...[
                                        SizedBox(height: compact ? 3 : 8),
                                        Text(
                                          label,
                                          style: TextStyle(
                                            color: colors.primary,
                                            fontSize: compact ? 12 : 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                ?trailing,
                              ],
                            ),
                            if (description case final detail?) ...[
                              const SizedBox(height: 16),
                              Text(
                                detail,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (actions.isNotEmpty) ...[
                              SizedBox(height: compact ? 6 : 18),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: actions,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              for (final sliver in slivers)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: embedded ? 8 : 16),
                  sliver: sliver,
                ),
              SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoEmptyCollection extends StatelessWidget {
  const _VideoEmptyCollection(
    this.title,
    this.description,
    this.icon, {
    this.compact = false,
  });
  final String title, description;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final titleStyle =
        (compact
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.titleLarge)
            ?.copyWith(fontWeight: FontWeight.w700);
    return Container(
      key: const ValueKey('video-collection-empty'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 24,
        vertical: compact ? 12 : 36,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(compact ? 16 : 24),
      ),
      child: compact
          ? Row(
              children: [
                Icon(icon, size: 24, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: titleStyle),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              children: [
                Icon(icon, size: 44, color: colors.primary),
                const SizedBox(height: 18),
                Text(title, textAlign: TextAlign.center, style: titleStyle),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Text(
                    description,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
    );
  }
}

Widget _collectionGrid(
  BuildContext context,
  int count,
  Widget Function(BuildContext, int) builder, {
  bool frames = false,
}) => SliverLayoutBuilder(
  builder: (context, box) {
    final extra = math.max(
      0.0,
      MediaQuery.textScalerOf(context).scale(16) - 16,
    );
    final columns = ((box.crossAxisExtent + 16) / (276 + extra * 4))
        .floor()
        .clamp(1, 3);
    final width = (box.crossAxisExtent - 16 * (columns - 1)) / columns;
    return SliverGrid.builder(
      itemCount: count,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        mainAxisExtent: frames
            ? width * 9 / 16 + 116 + extra * 4
            : 250 + extra * 5,
      ),
      itemBuilder: builder,
    );
  },
);

class _VideoSourcePreview extends StatelessWidget {
  const _VideoSourcePreview(this.source);
  final VideoSource? source;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.primaryContainer, colors.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.play_arrow_rounded,
          size: 32,
          color: colors.onPrimaryContainer,
        ),
      ),
    );
    final preview = source?.telegram?.coverPreview;
    return preview == null
        ? fallback
        : Image.memory(
            preview,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
  }
}

class _VideoEntryCard extends StatelessWidget {
  const _VideoEntryCard({
    super.key,
    required this.source,
    required this.status,
    required this.actions,
    required this.onTap,
    this.date,
    this.progress,
    this.artwork,
    this.compact = false,
  });
  final VideoSource source;
  final String status;
  final String? date;
  final double? progress;
  final Widget? artwork;
  final List<Widget> actions;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 6 : 12),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: auralisSurfaceShape(
          colors,
          radius: compact ? 14 : 22,
          borderOpacity: .35,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: LayoutBuilder(
            builder: (context, box) {
              final wide =
                  box.maxWidth >= 620 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 20;
              final controls = Wrap(
                spacing: compact ? 0 : 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              );
              final statusLabel = Text(
                status,
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              );
              return Padding(
                padding: EdgeInsets.all(compact ? 8 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(
                            compact ? 10 : 14,
                          ),
                          child: SizedBox(
                            width: compact ? 44 : (wide ? 112 : 64),
                            height: compact ? 44 : (wide ? 78 : 56),
                            child: artwork ?? _VideoSourcePreview(source),
                          ),
                        ),
                        SizedBox(width: compact ? 8 : 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                source.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    (compact
                                            ? Theme.of(context)
                                                  .textTheme
                                                  .titleSmall
                                            : Theme.of(context)
                                                  .textTheme
                                                  .titleMedium)
                                        ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              SizedBox(height: compact ? 2 : 4),
                              Text(
                                [
                                  source.telegram?.source ?? 'On your device',
                                  ?date,
                                ].join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                              if (!compact || wide) ...[
                                SizedBox(height: compact ? 3 : 8),
                                statusLabel,
                              ],
                            ],
                          ),
                        ),
                        if (wide) ...[const SizedBox(width: 16), controls],
                      ],
                    ),
                    if (!wide && compact)
                      Row(
                        children: [
                          Expanded(child: statusLabel),
                          controls,
                        ],
                      )
                    else if (!wide)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: controls,
                      ),
                    if (progress case final double value) ...[
                      SizedBox(height: compact ? 3 : 12),
                      LinearProgressIndicator(
                        value: value,
                        minHeight: compact ? 2 : 3,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _VideoSnapshotCard extends StatelessWidget {
  const _VideoSnapshotCard({
    super.key,
    required this.file,
    required this.onOpen,
    required this.onDelete,
  });
  final File file;
  final VoidCallback onOpen, onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final position = _snapshotPosition(file);
    return AuralisPressFeedback(
      builder: (context, states) => Material(
        color: colors.surfaceContainerLow,
        shape: auralisSurfaceShape(colors, radius: 24, borderOpacity: .35),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          statesController: states,
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      file,
                      fit: BoxFit.cover,
                      cacheWidth: 720,
                      frameBuilder: (_, child, frame, _) => frame != null
                          ? child
                          : ColoredBox(
                              color: colors.secondaryContainer,
                              child: Icon(
                                Icons.photo_outlined,
                                color: colors.onSecondaryContainer,
                                size: 40,
                              ),
                            ),
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: colors.secondaryContainer,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: colors.onSecondaryContainer,
                          size: 40,
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      top: 10,
                      end: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.scrim.withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            Icons.open_in_full_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _snapshotTitle(file),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              position == null
                                  ? 'PNG image'
                                  : 'Frame at ${clockText(position)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete snapshot',
                            onPressed: onDelete,
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
