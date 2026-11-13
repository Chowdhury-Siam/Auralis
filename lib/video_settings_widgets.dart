import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Video-only dialog surface. Long forms and their heading scroll together,
/// while actions remain reachable above a phone keyboard.
class VideoSettingsDialog extends StatefulWidget {
  const VideoSettingsDialog({
    super.key,
    required this.title,
    required this.icon,
    required this.content,
    this.description,
    this.actions = const [],
    this.width = 640,
  });

  final String title;
  final String? description;
  final IconData icon;
  final Widget content;
  final List<Widget> actions;
  final double width;

  @override
  State<VideoSettingsDialog> createState() => _VideoSettingsDialogState();
}

class _VideoSettingsDialogState extends State<VideoSettingsDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title, description = widget.description;
    final icon = widget.icon, content = widget.content;
    final actions = widget.actions, width = widget.width;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final media = MediaQuery.of(context);
    final available = math.max(
      80.0,
      media.size.height -
          media.viewInsets.vertical -
          media.padding.vertical -
          32,
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      backgroundColor: colors.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .45)),
      ),
      constraints: BoxConstraints(maxWidth: width, maxHeight: available),
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                radius: const Radius.circular(8),
                child: SingleChildScrollView(
                  controller: _scroll,
                  key: ValueKey('video-settings-dialog-$title'),
                  primary: false,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          VideoSettingsIcon(icon: icon),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    title,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (description != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    description,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close settings dialog',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      content,
                    ],
                  ),
                ),
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 8,
                  overflowSpacing: 8,
                  children: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class VideoSettingsIcon extends StatelessWidget {
  const VideoSettingsIcon({super.key, required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Icon(icon, size: 23, color: colors.onPrimaryContainer),
    );
  }
}

class VideoSettingsGroup extends StatelessWidget {
  const VideoSettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.description,
  });
  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(
                  description!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class VideoSettingsAction extends StatelessWidget {
  const VideoSettingsAction({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });
  final String title, description;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: false,
        enabled: onTap != null,
        minTileHeight: 112,
        contentPadding: const EdgeInsets.all(16),
        horizontalTitleGap: 14,
        leading: VideoSettingsIcon(icon: icon),
        title: Text(title),
        titleTextStyle: theme.textTheme.titleMedium?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(description),
        ),
        subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
          height: 1.4,
        ),
        trailing: Icon(
          Icons.arrow_forward_rounded,
          size: 19,
          color: colors.primary,
        ),
        onTap: onTap,
      ),
    );
  }
}
