import 'package:flutter/material.dart';

import 'listening.dart' show listeningTime;
import 'player.dart';
import 'preference_widgets.dart';

class WatchingStatsPage extends StatelessWidget {
  const WatchingStatsPage({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Watching stats')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListenableBuilder(
            listenable: player.viewChanges,
            builder: (context, _) {
              final data = player.settings.videoPlayback;
              final metrics = [
                (
                  'Watch time on this device',
                  listeningTime(data.watchTime.inMilliseconds),
                  Icons.schedule_rounded,
                ),
                (
                  'Video plays on this device',
                  '${data.videoPlays}',
                  Icons.play_arrow_rounded,
                ),
                (
                  'Videos marked watched',
                  '${data.watchedCount}',
                  Icons.check_circle_outline_rounded,
                ),
              ];
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final (label, value, icon) in metrics)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: PreferenceCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PreferenceIcon(icon),
                          title: Text(label),
                          subtitle: Text(
                            value,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
