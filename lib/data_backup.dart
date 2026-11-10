import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'listening.dart';
import 'models.dart';
import 'storage.dart';

enum BackupSection {
  playlists('Playlists', 'Your custom playlists and track order.', {
    'playlists',
  }),
  preferences(
    'App preferences',
    'Playback, navigation, lyrics and other app settings.',
    {
      'compactLibrary',
      'navigationStyle',
      'navigationRadius',
      'reducedMotion',
      'automaticUpdates',
      'volume',
      'automaticLyrics',
      'automaticTranslation',
      'keepArtwork',
      'artworkPreload',
      'lyricsFirst',
      'lyricsFallback',
      'translationFirst',
      'translationFallback',
      'translationDirection',
      'librarySort',
      'repeatMode',
    },
  ),
  favorites('Favorites', 'Tracks you marked as favorites.', {'favoriteIds'}),
  recent('Recently played', 'Your recent listening history.', {'recentIds'}),
  listening('Listening stats', 'Listening time, play counts and rankings.', {
    'listening',
  }),
  channels('Telegram channels', 'The channels selected for your library.', {
    'selectedChannels',
  });

  const BackupSection(this.label, this.description, this.keys);

  final String label, description;
  final Set<String> keys;

  bool isIn(Map<String, dynamic> data) => keys.any(data.containsKey);
}

class DataBackup {
  DataBackup._(this.snapshot, this.createdAt, this._version);
  final Map<String, dynamic> snapshot;
  final DateTime createdAt;
  final int _version;
  bool get isPartial => _version == 2;
  Iterable<BackupSection> get sections =>
      BackupSection.values.where((section) => section.isIn(snapshot));
  static const maxBytes = 64 * 1024 * 1024;

  static DataBackup create(
    AppSettings settings,
    DateTime now, {
    Set<BackupSection>? sections,
  }) {
    final data = settings.toJson();
    final partial =
        sections != null && sections.length != BackupSection.values.length;
    final snapshot = partial
        ? {
            for (final section in sections)
              for (final key in section.keys)
                if (data.containsKey(key)) key: data[key],
          }
        : data;
    return DataBackup._(
      jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>,
      now.toUtc(),
      partial ? 2 : 1,
    );
  }

