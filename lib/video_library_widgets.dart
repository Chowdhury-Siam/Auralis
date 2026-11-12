part of 'video_library.dart';

class _VideoCollectionPage extends StatelessWidget {
  const _VideoCollectionPage({
    required this.title,
    required this.summary,
    required this.description,
    required this.icon,
    required this.slivers,
    this.onBack,
    this.actions = const [],
    this.embedded = false,
    this.bottomPadding = 28,
  });

  final String title, summary, description;
  final IconData icon;
  final VoidCallback? onBack;
  final List<Widget> actions, slivers;
  final bool embedded;
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
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  embedded ? 8 : 16,
                  embedded ? 4 : 12,
                  embedded ? 8 : 16,
                  20,
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
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
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
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Icon(
                                    icon,
                                    color: colors.onPrimaryContainer,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        style: const TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -.7,
                                          height: 1.15,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        summary,
                                        style: TextStyle(
                                          color: colors.primary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              description,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                            if (actions.isNotEmpty) ...[
                              const SizedBox(height: 18),
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
  const _VideoEmptyCollection(this.title, this.description, this.icon);
  final String title, description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('video-collection-empty'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: colors.primary),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
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
  const _VideoSourcePreview(
    this.source, {
    this.icon = Icons.play_arrow_rounded,
  });
  final VideoSource? source;
  final IconData icon;

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
        child: Icon(icon, size: 32, color: colors.onPrimaryContainer),
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

class _VideoPlaylistCard extends StatelessWidget {
  const _VideoPlaylistCard({
    required this.name,
    required this.sources,
    required this.onOpen,
    required this.onRename,
    required this.onRemove,
  });
  final String name;
  final List<VideoSource> sources;
  final VoidCallback onOpen, onRename, onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final previews = sources
        .where((source) => source.telegram?.coverPreview != null)
        .take(3)
        .toList();
    return Material(
      color: colors.surfaceContainerLow,
      shape: auralisSurfaceShape(colors, radius: 24, borderOpacity: .35),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 112,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Row(
                    children: [
                      for (final source in <VideoSource?>[
                        if (previews.isEmpty) null else ...previews,
                      ])
                        Expanded(
                          child: _VideoSourcePreview(
                            source,
                            icon: Icons.playlist_play_rounded,
                          ),
                        ),
                    ],
                  ),
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: Material(
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(14),
                      child: AuralisPopupMenu<String>(
                        tooltip: 'Playlist options: $name',
                        icon: const Icon(Icons.more_horiz_rounded),
                        onSelected: (action) =>
                            action == 'rename' ? onRename() : onRemove(),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'rename',
                            child: AuralisMenuRow(
                              title: 'Rename',
                              icon: Icons.edit_outlined,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'remove',
                            child: AuralisMenuRow(
                              title: 'Remove',
                              icon: Icons.delete_outline_rounded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${sources.length} ${sources.length == 1 ? 'video' : 'videos'}',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: colors.primary,
                          size: 20,
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
  });
  final VideoSource source;
  final String status;
  final String? date;
  final double? progress;
  final List<Widget> actions;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: auralisSurfaceShape(colors, radius: 22, borderOpacity: .35),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: LayoutBuilder(
            builder: (context, box) {
              final wide =
                  box.maxWidth >= 620 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 20;
              final controls = Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              );
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: wide ? 112 : 64,
                            height: wide ? 78 : 56,
                            child: _VideoSourcePreview(source),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                source.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
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
                              const SizedBox(height: 8),
                              Text(
                                status,
                                style: TextStyle(
                                  color: colors.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (wide) ...[const SizedBox(width: 16), controls],
                      ],
                    ),
                    if (!wide)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: controls,
                      ),
                    if (progress case final double value) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: value,
                        minHeight: 3,
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
    return Material(
      color: colors.surfaceContainerLow,
      shape: auralisSurfaceShape(colors, radius: 24, borderOpacity: .35),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
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
    );
  }
}
