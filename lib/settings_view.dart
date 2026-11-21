import 'package:flutter/material.dart';

import 'preference_widgets.dart';

enum SettingsSection {
  general('General', Icons.widgets_rounded),
  appearance('Appearance', Icons.palette_rounded),
  media('Lyrics & artwork', Icons.lyrics_rounded),
  video('Settings & diagnostics', Icons.settings_outlined),
  data('Data & sync', Icons.cloud_sync_rounded),
  cache('Cache management', Icons.storage_rounded),
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
    return ListView(
      key: const PageStorageKey('settings-directory'),
      padding: EdgeInsets.only(bottom: bottomPadding),
      children: [
        for (var i = 0; i < sections.length; i++)
          SettingsActionTile(
            tileKey: ValueKey('settings-${sections[i].name}'),
            icon: sections[i].icon,
            title: sections[i].title,
            first: i == 0,
            last: i == sections.length - 1,
            onTap: () => onSelected(sections[i]),
          ),
      ],
    );
  }
}
