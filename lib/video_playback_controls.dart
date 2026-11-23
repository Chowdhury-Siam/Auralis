part of 'video_playback.dart';

enum _DragMode { seek, volume, brightness, zoom }

enum _BoostInput { pointer, space }

enum _VideoLevel {
  brightness('Brightness', Icons.brightness_6_rounded, Alignment.centerLeft),
  volume('Volume', Icons.volume_up_rounded, Alignment.centerRight);

  const _VideoLevel(this.label, this.icon, this.alignment);

  final String label;
  final IconData icon;
  final Alignment alignment;
}

class _VideoHud extends StatefulWidget {
  const _VideoHud(this.session, this.video);

  final _VideoPlaybackState session;
  final VideoState video;

  @override
  State<_VideoHud> createState() => _VideoHudState();
}

class _VideoHudState extends State<_VideoHud> with WidgetsBindingObserver {
  _VideoPlaybackState get session => widget.session;
  mpv.Player get player => session._player!;
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool get _playing => player.state.playing;
  bool get _buffering =>
      session._error == null &&
      (session._loading || player.state.buffering || session._waitingForVideo);
  bool get _gestures =>
      session._data.gestures &&
      !session._locked &&
      session._canPlay &&
      session._error == null;
  bool get _fullscreen => isFullscreen(context);
  VideoGestureOptions get _gestureOptions => session._data.gestureOptions;
  bool _gesture(VideoGesture gesture) =>
      _gestures && _gestureOptions.enabled(gesture);
  bool get _doubleTapGestures =>
      _gesture(VideoGesture.seekDoubleTap) ||
      _gesture(VideoGesture.pauseDoubleTap);
  bool get _dragGestures => [
    VideoGesture.swipeSeek,
    VideoGesture.swipeVolume,
    VideoGesture.swipeBrightness,
    VideoGesture.pinchZoom,
    VideoGesture.panZoom,
  ].any(_gesture);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _timelineChanges = ValueNotifier(0);
  Timer? _hide, _feedbackTimer, _spaceHold, _introPromptTimer;
  bool _spaceDown = false, _spaceBoosted = false;
  bool _visible = true, _exitArmed = false, _remaining = true;
  _BoostInput? _boostInput;
  double? _boostRateRequested;
  double _startRate = 1, _gestureValue = 0, _startZoom = 0;
  int _lastSeekDirection = 0, _accumulated = 0;
  Offset _tap = Offset.zero, _dragOrigin = Offset.zero;
  Duration _seekOrigin = Duration.zero, _target = Duration.zero;
  Duration? _scrub;
  _DragMode? _drag;
  String? _feedback;
  IconData? _feedbackIcon;
  ({_VideoLevel kind, double fraction})? _feedbackLevel;
  static const _playButtonSize = 64.0;
  static const _skipButtonSize = 48.0;
  static const _transportGap = 12.0;
  DateTime? _lastZoomUpdate;
  VideoSkipSegment? _lastSegment;
  bool _skippingSegment = false;

  VideoSkipSegment? get _activeSkipPrompt =>
      session._canPlay && !session._opening && session._error == null
      ? session._skipButtonSegment
      : null;

