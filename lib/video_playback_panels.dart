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
    builder: (dialog) => AuralisDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (choices.isEmpty) const Text('No options available.'),
          for (final choice in choices)
            AuralisChoiceTile(
              title: Text(choice.label),
              selected: choice.selected,
              onTap: () => Navigator.pop(dialog, choice.value),
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

  String _trackLabel(String id, String? title, String? language) {
    if (id == 'auto') return 'Automatic';
    if (id == 'no') return 'Off';
    final names = [
      title,
      language,
    ].whereType<String>().where((part) => part.isNotEmpty);
    return names.isEmpty ? 'Track $id' : names.join(' · ');
  }

  Future<void> _speedPanel(BuildContext context) async {
    final player = _player!;
    final rate = await _choose<double>(context, 'Playback speed', [
      for (final speed in const [
        .25,
        .5,
        .75,
        1.0,
        1.25,
        1.5,
        1.75,
        2.0,
        2.5,
        3.0,
      ])
        (value: speed, label: '$speed×', selected: speed == player.state.rate),
    ]);
    if (_canPlay && rate != null) await player.setRate(rate);
  }

  Future<void> _decoderPanel(BuildContext context) async {
    final mode = await _choose<String>(context, 'Video decoder', [
      for (final (id, label) in const [
        ('auto-safe', 'HW · Automatic'),
        ('auto-copy', 'HW+ · Hardware copy-back'),
        ('no', 'SW · Software'),
      ])
        (value: id, label: label, selected: id == _decoder),
    ]);
    if (_canPlay && mode != null) {
      await _native.setProperty('hwdec', mode);
      _decoder = mode;
      _changed();
    }
  }

  Future<void> _audioPanel(BuildContext context) async {
    final player = _player!;
    final selected = await _choose<_PanelAction>(context, 'Audio tracks', [
      for (final track in player.state.tracks.audio)
        (
          value: () => player.setAudioTrack(track),
          label: _trackLabel(track.id, track.title, track.language),
          selected: track.id == player.state.track.audio.id,
        ),
      (
        value: () => _sliderPanel(context, 'Audio controls', const [
          ('audio-delay', 'Delay (seconds)', -5, 5, 0),
          ('balance', 'Left / right balance', -1, 1, 0),
        ]),
        label: 'Delay and balance',
        selected: false,
      ),
    ]);
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
    final selected = await _choose<_PanelAction>(context, 'Subtitles', [
      for (final track in player.state.tracks.subtitle)
        (
          value: () => player.setSubtitleTrack(track),
          label: _trackLabel(track.id, track.title, track.language),
          selected: track.id == player.state.track.subtitle.id,
        ),
      (
        value: () => _secondarySubtitlePanel(context),
        label: 'Secondary subtitles',
        selected: false,
      ),
      (value: _subtitleFile, label: 'Open subtitle file', selected: false),
      (
        value: () => _findWyzieSubtitles(context),
        label: 'Search subtitles with Wyzie',
        selected: false,
      ),
      (
        value: () => _subtitleStylePanel(context),
        label: 'Style, position and delay',
        selected: false,
      ),
    ]);
    if (_canPlay && context.mounted && selected != null) await selected();
  }

  Future<void> _secondarySubtitlePanel(BuildContext context) async {
    final track = await _choose<String>(context, 'Secondary subtitles', [
      (value: 'no', label: 'Off', selected: _secondarySubtitle == 'no'),
      for (final track in _player!.state.tracks.subtitle)
        if (int.tryParse(track.id) != null &&
            track.id != _player!.state.track.subtitle.id)
          (
            value: track.id,
            label: _trackLabel(track.id, track.title, track.language),
            selected: track.id == _secondarySubtitle,
          ),
    ]);
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
        builder: (context, _) => AuralisDialog(
          title: AuralisDialogTitle(
            'Now playing · ${_queue.length}',
            actions: [
              IconButton(
                tooltip: 'Save queue as video playlist',
                onPressed: () => saveVideoPlaylist(dialog, _data,
                    widget.music.settings.save, List<VideoSource>.of(_queue)),
                icon: const Icon(Icons.save_outlined),
              ),
            ],
          ),
          width: 560,
          maxWidth: 660,
          scrollable: false,
          content: SizedBox(
            height: math.min(420, MediaQuery.sizeOf(context).height * .55),
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: _queue.length,
              onReorderItem: (oldIndex, newIndex) {
                final current = _source;
                _queue.insert(newIndex, _queue.removeAt(oldIndex));
                _index = _queue.indexOf(current);
                _changed();
              },
              itemBuilder: (context, index) {
                final entry = _queue[index];
                final current = index == _index;
                final preview = entry.telegram?.coverPreview;
                return AuralisChoiceTile(
                  key: ValueKey(entry.id),
                  selected: current,
                  leading: preview == null
                      ? Icon(
                          current
                              ? Icons.equalizer_rounded
                              : Icons.video_file_outlined,
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: Image.memory(
                            preview,
                            width: 52,
                            height: 38,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.movie_outlined),
                          ),
                        ),
                  title: Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: entry.duration > Duration.zero
                      ? Text(clockText(entry.duration))
                      : null,
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
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.drag_handle_rounded),
                        ),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.pop(dialog, entry),
                );
              },
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                _shuffle = !_shuffle;
                _changed();
              },
              icon: Icon(
                _shuffle ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
              ),
              label: Text(_shuffle ? 'Shuffle on' : 'Shuffle'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Done'),
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
          return AuralisDialog(
            title: const Text('Chapters and bookmarks'),
            scrollable: false,
            content: SizedBox(
              height: math.min(380, MediaQuery.sizeOf(context).height * .50),
              child: ListView(
                children: [
                  if (_chapters.isEmpty && _bookmarks.isEmpty)
                    const Text('This video has no chapters or bookmarks.'),
                  for (final chapter in _chapters)
                    AuralisChoiceTile(
                      title: Text(chapter.name),
                      trailing: Text(clockText(chapter.position)),
                      selected: identical(current, chapter),
                      onTap: () => Navigator.pop(dialog, chapter.position),
                    ),
                  if (_bookmarks.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Bookmarks'),
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
            ),
            actions: [
              TextButton.icon(
                onPressed: () => unawaited(_editBookmark(dialog)),
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Add bookmark'),
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
    final action = await _choose<_PanelAction>(
      context,
      'More player controls',
      [
        if (widget.onMinimize case final VoidCallback minimize)
          (
            value: () async {
              if (isFullscreen(context)) await exitFullscreen(context);
              if (_canPlay) minimize();
            },
            label: 'Minimize video',
            selected: false,
          ),
        (
          value: () => _settingsPanel(context),
          label: 'Player settings',
          selected: false,
        ),
        (
          value: () => _layoutPanel(context),
          label: 'Player control layout',
          selected: false,
        ),
        (
          value: () => _customControlsPanel(context),
          label: 'Custom buttons',
          selected: false,
        ),
        (
          value: () => _speedPanel(context),
          label: 'Playback speed',
          selected: false,
        ),
        (
          value: () => _audioPanel(context),
          label: 'Audio tracks',
          selected: false,
        ),
        (
          value: () => _subtitlesPanel(context),
          label: 'Subtitles',
          selected: false,
        ),
        (
          value: () => _decoderPanel(context),
          label: 'Video decoder',
          selected: false,
        ),
        (
          value: () => _zoomPanel(context, video),
          label: 'Video size and zoom',
          selected: false,
        ),
        (
          value: () => toggleFullscreen(context),
          label: 'Toggle fullscreen',
          selected: false,
        ),
        (
          value: () => _ambientPanel(context),
          label: 'Ambient lighting',
          selected: _ambient != _Ambient.off,
        ),
        (
          value: () => _upscalePanel(context),
          label: 'Anime4K',
          selected: _upscale != _Upscale.off,
        ),
        (
          value: () => _hdrPanel(context),
          label: 'HDR processing',
          selected: _activeHdr != VideoHdrProfile.off,
        ),
        (
          value: () => _toneMappingPanel(context),
          label: 'HDR tone mapping',
          selected: false,
        ),

        (
          value: () => _queuePanel(context),
          label: 'Now playing queue',
          selected: false,
        ),
        (
          value: () => _chaptersPanel(context),
          label: 'Chapters and bookmarks',
          selected: false,
        ),
        (
          value: () => _skipSegmentsPanel(context),
          label: 'Skip segments',
          selected: _skipStart != null,
        ),
        (
          value: () => _chapterStep(-1),
          label: 'Previous chapter',
          selected: false,
        ),
        (value: () => _chapterStep(1), label: 'Next chapter', selected: false),
        (
          value: () => _sleepPanel(context),
          label: 'Sleep timer',
          selected: _sleepAt != null,
        ),
        (
          value: () => _framePanel(context),
          label: 'Frame navigation',
          selected: false,
        ),
        if (Platform.isAndroid) ...[
          (
            value: _pictureInPicture,
            label: 'Picture in picture',
            selected: false,
          ),
          (
            value: () =>
                _orientationPanel(context, fullscreen: isFullscreen(context)),
            label: 'Orientation',
            selected: false,
          ),
        ],
        (value: _setLoopPoint, label: 'A–B loop', selected: _loopA != null),
        (
          value: () async {
            _repeatVideo = !_repeatVideo;
            await _setOption('loop-file', _repeatVideo ? 'inf' : 'no');
          },
          label: 'Repeat video',
          selected: _repeatVideo,
        ),
        (
          value: _toggleTransform,
          label: 'Mirror horizontally',
          selected: _mirror,
        ),
        (
          value: () => _toggleTransform(horizontal: false),
          label: 'Flip vertically',
          selected: _flip,
        ),
        (
          value: () => _videoFilterPanel(context),
          label: 'Video processing',
          selected: false,
        ),
        (
          value: _detectBlackBars,
          label: _cropped
              ? 'Restore original video frame'
              : 'Detect and crop black bars',
          selected: _cropped,
        ),
        (
          value: () => _infoPanel(context),
          label: 'Playback information',
          selected: false,
        ),
        (value: _saveFrame, label: 'Save video frame', selected: false),
        if (isEditableVideo(_source) && _duration > Duration.zero)
          (
            value: () => _withFilePicker(() => showVideoExport(context, [_source],
                duration: _duration, position: _position)),
            label: 'Trim or compress video',
            selected: false,
          ),
        (
          value: () => _open(resume: false),
          label: 'Restart video',
          selected: false,
        ),
        (
          value: () => _consolePanel(context),
          label: 'mpv console',
          selected: false,
        ),
        (
          value: () => _loadVideoScript(context),
          label: 'Load a player script',
          selected: false,
        ),
        (
          value: () => _configurationPanel(context),
          label: 'mpv configuration',
          selected: false,
        ),
      ],
    );
    if (_canPlay && context.mounted && action != null) {
      await action();
      _changed();
    }
  }
}
