import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_navigation.dart';
import 'data_files.dart';
import 'models.dart';
import 'player.dart';
import 'setup_permissions.dart';
import 'stats_view.dart';
import 'storage.dart';
import 'telegram/telegram_service.dart';

enum _Step {
  welcome,
  telegram,
  notifications,
  backup,
  lyrics,
  artwork,
  library,
  navigation,
  playback,
  battery,
  finish,
}

class SetupView extends StatefulWidget {
  const SetupView({
    super.key,
    required this.player,
    required this.telegram,
    required this.version,
    required this.connectBuilder,
    required this.onFinished,
    this.files = const DataFiles(),
    this.permissions = const SetupPermissions(),
  });
  final PlayerController player;
  final TelegramService telegram;
  final String version;
  final WidgetBuilder connectBuilder;
  final VoidCallback onFinished;
  final DataFiles files;
  final SetupPermissions permissions;
  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> with WidgetsBindingObserver {
  int _index = 0;
  bool _busy = false, _checked = false, _restored = false;
  bool? _notifications, _battery;
  String? _error, _permissionError;
  final _scroll = ScrollController();
  AppSettings get prefs => widget.player.settings;
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool get _android => Theme.of(context).platform == TargetPlatform.android;
  List<_Step> get _steps => [
    for (final step in _Step.values)
      if (_android || step != _Step.notifications && step != _Step.battery)
        step,
  ];
  _Step get _step => _steps[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.telegram.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_checked) {
      _checked = true;
      if (_android) unawaited(_readPermissions());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _android) {
      unawaited(_readPermissions());
    }
  }

  Future<void> _readPermissions() async {
    try {
      final status = await widget.permissions.status();
      if (mounted) {
        setState(() {
          _notifications = status.notifications;
          _battery = status.battery;
          _permissionError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _permissionError = 'Device settings could not be checked. You can continue and change them later.',
        );
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not finish that action. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _change(VoidCallback action) => unawaited(
    _run(() async {
      action();
      setState(() {});
      await prefs.save();
      widget.player.refreshSettings();
    }),
  );
  Future<void> _finish() => _run(() async {
    final wasComplete = prefs.setupComplete;
    final previousRelease = prefs.lastSeenRelease;
    prefs.setupComplete = true;
    if (!wasComplete) prefs.lastSeenRelease = widget.version;
    try {
      await prefs.save();
    } catch (_) {
      prefs.setupComplete = wasComplete;
      prefs.lastSeenRelease = previousRelease;
      rethrow;
    }
    if (mounted) widget.onFinished();
  });
  void _move(int value) {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _index = value;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _backup() => _run(() async {
    await showDialog<void>(
      context: context,
      builder: (_) => StatsDataDialog(
        player: widget.player,
        telegram: widget.telegram,
        files: widget.files,
        openBackupSection: true,
        onRestored: () async {
          _restored = true;
        },
      ),
    );
  });
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.telegram.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  Widget _switch(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> change,
  ) => Card.filled(
    margin: const EdgeInsets.only(bottom: 8),
    child: SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: _busy ? null : change,
    ),
  );
  Widget _select<T>(
    String label,
    T value,
    List<T> values,
    String Function(T) name,
    ValueChanged<T> change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final item in values)
          DropdownMenuItem(value: item, child: Text(name(item))),
      ],
      onChanged: _busy
          ? null
          : (v) {
              if (v != null) change(v);
            },
    ),
  );
  Widget _button(String label, IconData icon, Future<void> Function() action) =>
      FilledButton.icon(
        onPressed: _busy ? null : () => unawaited(action()),
        icon: Icon(icon),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(label),
        ),
      );

