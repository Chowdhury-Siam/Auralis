import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'storage.dart';
import 'video_playback_data.dart';

enum VideoDiagnostic {
  decoder('Video decoder', Icons.memory_rounded),
  information('Playback information', Icons.info_outline_rounded),
  console('mpv console', Icons.terminal_rounded),
  script('Load a player script', Icons.code_rounded);

  const VideoDiagnostic(this.label, this.icon);
  final String label;
  final IconData icon;
}

bool supportsVideoControl(VideoControl control) => switch (control) {
  VideoControl.fullscreen =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS,
  VideoControl.orientation || VideoControl.pip => Platform.isAndroid,
  _ => true,
};

String videoControlLabel(VideoPlaybackData data, VideoControl control) =>
    data.commands[control]?.label ?? control.label;

void _saveVideoSettings(
  BuildContext context,
  AppSettings settings,
  VoidCallback? onChanged,
) {
  onChanged?.call();
  unawaited(settings.save().catchError((Object _) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not save video settings.')),
      );
    }
  }));
}

class VideoSettingsOptions extends StatelessWidget {
  const VideoSettingsOptions({
    super.key,
    required this.settings,
    this.onChanged,
    this.onVolumeBoostDisabled,
    this.onFrameRateChanged,
    this.onAutoPipChanged,
    this.diagnostics = const {},
  });

