part of 'video_playback.dart';

typedef _PanelAction = Future<void> Function();
typedef _VideoChoice<T> = ({T value, String label, bool selected});

extension _PlaybackPanels on _VideoPlaybackState {
  Future<T?> _choose<T>(
    BuildContext context,
    String title,
    Iterable<_VideoChoice<T>> choices,
  ) => showAuralisDialog<T>(
    context: context,
    builder: (dialog) => _VideoPanel(
      title: title,
      icon: Icons.tune_rounded,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (choices.isEmpty) const Text('No options available.'),
          for (final choice in choices)
            _VideoMenuRow(
              label: choice.label,
              icon: Icons.tune_rounded,
              selected: choice.selected ? true : null,
              onTap: () => Navigator.pop(dialog, choice.value),
            ),
        ],
      ),
    ),
  );

  _VideoOption<T> _trackOption<T>(
    T value,
    String id,
    String? title,
    String? language, {
    required IconData icon,
    required bool selected,
    required String offHint,
  }) {
    if (id == 'auto') {
      return _VideoOption(value, 'Automatic', Icons.auto_awesome_rounded,
          detail: 'Use the default track', selected: selected);
    }
    if (id == 'no') {
      return _VideoOption(value, 'Off', Icons.block_rounded,
          detail: offHint, selected: selected);
    }
    final tag = language?.trim().toLowerCase().split(RegExp('[-_]')).first ?? '';
    final languageName = switch (tag) {
      'en' || 'eng' => 'English',
      'ja' || 'jpn' => 'Japanese',
      'de' || 'deu' || 'ger' => 'German',
      'es' || 'spa' => 'Spanish',
      'fr' || 'fra' || 'fre' => 'French',
      'pt' || 'por' => 'Portuguese',
      'it' || 'ita' => 'Italian',
      'zh' || 'zho' || 'chi' => 'Chinese',
      'ko' || 'kor' => 'Korean',
      'ar' || 'ara' => 'Arabic',
      'hi' || 'hin' => 'Hindi',
      'bn' || 'ben' => 'Bengali',
      'ru' || 'rus' => 'Russian',
      'id' || 'ind' => 'Indonesian',
      'th' || 'tha' => 'Thai',
      'vi' || 'vie' => 'Vietnamese',
      '' || 'und' => null,
      _ => tag.toUpperCase(),
    };
    final name = title?.trim();
    final label = name != null && name.isNotEmpty ? name : languageName ?? 'Track $id';
    return _VideoOption(value, label, icon,
        detail: languageName?.toLowerCase() == label.toLowerCase() ? null : languageName,
        selected: selected);
  }

  Widget _trackChoices<T>(
    List<_VideoOption<T>> options,
    ValueChanged<T> select,
  ) {
    bool isMode(_VideoOption<T> option) =>
        option.icon == Icons.auto_awesome_rounded || option.icon == Icons.block_rounded;
    final tracks = options.where((option) => !isMode(option));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in options)
          if (isMode(option)) option.row(select),
        if (tracks.isNotEmpty) ...[
          const _VideoSectionLabel('Available tracks'),
          for (final track in tracks) track.row(select),
        ] else
          const Padding(
            padding: EdgeInsets.all(10),
            child: Text('No tracks available.'),
          ),
      ],
    );
  }

  Future<void> _speedPanel(BuildContext context) async {
    final player = _player!;
    final rate = await showAuralisDialog<double>(
      context: context,
      builder: (dialog) => _VideoPanel(
        title: 'Playback speed',
        detail: 'Choose how fast the video plays.',
        icon: Icons.speed_rounded,
        width: 420,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, speeds) in const [
              ('Slower', [.25, .5, .75]),
              ('Normal', [1.0]),
              ('Faster', [1.25, 1.5, 1.75, 2.0, 2.5, 3.0]),
            ]) ...[
              _VideoSectionLabel(label),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final speed in speeds)
                    ChoiceChip(
                      label: Text('${speed % 1 == 0 ? speed.toInt() : speed}×'),
                      selected: speed == player.state.rate,
                      onSelected: (_) => Navigator.pop(dialog, speed),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    if (_canPlay && rate != null) await player.setRate(rate);
  }

  Future<void> _decoderPanel(BuildContext context) async {
    final mode = await showAuralisDialog<String>(
      context: context,
      builder: (dialog) => _VideoPanel(
        title: 'Video decoder',
        detail: 'Choose how the video is decoded.',
        icon: Icons.memory_rounded,
        content: Column(
          children: [
            for (final (id, label, detail, icon) in const [
              ('auto-safe', 'Automatic', 'Recommended. Uses hardware when supported.', Icons.auto_awesome_rounded),
              ('auto-copy', 'Hardware copy-back', 'Try this if automatic mode has display issues.', Icons.layers_outlined),
              ('no', 'Software', 'Uses the CPU. Can help with hardware decoding issues.', Icons.memory_rounded),
            ])
              _VideoMenuRow(
                label: label,
                detail: detail,
                icon: icon,
                selected: id == _decoder,
                onTap: () => Navigator.pop(dialog, id),
              ),
          ],
        ),
      ),
    );
    if (_canPlay && mode != null) {
      await _native.setProperty('hwdec', mode);
      _decoder = mode;
      _changed();
    }
  }

  Future<void> _audioPanel(BuildContext context) async {
    final player = _player!;
    Future<void> audioControls() => _sliderPanel(context, 'Audio controls', const [
      ('audio-delay', 'Delay (seconds)', -5, 5, 0),
      ('balance', 'Left / right balance', -1, 1, 0),
    ]);
    final selected = await showAuralisDialog<_PanelAction>(
      context: context,
      builder: (dialog) => _VideoPanel(
        title: 'Audio tracks',
        detail: 'Choose the soundtrack for this video.',
        icon: Icons.headphones_rounded,
        content: _trackChoices<_PanelAction>([
          for (final track in player.state.tracks.audio)
            _trackOption<_PanelAction>(
              () => player.setAudioTrack(track), track.id, track.title, track.language,
              icon: Icons.audiotrack_rounded,
              selected: track.id == player.state.track.audio.id,
              offHint: 'Mute the soundtrack',
            ),
        ], (action) => Navigator.pop(dialog, action)),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(dialog, audioControls),
            icon: const Icon(Icons.tune_rounded),
            label: const Text('Delay and balance'),
          ),
        ],
      ),
    );
    if (_canPlay && context.mounted && selected != null) await selected();
  }

  Future<void> _subtitleFile() async {
    final player = _player!;
    if (Platform.isAndroid) {
      const platform = MethodChannel('app.auralis/platform');
      final uri = await _withFilePicker(
        () => platform.invokeMethod<String>('openDocument'),
      );
      if (!_canPlay || uri == null) return;
      final bytes = await platform.invokeMethod<Uint8List>('readDocument', {
        'uri': uri,
        'maxBytes': 4 * 1024 * 1024,
      });
      if (_canPlay && bytes != null) {
        await player.setSubtitleTrack(
          mpv.SubtitleTrack.data(
            utf8.decode(bytes, allowMalformed: true),
            title: 'External subtitles',
          ),
        );
      }
    } else {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Subtitles',
            extensions: ['srt', 'ass', 'ssa', 'vtt', 'sub', 'sup', 'idx'],
          ),
        ],
      );
      if (_canPlay && file != null) {
        await player.setSubtitleTrack(
          mpv.SubtitleTrack.uri(
            File(file.path).uri.toString(),
            title: file.name,
          ),
        );
      }
    }
  }

  Future<void> _subtitlesPanel(BuildContext context) async {
    final player = _player!;
    final playerContext = context;
    var showOptions = false;
    final selected = await showAuralisDialog<_PanelAction>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void select(_PanelAction action) => Navigator.pop(dialog, action);
          return _VideoPanel(
            title: showOptions ? 'Subtitle options' : 'Subtitles',
            detail: showOptions ? null : 'Choose a subtitle track for this video.',
            icon: Icons.subtitles_outlined,
            onBack: showOptions ? () => update(() => showOptions = false) : null,
            content: showOptions
                ? Column(
                    children: [
                      _VideoOption<_PanelAction>(
                        () => _secondarySubtitlePanel(playerContext),
                        'Secondary subtitles', Icons.closed_caption_outlined,
                        detail: 'Show a second track alongside the main subtitles.',
                      ).row(select),
                      _VideoOption<_PanelAction>(
                        _subtitleFile, 'Open subtitle file', Icons.upload_file_outlined,
                      ).row(select),
                      _VideoOption<_PanelAction>(
                        () => _findWyzieSubtitles(playerContext),
                        'Search subtitles with Wyzie', Icons.search_rounded,
                      ).row(select),
                      _VideoOption<_PanelAction>(
                        () => _subtitleStylePanel(playerContext),
                        'Style, position and delay', Icons.text_fields_rounded,
                      ).row(select),
                    ],
                  )
                : _trackChoices<_PanelAction>([
                    for (final track in player.state.tracks.subtitle)
                      _trackOption<_PanelAction>(
                        () => player.setSubtitleTrack(track), track.id, track.title, track.language,
                        icon: Icons.subtitles_outlined,
                        selected: track.id == player.state.track.subtitle.id,
                        offHint: 'Hide subtitles',
                      ),
                  ], select),
            actions: [
              if (!showOptions)
                TextButton.icon(
                  onPressed: () => update(() => showOptions = true),
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Subtitle options'),
                ),
            ],
          );
        },
      ),
    );
    if (_canPlay && context.mounted && selected != null) await selected();
  }

  Future<void> _secondarySubtitlePanel(BuildContext context) async {
    final player = _player!;
    final track = await showAuralisDialog<String>(
      context: context,
      builder: (dialog) => _VideoPanel(
        title: 'Secondary subtitles',
        detail: 'Choose a second track to display.',
        icon: Icons.closed_caption_outlined,
        content: _trackChoices<String>([
          _trackOption('no', 'no', null, null,
              icon: Icons.subtitles_outlined,
              selected: _secondarySubtitle == 'no',
              offHint: 'Hide the second track'),
          for (final track in player.state.tracks.subtitle)
            if (int.tryParse(track.id) != null && track.id != player.state.track.subtitle.id)
              _trackOption(track.id, track.id, track.title, track.language,
                  icon: Icons.subtitles_outlined,
                  selected: track.id == _secondarySubtitle,
                  offHint: 'Hide the second track'),
        ], (id) => Navigator.pop(dialog, id)),
      ),
    );
    if (_canPlay && track != null) {
      await _native.setProperty('secondary-sid', track);
      _secondarySubtitle = track;
      _changed();
    }
  }

  Future<void> _subtitleStylePanel(BuildContext context) => _sliderPanel(
    context,
    'Subtitle style and timing',
    const [
      ('sub-scale', 'Primary size', .4, 2.5, 1),
      ('secondary-sub-scale', 'Secondary size', .4, 2.5, 1),
      ('sub-pos', 'Primary position', 0, 100, 100),
      ('secondary-sub-pos', 'Secondary position', 0, 100, 0),
      ('sub-delay', 'Primary delay (seconds)', -8, 8, 0),
      ('secondary-sub-delay', 'Secondary delay (seconds)', -8, 8, 0),
      ('sub-border-size', 'Outline width', 0, 10, 3),
      ('sub-shadow-offset', 'Shadow offset', 0, 8, 0),
    ],
    options: const [
      ('sub-ass-override', 'Override ASS styling', 'force', 'yes'),
      ('sub-bold', 'Bold', 'yes', 'no'),
      ('sub-italic', 'Italic', 'yes', 'no'),
    ],
  );

  Future<void> _sliderPanel(
    BuildContext context,
    String title,
    List<(String, String, double, double, double)> fields, {
    List<(String, String, String, String)> options = const [],
  }) async {
    if (!_canPlay || _player == null) return;
    final values = <String, double>{};
    final toggles = <String, bool>{};
    for (final (id, _, min, max, _) in fields) {
      if (!_canPlay) return;
      final actual = double.tryParse(await _native.getProperty(id));
      if (actual == null || !actual.isFinite) continue;
      values[id] = actual.clamp(min, max);
    }
    for (final (id, _, yes, _) in options) {
      if (!_canPlay) return;
      final actual = await _native.getProperty(id);
      if (actual.isNotEmpty) toggles[id] = actual == yes;
    }
    if (!context.mounted || !_canPlay) return;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AuralisDialog(
          title: Text(title),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (values.isEmpty && toggles.isEmpty)
                const Text('The decoder exposes no controls here.'),
              for (final (id, label, min, max, _) in fields)
                if (values[id] case final double value) ...[
                  Text('$label · ${value.toStringAsFixed(2)}'),
                  Slider(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: (next) => update(() => values[id] = next),
                    onChangeEnd: (next) =>
                        unawaited(_setOption(id, next.toStringAsFixed(3))),
                  ),
                ],
              for (final (id, label, yes, no) in options)
                if (toggles[id] case final bool enabled)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    value: enabled,
                    onChanged: (next) {
                      update(() => toggles[id] = next);
                      unawaited(_setOption(id, next ? yes : no));
                    },
                  ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setOption(String name, String value) async {
    if (_canPlay && _player != null) {
      try {
        await _native.setProperty(name, value);
        if (VideoPlaybackData.isSubtitleStyle(name, value) &&
            _data.subtitleStyle[name] != value) {
          _data.subtitleStyle[name] = value;
          _saveSettings();
        }
      } catch (_) {
        _notice('The decoder could not change this setting.');
      }
    }
  }

  Future<void> _queuePanel(BuildContext context) async {
    final source = await showAuralisDialog<VideoSource>(
      context: context,
      builder: (dialog) => ListenableBuilder(
        listenable: _changes,
        builder: (context, _) => _VideoPanel(
          title: 'Queue',
          detail: '${_index + 1} of ${_queue.length}',
          width: 480,
          maxHeight: 480,
          scrollable: false,
          content: ReorderableListView.builder(
            shrinkWrap: true,
            primary: false,
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: _queue.length,
            onReorderItem: (oldIndex, newIndex) {
              final current = _source;
              _queue.insert(newIndex, _queue.removeAt(oldIndex));
              _index = _queue.indexOf(current);
              _changed();
            },
            itemBuilder: (context, index) {
              final theme = Theme.of(context);
              final colors = theme.colorScheme;
              final entry = _queue[index];
              final current = index == _index;
              final time = entry.duration > Duration.zero
                  ? clockText(entry.duration)
                  : null;
              return Padding(
                key: ValueKey(entry.id),
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color: current
                      ? Color.alphaBlend(
                          colors.primary.withValues(alpha: .16),
                          colors.surfaceContainer,
                        )
                      : colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    dense: true,
                    minTileHeight: 50,
                    minVerticalPadding: 4,
                    minLeadingWidth: 28,
                    horizontalTitleGap: 8,
                    contentPadding: const EdgeInsetsDirectional.only(
                      start: 8,
                      end: 2,
                    ),
                    selected: current,
                    selectedColor: colors.primary,
                    leading: SizedBox(
                      width: 28,
                      child: Center(
                        child: current
                            ? Semantics(
                                label: 'Current video',
                                child: Icon(
                                  Icons.equalizer_rounded,
                                  size: 18,
                                  color: colors.primary,
                                ),
                              )
                            : Text(
                                '${index + 1}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                    title: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                        color: colors.onSurface,
                      ),
                    ),
                    subtitle: time == null
                        ? null
                        : Text(
                            time,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!current)
                          IconButton(
                            tooltip: 'Remove from queue',
                            onPressed: () {
                              final currentEntry = _source;
                              _queue.remove(entry);
                              _index = _queue.indexOf(currentEntry);
                              _changed();
                            },
                            icon: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 18,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ReorderableDragStartListener(
                          index: index,
                          child: Tooltip(
                            message: 'Drag to reorder',
                            child: SizedBox.square(
                              dimension: 44,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 20,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    onTap: () => Navigator.pop(dialog, entry),
                  ),
                ),
              );
            },
          ),
          actions: [
            FilledButton.tonalIcon(
              onPressed: () => saveVideoPlaylist(
                dialog, _data, widget.music.settings.save, List<VideoSource>.of(_queue),
              ),
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text('Save as playlist'),
            ),
            FilterChip(
              selected: _shuffle,
              showCheckmark: false,
              onSelected: (selected) {
                _shuffle = selected;
                _changed();
              },
              avatar: Icon(
                _shuffle ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
                size: 18,
              ),
              label: const Text('Shuffle'),
            ),
          ],
        ),
      ),
    );
    if (_canPlay && source != null) await _switchTo(_queue.indexOf(source));
  }

  Future<void> _chapterStep(int direction) async {
    if (_chapters.isEmpty) await _readChapters();
    if (!_canPlay) return;
    final offset = const Duration(milliseconds: 750) * direction;
    final at = _position + offset;
    final target = direction > 0
        ? _chapters.where((point) => point.position > at).firstOrNull
        : _chapters.where((point) => point.position < at).lastOrNull;
    if (target != null) await _seek(target.position);
  }

  Future<void> _chaptersPanel(BuildContext context) async {
    if (_chapters.isEmpty) await _readChapters();
    if (!_canPlay || !context.mounted) return;
    final id = _source.id;
    final choice = await showAuralisDialog<Duration>(
      context: context,
      builder: (dialog) => ListenableBuilder(
        listenable: _changes,
        builder: (context, _) {
          final at = _position + const Duration(milliseconds: 350);
          final current = _chapters
              .where((point) => point.position <= at)
              .lastOrNull;
          return _VideoPanel(
            title: 'Chapters and bookmarks',
            icon: Icons.bookmarks_outlined,
            detail: 'Choose a point to jump to.',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _VideoSectionLabel('Chapters'),
                if (_chapters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text('No chapters in this video.'),
                  ),
                for (final chapter in _chapters)
                  _VideoMenuRow(
                    label: chapter.name,
                    icon: identical(current, chapter)
                        ? Icons.play_circle_outline_rounded
                        : Icons.flag_outlined,
                    trailing: Text(clockText(chapter.position)),
                    selected: identical(current, chapter),
                    onTap: () => Navigator.pop(dialog, chapter.position),
                  ),
                const _VideoSectionLabel('Bookmarks'),
                if (_bookmarks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text('No bookmarks yet.'),
                  ),
                for (final point in _bookmarks)
                  AuralisChoiceTile(
                    leading: const Icon(Icons.bookmark_rounded),
                    title: Text(point.name),
                    subtitle: Text(clockText(point.position)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Rename bookmark',
                          onPressed: () => unawaited(
                            _editBookmark(dialog, existing: point),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                        IconButton(
                          tooltip: 'Delete bookmark',
                          onPressed: () {
                            _data.setBookmarks(
                              id,
                              _bookmarks
                                  .where((bookmark) => bookmark != point)
                                  .toList(),
                            );
                            _saveSettings();
                            _changed();
                          },
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                    onTap: () => Navigator.pop(dialog, point.position),
                  ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () => unawaited(_editBookmark(dialog)),
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Add bookmark'),
              ),
            ],
          );
        },
      ),
    );
    if (choice != null && _canPlay && id == _source.id) await _seek(choice);
  }

  Future<void> _editBookmark(
    BuildContext context, {
    VideoBookmark? existing,
  }) async {
    final id = _source.id;
    final time = existing?.position ?? _position;
    if (_duration <= Duration.zero) return;
    var name = existing?.name ?? 'Bookmark at ${clockText(time)}';
    final result = await showAuralisDialog<String>(
      context: context,
      builder: (dialog) => AuralisDialog(
        title: Text(existing == null ? 'Add bookmark' : 'Rename bookmark'),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          maxLength: 80,
          onChanged: (value) => name = value,
          onFieldSubmitted: (_) => Navigator.pop(dialog, name.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, name.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!_canPlay || id != _source.id || result == null || result.isEmpty) {
      return;
    }
    _data.setBookmarks(id, [
      for (final point in _bookmarks)
        if (point != existing) point,
      VideoBookmark(time, result),
    ]);
    _saveSettings();
    _changed();
  }

  Future<void> _setLoopPoint() async {
    if (!_canPlay || _opening || _duration <= Duration.zero) return;
    if (_loopA == null) {
      _loopA = _position;
      await _setOption(
        'ab-loop-a',
        (_position.inMilliseconds / 1000).toString(),
      );
      _notice('Loop start set. Choose the end point.');
    } else if (_loopB == null) {
      final end = _position;
      if (end <= _loopA!) {
        _notice('Choose an end point after the start.');
        return;
      }
      _loopB = end;
      await _setOption('ab-loop-b', (end.inMilliseconds / 1000).toString());
      _notice('A–B loop active.');
    } else {
      _loopA = _loopB = null;
      await _setOption('ab-loop-a', 'no');
      await _setOption('ab-loop-b', 'no');
      _notice('A–B loop cleared.');
    }
    _changed();
  }

  Future<void> _orientationPanel(
    BuildContext context, {
    required bool fullscreen,
  }) async {
    final selected = await _choose<_Orientation>(context, 'Orientation', [
      for (final value in _Orientation.values)
        (value: value, label: value.label, selected: _orientation == value),
    ]);
    if (selected != null && _canPlay) {
      _data.setOrientation(_source.id, selected.name);
      _saveSettings();
      await _applyOrientation(fullscreen: fullscreen);
    }
  }

  Future<void> _zoomPanel(BuildContext context, VideoState video) async {
    final selected = await _choose<_VideoFit>(context, 'Video size and zoom', [
      for (final mode in _VideoFit.values)
        (
          value: mode,
          label: mode == _VideoFit.fit ? 'Fit and reset zoom' : mode.label,
          selected: _fit == mode,
        ),
    ]);
    if (!_canPlay || selected == null) return;
    _fit = selected;
    if (video.mounted) video.update(fit: selected.boxFit);
    if (selected == _VideoFit.fit) await _setZoom(0, x: 0, y: 0);
    _changed();
  }

  Future<void> _saveFrame() async {
    if (!_canPlay || _player == null) return;
    final source = _source;
    final position = _position;
    try {
      final bytes = await _player!.screenshot(
        format: 'image/png',
        includeLibassSubtitles: _data.snapshotSubtitles,
      );
      if (!_canPlay || _source.id != source.id || bytes == null) {
        _notice('A video frame is not available yet.');
        return;
      }
      final title = source.title.replaceAll(
        RegExp(r'[^\p{L}\p{N}._-]+', unicode: true),
        '_',
      );
      final stem = title.characters.take(72).toString();
      final filename =
          '${stem.isEmpty ? 'video' : stem}-${position.inMilliseconds}ms.png';
      await storeVideoSnapshot(bytes, filename);
      _notice('Frame saved to Video snapshots.');
    } catch (_) {
      _notice('Could not save the video frame.');
    }
  }

  Future<void> _settingsPanel(BuildContext context) async {
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          Widget toggle(String label, bool value, ValueChanged<bool> setter) =>
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label),
                value: value,
                onChanged: (next) {
                  update(() => setter(next));
                  _saveSettings();
                  _changed();
                },
              );
          return AuralisDialog(
            title: const Text('Player settings'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Seek interval · ${_data.seekSeconds} seconds'),
                Slider(
                  min: 5,
                  max: 60,
                  divisions: 11,
                  value: _data.seekSeconds.toDouble().clamp(5, 60),
                  onChanged: (value) =>
                      update(() => _data.seekSeconds = value.round()),
                  onChangeEnd: (_) => _saveSettings(),
                ),
                toggle(
                  'Tap and swipe gestures',
                  _data.gestures,
                  (value) => _data.gestures = value,
                ),
                toggle(
                  'Require double tap for every seek',
                  _data.strictDoubleTap,
                  (value) => _data.strictDoubleTap = value,
                ),
                if (Platform.isAndroid)
                  toggle(
                    'Swap brightness and volume sides',
                    _data.swapSides,
                    (value) => _data.swapSides = value,
                  ),
                toggle('Allow volume boost', _data.volumeBoost, (value) {
                  _data.volumeBoost = value;
                  if (!value && _player!.state.volume > 100) {
                    unawaited(_player!.setVolume(100));
                  }
                }),
                toggle(
                  'Play immediately when opened',
                  _data.autoplay,
                  (value) => _data.autoplay = value,
                ),
                toggle(
                  'Play next video automatically',
                  _data.autoAdvance,
                  (value) => _data.autoAdvance = value,
                ),
                toggle(
                  'Automatically skip saved segments',
                  _data.autoSkip,
                  (value) => _data.autoSkip = value,
                ),
                toggle(
                  'Include subtitles in snapshots',
                  _data.snapshotSubtitles,
                  (value) => _data.snapshotSubtitles = value,
                ),
                toggle(
                  'Continue playing in the background',
                  _data.background,
                  (value) => _data.background = value,
                ),
                if (Platform.isAndroid) ...[
                  toggle('GPU-next renderer (reopen video)', _data.gpuNext, (
                    value,
                  ) {
                    _data.gpuNext = value;
                  }),
                  toggle('Match video frame rate', _data.matchRefreshRate, (
                    value,
                  ) {
                    _data.matchRefreshRate = value;
                    unawaited(_updateRefreshRate());
                  }),
                ],
                if (Platform.isAndroid)
                  toggle(
                    'Picture in picture when leaving the app',
                    _data.autoPip,
                    (value) {
                      _data.autoPip = value;
                      unawaited(_updatePip());
                    },
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _layoutPanel(BuildContext context) async {
    var wide = MediaQuery.sizeOf(context).width >= 660;
    var zone = VideoControlZone.topEnd;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void change(VoidCallback change) {
            update(change);
            _saveSettings();
            _changed();
          }

          final items = _data.controls(zone, wide: wide);
          return AuralisDialog(
            title: const Text('Player control layout'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final landscape in [false, true])
                      ChoiceChip(
                        label: Text(landscape ? 'Landscape' : 'Portrait'),
                        selected: wide == landscape,
                        onSelected: (_) => update(() => wide = landscape),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final value in VideoControlZone.values)
                      ChoiceChip(
                        label: Text(value.label),
                        selected: zone == value,
                        onSelected: (_) => update(() => zone = value),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Buttons in this area · ${items.length}/${zone.limit}'),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    for (final control in [
                      ...items,
                      ...VideoControl.values.where(
                        (item) => !items.contains(item),
                      ),
                    ])
                      if (Platform.isAndroid ||
                          (control != VideoControl.orientation &&
                              control != VideoControl.pip))
                        FilterChip(
                          label: Text(_controlLabel(control)),
                          selected: items.contains(control),
                          onSelected:
                              items.contains(control) ||
                                  items.length < zone.limit
                              ? (enabled) => change(() {
                                  _data.setControls(
                                    zone,
                                    wide: wide,
                                    controls: [
                                      ...items.where((item) => item != control),
                                      if (enabled) control,
                                    ],
                                  );
                                })
                              : null,
                        ),
                  ],
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Transparent button backgrounds'),
                  value: _data.transparentControls,
                  onChanged: (value) =>
                      change(() => _data.transparentControls = value),
                ),
                DropdownButton<VideoControlAnimation>(
                  isExpanded: true,
                  value: _data.animation,
                  items: [
                    for (final style in VideoControlAnimation.values)
                      DropdownMenuItem(
                        value: style,
                        child: Text('Animation · ${style.label}'),
                      ),
                  ],
                  onChanged: (style) {
                    if (style != null) change(() => _data.animation = style);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    change(() => _data.setControls(zone, wide: wide)),
                child: const Text('Reset this area'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _sleepPanel(BuildContext context) async {
    final remaining = _sleepAt?.difference(DateTime.now()).inMinutes;
    final minutes = await _choose<int>(
      context,
      remaining == null
          ? 'Sleep timer'
          : 'Sleep timer · ${math.max(0, remaining)} min left',
      [
        (value: 0, label: 'Off', selected: _sleepAt == null),
        for (final minutes in const [15, 30, 45, 60, 90])
          (value: minutes, label: '$minutes minutes', selected: false),
      ],
    );
    if (!_canPlay || minutes == null) return;
    _sleepTimer?.cancel();
    _sleepAt = null;
    if (minutes > 0) {
      final duration = Duration(minutes: minutes);
      _sleepAt = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () {
        _sleepAt = null;
        if (_canPlay) unawaited(_player?.pause());
      });
    }
  }

  Future<void> _framePanel(BuildContext context) => showAuralisDialog<void>(
    context: context,
    builder: (dialog) => AuralisDialog(
      title: const Text('Frame navigation'),
      content: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final (command, icon, label) in const [
            ('frame-back-step', Icons.skip_previous_rounded, 'Previous frame'),
            ('frame-step', Icons.skip_next_rounded, 'Next frame'),
          ])
            FilledButton.tonalIcon(
              onPressed: () {
                if (_canPlay) unawaited(_native.command([command]));
              },
              icon: Icon(icon),
              label: Text(label),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  Stream<List<(String, String)>> _playbackStatistics() async* {
    while (_canPlay) {
      final rows = <(String, String)>[];
      for (final (key, label) in const [
        ('video-format', 'Video codec'),
        ('audio-codec-name', 'Audio codec'),
        ('video-params/w', 'Width'),
        ('video-params/h', 'Height'),
        ('estimated-vf-fps', 'Output FPS'),
        ('container-fps', 'Source FPS'),
        ('hwdec-current', 'Hardware decoding'),
        ('frame-drop-count', 'Dropped frames'),
        ('video-bitrate', 'Video bitrate'),
        ('audio-bitrate', 'Audio bitrate'),
        ('demuxer-cache-duration', 'Buffer duration'),
        ('video-params/primaries', 'Color primaries'),
        ('video-params/gamma', 'Transfer function'),
      ]) {
        if (!_canPlay) return;
        final value = await _native.getProperty(key);
        if (value.isNotEmpty) rows.add((label, value));
      }
      yield rows;
      await Future<void>.delayed(
        Duration(seconds: _player?.state.playing == true ? 1 : 2),
      );
    }
  }

  Future<void> _infoPanel(BuildContext context) async {
    if (!_canPlay) return;
    final statistics = _playbackStatistics();
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => AuralisDialog(
        title: const Text('Playback information'),
        content: StreamBuilder<List<(String, String)>>(
          stream: statistics,
          builder: (context, snapshot) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_source.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 10),
              if (snapshot.hasError)
                const Text('Playback statistics are unavailable.')
              else if (!snapshot.hasData)
                const LinearProgressIndicator()
              else
                for (final (label, value) in snapshot.data!)
                  Text('$label  ·  $value'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _videoFilterPanel(BuildContext context) async {
    final choice = await _choose<String>(context, 'Video processing', [
      for (final value in const [
        'Default',
        'Vivid',
        'Cinema',
        'High contrast',
        'Monochrome',
      ])
        (value: value, label: value, selected: false),
      (value: 'custom', label: 'Fine-tune picture and deband', selected: false),
    ]);
    if (choice == null || !context.mounted || !_canPlay) return;
    if (choice == 'custom') {
      await _sliderPanel(
        context,
        'Picture adjustments',
        const [
          ('brightness', 'Brightness', -100, 100, 0),
          ('contrast', 'Contrast', -100, 100, 0),
          ('saturation', 'Saturation', -100, 100, 0),
          ('gamma', 'Gamma', -100, 100, 0),
          ('hue', 'Hue', -100, 100, 0),
          ('deband-iterations', 'Deband iterations', 0, 16, 1),
          ('deband-threshold', 'Deband threshold', 0, 128, 48),
          ('deband-range', 'Deband range', 1, 128, 16),
          ('deband-grain', 'Deband grain', 0, 128, 32),
        ],
        options: const [('deband', 'GPU debanding', 'yes', 'no')],
      );
      return;
    }
    final (contrast, saturation, gamma) = switch (choice) {
      'Vivid' => (10, 30, 4),
      'Cinema' => (14, -10, -5),
      'High contrast' => (26, 8, -7),
      'Monochrome' => (12, -100, 0),
      _ => (0, 0, 0),
    };
    await _setOption('contrast', '$contrast');
    await _setOption('saturation', '$saturation');
    await _setOption('gamma', '$gamma');
  }

  Future<void> _consolePanel(BuildContext context) async {
    String input = '';
    String? error;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          Future<void> run() async {
            try {
              final command = VideoCommand.parse(input);
              if (!_canPlay) return;
              await _native.command(command, checkError: true);
              if (context.mounted) update(() => error = null);
            } on FormatException catch (failure) {
              if (context.mounted) {
                update(() => error = failure.message);
              }
            } catch (_) {
              if (context.mounted) update(() => error = 'The command failed.');
            }
          }

          return AuralisDialog(
            title: const Text('mpv console'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  onChanged: (value) => input = value,
                  onSubmitted: (_) => unawaited(run()),
                  decoration: InputDecoration(
                    hintText: '["show-text", "Ready"]',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 10),
                for (final entry in _log.reversed.take(16))
                  Text(entry, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Done'),
              ),
              FilledButton(onPressed: run, child: const Text('Run')),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleTransform({bool horizontal = true}) async {
    if (!_canPlay || _player == null) return;
    final enabled = horizontal ? !_mirror : !_flip;
    final filter = horizontal ? '@auralis-mirror:hflip' : '@auralis-flip:vflip';
    await _native.command([
      'vf',
      enabled ? 'add' : 'remove',
      enabled ? filter : filter.split(':').first,
    ]);
    if (horizontal) {
      _mirror = enabled;
    } else {
      _flip = enabled;
    }
  }

  Future<void> _morePanel(BuildContext context, VideoState video) async {
    final playerContext = context;
    final groups = <_VideoMenuGroup>[
      _VideoMenuGroup('Playback', 'Speed, queue, chapters and repeat', Icons.play_circle_outline_rounded, [
        _VideoOption(() => _speedPanel(context), 'Playback speed', Icons.speed_rounded),
        _VideoOption(() => _queuePanel(context), 'Now playing queue', Icons.queue_play_next_rounded),
        _VideoOption(() => _chaptersPanel(context), 'Chapters and bookmarks', Icons.bookmarks_outlined),
        _VideoOption(() => _chapterStep(-1), 'Previous chapter', Icons.skip_previous_rounded),
        _VideoOption(() => _chapterStep(1), 'Next chapter', Icons.skip_next_rounded),
        _VideoOption(() => _skipSegmentsPanel(context), 'Skip segments', Icons.fast_forward_rounded),
        _VideoOption(_setLoopPoint, 'A–B loop', Icons.repeat_rounded, selected: _loopA != null),
        _VideoOption(() async {
          _repeatVideo = !_repeatVideo;
          await _setOption('loop-file', _repeatVideo ? 'inf' : 'no');
        }, 'Repeat video', Icons.repeat_one_rounded, selected: _repeatVideo),
        _VideoOption(() => _sleepPanel(context), 'Sleep timer', Icons.timer_outlined, selected: _sleepAt != null),
        _VideoOption(() => _open(resume: false), 'Restart video', Icons.restart_alt_rounded),
      ]),
      _VideoMenuGroup('Audio & subtitles', 'Soundtrack, captions and timing', Icons.headphones_rounded, [
        _VideoOption(() => _audioPanel(context), 'Audio tracks', Icons.audiotrack_rounded),
        _VideoOption(() => _subtitlesPanel(context), 'Subtitles', Icons.subtitles_outlined),
      ]),
      _VideoMenuGroup('Picture & display', 'Size, lighting and video quality', Icons.aspect_ratio_rounded, [
        _VideoOption(() => _zoomPanel(context, video), 'Video size and zoom', Icons.zoom_in_rounded),
        if (Platform.isAndroid) ...[
          _VideoOption(_pictureInPicture, 'Picture in picture', Icons.picture_in_picture_alt_outlined),
          _VideoOption(
            () => _orientationPanel(context, fullscreen: isFullscreen(context)),
            'Orientation', Icons.screen_rotation_rounded,
          ),
        ],
        _VideoOption(() => _ambientPanel(context), 'Ambient lighting', Icons.light_mode_outlined, selected: _ambient != _Ambient.off),
        _VideoOption(() => _upscalePanel(context), 'Anime4K', Icons.auto_awesome_rounded, selected: _upscale != _Upscale.off),
        _VideoOption(() => _hdrPanel(context), 'HDR processing', Icons.hdr_on_rounded, selected: _activeHdr != VideoHdrProfile.off),
        _VideoOption(() => _toneMappingPanel(context), 'HDR tone mapping', Icons.tonality_rounded),
        _VideoOption(_toggleTransform, 'Mirror horizontally', Icons.flip_rounded, selected: _mirror),
        _VideoOption(() => _toggleTransform(horizontal: false), 'Flip vertically', Icons.swap_vert_rounded, selected: _flip),
        _VideoOption(() => _videoFilterPanel(context), 'Video processing', Icons.tune_rounded),
        _VideoOption(
          _detectBlackBars,
          _cropped ? 'Restore original video frame' : 'Detect and crop black bars',
          Icons.crop_rounded,
          selected: _cropped,
        ),
      ]),
      _VideoMenuGroup('Capture & edit', 'Snapshots, frame stepping and clips', Icons.photo_camera_outlined, [
        _VideoOption(_saveFrame, 'Save video frame', Icons.photo_camera_outlined),
        _VideoOption(() => _framePanel(context), 'Frame navigation', Icons.movie_outlined),
      ]),
      _VideoMenuGroup('Settings & diagnostics', 'Controls, decoder and advanced tools', Icons.settings_outlined, [
        _VideoOption(() => _settingsPanel(context), 'Player settings', Icons.settings_outlined),
        _VideoOption(() => _layoutPanel(context), 'Player control layout', Icons.dashboard_customize_outlined),
        _VideoOption(() => _customControlsPanel(context), 'Custom buttons', Icons.extension_outlined),
        _VideoOption(() => _decoderPanel(context), 'Video decoder', Icons.memory_rounded),
        _VideoOption(() => _infoPanel(context), 'Playback information', Icons.info_outline_rounded),
        _VideoOption(() => _consolePanel(context), 'mpv console', Icons.terminal_rounded),
        _VideoOption(() => _loadVideoScript(context), 'Load a player script', Icons.code_rounded),
        _VideoOption(() => _configurationPanel(context), 'mpv configuration', Icons.build_outlined),
      ]),
    ];
    final fullscreen = isFullscreen(context);
    _VideoMenuGroup? page;
    final action = await showAuralisDialog<_PanelAction>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          final group = page;
          void select(_PanelAction action) => Navigator.pop(dialog, action);
          return _VideoPanel(
            title: group?.title ?? 'Player controls',
            icon: group?.icon ?? Icons.tune_rounded,
            detail: group?.detail,
            width: 540,
            onBack: group == null ? null : () => update(() => page = null),
            content: Column(
              key: ValueKey(group?.title),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (group == null) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (widget.onMinimize case final VoidCallback minimize)
                        OutlinedButton.icon(
                          onPressed: () => select(() async {
                            if (fullscreen) await exitFullscreen(playerContext);
                            if (_canPlay) minimize();
                          }),
                          icon: const Icon(Icons.picture_in_picture_alt_outlined),
                          label: const Text('Minimize video'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => select(() => toggleFullscreen(playerContext)),
                        icon: Icon(fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                        label: Text(fullscreen ? 'Exit fullscreen' : 'Fullscreen'),
                      ),
                      if (widget.onClose case final VoidCallback close)
                        TextButton.icon(
                          onPressed: () => select(() async {
                            if (fullscreen) await exitFullscreen(playerContext);
                            if (mounted && !_closed) close();
                          }),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Close video'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final section in groups)
                    _VideoMenuRow(
                      label: section.title,
                      detail: section.detail,
                      icon: section.icon,
                      onTap: () => update(() => page = section),
                    ),
                ] else
                  for (final item in group.items) item.row(select),
              ],
            ),
          );
        },
      ),
    );
    if (_canPlay && context.mounted && action != null) {
      await action();
      _changed();
    }
  }
}