  String encode() {
    final digest = sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'auralis-backup',
      'version': _version,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'data': snapshot,
      'sha256': digest,
    });
  }

  static DataBackup parse(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('Backup exceeds 64 MiB.');
    }
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> ||
        json['format'] != 'auralis-backup' ||
        json['version'] is! int ||
        (json['version'] != 1 && json['version'] != 2)) {
      throw const FormatException('Choose a supported Auralis backup.');
    }
    final version = json['version'] as int;
    final snapshot = json['data'];
    final stamp = json['createdAt'];
    final created = stamp is String ? DateTime.tryParse(stamp) : null;
    if (snapshot is! Map<String, dynamic> ||
        created == null ||
        json['sha256'] is! String) {
      throw const FormatException('Incomplete backup.');
    }
    if (sha256.convert(utf8.encode(jsonEncode(snapshot))).toString() !=
        json['sha256']) {
      throw const FormatException(
        'Backup integrity check failed. The file may be damaged.',
      );
    }
    _validate(snapshot, partial: version == 2);
    return DataBackup._(snapshot, created, version);
  }

  static void _validatePreferences(Map<String, dynamic> data) {
    if (data['reducedMotion'] is! bool || data['automaticUpdates'] is! bool) {
      throw const FormatException('Invalid preferences.');
    }
    final volume = data['volume'];
    if (volume is! num || !volume.isFinite || volume < 0 || volume > 100) {
      throw const FormatException('Invalid volume preference.');
    }
    if (!LibrarySort.values.any((v) => v.name == data['librarySort']) ||
        !PlaybackRepeat.values.any((v) => v.name == data['repeatMode'])) {
      throw const FormatException('Invalid playback preferences.');
    }
    for (final name in [
      'automaticLyrics',
      'automaticTranslation',
      'keepArtwork',
      'compactLibrary',
    ]) {
      if (data.containsKey(name) && data[name] is! bool) {
        throw const FormatException('Invalid media preference.');
      }
    }
    if (data.containsKey('artworkPreload') &&
        (data['artworkPreload'] is! int ||
            (data['artworkPreload'] as int) < 0 ||
            (data['artworkPreload'] as int) > 50)) {
      throw const FormatException('Invalid artwork preload count.');
    }
    if ((data.containsKey('navigationStyle') &&
            !AppNavigationStyle.values.any(
              (v) => v.name == data['navigationStyle'],
            )) ||
        (data.containsKey('navigationRadius') &&
            (data['navigationRadius'] is! num ||
                !(data['navigationRadius'] as num).isFinite ||
                (data['navigationRadius'] as num) < 0 ||
                (data['navigationRadius'] as num) > 40))) {
      throw const FormatException('Invalid navigation preferences.');
    }
    for (final (first, fallback, values) in [
      (
        'lyricsFirst',
        'lyricsFallback',
        LyricsSource.values.map((v) => v.name).toSet(),
      ),
      (
        'translationFirst',
        'translationFallback',
        TranslationSource.values.map((v) => v.name).toSet(),
      ),
    ]) {
      if ((data.containsKey(first) && !values.contains(data[first])) ||
          (data[fallback] != null && !values.contains(data[fallback])) ||
          (data[first] != null && data[first] == data[fallback])) {
        throw const FormatException('Invalid provider order.');
      }
    }
    if (data.containsKey('translationDirection') &&
        !TranslationDirection.values.any(
          (v) => v.name == data['translationDirection'],
        )) {
      throw const FormatException('Invalid translation direction.');
    }
  }

  static final _allowed = {
    for (final section in BackupSection.values) ...section.keys,
  };

  static void _validate(Map<String, dynamic> data, {bool partial = false}) {
    if (data.keys.any((key) => !_allowed.contains(key))) {
      throw const FormatException('Backup contains unsupported app data.');
    }
    if (!partial || BackupSection.preferences.isIn(data)) {
      _validatePreferences(data);
    }

    void ids(Object? value, int maximum) {
      if (value is! List || value.length > maximum) {
        throw const FormatException('Invalid collection size.');
      }
      final seen = <String>{};
      for (final id in value) {
        if (!seen.add(dataText(id, maximum: 200, empty: false))) {
          throw const FormatException('Duplicate collection entry.');
        }
      }
    }

    if (!partial || data.containsKey('favoriteIds')) {
      ids(data['favoriteIds'], 10000);
    }
    if (!partial || data.containsKey('recentIds')) {
      ids(data['recentIds'], 100);
    }
    if (!partial || data.containsKey('playlists')) {
      final playlists = data['playlists'];
      if (playlists is! Map || playlists.length > 100) {
        throw const FormatException('Invalid playlists.');
      }
      final names = <String>{};
      for (final entry in playlists.entries) {
        final name = dataText(entry.key, maximum: 60, empty: false);
        if (name.trim() != name || !names.add(name.toLowerCase())) {
          throw const FormatException('Invalid playlist name.');
        }
        ids(entry.value, 5000);
      }
    }
    if (!partial || data.containsKey('selectedChannels')) {
      final channels = data['selectedChannels'];
      if (channels is! List || channels.length > 1000) {
        throw const FormatException('Invalid channel preferences.');
      }
      final channelIds = <int>{};
      for (final channel in channels) {
        if (channel is! Map ||
            channel['id'] is! int ||
            !channelIds.add(channel['id'] as int)) {
          throw const FormatException('Invalid channel reference.');
        }
        dataText(channel['title']);
      }
    }
    if (!partial || data.containsKey('listening')) {
      if (data['listening'] == null) {
        throw const FormatException('Listening statistics are missing.');
      }
      ListeningStats.fromJson(data['listening']);
    }
  }

  static void validateSnapshot(Map<String, dynamic> data) => _validate(data);
}
