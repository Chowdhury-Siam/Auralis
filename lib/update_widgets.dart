import 'package:flutter/material.dart';

import 'updater.dart';

class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key, required this.updater});
  final AppUpdater updater;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updater,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
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
                ? 'At startup and every six hours. Android asks before installation.'
                : 'At startup and every six hours',
          ),
          value: updater.settings.automaticUpdates,
          onChanged: updater.setAutomatic,
        ),
        Text(
          'Installed: ${updater.currentVersion}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(updater.status, style: Theme.of(context).textTheme.bodySmall),
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
            TextButton(
              onPressed:
                  updater.checking || updater.downloading || updater.installing
                  ? null
                  : updater.check,
              child: Text(updater.checking ? 'Checking…' : 'Check now'),
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

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updater});
  final AppUpdater updater;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updater,
    builder: (context, _) {
      if (updater.available == null) return const SizedBox.shrink();
      return Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  updater.downloading
                      ? 'Downloading update… ${(updater.progress * 100).round()}%'
                      : updater.error != null
                      ? 'Update needs attention. Open Settings to retry.'
                      : 'Auralis ${updater.available!.version} is available.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (updater.error == null)
                TextButton(
                  onPressed: updater.downloading || updater.installing
                      ? null
                      : () async {
                          if (updater.downloaded == null) {
                            await updater.download();
                          } else {
                            await confirmUpdate(context, updater);
                          }
                        },
                  child: Text(
                    updater.downloaded == null
                        ? 'Download'
                        : updater.installLabel,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> confirmUpdate(BuildContext context, AppUpdater updater) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        updater.isAndroid
            ? 'Install Android update?'
            : 'Install update and restart?',
      ),
      content: Text(
        updater.isAndroid
            ? 'Version ${updater.available?.version} has passed its SHA-256 checksum check. Android will ask you to confirm installation. If prompted, allow updates from Auralis. Your settings and Telegram session stay on this device.'
            : 'The ${updater.available?.version} installer passed its SHA-256 checksum check. '
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