  final AppSettings settings;
  final VoidCallback? onChanged,
      onVolumeBoostDisabled,
      onFrameRateChanged,
      onAutoPipChanged;
  final Map<VideoDiagnostic, Future<void> Function(BuildContext)> diagnostics;
  VideoPlaybackData get _data => settings.videoPlayback;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (label, icon, open) in [
        ('Player settings', Icons.settings_outlined, _settingsPanel),
        (
          'Player control layout',
          Icons.dashboard_customize_outlined,
          _layoutPanel,
        ),
        ('Custom buttons', Icons.extension_outlined, _customControlsPanel),
        ('mpv configuration', Icons.build_outlined, _configurationPanel),
      ])
        ListTile(
          leading: Icon(icon),
          title: Text(label),
          trailing: const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: () => open(context),
        ),
      const Divider(),
      if (diagnostics.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Open a video and choose More → Video settings to use playback diagnostics.',
          ),
        ),
      for (final diagnostic in VideoDiagnostic.values)
        ListTile(
          enabled: diagnostics.containsKey(diagnostic),
          leading: Icon(diagnostic.icon),
          title: Text(diagnostic.label),
          onTap: diagnostics[diagnostic] == null
              ? null
              : () => diagnostics[diagnostic]!(context),
        ),
    ],
  );

  Future<T?> _choose<T>(
    BuildContext context,
    String title,
    List<({T value, String label, bool selected})> choices,
  ) => showAuralisDialog<T>(
    context: context,
    builder: (dialog) => AuralisDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final choice in choices)
            AuralisChoiceTile(
              title: Text(choice.label),
              selected: choice.selected,
              onTap: () => Navigator.pop(dialog, choice.value),
            ),
        ],
      ),
    ),
  );

  Future<void> _customControlsPanel(BuildContext context) async {
    final slot = await _choose<VideoControl>(context, 'Custom buttons', [
      for (final slot in const [
        VideoControl.customOne,
        VideoControl.customTwo,
        VideoControl.customThree,
      ])
        (value: slot, label: videoControlLabel(_data, slot), selected: false),
    ]);
    if (slot != null && context.mounted) {
      await showVideoCommandEditor(context, settings, slot, onChanged: onChanged);
    }
  }

  Future<void> _settingsPanel(BuildContext context) async {
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          Widget toggle(String label, bool value, ValueChanged<bool> setter) =>
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label),
                value: value,
                onChanged: (next) {
                  update(() => setter(next));
                  _saveVideoSettings(context, settings, onChanged);
                },
              );
          return AuralisDialog(
            title: const Text('Player settings'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Seek interval · ${_data.seekSeconds} seconds'),
                Slider(
                  min: 5,
                  max: 60,
                  divisions: 11,
                  value: _data.seekSeconds.toDouble().clamp(5, 60),
                  onChanged: (value) =>
                      update(() => _data.seekSeconds = value.round()),
                  onChangeEnd: (_) =>
                      _saveVideoSettings(context, settings, onChanged),
                ),
                toggle(
                  'Tap and swipe gestures',
                  _data.gestures,
                  (value) => _data.gestures = value,
                ),
                toggle(
                  'Require double tap for every seek',
                  _data.strictDoubleTap,
                  (value) => _data.strictDoubleTap = value,
                ),
                if (Platform.isAndroid)
                  toggle(
                    'Swap brightness and volume sides',
                    _data.swapSides,
                    (value) => _data.swapSides = value,
                  ),
                toggle('Allow volume boost', _data.volumeBoost, (value) {
                  _data.volumeBoost = value;
                  if (!value) onVolumeBoostDisabled?.call();
                }),
                toggle(
                  'Play immediately when opened',
                  _data.autoplay,
                  (value) => _data.autoplay = value,
                ),
                toggle(
                  'Play next video automatically',
                  _data.autoAdvance,
                  (value) => _data.autoAdvance = value,
                ),
                toggle(
                  'Automatically skip saved segments',
                  _data.autoSkip,
                  (value) => _data.autoSkip = value,
                ),
                toggle(
                  'Include subtitles in snapshots',
                  _data.snapshotSubtitles,
                  (value) => _data.snapshotSubtitles = value,
                ),
                toggle(
                  'Continue playing in the background',
                  _data.background,
                  (value) => _data.background = value,
                ),
                if (Platform.isAndroid) ...[
                  toggle('GPU-next renderer (reopen video)', _data.gpuNext, (
                    value,
                  ) {
                    _data.gpuNext = value;
                  }),
                  toggle('Match video frame rate', _data.matchRefreshRate, (
                    value,
                  ) {
                    _data.matchRefreshRate = value;
                    onFrameRateChanged?.call();
                  }),
                ],
                if (Platform.isAndroid)
                  toggle(
                    'Picture in picture when leaving the app',
                    _data.autoPip,
                    (value) {
                      _data.autoPip = value;
                      onAutoPipChanged?.call();
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
          );
        },
      ),
    );
  }

  Future<void> _layoutPanel(BuildContext context) async {
    var wide = MediaQuery.sizeOf(context).width >= 660;
    var zone = VideoControlZone.topEnd;
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void change(VoidCallback change) {
            update(change);
            _saveVideoSettings(context, settings, onChanged);
          }

          final items = _data
              .controls(zone, wide: wide)
              .where(supportsVideoControl)
              .toList();
          return AuralisDialog(
            title: const Text('Player control layout'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final landscape in [false, true])
                      ChoiceChip(
                        label: Text(landscape ? 'Landscape' : 'Portrait'),
                        selected: wide == landscape,
                        onSelected: (_) => update(() => wide = landscape),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final value in VideoControlZone.values)
                      ChoiceChip(
                        label: Text(value.label),
                        selected: zone == value,
                        onSelected: (_) => update(() => zone = value),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Buttons in this area · ${items.length}/${zone.limit}'),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    for (final control in [
                      ...items,
                      ...VideoControl.values.where(
                        (item) => supportsVideoControl(item) && !items.contains(item),
                      ),
                    ])
                      FilterChip(
                        label: Text(videoControlLabel(_data, control)),
                        selected: items.contains(control),
                        onSelected:
                            items.contains(control) || items.length < zone.limit
                            ? (enabled) => change(() {
                                _data.setControls(
                                  zone,
                                  wide: wide,
                                  controls: [
                                    ...items.where((item) => item != control),
                                    if (enabled) control,
                                  ],
                                );
                              })
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Transparent button backgrounds'),
                  value: _data.transparentControls,
                  onChanged: (value) =>
                      change(() => _data.transparentControls = value),
                ),
                DropdownButton<VideoControlAnimation>(
                  isExpanded: true,
                  value: _data.animation,
                  items: [
                    for (final style in VideoControlAnimation.values)
                      DropdownMenuItem(
                        value: style,
                        child: Text('Animation · ${style.label}'),
                      ),
                  ],
                  onChanged: (style) {
                    if (style != null) change(() => _data.animation = style);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    change(() => _data.setControls(zone, wide: wide)),
                child: const Text('Reset this area'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
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
    if (input == null || !context.mounted) return;
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
                _saveVideoSettings(context, settings, onChanged);
                Navigator.pop(dialog);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showVideoCommandEditor(
  BuildContext context,
  AppSettings settings,
  VideoControl slot, {
  VoidCallback? onChanged,
}) async {
  final data = settings.videoPlayback;
  final existing = data.commands[slot];
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
                data.commands.remove(slot);
                _saveVideoSettings(context, settings, onChanged);
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
                data.commands[slot] = VideoCommand(
                  name,
                  VideoCommand.parse(command),
                );
                _saveVideoSettings(context, settings, onChanged);
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
