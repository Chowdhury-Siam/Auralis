import 'package:flutter/material.dart';

enum SettingsSection {
  general(
    'General',
    Icons.widgets_outlined,
    'setup welcome volume sleep timer playback',
  ),
  appearance(
    'Appearance',
    Icons.palette_outlined,
    'compact library navigation pill corner radius theme layout',
  ),
  media(
    'Lyrics & artwork',
    Icons.lyrics_outlined,
    'automatic translate translation japanese english google mymemory deepl fallback source provider covers preload cache retain',
  ),
  data(
    'Data & sync',
    Icons.cloud_sync_outlined,
    'listening stats statistics time rankings activity export csv json backup restore recovery account worker devices telegram',
  ),
  privacy(
    'Privacy & security',
    Icons.lock_outline_rounded,
    'credentials encryption keystore dpapi login password logout sign out telegram',
  ),
  updates(
    'App updates',
    Icons.system_update_alt_rounded,
    'version check automatic download install release',
  ),
  about(
    'About',
    Icons.info_outline_rounded,
    'auralis version licenses licence agpl libmpv tdlib whats new changes',
  );

  const SettingsSection(this.title, this.icon, this.keywords);
  final String title, keywords;
  final IconData icon;
  bool matches(String query) {
    final text = '$title $keywords'.toLowerCase().replaceAll(
      RegExp("['’]"),
      '',
    );
    return query
        .replaceAll(RegExp("['’]"), '')
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .every(text.contains);
  }
}

class SettingsDirectory extends StatelessWidget {
  const SettingsDirectory({
    super.key,
    required this.search,
    required this.sections,
    required this.onSelected,
    required this.bottomPadding,
  });
  final TextEditingController search;
  final List<SettingsSection> sections;
  final ValueChanged<SettingsSection> onSelected;
  final double bottomPadding;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: search,
      builder: (context, value, _) {
        final results = sections
            .where((section) => section.matches(value.text))
            .toList();
        return ListView(
          key: const PageStorageKey('settings-directory'),
          padding: EdgeInsets.only(bottom: bottomPadding),
          children: [
            TextField(
              key: const ValueKey('settings-search'),
              controller: search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              decoration: InputDecoration(
                hintText: 'Search settings…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear settings search',
                        onPressed: search.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                filled: true,
                fillColor: colors.surfaceContainerHigh,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(32),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(32),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (results.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Column(
                  children: [
                    Icon(
                      Icons.search_off_rounded,
                      size: 32,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    const Text('No matching settings'),
                    TextButton(
                      onPressed: search.clear,
                      child: const Text('Show all settings'),
                    ),
                  ],
                ),
              ),
            for (var i = 0; i < results.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Material(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(i == 0 ? 28 : 6),
                    bottom: Radius.circular(i == results.length - 1 ? 28 : 6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: ValueKey('settings-${results[i].name}'),
                    minTileHeight: 62,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    horizontalTitleGap: 18,
                    leading: Icon(
                      results[i].icon,
                      size: 25,
                      color: colors.onSurfaceVariant,
                    ),
                    title: Text(
                      results[i].title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      onSelected(results[i]);
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
