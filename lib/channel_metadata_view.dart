import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_popups.dart';
import 'channel_metadata.dart';

class ChannelMetadataHeader extends StatefulWidget {
  const ChannelMetadataHeader({
    super.key,
    required this.channelId,
    required this.channelName,
    required this.repository,
    required this.videoCount,
    this.onPlay,
  });
  final int channelId, videoCount;
  final String channelName;
  final ChannelMetadataRepository repository;
  final VoidCallback? onPlay;
  @override
  State<ChannelMetadataHeader> createState() => _ChannelMetadataHeaderState();
}

class _ChannelMetadataHeaderState extends State<ChannelMetadataHeader> {
  late Future<MetadataMatch> _match;
  bool _expanded = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _match = widget.repository.identify(widget.channelId, widget.channelName);
  }

  @override
  void didUpdateWidget(ChannelMetadataHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.channelName != widget.channelName ||
        oldWidget.repository != widget.repository) {
      _expanded = false;
      _load();
    }
  }

  Future<void> _choose() async {
    final repository = widget.repository;
    final id = widget.channelId, name = widget.channelName;
    final result = await showAuralisDialog<ChannelTitle>(
      context: context,
      builder: (_) => _TitleSearch(repository: repository, initialQuery: name),
    );
    if (result == null) return;
    await repository.select(id, name, result);
    if (!mounted || widget.channelId != id || widget.repository != repository) {
      return;
    }
    setState(() {
      _expanded = false;
      _match = repository.identifySaved(id);
    });
  }

  Widget _art(String? url, {bool poster = false}) =>
      MetadataArtwork(repository: widget.repository, url: url, poster: poster);

  @override
  Widget build(BuildContext context) => FutureBuilder<MetadataMatch>(
    future: _match,
    builder: (context, snapshot) {
      final colors = Theme.of(context).colorScheme;
      final theme = Theme.of(context).textTheme;
      final data = snapshot.data, title = data?.selected;
      final waiting = snapshot.connectionState != ConnectionState.done;
      final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
      final stacked = MediaQuery.sizeOf(context).width < 360 || textScale > 1.5;
      final details = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title?.title ?? widget.channelName,
            key: const ValueKey('channel-metadata-title'),
            style: theme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            widget.channelName,
            style: theme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (title != null) ...[
            if (title.studio?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(title.studio!, style: theme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Text(
              [
                if (title.year != null) '${title.year}',
                if (title.format != null) title.format!.replaceAll('_', ' '),
                if (title.status != null) title.status!,
                if (title.rating != null)
                  '${title.rating!.toStringAsFixed(1)}${title.provider == 'AniList' ? '/100' : '/10'}',
              ].join(' · '),
              style: theme.bodyMedium?.copyWith(color: colors.primary),
            ),
          ],
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Material(
            color: colors.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title?.banner case final String banner)
                  SizedBox(
                    height: 150,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _art(banner),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                colors.surfaceContainerLow,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (stacked) ...[
                        if (title?.cover != null) ...[
                          SizedBox(
                            width: 100,
                            height: 145,
                            child: _art(title!.cover, poster: true),
                          ),
                          const SizedBox(height: 12),
                        ],
                        details,
                      ] else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (title?.cover != null) ...[
                              SizedBox(
                                width: 105,
                                height: 155,
                                child: _art(title!.cover, poster: true),
                              ),
                              const SizedBox(width: 14),
                            ],
                            Expanded(child: details),
                          ],
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (widget.onPlay != null)
                            FilledButton.icon(
                              key: const ValueKey('channel-metadata-play'),
                              onPressed: widget.onPlay,
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('Start'),
                            ),
                          TextButton.icon(
                            key: const ValueKey('channel-metadata-choose'),
                            onPressed: _choose,
                            icon: const Icon(Icons.manage_search_rounded),
                            label: Text(
                              title == null ? 'Identify title' : 'Change title',
                            ),
                          ),
                          Text(
                            '${widget.videoCount} channel videos',
                            style: theme.bodySmall,
                          ),
                        ],
                      ),
                      if (waiting) ...[
                        const SizedBox(height: 4),
                        const Text('Finding title information…'),
                      ] else if (title == null)
                        Text(
                          data?.failed == true
                              ? 'Title information is unavailable. Your videos are ready to play. Search again when online.'
                              : 'No confident match. Search and select a title to add its details.',
                          style: theme.bodySmall,
                        ),
                      if (title != null) ...[
                        if (title.description.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            title.description,
                            maxLines: _expanded ? null : 4,
                            overflow: _expanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: theme.bodyMedium?.copyWith(height: 1.45),
                          ),
                          TextButton.icon(
                            onPressed: () =>
                                setState(() => _expanded = !_expanded),
                            icon: Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                            ),
                            label: Text(_expanded ? 'Show less' : 'Read more'),
                          ),
                        ],
                        if (title.nativeTitle != null &&
                            title.nativeTitle != title.title) ...[
                          const SizedBox(height: 4),
                          Text(title.nativeTitle!, style: theme.bodySmall),
                        ],
                        if (title.episodes != null ||
                            title.minutes != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            [
                              if (title.episodes != null)
                                '${title.episodes} catalogue episodes',
                              if (title.minutes != null)
                                '${title.minutes} min${title.format == 'Film' || title.format == 'MOVIE' ? '' : ' / episode'}',
                            ].join(' · '),
                          ),
                        ],
                        if (title.genres.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final genre in title.genres)
                                Chip(
                                  label: Text(genre),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => showAuralisDialog<void>(
                            context: context,
                            builder: (c) => AuralisDialog(
                              title: Text('Source: ${title.provider}'),
                              content: SelectableText(
                                [
                                  if (title.url != null) title.url!,
                                  if (title.provider == 'TVmaze') 'TVmaze · CC BY-SA 4.0 · https://www.tvmaze.com/api',
                                  if (title.provider == 'Wikipedia') 'Wikipedia contributors · CC BY-SA · Image rights vary; see the source article.',
                                  if (title.provider == 'AniList') 'Title information and artwork from AniList.',
                                ].join('\n\n'),
                              ),
                              actions: [
                                if (title.url != null)
                                  TextButton(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: title.url!),
                                      );
                                    },
                                    child: const Text('Copy source link'),
                                  ),
                                TextButton(
                                  onPressed: () => Navigator.pop(c),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          ),
                          child: Text(
                            'Source: ${title.provider}${data?.manual == true ? ' · Selected by you' : ''}',
                          ),
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
    },
  );
}

