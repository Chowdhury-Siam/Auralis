import 'dart:async';

import 'package:flutter/material.dart';

import 'app_popups.dart';

import 'app_navigation.dart';
import 'data_files.dart';
import 'models.dart';
import 'player.dart';
import 'preference_widgets.dart';
import 'setup_permissions.dart';
import 'stats_view.dart';
import 'storage.dart';
import 'sync/controller.dart';
import 'sync/settings_view.dart';
import 'telegram/telegram_service.dart';

enum _Step {
  welcome,
  telegram,
  notifications,
  backup,
  lyrics,
  artwork,
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
    this.sync,
    this.files = const DataFiles(),
    this.permissions = const SetupPermissions(),
  });
  final PlayerController player;
  final TelegramService telegram;
  final String version;
  final WidgetBuilder connectBuilder;
  final VoidCallback onFinished;
  final SyncController? sync;
  final DataFiles files;
  final SetupPermissions permissions;
  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> with WidgetsBindingObserver {
  int _index = 0;
  int _previewDestination = 0;
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
    await showAuralisDialog<void>(
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

  Future<void> _openSync(SyncController sync, SyncAccountEntry entry) =>
      _run(() async {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => SyncAccountPage(sync: sync, entry: entry),
          ),
        );
      });

  Widget _syncCard(SyncController sync) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      final account = sync.signedIn ? sync.account : null;
      final disabled = _busy || sync.busy;
      return Card.filled(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PreferenceIcon(
                  account == null
                      ? Icons.cloud_sync_rounded
                      : Icons.cloud_done_rounded,
                ),
                title: Text(
                  account == null ? 'Worker Sync' : 'Worker connected',
                ),
                subtitle: Text(
                  account == null
                      ? 'Sync favorites, playlists and listening history across devices.'
                      : '${account.username} · ${sync.status}',
                ),
              ),
              const SizedBox(height: 8),
              if (account == null) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('setup-sync-sign-in'),
                      onPressed: disabled
                          ? null
                          : () => _openSync(sync, SyncAccountEntry.signIn),
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('Sign in'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('setup-sync-register'),
                      onPressed: disabled
                          ? null
                          : () => _openSync(sync, SyncAccountEntry.register),
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Create account'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Optional. Connect anytime in Settings → Account & sync.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ] else
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: disabled
                        ? null
                        : () => _openSync(sync, SyncAccountEntry.settings),
                    child: const Text('Manage account'),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
        ChoiceMenu<T>(
          key: ValueKey('setup-choice-$label'),
          title: label,
          value: value,
          values: values,
          label: name,
          enabled: !_busy,
          onSelected: change,
        ),
      ],
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
      Icons.graphic_eq_rounded,
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
      'Auralis caches covers automatically. Use Library Refresh to save available artwork and lyrics ahead of time.',
      Icons.album_rounded,
    ),
    _Step.navigation => (
      'Make it feel yours',
      'Try a compact navigation style. Wider windows use a sidebar.',
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
      'Open your library whenever you’re ready. You can revisit setup in Settings.',
      Icons.check_circle_rounded,
    ),
  };

  Widget _controls() => switch (_step) {
    _Step.welcome => Column(
      children: [
        DefaultInterfacePreference(
          value: prefs.defaultInterface,
          onSelected: (mode) => _change(() => prefs.defaultInterface = mode),
        ),
        const SizedBox(height: 12),
        switch (widget.sync) {
          final SyncController sync => _syncCard(sync),
          null => const SizedBox.shrink(),
        },
      ],
    ),
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
      'Streamed music stays in temporary storage.',
      textAlign: TextAlign.center,
    ),
    _Step.navigation => Column(
      children: [
        Card.filled(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Text(
                  'Preview · ${AppNavigation.labels[_previewDestination]}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              AppNavigation(
                style: prefs.navigationStyle,
                radius: prefs.navigationRadius,
                reducedMotion: prefs.reducedMotion,
                selected: _previewDestination,
                onSelected: (value) =>
                    setState(() => _previewDestination = value),
              ),
            ],
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
                    'Floating bar with labeled tabs.',
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

  Widget _hero() {
    final (title, description, icon) = _heading;
    final welcome = _step == _Step.welcome;
    final text = Theme.of(context).textTheme;
    final foreground = welcome ? colors.onPrimaryContainer : colors.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: welcome ? colors.primaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            if (welcome)
              PositionedDirectional(
                end: -28,
                bottom: -44,
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.album_outlined,
                    size: 184,
                    color: foreground.withValues(alpha: .12),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.all(welcome ? 24 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: welcome
                            ? colors.primary
                            : colors.primaryContainer,
                        borderRadius: BorderRadius.circular(welcome ? 18 : 14),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(welcome ? 12 : 8),
                        child: Icon(
                          icon,
                          size: welcome ? 28 : 22,
                          color: welcome
                              ? colors.onPrimary
                              : colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: welcome ? 14 : 10),
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: (welcome ? text.displaySmall : text.headlineSmall)
                          ?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: text.bodyMedium?.copyWith(
                      color: welcome ? foreground : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWelcome = _step == _Step.welcome;
    final isLast = _step == _Step.finish;
    final canSkipStep = switch (_step) {
      _Step.telegram => !widget.telegram.ready,
      _Step.notifications => _notifications != true,
      _Step.backup => !_restored,
      _Step.battery => _battery != true,
      _ => false,
    };
    final nextLabel = isWelcome
        ? 'Customize setup'
        : isLast
        ? 'Finish setup'
        : canSkipStep
        ? 'Skip step'
        : 'Continue';
    final reduceMotion =
        prefs.reducedMotion || MediaQuery.disableAnimationsOf(context);
    final stepCount = _steps.length - 1;

    return PopScope<Object?>(
      canPop: _index == 0 && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index > 0) _move(_index - 1);
      },
      child: Scaffold(
        key: const ValueKey('setup-page'),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Row(
                      children: [
                        if (!isWelcome)
                          IconButton(
                            tooltip: 'Previous setup step',
                            onPressed: _busy ? null : () => _move(_index - 1),
                            icon: const Icon(Icons.arrow_back_rounded),
                          )
                        else
                          const SizedBox(height: 48),
                        Expanded(
                          child: Text(
                            isWelcome
                                ? 'AURALIS'
                                : 'Step $_index of $stepCount',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  letterSpacing: isWelcome ? 3 : 0,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            isWelcome ? 'v${widget.version}' : 'Optional setup',
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!isWelcome)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: LinearProgressIndicator(
                        value: _index / stepCount,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(4),
                        semanticsLabel: 'Setup progress',
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (box.maxHeight - 28)
                                .clamp(0, 1200)
                                .toDouble(),
                          ),
                          child: Center(
                            child: AnimatedSwitcher(
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 180),
                              switchInCurve: Curves.easeOutCubic,
                              layoutBuilder: (current, _) =>
                                  current ?? const SizedBox.shrink(),
                              child: Column(
                                key: ValueKey(_step),
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _hero(),
                                  if (!isLast) ...[
                                    const SizedBox(height: 14),
                                    _controls(),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Material(
                    color: colors.surfaceContainerLow,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_error case final String error)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  error,
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                            ),
                          Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (!isLast)
                                TextButton(
                                  key: const ValueKey('setup-skip'),
                                  onPressed: _busy ? null : _finish,
                                  child: Text(
                                    isWelcome
                                        ? 'Skip setup'
                                        : 'Skip remaining steps',
                                  ),
                                ),
                              FilledButton.icon(
                                key: const ValueKey('setup-next'),
                                onPressed: _busy
                                    ? null
                                    : isLast
                                    ? _finish
                                    : () => _move(_index + 1),
                                icon: _busy
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        isLast
                                            ? Icons.check_rounded
                                            : Icons.arrow_forward_rounded,
                                      ),
                                label: Text(nextLabel),
                              ),
                            ],
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
      ),
    );
  }
}
