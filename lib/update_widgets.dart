import 'package:flutter/material.dart';

import 'updater.dart';
import 'release_notes.dart';

class UpdateSettings extends StatelessWidget {
  const UpdateSettings({
    super.key,
    required this.updater,
    this.showHeading = true,
  });
  final AppUpdater updater;
  final bool showHeading;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updater,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeading)
          const Text(
            'App updates',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            updater.isAndroid
                ? 'Check and download automatically'
                : 'Check automatically',
          ),
          subtitle: Text(
            updater.isAndroid
                ? 'At startup and every thirty minutes. Tap Install update to install.'
                : 'At startup and every thirty minutes',
          ),
          value: updater.settings.automaticUpdates,
          onChanged: updater.setAutomatic,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                Icons.system_update_alt_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Installed: ${updater.currentVersion}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      updater.status,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (updater.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              updater.error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        if (updater.downloading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(value: updater.progress),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed:
                  updater.checking || updater.downloading || updater.installing
                  ? null
                  : updater.check,
              label: Text(updater.checking ? 'Checking…' : 'Check now'),
            ),
            if (updater.available != null)
              TextButton(
                onPressed: () => showReleaseChanges(
                  context,
                  '${updater.available!.version}',
                  updater.available!.notes.isEmpty
                      ? 'Release notes are not available for this update.'
                      : updater.available!.notes,
                ),
                child: const Text('What changed'),
              ),
            if (updater.available != null && updater.downloaded == null)
              FilledButton.tonal(
                onPressed: updater.downloading || updater.checking
                    ? null
                    : updater.download,
                child: Text(
                  updater.downloading
                      ? 'Downloading…'
                      : 'Download ${updater.available!.version}',
                ),
              ),
            if (updater.downloaded != null)
              FilledButton(
                onPressed: updater.installing || updater.checking
                    ? null
                    : () => confirmUpdate(context, updater),
                child: Text(updater.installLabel),
              ),
          ],
        ),
      ],
    ),
  );
}

class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, required this.updater});
  final AppUpdater updater;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  StableVersion? _dismissedVersion;
  AppUpdater get updater => widget.updater;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updater,
    builder: (context, _) {
      final release = updater.available;
      if (release == null) return const SizedBox.shrink();
      final dismissed = _dismissedVersion;
      if (dismissed != null && release.version.compareTo(dismissed) <= 0) {
        return const SizedBox.shrink();
      }
      final version = release.version.toString();
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final hasError = updater.error != null;
      final ready = updater.downloaded != null;
      final busy =
          updater.checking || updater.downloading || updater.installing;
      final (title, icon) = switch ((
        hasError,
        updater.installing,
        updater.downloading,
        ready,
      )) {
        (true, _, _, _) => (
          'Update needs attention',
          Icons.info_outline_rounded,
        ),
        (_, true, _, _) => (
          'Installing update',
          Icons.system_update_alt_rounded,
        ),
        (_, _, true, _) => ('Downloading update', Icons.download_rounded),
        (_, _, _, true) => ('Update ready', Icons.check_rounded),
        _ => ('Update available', Icons.system_update_alt_rounded),
      };
      final subtitle = hasError
          ? 'Open Settings to retry.'
          : updater.downloading
          ? 'Auralis $version · ${(updater.progress * 100).round()}%'
          : 'Auralis $version';
      final summary = Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: hasError ? colors.errorContainer : colors.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(
                icon,
                size: 20,
                color: hasError
                    ? colors.onErrorContainer
                    : colors.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
      final dismiss = IconButton(
        tooltip: 'Dismiss update notice',
        onPressed: () => setState(() => _dismissedVersion = release.version),
        icon: const Icon(Icons.close_rounded, size: 20),
      );
      final actions = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          TextButton(
            onPressed: () => showReleaseChanges(
              context,
              version,
              release.notes.isEmpty
                  ? 'Release notes are not available for this update.'
                  : release.notes,
            ),
            child: const Text('What changed'),
          ),
          if (!hasError)
            FilledButton(
              onPressed: busy
                  ? null
                  : ready
                  ? () => confirmUpdate(context, updater)
                  : updater.download,
              child: Text(
                ready ? updater.installLabel : 'Download',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );
      return Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            key: const ValueKey('update-card'),
            color: colors.surfaceContainerHigh,
            surfaceTintColor: Colors.transparent,
            elevation: 4,
            shadowColor: Colors.black.withValues(alpha: .30),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide =
                      box.maxWidth >= 520 &&
                      MediaQuery.textScalerOf(context).scale(14) <= 16;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(flex: 2, child: summary),
                          if (wide) ...[
                            const SizedBox(width: 8),
                            Expanded(flex: 3, child: actions),
                          ],
                          dismiss,
                        ],
                      ),
                      if (updater.downloading)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 8, 4, 4),
                          child: LinearProgressIndicator(
                            value: updater.progress,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(4),
                            semanticsLabel: 'Update download progress',
                          ),
                        ),
                      if (!wide)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, right: 4),
                          child: actions,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<void> confirmUpdate(BuildContext context, AppUpdater updater) async {
  if (updater.isAndroid) {
    await updater.install();
    return;
  }
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Install update and restart?'),
      content: Text(
        'The ${updater.available?.version} installer passed its SHA-256 checksum check. '
        'Auralis will close and open the Windows installer. Complete its steps to install and reopen Auralis. Your settings and Telegram session stay on this device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(updater.installLabel),
        ),
      ],
    ),
  );
  if (accepted == true) await updater.install();
}
