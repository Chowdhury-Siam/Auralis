import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'preference_widgets.dart';
import 'storage.dart';
import 'video_playback_data.dart';
import 'video_settings_widgets.dart';

export 'video_settings_widgets.dart';

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
  unawaited(
    settings.save().catchError((Object _) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not save video settings.')),
        );
      }
    }),
  );
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
  Widget build(BuildContext context) {
    final active = [
      for (final diagnostic in VideoDiagnostic.values)
        if (diagnostics[diagnostic] case final open?) (diagnostic, open),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsActionTile(
          title: 'Player settings',
          icon: Icons.tune_rounded,
          first: true,
          onTap: () => _settingsPanel(context),
        ),
        SettingsActionTile(
          title: 'Player control layout',
          icon: Icons.dashboard_customize_outlined,
          onTap: () => _layoutPanel(context),
        ),
        SettingsActionTile(
          title: 'Custom buttons',
          icon: Icons.extension_outlined,
          onTap: () => _customControlsPanel(context),
        ),
        SettingsActionTile(
          title: 'mpv configuration',
          icon: Icons.code_rounded,
          last: true,
          onTap: () => _configurationPanel(context),
        ),
        const SizedBox(height: 8),
        if (active.isEmpty)
          const SettingsActionTile(
            key: ValueKey('video-diagnostics-idle'),
            title: 'Live diagnostics',
            subtitle: 'Open a video and choose More → Video settings.',
            icon: Icons.monitor_heart_outlined,
            first: true,
            last: true,
          )
        else
          for (var i = 0; i < active.length; i++)
            SettingsActionTile(
              title: active[i].$1.label,
              icon: active[i].$1.icon,
              first: i == 0,
              last: i == active.length - 1,
              onTap: () => active[i].$2(context),
            ),
      ],
    );
  }

  Future<T?> _choose<T>(
    BuildContext context,
    String title,
    List<({T value, String label, bool selected})> choices,
  ) => showAuralisDialog<T>(
    context: context,
    builder: (dialog) => VideoSettingsDialog(
      title: title,
      icon: title == 'mpv configuration'
          ? Icons.code_rounded
          : Icons.extension_outlined,
      description: title == 'mpv configuration'
          ? 'Choose a configuration file to edit. Changes apply when the player reopens.'
          : 'Choose a slot to edit its name and command.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final choice in choices)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                child: AuralisChoiceTile(
                  title: Text(choice.label),
                  subtitle: Text(
                    choice.selected ? 'Configured' : 'Not configured yet',
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () => Navigator.pop(dialog, choice.value),
                ),
              ),
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
        (
          value: slot,
          label: videoControlLabel(_data, slot),
          selected: _data.commands.containsKey(slot),
        ),
    ]);
    if (slot != null && context.mounted) {
      await showVideoCommandEditor(
        context,
        settings,
        slot,
        onChanged: onChanged,
      );
    }
  }

  Future<void> _settingsPanel(BuildContext context) async {
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          Widget toggle(String label, bool value, ValueChanged<bool> setter) =>
              SwitchListTile(
                dense: false,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                value: value,
                onChanged: (next) {
                  update(() => setter(next));
                  _saveVideoSettings(context, settings, onChanged);
                },
              );
          return VideoSettingsDialog(
            title: 'Player settings',
            icon: Icons.tune_rounded,
            description: 'Fine-tune how Video plays and responds.',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VideoSettingsGroup(
                  title: 'Seeking & gestures',
                  description:
                      'Control how taps and swipes move through a video.',
                  children: [
                    Text('Seek interval · ${_data.seekSeconds} seconds'),
                    Slider(
                      min: 5,
                      max: 60,
                      divisions: 11,
                      value: _data.seekSeconds.toDouble().clamp(5, 60),
                      label: '${_data.seekSeconds} seconds',
                      semanticFormatterCallback: (value) =>
                          '${value.round()} seconds',
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
                    TextButton.icon(
                      onPressed: () async {
                        await _gesturePanel(context);
                        if (context.mounted) update(() {});
                      },
                      icon: const Icon(Icons.touch_app_outlined),
                      label: const Text('Customize each gesture'),
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
                  ],
                ),
                VideoSettingsGroup(
                  title: 'Playback',
                  description:
                      'Choose what happens when a video opens or ends.',
                  children: [
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
                      'Continue playing in the background',
                      _data.background,
                      (value) => _data.background = value,
                    ),
                  ],
                ),
                VideoSettingsGroup(
                  title: 'Audio & snapshots',
                  children: [
                    toggle('Allow volume boost', _data.volumeBoost, (value) {
                      _data.volumeBoost = value;
                      if (!value) onVolumeBoostDisabled?.call();
                    }),
                    toggle(
                      'Include subtitles in snapshots',
                      _data.snapshotSubtitles,
                      (value) => _data.snapshotSubtitles = value,
                    ),
                  ],
                ),
                if (Platform.isAndroid) ...[
                  VideoSettingsGroup(
                    title: 'Device behavior',
                    description:
                        'Display and picture-in-picture options for Android.',
                    children: [
                      toggle(
                        'GPU-next renderer (reopen video)',
                        _data.gpuNext,
                        (value) {
                          _data.gpuNext = value;
                        },
                      ),
                      toggle('Match video frame rate', _data.matchRefreshRate, (
                        value,
                      ) {
                        _data.matchRefreshRate = value;
                        onFrameRateChanged?.call();
                      }),
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
                ],
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

  Future<void> _gesturePanel(BuildContext context) async {
    await showAuralisDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          void change(VoidCallback action) {
            update(action);
            _saveVideoSettings(context, settings, onChanged);
          }

          Widget choice<T>(
            String title,
            T value,
            List<T> values,
            String Function(T) label,
            ValueChanged<T> set,
          ) => PreferenceChoice<T>(
            title: title,
            value: value,
            values: values,
            label: label,
            onSelected: (value) => change(() => set(value)),
          );
          final options = _data.gestureOptions;
          final desktop =
              Platform.isWindows || Platform.isLinux || Platform.isMacOS;
          return VideoSettingsDialog(
            title: 'Gesture customization',
            icon: Icons.touch_app_outlined,
            description:
                'Toggle each input independently. The master Tap and swipe switch '
                'still controls touch gestures. Buttons, Back/unlock and the locked skip button stay available.',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VideoSettingsGroup(
                  title: 'Individual gestures',
                  children: [
                    for (final gesture in VideoGesture.values)
                      if ((gesture != VideoGesture.swipeBrightness ||
                              Platform.isAndroid) &&
                          (gesture != VideoGesture.spaceHold || desktop))
                        SwitchListTile(
                          key: ValueKey('video-gesture-${gesture.name}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(gesture.label),
                          value: options.enabled(gesture),
                          onChanged: (value) =>
                              change(() => options.setEnabled(gesture, value)),
                        ),
                  ],
                ),
                VideoSettingsGroup(
                  title: 'Sensitivity & timing',
                  children: [
                    choice<int>(
                      'Side seek zones',
                      options.seekZonePercent,
                      [25, 30, 36, 40],
                      (value) => '$value% each side',
                      (value) => options.seekZonePercent = value,
                    ),
                    choice<int>(
                      'Swipe seek range',
                      options.swipeSeekSeconds,
                      [30, 60, 120, 240, 600],
                      (value) => '$value seconds per width',
                      (value) => options.swipeSeekSeconds = value,
                    ),
                    choice<double>(
                      'Volume / brightness sensitivity',
                      options.swipeSensitivity,
                      [.5, 1, 1.5, 2],
                      (value) => '$value×',
                      (value) => options.swipeSensitivity = value,
                    ),
                    choice<double>(
                      'Pinch zoom sensitivity',
                      options.zoomSensitivity,
                      [.5, 1, 1.5, 2],
                      (value) => '$value×',
                      (value) => options.zoomSensitivity = value,
                    ),
                    choice<double>(
                      'Temporary speed',
                      options.boostRate,
                      [1.25, 1.5, 1.75, 2, 2.5, 3],
                      (value) => '$value×',
                      (value) => options.boostRate = value,
                    ),
                    if (desktop)
                      choice<int>(
                        'Space-hold delay',
                        options.spaceHoldMs,
                        [250, 400, 600, 800],
                        (value) => '$value ms',
                        (value) => options.spaceHoldMs = value,
                      ),
                    choice<int>(
                      'Hide controls after',
                      options.hideSeconds,
                      [0, 2, 4, 6, 10],
                      (value) => value == 0 ? 'Never' : '$value seconds',
                      (value) => options.hideSeconds = value,
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: () async {
                    final confirmed = await confirmAuralisAction(
                      context,
                      title: 'Reset video gestures?',
                      message:
                          'Restore gesture switches, sensitivity, timing, seek interval and sides. '
                          'Other Video and Music settings are unchanged.',
                      confirmLabel: 'Reset gestures',
                    );
                    if (confirmed == true && context.mounted) {
                      change(() {
                        _data.gestureOptions = VideoGestureOptions();
                        _data.gestures = true;
                        _data.strictDoubleTap = false;
                        _data.swapSides = false;
                        _data.seekSeconds = 10;
                      });
                    }
                  },
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset gestures'),
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
          return VideoSettingsDialog(
            title: 'Player control layout',
            icon: Icons.dashboard_customize_outlined,
            description: 'Design portrait and landscape layouts independently.',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VideoSettingsGroup(
                  title: 'Layout & position',
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
                  ],
                ),
                VideoSettingsGroup(
                  title: 'Buttons in this area · ${items.length}/${zone.limit}',
                  description: 'Selected buttons appear in selection order. Each area has a fixed limit.',
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        for (final control in [
                          ...items,
                          ...VideoControl.values.where(
                            (item) =>
                                supportsVideoControl(item) &&
                                !items.contains(item),
                          ),
                        ])
                          FilterChip(
                            label: Text(videoControlLabel(_data, control)),
                            selected: items.contains(control),
                            onSelected:
                                items.contains(control) ||
                                    items.length < zone.limit
                                ? (enabled) => change(() {
                                    _data.setControls(
                                      zone,
                                      wide: wide,
                                      controls: [
                                        ...items.where(
                                          (item) => item != control,
                                        ),
                                        if (enabled) control,
                                      ],
                                    );
                                  })
                                : null,
                          ),
                      ],
                    ),
                  ],
                ),
                VideoSettingsGroup(
                  title: 'Appearance & motion',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Transparent button backgrounds'),
                      value: _data.transparentControls,
                      onChanged: (value) =>
                          change(() => _data.transparentControls = value),
                    ),
                    PreferenceChoice<VideoControlAnimation>(
                      title: 'Control animation',
                      value: _data.animation,
                      values: VideoControlAnimation.values,
                      label: (style) => style.label,
                      onSelected: (style) =>
                          change(() => _data.animation = style),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    change(() => _data.setControls(zone, wide: wide)),
                child: const Text('Reset this area'),
              ),
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
        builder: (context, update) => VideoSettingsDialog(
          title: filename,
          icon: Icons.code_rounded,
          description:
              'Advanced options. Changes load when you reopen the player.',
          content: TextFormField(
            initialValue: text,
            minLines: 3,
            maxLines: 8,
            maxLength: 32768,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', height: 1.5),
            onChanged: (value) => text = value,
            decoration: InputDecoration(
              hintText: input ? 'Ctrl+j seek 10' : 'keep-open=yes',
              labelText: filename,
              alignLabelWithHint: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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
      builder: (context, update) => VideoSettingsDialog(
        title: slot.label,
        icon: Icons.extension_outlined,
        description:
            'Name your shortcut and enter an mpv command as a JSON array.',
        content: Column(
          children: [
            TextFormField(
              initialValue: label,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: 'Button name',
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onChanged: (value) => label = value,
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: command,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', height: 1.5),
              decoration: InputDecoration(
                labelText: 'mpv command',
                hintText: '["show-text", "Ready"]',
                alignLabelWithHint: true,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
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