  (String, String, IconData) get _heading => switch (_step) {
    _Step.welcome => (
      'Welcome to\nAuralis',
      'Your channels. Your soundtrack.',
      Icons.headphones_rounded,
    ),
    _Step.telegram => (
      'Your music library',
      'Connect Telegram and choose the channels you listen to.',
      Icons.send_rounded,
    ),
    _Step.notifications => (
      'Playback controls',
      'Keep music controls handy in the notification shade and on your lock screen.',
      Icons.notifications_active_rounded,
    ),
    _Step.backup => (
      'Have a backup?',
      'Restore your Auralis settings, collections and saved account, or start fresh.',
      Icons.upload_file_rounded,
    ),
    _Step.lyrics => (
      'Every word, in sync',
      'Choose automatic lyrics and translation. Originals and timestamps stay intact.',
      Icons.lyrics_rounded,
    ),
    _Step.artwork => (
      'Covers stay with you',
      'Library Refresh saves available artwork and lyrics on this device.',
      Icons.album_rounded,
    ),
    _Step.library => (
      'Library layout',
      'Choose how you move between songs, favorites, playlists and recent music.',
      Icons.library_music_rounded,
    ),
    _Step.navigation => (
      'Make it feel yours',
      'Choose your phone’s navigation style. Desktop keeps its sidebar.',
      Icons.space_dashboard_rounded,
    ),
    _Step.playback => (
      'Settle in and listen',
      'Your music keeps playing while you use other apps.',
      Icons.bedtime_rounded,
    ),
    _Step.battery => (
      'Background playback',
      'If your phone interrupts music, allow unrestricted battery use for Auralis. This is optional.',
      Icons.battery_charging_full_rounded,
    ),
    _Step.finish => (
      'All set!',
      'You’re ready to enjoy your music. Everything here can be changed later in Settings.',
      Icons.check_circle_rounded,
    ),
  };

