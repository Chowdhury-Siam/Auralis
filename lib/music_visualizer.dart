import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'music_visualizer_capture.dart';
import 'music_visualizer_data.dart';
import 'music_visualizer_webview.dart';
import 'player.dart';
import 'preference_widgets.dart';

typedef MusicVisualizerRendererBuilder = Widget Function(
  ValueChanged<Map<String, dynamic>> onMessage,
  ValueChanged<String> onError,
);

class MusicVisualizerPane extends StatefulWidget {
  const MusicVisualizerPane({
    super.key,
    required this.player,
    required this.mode,
    required this.fullscreen,
    required this.onFullscreen,
    this.webController,
    this.rendererBuilder,
  });
  final PlayerController player;
  final MusicPanel mode;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final MusicVisualizerWebController? webController;
  final MusicVisualizerRendererBuilder? rendererBuilder;

  @override
  State<MusicVisualizerPane> createState() => _MusicVisualizerPaneState();
}

class _MusicVisualizerPaneState extends State<MusicVisualizerPane>
    with WidgetsBindingObserver {
  late final _web = widget.webController ?? MusicVisualizerWebController();
  late final _capture = MusicVisualizerCapture(
    canRead: () => !_sending && _ready && _active,
    onFrame: (samples, rate) {
      if (!_ready || !_active || _sending) return;
      _sending = true;
      unawaited(
        _web
            .execute(
              'window.auralisVisuals?.feed(${jsonEncode(base64Encode(samples))},$rate)',
            )
            .catchError(
              (_) => _failed('Could not send output audio to the visualizer.'),
            )
            .whenComplete(() => _sending = false),
      );
    },
    onError: _failed,
  );
  bool _ready = false, _visible = true;
  bool _focused = true, _sending = false, _lastActive = false, _reduced = false;
  final _variation = Random.secure().nextInt(1 << 32);
  String _activePreset = '';
  String? _configuredSong;
  bool _systemReduced = false, _mobile = false, _windows = false;
  Object? _lastPlaybackState;
  Widget? _renderer;
  int? _viewId;
  AppLifecycleState? _lifecycle;
  String? _error;
  List<String> _presets = [];
  Timer? _readyTimeout;
  MusicVisualizerSettings get _settings =>
      widget.player.settings.musicVisualizer;
  bool get _active =>
      _ready &&
      _error == null &&
      _visible &&
      (_windows || _focused) &&
      !_reduced &&
      (_lifecycle == null ||
          _lifecycle == AppLifecycleState.resumed ||
          (_windows && _lifecycle == AppLifecycleState.inactive)) &&
      widget.player.audio.playing &&
      !widget.player.audio.buffering;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    widget.player.addListener(_playback);
    _watchReady();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _systemReduced = MediaQuery.disableAnimationsOf(context);
    _mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    _windows = Theme.of(context).platform == TargetPlatform.windows;
    _reduced = _systemReduced || widget.player.settings.reducedMotion;
    _lastPlaybackState = _playbackState;
    _sync();
  }

  @override
  void didUpdateWidget(MusicVisualizerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_playback);
      widget.player.addListener(_playback);
    }
    if (oldWidget.rendererBuilder != widget.rendererBuilder) _renderer = null;
    if (oldWidget.mode != widget.mode) _sync(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _sync();
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ui.ViewFocusState.focused;
    _sync();
  }

  void _playback() {
    _reduced = _systemReduced || widget.player.settings.reducedMotion;
    final state = _playbackState;
    if (state == _lastPlaybackState) return;
    _lastPlaybackState = state;
    _sync(force: true);
    if (mounted) setState(() {});
  }

  Object get _playbackState => (
    widget.player.audio.playing,
    widget.player.audio.buffering,
    widget.player.settings.reducedMotion,
    _settings.fps,
    widget.player.current?.id,
  );

  void _failed(String message) {
    if (!mounted) return;
    _readyTimeout?.cancel();
    setState(() => _error = message);
    _capture.setActive(false);
    unawaited(
      _web
          .execute('window.auralisVisuals?.configure({active:false})')
          .catchError((_) {}),
    );
  }

  void _sync({bool force = false, String? preset}) {
    final active = _active;
    // Animation FPS stays user-selectable. Native waveform reads do not need
    // to cross Android's platform/WebView bridges more than 30 times a second.
    final captureFps = _settings.fps.clamp(20, _mobile ? 30 : 60);
    _capture.setActive(active, fps: captureFps);
    if (!_ready || (!force && active == _lastActive)) return;
    _lastActive = active;
    final track = widget.player.current;
    final song = track == null
        ? ''
        : '${track.id}:${track.title}:${track.artist}';
    final value = {
      ...(_settings.toJson()..remove('preset')),
      'mode': widget.mode == MusicPanel.spectrum ? 'spectrum' : 'visualizer',
      'active': active,
      'song': song,
      'variation': _variation,
      if (preset != null || (!_settings.cycle && song != _configuredSong))
        'preset': preset ?? _settings.preset,
      'mobile': _mobile,
    };
    _configuredSong = song;
    unawaited(
      _web
          .execute('window.auralisVisuals?.configure(${jsonEncode(value)})')
          .catchError(
            (_) => _failed(
              'The visualizer could not start. Try another mode or return to Lyrics.',
            ),
          ),
    );
  }

  void _message(Map<String, dynamic> message) {
    if (!mounted) return;
    if (message['type'] == 'ready') {
      _readyTimeout?.cancel();
      _presets = (message['presets'] is List ? message['presets'] as List : [])
          .whereType<String>()
          .where((name) => name.length <= 300)
          .take(1000)
          .toList();
      setState(() => _ready = true);
      _sync(force: true);
    } else if (message['type'] == 'presets' && message['presets'] is List) {
      setState(
        () => _presets = (message['presets'] as List)
            .whereType<String>()
            .where((name) => name.length <= 300)
            .take(1000)
            .toList(),
      );
    } else if (message['type'] == 'preset' && message['name'] is String) {
      final name = message['name'] as String;
      if (_presets.contains(name)) {
        setState(() => _activePreset = name);
      }
    } else if (message['type'] == 'error') {
      _failed(
        'The graphics engine could not render this preset. Retry or return to Lyrics.',
      );
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _ready = false;
      _renderer = null;
      _configuredSong = null;
    });
    _watchReady();
  }

  void _watchReady() {
    _readyTimeout?.cancel();
    _readyTimeout = Timer(const Duration(seconds: 20), () {
      if (!_ready) {
        _failed(
          'The visualizer did not start. Update System WebView or WebView2 and retry.',
        );
      }
    });
  }

  Future<void> _save({String? preset}) async {
    _sync(force: true, preset: preset);
    try {
      await widget.player.settings.save();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Visualizer changed for this session. Could not save preferences.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _options() async {
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void change(VoidCallback action) {
            setState(action);
            update(() {});
            unawaited(_save());
          }

          final spectrum = widget.mode == MusicPanel.spectrum;
          return AuralisDialog(
            width: 380,
            maxWidth: 460,
            title: AuralisDialogTitle(
              spectrum ? 'Spectrum settings' : 'Visualizer settings',
              leading: PreferenceIcon(
                spectrum
                    ? Icons.graphic_eq_rounded
                    : Icons.auto_awesome_rounded,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PreferenceCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (spectrum) ...[
                        PreferenceChoice<String>(
                          title: 'Style',
                          value: _settings.spectrum,
                          values: MusicVisualizerSettings.spectrumStyles.keys
                              .toList(),
                          label: (value) =>
                              MusicVisualizerSettings.spectrumStyles[value]!,
                          onSelected: (value) =>
                              change(() => _settings.spectrum = value),
                        ),
                        PreferenceChoice<String>(
                          title: 'Colors',
                          value: _settings.palette,
                          values: MusicVisualizerSettings.spectrumPalettes.keys
                              .toList(),
                          label: (value) =>
                              MusicVisualizerSettings.spectrumPalettes[value]!,
                          onSelected: (value) =>
                              change(() => _settings.palette = value),
                        ),
                      ] else ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Song-driven motion'),
                          subtitle: const Text(
                            'React to beats and changes in energy',
                          ),
                          value: _settings.songMotion,
                          onChanged: (value) =>
                              change(() => _settings.songMotion = value),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Cycle presets'),
                          value: _settings.cycle,
                          onChanged: (value) =>
                              change(() => _settings.cycle = value),
                        ),
                        if (_settings.cycle)
                          PreferenceChoice<int>(
                            title: 'Change every',
                            value: _settings.cycleSeconds,
                            values: const [15, 30, 60],
                            label: (value) => '$value sec',
                            onSelected: (value) =>
                                change(() => _settings.cycleSeconds = value),
                          ),
                        AuralisChoiceTile(
                          leading: const Icon(
                            Icons.auto_awesome_motion_rounded,
                          ),
                          title: const Text('Choose preset'),
                          subtitle: Text(
                            _activePreset,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () async {
                            Navigator.pop(dialog);
                            await _choosePreset();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                PreferenceCard(
                  child: PreferenceChoice<int>(
                    title: 'Frame limit',
                    value: _settings.fps,
                    values: MusicVisualizerSettings.frameLimits,
                    label: (value) => '$value FPS',
                    onSelected: (value) => change(() => _settings.fps = value),
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _choosePreset() async {
    var query = '';
    final selected = await showAuralisDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AuralisDialog(
          title: const AuralisDialogTitle(
            'Choose preset',
            leading: PreferenceIcon(Icons.auto_awesome_motion_rounded),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search presets',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (value) =>
                    update(() => query = value.trim().toLowerCase()),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 240,
                child: ListView(
                  children: [
                    for (final name in _presets.where(
                      (name) => name.toLowerCase().contains(query),
                    ))
                      AuralisChoiceTile(
                        title: Text(name),
                        selected: name == _activePreset,
                        onTap: () => Navigator.pop(dialog, name),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _settings.preset = selected);
    await _save(preset: selected);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.player.removeListener(_playback);
    _readyTimeout?.cancel();
    unawaited(_capture.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq_rounded, size: 44, color: colors.primary),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Analyze device output audio locally, not the microphone. '
                'Other apps playing through the same output may also appear. '
                'Android calls the required output-analysis permission “microphone”. '
                'Nothing is recorded or uploaded. Animated presets may flash.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.graphic_eq_rounded),
                label: const Text('Retry visualizer'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          key: const ValueKey('music-visualizer-surface'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: _renderer ??= RepaintBoundary(
              child:
                  widget.rendererBuilder?.call(_message, _failed) ??
                  MusicVisualizerWebView(
                    controller: _web,
                    onMessage: _message,
                    onError: _failed,
                  ),
            ),
          ),
        ),
        if (_ready && !widget.player.audio.playing)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Paused', textAlign: TextAlign.center),
          ),
        if (_ready && _reduced)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Visualizers are stopped by your reduced-motion preference.',
              textAlign: TextAlign.center,
            ),
          ),
        Wrap(
          key: const ValueKey('music-visualizer-controls'),
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.mode == MusicPanel.visualizer) ...[
              IconButton(
                tooltip: 'Previous preset',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: !_ready
                    ? null
                    : () => unawaited(
                        _web.execute('window.auralisVisuals?.step(-1)'),
                      ),
              ),
              IconButton(
                tooltip: 'Random preset',
                icon: const Icon(Icons.shuffle_rounded),
                onPressed: !_ready
                    ? null
                    : () => unawaited(
                        _web.execute('window.auralisVisuals?.step(0)'),
                      ),
              ),
              IconButton(
                tooltip: 'Next preset',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: !_ready
                    ? null
                    : () => unawaited(
                        _web.execute('window.auralisVisuals?.step(1)'),
                      ),
              ),
            ],
            IconButton(
              tooltip: widget.mode == MusicPanel.spectrum
                  ? 'Spectrum settings'
                  : 'Visualizer settings',
              icon: const Icon(Icons.tune_rounded),
              onPressed: !_ready ? null : _options,
            ),
            if (!_mobile)
              IconButton(
                tooltip: widget.fullscreen
                    ? 'Exit expanded visualizer'
                    : 'Expand visualizer',
                icon: Icon(
                  widget.fullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                ),
                onPressed: widget.onFullscreen,
              ),
          ],
        ),
        if (widget.mode == MusicPanel.visualizer && _activePreset.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _activePreset,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}
