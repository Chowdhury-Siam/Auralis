part of 'video_playback.dart';

enum _DragMode { seek, volume, brightness, zoom }

class _VideoHud extends StatefulWidget {
  const _VideoHud(this.session, this.video);

  final _VideoPlaybackState session;
  final VideoState video;

  @override
  State<_VideoHud> createState() => _VideoHudState();
}

class _VideoHudState extends State<_VideoHud> {
  _VideoPlaybackState get session => widget.session;
  mpv.Player get player => session._player!;
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool get _playing => player.state.playing;
  bool get _gestures =>
      session._data.gestures &&
      !session._locked &&
      session._canPlay &&
      session._error == null;
  bool get _fullscreen => isFullscreen(context);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _hide, _feedbackTimer;
  bool _visible = true,
      _exitArmed = false,
      _boosting = false,
      _remaining = true;
  double _startRate = 1, _gestureValue = 0, _startZoom = 0;
  int _lastSeekDirection = 0, _accumulated = 0;
  Offset _tap = Offset.zero, _dragOrigin = Offset.zero;
  Duration _seekOrigin = Duration.zero, _target = Duration.zero;
  Duration? _scrub;
  _DragMode? _drag;
  String? _feedback;
  IconData? _feedbackIcon;
  DateTime? _lastZoomUpdate;
  VideoSkipSegment? _lastSegment;

  @override
  void initState() {
    super.initState();
    session._changes.addListener(_refresh);
    _subscriptions.addAll([
      player.stream.playing.listen((playing) {
        if (!playing) _show();
        _refresh();
        _armHide();
      }),
      player.stream.position.listen((_) {
        final segment = session._currentSegment;
        if (_visible || !identical(segment, _lastSegment)) _refresh();
        _lastSegment = segment;
      }),
      player.stream.duration.listen((_) => _refresh()),
      player.stream.buffering.listen((_) => _refresh()),
      player.stream.buffer.listen((_) {
        if (_visible) _refresh();
      }),
      player.stream.rate.listen((_) => _refresh()),
      player.stream.volume.listen((_) => _refresh()),
    ]);
    _armHide();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    session._changes.removeListener(_refresh);
    _hide?.cancel();
    _feedbackTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  void _armHide() {
    _hide?.cancel();
    if (_playing && _scrub == null) {
      _hide = Timer(const Duration(seconds: 4), () {
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

  void _feedbackFor(String text, IconData icon, {bool resetSeek = true}) {
    _feedbackTimer?.cancel();
    if (!mounted) return;
    if (resetSeek) {
      _lastSeekDirection = 0;
      _accumulated = 0;
    }
    setState(() {
      _feedback = text;
      _feedbackIcon = icon;
    });
    _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _feedback = null;
        _feedbackIcon = null;
        _lastSeekDirection = 0;
        _accumulated = 0;
        _exitArmed = false;
      });
    });
  }

  int _seekZone(double x, double width) => x < width * .36
      ? -1
      : x > width * .64
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
    if (_gestures &&
        !session._data.strictDoubleTap &&
        zone != 0 &&
        zone == _lastSeekDirection) {
      _skip(zone);
    } else {
      setState(() => _visible = !_visible);
      _armHide();
    }
  }

  void _doubleTap(double width) {
    if (!_gestures) return;
    final zone = _seekZone(_tap.dx, width);
    if (zone == 0) {
      unawaited(_perform(session._togglePlayback));
      _show();
    } else {
      _skip(zone);
    }
  }

  void _longPress() {
    if (!_gestures) return;
    _boosting = true;
    _startRate = player.state.rate;
    _boostAt(2);
  }

  void _boostAt(double rate) {
    if (!_boosting) return;
    _feedbackFor('${rate.toStringAsFixed(2)}×', Icons.speed_rounded);
    unawaited(_perform(() => player.setRate(rate)));
  }

