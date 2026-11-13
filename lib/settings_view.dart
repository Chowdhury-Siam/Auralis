import 'package:flutter/material.dart';

import 'preference_widgets.dart';

enum SettingsSection {
  general('General', Icons.widgets_rounded),
  appearance('Appearance', Icons.palette_rounded),
  media('Lyrics & artwork', Icons.lyrics_rounded),
  video('Settings & diagnostics', Icons.settings_outlined),
  data('Data & sync', Icons.cloud_sync_rounded),
  privacy('Privacy & security', Icons.lock_rounded),
  updates('App updates', Icons.system_update_alt_rounded),
  about('About', Icons.info_rounded);

  const SettingsSection(this.title, this.icon);
  final String title;
  final IconData icon;
}

class SettingsDirectory extends StatelessWidget {
  const SettingsDirectory({
    super.key,
    required this.sections,
    required this.onSelected,
    required this.bottomPadding,
  });
  final List<SettingsSection> sections;
  final ValueChanged<SettingsSection> onSelected;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      key: const PageStorageKey('settings-directory'),
      padding: EdgeInsets.only(bottom: bottomPadding),
      children: [
        for (var i = 0; i < sections.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Material(
              color: colors.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(i == 0 ? 20 : 6),
                  bottom: Radius.circular(i == sections.length - 1 ? 20 : 6),
                ),
                side: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .35),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: ValueKey('settings-${sections[i].name}'),
                minTileHeight: 56,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                horizontalTitleGap: 12,
                leading: PreferenceIcon(sections[i].icon),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                title: Text(
                  sections[i].title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => onSelected(sections[i]),
              ),
            ),
          ),
      ],
    );
  }
}
