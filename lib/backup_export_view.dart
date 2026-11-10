import 'package:flutter/material.dart';

import 'data_backup.dart';

class BackupExportPage extends StatefulWidget {
  const BackupExportPage({
    super.key,
    required this.showTelegram,
    required this.telegramAvailable,
    required this.onExport,
  });

  final bool showTelegram, telegramAvailable;
  final Future<({bool saved, String? error})> Function(
    Set<BackupSection> sections,
    bool includeTelegram,
  )
  onExport;

  @override
  State<BackupExportPage> createState() => _BackupExportPageState();
}

class _BackupExportPageState extends State<BackupExportPage> {
  final _sections = BackupSection.values.toSet();
  late bool _includeTelegram = widget.telegramAvailable;
  bool _busy = false;
  String? _error;

  int get _selected => _sections.length + (_includeTelegram ? 1 : 0);
  int get _available =>
      BackupSection.values.length + (widget.telegramAvailable ? 1 : 0);

  void _selectAll(bool selected) => setState(() {
    _sections.clear();
    if (selected) _sections.addAll(BackupSection.values);
    _includeTelegram = selected && widget.telegramAvailable;
    _error = null;
  });

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.onExport(Set.of(_sections), _includeTelegram);
    if (!mounted) return;
    if (result.saved) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = result.error;
      });
    }
  }

  Widget _section({
    required IconData icon,
    required String title,
    required String description,
    required bool selected,
    required ValueChanged<bool>? onChanged,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
        width: selected ? 2 : 1,
      ),
    );
    return Material(
      color: colors.surfaceContainerLow,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        value: selected,
        onChanged: _busy ? null : onChanged,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Icon(Icons.check_rounded, size: 17)
              : null,
        ),
        secondary: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: selected
                ? colors.secondaryContainer
                : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(
            icon,
            size: 22,
            color: selected
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant,
          ),
        ),
        title: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(description),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope<void>(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: colors.surfaceContainer,
          centerTitle: true,
          toolbarHeight: 64,
          leading: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: Center(
              child: IconButton.filledTonal(
                tooltip: 'Close export',
                onPressed: _busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
          title: Text(
            'Export Backup',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  Card.filled(
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Choose what to include in your backup.'),
                          const SizedBox(height: 6),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              '$_selected of $_available sections selected',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final section in BackupSection.values) ...[
                    _section(
                      icon: switch (section) {
                        BackupSection.playlists => Icons.playlist_play_rounded,
                        BackupSection.preferences => Icons.settings_outlined,
                        BackupSection.favorites =>
                          Icons.favorite_border_rounded,
                        BackupSection.recent => Icons.history_rounded,
                        BackupSection.listening => Icons.insights_rounded,
                        BackupSection.channels => Icons.campaign_outlined,
                      },
                      title: section.label,
                      description: section.description,
                      selected: _sections.contains(section),
                      onChanged: (selected) => setState(() {
                        if (selected) {
                          _sections.add(section);
                        } else {
                          _sections.remove(section);
                        }
                      }),
                    ),
                    const SizedBox(height: 9),
                  ],
                  if (widget.showTelegram)
                    _section(
                      icon: Icons.lock_outline_rounded,
                      title: 'Include Telegram account',
                      description: widget.telegramAvailable
                          ? 'Adds your sign-in in a password-protected backup. Playback briefly pauses.'
                          : 'Connect Telegram to include your sign-in.',
                      selected: _includeTelegram,
                      onChanged: widget.telegramAvailable
                          ? (selected) =>
                                setState(() => _includeTelegram = selected)
                          : null,
                    ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: Material(
          color: colors.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.center,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_busy && ModalRoute.isCurrentOf(context) == true)
                        const LinearProgressIndicator(),
                      if (_error case final error?)
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
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton.filledTonal(
                                tooltip: 'Select all',
                                onPressed: _busy || _selected == _available
                                    ? null
                                    : () => _selectAll(true),
                                icon: const Icon(Icons.select_all_rounded),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: 'Deselect all',
                                onPressed: _busy || _selected == 0
                                    ? null
                                    : () => _selectAll(false),
                                icon: const Icon(Icons.deselect_rounded),
                              ),
                            ],
                          ),
                          FilledButton.icon(
                            key: const ValueKey('export-backup-submit'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 50),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                            ),
                            onPressed: _busy || _selected == 0 ? null : _export,
                            icon: const Icon(Icons.save_rounded),
                            label: const Text('Export Backup'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
