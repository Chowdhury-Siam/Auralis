part of 'video_playback.dart';

extension _VideoPlaybackConfig on _VideoPlaybackState {
  Future<Directory> _videoToolsDirectory() async {
    if (_scripts case final Directory directory) return directory;
    final created = await (await getTemporaryDirectory()).createTemp(
      'auralis-mpv-',
    );
    if (!_canPlay || _scripts != null) {
      await created.delete(recursive: true);
      if (_scripts case final Directory directory when _canPlay) {
        return directory;
      }
      throw StateError('Video playback closed');
    }
    return _scripts = created;
  }

  Future<void> _loadConfiguration(String text, {required bool input}) async {
    if (text.trim().isEmpty) return;
    final directory = await _videoToolsDirectory();
    final file = File.fromUri(
      directory.uri.resolve(input ? 'input.conf' : 'mpv.conf'),
    );
    await file.writeAsString(text, flush: true);
    if (!_canPlay) return;
    if (input) {
      await _native.command(['load-input-conf', file.path], checkError: true);
      _customKeysLoaded = true;
    } else {
      await _native.loadConfiguration(file.path);
    }
  }

  Future<void> _applySavedConfigurations() async {
    for (final (text, input) in [
      (_data.mpvConfig, false),
      (_data.inputConfig, true),
    ]) {
      try {
        if (_canPlay) await _loadConfiguration(text, input: input);
      } catch (_) {
        _notice(
          'The player could not load ${input ? 'input.conf' : 'mpv.conf'}.',
        );
      }
    }
  }

  Future<void> _configurationPanel(BuildContext context) async {
    final input = await _choose<bool>(context, 'mpv configuration', [
      (value: false, label: 'mpv.conf', selected: _data.mpvConfig.isNotEmpty),
      (
        value: true,
        label: 'input.conf',
        selected: _data.inputConfig.isNotEmpty,
      ),
    ]);
    if (input == null || !context.mounted || !_canPlay) return;
    final filename = input ? 'input.conf' : 'mpv.conf';
    var text = input ? _data.inputConfig : _data.mpvConfig;
    String? error;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AuralisDialog(
          title: Text(filename),
          content: TextFormField(
            initialValue: text,
            minLines: 3,
            maxLines: 8,
            maxLength: 32768,
            autocorrect: false,
            onChanged: (value) => text = value,
            decoration: InputDecoration(
              hintText: input ? 'Ctrl+j seek 10' : 'keep-open=yes',
              errorText: error,
              helperText: 'Changes load when you reopen the player.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (text.length > 32768 ||
                    text.contains(String.fromCharCode(0))) {
                  update(() => error = 'Enter a valid configuration.');
                  return;
                }
                if (input) {
                  _data.inputConfig = text;
                } else {
                  _data.mpvConfig = text;
                }
                _saveSettings();
                Navigator.pop(dialog);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  String? _mpvKey(KeyEvent event) {
    if (!_customKeysLoaded) return null;
    final label = event.logicalKey.keyLabel.toLowerCase();
    if (!RegExp(r'^[a-z0-9]$').hasMatch(label)) return null;
    final keyboard = HardwareKeyboard.instance;
    return [
      if (keyboard.isControlPressed) 'Ctrl',
      if (keyboard.isAltPressed) 'Alt',
      if (keyboard.isMetaPressed) 'Meta',
      if (keyboard.isShiftPressed) 'Shift',
      label,
    ].join('+');
  }
}
