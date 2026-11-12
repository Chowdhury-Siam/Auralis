import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:audio_session/audio_session.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'app_popups.dart';
import 'models.dart';
import 'player.dart';
import 'telegram/stream_proxy.dart';
import 'telegram/telegram_service.dart';
import 'video_playback_data.dart';
import 'video_settings.dart';
import 'video_library.dart';

part 'video_playback_controls.dart';
part 'video_playback_panels.dart';
part 'video_playback_popup.dart';
part 'video_playback_processing.dart';
part 'video_playback_tools.dart';
part 'video_playback_lookup.dart';
part 'video_playback_config.dart';
part 'video_playback_hdr.dart';

const _videoWindow = MethodChannel('app.auralis/video');
final _desktopVideo = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<({Uint8List bytes, String? path})?> _pickVideoDocument(
  String label,
  List<String> extensions, {
  int maxBytes = 1024 * 1024,
}) async {
  if (Platform.isAndroid) {
    const storage = MethodChannel('app.auralis/platform');
    final uri = await storage.invokeMethod<String>('openDocument');
    if (uri == null) return null;
    final bytes = await storage.invokeMethod<Uint8List>('readDocument', {
      'uri': uri,
      'maxBytes': maxBytes,
    });
    return bytes == null ? null : (bytes: bytes, path: null);
  }
  final file = await openFile(
    acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
  );
  if (file == null) return null;
  final length = await file.length();
  if (length > maxBytes) throw const FormatException('The file is too large.');
  return (bytes: await file.readAsBytes(), path: file.path);
}


class VideoPlayback extends StatefulWidget {
  const VideoPlayback({
    super.key,
    required this.sources,
    required this.initialIndex,
    required this.telegram,
    required this.music,
    required this.proxy,
    required this.onOpened,
    this.onWatched,
    this.minimized = false,
    this.miniBottomInset = 0,
    this.onBack,
    this.onMinimize,
    this.onExpand,
    this.onClose,
    this.onRelease,
    this.createController,
  });

  final List<VideoSource> sources;
  final int initialIndex;
  final TelegramService telegram;
  final PlayerController music;
  final TelegramStreamProxy proxy;
  final ValueChanged<VideoSource> onOpened;
  final VoidCallback? onWatched;
  final bool minimized;
  final double miniBottomInset;
  final VoidCallback? onBack, onMinimize, onExpand, onClose;
  final ValueChanged<Future<void>>? onRelease;
  @visibleForTesting
  final VideoController Function()? createController;

  @override
  State<VideoPlayback> createState() => _VideoPlaybackState();
}

