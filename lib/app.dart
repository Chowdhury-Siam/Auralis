import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'lyrics.dart';
import 'lyrics_view.dart';
import 'player.dart';
import 'telegram/telegram_service.dart';
import 'telegram/channel_library.dart';
import 'updater.dart';
import 'update_widgets.dart';
import 'wave_seek_bar.dart';
import 'data_files.dart';
import 'stats_view.dart';

const accent = Color(0xFFC7B5FF),
    surface = Color(0xFF19171E),
    muted = Color(0xFFAAA4B5);

class AuralisApp extends StatelessWidget {
  const AuralisApp({
    super.key,
    required this.player,
    required this.telegram,
    this.startupWarning,
    this.updater,
    this.dataFiles = const DataFiles(),
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final AppUpdater? updater;
  final DataFiles dataFiles;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Auralis',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Segoe UI',
      scaffoldBackgroundColor: const Color(0xFF111015),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        surface: surface,
        primary: accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF211E28),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      dividerColor: const Color(0xFF302B39),
    ),
    home: PlayerShell(
      player: player,
      telegram: telegram,
      startupWarning: startupWarning,
      updater: updater,
      dataFiles: dataFiles,
    ),
  );
}

class PlayerShell extends StatefulWidget {
  const PlayerShell({
    super.key,
    required this.player,
    required this.telegram,
    this.startupWarning,
    this.updater,
    this.dataFiles = const DataFiles(),
  });
  final PlayerController player;
  final TelegramService telegram;
  final String? startupWarning;
  final AppUpdater? updater;
  final DataFiles dataFiles;
  @override
  State<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends State<PlayerShell> {
  int destination = 0;
  bool showLyrics = false;
  String collection = 'All songs';
  String? selectedPlaylist;
  final lyrics = LyricsRepository();
  final search = TextEditingController();
  late final ChannelLibrary library;
  PlayerController get player => widget.player;
  TelegramService get telegram => widget.telegram;
  @override
  void initState() {
    super.initState();
    library = ChannelLibrary(telegram, player.settings);
    search.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    lyrics.close();
    library.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> _stats({bool backup = false}) async {
    await player.flushListeningStats();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => StatsDataDialog(
        player: player,
        telegram: telegram,
        files: widget.dataFiles,
        openBackupSection: backup,
        onRestored: () async {
          setState(() {
            selectedPlaylist = null;
            collection = 'All songs';
          });
          await library.refresh();
        },
      ),
    );
  }

  void _openTelegram() {
    setState(() {
      search.clear();
      destination = 1;
    });
  }

  void _notice(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([player, telegram, library]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final immersiveLyrics = destination == 3 && showLyrics;
        final compact = box.maxWidth < 900;
        final narrow = box.maxWidth < 1180;
        final short = box.maxHeight < 560;
        final wide = box.maxWidth >= 1220 && box.maxHeight >= 620;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
                player.restoringData ? null : unawaited(player.audio.toggle()),
            const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
                unawaited(player.next()),
            const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
                unawaited(player.previous()),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: immersiveLyrics ? lyricsBackground : null,
              bottomNavigationBar: compact && destination != 3
                  ? _bottomNavigation()
                  : null,
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          if (!compact && !immersiveLyrics)
                            _navigation(narrow, short: short),
                          Expanded(
                            child: Padding(
                              padding: immersiveLyrics
                                  ? EdgeInsets.zero
                                  : EdgeInsets.fromLTRB(
                                      narrow ? 16 : 30,
                                      short ? 12 : 26,
                                      narrow ? 16 : 26,
                                      0,
                                    ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (!(destination == 3 && showLyrics)) ...[
                                    _header(narrow, short: short),
                                    SizedBox(height: short ? 10 : 22),
                                  ],
                                  if (widget.updater != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: UpdateBanner(
                                        updater: widget.updater!,
                                      ),
                                    ),
                                  if (widget.startupWarning != null)
                                    _banner(widget.startupWarning!),
                                  if (player.error ?? player.audio.error
                                      case final String error)
                                    _banner(error),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      // The dock/nav reappear on exit. Fade in the
                                      // new page without squeezing an outgoing
                                      // full player into its smaller viewport.
                                      layoutBuilder: (current, _) =>
                                          current ?? const SizedBox.shrink(),
                                      duration: Duration(
                                        milliseconds:
                                            player.settings.reducedMotion ||
                                                MediaQuery.disableAnimationsOf(
                                                  context,
                                                )
                                            ? 0
                                            : 180,
                                      ),
                                      child: KeyedSubtree(
                                        key: ValueKey((
                                          destination,
                                          showLyrics,
                                        )),
                                        child: switch (destination) {
                                          0 => _library(),
                                          1 => _telegram(),
                                          2 => _queue(),
                                          _ =>
                                            showLyrics
                                                ? LyricsView(
                                                    player: player,
                                                    repository: lyrics,
                                                    files: widget.dataFiles,
                                                    loadEmbedded:
                                                        telegram.embeddedLyrics,
                                                    artwork: Artwork(
                                                      seed:
                                                          player
                                                              .current
                                                              ?.title ??
                                                          'Auralis',
                                                      telegram: telegram,
                                                      track: player.current,
                                                    ),
                                                    onBack: () => setState(() {
                                                      showLyrics = false;
                                                    }),
                                                  )
                                                : _nowPlaying(),
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (wide && destination != 3)
                            Container(
                              width: (box.maxWidth * .23).clamp(280, 360),
                              margin: const EdgeInsets.fromLTRB(0, 20, 20, 20),
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: surface,
                                borderRadius: BorderRadius.circular(28),
                              ),
                              child: _nowPlaying(compact: true),
                            ),
                        ],
                      ),
                    ),
                    if (destination != 3 && player.current != null)
                      _transport(box.maxWidth < 600),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _bottomNavigation() => NavigationBar(
    height: 56,
    selectedIndex: destination,
    labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
    onDestinationSelected: (i) {
      if (i == 4) {
        _settings();
        return;
      }
      setState(() {
        destination = i;
        search.clear();
      });
    },
    destinations: const [
      NavigationDestination(
        icon: Icon(Icons.library_music_rounded),
        label: 'Library',
        tooltip: 'Library',
      ),
      NavigationDestination(
        icon: Icon(Icons.send_rounded),
        label: 'Telegram',
        tooltip: 'Telegram',
      ),
      NavigationDestination(
        icon: Icon(Icons.queue_music_rounded),
        label: 'Play queue',
        tooltip: 'Play queue',
      ),
      NavigationDestination(
        icon: Icon(Icons.album_rounded),
        label: 'Now playing',
        tooltip: 'Now playing',
      ),
      NavigationDestination(
        icon: Icon(Icons.tune_rounded),
        label: 'Settings',
        tooltip: 'Settings',
      ),
    ],
  );

  Widget _navigation(bool narrow, {bool short = false}) => Container(
    width: narrow ? 72 : 202,
    decoration: const BoxDecoration(
      color: Color(0xFF17151B),
      border: Border(right: BorderSide(color: Color(0xFF26222E))),
    ),
    padding: EdgeInsets.symmetric(
      horizontal: narrow ? 8 : 14,
      vertical: short ? 8 : 16,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!short)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.graphic_eq_rounded, color: accent, size: 30),
              if (!narrow) ...[
                const SizedBox(width: 10),
                const Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Auralis',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.3,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        if (!short) const SizedBox(height: 8),
        if (!narrow && !short)
          const Text(
            'A LITTLE CLOSER TO MUSIC',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 8, letterSpacing: 1.4),
          ),
        SizedBox(
          height: short
              ? 0
              : narrow
              ? 20
              : 32,
        ),
        for (final (i, icon, label) in [
          (0, Icons.library_music_rounded, 'Library'),
          (1, Icons.send_rounded, 'Telegram'),
          (2, Icons.queue_music_rounded, 'Play queue'),
          (3, Icons.album_rounded, 'Now playing'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Tooltip(
              message: label,
              child: Material(
                color: destination == i
                    ? const Color(0xFF332B45)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => setState(() {
                    destination = i;
                    search.clear();
                  }),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: short ? 10 : 16,
                    ),
                    child: Row(
                      mainAxisAlignment: narrow
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Icon(
                          icon,
                          color: destination == i ? accent : muted,
                          size: 23,
                        ),
                        if (!narrow) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: destination == i ? accent : muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        if (!narrow && !short)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'YOUR MUSIC. YOUR SPACE.\n\nIndependent. Open source.',
              style: TextStyle(color: muted, fontSize: 10, height: 1.4),
            ),
          ),
        IconButton(
          onPressed: _settings,
          tooltip: 'Settings',
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    ),
  );

  Widget _header(bool narrow, {bool short = false}) => destination == 3
      ? Row(
          children: [
            IconButton.filledTonal(
              tooltip: 'Back to Library',
              onPressed: () => setState(() {
                destination = 0;
              }),
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Now playing',
                key: ValueKey('page-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: MediaQuery.sizeOf(context).width < 900 ? _settings : _stats,
              tooltip: MediaQuery.sizeOf(context).width < 900 ? 'Settings' : 'Listening stats',
              icon: Icon(MediaQuery.sizeOf(context).width < 900
                ? Icons.tune_rounded : Icons.bar_chart_rounded),
            ),
            IconButton.filledTonal(
              key: const ValueKey('now-playing-queue'),
              tooltip: 'Queue',
              onPressed: () => setState(() {
                destination = 2;
                showLyrics = false;
              }),
              icon: const Icon(Icons.queue_music_rounded),
            ),
          ],
        )
      : Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!short)
                    Text(
                      [
                        'YOUR COLLECTION',
                        'MUSIC IN YOUR CHANNELS',
                        'KEEP THE GOOD ONES GOING',
                        'IN THE MOMENT',
                      ][destination],
                      style: const TextStyle(
                        fontSize: 9,
                        letterSpacing: 1.7,
                        color: accent,
                      ),
                    ),
                  if (!short) const SizedBox(height: 7),
                  Text(
                    key: const ValueKey('page-title'),
                    [
                      'Library',
                      'Telegram',
                      'Play queue',
                      'Now playing',
                    ][destination],
                    style: TextStyle(
                      fontSize: short
                          ? 24
                          : narrow
                          ? 28
                          : 36,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -1.4,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _stats,
              tooltip: 'Listening stats',
              icon: const Icon(Icons.bar_chart_rounded),
            ),
            if (destination == 0) ...[
              if (short)
                IconButton(
                  tooltip: 'Refresh Library',
                  onPressed: !telegram.ready || library.saving
                      ? null
                      : () {
                          telegram.clearImageCache();
                          unawaited(library.refresh());
                        },
                  icon: const Icon(Icons.refresh_rounded),
                ),
              PopupMenuButton<LibrarySort>(
                tooltip: 'Sort Library',
                icon: const Icon(Icons.sort_rounded),
                position: PopupMenuPosition.under,
                offset: const Offset(0, 6),
                color: surface,
                surfaceTintColor: Colors.transparent,
                elevation: 4,
                shadowColor: const Color(0x40000000),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Color(0xFF302B39)),
                ),
                clipBehavior: Clip.antiAlias,
                itemBuilder: (context) => [
                  for (final sort in LibrarySort.values)
                    CheckedPopupMenuItem(
                      value: sort,
                      checked: player.settings.librarySort == sort,
                      child: Text(
                        sort.label,
                        style: TextStyle(
                          color: player.settings.librarySort == sort
                              ? accent
                              : null,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
                onSelected: (sort) async {
                  setState(() => player.settings.librarySort = sort);
                  try {
                    await player.settings.save();
                  } catch (_) {
                    _notice(
                      'Sort changed for this session. Could not save your preference.',
                    );
                  }
                },
              ),
              IconButton(
                onPressed: _openTelegram,
                tooltip: 'Choose channels',
                icon: const Icon(Icons.playlist_add_rounded),
              ),
            ],
          ],
        );
  Widget _banner(String text) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF3C2730),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xFFFFCDD8), fontSize: 12),
    ),
  );
  Widget _search(String hint) => TextField(
    controller: search,
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      suffixIcon: search.text.isEmpty
          ? null
          : IconButton(
              onPressed: search.clear,
              tooltip: 'Clear search',
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
    ),
  );

  Future<String?> _editPlaylist({String? previous}) => showDialog<String>(
    context: context,
    builder: (dialogContext) {
      var name = previous ?? '';
      String? error;
      var busy = false;
      return StatefulBuilder(
        builder: (context, update) {
          Future<void> submit() async {
            if (busy) return;
            update(() {
              busy = true;
              error = null;
            });
            try {
              final saved = previous == null
                  ? await player.createPlaylist(name)
                  : await player.renamePlaylist(previous, name);
              if (dialogContext.mounted) Navigator.pop(dialogContext, saved);
            } catch (e) {
              if (dialogContext.mounted) {
                update(() {
                  busy = false;
                  error = e is ArgumentError
                      ? '${e.message}'
                      : e is StateError
                      ? e.message
                      : 'Could not save this playlist.';
                });
              }
            }
          }

          return AlertDialog(
            title: Text(
              previous == null ? 'Create playlist' : 'Rename playlist',
            ),
            content: SizedBox(
              width: 360,
              child: TextFormField(
                initialValue: previous,
                autofocus: true,
                maxLength: 60,
                enabled: !busy,
                onChanged: (value) => name = value,
                onFieldSubmitted: (_) => unawaited(submit()),
                decoration: InputDecoration(
                  labelText: 'Playlist name',
                  errorText: error,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(previous == null ? 'Create' : 'Rename'),
              ),
            ],
          );
        },
      );
    },
  );

  Future<void> _choosePlaylist(Track track) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist'),
        children: [
          for (final entry in player.settings.playlists.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(
                '${entry.key} · ${entry.value.length}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text(
              'Create playlist',
              style: TextStyle(color: accent),
            ),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    final name = selected.isEmpty ? await _editPlaylist() : selected;
    if (!mounted || name == null) return;
    try {
      await player.addToPlaylist(name, track);
      _notice('Added to $name');
    } on StateError catch (e) {
      _notice(e.message);
    }
  }

  Future<void> _deletePlaylist(String name) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Remove “$name” from this device? The music in Telegram is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    await player.deletePlaylist(name);
    if (mounted) setState(() => selectedPlaylist = null);
  }

  Widget _sleepControl({Key? key}) => IconButton(
    key: key,
    tooltip: player.sleepActive ? 'Sleep timer active' : 'Sleep timer',
    onPressed: _sleepTimer,
    icon: Icon(
      Icons.bedtime_outlined,
      color: player.sleepActive ? accent : muted,
    ),
  );

  Future<void> _sleepTimer() => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: player,
      builder: (context, _) => AlertDialog(
        title: const Text('Sleep timer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                player.sleepAfterTrack
                    ? 'Pauses at the end of the current track.'
                    : player.sleepUntil != null
                    ? 'Pauses at ${TimeOfDay.fromDateTime(player.sleepUntil!).format(context)}.'
                    : 'Pause playback after a duration or when the track ends.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final minutes in [15, 30, 45, 60, 90])
                    ActionChip(
                      label: Text('$minutes min'),
                      onPressed: () {
                        player.setSleepTimer(Duration(minutes: minutes));
                        Navigator.pop(context);
                      },
                    ),
                ],
              ),
              TextButton.icon(
                onPressed: player.current == null
                    ? null
                    : () {
                        player.sleepAtTrackEnd();
                        Navigator.pop(context);
                      },
                icon: const Icon(Icons.music_note_rounded),
                label: const Text('End of current track'),
              ),
            ],
          ),
        ),
        actions: [
          if (player.sleepActive)
            TextButton(
              onPressed: () {
                player.cancelSleepTimer();
                Navigator.pop(context);
              },
              child: const Text('Cancel timer'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );

  Widget _trackActions(Track track) => PopupMenuButton<String>(
    tooltip: 'Track actions for ${track.title}',
    icon: const Icon(Icons.playlist_play_rounded, size: 22),
    onSelected: (value) async {
      try {
        switch (value) {
          case 'favorite':
            await player.toggleFavorite(track);
          case 'next':
            player.playNext(track);
            _notice('Playing next');
          case 'playlist':
            await _choosePlaylist(track);
          case 'remove':
            final name = selectedPlaylist;
            if (name != null) await player.removeFromPlaylist(name, track);
        }
      } on StateError catch (e) {
        _notice(e.message);
      }
    },
    itemBuilder: (_) => [
      for (final (value, icon, label) in [
        (
          'favorite',
          player.settings.favoriteIds.contains(track.id)
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          player.settings.favoriteIds.contains(track.id)
              ? 'Remove from favorites'
              : 'Add to favorites',
        ),
        ('next', Icons.play_arrow_rounded, 'Play next'),
        ('playlist', Icons.playlist_add_rounded, 'Add to playlist'),
        if (collection == 'Playlists' && selectedPlaylist != null)
          (
            'remove',
            Icons.remove_circle_outline_rounded,
            'Remove from playlist',
          ),
      ])
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        ),
    ],
  );

  List<Track> _collectionTracks() {
    final tracks = library.tracks;
    if (collection == 'Favorites') {
      return tracks
          .where((t) => player.settings.favoriteIds.contains(t.id))
          .toList();
    }
    final ids = collection == 'Recently played'
        ? player.settings.recentIds
        : collection == 'Playlists'
        ? player.settings.playlists[selectedPlaylist] ?? <String>[]
        : null;
    if (ids == null) return tracks;
    final byId = {for (final track in tracks) track.id: track};
    return [
      for (final id in ids)
        if (byId[id] case final Track track) track,
    ];
  }

  Widget _playlists() {
    final entries = player.settings.playlists.entries
        .where(
          (entry) =>
              entry.key.toLowerCase().contains(search.text.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final name = await _editPlaylist();
              if (mounted && name != null) {
                setState(() {
                  selectedPlaylist = name;
                  search.clear();
                });
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create playlist'),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _empty(
                  Icons.playlist_play_rounded,
                  'Your playlists live here',
                  search.text.isEmpty
                      ? 'Create a playlist, then add music using a track’s actions.'
                      : 'No playlists match this search.',
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) => ListTile(
                    leading: const Icon(
                      Icons.playlist_play_rounded,
                      color: accent,
                    ),
                    title: Text(
                      entries[i].key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${entries[i].value.length} saved tracks · on this device',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => setState(() {
                      selectedPlaylist = entries[i].key;
                      search.clear();
                    }),
                  ),
                ),
        ),
      ],
    );
  }


  Widget _libraryBadge(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF211D29),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF342F3E)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: accent),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _librarySummaryBar({
    required bool compact,
    required int trackCount,
    required int savedCount,
    required bool allSongs,
    required bool recent,
  }) {
    final trackText = allSongs
        ? '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}'
        : '$trackCount of $savedCount loaded';
    final channelCount = player.settings.selectedChannels.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF17141D),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF302B39)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _libraryBadge(Icons.music_note_rounded, trackText),
                    _libraryBadge(
                      Icons.campaign_rounded,
                      '$channelCount ${channelCount == 1 ? 'channel' : 'channels'}',
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (recent && player.settings.recentIds.isNotEmpty)
                      Expanded(
                        child: TextButton(
                          onPressed: player.clearRecent,
                          child: const Text('Clear history'),
                        ),
                      ),
                    if (recent && player.settings.recentIds.isNotEmpty)
                      const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: !telegram.ready || library.saving
                            ? null
                            : () {
                                telegram.clearImageCache();
                                unawaited(library.refresh());
                              },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Refresh library'),
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                _libraryBadge(Icons.music_note_rounded, trackText),
                const SizedBox(width: 8),
                _libraryBadge(
                  Icons.campaign_rounded,
                  '$channelCount ${channelCount == 1 ? 'channel' : 'channels'}',
                ),
                const Spacer(),
                if (recent && player.settings.recentIds.isNotEmpty)
                  TextButton(
                    onPressed: player.clearRecent,
                    child: const Text('Clear history'),
                  ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: !telegram.ready || library.saving
                      ? null
                      : () {
                          telegram.clearImageCache();
                          unawaited(library.refresh());
                        },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Refresh library'),
                ),
              ],
            ),
    );
  }

  Widget _library() => LayoutBuilder(
    builder: (context, box) {
      final compact = box.maxHeight < 330;
      final tracks = _collectionTracks();
      final savedCount = collection == 'Favorites'
          ? player.settings.favoriteIds.length
          : collection == 'Recently played'
          ? player.settings.recentIds.length
          : selectedPlaylist != null
          ? player.settings.playlists[selectedPlaylist]?.length ?? 0
          : tracks.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _search(
            collection == 'Playlists' && selectedPlaylist == null
                ? 'Search playlists'
                : 'Search your music',
          ),
          const SizedBox(height: 8),
          if (!compact || selectedPlaylist == null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final label in [
                    'All songs',
                    'Favorites',
                    'Playlists',
                    'Recently played',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: collection == label,
                        onSelected: (_) => setState(() {
                          collection = label;
                          selectedPlaylist = null;
                          search.clear();
                        }),
                      ),
                    ),
                  if (compact &&
                      collection == 'Recently played' &&
                      player.settings.recentIds.isNotEmpty)
                    TextButton(
                      onPressed: player.clearRecent,
                      child: const Text('Clear history'),
                    ),
                ],
              ),
            ),
          if (collection == 'Playlists' && selectedPlaylist != null)
            Row(
              children: [
                IconButton(
                  tooltip: 'Back to playlists',
                  onPressed: () => setState(() {
                    selectedPlaylist = null;
                    search.clear();
                  }),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    selectedPlaylist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Rename playlist',
                  onPressed: () async {
                    final name = await _editPlaylist(
                      previous: selectedPlaylist,
                    );
                    if (mounted && name != null) {
                      setState(() => selectedPlaylist = name);
                    }
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete playlist',
                  onPressed: () => _deletePlaylist(selectedPlaylist!),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          if (!compact) ...[
            const SizedBox(height: 10),
            _librarySummaryBar(
              compact: box.maxWidth < 680,
              trackCount: tracks.length,
              savedCount: savedCount,
              allSongs: collection == 'All songs',
              recent: collection == 'Recently played',
            ),
          ],
          if (library.error != null) _banner(library.error!),
          if (library.loading) ...[
            const LinearProgressIndicator(minHeight: 2),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Loading music from your channels…',
                style: TextStyle(color: muted, fontSize: 11),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: collection == 'Playlists' && selectedPlaylist == null
                ? _playlists()
                : !telegram.ready
                ? _empty(
                    Icons.send_rounded,
                    'Connect Telegram for your music',
                    'Sign in and choose channels to fill your Library.',
                    action: FilledButton.tonalIcon(
                      onPressed: _openTelegram,
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Connect Telegram'),
                    ),
                  )
                : player.settings.selectedChannels.isEmpty
                ? _empty(
                    Icons.campaign_rounded,
                    'Choose your music channels',
                    'Select channels in Telegram. Their music appears here together.',
                    action: FilledButton.tonalIcon(
                      onPressed: _openTelegram,
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Choose channels'),
                    ),
                  )
                : library.tracks.isEmpty
                ? _empty(
                    Icons.library_music_rounded,
                    library.loading ? 'Finding your music' : 'No music loaded',
                    library.loading
                        ? 'Tracks appear here as your channels load.'
                        : 'Refresh to try again, or choose different channels.',
                  )
                : tracks.isEmpty && collection != 'All songs'
                ? _empty(
                    Icons.music_note_rounded,
                    'No loaded tracks in this collection',
                    'Add music using track actions. Saved entries appear when their Telegram channels are selected and loaded.',
                  )
                : _trackList(
                    tracks,
                    preserveOrder:
                        collection == 'Recently played' ||
                        collection == 'Playlists',
                  ),
          ),
        ],
      );
    },
  );
  Widget _trackList(List<Track> tracks, {bool preserveOrder = false}) {
    final query = search.text.toLowerCase();
    final visible = tracks
        .where(
          (t) => '${t.title} ${t.artist} ${t.source}'.toLowerCase().contains(
            query,
          ),
        )
        .toList();
    if (!preserveOrder) visible.sort(player.settings.librarySort.compare);
    if (visible.isEmpty) {
      return _empty(
        Icons.search_off_rounded,
        'No tracks found',
        'Try another search or choose a different source.',
      );
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) => _trackTile(
        visible[i],
        onPlay: () => player.play(visible[i], from: visible),
      ),
    );
  }

  Widget _trackTile(
    Track track, {
    required VoidCallback onPlay,
    bool queued = false,
  }) {
    final active = player.current?.id == track.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active ? const Color(0xFF2B2438) : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          onTap: onPlay,
          leading: SizedBox(
            width: 42,
            height: 42,
            child: Artwork(
              seed: track.title,
              small: true,
              telegram: telegram,
              track: track,
            ),
          ),
          title: Text(
            key: ValueKey('track-title-${track.id}'),
            track.title.isEmpty ? 'Untitled audio' : track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active ? accent : null,
            ),
          ),
          subtitle: Text(
            '${track.artist} · ${track.source}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: muted),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (track.duration > Duration.zero)
                Text(
                  clockText(track.duration),
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
              if (queued)
                const SizedBox(
                  width: 30,
                  child: Icon(
                    Icons.drag_handle_rounded,
                    size: 19,
                    color: muted,
                  ),
                )
              else
                IconButton(
                  tooltip: 'Add ${track.title} to queue',
                  onPressed: () {
                    player.enqueue(track);
                    _notice('Added to queue');
                  },
                  icon: const Icon(Icons.playlist_add_rounded, size: 20),
                ),
              _trackActions(track),
            ],
          ),
        ),
      ),
    );
  }

  Widget _telegram() {
    if (!telegram.ready) return _signIn();
    final query = search.text.toLowerCase();
    final selected = player.settings.selectedChannels.map((c) => c.id).toSet();
    final channels =
        {
            for (final c in player.settings.selectedChannels) c.id: c,
            for (final c in telegram.channels) c.id: c,
          }.values.where((c) => c.title.toLowerCase().contains(query)).toList()
          ..sort((a, b) {
            if (selected.contains(a.id) != selected.contains(b.id)) {
              return selected.contains(a.id) ? -1 : 1;
            }
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _search('Find an accessible channel'),
        const SizedBox(height: 8),
        Expanded(
          child: CustomScrollView(
            key: const ValueKey('telegram-channels'),
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Select channels to combine their music in Library.',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${channels.length} channels · ${telegram.connection}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                        TextButton.icon(
                          onPressed: telegram.busy
                              ? null
                              : () => telegram.action(telegram.refreshChats),
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('Load more'),
                        ),
                        TextButton.icon(
                          onPressed: () => setState(() {
                            search.clear();
                            destination = 0;
                          }),
                          icon: const Icon(Icons.library_music_rounded, size: 17),
                          label: Text(
                            'Open Library (${player.settings.selectedChannels.length})',
                          ),
                        ),
                      ],
                    ),
                    if (telegram.error != null) _banner(telegram.error!),
                    if (library.error != null) _banner(library.error!),
                  ],
                ),
              ),
              if (channels.isEmpty)
                SliverToBoxAdapter(
                  child: _empty(
                    Icons.campaign_outlined,
                    'No channels to show',
                    'Join a channel in Telegram, then load your channels here.',
                  ),
                )
              else
                SliverList.builder(
                  itemCount: channels.length,
                  itemBuilder: (context, i) => CheckboxListTile(
                    value: library.selected(channels[i].id),
                    onChanged: library.saving
                        ? null
                        : (value) => unawaited(
                            library.select(channels[i], value ?? false),
                          ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    secondary: SizedBox(
                      width: 40,
                      height: 40,
                      child: ClipOval(
                        child: Artwork(
                          seed: channels[i].title,
                          small: true,
                          telegram: telegram,
                          fileId: channels[i].photoFileId,
                          preview: channels[i].photoPreview,
                        ),
                      ),
                    ),
                    title: Text(
                      channels[i].title,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      library.selected(channels[i].id)
                          ? 'Selected for Library'
                          : 'Add music to Library',
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _signIn() => SingleChildScrollView(
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF30283E),
                borderRadius: BorderRadius.circular(26),
              ),
              child: const Icon(Icons.send_rounded, color: accent, size: 36),
            ),
            const SizedBox(height: 22),
            const Text(
              'Your channels. Your soundtrack.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -.6,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Connect Telegram to browse music shared in channels you can access. Audio stays on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, height: 1.6, fontSize: 12),
            ),
            const SizedBox(height: 24),
            AuthForm(telegram: telegram),
            const SizedBox(height: 18),
            const Text(
              'Credentials are encrypted on this device.\nLogin codes and passwords are never saved.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 10, height: 1.6),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  );

  Widget _queue() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '${player.queue.length} tracks',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
          IconButton(
            onPressed: player.queue.isEmpty ? null : player.shuffle,
            tooltip: 'Shuffle upcoming tracks',
            icon: const Icon(Icons.shuffle_rounded),
          ),
          TextButton(
            onPressed: player.queue.isEmpty ? null : () => player.clear(),
            child: const Text('Clear'),
          ),
        ],
      ),
      Expanded(
        child: player.queue.isEmpty
            ? _empty(
                Icons.queue_music_rounded,
                'A little more of what you love',
                'Add tracks from your Library to build a queue.',
              )
            : ReorderableListView.builder(
                itemCount: player.queue.length,
                buildDefaultDragHandles: false,
                onReorderItem: player.reorder,
                itemBuilder: (context, i) => ReorderableDragStartListener(
                  key: ValueKey('$i:${player.queue[i].id}'),
                  index: i,
                  child: _trackTile(
                    player.queue[i],
                    queued: true,
                    onPlay: () => player.playAt(i),
                  ),
                ),
              ),
      ),
    ],
  );
  Widget _miniNowPlaying(BoxConstraints box, Track? track) {
    final coverSize = math.min(200.0, math.min(box.maxWidth - 18, box.maxHeight * .36));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('NOW PLAYING', style: TextStyle(color: muted, fontSize: 10, letterSpacing: 1.5)),
        const SizedBox(height: 14),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: coverSize,
                maxHeight: coverSize,
              ),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Artwork(
                    key: const ValueKey('now-playing-artwork'),
                    seed: track?.title ?? 'Auralis',
                    telegram: telegram,
                    track: track,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          track?.title ?? 'Find your next favorite',
          key: const ValueKey('now-playing-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          track?.artist ?? 'A space for the music you love',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 14),
        Row(
          key: const ValueKey('now-playing-actions'),
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: track == null
                    ? null
                    : () => setState(() {
                        destination = 3;
                        showLyrics = true;
                        search.clear();
                      }),
                icon: const Icon(Icons.lyrics_rounded, size: 17),
                label: const Text('Lyrics'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                key: const ValueKey('now-playing-queue'),
                onPressed: () => setState(() {
                  destination = 2;
                  showLyrics = false;
                  search.clear();
                }),
                icon: const Icon(Icons.queue_music_rounded, size: 17),
                label: const Text('Queue'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _nowPlaying({bool compact = false}) {
    final track = player.current;
    final audio = player.audio;
    final duration = audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final buffered = duration <= 0
        ? 0.0
        : (audio.buffered.inMilliseconds / duration).clamp(0.0, 1.0);
    final nextIndex = player.index + 1;
    final hasNext = player.index >= 0 && nextIndex < player.queue.length;
    final favorite = player.settings.favoriteIds.contains(track?.id);

    return Material(
      color: Colors.transparent,
      child: LayoutBuilder(
        key: const ValueKey('now-playing-layout'),
        builder: (context, box) {
          if (compact) return _miniNowPlaying(box, track);
          final scale = MediaQuery.textScalerOf(context)
              .scale(1)
              .clamp(1.0, 2.0);
          final horizontal = box.maxWidth >= 700;
          final preview =
              hasNext && box.maxWidth >= 680 && box.maxHeight >= 440 * scale;
          final previewHeight = 40.0 + 52 * scale;
          final heroHeight =
              box.maxHeight - 12 - (preview ? previewHeight + 12 : 0);
          final tight = heroHeight < (horizontal ? 550 : 520) * scale;
          final veryShort = horizontal && heroHeight < 360;
          final comfortable = horizontal && heroHeight >= 420 * scale;
          final spacious = heroHeight >= 580 * scale;
          final framed =
              horizontal && box.maxWidth >= 860 && heroHeight >= 460 * scale;
          final gap = veryShort
              ? 4.0
              : spacious
              ? 10.0
              : 6.0;
          final transportHeight = veryShort
              ? 48.0
              : horizontal
              ? (spacious
                    ? 72.0
                    : comfortable
                    ? 56.0
                    : 52.0)
              : tight
              ? 52.0
              : 72.0;

          Widget pill({
            required String tooltip,
            required IconData icon,
            required VoidCallback? onPressed,
            Color background = const Color(0xFF2B2436),
            Color foreground = accent,
            Key? key,
          }) => Expanded(
            child: IconButton.filledTonal(
              key: key,
              tooltip: tooltip,
              onPressed: onPressed,
              style: IconButton.styleFrom(
                minimumSize: const Size(48, 48),
                backgroundColor: background,
                foregroundColor: foreground,
                disabledBackgroundColor: const Color(0xFF211D28),
                shape: const StadiumBorder(),
              ),
              icon: Icon(icon, size: tight ? 26 : 32),
            ),
          );

          Widget artwork() => LayoutBuilder(
            builder: (context, artBox) {
              final peek = hasNext && !tight && !horizontal ? 40.0 : 0.0;
              final size = math.max(
                0.0,
                math.min(
                  horizontal ? 410.0 : 380.0,
                  math.min(
                    artBox.maxHeight,
                    artBox.maxWidth - peek - (peek > 0 ? 12 : 0),
                  ),
                ),
              );
              return Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: size,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF211B2B),
                          borderRadius: BorderRadius.circular(tight ? 26 : 34),
                          border: Border.all(
                            color: accent.withValues(alpha: .14),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              tight ? 21 : 29,
                            ),
                            child: Artwork(
                              key: const ValueKey('now-playing-artwork'),
                              seed: track?.title ?? 'Auralis',
                              telegram: telegram,
                              track: track,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (peek > 0) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: peek,
                        height: size,
                        child: Tooltip(
                          message: 'Play next track',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Material(
                              child: InkWell(
                                key: const ValueKey('now-playing-next-cover'),
                                onTap: () => player.playAt(nextIndex),
                                child: ExcludeSemantics(
                                  child: OverflowBox(
                                    maxWidth: size,
                                    maxHeight: size,
                                    alignment: Alignment.centerLeft,
                                    child: SizedBox.square(
                                      dimension: size,
                                      child: Artwork(
                                        seed: player.queue[nextIndex].title,
                                        telegram: telegram,
                                        track: player.queue[nextIndex],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );

          Widget details() => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (horizontal && spacious && track != null) ...[
                Text(
                  'PLAYING FROM  ·  ${track.source.isEmpty ? 'YOUR LIBRARY' : track.source}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: accent,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                track?.title ?? 'Find your next favorite',
                key: const ValueKey('now-playing-title'),
                maxLines: horizontal
                    ? (comfortable ? 2 : 1)
                    : tight
                    ? 1
                    : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: horizontal
                      ? (veryShort
                            ? 20
                            : spacious
                            ? 34
                            : comfortable
                            ? 28
                            : 24)
                      : tight
                      ? 22
                      : 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.7,
                  height: 1.18,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                track?.artist ?? 'Choose a song from your Library',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: muted,
                  fontSize: veryShort
                      ? 12
                      : tight
                      ? 14
                      : 16,
                ),
              ),
            ],
          );

          final seek = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              WaveSeekBar(
                value: progress,
                buffered: buffered,
                playing: audio.playing && !audio.buffering && track != null,
                reducedMotion: player.settings.reducedMotion,
                format: (v) =>
                    clockText(Duration(milliseconds: (v * duration).round())),
                onChanged: duration <= 0
                    ? null
                    : (v) => player.seek(
                        Duration(milliseconds: (v * duration).round()),
                      ),
              ),
              Row(
                children: [
                  Text(
                    clockText(audio.position),
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      track == null
                          ? 'Nothing playing'
                          : switch (track.mime.toLowerCase()) {
                              'audio/x-flac' || 'audio/flac' => 'FLAC',
                              'audio/mpeg' || 'audio/mp3' => 'MP3',
                              'audio/mp4' || 'audio/x-m4a' => 'M4A',
                              'application/octet-stream' => 'Original audio',
                              _ =>
                                track.mime.startsWith('audio/')
                                    ? track.mime.substring(6).toUpperCase()
                                    : 'Original audio',
                            },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10, color: accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    clockText(audio.duration),
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
            ],
          );

          final transport = SizedBox(
            key: const ValueKey('now-playing-transport'),
            height: transportHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                pill(
                  tooltip: 'Previous track',
                  icon: Icons.skip_previous_rounded,
                  onPressed: track == null
                      ? null
                      : () => unawaited(player.previous()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: IconButton.filled(
                    key: const ValueKey('now-playing-play-pause'),
                    tooltip: audio.playing ? 'Pause' : 'Play',
                    onPressed: track == null || player.loading
                        ? null
                        : audio.toggle,
                    style: IconButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: const Color(0xFF21182F),
                      shape: const StadiumBorder(),
                    ),
                    icon: player.loading || audio.buffering
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            audio.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: tight ? 32 : 42,
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                pill(
                  tooltip: 'Next track',
                  icon: Icons.skip_next_rounded,
                  onPressed: track == null
                      ? null
                      : () => unawaited(player.next()),
                ),
              ],
            ),
          );

          final modes = DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1724),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF302839)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  pill(
                    key: const ValueKey('now-playing-shuffle'),
                    tooltip: 'Shuffle upcoming tracks',
                    icon: Icons.shuffle_rounded,
                    onPressed: hasNext ? player.shuffle : null,
                    background: Colors.transparent,
                  ),
                  const SizedBox(width: 4),
                  pill(
                    key: const ValueKey('now-playing-repeat'),
                    tooltip: switch (player.repeatMode) {
                      PlaybackRepeat.off => 'Repeat: off',
                      PlaybackRepeat.all => 'Repeat: queue',
                      PlaybackRepeat.one => 'Repeat: one track',
                    },
                    icon: player.repeatMode == PlaybackRepeat.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    onPressed: player.toggleRepeat,
                    background: player.repeat
                        ? accent.withValues(alpha: .16)
                        : Colors.transparent,
                    foreground: player.repeat ? const Color(0xFFE5D9FF) : muted,
                  ),
                  const SizedBox(width: 4),
                  pill(
                    key: const ValueKey('now-playing-favorite'),
                    tooltip: favorite
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                    icon: favorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    background: Colors.transparent,
                    onPressed: track == null
                        ? null
                        : () async {
                            try {
                              await player.toggleFavorite(track);
                            } on StateError catch (e) {
                              _notice(e.message);
                            }
                          },
                  ),
                ],
              ),
            ),
          );

          final actions = LayoutBuilder(
            builder: (context, actionBox) {
              final labels = actionBox.maxWidth >= 400 * scale;
              return Row(
                key: const ValueKey('now-playing-actions'),
                children: [
                  Tooltip(
                    message: 'Lyrics',
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: EdgeInsets.symmetric(
                          horizontal: labels ? 12 : 8,
                        ),
                        backgroundColor: labels
                            ? accent.withValues(alpha: .09)
                            : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: track == null
                          ? null
                          : () => setState(() {
                              showLyrics = true;
                              search.clear();
                            }),
                      icon: const Icon(Icons.lyrics_rounded, size: 21),
                      label: labels
                          ? const Text('Lyrics')
                          : const SizedBox.shrink(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add to playlist',
                    onPressed: track == null
                        ? null
                        : () => _choosePlaylist(track),
                    icon: const Icon(Icons.playlist_add_rounded),
                  ),
                  _sleepControl(key: const ValueKey('sleep-timer-control')),
                  const Spacer(),
                  _volumeControl(true, tight: true),
                ],
              );
            },
          );

          final controls = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (horizontal) ...[details(), SizedBox(height: gap)],
              seek,
              SizedBox(height: gap),
              transport,
              SizedBox(height: gap),
              modes,
              SizedBox(height: gap),
              actions,
            ],
          );

          final hero = horizontal
              ? Row(
                  children: [
                    Expanded(flex: 5, child: artwork()),
                    const SizedBox(width: 28),
                    Expanded(
                      flex: 6,
                      child: framed
                          ? Container(
                              key: const ValueKey('now-playing-control-card'),
                              padding: EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: spacious ? 16 : 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF19151F),
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: const Color(0xFF302738),
                                ),
                              ),
                              child: controls,
                            )
                          : controls,
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: tight
                          ? Row(
                              children: [
                                SizedBox(
                                  width: math.min(116, box.maxWidth * .32),
                                  child: artwork(),
                                ),
                                const SizedBox(width: 16),
                                Expanded(child: details()),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: artwork()),
                                SizedBox(height: gap),
                                details(),
                              ],
                            ),
                    ),
                    SizedBox(height: gap),
                    controls,
                  ],
                );

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1140),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: hero),
                    if (preview) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        height: previewHeight,
                        child: Material(
                          color: const Color(0xFF1C1823),
                          borderRadius: BorderRadius.circular(22),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: const ValueKey('now-playing-next-0'),
                            onTap: () => player.playAt(nextIndex),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: SizedBox.square(
                                      dimension: 48,
                                      child: Artwork(
                                        seed: player.queue[nextIndex].title,
                                        telegram: telegram,
                                        track: player.queue[nextIndex],
                                        small: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'UP NEXT · ${player.queue.length - nextIndex} tracks',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: accent,
                                            fontSize: 10,
                                            letterSpacing: 1,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          player.queue[nextIndex].title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          player.queue[nextIndex].artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: muted,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Icon(
                                    Icons.play_circle_fill_rounded,
                                    size: 32,
                                    color: accent,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(
    IconData icon,
    String title,
    String description, {
    Widget? action,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: const Color(0xFF25202E),
              borderRadius: BorderRadius.circular(34),
            ),
            child: Icon(icon, size: 38, color: accent),
          ),
          const SizedBox(height: 22),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, height: 1.8, fontSize: 12),
          ),
          if (action != null) ...[const SizedBox(height: 24), action],
        ],
      ),
    ),
  );


  Widget _playerPanel({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(12),
    double radius = 24,
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: const Color(0xFF201C28),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFF332D3F)),
    ),
    child: child,
  );

  Widget _volumeControl(bool narrow, {bool tight = false}) => Listener(
    key: const ValueKey('volume-control'),
    onPointerSignal: (event) {
      if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          unawaited(
            player.setVolume(
              player.settings.volume + (event.scrollDelta.dy < 0 ? 5 : -5),
            ),
          );
        });
      }
    },
    child: Tooltip(
      message: 'Volume: ${player.settings.volume.round()}% (scroll to adjust)',
      child: _playerPanel(
        padding: EdgeInsets.symmetric(
          horizontal: narrow ? 10 : 12,
          vertical: tight ? 0 : narrow ? 6 : 8,
        ),
        radius: 18,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.volume_up_rounded, size: 18, color: muted),
            const SizedBox(width: 8),
            SizedBox(
              width: narrow ? 74 : 96,
              child: Semantics(
                label: 'Volume',
                child: Slider(
                  key: const ValueKey('volume-slider'),
                  value: player.settings.volume,
                  max: 100,
                  label: '${player.settings.volume.round()}%',
                  onChanged: (v) =>
                      unawaited(player.setVolume(v, persist: false)),
                  onChangeEnd: player.setVolume,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );


  Widget _transport(bool narrow) {
    final audio = player.audio, duration = player.audio.duration.inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (audio.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final buffer = duration <= 0
        ? 0.0
        : (audio.buffered.inMilliseconds / duration).clamp(0.0, 1.0);
    final preview = Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('open-current-track'),
        borderRadius: BorderRadius.circular(20),
        onTap: player.current == null
            ? null
            : () => setState(() {
                destination = 3;
                search.clear();
              }),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: narrow ? 44 : 54,
                  height: narrow ? 44 : 54,
                  child: Artwork(
                    seed: player.current?.title ?? 'Auralis',
                    small: true,
                    telegram: telegram,
                    track: player.current,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      player.current?.title ?? 'Nothing playing',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      player.current?.artist ?? 'Choose a track to get started',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (player.current != null)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: 16,
                    color: muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final transportButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (player.loading || audio.buffering)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        IconButton(
          onPressed: player.current == null ? null : player.previous,
          tooltip: 'Previous track',
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 2),
        IconButton.filled(
          onPressed: player.current == null || player.loading ? null : audio.toggle,
          tooltip: audio.playing ? 'Pause' : 'Play',
          style: IconButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: const Color(0xFF1D1825),
          ),
          icon: Icon(
            audio.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        const SizedBox(width: 2),
        IconButton(
          onPressed: player.current == null ? null : player.next,
          tooltip: 'Next track',
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );

    final utilityButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: player.toggleRepeat,
          tooltip: switch (player.repeatMode) {
            PlaybackRepeat.off => 'Repeat: off',
            PlaybackRepeat.all => 'Repeat: queue',
            PlaybackRepeat.one => 'Repeat: one track',
          },
          icon: Icon(
            player.repeatMode == PlaybackRepeat.one
                ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            color: player.repeat ? accent : muted,
          ),
        ),
        _sleepControl(key: const ValueKey('sleep-timer-control')),
        _volumeControl(narrow),
      ],
    );

    final progressBar = Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(
            clockText(audio.position),
            style: const TextStyle(fontSize: 10, color: muted),
          ),
        ),
        Expanded(
          child: WaveSeekBar(
            value: progress,
            buffered: buffer,
            playing: audio.playing && !audio.buffering && player.current != null,
            reducedMotion: player.settings.reducedMotion,
            format: (v) =>
                clockText(Duration(milliseconds: (v * duration).round())),
            onChanged: duration <= 0
                ? null
                : (v) => player.seek(
                      Duration(milliseconds: (v * duration).round()),
                    ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            clockText(audio.duration),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 10, color: muted),
          ),
        ),
      ],
    );

    final compactPreview = Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('open-current-track'),
        borderRadius: BorderRadius.circular(14),
        onTap: player.current == null
            ? null
            : () => setState(() {
                destination = 3;
                search.clear();
              }),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.square(
                dimension: 36,
                child: Artwork(
                  seed: player.current?.title ?? 'Auralis',
                  small: true,
                  telegram: telegram,
                  track: player.current,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    player.current?.title ?? 'Nothing playing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    player.current?.artist ?? 'Choose a track',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Container(
      key: const ValueKey('player-bar'),
      decoration: const BoxDecoration(
        color: Color(0xFF17141D),
        border: Border(top: BorderSide(color: Color(0xFF302B39))),
      ),
      padding: EdgeInsets.fromLTRB(narrow ? 10 : 18, narrow ? 4 : 10, narrow ? 10 : 18, narrow ? 6 : 12),
      child: narrow
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Two compact control rows plus the seek bar. Never stack
                // large full-size player cards on short phone windows.
                progressBar,
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: compactPreview),
                    const SizedBox(width: 4),
                    transportButtons,
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    IconButton(
                      onPressed: player.toggleRepeat,
                      tooltip: switch (player.repeatMode) {
                        PlaybackRepeat.off => 'Repeat: off',
                        PlaybackRepeat.all => 'Repeat: queue',
                        PlaybackRepeat.one => 'Repeat: one track',
                      },
                      icon: Icon(
                        player.repeatMode == PlaybackRepeat.one
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        color: player.repeat ? accent : muted,
                      ),
                    ),
                    _sleepControl(key: const ValueKey('sleep-timer-control')),
                    const Spacer(),
                    _volumeControl(true),
                  ],
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth < 960) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Expanded(child: compactPreview),
                        transportButtons,
                        utilityButtons,
                      ]),
                      progressBar,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(flex: 3, child: preview),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 5,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [transportButtons, progressBar],
                      ),
                    ),
                    const SizedBox(width: 24),
                    utilityButtons,
                  ],
                );
              },
            ),
    );
  }


  Future<void> _settings() => showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Make it yours'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Reduce motion'),
                  subtitle: const Text('Use instant page transitions'),
                  value: player.settings.reducedMotion,
                  onChanged: (v) async {
                    update(() {
                      player.settings.reducedMotion = v;
                    });
                    setState(() {});
                    try {
                      await player.settings.save();
                    } catch (_) {
                      _notice('Could not save settings.');
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bar_chart_rounded),
                  title: const Text('Listening stats'),
                  subtitle: const Text(
                    'Listening time, rankings and data export',
                  ),
                  onTap: () async {
                    await _stats();
                    if (dialogContext.mounted) update(() {});
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Backup & Restore'),
                  subtitle: const Text('Stats, collections and preferences'),
                  onTap: () async {
                    await _stats(backup: true);
                    if (dialogContext.mounted) update(() {});
                  },
                ),
                const Divider(),
                if (widget.updater != null) ...[
                  UpdateSettings(updater: widget.updater!),
                  const Divider(),
                ],
                Text(
                  'Auralis ${widget.updater?.currentVersion ?? '0.1.43'} · AGPL-3.0-or-later\nIndependent Flutter interface. Playback by libmpv. Telegram connectivity by TDLib.',
                  style: const TextStyle(
                    color: muted,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                if (telegram.ready)
                  TextButton(
                    onPressed: telegram.busy
                        ? null
                        : () async {
                            await player.clear();
                            await telegram.logout();
                            if (telegram.ready && telegram.error != null) {
                              _notice(telegram.error!);
                            }
                            if (!telegram.ready) {
                              player.settings.selectedChannels = [];
                              try {
                                await player.settings.save();
                              } catch (_) {
                                _notice(
                                  'Signed out, but the old channel selection could not be removed from settings.',
                                );
                              }
                            }
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            if (mounted && !telegram.ready) _openTelegram();
                          },
                    child: const Text('Sign out of Telegram'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Auralis',
              applicationVersion: widget.updater?.currentVersion ?? '0.1.43',
            ),
            child: const Text('Licenses'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}

class AuthForm extends StatefulWidget {
  const AuthForm({super.key, required this.telegram});
  final TelegramService telegram;
  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  final apiId = TextEditingController(),
      apiHash = TextEditingController(),
      value = TextEditingController();
  String? _lastState;
  @override
  void dispose() {
    apiId.dispose();
    apiHash.dispose();
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final td = widget.telegram;
    if (_lastState != td.state) {
      value.clear();
      if (td.state == 'disconnected') {
        apiId.clear();
        apiHash.clear();
      }
      _lastState = td.state;
    }
    final initial = td.state == 'disconnected';
    final label = switch (td.state) {
      'authorizationStateWaitPhoneNumber' =>
        'Phone number, including country code',
      'authorizationStateWaitCode' => 'Login code from Telegram',
      'authorizationStateWaitPassword' => 'Two-step verification password',
      'authorizationStateWaitEmailAddress' =>
        'Email address requested by Telegram',
      'authorizationStateWaitEmailCode' => 'Email verification code',
      _ => null,
    };
    Future<void> submit() async {
      if (initial) {
        await td.start(
          apiId: int.tryParse(apiId.text.trim()) ?? 0,
          apiHash: apiHash.text.trim(),
        );
        apiHash.clear();
      } else {
        final input = value.text;
        value.clear();
        await td.submit(input);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (initial) ...[
          const Text(
            'Create an API application at my.telegram.org, then enter its details here.',
            style: TextStyle(fontSize: 12, color: muted, height: 1.6),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: apiId,
            decoration: const InputDecoration(labelText: 'Telegram API ID'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: apiHash,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Telegram API hash'),
          ),
        ] else if (label != null)
          TextField(
            key: ValueKey(td.state),
            controller: value,
            obscureText: td.state == 'authorizationStateWaitPassword',
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: label),
            onSubmitted: td.busy ? null : (_) => submit(),
          )
        else
          Text(switch (td.state) {
            'authorizationStateWaitRegistration' => 'Create your Telegram account in the official app first, then restart Auralis.',
            'authorizationStateClosed' =>
              'Telegram was closed. Restart Auralis to reconnect.',
            'authorizationStateLoggingOut' => 'Signing out of Telegram… Keep your internet connection available. The API ID and hash form will appear when sign-out finishes.',
            'authorizationStateWaitPremiumPurchase' => 'Telegram requires a Premium verification step. Complete it in the official app.',
            'authorizationStateWaitOtherDeviceConfirmation' =>
              'Confirm this sign-in in your Telegram application.',
            _ => 'Connecting securely to Telegram…',
          }, style: const TextStyle(color: muted, height: 1.6)),
        if (td.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              td.error!,
              style: const TextStyle(color: Color(0xFFFFB4C8), fontSize: 12),
            ),
          ),
        const SizedBox(height: 18),
        if (initial || label != null)
          FilledButton(
            onPressed: td.busy ? null : submit,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: td.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(initial ? 'Connect Telegram' : 'Continue'),
            ),
          ),
      ],
    );
  }
}

/// Telegram images, tiny previews and embedded covers with a visible fallback.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.seed,
    this.small = false,
    this.telegram,
    this.fileId,
    this.track,
    this.preview,
  });
  final String seed;
  final bool small;
  final TelegramService? telegram;
  final int? fileId;
  final Track? track;
  final Uint8List? preview;

  @override
  Widget build(BuildContext context) {
    final placeholder = Tooltip(
      message: track == null ? 'Artwork unavailable' : 'No cover available yet',
      child: CustomPaint(
        painter: _RecordPainter(seed),
        child: const SizedBox.expand(),
      ),
    );
    Widget image(ImageProvider provider, Widget fallback) => Image(
      image: ResizeImage(provider, width: small ? 96 : 640),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (context, error, stack) => fallback,
      frameBuilder: (context, child, frame, synchronous) =>
          frame == null ? fallback : child,
    );
    final mini = track?.coverPreview ?? preview;
    final fallback = mini == null
        ? placeholder
        : image(MemoryImage(mini), placeholder);
    Widget child = fallback;
    if (telegram != null && track != null) {
      child = FutureBuilder<Uint8List?>(
        key: ValueKey((track!.fileId, track!.coverFileId)),
        future: telegram!.cover(track!),
        builder: (context, snapshot) =>
            snapshot.connectionState == ConnectionState.done &&
                snapshot.data != null
            ? image(MemoryImage(snapshot.data!), fallback)
            : fallback,
      );
    } else if (telegram != null && fileId != null) {
      child = FutureBuilder<String?>(
        key: ValueKey(fileId),
        future: telegram!.image(fileId!),
        builder: (context, snapshot) =>
            snapshot.connectionState == ConnectionState.done &&
                snapshot.data != null
            ? image(FileImage(File(snapshot.data!)), fallback)
            : fallback,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(small ? 12 : 30),
      child: child,
    );
  }
}

class _RecordPainter extends CustomPainter {
  _RecordPainter(this.seed);
  final String seed;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = 240.0 + seed.codeUnits.fold(0, (a, b) => a + b) % 80;
    final dark = HSLColor.fromAHSL(1, hue, .25, .2).toColor(),
        light = HSLColor.fromAHSL(1, hue, .5, .72).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [light, dark],
        ).createShader(rect),
    );
    final center = Offset(size.width * .62, size.height * .57);
    for (var i = 1; i < 11; i++) {
      canvas.drawCircle(
        center,
        size.width * (.08 + i * .034),
        Paint()
          ..color = Colors.black.withValues(alpha: .13)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * .012,
      );
    }
    canvas.drawCircle(
      center,
      size.width * .085,
      Paint()..color = const Color(0xFFDAD0E9),
    );
    canvas.drawCircle(center, size.width * .018, Paint()..color = dark);
    final path = Path()
      ..moveTo(0, size.height * .7)
      ..cubicTo(
        size.width * .2,
        size.height * .3,
        size.width * .3,
        size.height * .9,
        size.width,
        size.height * .2,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: .12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * .11,
    );
  }

  @override
  bool shouldRepaint(_RecordPainter oldDelegate) => seed != oldDelegate.seed;
}