  VideoSkipSegment? get _visibleSkipPrompt =>
      _introPromptTimer?.isActive == false ? null : _lastSegment;
  int _lastHideSeconds = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session._changes.addListener(_refresh);
    _subscriptions.addAll([
      player.stream.playing.listen((playing) {
        if (!playing) _show();
        _refresh();
        _armHide();
      }),
      player.stream.position.listen((_) {
        if (_visible) _timelineChanges.value++;
        if (!identical(_activeSkipPrompt, _lastSegment)) _refresh();
      }),
      player.stream.duration.listen((_) => _refresh()),
      player.stream.buffering.listen((_) => _refresh()),
      player.stream.buffer.listen((_) {
        if (_visible) _timelineChanges.value++;
      }),
      player.stream.rate.listen((_) => _refresh()),
      player.stream.volume.listen((_) => _refresh()),
    ]);
    _updateSkipPrompt();
    _armHide();
  }

  @override
  void didUpdateWidget(covariant _VideoHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateSkipPrompt();
  }

  void _updateSkipPrompt() {
    final segment = _activeSkipPrompt;
    final previous = _lastSegment;
    // Chapter rereads may replace a segment with an equivalent object.
    if (segment?.start != previous?.start ||
        segment?.end != previous?.end ||
        segment?.label != previous?.label) {
      _introPromptTimer?.cancel();
      _introPromptTimer = null;
    }
    _lastSegment = segment;
    if (segment == null ||
        _introPromptTimer != null ||
        session._pip ||
        session.widget.minimized) {
      return;
    }
    final label = videoSkipChapterLabel(segment.label);
    if (label != 'Intro' && label != 'Opening') return;
    _introPromptTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() {});
    });
  }

  void _refresh() {
    _updateSkipPrompt();
    if (_lastHideSeconds != _gestureOptions.hideSeconds) {
      if (_gestureOptions.hideSeconds == 0) _visible = true;
      _armHide();
    }
    if (!_gestureOptions.enabled(VideoGesture.keyboard) ||
        session._locked ||
        !session._canPlay) {
      _cancelSpaceHold();
    } else if (!_gestureOptions.enabled(VideoGesture.spaceHold)) {
      _spaceHold?.cancel();
      _spaceHold = null;
      _stopBoost(_BoostInput.space);
    }
    if (!_gesture(VideoGesture.holdSpeed)) _stopBoost(_BoostInput.pointer);
    if (_drag == _DragMode.seek && !_gesture(VideoGesture.swipeSeek)) {
      _drag = null;
      _scrub = null;
      _armHide();
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelSpaceHold();
      _stopBoost(_BoostInput.pointer);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelSpaceHold();
    _stopBoost(_BoostInput.pointer);
    session._changes.removeListener(_refresh);
    _hide?.cancel();
    _feedbackTimer?.cancel();
    _introPromptTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _timelineChanges.dispose();
    super.dispose();
  }

  void _armHide() {
    _hide?.cancel();
    _lastHideSeconds = _gestureOptions.hideSeconds;
    if (_playing && _scrub == null && _gestureOptions.hideSeconds > 0) {
      _hide = Timer(Duration(seconds: _gestureOptions.hideSeconds), () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  void _show() {
    if (!_visible && mounted) setState(() => _visible = true);
    _armHide();
  }

  Future<void> _perform(Future<void> Function() operation) async {
    _hide?.cancel();
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        session._notice('This playback action could not be applied.');
      }
    } finally {
      if (mounted) _armHide();
    }
  }

  Future<void> _skipSegment() async {
    if (_skippingSegment || session._pip || _visibleSkipPrompt == null) {
      return;
    }
    // Resolve at activation time, not from an older frame's button callback.
    final segment = _activeSkipPrompt;
    if (segment == null) return;
    setState(() => _skippingSegment = true);
    try {
      await _perform(() => session._seek(segment.end));
    } finally {
      if (mounted) setState(() => _skippingSegment = false);
    }
  }

  void _feedbackFor(
    String text,
    IconData icon, {
    bool resetSeek = true,
    ({_VideoLevel kind, double fraction})? level,
  }) {
    _feedbackTimer?.cancel();
    if (!mounted) return;
    if (resetSeek) {
      _lastSeekDirection = 0;
      _accumulated = 0;
    }
    setState(() {
      _feedback = text;
      _feedbackIcon = icon;
      _feedbackLevel = level;
    });
    _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _feedback = null;
        _feedbackIcon = null;
        _feedbackLevel = null;
        _lastSeekDirection = 0;
        _accumulated = 0;
        _exitArmed = false;
      });
    });
  }

  void _feedbackForLevel(_VideoLevel kind, double value, {double max = 100}) {
    _feedbackFor(
      '${value.round()}%',
      kind == _VideoLevel.volume && value == 0
          ? Icons.volume_off_rounded
          : kind.icon,
      level: (kind: kind, fraction: value / max),
    );
  }

  int _seekZone(double x, double width) =>
      x < width * (_gestureOptions.seekZonePercent / 100)
      ? -1
      : x > width * (1 - _gestureOptions.seekZonePercent / 100)
      ? 1
      : 0;

  void _skip(int direction) {
    if (!session._canPlay || session._duration <= Duration.zero) return;
    if (direction != _lastSeekDirection) {
      _target = session._position;
      _accumulated = 0;
    }
    final seconds = direction * session._data.seekSeconds;
    final millis = (_target.inMilliseconds + seconds * 1000).clamp(
      0,
      session._duration.inMilliseconds,
    );
    final newTarget = Duration(milliseconds: millis);
    if (newTarget == _target) return;
    _target = newTarget;
    _lastSeekDirection = direction;
    _accumulated += seconds;
    _feedbackFor(
      '${_accumulated > 0 ? '+' : '−'}${_accumulated.abs()} s',
      direction < 0 ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
      resetSeek: false,
    );
    unawaited(_perform(() => session._seek(_target)));
  }

  void _tapUp(TapUpDetails details, double width) {
    if (session._locked) {
      _show();
      return;
    }
    final zone = _seekZone(details.localPosition.dx, width);
    if (_gesture(VideoGesture.seekDoubleTap) &&
        !session._data.strictDoubleTap &&
        zone != 0 &&
        zone == _lastSeekDirection) {
      _skip(zone);
    } else if (_gesture(VideoGesture.tapControls)) {
      setState(() => _visible = !_visible);
      _armHide();
    }
  }

  void _doubleTap(double width) {
    if (!_gestures) return;
    final zone = _seekZone(_tap.dx, width);
    if (zone == 0) {
      if (!_gesture(VideoGesture.pauseDoubleTap)) return;
      unawaited(_perform(session._togglePlayback));
      _show();
    } else {
      if (!_gesture(VideoGesture.seekDoubleTap)) return;
      _skip(zone);
    }
  }

  void _startBoost(_BoostInput input) {
    if (_boostInput != null ||
        !session._canPlay ||
        session._opening ||
        session._locked ||
        session._error != null) {
      return;
    }
    _boostInput = input;
    _startRate = player.state.rate;
    if (input == _BoostInput.pointer) {
      unawaited(Feedback.forLongPress(context));
    }
    _boostAt(input, _gestureOptions.boostRate);
  }

  void _boostAt(_BoostInput input, double rate) {
    if (_boostInput != input) return;
    _feedbackFor(
      rate == 2 ? '2×' : '${rate.toStringAsFixed(2)}×',
      Icons.speed_rounded,
    );
    // Pointer motion often remains within the same speed step. Keep feedback
    // timing, but don't queue identical platform calls for each input pixel.
    if (_boostRateRequested == rate) {
      _armHide();
      return;
    }
    _boostRateRequested = rate;
    unawaited(_perform(() => player.setRate(rate)));
  }

  void _stopBoost(_BoostInput input) {
    if (_boostInput != input) return;
    _boostInput = null;
    _boostRateRequested = null;
    final rate = _startRate;
    if (session._canPlay) {
      unawaited(_perform(() => player.setRate(rate)));
    }
  }

  void _cancelSpaceHold() {
    _spaceHold?.cancel();
    _spaceHold = null;
    _spaceDown = false;
    _spaceBoosted = false;
    _stopBoost(_BoostInput.space);
  }

  KeyEventResult _spaceKey(KeyEvent event) {
    if (!_gestureOptions.enabled(VideoGesture.keyboard)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent &&
        !event.synthesized &&
        !session._locked &&
        session._canPlay) {
      if (_spaceDown) return KeyEventResult.handled;
      _spaceDown = true;
      _spaceBoosted = false;
      if (_gestureOptions.enabled(VideoGesture.spaceHold)) {
        _spaceHold = Timer(
          Duration(milliseconds: _gestureOptions.spaceHoldMs),
          () {
            if (_gestureOptions.enabled(VideoGesture.spaceHold)) {
              _spaceBoosted = true;
              _startBoost(_BoostInput.space);
            }
          },
        );
      }
    }
    if (!_spaceDown) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      final tap = !_spaceBoosted && !event.synthesized;
      _cancelSpaceHold();
      if (tap && !session._locked) {
        unawaited(_perform(session._togglePlayback));
      }
    }
    return KeyEventResult.handled;
  }

  void _dragStart(ScaleStartDetails details) {
    if (!_gestures) return;
    _drag = null;
    _dragOrigin = details.localFocalPoint;
    _seekOrigin = session._position;
    _startZoom = session._zoom;
  }

  void _dragUpdate(ScaleUpdateDetails details, Size size) {
    if (!_gestures) return;
    final delta = details.localFocalPoint - _dragOrigin;
    if (details.pointerCount > 1) {
      if (!_gesture(VideoGesture.pinchZoom) &&
          !_gesture(VideoGesture.panZoom)) {
        return;
      }
      _drag = _DragMode.zoom;
    } else if (_startZoom > .02 &&
        _drag == null &&
        _gesture(VideoGesture.panZoom)) {
      _drag = _DragMode.zoom;
    }
    if (_drag == null) {
      if (delta.distance < 7) return;
      if (delta.dx.abs() >= delta.dy.abs()) {
        if (!_gesture(VideoGesture.swipeSeek)) return;
        _drag = _DragMode.seek;
      } else {
        final brightness =
            Platform.isAndroid && _dragOrigin.dx < size.width / 2;
        if (!_gesture(
          brightness ? VideoGesture.swipeBrightness : VideoGesture.swipeVolume,
        )) {
          return;
        }
        _drag = brightness ? _DragMode.brightness : _DragMode.volume;
        _gestureValue = brightness
            ? (session._brightness ?? .5)
            : player.state.volume / 100;
      }
    }
    switch (_drag!) {
      case _DragMode.seek:
        if (!_gesture(VideoGesture.swipeSeek)) return;
        final span = math.min(
          _gestureOptions.swipeSeekSeconds * 1000,
          session._duration.inMilliseconds,
        );
        final offset = (delta.dx / size.width * span).round();
        final target = Duration(
          milliseconds: (_seekOrigin.inMilliseconds + offset).clamp(
            0,
            session._duration.inMilliseconds,
          ),
        );
        _scrub = target;
        final difference = (target - _seekOrigin).inSeconds;
        _feedbackFor(
          '${clockText(target)}  (${difference >= 0 ? '+' : '−'}${difference.abs()} s)',
          Icons.swap_horiz_rounded,
        );
      case _DragMode.volume:
        if (!_gesture(VideoGesture.swipeVolume)) return;
        final max = session._data.volumeBoost ? 1.3 : 1.0;
        final value =
            (_gestureValue -
                    delta.dy /
                        size.height *
                        1.5 *
                        _gestureOptions.swipeSensitivity)
                .clamp(0.0, max);
        _feedbackForLevel(_VideoLevel.volume, value * 100, max: max * 100);
        unawaited(_perform(() => session._setVideoVolume(value * 100)));
      case _DragMode.brightness:
        if (!_gesture(VideoGesture.swipeBrightness)) return;
        final value =
            (_gestureValue -
                    delta.dy /
                        size.height *
                        1.5 *
                        _gestureOptions.swipeSensitivity)
                .clamp(.01, 1.0);
        _feedbackForLevel(_VideoLevel.brightness, value * 100);
        unawaited(session._setBrightness(value));
      case _DragMode.zoom:
        final now = DateTime.now();
        if (_lastZoomUpdate != null &&
            now.difference(_lastZoomUpdate!) <
                const Duration(milliseconds: 36)) {
          return;
        }
        _lastZoomUpdate = now;
        if (!_gesture(VideoGesture.pinchZoom) &&
            !_gesture(VideoGesture.panZoom)) {
          return;
        }
        final zoom =
            (_startZoom +
                    (_gesture(VideoGesture.pinchZoom)
                        ? math.log(details.scale) /
                              math.ln2 *
                              _gestureOptions.zoomSensitivity
                        : 0))
                .clamp(-1.0, 2.0);
        _feedbackFor(
          '${math.pow(2, zoom).toStringAsFixed(2)}×',
          Icons.zoom_in_rounded,
        );
        unawaited(
          _perform(
            () => session._setZoom(
              zoom,
              x: _gesture(VideoGesture.panZoom)
                  ? session._panX + details.focalPointDelta.dx / size.width * 2
                  : session._panX,
              y: _gesture(VideoGesture.panZoom)
                  ? session._panY + details.focalPointDelta.dy / size.height * 2
                  : session._panY,
            ),
          ),
        );
    }
  }

  void _dragEnd(ScaleEndDetails _) {
    final target = _gesture(VideoGesture.swipeSeek) ? _scrub : null;
    _drag = null;
    _scrub = null;
    if (target != null) unawaited(_perform(() => session._seek(target)));
    _armHide();
  }

  Future<void> _back() async {
    if (session._locked) {
      if (_exitArmed) {
        _exitArmed = false;
        session._locked = false;
        session._changed();
        _show();
      } else {
        _exitArmed = true;
        _feedbackFor('Press Back again to unlock', Icons.lock_rounded);
      }
      return;
    }
    if (_fullscreen) {
      await exitFullscreen(context);
    } else if (mounted) {
      final onBack = session.widget.onBack;
      if (onBack == null) {
        Navigator.of(context).pop();
      } else {
        onBack();
      }
    }
  }

  Future<void> _toggleFullscreen() => toggleFullscreen(context);

  KeyEventResult _keys(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (event is KeyDownEvent) unawaited(_back());
      return KeyEventResult.handled;
    }
    if (!_gestureOptions.enabled(VideoGesture.keyboard)) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space && _desktopVideo) {
      return _spaceKey(event);
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      unawaited(_back());
    } else if (session._locked) {
      return KeyEventResult.ignored;
    } else if (session._mpvKey(event) case final String name
        when name.contains('+')) {
      unawaited(_perform(() => session._native.command(['keypress', name])));
    } else if (key == LogicalKeyboardKey.space) {
      unawaited(_perform(session._togglePlayback));
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _skip(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _skip(1);
    } else if (key == LogicalKeyboardKey.keyF && _desktopVideo) {
      unawaited(_perform(_toggleFullscreen));
    } else if (key == LogicalKeyboardKey.keyN ||
        key == LogicalKeyboardKey.keyP) {
      unawaited(
        _perform(() => session._step(key == LogicalKeyboardKey.keyN ? 1 : -1)),
      );
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final increment = key == LogicalKeyboardKey.arrowUp ? 5 : -5;
      final max = session._data.volumeBoost ? 130.0 : 100.0;
      final volume = (player.state.volume + increment).clamp(0.0, max);
      _feedbackForLevel(_VideoLevel.volume, volume, max: max);
      unawaited(_perform(() => session._setVideoVolume(volume)));
    } else if (session._mpvKey(event) case final String name) {
      unawaited(_perform(() => session._native.command(['keypress', name])));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _button(
    String label,
    IconData? icon,
    Future<void> Function()? action, {
    double size = 44,
    bool selected = false,
    VoidCallback? onLongPress,
  }) {
    final bg = selected
        ? colors.primaryContainer
        : session._data.transparentControls
        ? Colors.transparent
        : colors.surfaceContainerHigh.withValues(alpha: .74);
    final fg = selected ? colors.onPrimaryContainer : colors.onSurface;
    return Tooltip(
      message: label,
      child: Material(
        color: bg,
        shape: CircleBorder(side: BorderSide(color: fg.withValues(alpha: .13))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: action == null ? null : () => unawaited(_perform(action)),
          onLongPress: onLongPress,
          child: SizedBox.square(
            dimension: size,
            child: Icon(
              icon,
              size: size >= 60 ? 32 : 21,
              color: action == null ? fg.withValues(alpha: .35) : fg,
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 9,
    ),
  }) => DecoratedBox(
    decoration: BoxDecoration(
      color: colors.surfaceContainerHigh.withValues(alpha: .74),
      border: Border.all(color: colors.onSurface.withValues(alpha: .13)),
      borderRadius: BorderRadius.circular(26),
    ),
    child: Padding(padding: padding, child: child),
  );

  Widget _top(bool wide) {
    final title = Expanded(
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: _pill(
          Text(
            '${session._source.title}  ·  ${session._index + 1}/${session._queue.length}',
            key: const ValueKey('video-player-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    final start = _zone(VideoControlZone.topStart, wide);
    final end = _zone(VideoControlZone.topEnd, wide);
    final more = _button(
      'More player controls',
      Icons.more_vert_rounded,
      () => session._morePanel(context, widget.video),
    );
    return Column(
      key: const ValueKey('video-top-controls'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          children: [
            _button('Back to videos', Icons.arrow_back_rounded, _back),
            const SizedBox(width: 6),
            if (wide)
              for (final button in start)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 5),
                  child: button,
                ),
            title,
            if (wide) ...[
              for (final button in [...end, more])
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 5),
                  child: button,
                ),
            ],
          ],
        ),
        if (!wide)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [...start, ...end, more],
            ),
          ),
      ],
    );
  }

  Widget _transport() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _button(
        'Previous video',
        Icons.skip_previous_rounded,
        session._index > 0 ? () => session._step(-1) : null,
        size: _skipButtonSize,
      ),
      const SizedBox(width: _transportGap),
      _button(
        _playing ? 'Pause video' : 'Play video',
        _buffering
            ? null
            : _playing
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        session._loading || session._error != null
            ? null
            : session._togglePlayback,
        selected: true,
        size: _playButtonSize,
      ),
      const SizedBox(width: _transportGap),
      _button(
        'Next video',
        Icons.skip_next_rounded,
        session._index + 1 < session._queue.length ||
                (session._shuffle && session._queue.length > 1)
            ? () => session._step(1)
            : null,
        size: _skipButtonSize,
      ),
    ],
  );

  List<Widget> _zone(VideoControlZone zone, bool wide) => [
    for (final control in session._data.controls(zone, wide: wide))
      if (supportsVideoControl(control)) _control(control),
  ];

  Widget _control(VideoControl control) => switch (control) {
    VideoControl.decoder => Tooltip(
      message: control.label,
      child: TextButton(
        onPressed: () =>
            unawaited(_perform(() => session._decoderPanel(context))),
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurface,
          backgroundColor: session._data.transparentControls
              ? Colors.transparent
              : colors.surfaceContainerHigh.withValues(alpha: .74),
          minimumSize: const Size(48, 44),
        ),
        child: Text(
          session._decoder == 'no'
              ? 'SW'
              : session._decoder == 'auto-copy'
              ? 'HW+'
              : 'HW',
        ),
      ),
    ),
    VideoControl.audio => _button(
      control.label,
      Icons.music_note_rounded,
      () => session._audioPanel(context),
    ),
    VideoControl.subtitles => _button(
      control.label,
      Icons.subtitles_rounded,
      () => session._subtitlesPanel(context),
    ),
    VideoControl.lock => _button(
      control.label,
      Icons.lock_open_rounded,
      () async {
        session._locked = true;
        session._changed();
      },
    ),
    VideoControl.orientation => _button(
      control.label,
      Icons.screen_rotation_rounded,
      () => session._orientationPanel(context),
    ),
    VideoControl.speed => _button(
      control.label,
      Icons.speed_rounded,
      () => player.setRate(player.state.rate == 2.0 ? 1.0 : 2.0),
      selected: player.state.rate == 2.0,
      onLongPress: () =>
          unawaited(_perform(() => session._speedPanel(context))),
    ),
    VideoControl.chapters => _button(
      control.label,
      Icons.bookmarks_outlined,
      () => session._chaptersPanel(context),
      onLongPress: () =>
          unawaited(_perform(() => session._editBookmark(context))),
    ),
    VideoControl.queue => _button(
      control.label,
      Icons.playlist_play_rounded,
      () => session._queuePanel(context),
    ),
    VideoControl.zoom => _button(
      control.label,
      Icons.zoom_in_rounded,
      () => session._zoomPanel(context, widget.video),
    ),
    VideoControl.screenshot => _button(
      control.label,
      Icons.photo_camera_outlined,
      session._saveFrame,
    ),
    VideoControl.fullscreen => _button(
      _fullscreen ? 'Exit fullscreen' : control.label,
      _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
      _toggleFullscreen,
    ),
    VideoControl.pip => _button(
      control.label,
      Icons.picture_in_picture_alt_rounded,
      session._pictureInPicture,
    ),
    VideoControl.skipBack => _button(
      control.label,
      Icons.fast_rewind_rounded,
      () async => _skip(-1),
    ),
    VideoControl.skipForward => _button(
      control.label,
      Icons.fast_forward_rounded,
      () async => _skip(1),
    ),
    VideoControl.stats => _button(
      control.label,
      Icons.monitor_heart_outlined,
      () => session._infoPanel(context),
    ),
    VideoControl.skipSegments => _button(
      control.label,
      Icons.fast_forward_rounded,
      () => session._skipSegmentsPanel(context),
    ),
    VideoControl.customOne ||
    VideoControl.customTwo ||
    VideoControl.customThree => _button(
      videoControlLabel(session._data, control),
      Icons.bolt_rounded,
      () => session._runCustomControl(context, control),
    ),
  };

  Widget _bottom(bool wide) {
    final left = Wrap(
      spacing: 5,
      runSpacing: 4,
      children: _zone(VideoControlZone.bottomStart, wide),
    );
    final right = Wrap(
      spacing: 5,
      runSpacing: 4,
      children: _zone(VideoControlZone.bottomEnd, wide),
    );
    return Column(
      key: const ValueKey('video-bottom-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (wide)
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: left,
                ),
              ),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: right,
                ),
              ),
            ],
          )
        else
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 4,
            children: [left, right],
          ),
        const SizedBox(height: 2),
        RepaintBoundary(
          child: ListenableBuilder(
            key: const ValueKey('video-live-timeline'),
            listenable: _timelineChanges,
            builder: (context, _) => _timeline(),
          ),
        ),
      ],
    );
  }

  Widget _timeline() {
    final duration = session._duration;
    final position = _scrub ?? session._position;
    final length = duration.inMilliseconds;
    final value = length <= 0
        ? 0.0
        : (position.inMilliseconds / length).clamp(0.0, 1.0);
    final buffer = length <= 0
        ? 0.0
        : (player.state.buffer.inMilliseconds / length).clamp(0.0, 1.0);
    final shownTime = _remaining && position < duration
        ? '−${clockText(duration - position)}'
        : clockText(duration);
    final marks = [
      for (final point in session._chapters) (point.position, false),
      for (final point in session._bookmarks) (point.position, true),
      for (final segment in session._segments) ...[
        (segment.start, true),
        (segment.end, true),
      ],
    ];
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: colors.onSurface);
    return Row(
      children: [
        Text(clockText(position), style: style),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Slider(
                key: const ValueKey('video-seek'),
                value: value,
                secondaryTrackValue: math.max(value, buffer),
                activeColor: colors.primary,
                inactiveColor: colors.onSurface.withValues(alpha: .25),
                semanticFormatterCallback: (value) =>
                    clockText(Duration(milliseconds: (value * length).round())),
                onChanged: length <= 0
                    ? null
                    : (value) {
                        _hide?.cancel();
                        setState(
                          () => _scrub = Duration(
                            milliseconds: (value * length).round(),
                          ),
                        );
                      },
                onChangeEnd: length <= 0
                    ? null
                    : (value) {
                        setState(() => _scrub = null);
                        unawaited(
                          _perform(
                            () => session._seek(
                              Duration(milliseconds: (value * length).round()),
                            ),
                          ),
                        );
                      },
              ),
              if (length > 0 && marks.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 25),
                      child: CustomPaint(
                        painter: _VideoMarkers(
                          [
                            for (final (time, bookmark) in marks)
                              (time.inMilliseconds / length, bookmark),
                          ],
                          colors.tertiary,
                          colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        InkWell(
          onTap: _gesture(VideoGesture.tapTime)
              ? () => setState(() => _remaining = !_remaining)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(shownTime, style: style),
          ),
        ),
      ],
    );
  }

  Widget _feedbackOverlay(String text, Size viewport, EdgeInsets insets) {
    if (_feedbackLevel case final level?) {
      return _levelIndicator(text, level.kind, level.fraction, viewport, insets);
    }
    return Center(
      child: Transform.translate(
        offset: Offset(0, -math.min(76.0, viewport.height / 4)),
        child: _pill(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_feedbackIcon, size: 20, color: colors.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _levelIndicator(
    String text,
    _VideoLevel kind,
    double fraction,
    Size viewport,
    EdgeInsets insets,
  ) {
    const transportWidth =
        _playButtonSize + 2 * (_skipButtonSize + _transportGap);
    final sideWidth =
        (viewport.width - insets.horizontal - transportWidth) / 2 - 6;
    if (sideWidth <= 0) return const SizedBox.shrink();
    final accent = kind == _VideoLevel.brightness
        ? colors.tertiary
        : colors.primary;
    return Align(
      alignment: kind.alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: sideWidth),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Semantics(
            label: kind.label,
            value: text,
            excludeSemantics: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh.withValues(alpha: .96),
                border: Border.all(
                  color: colors.onSurface.withValues(alpha: .14),
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .16),
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox.square(
                        dimension: 32,
                        child: Icon(_feedbackIcon, size: 18, color: accent),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: SizedBox(
                          width: 48,
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 5,
                            borderRadius: BorderRadius.circular(3),
                            color: accent,
                            backgroundColor: accent.withValues(alpha: .18),
                            stopIndicatorRadius: 0,
                            trackGap: 0,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    SizedBox(
                      width: 40,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          text,
                          style: TextStyle(
                            color: colors.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overlay(bool wide, double horizontalInset) {
    final shown = _visible && !session._locked && session._error == null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : session._data.animation == VideoControlAnimation.fade
        ? const Duration(milliseconds: 110)
        : const Duration(milliseconds: 200);
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedSwitcher(
        duration: duration,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [
            for (final child in previous) IgnorePointer(child: child),
            ?current,
          ],
        ),
        transitionBuilder: (child, animation) {
          final fade = FadeTransition(opacity: animation, child: child);
          return switch (session._data.animation) {
            VideoControlAnimation.standard ||
            VideoControlAnimation.fade => fade,
            VideoControlAnimation.scale => ScaleTransition(
              scale: Tween(begin: .97, end: 1.0).animate(animation),
              child: fade,
            ),
            VideoControlAnimation.elastic => ScaleTransition(
              scale: Tween(begin: .94, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
              ),
              child: fade,
            ),
            VideoControlAnimation.slide => SlideTransition(
              position: Tween(
                begin: const Offset(0, .035),
                end: Offset.zero,
              ).animate(animation),
              child: fade,
            ),
          };
        },
        child: !shown
            ? const SizedBox.shrink(key: ValueKey(false))
            : Stack(
                key: const ValueKey(true),
                fit: StackFit.expand,
                children: [
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xB0000000),
                            Color(0x10000000),
                            Color(0x18000000),
                            Color(0xD9000000),
                          ],
                          stops: [0, .34, .58, 1],
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    minimum: EdgeInsets.fromLTRB(
                      horizontalInset,
                      6,
                      horizontalInset,
                      2,
                    ),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _top(wide),
                    ),
                  ),
                  Center(child: _transport()),
                  SafeArea(
                    minimum: EdgeInsets.fromLTRB(
                      horizontalInset,
                      2,
                      horizontalInset,
                      2,
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _bottom(wide),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (session._pip) return const SizedBox.expand();
    final segment = _visibleSkipPrompt;
    return PopScope(
      canPop:
          session.widget.minimized ||
          (!session._locked && (_fullscreen || session.widget.onBack == null)),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop &&
            !session.widget.minimized &&
            (session._locked ||
                (!_fullscreen && session.widget.onBack != null))) {
          unawaited(_back());
        }
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _keys,
        onFocusChange: (focused) {
          if (!focused) _cancelSpaceHold();
        },
        child: MouseRegion(
          onHover: _gestureOptions.enabled(VideoGesture.hoverControls)
              ? (_) => _show()
              : null,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              fit: StackFit.expand,
              children: [
                if (session._fit == _VideoFit.fit &&
                    session._ambient != _Ambient.off)
                  _AmbientBars(
                    video: session._video!,
                    mode: session._ambient,
                    thermalLimit: session._thermalLimit,
                  ),
                GestureDetector(
                  key: const ValueKey('video-gesture-surface'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _tapUp(details, box.maxWidth),
                  onDoubleTapDown: _doubleTapGestures
                      ? (details) => _tap = details.localPosition
                      : null,
                  onDoubleTap: _doubleTapGestures
                      ? () => _doubleTap(box.maxWidth)
                      : null,
                  onLongPressStart: _gesture(VideoGesture.holdSpeed)
                      ? (_) => _startBoost(_BoostInput.pointer)
                      : null,
                  onLongPressMoveUpdate: _gesture(VideoGesture.holdSpeed)
                      ? (details) {
                          final step = (details.offsetFromOrigin.dx / 40)
                              .round();
                          _boostAt(
                            _BoostInput.pointer,
                            (_gestureOptions.boostRate + step * .25).clamp(
                              .5,
                              3.0,
                            ),
                          );
                        }
                      : null,
                  onLongPressEnd: _gesture(VideoGesture.holdSpeed)
                      ? (_) => _stopBoost(_BoostInput.pointer)
                      : null,
                  onLongPressCancel: _gesture(VideoGesture.holdSpeed)
                      ? () => _stopBoost(_BoostInput.pointer)
                      : null,
                  onScaleStart: _dragGestures ? _dragStart : null,
                  onScaleUpdate: _dragGestures
                      ? (details) => _dragUpdate(details, box.biggest)
                      : null,
                  onScaleEnd: _dragGestures ? _dragEnd : null,
                ),
                Builder(
                  builder: (context) {
                    // Controls belong to the full player viewport, including
                    // pillarboxes, not the fitted video image. SafeArea below
                    // applies each device inset independently.
                    const inset = 10.0;
                    final padding = MediaQuery.paddingOf(context);
                    final insets = EdgeInsets.only(
                      left: math.max(inset, padding.left),
                      right: math.max(inset, padding.right),
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        _overlay(
                          box.maxWidth - insets.horizontal >= 640,
                          inset,
                        ),
                        if (_feedback case final String text)
                          IgnorePointer(
                            child: Padding(
                              padding: insets,
                              child: _feedbackOverlay(
                                text,
                                box.biggest,
                                insets,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                // This is intentionally outside the hidden/locked controls
                // overlay: lock still blocks ordinary gestures and transport.
                if (segment != null)
                  SafeArea(
                    minimum: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Align(
                      alignment: const AlignmentDirectional(.95, .4),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: math.max(
                            0,
                            math.min(280, box.maxWidth - 32),
                          ),
                        ),
                        child: Tooltip(
                          message: 'Skip to ${clockText(segment.end)}',
                          child: FilledButton.tonalIcon(
                            key: const ValueKey('video-skip-segment'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 48),
                            ),
                            onPressed: _skippingSegment
                                ? null
                                : () => unawaited(_skipSegment()),
                            icon: const Icon(Icons.fast_forward_rounded),
                            label: Text(
                              segment.buttonLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!session._locked &&
                    !_visible &&
                    !_gesture(VideoGesture.tapControls) &&
                    session._error == null)
                  SafeArea(
                    minimum: const EdgeInsets.all(12),
                    child: Align(
                      alignment: AlignmentDirectional.topEnd,
                      child: _button(
                        'Show controls',
                        Icons.touch_app_rounded,
                        () async => _show(),
                      ),
                    ),
                  ),
                if (session._locked && _visible)
                  SafeArea(
                    minimum: const EdgeInsets.all(12),
                    child: Align(
                      alignment: AlignmentDirectional.topEnd,
                      child: _button(
                        'Unlock controls',
                        Icons.lock_rounded,
                        () async {
                          session._locked = false;
                          session._changed();
                          _show();
                        },
                      ),
                    ),
                  ),
                if (_buffering)
                  const IgnorePointer(
                    child: Center(
                      child: SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          semanticsLabel: 'Loading video',
                        ),
                      ),
                    ),
                  ),
                if (session._error != null)
                  ColoredBox(
                    color: colors.surface.withValues(alpha: .92),
                    child: SafeArea(
                      minimum: const EdgeInsets.all(10),
                      child: Stack(
                        children: [
                          session._failure(context),
                          _button(
                            'Back to videos',
                            Icons.arrow_back_rounded,
                            _back,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoMarkers extends CustomPainter {
  const _VideoMarkers(this.marks, this.accent, this.base);
  final List<(double, bool)> marks;
  final Color accent, base;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (fraction, bookmark) in marks) {
      if (fraction < 0 || fraction > 1) continue;
      final x = size.width * fraction;
      final radius = bookmark ? 4.0 : 2.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, size.height / 2),
            width: radius,
            height: radius * 2,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = bookmark ? accent : base.withValues(alpha: .65),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VideoMarkers oldDelegate) =>
      !listEquals(oldDelegate.marks, marks) ||
      oldDelegate.accent != accent ||
      oldDelegate.base != base;
}
