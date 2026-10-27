import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'listening.dart';
import 'models.dart';
import 'storage.dart';

class DataBackup {
  DataBackup._(this.snapshot, this.createdAt);
  final Map<String, dynamic> snapshot;
  final DateTime createdAt;
  static const maxBytes = 64 * 1024 * 1024;

  static DataBackup create(AppSettings settings, DateTime now) => DataBackup._(
    jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    now.toUtc(),
  );

  String encode() {
    final digest = sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'auralis-backup',
      'version': 1,
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
        json['version'] != 1) {
      throw const FormatException(
        'Choose a supported Auralis backup (version 1).',
      );
    }
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
    _validate(snapshot);
    return DataBackup._(snapshot, created);
  }

  static void _validate(Map<String, dynamic> data) {
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

    ids(data['favoriteIds'], 10000);
    ids(data['recentIds'], 100);
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
    if (data['listening'] == null) {
      throw const FormatException('Listening statistics are missing.');
    }
    ListeningStats.fromJson(data['listening']);
    // Keep the restore scope explicit: never restore arbitrary settings/paths/secrets.
    const allowed = {
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
      'favoriteIds',
      'playlists',
      'recentIds',
      'selectedChannels',
      'listening',
    };
    if (data.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Backup contains unsupported app data.');
    }
  }

  static void validateSnapshot(Map<String, dynamic> data) => _validate(data);
}