enum _Orientation {
  free('Free', []),
  video('Match video', []),
  portrait('Portrait', [DeviceOrientation.portraitUp]),
  reversePortrait('Reverse portrait', [DeviceOrientation.portraitDown]),
  sensorPortrait('Sensor portrait', [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]),
  landscape('Landscape', [DeviceOrientation.landscapeLeft]),
  reverseLandscape('Reverse landscape', [DeviceOrientation.landscapeRight]),
  sensorLandscape('Sensor landscape', [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  const _Orientation(this.label, this.orientations);
  final String label;
  final List<DeviceOrientation> orientations;
}

enum _VideoFit {
  fit('Fit', BoxFit.contain),
  crop('Crop', BoxFit.cover),
  stretch('Stretch', BoxFit.fill);

  const _VideoFit(this.label, this.boxFit);
  final String label;
  final BoxFit boxFit;
}

class _VideoPlaybackState extends State<VideoPlayback>
    with WidgetsBindingObserver {
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _changes = ValueNotifier(0);
  final _log = <String>[];
  final _closing = Completer<Track?>();
  Future<void>? _openingTask, _releaseTask;
  late final _queue = List<VideoSource>.of(widget.sources);
  late int _index = widget.initialIndex;
  VideoSource get _source => _queue[_index];
  VideoPlaybackData get _data => widget.music.settings.videoPlayback;

  mpv.Player? _player;
  VideoController? _video;
  AudioSession? _session;
  Timer? _checkpoint, _sleepTimer, _thermalTimer;
  Timer? _startupTimeout;
  DateTime? _sleepAt;
  String? _error;
  bool _loading = true,
      _opening = false,
      _closed = false,
      _surfaceDetached = false,
      _positionReady = false;
  bool _invalidated = false, _pip = false, _locked = false, _shuffle = false;
  bool _mirror = false,
      _flip = false,
      _repeatVideo = false,
      _resumeSeek = false;
  bool _appInBackground = false, _selectingFile = false;
  bool _acceptVideoParams = false;
  List<DeviceOrientation>? _requestedOrientations;
  bool _hasHistoryRecord = false;
  bool _probingCrop = false, _cropped = false;
  String _decoder = 'auto-safe';
  String _secondarySubtitle = 'no';
  double? _brightness;
  bool _brightnessChanged = false;
  double _zoom = 0, _panX = 0, _panY = 0;
  Duration? _skipStart;
  Duration? _autoSkipEnd;
  Directory? _scripts;
  bool _customKeysLoaded = false;
  List<VideoBookmark> _chapters = const [];
  _VideoFit _fit = _VideoFit.fit;
  _Upscale _upscale = _Upscale.off;
  _ShaderQuality _quality = _ShaderQuality.balanced;
  late _Ambient _ambient = _Ambient.values.firstWhere(
    (mode) => mode.name == _data.ambientMode,
    orElse: () => _Ambient.off,
  );
  List<String> _activeShaders = const [];
  final _previousHdrOptions = <String, String>{};
  VideoHdrProfile _activeHdr = VideoHdrProfile.off;
  Future<void> _shaderUpdates = Future<void>.value();
  bool _thermalLimit = false;

  _Orientation get _orientation => _Orientation.values.firstWhere(
    (value) => value.name == _data.orientations[_source.id],
    orElse: () => _Orientation.video,
  );

  bool get _canPlay =>
      mounted &&
      !_closed &&
      !_invalidated &&
      (_source.telegram == null || widget.telegram.ready);
  mpv.NativePlayer get _native => _player!.platform as mpv.NativePlayer;
  Duration get _position => _player?.state.position ?? Duration.zero;
  Duration get _duration {
    final duration = _player?.state.duration ?? Duration.zero;
    return duration > Duration.zero ? duration : _source.duration;
  }

  List<VideoBookmark> get _bookmarks => _data.bookmarks[_source.id] ?? const [];
  List<VideoSkipSegment> get _segments =>
      _data.skipSegments[_source.id] ?? const [];
  VideoSkipSegment? get _currentSegment => _segments
      .where(
        (segment) => segment.end <= _duration && segment.contains(_position),
      )
      .lastOrNull;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.telegram.addListener(_authorizationChanged);
    widget.music.audio.addListener(_musicChanged);
    widget.music.releaseVideo = _releaseForExit;
    if (Platform.isAndroid) _videoWindow.setMethodCallHandler(_windowEvent);
    _checkpoint = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _saveProgress(),
    );
    if (Platform.isAndroid) {
      _thermalTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_refreshThermal()),
      );
    }
    unawaited(_open());
  }

  void _changed() {
    if (mounted && !_closed) _changes.value++;
  }

  Future<void> _windowEvent(MethodCall call) async {
    if (_closed) return;
    if (call.method == 'togglePlayback') {
      await _togglePlayback();
      return;
    }
    if (call.method != 'pipChanged') return;
    _pip = call.arguments == true;
    _changed();
    if (!_pip && _appInBackground && !_data.background) await _player?.pause();
  }

  Future<void> _updatePip() async {
    if (!Platform.isAndroid || _closed) return;
    try {
      final state = _player?.state;
      await _videoWindow.invokeMethod<void>('autoPip', {
        'auto': _data.autoPip && !_selectingFile && !widget.minimized,
        'playing': state?.playing == true,
        'width': state?.videoParams.dw ?? state?.width,
        'height': state?.videoParams.dh ?? state?.height,
      });
    } on PlatformException {
      // Playback stays usable on devices that disable picture in picture.
    } on MissingPluginException {
      // Platform implementation is unavailable in widget tests.
    }
  }

  void _authorizationChanged() {
    if (widget.telegram.ready || _source.telegram == null || _invalidated) {
      return;
    }
    _saveProgress();
    _invalidated = true;
    unawaited(_player?.stop());
    unawaited(widget.proxy.stop());
    _error = 'The Telegram session changed. Return to the video browser.';
    _changed();
  }

  void _musicChanged() {
    if (widget.music.audio.playing && _player?.state.playing == true) {
      unawaited(_player?.pause());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInBackground = state == AppLifecycleState.paused;
    if (_appInBackground) {
      _saveProgress();
      if (!_pip && !_data.background) unawaited(_pauseOutsidePip());
    }
  }

  Future<void> _pauseOutsidePip() async {
    // Android can deliver onPause immediately before entering picture in picture.
    if (Platform.isAndroid) {
      await Future<void>.delayed(const Duration(milliseconds: 240));
    }
    if (_canPlay && _appInBackground && !_pip && !_data.background) {
      await _player?.pause();
    }
  }

  void _setError(String message) {
    if (!_canPlay || _error != null) return;
    _startupTimeout?.cancel();
    _error = message;
    _loading = false;
    _changed();
  }

  VideoController _createController() {
    mpv.MediaKit.ensureInitialized();
    return VideoController(
      mpv.Player(
        configuration: const mpv.PlayerConfiguration(
          title: 'Auralis Video',
          libass: true,
          libassAndroidFont: 'assets/fonts/DejaVuSans.ttf',
          libassAndroidFontName: 'DejaVu Sans',
          bufferSize: 32 * 1024 * 1024,
        ),
      ),
      configuration: VideoControllerConfiguration(
        vo: Platform.isAndroid && _data.gpuNext ? 'gpu-next,gpu' : null,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );
  }

  Future<void> _open({bool resume = true}) {
    if (_opening || !_canPlay) return Future<void>.value();
    return _openingTask = _openVideo(resume: resume);
  }

  Future<void> _openVideo({required bool resume}) async {
    _opening = _loading = true;
    _startupTimeout?.cancel();
    _acceptVideoParams = false;
    _positionReady = false;
    _resumeSeek = resume && !_data.isWatched(_source) &&
        _data.positions[_source.id] != null;
    _error = null;
    _chapters = const [];
    _skipStart = _autoSkipEnd = null;
    _secondarySubtitle = 'no';
    _changed();
    unawaited(_applyOrientation());
    try {
      if (!_source.canPlay) {
        throw const FormatException('Choose a Telegram or local video.');
      }
      if (_player == null) {
        final video = _video =
            widget.createController?.call() ?? _createController();
        final player = _player = video.player;
        _subscriptions.addAll([
          player.stream.error.listen(
            (_) => _setError('The video could not be played.'),
          ),
          widget.proxy.errors.listen((_) {
            if (_source.telegram != null) {
              _setError('Telegram could not load the video.');
            }
          }),
          player.stream.log.listen((entry) {
            // The backend can log local paths, URL credentials and Telegram capability URLs.
            final text = entry.text.replaceAll(
              RegExp(r'(?:https?|file|fd|content)://\S+', caseSensitive: false),
              '[media source]',
            );
            if (_log.length >= 80) _log.removeAt(0);
            _log.add('${entry.prefix}: $text');
          }),
          player.stream.width.listen((_) => unawaited(_updateUpscaling())),
          player.stream.height.listen((_) => unawaited(_updateUpscaling())),
          if (Platform.isAndroid)
            player.stream.videoParams.listen((_) {
              if (!_acceptVideoParams || !_canPlay) return;
              if (!player.state.playing &&
                  (player.state.width ?? 0) > 0 &&
                  (player.state.height ?? 0) > 0) {
                _startupTimeout?.cancel();
              }
              unawaited(_applyOrientation());
            }),
          player.stream.duration.listen((duration) {
            if (duration > Duration.zero && _canPlay) {
              unawaited(_readChapters());
            }
          }),
          player.stream.position.listen((position) {
            if (_acceptVideoParams &&
                position > Duration.zero &&
                _startupTimeout?.isActive == true) {
              _startupTimeout!.cancel();
              unawaited(_applyOrientation());
            }
            if (position > Duration.zero && !_opening && !_positionReady) {
              _positionReady = true;
              if (_data.hdrProfile != _activeHdr) unawaited(_updateUpscaling());
              unawaited(_updateRefreshRate());
            }
            if (_autoSkipEnd case final Duration end when position >= end) {
              _autoSkipEnd = null;
            }
            final segment = _data.autoSkip ? _currentSegment : null;
            if (_data.autoSkip &&
                player.state.playing &&
                _autoSkipEnd == null &&
                !_opening &&
                _canPlay &&
                segment != null) {
              _autoSkipEnd = segment.end;
              unawaited(
                _seek(segment.end).catchError((Object _) {
                  _autoSkipEnd = null;
                }),
              );
            }
          }),
          player.stream.completed.listen((completed) {
            if (completed && !_opening && _error == null && _canPlay) {
              _data.setWatched(_source, true);
              _data.positions.remove(_source.id);
              _positionReady = false;
              _saveSettings();
              widget.onWatched?.call();
              if (!_repeatVideo && _data.autoAdvance) unawaited(_step(1));
            }
          }),
          player.stream.playing.listen((playing) {
            if (_closed) return;
            if (playing && widget.music.audio.playing) {
              unawaited(widget.music.audio.toggle());
            }
            unawaited(_updatePip());
          }),
        ]);
        await video.platform.future;
        if (!_canPlay) return;
        await _native.setProperty('network-timeout', '60');
        await _applySavedConfigurations();
        for (final entry in _data.subtitleStyle.entries.toList()) {
          if (!_canPlay) return;
          await _setOption(entry.key, entry.value);
        }
      } else {
        await _player!.stop();
        if (_cropped) {
          await _native.command(['vf', 'remove', '@auralis-crop']);
          _cropped = false;
        }
      }
      if (!_canPlay) return;
      await _native.setProperty('secondary-sid', 'no');
      if (!_canPlay) return;
      if (widget.music.audio.playing) await widget.music.audio.toggle();
      if (!_canPlay) return;
      if (Platform.isAndroid && _session == null) {
        final session = await AudioSession.instance;
        if (!_canPlay) return;
        _session = session;
        _subscriptions.add(
          session.interruptionEventStream.listen((event) {
            if (event.begin) unawaited(_player?.pause());
          }),
        );
      }
      var source = _source;
      if (source.telegram case final Track reference when reference.fileId == null) {
        final restored = await Future.any([
          widget.telegram.restoreVideo(reference),
          _closing.future,
        ]);
        if (!_canPlay) return;
        if (restored == null) {
          throw const FormatException('This Telegram video is unavailable.');
        }
        _queue[_index] = source = VideoSource.telegram(restored);
      }
      final track = source.telegram;
      if (track == null) await widget.proxy.stop();
      final uri = track == null ? source.uri! : await widget.proxy.uri(track);
      if (!_canPlay) return;
      if (await _session?.setActive(true) == false) {
        throw StateError('Audio focus unavailable');
      }
      if (!_canPlay) return;
      final start = _resumeSeek ? _data.positions[source.id] : null;
      await _native.setProperty('start', 'none');
      if (Platform.isAndroid && _brightness == null) {
        try {
          _brightness = await _videoWindow.invokeMethod<double>(
            'getBrightness',
          );
        } on PlatformException {
          // Brightness stays controlled by Android when unavailable.
        } on MissingPluginException {
          // Playback can run without a window integration.
        }
      }
      if (!_canPlay) return;
      _acceptVideoParams = true;
      if (Platform.isAndroid) {
        _startupTimeout = Timer(const Duration(seconds: 45), () {
          _setError('The video took too long to start. Try again.');
          if (_opening && track != null) {
            unawaited(
              _releaseStep(widget.proxy.interrupt, 'interrupt video reads'),
            );
          }
        });
      }
      await _player!.open(
        mpv.Media(uri.toString(), start: start),
        play: _data.autoplay,
      );
      if (!_canPlay || _error != null) return;
      widget.onOpened(source);
      _hasHistoryRecord = _data.history.containsKey(source.id);
      await _applyOrientation();
      unawaited(_updateRefreshRate());
    } catch (failure) {
      if (_canPlay) {
        unawaited(widget.proxy.stop());
        _setError(
          failure is FormatException
              ? failure.message
              : 'Could not start the video.',
        );
      }
    } finally {
      _opening = _loading = false;
      if (mounted && !_closed) setState(() {});
      _changed();
    }
  }


  Future<void> _readChapters() async {
    if (!_canPlay || _player == null) return;
    final id = _source.id;
    try {
      final count =
          (int.tryParse(await _native.getProperty('chapter-list/count')) ?? 0)
              .clamp(0, 500);
      final result = <VideoBookmark>[];
      for (var i = 0; i < count && _canPlay && id == _source.id; i++) {
        final seconds = double.tryParse(
          await _native.getProperty('chapter-list/$i/time'),
        );
        if (seconds == null ||
            !seconds.isFinite ||
            seconds < 0 ||
            seconds > 31536000) {
          continue;
        }
        final title = await _native.getProperty('chapter-list/$i/title');
        result.add(
          VideoBookmark(
            Duration(milliseconds: (seconds * 1000).round()),
            title.isEmpty ? 'Chapter ${i + 1}' : title,
          ),
        );
      }
      if (!_canPlay || id != _source.id) return;
      _chapters = result;
      _changed();
    } catch (_) {
      // Chapter metadata is optional.
    }
  }

  void _saveSettings() =>
      unawaited(widget.music.settings.save().catchError((Object _) {}));

  void _saveProgress() {
    if (!_positionReady ||
        _closed ||
        _invalidated ||
        _opening ||
        _error != null) {
      return;
    }
    final id = _source.id;
    if (_data.isWatched(_source)) return;
    if (_hasHistoryRecord && !_data.history.containsKey(id)) return;
    final old = _data.positions[id];
    if (old == _position) return;
    _data.remember(id, _position, _duration);
    if (old != _data.positions[id]) _saveSettings();
  }

  Future<void> _switchTo(int index) async {
    if (_opening || index < 0 || index >= _queue.length || index == _index) {
      return;
    }
    if (_queue[index].telegram != null && !widget.telegram.ready) {
      _notice('Reconnect Telegram to play this video.');
      return;
    }
    _saveProgress();
    _index = index;
    await _open();
  }

  Future<void> _step(int direction) async {
    final next = _index + direction;
    if (_shuffle && direction > 0 && _queue.length > 1) {
      final pick = math.Random().nextInt(_queue.length - 1);
      await _switchTo(pick >= _index ? pick + 1 : pick);
    } else {
      await _switchTo(next);
    }
  }

  Future<void> _seek(Duration target) async {
    if (!_canPlay ||
        _player == null ||
        _opening ||
        _duration <= Duration.zero) {
      return;
    }
    final position = Duration(
      milliseconds: target.inMilliseconds.clamp(0, _duration.inMilliseconds),
    );
    await _player!.seek(position);
  }

  Future<void> _togglePlayback() async {
    if (!_canPlay || _opening || _player == null) return;
    if (_player!.state.completed) {
      await _seek(Duration.zero);
      if (!_canPlay) return;
      await _player!.play();
    } else {
      await _player!.playOrPause();
    }
  }

  Future<void> _setZoom(double zoom, {double? x, double? y}) async {
    if (!_canPlay || _player == null) return;
    _zoom = zoom.clamp(-1, 2);
    _panX = (x ?? _panX).clamp(-1, 1);
    _panY = (y ?? _panY).clamp(-1, 1);
    await _native.setProperty('video-zoom', _zoom.toStringAsFixed(3));
    if (!_canPlay) return;
    await _native.setProperty('video-pan-x', _panX.toStringAsFixed(3));
    if (!_canPlay) return;
    await _native.setProperty('video-pan-y', _panY.toStringAsFixed(3));
  }

  Future<void> _applyOrientation() async {
    if (!Platform.isAndroid || _closed) return;
    final orientation = widget.minimized ? _Orientation.free : _orientation;
    // Keep startup in landscape. After it starts, use the decoder's display
    // dimensions, which already account for rotation metadata.
    final state = _acceptVideoParams && _startupTimeout?.isActive != true
        ? _player?.state
        : null;
    final width = state?.width ?? 0;
    final height = state?.height ?? 0;
    final allowed = switch (orientation) {
      _Orientation.video when width > 0 && height > width =>
        _Orientation.sensorPortrait.orientations,
      _Orientation.video => _Orientation.sensorLandscape.orientations,
      _ => orientation.orientations,
    };
    if (listEquals(allowed, _requestedOrientations)) return;
    _requestedOrientations = allowed;
    await _releaseStep(
      () => SystemChrome.setPreferredOrientations(allowed),
      'set video orientation',
    );
  }

  Future<T> _withFilePicker<T>(Future<T> Function() pick) async {
    _selectingFile = true;
    await _updatePip();
    try {
      return await pick();
    } finally {
      _selectingFile = false;
      await _updatePip();
    }
  }

  Future<void> _pictureInPicture() async {
    if (!Platform.isAndroid || !_canPlay) return;
    try {
      await _updatePip();
      if (!_canPlay) return;
      final entered = await _videoWindow.invokeMethod<bool>('pictureInPicture');
      if (entered != true && mounted) {
        _notice('Picture in picture is unavailable on this device.');
      }
    } on PlatformException {
      if (mounted) _notice('Picture in picture is unavailable on this device.');
    }
  }

  @override
  void didUpdateWidget(covariant VideoPlayback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.minimized != oldWidget.minimized) {
      unawaited(_applyOrientation());
      unawaited(_updatePip());
      unawaited(_updateRefreshRate());
    }
  }

  Future<void> _setBrightness(double value) async {
    if (!Platform.isAndroid || _closed) return;
    _brightness = value.clamp(.01, 1);
    _brightnessChanged = true;
    try {
      await _videoWindow.invokeMethod<void>('brightness', _brightness);
    } on PlatformException {
      // Ignore devices that do not expose per-window brightness.
    } on MissingPluginException {
      // Widget tests do not have an Android window.
    }
  }

  void _notice(String text) {
    if (!mounted || _closed) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _releaseStep(Future<void> Function() action, String step) async {
    try {
      await action();
    } catch (_) {
      debugPrint('Video shutdown: could not $step.');
    }
  }

  Future<void> _release(
    VideoPlayback playback, {
    required bool detachSurface,
  }) async {
    if (Platform.isAndroid) {
      // Close active HTTP sockets so mpv can abort a read during shutdown.
      // Keep the Telegram file buffer until the decoder has stopped.
      await _releaseStep(playback.proxy.interrupt, 'interrupt video reads');
    }
    await _releaseStep(() async {
      await _openingTask;
    }, 'finish opening media');
    for (final subscription in _subscriptions) {
      await _releaseStep(subscription.cancel, 'detach playback listener');
    }
    await _releaseStep(() => _shaderUpdates, 'finish video filter changes');
    if (Platform.isWindows) {
      // Unload playback while the Windows renderer can still consume its last
      // update. Disposing the player also tears down the native texture.
      await _releaseStep(() async {
        await _player?.stop();
      }, 'stop Windows video playback');
    }
    if (detachSurface && mounted && _video != null) {
      setState(() => _surfaceDetached = true);
      if (WidgetsBinding.instance.framesEnabled) {
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    await _releaseStep(() async {
      await _player?.dispose();
    }, 'release the decoder');
    // The decoder may still be reading the proxy while it stops.
    await _releaseStep(playback.proxy.stop, 'close the Telegram video stream');
    if (_scripts case final Directory scripts) {
      await _releaseStep(() async {
        await scripts.delete(recursive: true);
      }, 'remove script cache');
    }
    await _releaseStep(() async {
      if (!playback.music.audio.playing) await _session?.setActive(false);
    }, 'release audio focus');
    if (Platform.isAndroid) {
      await _releaseStep(_resetAndroidWindow, 'reset the Android video window');
    }
    if (playback.music.releaseVideo == _releaseForExit) {
      playback.music.releaseVideo = null;
    }
  }

  Future<void> _resetAndroidWindow() async {
    try {
      await SystemChrome.setPreferredOrientations([]);
      await _videoWindow.invokeMethod<void>('autoPip', {
        'auto': false,
        'playing': false,
      });
      if (_brightnessChanged) {
        await _videoWindow.invokeMethod<void>('brightness');
      }
      await _videoWindow.invokeMethod<void>('matchRefreshRate');
    } on PlatformException {
      // Window may have closed before the route.
    } on MissingPluginException {
      // Widget tests do not have an Android window.
    }
  }

  Future<void> _releaseForExit() => _beginRelease(detachSurface: true);

  Future<void> _beginRelease({required bool detachSurface}) {
    if (_releaseTask case final Future<void> release) return release;
    _saveProgress();
    _closed = true;
    _closing.complete(null);
    _checkpoint?.cancel();
    _startupTimeout?.cancel();
    _sleepTimer?.cancel();
    _thermalTimer?.cancel();
    widget.music.audio.removeListener(_musicChanged);
    widget.telegram.removeListener(_authorizationChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      _videoWindow.setMethodCallHandler(null);
    }
    final playback = widget;
    final release = _releaseTask = Future<void>.microtask(
      () => _release(playback, detachSurface: detachSurface),
    );
    widget.onRelease?.call(release);
    return release;
  }

  @override
  void dispose() {
    unawaited(_beginRelease(detachSurface: false));
    _changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_surfaceDetached) {
      return const PopScope(canPop: false, child: SizedBox.shrink());
    }
    final video = _video;
    final surface = Scaffold(
      backgroundColor: Colors.black,
      body: video == null
          ? ListenableBuilder(
              listenable: _changes,
              builder: (context, _) => SafeArea(
                child: Stack(
                  children: [
                    Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : _failure(context),
                    ),
                    PositionedDirectional(
                      start: 12,
                      top: 6,
                      child: BackButton(
                        onPressed: widget.onBack,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : Video(
              controller: video,
              fit: _fit.boxFit,
              subtitleViewConfiguration: const SubtitleViewConfiguration(
                visible: false,
              ),
              pauseUponEnteringBackgroundMode: false,
              resumeUponEnteringForegroundMode: false,
              controls: (state) => _VideoHud(this, state),
            ),
    );
    if (widget.onBack == null) return surface;
    return PopScope(
      canPop: widget.minimized || video != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !widget.minimized && video == null) {
          widget.onBack?.call();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: widget.minimized,
            child: ExcludeFocus(
              excluding: widget.minimized,
              child: TickerMode(enabled: !widget.minimized, child: surface),
            ),
          ),
          if (widget.minimized && MediaQuery.viewInsetsOf(context).bottom == 0)
            Positioned(
              left: 12,
              right: 12,
              bottom:
                  widget.miniBottomInset +
                  MediaQuery.paddingOf(context).bottom +
                  8,
              child: Align(
                alignment: widget.miniBottomInset == 0
                    ? AlignmentDirectional.bottomEnd
                    : Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: _miniPlayer(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniPlayer(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) => StreamBuilder<bool>(
        stream: _player?.stream.playing,
        builder: (context, _) {
          final playing = _player?.state.playing == true;
          return Material(
            key: const ValueKey('video-mini-player'),
            color: colors.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                Expanded(
                  child: ListTile(
                    leading: Icon(
                      Icons.smart_display_rounded,
                      color: colors.primary,
                    ),
                    title: Text(
                      _source.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _error == null ? 'Video playback' : 'Playback error',
                    ),
                    onTap: widget.onExpand,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: playing ? 'Pause video' : 'Play video',
                  onPressed: _loading || _error != null
                      ? null
                      : _togglePlayback,
                  icon: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                ),
                IconButton(
                  tooltip: 'Close video',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _failure(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error ?? '', textAlign: TextAlign.center),
          if (_canPlay)
            FilledButton.tonal(
              onPressed: _opening ? null : _open,
              child: const Text('Retry'),
            ),
        ],
      ),
    ),
  );
}
