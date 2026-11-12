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
