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
    this.inDialog = false,
  });

  final AppSettings settings;
  final VoidCallback? onChanged,
      onVolumeBoostDisabled,
      onFrameRateChanged,
      onAutoPipChanged;
  final Map<VideoDiagnostic, Future<void> Function(BuildContext)> diagnostics;
  final bool inDialog;
  VideoPlaybackData get _data => settings.videoPlayback;

  @override
  Widget build(BuildContext context) => inDialog
      ? _content(context, false)
      : LayoutBuilder(
          builder: (context, box) => _content(
            context,
            box.maxWidth >= 640 &&
                MediaQuery.textScalerOf(context).scale(14) < 21,
          ),
        );

  Widget _content(BuildContext context, bool twoColumns) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actions = [
      for (final (label, detail, icon, open) in [
        (
          'Player settings',
          'Playback, gestures, audio and snapshots.',
          Icons.tune_rounded,
          _settingsPanel,
        ),
        (
          'Player control layout',
          'Arrange each area in portrait and landscape.',
          Icons.dashboard_customize_outlined,
          _layoutPanel,
        ),
        (
          'Custom buttons',
          'Give your own mpv commands a place in the player.',
          Icons.extension_outlined,
          _customControlsPanel,
        ),
        (
          'mpv configuration',
          'Edit player options and keyboard shortcuts.',
          Icons.code_rounded,
          _configurationPanel,
        ),
      ])
        VideoSettingsAction(
          title: label,
          description: detail,
          icon: icon,
          onTap: () => open(context),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!inDialog) ...[
          Container(
            key: const ValueKey('video-settings-intro'),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const VideoSettingsIcon(icon: Icons.movie_outlined),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your player, your way',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Personalize Video without changing Music settings.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        for (var index = 0; index < actions.length; index += twoColumns ? 2 : 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: twoColumns
                ? IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: actions[index]),
                        const SizedBox(width: 12),
                        Expanded(child: actions[index + 1]),
                      ],
                    ),
                  )
                : actions[index],
          ),
        const SizedBox(height: 8),
        if (diagnostics.isEmpty)
          VideoSettingsGroup(
            key: const ValueKey('video-diagnostics-idle'),
            title: 'Live diagnostics',
            description: 'Available while a video is open',
            children: [
              Text(
                'Open a video, then choose More → Video settings for decoder controls, '
                'playback information, the mpv console and player scripts.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Live diagnostics',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final diagnostic in VideoDiagnostic.values)
            if (diagnostics[diagnostic] case final open?)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: VideoSettingsAction(
                  title: diagnostic.label,
                  description: switch (diagnostic) {
                    VideoDiagnostic.decoder =>
                      'Choose hardware or software decoding.',
                    VideoDiagnostic.information =>
                      'Live codecs, frame rate and playback health.',
                    VideoDiagnostic.console =>
                      'Run a command and inspect recent player logs.',
                    VideoDiagnostic.script =>
                      'Load a local script for the current player.',
                  },
                  icon: diagnostic.icon,
                  onTap: () => open(context),
                ),
              ),
        ],
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
