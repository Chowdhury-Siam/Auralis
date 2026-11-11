part of 'video_playback.dart';

enum _Upscale {
  off('Off'),
  a('A'),
  b('B'),
  c('C'),
  aPlus('A+'),
  bPlus('B+'),
  cPlus('C+');

  const _Upscale(this.label);
  final String label;

  List<String> shaders(String quality) {
    final restore = 'Restore_CNN_$quality';
    final soft = 'Restore_CNN_Soft_$quality';
    final upscale = 'Upscale_CNN_x2_$quality';
    final denoise = 'Upscale_Denoise_CNN_x2_$quality';
    const down = 'AutoDownscalePre_x2';
    return [
      if (this != off) 'Clamp_Highlights',
      ...switch (this) {
        off => const <String>[],
        a => [restore, upscale, down, upscale],
        b => [soft, upscale, down, upscale],
        c => [denoise, down, upscale],
        aPlus => [restore, upscale, down, restore, upscale],
        bPlus => [soft, upscale, down, soft, upscale],
        cPlus => [denoise, down, restore, upscale],
      },
    ];
  }
}

enum _ShaderQuality {
  fast('Fast', 'S'),
  balanced('Balanced', 'M'),
  high('High', 'L');

  const _ShaderQuality(this.label, this.suffix);
  final String label, suffix;
}

enum _Ambient {
  off('Off'),
  glow('Glow'),
  frame('Frame extension');

  const _Ambient(this.label);
  final String label;
}

extension _PlaybackProcessing on _VideoPlaybackState {
  Future<void> _detectBlackBars() async {
    final player = _player;
    if (!_canPlay || player == null || _probingCrop) return;
    if (_cropped) {
      await _native.command([
        'vf',
        'remove',
        '@auralis-crop',
      ], checkError: true);
      _cropped = false;
      return;
    }
    if (!player.state.playing) {
      _notice('Play the video before detecting black bars.');
      return;
    }
    final source = _source.id;
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    if (width <= 0 || height <= 0) return;
    _probingCrop = true;
    const probe = '@auralis-crop-detect';
    try {
      await _native.command([
        'vf',
        'pre',
        '$probe:lavfi=[cropdetect=limit=0.094:round=2:reset=0]',
      ], checkError: true);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      if (!_canPlay || _source.id != source || _opening) return;
      final dimensions = <int>[];
      for (final property in ['w', 'h', 'x', 'y']) {
        final value = await _native.getProperty(
          'vf-metadata/auralis-crop-detect/lavfi.cropdetect.$property',
        );
        dimensions.add(int.tryParse(value) ?? -1);
      }
      if (!_canPlay || _source.id != source || _opening) return;
      final [w, h, x, y] = dimensions;
      if (w < width / 2 ||
          h < height / 2 ||
          x < 0 ||
          y < 0 ||
          x + w > width ||
          y + h > height ||
          width - w < 4 && height - h < 4) {
        _notice('No stable black bars were detected.');
        return;
      }
      await _native.command([
        'vf',
        'add',
        '@auralis-crop:lavfi=[crop=w=$w:h=$h:x=$x:y=$y]',
      ], checkError: true);
      _cropped = true;
    } catch (_) {
      if (_canPlay && _source.id == source) {
        _notice('The current decoder could not detect black bars.');
      }
    } finally {
      if (_canPlay) await _native.command(['vf', 'remove', probe]);
      _probingCrop = false;
    }
  }

  Future<void> _refreshThermal() async {
    if (!Platform.isAndroid ||
        !_canPlay ||
        _player?.state.playing != true ||
        (_upscale == _Upscale.off && _ambient == _Ambient.off)) {
      return;
    }
    try {
      final headroom = await _videoWindow.invokeMethod<double>(
        'thermalHeadroom',
      );
      if (!_canPlay || headroom == null || !headroom.isFinite) return;
      final throttled = headroom >= .75;
      if (throttled != _thermalLimit) {
        _thermalLimit = throttled;
        await _applyUpscaling();
        _changed();
      }
    } on PlatformException {
      // Some Android devices do not report thermal headroom.
    } on MissingPluginException {
      // Widget tests do not have Android thermal services.
    }
  }

