import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'storage.dart';

const currentReleaseVersion = '0.1.93';
Future<void> showReleaseChanges(
  BuildContext context,
  String version,
  String notes,
) => showDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    title: Text('What’s new in $version'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(child: SelectableText(notes)),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
    ],
  ),
);
Future<void> showInstalledChanges(BuildContext context, String version) async {
  String notes;
  try {
    final data = jsonDecode(
      await rootBundle.loadString('assets/release-notes.json'),
    ) as Map;
    final releases = (data['releases'] as List).cast<Map>();
    final match = releases.where((r) => r['version'] == version);
    notes = match.isEmpty
        ? 'Release notes are unavailable for this version.'
        : (match.first['changes'] as List)
              .map((line) => '• $line')
              .join('\n\n');
  } catch (_) {
    notes = 'Release notes could not be loaded. Please try again.';
  }
  if (context.mounted) await showReleaseChanges(context, version, notes);
}

Future<void> maybeShowWhatsNew(
  BuildContext context,
  AppSettings settings,
  String version,
) async {
  if (settings.lastSeenRelease == version) return;
  await showInstalledChanges(context, version);
  if (!context.mounted) return;
  settings.lastSeenRelease = version;
  try {
    await settings.save();
  } catch (_) {
    /* Retry the notice next launch if storage failed. */
  }
}
