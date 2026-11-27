part of 'video_playback.dart';

typedef _PanelAction = Future<void> Function();
typedef _VideoChoice<T> = ({T value, String label, bool selected});

String _videoSpeedLabel(double rate) => rate
    .toStringAsFixed(2)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

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
    String autoHint = 'Use the default track',
  }) {
    if (id == 'auto') {
      return _VideoOption(
        value,
        'Automatic',
        Icons.auto_awesome_rounded,
        detail: autoHint,
        selected: selected,
      );
    }
    if (id == 'no') {
      return _VideoOption(
        value,
        'Off',
        Icons.block_rounded,
        detail: offHint,
        selected: selected,
      );
    }
    final tag =
        language?.trim().toLowerCase().split(RegExp('[-_]')).first ?? '';
    final languageName = switch (tag) {
      'en' || 'eng' || 'english' => 'English',
      'ja' || 'jp' || 'jpn' || 'jap' || 'japan' || 'japanese' => 'Japanese',
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
    final label = name != null && name.isNotEmpty
        ? name
        : languageName ?? 'Track $id';
    return _VideoOption(
      value,
      label,
      icon,
      detail: languageName?.toLowerCase() == label.toLowerCase()
          ? null
          : languageName,
      selected: selected,
    );
  }

  Widget _trackChoices<T>(
    List<_VideoOption<T>> options,
    ValueChanged<T> select,
  ) {
    bool isMode(_VideoOption<T> option) =>
        option.icon == Icons.auto_awesome_rounded ||
        option.icon == Icons.block_rounded;
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
    var rate = player.state.rate.clamp(.25, 4.0);
    await _showPlaybackSheet<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void apply(double next) {
            final value = ((next.clamp(.25, 4.0) * 20).round()) / 20;
            update(() => rate = value);
            if (_canPlay) {
              unawaited(
                player.setRate(value).catchError((Object _) {
                  _notice('Playback speed could not be changed.');
                }),
              );
            }
          }

          return _VideoPanel(
            title: 'Playback speed',
            icon: Icons.speed_rounded,
            width: 520,
            embedded: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_videoSpeedLabel(rate)}×',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: rate <= .25 ? null : () => apply(rate - .05),
                      tooltip: 'Decrease speed',
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('video-speed-slider'),
                        min: .25,
                        max: 4,
                        divisions: 75,
                        value: rate,
                        semanticFormatterCallback: (value) =>
                            '${_videoSpeedLabel(value)}×',
                        onChanged: (value) => update(() => rate = value),
                        onChangeEnd: apply,
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: rate >= 4 ? null : () => apply(rate + .05),
                      tooltip: 'Increase speed',
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    spacing: 6,
                    children: [
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
                        4.0,
                      ])
                        ChoiceChip(
                          label: Text('${_videoSpeedLabel(speed)}×'),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          showCheckmark: false,
                          selected: speed == rate,
                          onSelected: (_) => apply(speed),
                        ),
                    ],
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Audio pitch correction'),
                  value: _data.audioPitchCorrection,
                  onChanged: (enabled) async {
                    if (!_canPlay) return;
                    try {
                      await _native.setProperty(
                        'audio-pitch-correction',
                        enabled ? 'yes' : 'no',
                      );
                      _data.audioPitchCorrection = enabled;
                      _saveSettings();
                      if (context.mounted) update(() {});
                    } catch (_) {
                      _notice('Pitch correction could not be changed.');
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => apply(1), child: const Text('Reset')),
              FilledButton.tonal(
                onPressed: rate == _data.defaultVideoSpeed
                    ? null
                    : () {
                        update(() => _data.defaultVideoSpeed = rate);
                        _saveSettings();
                      },
                child: const Text('Make default speed'),
              ),
            ],
          );
        },
      ),
    );
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
              (
                'auto-safe',
                'Automatic',
                'Recommended. Uses hardware when supported.',
                Icons.auto_awesome_rounded,
              ),
              (
                'auto-copy',
                'Hardware copy-back',
                'Try this if automatic mode has display issues.',
                Icons.layers_outlined,
              ),
              (
                'no',
                'Software',
                'Uses the CPU. Can help with hardware decoding issues.',
                Icons.memory_rounded,
              ),
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
    Future<void> audioControls() =>
        _sliderPanel(context, 'Audio controls', const [
          ('audio-delay', 'Delay (seconds)', -5, 5, 0),
          ('balance', 'Left / right balance', -1, 1, 0),
        ]);
    final selected = await _showPlaybackSheet<_PanelAction>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => _VideoPanel(
          title: 'Audio tracks',
          icon: Icons.headphones_rounded,
          embedded: true,
          width: 520,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _VideoMenuRow(
                label: 'Add external audio',
                icon: Icons.add_rounded,
                onTap: () => Navigator.pop(dialog, _audioFile),
              ),
              _trackChoices<_PanelAction>([
                for (final track in player.state.tracks.audio)
                  _trackOption<_PanelAction>(
                    () => _selectAudioTrack(track),
                    track.id,
                    track.title,
                    track.language,
                    icon: Icons.audiotrack_rounded,
                    selected: track.id == player.state.track.audio.id,
                    offHint: 'Mute the soundtrack',
                    autoHint: 'Prefer Japanese when available',
                  ),
              ], (action) => Navigator.pop(dialog, action)),
              const _VideoSectionLabel('Audio channels'),
              Wrap(
                spacing: 6,
                children: [
                  for (final (value, label) in const [
                    ('auto', 'Auto'),
                    ('auto-safe', 'Auto safe'),
                    ('mono', 'Mono'),
                    ('stereo', 'Stereo'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: value == _audioChannels,
                      onSelected: (_) async {
                        if (!_canPlay || value == _audioChannels) return;
                        try {
                          await _native.setProperty('audio-channels', value);
                          _audioChannels = value;
                          if (context.mounted) update(() {});
                        } catch (_) {
                          _notice('This audio channel layout is unavailable.');
                        }
                      },
                    ),
                ],
              ),
              const _VideoSectionLabel('Audio processing'),
              for (final (id, label, filter) in const [
                (
                  'normalize',
                  'Volume normalization',
                  'lavfi=[dynaudnorm=f=100:g=5]',
                ),
                (
                  'compress',
                  'Dynamic range compression',
                  'lavfi=[acompressor]',
                ),
              ])
                SwitchListTile(
                  dense: true,
                  title: Text(label),
                  value: _activeAudioFilters.contains(id),
                  onChanged: (enabled) async {
                    if (!_canPlay) return;
                    try {
                      final name = '@auralis-$id';
                      await _native.command([
                        'af',
                        enabled ? 'add' : 'remove',
                        enabled ? '$name:$filter' : name,
                      ]);
                      if (enabled) {
                        _activeAudioFilters.add(id);
                      } else {
                        _activeAudioFilters.remove(id);
                      }
                      if (context.mounted) update(() {});
                    } catch (_) {
                      _notice('This audio filter is unavailable.');
                    }
                  },
                ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(dialog, audioControls),
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Delay and balance'),
            ),
          ],
        ),
      ),
    );
    if (_canPlay && context.mounted && selected != null) await selected();
  }

  Future<void> _audioFile() async {
    final generation = _trackGeneration;
    String? uri;
    var title = 'External audio';
    if (Platform.isAndroid) {
      const platform = MethodChannel('app.auralis/platform');
      uri = await _withFilePicker(
        () =>
            platform.invokeMethod<String>('openDocument', {'mime': 'audio/*'}),
      );
    } else {
      final file = await _withFilePicker(
        () => openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Audio',
              extensions: [
                'aac',
                'ac3',
                'flac',
                'm4a',
                'mp3',
                'ogg',
                'opus',
                'wav',
              ],
            ),
          ],
        ),
      );
      uri = file == null ? null : File(file.path).uri.toString();
      title = file?.name ?? title;
    }
    if (!_canPlay ||
        _opening ||
        generation != _trackGeneration ||
        uri == null) {
      return;
    }
    final media = mpv.Media(uri);
    _externalAudio.add(media);
    await _selectAudioTrack(mpv.AudioTrack.uri(media.uri, title: title));
  }

  Future<void> _subtitleFile() async {
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
        await _selectSubtitleTrack(
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
        await _selectSubtitleTrack(
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
    final selected = await _showPlaybackSheet<_PanelAction>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void select(_PanelAction action) => Navigator.pop(dialog, action);
          return _VideoPanel(
            title: showOptions ? 'Subtitle options' : 'Subtitles',
            detail: showOptions
                ? null
                : _source.channelId == null
                ? 'Choose a subtitle track for this video.'
                : 'Your subtitle track choice is saved for this channel.',
            icon: Icons.subtitles_outlined,
            embedded: true,
            width: 520,
            onBack: showOptions
                ? () => update(() => showOptions = false)
                : null,
            content: showOptions
                ? Column(
                    children: [
                      _VideoOption<_PanelAction>(
                        () => _secondarySubtitlePanel(playerContext),
                        'Secondary subtitles',
                        Icons.closed_caption_outlined,
                        detail:
                            'Show a second track alongside the main subtitles.',
                      ).row(select),
                      _VideoOption<_PanelAction>(
                        () => _findWyzieSubtitles(playerContext),
                        'Search subtitles with Wyzie',
                        Icons.search_rounded,
                      ).row(select),
                      _VideoOption<_PanelAction>(
                        () => _subtitleStylePanel(playerContext),
                        'Style, position and delay',
                        Icons.text_fields_rounded,
                      ).row(select),
                    ],
                  )
                : Column(
                    children: [
                      _VideoMenuRow(
                        label: 'Add external subtitles',
                        icon: Icons.add_rounded,
                        onTap: () => select(_subtitleFile),
                      ),
                      _trackChoices<_PanelAction>([
                        for (final track in player.state.tracks.subtitle)
                          _trackOption<_PanelAction>(
                            () => _selectSubtitleTrack(track),
                            track.id,
                            track.title,
                            track.language,
                            icon: Icons.subtitles_outlined,
                            selected:
                                track.id == player.state.track.subtitle.id,
                            offHint: 'Hide subtitles',
                            autoHint: 'Prefer English when available',
                          ),
                      ], select),
                    ],
                  ),
            actions: [
              if (!showOptions) ...[
                IconButton(
                  onPressed: () =>
                      select(() => _findWyzieSubtitles(playerContext)),
                  tooltip: 'Search subtitles with Wyzie',
                  icon: const Icon(Icons.search_rounded),
                ),
                IconButton(
                  onPressed: () =>
                      select(() => _subtitleStylePanel(playerContext)),
                  tooltip: 'Style, position and delay',
                  icon: const Icon(Icons.palette_outlined),
                ),
                TextButton.icon(
                  onPressed: () => update(() => showOptions = true),
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Subtitle options'),
                ),
              ],
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
          _trackOption(
            'no',
            'no',
            null,
            null,
            icon: Icons.subtitles_outlined,
            selected: _secondarySubtitle == 'no',
            offHint: 'Hide the second track',
          ),
          for (final track in player.state.tracks.subtitle)
            if (int.tryParse(track.id) != null &&
                track.id != player.state.track.subtitle.id)
              _trackOption(
                track.id,
                track.id,
                track.title,
                track.language,
                icon: Icons.subtitles_outlined,
                selected: track.id == _secondarySubtitle,
                offHint: 'Hide the second track',
              ),
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
        final generation = _trackGeneration;
        await _native.setProperty(name, value);
        final level = name == 'brightness' ? double.tryParse(value) : null;
        if (level != null &&
            level.isFinite &&
            _canPlay &&
            !_opening &&
            generation == _trackGeneration) {
          if (_source.channelId == null) _localPictureBrightness = level;
          _pictureBrightnessChanged = true;
          _rememberChannelSettings(
            (settings) => settings.pictureBrightness = level,
          );
        }
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

  Widget _queueItemActions(BuildContext dialog, VideoSource entry) =>
      IconButton.filledTonal(
        tooltip: 'Video actions for ${entry.title}',
        icon: const Icon(Icons.more_vert_rounded, size: 20),
        onPressed: () async {
          final action = await showVideoItemSheet(
            context: dialog,
            source: entry,
            data: _data,
            playNext: entry.id != _source.id,
            telegram: widget.telegram,
            removeLabel: entry.id == _source.id ? null : 'Remove from queue',
          );
          if (!_canPlay || !dialog.mounted || action == null) return;
          final index = _queue.indexWhere((source) => source.id == entry.id);
          if (index < 0) return;
          switch (action) {
            case 'play':
              Navigator.pop(dialog, _queue[index]);
            case 'watched':
              _data.setWatched(entry, !_data.isWatched(entry));
              _saveSettings();
              widget.onWatched?.call();
              _changed();
            case 'next' || 'remove':
              if (entry.id == _source.id) return;
              final current = _source;
              final selected = _queue.removeAt(index);
              _index = _queue.indexOf(current);
              if (action == 'next') _queue.insert(_index + 1, selected);
              _queueChanged();
          }
        },
      );

  Future<void> _queuePanel(BuildContext context) async {
    final source = await _showPlaybackSheet<VideoSource>(
      context: context,
      builder: (dialog) => ListenableBuilder(
        listenable: _changes,
        builder: (context, _) => _VideoPanel(
          title: 'Queue',
          detail: '${_queue.length} ${_queue.length == 1 ? 'video' : 'videos'}',
          width: 560,
          embedded: true,
          maxHeight: 480,
          scrollable: false,
          content: _queueGrid
              ? _queueGridView(dialog)
              : ReorderableListView.builder(
                  physics: const ClampingScrollPhysics(),
                  shrinkWrap: true,
                  primary: false,
                  padding: EdgeInsets.zero,
                  buildDefaultDragHandles: false,
                  itemCount: _queue.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final current = _source;
                    _queue.insert(newIndex, _queue.removeAt(oldIndex));
                    _index = _queue.indexOf(current);
                    _queueChanged();
                  },
                  itemBuilder: (context, index) {
                    final theme = Theme.of(context);
                    final colors = theme.colorScheme;
                    final entry = _queue[index];
                    final current = index == _index;
                    final info = _queueVideoDetails(entry);
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
                            width: 66,
                            height: 38,
                            child: _queuePreview(entry, index),
                          ),
                          title: Text(
                            entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: current
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                          subtitle: info.isEmpty
                              ? null
                              : Text(
                                  info,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _queueItemActions(dialog, entry),
                              if (!current)
                                IconButton(
                                  tooltip: 'Remove from queue',
                                  onPressed: () {
                                    final currentEntry = _source;
                                    _queue.remove(entry);
                                    _index = _queue.indexOf(currentEntry);
                                    _queueChanged();
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
            IconButton(
              tooltip: _queueGrid ? 'Show queue as list' : 'Show queue as grid',
              icon: Icon(
                _queueGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
              ),
              onPressed: () {
                _queueGrid = !_queueGrid;
                _changed();
              },
            ),
            FilterChip(
              selected: _shuffle,
              showCheckmark: false,
              onSelected: (selected) {
                _shuffle = selected;
                _queueChanged();
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

  String _queueVideoDetails(VideoSource entry) {
    final time = _data.durationOf(entry);
    final width = entry.telegram?.videoWidth;
    final height = entry.telegram?.videoHeight;
    return [
      if (time > Duration.zero) clockText(time),
      if (width != null && height != null) '$width×$height',
    ].join(' · ');
  }

  Widget _queuePreview(VideoSource entry, int index) {
    final current = index == _index;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoSourcePreview(entry),
          PositionedDirectional(
            top: 4,
            start: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .68),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: current
                    ? const Icon(
                        Icons.equalizer_rounded,
                        size: 14,
                        color: Colors.white,
                        semanticLabel: 'Current video',
                      )
                    : Text(
                        '${index + 1}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _queueGridView(BuildContext dialog) => GridView.builder(
    key: const ValueKey('video-queue-grid'),
    shrinkWrap: true,
    primary: false,
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 190,
      mainAxisExtent: 144,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
    ),
    itemCount: _queue.length,
    itemBuilder: (context, index) {
      final entry = _queue[index];
      final details = _queueVideoDetails(entry);
      final colors = Theme.of(context).colorScheme;
      return Material(
        color: index == _index
            ? colors.secondaryContainer
            : colors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pop(dialog, entry),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _queuePreview(entry, index)),
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 4),
                        child: Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    _queueItemActions(dialog, entry),
                  ],
                ),
                if (details.isNotEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 4,
                      bottom: 3,
                    ),
                    child: Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

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
                          onPressed: () =>
                              unawaited(_editBookmark(dialog, existing: point)),
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

  Future<void> _orientationPanel(BuildContext context) async {
    final selected = await _choose<_Orientation>(context, 'Orientation', [
      for (final value in _Orientation.values)
        (value: value, label: value.label, selected: _orientation == value),
    ]);
    if (selected != null && _canPlay) {
      _data.setOrientation(_source.id, selected.name);
      _saveSettings();
      await _applyOrientation();
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
      final stem = String.fromCharCodes(title.runes.take(48));
      final filename =
          '${stem.isEmpty ? 'video' : stem}-${position.inMilliseconds}ms.png';
      await storeVideoSnapshot(bytes, filename);
      _notice(
        Platform.isAndroid
            ? 'Snapshot saved to Download/Snapshots.'
            : 'Snapshot saved to Snapshots in Downloads.',
      );
    } on PlatformException catch (error) {
      _notice(error.message ?? 'Could not save the video frame.');
    } catch (_) {
      _notice('Could not save the video frame.');
    }
  }

  Future<void> _videoSettingsPanel(BuildContext context) =>
      showAuralisDialog<void>(
        context: context,
        builder: (dialog) => VideoSettingsDialog(
          title: 'Settings & diagnostics',
          icon: Icons.tune_rounded,
          description: 'Personalize Video and inspect the current playback.',
          content: VideoSettingsOptions(
            settings: widget.music.settings,
            onChanged: _changed,
            onVolumeBoostDisabled: () {
              final player = _player;
              if (_canPlay && player != null && player.state.volume > 100) {
                unawaited(_setVideoVolume(100));
              }
            },
            onFrameRateChanged: () => unawaited(_updateRefreshRate()),
            onAutoPipChanged: () => unawaited(_updatePip()),
            diagnostics: {
              VideoDiagnostic.decoder: _decoderPanel,
              VideoDiagnostic.information: _infoPanel,
              VideoDiagnostic.console: _consolePanel,
              VideoDiagnostic.script: _loadVideoScript,
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Done'),
            ),
          ],
        ),
      );

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
      builder: (dialog) => VideoSettingsDialog(
        title: 'Playback information',
        icon: Icons.monitor_heart_outlined,
        description: 'Live details from the current video.',
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
                VideoSettingsGroup(
                  title: 'Playback health',
                  children: [
                    for (final (label, value) in snapshot.data!)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Flexible(
                              child: SelectableText(
                                value,
                                textAlign: TextAlign.end,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
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

          return VideoSettingsDialog(
            title: 'mpv console',
            icon: Icons.terminal_rounded,
            description:
                'Run a JSON command for this player. Recent logs appear below.',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', height: 1.5),
                  onChanged: (value) => input = value,
                  onSubmitted: (_) => unawaited(run()),
                  decoration: InputDecoration(
                    hintText: '["show-text", "Ready"]',
                    labelText: 'Command',
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 10),
                VideoSettingsGroup(
                  title: 'Recent logs',
                  children: [
                    if (_log.isEmpty) const Text('No log entries yet.'),
                    for (final entry in _log.reversed.take(16))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: SelectableText(
                          entry,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace', height: 1.5),
                        ),
                      ),
                  ],
                ),
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

  List<_VideoMenuGroup> _videoControlGroups(
    BuildContext context,
    VideoState video,
  ) => <_VideoMenuGroup>[
    _VideoMenuGroup(
      'Playback',
      'Speed, queue, chapters and repeat',
      Icons.play_circle_outline_rounded,
      [
        _VideoOption(
          () => _speedPanel(context),
          'Playback speed',
          Icons.speed_rounded,
        ),
        _VideoOption(
          () => _queuePanel(context),
          'Now playing queue',
          Icons.queue_play_next_rounded,
        ),
        _VideoOption(
          () => _chaptersPanel(context),
          'Chapters and bookmarks',
          Icons.bookmarks_outlined,
        ),
        _VideoOption(
          () => _skipSegmentsPanel(context),
          'Skip segments',
          Icons.fast_forward_rounded,
        ),
        _VideoOption(
          () async {
            _repeatVideo = !_repeatVideo;
            await _setOption('loop-file', _repeatVideo ? 'inf' : 'no');
          },
          'Repeat video',
          Icons.repeat_one_rounded,
          selected: _repeatVideo,
        ),
        _VideoOption(
          () => _sleepPanel(context),
          'Sleep timer',
          Icons.timer_outlined,
          selected: _sleepAt != null,
        ),
        _VideoOption(
          () => _open(resume: false),
          'Restart video',
          Icons.restart_alt_rounded,
        ),
      ],
    ),
    _VideoMenuGroup(
      'Audio & subtitles',
      'Soundtrack, captions and timing',
      Icons.headphones_rounded,
      [
        _VideoOption(
          () => _audioPanel(context),
          'Audio tracks',
          Icons.audiotrack_rounded,
        ),
        _VideoOption(
          () => _subtitlesPanel(context),
          'Subtitles',
          Icons.subtitles_outlined,
        ),
      ],
    ),
    _VideoMenuGroup(
      'Picture & display',
      'Size, lighting and picture processing',
      Icons.aspect_ratio_rounded,
      [
        _VideoOption(
          () => _zoomPanel(context, video),
          'Video size and zoom',
          Icons.zoom_in_rounded,
        ),
        if (Platform.isAndroid) ...[
          _VideoOption(
            _pictureInPicture,
            'Picture in picture',
            Icons.picture_in_picture_alt_outlined,
          ),
          _VideoOption(
            () => _orientationPanel(context),
            'Orientation',
            Icons.screen_rotation_rounded,
          ),
        ],
        _VideoOption(
          () => _ambientPanel(context),
          'Ambient lighting',
          Icons.light_mode_outlined,
          selected: _ambient != _Ambient.off,
        ),
        _VideoOption(
          () => _upscalePanel(context),
          'Anime4K',
          Icons.auto_awesome_rounded,
          selected: _upscale != _Upscale.off,
        ),
        _VideoOption(
          () => _hdrPanel(context),
          'HDR processing',
          Icons.hdr_on_rounded,
          selected: _activeHdr != VideoHdrProfile.off,
        ),
        _VideoOption(
          () => _toneMappingPanel(context),
          'HDR tone mapping',
          Icons.tonality_rounded,
        ),
        _VideoOption(
          _toggleTransform,
          'Mirror horizontally',
          Icons.flip_rounded,
          selected: _mirror,
        ),
        _VideoOption(
          () => _toggleTransform(horizontal: false),
          'Flip vertically',
          Icons.swap_vert_rounded,
          selected: _flip,
        ),
        _VideoOption(
          () => _videoFilterPanel(context),
          'Video processing',
          Icons.tune_rounded,
        ),
        _VideoOption(
          _detectBlackBars,
          _cropped
              ? 'Restore original video frame'
              : 'Detect and crop black bars',
          Icons.crop_rounded,
          selected: _cropped,
        ),
      ],
    ),
    _VideoMenuGroup(
      'Capture & edit',
      'Snapshots, frame stepping and clips',
      Icons.photo_camera_outlined,
      [
        _VideoOption(
          _saveFrame,
          'Save video frame',
          Icons.photo_camera_outlined,
        ),
        _VideoOption(
          () => _framePanel(context),
          'Frame navigation',
          Icons.movie_outlined,
        ),
      ],
    ),
  ];
  Future<void> _controlsDrawer(BuildContext context, VideoState video) async {
    final controls = [
      _VideoOption<_PanelAction>(
        () => _decoderPanel(context),
        'Video decoder',
        Icons.memory_rounded,
      ),
      _VideoOption<_PanelAction>(
        () => _infoPanel(context),
        'Playback information',
        Icons.monitor_heart_outlined,
      ),
      for (final group in _videoControlGroups(context, video)) ...group.items,
    ];
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final action = await showGeneralDialog<_PanelAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black38,
      transitionDuration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 210),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: animation.drive(
          Tween(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        textDirection: Directionality.of(context),
        child: child,
      ),
      pageBuilder: (dialog, _, _) => SafeArea(
        minimum: const EdgeInsets.all(8),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: _VideoPanel(
            title: 'Controls drawer',
            width: 396,
            maxHeight: MediaQuery.sizeOf(dialog).height - 16,
            embedded: true,
            scrollable: false,
            content: GridView.builder(
              key: const ValueKey('video-controls-drawer'),
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              primary: false,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 128,
                mainAxisExtent: 86,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: controls.length,
              itemBuilder: (context, index) {
                final item = controls[index];
                final colors = Theme.of(context).colorScheme;
                final selected = item.selected == true;
                return Material(
                  color: selected
                      ? colors.primaryContainer
                      : colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.pop(dialog, item.value),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(item.icon, size: 20),
                          const SizedBox(height: 5),
                          Text(
                            item.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    if (_canPlay && context.mounted && action != null) {
      await action();
      _changed();
    }
  }

  Future<void> _morePanel(BuildContext context, VideoState video) async {
    final playerContext = context;
    final groups = _videoControlGroups(context, video);
    final fullscreen = isFullscreen(context);
    _VideoMenuGroup? page;
    final action = await _showPlaybackSheet<_PanelAction>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          final group = page;
          void select(_PanelAction action) => Navigator.pop(dialog, action);
          return _VideoPanel(
            title: group?.title ?? 'More',
            embedded: true,
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
                          icon: const Icon(
                            Icons.picture_in_picture_alt_outlined,
                          ),
                          label: const Text('Minimize video'),
                        ),
                      if (_desktopVideo)
                        OutlinedButton.icon(
                          onPressed: () =>
                              select(() => toggleFullscreen(playerContext)),
                          icon: Icon(
                            fullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                          ),
                          label: Text(
                            fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                          ),
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
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final (label, icon, open) in [
                        (
                          'Sleep timer',
                          Icons.timer_outlined,
                          () => _sleepPanel(context),
                        ),
                        (
                          'Video processing',
                          Icons.tune_rounded,
                          () => _videoFilterPanel(context),
                        ),
                        (
                          'Playback information',
                          Icons.monitor_heart_outlined,
                          () => _infoPanel(context),
                        ),
                      ])
                        ActionChip(
                          avatar: Icon(icon, size: 16),
                          label: Text(label),
                          onPressed: () => select(open),
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
                  _VideoMenuRow(
                    label: 'Video settings',
                    detail: 'Player options and playback diagnostics',
                    icon: Icons.settings_outlined,
                    onTap: () => select(() => _videoSettingsPanel(context)),
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