  Future<void> _updateUpscaling() async {
    try {
      await _applyUpscaling();
    } catch (_) {
      if (_canPlay) _notice('Could not load the selected video shaders.');
    }
  }

  Future<void> _upscalePanel(BuildContext context) async {
    final action = await _choose<_PanelAction>(context, 'Anime4K', [
      for (final value in _Upscale.values)
        (
          value: () async {
            _upscale = value;
            await _updateUpscaling();
            final state = _player!.state;
            if (value != _Upscale.off &&
                ((state.width ?? 0) >= 3840 || (state.height ?? 0) >= 2160)) {
              _notice('Anime4K is disabled for this 4K video.');
            }
          },
          label: value.label,
          selected: value == _upscale,
        ),
      (
        value: () async {
          final quality = await _choose<_ShaderQuality>(
            context,
            'Anime4K quality',
            [
              for (final value in _ShaderQuality.values)
                (value: value, label: value.label, selected: value == _quality),
            ],
          );
          if (_canPlay && quality != null) {
            _quality = quality;
            await _updateUpscaling();
          }
        },
        label: 'Quality · ${_quality.label}',
        selected: false,
      ),
    ]);
    if (_canPlay && context.mounted && action != null) await action();
  }

  Future<void> _ambientPanel(BuildContext context) async {
    final choice = await _choose<_Ambient>(context, 'Ambient lighting', [
      for (final value in _Ambient.values)
        (value: value, label: value.label, selected: value == _ambient),
    ]);
    if (_canPlay && choice != null) {
      _ambient = choice;
      _data.ambientMode = choice.name;
      _saveSettings();
      _changed();
    }
  }

  Future<void> _toneMappingPanel(BuildContext context) async {
    final property = await _native.getProperty('tone-mapping');
    if (!_canPlay || !context.mounted) return;
    final choice = await _choose<String>(context, 'HDR tone mapping', [
      for (final (value, label) in const [
        ('auto', 'Automatic'),
        ('bt.2390', 'BT.2390'),
        ('bt.2446a', 'BT.2446A'),
        ('reinhard', 'Reinhard'),
        ('hable', 'Hable'),
        ('mobius', 'Mobius'),
      ])
        (value: value, label: label, selected: value == property),
    ]);
    if (_canPlay && choice != null) await _setOption('tone-mapping', choice);
  }
}

class _AmbientBars extends StatelessWidget {
  const _AmbientBars({
    required this.video,
    required this.mode,
    required this.thermalLimit,
  });

  final VideoController video;
  final _Ambient mode;
  final bool thermalLimit;

  @override
  Widget build(BuildContext context) {
    if (mode == _Ambient.off || thermalLimit) return const SizedBox.shrink();
    return ValueListenableBuilder<int?>(
      valueListenable: video.id,
      builder: (context, id, _) => ValueListenableBuilder<Rect?>(
        valueListenable: video.rect,
        builder: (context, rect, _) {
          if (id == null ||
              rect == null ||
              rect.width <= 1 ||
              rect.height <= 1) {
            return const SizedBox.shrink();
          }
          return IgnorePointer(
            child: ClipPath(
              clipper: _LetterboxClip(rect.size),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: mode == _Ambient.glow ? 30 : 12,
                  sigmaY: mode == _Ambient.glow ? 30 : 12,
                  tileMode: TileMode.clamp,
                ),
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    Colors.black.withValues(
                      alpha: mode == _Ambient.glow ? .55 : .30,
                    ),
                    BlendMode.srcOver,
                  ),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: rect.width,
                      height: rect.height,
                      child: Texture(
                        textureId: id,
                        filterQuality: FilterQuality.low,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LetterboxClip extends CustomClipper<Path> {
  const _LetterboxClip(this.source);
  final Size source;

  @override
  Path getClip(Size size) {
    final outer = Offset.zero & size;
    final fitted = applyBoxFit(BoxFit.contain, source, size);
    final inner = Alignment.center.inscribe(fitted.destination, outer);
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(outer),
      Path()..addRect(inner.inflate(1)),
    );
  }

  @override
  bool shouldReclip(covariant _LetterboxClip oldClipper) =>
      oldClipper.source != source;
}
