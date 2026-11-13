import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'app_motion.dart';
import 'discovery_widgets.dart';
import 'models.dart';
import 'playlist_photos.dart';
import 'app_popups.dart';

class MusicPlaylistPreview {
  const MusicPlaylistPreview({
    required this.name,
    required this.songCount,
    required this.tracks,
    this.photo,
  });

  final String name;
  final int songCount;
  final List<Track> tracks;
  final String? photo;
}

class MusicPlaylistsView extends StatelessWidget {
  const MusicPlaylistsView({
    super.key,
    required this.playlists,
    required this.artwork,
    required this.onCreate,
    required this.onOpen,
    required this.searching,
    required this.bottomPadding,
    this.video = false,
    this.coverBuilder,
    this.actionsBuilder,
  });

  final List<MusicPlaylistPreview> playlists;
  final Widget Function(Track) artwork;
  final VoidCallback onCreate;
  final ValueChanged<String> onOpen;
  final bool searching;
  final double bottomPadding;
  final bool video;
  final Widget? Function(MusicPlaylistPreview)? coverBuilder;
  final Widget Function(MusicPlaylistPreview)? actionsBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomScrollView(
      key: video
          ? const ValueKey('video-collection-scroll')
          : const PageStorageKey('music-playlists'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
          sliver: SliverToBoxAdapter(
            child: DiscoveryCard(
              key: ValueKey(
                video ? 'video-collection-header' : 'music-playlists-header',
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  final intro = Row(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Icon(
                            Icons.playlist_play_rounded,
                            color: colors.onPrimaryContainer,
                            size: 28,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video ? 'Video playlists' : 'Made for your music',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              video
                                  ? 'Keep your favorite videos together.'
                                  : 'Keep your favorite songs together.',
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                  final create = FilledButton.tonalIcon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Create playlist'),
                  );
                  return box.maxWidth >= 560
                      ? Row(
                          children: [
                            Expanded(child: intro),
                            const SizedBox(width: 20),
                            create,
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [intro, const SizedBox(height: 16), create],
                        );
                },
              ),
            ),
          ),
        ),
        if (playlists.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            sliver: SliverToBoxAdapter(
              child: DiscoveryCard(
                key: ValueKey(
                  video ? 'video-collection-empty' : 'music-playlists-empty',
                ),
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    Icon(
                      searching
                          ? Icons.search_off_rounded
                          : Icons.queue_music_rounded,
                      size: 42,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      searching
                          ? 'No playlists found'
                          : video
                          ? 'Make room for your favorites'
                          : 'Your playlists live here',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      searching
                          ? 'Try another name or clear your search.'
                          : video
                          ? 'Create your first playlist to collect videos for later.'
                          : 'Create a playlist, then add music using a track’s actions.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            sliver: SliverLayoutBuilder(
              builder: (context, box) {
                final extra = math.max(
                  0.0,
                  MediaQuery.textScalerOf(context).scale(16) - 16,
                );
                final columns = ((box.crossAxisExtent + 14) / (260 + extra * 4))
                    .floor()
                    .clamp(1, 3);
                return SliverGrid.builder(
                  itemCount: playlists.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    mainAxisExtent: 260 + extra * 6,
                  ),
                  itemBuilder: (context, index) => MusicPlaylistCard(
                    key: ValueKey((
                      video ? 'video-playlist' : 'music-playlist',
                      playlists[index].name,
                    )),
                    playlist: playlists[index],
                    artwork: artwork,
                    onTap: () => onOpen(playlists[index].name),
                    video: video,
                    cover: coverBuilder?.call(playlists[index]),
                    actions: actionsBuilder?.call(playlists[index]),
                  ),
                );
              },
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
  }
}

class MusicPlaylistCard extends StatelessWidget {
  const MusicPlaylistCard({
    super.key,
    required this.playlist,
    required this.artwork,
    required this.onTap,
    this.video = false,
    this.cover,
    this.actions,
  });

  final MusicPlaylistPreview playlist;
  final Widget Function(Track) artwork;
  final VoidCallback onTap;
  final bool video;
  final Widget? cover, actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final covers = playlist.tracks.take(4).map(artwork).toList();
    Widget coverColumn(List<Widget> children) => Column(
      children: [for (final child in children) Expanded(child: child)],
    );
    final cover = covers.isEmpty
        ? DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colors.primaryContainer, colors.secondaryContainer],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.queue_music_rounded,
                size: 56,
                color: colors.onPrimaryContainer,
              ),
            ),
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: coverColumn(
                  covers.take(covers.length > 2 ? 2 : 1).toList(),
                ),
              ),
              if (covers.length > 1)
                Expanded(
                  child: coverColumn(
                    covers.skip(covers.length > 2 ? 2 : 1).toList(),
                  ),
                ),
            ],
          );
    return AuralisPressFeedback(
      builder: (context, states) => Material(
        color: colors.surfaceContainerLow,
        shape: auralisSurfaceShape(colors, borderOpacity: .35),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          statesController: states,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ExcludeSemantics(
                          child: PlaylistPhoto(
                            token: playlist.photo,
                            fallback: this.cover ?? cover,
                          ),
                        ),
                      ),
                      if (actions != null)
                        PositionedDirectional(top: 6, end: 6, child: actions!),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded, color: colors.primary),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  playlist.songCount == 0
                      ? video
                            ? 'No videos yet'
                            : 'No songs yet'
                      : '${playlist.songCount} ${video ? (playlist.songCount == 1 ? 'video' : 'videos') : (playlist.songCount == 1 ? 'song' : 'songs')}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                if (!video && playlist.tracks.length < playlist.songCount) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${playlist.tracks.length} available in Library',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlaylistCardMenu extends StatelessWidget {
  const PlaylistCardMenu({
    super.key,
    required this.name,
    required this.hasPhoto,
    required this.onChangePhoto,
    required this.onResetPhoto,
    required this.onRename,
    required this.onRemove,
  });
  final String name;
  final bool hasPhoto;
  final VoidCallback onChangePhoto, onResetPhoto, onRename, onRemove;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(14),
    child: AuralisPopupMenu<String>(
      tooltip: 'Playlist options: $name',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (action) {
        switch (action) {
          case 'photo':
            onChangePhoto();
          case 'reset':
            onResetPhoto();
          case 'rename':
            onRename();
          case 'remove':
            onRemove();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'photo',
          child: AuralisMenuRow(
            title: 'Change playlist photo',
            icon: Icons.add_photo_alternate_outlined,
          ),
        ),
        if (hasPhoto)
          const PopupMenuItem(
            value: 'reset',
            child: AuralisMenuRow(
              title: 'Reset photo',
              icon: Icons.restart_alt_rounded,
            ),
          ),
        const PopupMenuItem(
          value: 'rename',
          child: AuralisMenuRow(title: 'Rename', icon: Icons.edit_outlined),
        ),
        const PopupMenuItem(
          value: 'remove',
          child: AuralisMenuRow(
            title: 'Remove',
            icon: Icons.delete_outline_rounded,
          ),
        ),
      ],
    ),
  );
}
