import 'dart:math' as math;

import 'models.dart';

int dataInteger(Object? value, {int maximum = 9007199254740991}) {
  if (value is! int || value < 0 || value > maximum) {
    throw const FormatException('Invalid numeric value in app data.');
  }
  return value;
}

String dataText(Object? value, {int maximum = 1000, bool empty = true}) {
  if (value is! String || value.length > maximum || (!empty && value.isEmpty)) {
    throw const FormatException('Invalid text in app data.');
  }
  return value;
}

String listeningDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class ListeningTrack {
  ListeningTrack({
    required this.title,
    required this.artist,
    required this.source,
    this.milliseconds = 0,
    this.plays = 0,
    this.lastListened,
  });
  String title, artist, source;
  int milliseconds, plays;
  DateTime? lastListened;

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'source': source,
    'milliseconds': milliseconds,
    'plays': plays,
    'lastListened': lastListened?.toUtc().toIso8601String(),
  };
}

class ListeningDay {
  ListeningDay({this.milliseconds = 0, this.plays = 0});
  int milliseconds, plays;
  Map<String, dynamic> toJson() => {
    'milliseconds': milliseconds,
    'plays': plays,
  };
}

class ListeningStats {
  final tracks = <String, ListeningTrack>{};
  final days = <String, ListeningDay>{};
  int get milliseconds =>
      tracks.values.fold(0, (sum, track) => sum + track.milliseconds);
  int get plays => tracks.values.fold(0, (sum, track) => sum + track.plays);
  List<MapEntry<String, ListeningTrack>> get topTracks =>
      tracks.entries.toList()..sort((a, b) {
        final result = b.value.milliseconds.compareTo(a.value.milliseconds);
        return result == 0 ? a.key.compareTo(b.key) : result;
      });
  List<MapEntry<String, int>> get topArtists {
    final values = <String, int>{};
    for (final track in tracks.values) {
      final name = track.artist.trim().isEmpty
          ? 'Unknown artist'
          : track.artist.trim();
      values.update(
        name,
        (value) => value + track.milliseconds,
        ifAbsent: () => track.milliseconds,
      );
    }
    return values.entries.toList()..sort((a, b) {
      final result = b.value.compareTo(a.value);
      return result == 0 ? a.key.compareTo(b.key) : result;
    });
  }

  /// Uses local calendar days; each short sample can cross midnight.
  void record(Track track, int milliseconds, int plays, DateTime end) {
    if (milliseconds <= 0 && plays == 0) return;
    // Keep captured metadata within the portable backup schema's text bounds.
    String label(String text) =>
        text.length > 1000 ? text.substring(0, 1000) : text;
    final value = tracks.putIfAbsent(
      track.id,
      () => ListeningTrack(
        title: label(track.title),
        artist: label(track.artist),
        source: label(track.source),
      ),
    );
    value.title = label(track.title);
    value.artist = label(track.artist);
    value.source = label(track.source);
    value.milliseconds += milliseconds;
    value.plays += plays;
    value.lastListened = end;
    var cursor = end.subtract(Duration(milliseconds: milliseconds));
    var remaining = milliseconds;
    while (remaining > 0) {
      final midnight = cursor.isUtc
          ? DateTime.utc(cursor.year, cursor.month, cursor.day + 1)
          : DateTime(cursor.year, cursor.month, cursor.day + 1);
      final amount = math.min(
        remaining,
        midnight.difference(cursor).inMilliseconds,
      );
      if (amount <= 0) break;
      days.putIfAbsent(listeningDate(cursor), ListeningDay.new).milliseconds +=
          amount;
      cursor = cursor.add(Duration(milliseconds: amount));
      remaining -= amount;
    }
    if (plays > 0) {
      days.putIfAbsent(listeningDate(end), ListeningDay.new).plays += plays;
    }
  }

  Map<String, dynamic> toJson() => {
    'tracks': {
      for (final entry in tracks.entries) entry.key: entry.value.toJson(),
    },
    'days': {for (final entry in days.entries) entry.key: entry.value.toJson()},
  };

  static ListeningStats fromJson(Object? json) {
    final result = ListeningStats();
    if (json == null) return result;
    if (json is! Map || json['tracks'] is! Map || json['days'] is! Map) {
      throw const FormatException('Invalid listening statistics.');
    }
    final rawTracks = json['tracks'] as Map, rawDays = json['days'] as Map;
    if (rawTracks.length > 100000 || rawDays.length > 36600) {
      throw const FormatException(
        'Listening statistics exceed supported limits.',
      );
    }
    for (final entry in rawTracks.entries) {
      final id = dataText(entry.key, maximum: 200, empty: false);
      final value = entry.value;
      if (value is! Map) {
        throw const FormatException('Invalid track statistics.');
      }
      final stamp = value['lastListened'];
      final parsed = stamp == null
          ? null
          : DateTime.tryParse(dataText(stamp, maximum: 40));
      if (stamp != null && parsed == null) {
        throw const FormatException('Invalid listening timestamp.');
      }
      result.tracks[id] = ListeningTrack(
        title: dataText(value['title']),
        artist: dataText(value['artist']),
        source: dataText(value['source']),
        milliseconds: dataInteger(value['milliseconds']),
        plays: dataInteger(value['plays']),
        lastListened: parsed,
      );
    }
    for (final entry in rawDays.entries) {
      final key = dataText(entry.key, maximum: 10, empty: false),
          value = entry.value;
      final date = DateTime.tryParse(key);
      if (date == null || listeningDate(date) != key || value is! Map) {
        throw const FormatException('Invalid daily listening statistics.');
      }
      result.days[key] = ListeningDay(
        milliseconds: dataInteger(value['milliseconds']),
        plays: dataInteger(value['plays']),
      );
    }
    dataInteger(result.milliseconds);
    dataInteger(result.plays);
    if (result.days.values.fold<int>(0, (sum, day) => sum + day.milliseconds) !=
            result.milliseconds ||
        result.days.values.fold<int>(0, (sum, day) => sum + day.plays) !=
            result.plays) {
      throw const FormatException('Listening totals are inconsistent.');
    }
    return result;
  }

  String toCsv() {
    String cell(String value) {
      // Telegram metadata is untrusted spreadsheet input.
      if (RegExp(r'^\s*[=+@-]|^[\t\r\n]').hasMatch(value)) value = "'$value";
      return '"${value.replaceAll('"', '""')}"';
    }

    final rows = <String>[
      'record_type,date,track_id,title,artist,source,listen_seconds,qualified_plays,last_listened_at',
    ];
    for (final entry in topTracks) {
      final track = entry.value;
      rows.add(
        [
          'track',
          '',
          cell(entry.key),
          cell(track.title),
          cell(track.artist),
          cell(track.source),
          (track.milliseconds / 1000).toStringAsFixed(3),
          '${track.plays}',
          cell(track.lastListened?.toUtc().toIso8601String() ?? ''),
        ].join(','),
      );
    }
    final dates = days.keys.toList()..sort();
    for (final date in dates) {
      final day = days[date]!;
      rows.add(
        [
          'day',
          date,
          '',
          '',
          '',
          '',
          (day.milliseconds / 1000).toStringAsFixed(3),
          '${day.plays}',
          '',
        ].join(','),
      );
    }
    return '\uFEFF${rows.join('\r\n')}\r\n';
  }
}

String listeningTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
  return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
}
