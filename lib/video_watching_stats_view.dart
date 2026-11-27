import 'package:flutter/material.dart';

import 'listening.dart' show listeningTime;
import 'player.dart';
import 'stats_view.dart';
import 'video_playback_data.dart';

class WatchingStatsPage extends StatelessWidget {
  const WatchingStatsPage({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) => StatsPage(
    title: 'Watching stats',
    close: IconButton(
      tooltip: 'Close',
      onPressed: () => Navigator.pop(context),
      icon: const Icon(Icons.close_rounded, size: 20),
    ),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: ListenableBuilder(
        listenable: player.viewChanges,
        builder: (context, _) {
          final data = player.settings.videoPlayback;
          final watchTime = data.watchTime.inMilliseconds;
          return LayoutBuilder(
            builder: (context, box) {
              final largeText = MediaQuery.textScalerOf(context).scale(16) > 22;
              final overview = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatsMetricCard(
                    label: 'Watch time',
                    value: listeningTime(watchTime),
                    icon: Icons.schedule_rounded,
                    highlighted: true,
                  ),
                  const SizedBox(height: 10),
                  if (box.maxWidth < 280 || largeText) ...[
                    _plays(data),
                    const SizedBox(height: 10),
                    _watched(data),
                  ] else
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _plays(data)),
                          const SizedBox(width: 10),
                          Expanded(child: _watched(data)),
                        ],
                      ),
                    ),
                ],
              );
              final breakdown = _WatchingBreakdown(
                data: data,
                totalMilliseconds: watchTime,
              );
              return box.maxWidth >= 730 && !largeText
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: overview),
                        const SizedBox(width: 16),
                        Expanded(child: breakdown),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        overview,
                        const SizedBox(height: 16),
                        breakdown,
                      ],
                    );
            },
          );
        },
      ),
    ),
  );

  Widget _plays(VideoPlaybackData data) => StatsMetricCard(
    label: 'Video plays',
    value: '${data.videoPlays}',
    icon: Icons.play_circle_outline_rounded,
    secondary: true,
  );

  Widget _watched(VideoPlaybackData data) => StatsMetricCard(
    label: 'Videos marked watched',
    value: '${data.watchedCount}',
    icon: Icons.check_circle_outline_rounded,
  );
}

class _WatchingBreakdown extends StatelessWidget {
  const _WatchingBreakdown({
    required this.data,
    required this.totalMilliseconds,
  });

  final VideoPlaybackData data;
  final int totalMilliseconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return StatsPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Watching activity',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'All time',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (totalMilliseconds == 0 && data.videoPlays == 0) ...[
            const SizedBox(height: 16),
            const Text('Watch a video to start tracking your activity.'),
          ] else
            for (final (telegram, label, icon, accent) in [
              (true, 'Telegram', Icons.telegram, colors.primary),
              (false, 'On device', Icons.devices_rounded, colors.tertiary),
            ])
              _source(context, telegram, label, icon, accent),
        ],
      ),
    );
  }

  Widget _source(
    BuildContext context,
    bool telegram,
    String label,
    IconData icon,
    Color accent,
  ) {
    final theme = Theme.of(context);
    final (:milliseconds, :plays) = data.watchingTotals(telegram: telegram);
    final time = listeningTime(milliseconds);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: accent),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: LinearProgressIndicator(
              value: totalMilliseconds == 0
                  ? 0
                  : milliseconds / totalMilliseconds,
              minHeight: 5,
              borderRadius: BorderRadius.circular(8),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: accent,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '$time · $plays ${plays == 1 ? 'play' : 'plays'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
