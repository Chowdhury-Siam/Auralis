import 'package:flutter/material.dart';

import 'app_popups.dart';
import 'models.dart';

class MediaItemAction {
  const MediaItemAction(
    this.id,
    this.label,
    this.icon, {
    this.primary = false,
    this.selected = false,
    this.destructive = false,
  });

  final String id, label;
  final IconData icon;
  final bool primary, selected, destructive;
}

List<(String, String)> mediaItemDetails(Track track, {required bool video}) => [
  ('Mode', video ? 'Video' : 'Music'),
  if (!video && track.artist.isNotEmpty) ('Artist', track.artist),
  if (track.source.isNotEmpty) ('Channel', track.source),
  if (track.duration > Duration.zero) ('Duration', clockText(track.duration)),
  if (track.mime.isNotEmpty && track.mime != 'application/octet-stream')
    ('Format', track.mime),
  if (track.size > 0)
    (
      'File size',
      track.size >= 1024 * 1024
          ? '${(track.size / (1024 * 1024)).toStringAsFixed(1)} MB'
          : track.size >= 1024
          ? '${(track.size / 1024).toStringAsFixed(1)} KB'
          : '${track.size} bytes',
    ),
  if (video && (track.videoWidth ?? 0) > 0 && (track.videoHeight ?? 0) > 0)
    ('Resolution', '${track.videoWidth} × ${track.videoHeight}'),
];

/// Return a choice before running it, so playback and follow-up dialogs never
/// compete with a still-open modal route.
Future<String?> showMediaItemSheet({
  required BuildContext context,
  required String title,
  required String subtitle,
  required Widget artwork,
  required List<MediaItemAction> actions,
  required List<(String, String)> details,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  Widget content(BuildContext context) => _MediaItemSheet(
    title: title,
    subtitle: subtitle,
    artwork: artwork,
    actions: actions,
    details: details,
  );
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showAuralisDialog<String>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * .9,
          ),
          child: content(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    clipBehavior: Clip.antiAlias,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .9,
    ),
    builder: content,
  );
}

class _MediaItemSheet extends StatefulWidget {
  const _MediaItemSheet({
    required this.title,
    required this.subtitle,
    required this.artwork,
    required this.actions,
    required this.details,
  });
  final String title, subtitle;
  final Widget artwork;
  final List<MediaItemAction> actions;
  final List<(String, String)> details;

  @override
  State<_MediaItemSheet> createState() => _MediaItemSheetState();
}

class _MediaItemSheetState extends State<_MediaItemSheet> {
  bool _info = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget tab(String label, IconData icon, bool info) => Expanded(
      child: Material(
        color: _info == info
            ? colors.primaryContainer
            : colors.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => setState(() => _info = info),
          child: Semantics(
            selected: _info == info,
            button: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const ValueKey('media-item-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: SizedBox.square(dimension: 72, child: widget.artwork),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (widget.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close actions',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_info)
              for (final (label, value) in widget.details)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(value),
                    ],
                  ),
                )
            else
              LayoutBuilder(
                builder: (context, box) {
                  final singleColumn =
                      box.maxWidth < 300 ||
                      MediaQuery.textScalerOf(context).scale(14) > 22;
                  final secondaryCount = widget.actions
                      .where((action) => !action.primary)
                      .length;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final (index, action) in widget.actions.indexed)
                        SizedBox(
                          width:
                              action.primary ||
                                  singleColumn ||
                                  (index == widget.actions.length - 1 &&
                                      secondaryCount.isOdd)
                              ? box.maxWidth
                              : (box.maxWidth - 12) / 2,
                          child: FilledButton.icon(
                            key: ValueKey('media-action-${action.id}'),
                            style: FilledButton.styleFrom(
                              backgroundColor: action.destructive
                                  ? colors.errorContainer
                                  : action.primary || action.selected
                                  ? colors.primaryContainer
                                  : colors.secondaryContainer,
                              foregroundColor: action.destructive
                                  ? colors.onErrorContainer
                                  : action.primary || action.selected
                                  ? colors.onPrimaryContainer
                                  : colors.onSecondaryContainer,
                              minimumSize: const Size(0, 64),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                            onPressed: () => Navigator.pop(context, action.id),
                            icon: Icon(action.icon, size: 22),
                            label: Text(
                              action.label,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                tab('Options', Icons.tune_rounded, false),
                const SizedBox(width: 10),
                tab('Info', Icons.info_outline_rounded, true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
