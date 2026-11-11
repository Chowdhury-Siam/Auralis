part of 'video_playback.dart';

extension _VideoHdrPipeline on _VideoPlaybackState {
  List<String> _hdrFiles(VideoHdrProfile profile) => switch (profile) {
    VideoHdrProfile.pq || VideoHdrProfile.hlg => [
      'utils/clip_both.glsl',
      'transfer-function/${profile.name}_inv.glsl',
      'tone-mapping/astra.glsl',
      'gamut-mapping/bottosson.glsl',
      'transfer-function/bt1886.glsl',
    ],
    VideoHdrProfile.gamut => [
      'transfer-function/bt1886_inv.glsl',
      'gamut-mapping/bottosson.glsl',
      'transfer-function/bt1886.glsl',
    ],
    _ => const [],
  };

  Map<String, String> _hdrOptions(VideoHdrProfile profile) {
    final linear = profile == VideoHdrProfile.linear;
    return {
      'target-colorspace-hint': linear ? 'yes' : 'no',
      'target-colorspace-hint-mode': 'target',
      'target-prim': linear ? 'auto' : 'bt.2020',
      'target-trc': switch (profile) {
        VideoHdrProfile.pq => 'pq',
        VideoHdrProfile.hlg => 'hlg',
        VideoHdrProfile.gamut => 'bt.1886',
        _ => 'auto',
      },
      'target-peak': 'auto',
      'inverse-tone-mapping': linear ? 'yes' : 'no',
      'tone-mapping': linear ? 'clip' : 'auto',
      'hdr-compute-peak': linear ? 'yes' : 'no',
      'hdr-reference-white': '203',
      'tone-mapping-visualize': 'no',
      'glsl-shader-opts': profile == VideoHdrProfile.pq
          ? 'auto_exposure_limit_positive=1.02'
          : '',
    };
  }

  Future<String> _cacheVideoShader(String name) async {
    final cache = await getTemporaryDirectory();
    final target = File.fromUri(cache.uri.resolve('auralis-shaders-v1/$name'));
    if (!await target.exists()) {
      final asset = await rootBundle.load('assets/shaders/$name');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        flush: true,
      );
    }
    return target.path;
  }

  Future<bool> _hasHdrRenderer() async =>
      _canPlay &&
      _player != null &&
      await _native.getProperty('current-vo') == 'gpu-next';

  Future<void> _applyUpscaling() {
    final operation = _shaderUpdates.then((_) => _applyVideoShaders());
    _shaderUpdates = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _applyVideoShaders() async {
    if (!_canPlay || _player == null) return;
    final desired = _data.hdrProfile;
    final profile = desired != VideoHdrProfile.off && await _hasHdrRenderer()
        ? desired
        : VideoHdrProfile.off;
    if (!_canPlay) return;
    final video = _player!.state;
    final highResolution =
        (video.width ?? 0) >= 3840 || (video.height ?? 0) >= 2160;
    final quality = _thermalLimit ? _ShaderQuality.fast : _quality;
    final paths = [
      if (!highResolution)
        for (final shader in _upscale.shaders(quality.suffix))
          'anime4k/Anime4K_$shader.glsl',
      for (final shader in _hdrFiles(profile)) 'hdr-toys/$shader',
    ];
    final files = <String>[];
    for (final path in paths) {
      if (!_canPlay) return;
      files.add(await _cacheVideoShader(path));
    }
    if (!_canPlay) return;

    if (_activeHdr != profile) {
      if (_previousHdrOptions.isEmpty && profile != VideoHdrProfile.off) {
        for (final name in _hdrOptions(profile).keys) {
          if (!_canPlay) return;
          _previousHdrOptions[name] = await _native.getProperty(name);
        }
      }
      final options = profile == VideoHdrProfile.off
          ? _previousHdrOptions
          : _hdrOptions(profile);
      for (final entry in options.entries) {
        if (!_canPlay) return;
        if (_previousHdrOptions[entry.key]?.isNotEmpty == true ||
            entry.key == 'glsl-shader-opts') {
          await _native.setProperty(entry.key, entry.value);
        }
      }
      _activeHdr = profile;
      if (profile == VideoHdrProfile.off) _previousHdrOptions.clear();
    }

    if (listEquals(files, _activeShaders)) return;
    final previous = _activeShaders;
    _activeShaders = [];
    for (final path in previous.toSet()) {
      if (!_canPlay) return;
      await _native.command(['change-list', 'glsl-shaders', 'remove', path]);
    }
    for (final path in files) {
      if (!_canPlay) return;
      await _native.command([
        'change-list',
        'glsl-shaders',
        'append',
        path,
      ], checkError: true);
      _activeShaders.add(path);
    }
  }

  Future<void> _hdrPanel(BuildContext context) async {
    final available = await _hasHdrRenderer();
    if (!_canPlay || !context.mounted) return;
    final choice = await _choose<VideoHdrProfile>(context, 'HDR processing', [
      for (final profile in VideoHdrProfile.values)
        (
          value: profile,
          label: profile.label,
          selected: profile == _data.hdrProfile,
        ),
    ]);
    if (choice == null || !_canPlay) return;
    _data.hdrProfile = choice;
    _saveSettings();
    await _updateUpscaling();
    if (!available &&
        choice != VideoHdrProfile.off &&
        _activeHdr == VideoHdrProfile.off) {
      _notice(
        Platform.isAndroid
            ? 'Enable GPU-next in Player settings, then reopen the video.'
            : 'HDR shaders require a GPU-next video output.',
      );
    }
    _changed();
  }

  Future<void> _updateRefreshRate() async {
    if (!Platform.isAndroid || !_canPlay || _player == null) return;
    try {
      final fps = _data.matchRefreshRate && !widget.minimized
          ? double.tryParse(await _native.getProperty('container-fps'))
          : null;
      if (!_canPlay) return;
      await _videoWindow.invokeMethod<void>('matchRefreshRate', fps);
    } on PlatformException {
      // The current display can decline a refresh-rate request.
    } on MissingPluginException {
      // No Android window in this runtime.
    }
  }
}
