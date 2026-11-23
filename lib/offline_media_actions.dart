import 'package:flutter/material.dart';

import 'media_item_sheet.dart';
import 'models.dart';
import 'telegram/telegram_service.dart';

MediaItemAction? offlineMediaAction(
  TelegramService telegram,
  Track track, {
  required bool video,
}) {
  if (telegram.offline.contains(track.id, video: video)) {
    return const MediaItemAction(
      'offline',
      'Remove offline copy',
      Icons.download_done_rounded,
    );
  }
  if (telegram.offline.saving(track.id, video: video)) {
    return const MediaItemAction(
      'offline',
      'Saving for offline…',
      Icons.downloading_rounded,
    );
  }
  if (telegram.ready && (video || track.fileId != null)) {
    return const MediaItemAction(
      'offline',
      'Save for offline',
      Icons.download_rounded,
    );
  }
  return null;
}

Future<void> changeOfflineMedia(
  BuildContext context,
  TelegramService telegram,
  Track track, {
  required bool video,
}) async {
  if (telegram.offline.saving(track.id, video: video)) return;
  final removing = telegram.offline.contains(track.id, video: video);
  void notice(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  try {
    if (removing) {
      await telegram.offline.remove(track.id, video: video);
      notice('Offline copy removed');
    } else {
      notice('Saving for offline. The download may wait for active playback.');
      await telegram.saveOffline(track, video: video);
      notice('Saved for offline');
    }
  } on StateError catch (error) {
    notice(error.message);
  } catch (_) {
    notice(
      removing ? 'Could not remove the offline copy.' : 'Could not save for offline. Check your connection and available storage.',
    );
  }
}