  void _longEnd() {
    if (!_boosting) return;
    _boosting = false;
    unawaited(_perform(() => player.setRate(_startRate)));
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
    if (details.pointerCount > 1 || (_startZoom > .02 && _drag == null)) {
      _drag = _DragMode.zoom;
    }
    if (_drag == null) {
      if (delta.distance < 7) return;
      if (delta.dx.abs() >= delta.dy.abs()) {
        _drag = _DragMode.seek;
      } else {
        final left = _dragOrigin.dx < size.width / 2;
        final brightness =
            Platform.isAndroid && left != session._data.swapSides;
        _drag = brightness ? _DragMode.brightness : _DragMode.volume;
        _gestureValue = brightness
            ? (session._brightness ?? .5)
            : player.state.volume / 100;
      }
    }
    switch (_drag!) {
      case _DragMode.seek:
        final span = math.min(240000, session._duration.inMilliseconds);
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
        final max = session._data.volumeBoost ? 1.3 : 1.0;
        final value = (_gestureValue - delta.dy / size.height * 1.5).clamp(
          0.0,
          max,
        );
        _feedbackFor('${(value * 100).round()}%', Icons.volume_up_rounded);
        unawaited(_perform(() => player.setVolume(value * 100)));
      case _DragMode.brightness:
        final value = (_gestureValue - delta.dy / size.height * 1.5).clamp(
          .01,
          1.0,
        );
        _feedbackFor('${(value * 100).round()}%', Icons.brightness_6_rounded);
        unawaited(session._setBrightness(value));
      case _DragMode.zoom:
        final now = DateTime.now();
        if (_lastZoomUpdate != null &&
            now.difference(_lastZoomUpdate!) <
                const Duration(milliseconds: 36)) {
          return;
        }
        _lastZoomUpdate = now;
        final zoom = (_startZoom + math.log(details.scale) / math.ln2).clamp(
          -1.0,
          2.0,
        );
        _feedbackFor(
          '${math.pow(2, zoom).toStringAsFixed(2)}×',
          Icons.zoom_in_rounded,
        );
        unawaited(
          _perform(
            () => session._setZoom(
              zoom,
              x: session._panX + details.focalPointDelta.dx / size.width * 2,
              y: session._panY + details.focalPointDelta.dy / size.height * 2,
            ),
          ),
        );
    }
  }