class MetadataArtwork extends StatefulWidget {
  const MetadataArtwork({
    super.key,
    required this.repository,
    required this.url,
    this.poster = false,
  });
  final ChannelMetadataRepository repository;
  final String? url;
  final bool poster;
  @override
  State<MetadataArtwork> createState() => _MetadataArtworkState();
}

class _MetadataArtworkState extends State<MetadataArtwork> {
  Future<File?>? _file;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _file = widget.url == null ? null : widget.repository.image(widget.url!);
  }

  @override
  void didUpdateWidget(MetadataArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: const Center(child: Icon(Icons.movie_outlined, size: 32)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.poster ? 12 : 0),
      child: FutureBuilder<File?>(
        future: _file,
        builder: (_, snapshot) => snapshot.data == null
            ? fallback
            : Image.file(
                snapshot.data!,
                fit: BoxFit.cover,
                cacheWidth: widget.poster ? 360 : 1400,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _TitleSearch extends StatefulWidget {
  const _TitleSearch({required this.repository, required this.initialQuery});
  final ChannelMetadataRepository repository;
  final String initialQuery;
  @override
  State<_TitleSearch> createState() => _TitleSearchState();
}

class _TitleSearchState extends State<_TitleSearch> {
  late final _query = TextEditingController(
    text: cleanChannelTitle(widget.initialQuery),
  );
  MetadataKind _kind = MetadataKind.any;
  List<ChannelTitle> _rows = [];
  bool _busy = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final term = _query.text.trim();
    final generation = ++_generation;
    if (term.isEmpty) {
      setState(() {
        _busy = false;
        _rows = [];
        _error = 'Enter a title.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _rows = [];
    });
    try {
      final rows = await widget.repository.search(term, kind: _kind);
      if (!mounted || generation != _generation) return;
      setState(() {
        _rows = rows;
        _busy = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = 'Could not search. Check your connection and try again.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final height =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).vertical;
    return AuralisDialog(
      title: const Text('Find the correct title'),
      width: 560,
      maxWidth: 620,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('channel-metadata-query'),
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            onChanged: (_) {
              setState(() {
                _generation++;
                _busy = false;
                _rows = [];
                _error = null;
              });
            },
            decoration: InputDecoration(
              labelText: 'Anime, movie or series',
              suffixIcon: IconButton(
                tooltip: 'Search titles',
                onPressed: _search,
                icon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<MetadataKind>(
            initialValue: _kind,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Search in'),
            items: const [
              DropdownMenuItem(
                value: MetadataKind.any,
                child: Text('Automatic · AniList first'),
              ),
              DropdownMenuItem(
                value: MetadataKind.anime,
                child: Text('Anime · AniList'),
              ),
              DropdownMenuItem(
                value: MetadataKind.series,
                child: Text('TV series · TVmaze'),
              ),
              DropdownMenuItem(
                value: MetadataKind.film,
                child: Text('Films · Wikipedia'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                _kind = value;
                _search();
              }
            },
          ),
          const SizedBox(height: 8),
          if (_busy)
            const Text('Searching titles…')
          else if (_error != null)
            Text(_error!)
          else if (_rows.isEmpty)
            const Text('No matching titles. Try another name or catalogue.')
          else
            SizedBox(
              height: (height * .4).clamp(120.0, 360.0),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final row = _rows[index];
                  return ListTile(
                    key: ValueKey(('metadata-candidate', row.key)),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 6,
                    ),
                    leading: SizedBox(
                      width: 42,
                      height: 62,
                      child: MetadataArtwork(
                        repository: widget.repository,
                        url: row.cover,
                        poster: true,
                      ),
                    ),
                    title: Text(row.title),
                    subtitle: Text(
                      [
                        row.provider,
                        if (row.year != null) '${row.year}',
                        if (row.format != null) row.format!,
                        if (row.nativeTitle != null) row.nativeTitle!,
                        if (row.description.isNotEmpty) row.description,
                      ].join(' · '),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, row),
                  );
                },
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
