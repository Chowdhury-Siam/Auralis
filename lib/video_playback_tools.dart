part of 'video_playback.dart';

extension _VideoPlaybackTools on _VideoPlaybackState {
  Future<void> _syncplayPanel(BuildContext context) async {
    var address = '';
    var user = '';
    var room = '';
    var password = '';
    String? error;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => ListenableBuilder(
        listenable: _room,
        builder: (context, _) => StatefulBuilder(
          builder: (context, update) {
            void join() {
              try {
                final endpoint = VideoSyncplay.endpoint(address);
                if (user.trim().isEmpty || room.trim().isEmpty) {
                  throw const FormatException('Enter a name and room.');
                }
                update(() => error = null);
                unawaited(
                  _room.connect(
                    endpoint,
                    username: user.trim(),
                    roomName: room.trim(),
                    password: password,
                  ),
                );
              } on FormatException catch (failure) {
                update(() => error = failure.message);
              }
            }

            final locked = _room.connecting || _room.connected;
            final notice = error ?? _room.error;
            return AuralisDialog(
              title: const Text('Syncplay room'),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_room.connected) ...[
                    Text('Room · ${_room.room}'),
                    Text('Joined as ${_room.user}'),
                    const SizedBox(height: 8),
                    Text(_room.users.take(20).join(', ')),
                  ] else ...[
                    const Text(
                      'Open the same video on each device before joining. '
                      'The room shares the video title and synchronizes playback.',
                    ),
                    const SizedBox(height: 12),
                    for (final (label, hint, secret, setter) in [
                      (
                        'Server',
                        'syncplay.pl:8999',
                        false,
                        (String value) => address = value,
                      ),
                      (
                        'Your name',
                        null,
                        false,
                        (String value) => user = value,
                      ),
                      ('Room', null, false, (String value) => room = value),
                      (
                        'Server password (optional)',
                        null,
                        true,
                        (String value) => password = value,
                      ),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          enabled: !locked,
                          obscureText: secret,
                          maxLength: secret ? 256 : 128,
                          onChanged: setter,
                          decoration: InputDecoration(
                            labelText: label,
                            hintText: hint,
                            counterText: '',
                          ),
                        ),
                      ),
                    if (_room.connecting) const LinearProgressIndicator(),
                  ],
                  if (notice != null) Text(notice),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Done'),
                ),
                if (locked)
                  TextButton(
                    onPressed: _room.disconnect,
                    child: Text(
                      _room.connecting ? 'Cancel connection' : 'Leave room',
                    ),
                  )
                else
                  FilledButton(onPressed: join, child: const Text('Join')),
              ],
            );
          },
        ),
      ),
    );
  }

  static const _customSlots = [
    VideoControl.customOne,
    VideoControl.customTwo,
    VideoControl.customThree,
  ];

  String _controlLabel(VideoControl control) =>
      _data.commands[control]?.label ?? control.label;

  Future<void> _runCustomControl(
    BuildContext context,
    VideoControl slot,
  ) async {
    final command = _data.commands[slot];
    if (command == null) {
      await _editCommand(context, slot);
    } else if (_canPlay) {
      await _native.command(command.args, checkError: true);
    }
  }

  Future<void> _customControlsPanel(BuildContext context) async {
    final slot = await _choose<VideoControl>(context, 'Custom buttons', [
      for (final slot in _customSlots)
        (value: slot, label: _controlLabel(slot), selected: false),
    ]);
    if (slot != null && _canPlay && context.mounted) {
      await _editCommand(context, slot);
    }
  }

  Future<void> _editCommand(BuildContext context, VideoControl slot) async {
    final existing = _data.commands[slot];
    var label = existing?.label ?? '';
    var command = existing == null ? '' : jsonEncode(existing.args);
    String? error;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AuralisDialog(
          title: Text(slot.label),
          content: Column(
            children: [
              TextFormField(
                initialValue: label,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Button name'),
                onChanged: (value) => label = value,
              ),
              const SizedBox(height: 10),
              TextFormField(
                initialValue: command,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'mpv command',
                  hintText: '["show-text", "Ready"]',
                  errorText: error,
                ),
                onChanged: (value) => command = value,
              ),
            ],
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () {
                  _data.commands.remove(slot);
                  _saveSettings();
                  _changed();
                  Navigator.pop(dialog);
                },
                child: const Text('Remove'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final name = label.trim();
                  if (name.isEmpty) {
                    throw const FormatException('Enter a button name.');
                  }
                  _data.commands[slot] = VideoCommand(
                    name,
                    VideoCommand.parse(command),
                  );
                  _saveSettings();
                  _changed();
                  Navigator.pop(dialog);
                } on FormatException catch (failure) {
                  update(() => error = failure.message);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadVideoScript(BuildContext context) async {
    final extension = await _choose<String>(context, 'Load a player script', [
      (value: 'lua', label: 'Lua script', selected: false),
      (value: 'js', label: 'JavaScript script', selected: false),
    ]);
    if (!_canPlay || extension == null) return;
    final chosen = await _withFilePicker(
      () => _pickVideoDocument('mpv script', [extension]),
    );
    if (!_canPlay || chosen == null) return;
    var path = chosen.path;
    if (path == null) {
      final directory = await _videoToolsDirectory();
      final file = File.fromUri(
        directory.uri.resolve(
          'script-${DateTime.now().microsecondsSinceEpoch}.$extension',
        ),
      );
      await file.writeAsBytes(chosen.bytes);
      path = file.path;
    }
    if (_canPlay) {
      await _native.command(['load-script', path], checkError: true);
    }
  }

  Future<void> _skipSegmentsPanel(BuildContext context) async {
    final id = _source.id;
    final active = _currentSegment;
    final action = await _choose<_PanelAction>(context, 'Skip segments', [
      if (_duration > Duration.zero)
        (
          value: () => _findAniSkip(context),
          label: 'Find AniSkip segments',
          selected: false,
        ),
      if (active != null)
        (
          value: () => _seek(active.end),
          label: 'Skip ${active.label}',
          selected: false,
        ),
      (
        value: () async {
          _skipStart = _position;
          _notice('Start marked at ${clockText(_position)}.');
        },
        label: 'Mark start at ${clockText(_position)}',
        selected: false,
      ),
      if (_skipStart case final Duration start when _position > start)
        (
          value: () => _saveSkipSegment(context, start, _position),
          label: 'Mark end and save',
          selected: false,
        ),
      if (_skipStart != null)
        (
          value: () async => _skipStart = null,
          label: 'Clear start mark',
          selected: false,
        ),
      for (final segment in _segments)
        (
          value: () => _manageSkipSegment(context, segment),
          label:
              '${segment.label} · ${clockText(segment.start)}–${clockText(segment.end)}',
          selected: false,
        ),
    ]);
    if (action != null && context.mounted && _canPlay && _source.id == id) {
      await action();
      _changed();
    }
  }

  Future<void> _saveSkipSegment(
    BuildContext context,
    Duration start,
    Duration end,
  ) async {
    final id = _source.id;
    if (_segments.length >= 30) {
      _notice('This video already has 30 skip segments.');
      return;
    }
    var label = '';
    final name = await showAuralisDialog<String>(
      context: context,
      builder: (dialog) => AuralisDialog(
        title: const Text('Name skip segment'),
        content: TextField(
          autofocus: true,
          maxLength: 40,
          onChanged: (value) => label = value.trim(),
          decoration: const InputDecoration(hintText: 'Intro'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialog, label.isEmpty ? 'Intro' : label),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || !_canPlay || _source.id != id || end <= start) return;
    _data.setSkipSegments(id, [
      ..._segments,
      VideoSkipSegment(start, end, name),
    ]);
    _skipStart = null;
    _saveSettings();
    _changed();
  }

  Future<void> _manageSkipSegment(
    BuildContext context,
    VideoSkipSegment segment,
  ) async {
    final id = _source.id;
    final action = await _choose<String>(context, segment.label, [
      (value: 'seek', label: 'Go to start', selected: false),
      (value: 'remove', label: 'Remove segment', selected: false),
    ]);
    if (!_canPlay || _source.id != id) return;
    if (action == 'seek') await _seek(segment.start);
    if (action == 'remove') {
      _data.setSkipSegments(
        id,
        _segments.where((item) => item != segment).toList(),
      );
      _saveSettings();
      _changed();
    }
  }
}
