import 'package:flutter/material.dart';

enum SettingsSection {
  general(
    'General',
    Icons.widgets_rounded,
    'setup welcome volume sleep timer playback',
  ),
  appearance(
    'Appearance',
    Icons.palette_rounded,
    'compact library navigation pill corner radius theme layout',
  ),
  media(
    'Lyrics & artwork',
    Icons.lyrics_rounded,
    'automatic translate translation japanese english google mymemory deepl fallback source provider covers preload cache retain',
  ),
  data(
    'Data & sync',
    Icons.cloud_sync_rounded,
    'listening stats statistics time rankings activity export csv json backup restore recovery account worker devices telegram',
  ),
  privacy(
    'Privacy & security',
    Icons.lock_rounded,
    'credentials encryption keystore dpapi login password logout sign out telegram',
  ),
  updates(
    'App updates',
    Icons.system_update_alt_rounded,
    'version check automatic download install release',
  ),
  about(
    'About',
    Icons.info_rounded,
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
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
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
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: colors.primary),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
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
                  color: colors.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(i == 0 ? 20 : 6),
                      bottom: Radius.circular(i == results.length - 1 ? 20 : 6),
                    ),
                    side: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: .35),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: ValueKey('settings-${results[i].name}'),
                    minTileHeight: 56,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 2,
                    ),
                    horizontalTitleGap: 12,
                    leading: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        results[i].icon,
                        size: 20,
                        color: colors.primary,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    title: Text(
                      results[i].title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
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