  void _dragEnd(ScaleEndDetails _) {
    final target = _scrub;
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
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
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
    } else if (key == LogicalKeyboardKey.keyF) {
      unawaited(_perform(_toggleFullscreen));
    } else if (key == LogicalKeyboardKey.keyN ||
        key == LogicalKeyboardKey.keyP) {
      unawaited(
        _perform(() => session._step(key == LogicalKeyboardKey.keyN ? 1 : -1)),
      );
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final increment = key == LogicalKeyboardKey.arrowUp ? 5 : -5;
      final volume = (player.state.volume + increment).clamp(
        0.0,
        session._data.volumeBoost ? 130.0 : 100.0,
      );
      _feedbackFor('${volume.round()}%', Icons.volume_up_rounded);
      unawaited(_perform(() => player.setVolume(volume)));
    } else if (session._mpvKey(event) case final String name) {
      unawaited(_perform(() => session._native.command(['keypress', name])));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _button(
    String label,
    IconData icon,
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

  Widget _pill(Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: colors.surfaceContainerHigh.withValues(alpha: .74),
      border: Border.all(color: colors.onSurface.withValues(alpha: .13)),
      borderRadius: BorderRadius.circular(26),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: child,
    ),
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
        size: 48,
      ),
      const SizedBox(width: 12),
      _button(
        _playing ? 'Pause video' : 'Play video',
        _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        session._loading || session._error != null
            ? null
            : session._togglePlayback,
        selected: true,
        size: 64,
      ),
      const SizedBox(width: 12),
      _button(
        'Next video',
        Icons.skip_next_rounded,
        session._index + 1 < session._queue.length ||
                (session._shuffle && session._queue.length > 1)
            ? () => session._step(1)
            : null,
        size: 48,
      ),
    ],
  );

  List<Widget> _zone(VideoControlZone zone, bool wide) => [
    for (final control in session._data.controls(zone, wide: wide))
      if (Platform.isAndroid ||
          (control != VideoControl.orientation && control != VideoControl.pip))
        _control(control),
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
      () => session._orientationPanel(context, fullscreen: _fullscreen),
    ),
    VideoControl.speed => _button(
      control.label,
      Icons.speed_rounded,
      () => session._speedPanel(context),
    ),
    VideoControl.loop => _button(
      control.label,
      Icons.repeat_rounded,
      session._setLoopPoint,
      selected: session._loopA != null,
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
      session._controlLabel(control),
      Icons.bolt_rounded,
      () => session._runCustomControl(context, control),
    ),
  };

  Widget _bottom(bool wide, bool short) {
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
      mainAxisSize: MainAxisSize.min,
      children: [
        if (wide && !short && session._chapters.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () =>
                      unawaited(_perform(() => session._chapterStep(-1))),
                  child: const Text('Previous chapter'),
                ),
                TextButton(
                  onPressed: () =>
                      unawaited(_perform(() => session._chapterStep(1))),
                  child: const Text('Next chapter'),
                ),
              ],
            ),
          ),
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
        _timeline(),
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
      if (session._loopA case final Duration a) (a, true),
      if (session._loopB case final Duration b) (b, true),
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
          onTap: () => setState(() => _remaining = !_remaining),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(shownTime, style: style),
          ),
        ),
      ],
    );
  }

  Widget _overlay(bool wide, bool short) {
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
                    minimum: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _top(wide),
                    ),
                  ),
                  Center(child: _transport()),
                  SafeArea(
                    minimum: const EdgeInsets.fromLTRB(10, 2, 10, 2),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _bottom(wide, short),
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
    final wide = MediaQuery.sizeOf(context).width >= 660;
    final short = MediaQuery.sizeOf(context).height < 380;
    final segment = session._currentSegment;
    return PopScope(
      canPop:
          session.widget.minimized ||
          (!session._locked && session.widget.onBack == null),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop &&
            !session.widget.minimized &&
            (session._locked || session.widget.onBack != null)) {
          unawaited(_back());
        }
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _keys,
        child: MouseRegion(
          onHover: (_) => _show(),
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
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _tapUp(details, box.maxWidth),
                  onDoubleTapDown: _gestures
                      ? (details) => _tap = details.localPosition
                      : null,
                  onDoubleTap: _gestures
                      ? () => _doubleTap(box.maxWidth)
                      : null,
                  onLongPressStart: _gestures ? (_) => _longPress() : null,
                  onLongPressMoveUpdate: _gestures
                      ? (details) {
                          final step = (details.offsetFromOrigin.dx / 40)
                              .round();
                          _boostAt((2 + step * .25).clamp(.5, 3.0));
                        }
                      : null,
                  onLongPressEnd: _gestures ? (_) => _longEnd() : null,
                  onLongPressCancel: _gestures ? _longEnd : null,
                  onScaleStart: _gestures ? _dragStart : null,
                  onScaleUpdate: _gestures
                      ? (details) => _dragUpdate(details, box.biggest)
                      : null,
                  onScaleEnd: _gestures ? _dragEnd : null,
                ),
                _overlay(wide, short),
                if (!session._locked &&
                    !session._pip &&
                    session._error == null &&
                    segment != null)
                  SafeArea(
                    minimum: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: const AlignmentDirectional(.95, .4),
                      child: FilledButton.tonalIcon(
                        onPressed: () => unawaited(
                          _perform(() => session._seek(segment.end)),
                        ),
                        icon: const Icon(Icons.fast_forward_rounded),
                        label: Text('Skip ${segment.label}'),
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
                if (session._loading || player.state.buffering)
                  const IgnorePointer(
                    child: Align(
                      alignment: Alignment(0, -.42),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                if (_feedback case final String text)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment(_lastSeekDirection * .63, -.26),
                      child: _pill(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_feedbackIcon, color: colors.primary),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                text,
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
      oldDelegate.marks != marks ||
      oldDelegate.accent != accent ||
      oldDelegate.base != base;
}