  Widget _controls() => switch (_step) {
    _Step.welcome => Center(child: Chip(label: Text('v${widget.version}'))),
    _Step.telegram => Column(
      children: [
        Text(
          widget.telegram.ready
              ? '${prefs.selectedChannels.length} channels selected'
              : 'Sign in with your own Telegram account. You can also do this later.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        _button(
          widget.telegram.ready ? 'Choose channels' : 'Connect Telegram',
          Icons.send_rounded,
          () => _run(() async {
            await Navigator.of(context)
                .push<void>(MaterialPageRoute(builder: widget.connectBuilder));
          }),
        ),
      ],
    ),
    _Step.notifications => Column(
      children: [
        if (_permissionError != null)
          Text(_permissionError!, textAlign: TextAlign.center),
        if (_notifications == true)
          const Chip(
            avatar: Icon(Icons.check_rounded),
            label: Text('Notifications enabled'),
          )
        else
          _button(
            'Enable notifications',
            Icons.notifications_rounded,
            () => _run(() async {
              await widget.permissions.notifications();
              await _readPermissions();
            }),
          ),
        const SizedBox(height: 8),
        const Text(
          'Music playback remains available if you skip this.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
    _Step.backup => Column(
      children: [
        _button('Import backup', Icons.file_open_rounded, _backup),
        if (_restored) ...[
          const SizedBox(height: 12),
          const Text('Backup restored.'),
          TextButton(
            onPressed: _busy ? null : _finish,
            child: const Text('Finish with restored settings'),
          ),
        ],
      ],
    ),
    _Step.lyrics => Column(
      children: [
        _switch(
          'Find lyrics automatically',
          'Saved and embedded lyrics come first.',
          prefs.automaticLyrics,
          (v) => _change(() => prefs.automaticLyrics = v),
        ),
        _switch(
          'Translate automatically',
          'Lyric text is sent to your selected translators.',
          prefs.automaticTranslation,
          (v) => _change(() => prefs.automaticTranslation = v),
        ),
        _select<TranslationDirection>(
          'Direction',
          prefs.translationDirection,
          TranslationDirection.values,
          (v) => v.label,
          (v) => _change(() => prefs.translationDirection = v),
        ),
        _select<LyricsSource>(
          'First lyric source',
          prefs.lyricsFirst,
          LyricsSource.values,
          (v) => v.label,
          (v) => _change(() {
            prefs.lyricsFirst = v;
            prefs.lyricsFallback = LyricsSource.values.firstWhere(
              (s) => s != v,
            );
          }),
        ),
        _select<TranslationSource>(
          'First translator',
          prefs.translationFirst,
          TranslationSource.values,
          (v) => v.label,
          (v) => _change(() {
            prefs.translationFirst = v;
            prefs.translationFallback = TranslationSource.values.firstWhere(
              (s) => s != v,
            );
          }),
        ),
        const Text(
          'The other provider is the fallback. Customize or disable fallbacks in Settings → Lyrics & artwork → Lyrics & translation.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
    _Step.artwork => const Text(
      'Covers are saved automatically on this device. Use Library Refresh to save available artwork and lyrics. Music files remain temporary.',
      textAlign: TextAlign.center,
    ),
    _Step.library => Column(
      children: [
        Card.filled(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Library',
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(color: colors.primary),
                ),
                const SizedBox(height: 16),
                prefs.compactLibrary
                    ? const Chip(
                        avatar: Icon(Icons.music_note_rounded),
                        label: Text('All songs  ▾'),
                      )
                    : const Wrap(
                        spacing: 8,
                        children: [
                          Chip(label: Text('All songs')),
                          Chip(label: Text('Favorites')),
                          Chip(label: Text('Playlists')),
                        ],
                      ),
              ],
            ),
          ),
        ),
        _switch(
          'Compact mode',
          'Use a single collection menu.',
          prefs.compactLibrary,
          (v) => _change(() => prefs.compactLibrary = v),
        ),
      ],
    ),
    _Step.navigation => Column(
      children: [
        ExcludeSemantics(
          child: IgnorePointer(
            child: AppNavigation(
              style: prefs.navigationStyle,
              radius: prefs.navigationRadius,
              selected: 0,
              onSelected: (_) {},
              onSearch: () {},
            ),
          ),
        ),
        for (final style in AppNavigationStyle.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: prefs.navigationStyle == style
                  ? colors.primaryContainer
                  : colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: Text(style.label),
                subtitle: Text(switch (style) {
                  AppNavigationStyle.expressive =>
                    'Floating pill with a separate search button.',
                  AppNavigationStyle.classic => 'A compact row of icons.',
                  AppNavigationStyle.fullWidth =>
                    'Labels across the bottom of the screen.',
                }),
                selected: prefs.navigationStyle == style,
                trailing: Icon(
                  prefs.navigationStyle == style
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                onTap: _busy
                    ? null
                    : () => _change(() => prefs.navigationStyle = style),
              ),
            ),
          ),
        if (prefs.navigationStyle != AppNavigationStyle.fullWidth) ...[
          const Text('Corner radius'),
          Slider(
            value: prefs.navigationRadius,
            min: 0,
            max: 40,
            divisions: 8,
            label: prefs.navigationRadius.round().toString(),
            onChanged: _busy
                ? null
                : (v) {
                    setState(() => prefs.navigationRadius = v);
                  },
            onChangeEnd: (_) => _change(() {}),
          ),
        ],
      ],
    ),
    _Step.playback => const Column(
      children: [
        ListTile(
          leading: Icon(Icons.bedtime_rounded),
          title: Text('Wind down with a sleep timer'),
          subtitle: Text(
            'Open the clock control in Now Playing to stop after a duration or at the end of a song.',
          ),
        ),
        ListTile(
          leading: Icon(Icons.volume_up_rounded),
          title: Text('Volume, your way'),
          subtitle: Text(
            'Use your phone’s volume buttons, or ↑ / ↓ on desktop.',
          ),
        ),
      ],
    ),
    _Step.battery => Column(
      children: [
        if (_permissionError != null)
          Text(_permissionError!, textAlign: TextAlign.center),
        if (_battery == true)
          const Chip(
            avatar: Icon(Icons.check_rounded),
            label: Text('Battery optimization disabled'),
          )
        else
          _button(
            'Open battery settings',
            Icons.battery_4_bar_rounded,
            () => _run(() async {
              await widget.permissions.battery();
              await _readPermissions();
            }),
          ),
        const SizedBox(height: 12),
        const Text(
          'Choose Auralis and allow unrestricted use if needed. You can skip this step.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
    _Step.finish => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) {
    final (title, description, icon) = _heading;
    final isWelcome = _step == _Step.welcome;
    final isLast = _step == _Step.finish;
    return PopScope<Object?>(
      canPop: _index == 0 && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index > 0) _move(_index - 1);
      },
      child: Scaffold(
        key: const ValueKey('setup-page'),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Row(
                  children: [
                    if (_index > 0)
                      IconButton(
                        tooltip: 'Previous setup step',
                        onPressed: _busy ? null : () => _move(_index - 1),
                        icon: const Icon(Icons.arrow_back_rounded),
                      )
                    else
                      const SizedBox(height: 48),
                    const Spacer(),
                    Text(
                      'AURALIS',
                      style: TextStyle(
                        letterSpacing: 3,
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 580),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              title,
                              textAlign: isWelcome
                                  ? TextAlign.left
                                  : TextAlign.center,
                              style: TextStyle(
                                fontSize: isWelcome ? 44 : 30,
                                height: 1.12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                                color: isWelcome
                                    ? colors.primary
                                    : colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              description,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            if (![
                              _Step.navigation,
                              _Step.library,
                              _Step.lyrics,
                            ].contains(_step))
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 20,
                                ),
                                child: SetupIllustration(
                                  icon: icon,
                                  height: box.maxHeight > 580
                                      ? 240
                                      : box.maxHeight > 500
                                      ? 150
                                      : 96,
                                ),
                              ),
                            const SizedBox(height: 16),
                            _controls(),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: colors.error),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            if ([
                              _Step.telegram,
                              _Step.notifications,
                              _Step.backup,
                              _Step.battery,
                            ].contains(_step))
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _move(_index + 1),
                                child: const Text('Skip for now'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Material(
                    color: colors.surfaceContainerHigh,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(32),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isWelcome
                                    ? 'Let’s go!'
                                    : 'Step $_index of ${_steps.length - 1}',
                                style: TextStyle(
                                  fontSize: isWelcome ? 22 : 15,
                                  fontWeight: isWelcome
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isWelcome
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            FilledButton(
                              key: const ValueKey('setup-next'),
                              onPressed: _busy
                                  ? null
                                  : isLast
                                  ? _finish
                                  : () => _move(_index + 1),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(64, 64),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                              ),
                              child: _busy
                                  ? const SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Semantics(
                                      label: isLast
                                          ? 'Finish setup'
                                          : 'Next setup step',
                                      child: Icon(
                                        isLast
                                            ? Icons.check_rounded
                                            : Icons.arrow_forward_rounded,
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
            ],
          ),
        ),
      ),
    );
  }
}

class SetupIllustration extends StatelessWidget {
  const SetupIllustration({
    super.key,
    required this.icon,
    required this.height,
  });
  final IconData icon;
  final double height;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        child: Center(
          child: SizedBox(
            width: math.min(300, MediaQuery.sizeOf(context).width - 72),
            height: height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  right: 12,
                  top: height * .18,
                  child: Transform.rotate(
                    angle: -.35,
                    child: Container(
                      width: height * .54,
                      height: height * .54,
                      decoration: BoxDecoration(
                        color: c.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Icon(
                        Icons.music_note_rounded,
                        size: height * .28,
                        color: c.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Transform.rotate(
                  angle: -.2,
                  child: Container(
                    width: height * .72,
                    height: height * .72,
                    decoration: BoxDecoration(
                      color: c.primaryContainer,
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: Icon(
                      icon,
                      size: height * .42,
                      color: c.onPrimaryContainer,
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  top: 4,
                  child: CircleAvatar(
                    radius: height * .15,
                    backgroundColor: c.surfaceContainerHighest,
                    child: Icon(Icons.favorite_rounded, color: c.primary),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 2,
                  child: CircleAvatar(
                    radius: height * .16,
                    backgroundColor: c.secondaryContainer,
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      color: c.onSecondaryContainer,
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
