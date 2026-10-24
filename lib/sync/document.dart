import 'dart:convert';
import 'dart:math';

import '../listening.dart';

String newSyncKey() => List.generate(32, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
Map<String, dynamic> detached(Map<String, dynamic> data) => jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

/// Durable field operations and tombstones; playback and credentials are excluded.
class SyncDocument {
  SyncDocument(this.state) {
    state.putIfAbsent('device', () => newSyncKey().substring(0, 32));
    state.putIfAbsent('clock', () => 0);
    state.putIfAbsent('cursor', () => 0);
    state.putIfAbsent('bootstrap', () => true);
    state.putIfAbsent('records', () => <String, dynamic>{});
    state.putIfAbsent('dirty', () => <String>[]);
  }
  final Map<String, dynamic> state;
  Map<String, dynamic> get records => state['records'] as Map<String, dynamic>;
  String get device => state['device'] as String;
  late final Set<String> _dirty = (state['dirty'] as List).cast<String>().toSet();
  Set<String> get dirty => _dirty;
  static String key(List<String> parts) => jsonEncode(parts);
  static int compare(Map a, Map b) {
    final clock = (a['clock'] as int).compareTo(b['clock'] as int);
    return clock == 0 ? (a['device'] as String).compareTo(b['device'] as String) : clock;
  }
  static void validate(String key, dynamic record) {
    final parts = jsonDecode(key);
    if (key.length > 600 || parts is! List || parts.any((p) => p is! String) || record is! Map ||
        record.keys.length != 3 || !record.containsKey('value') || record['clock'] is! int || (record['clock'] as int) < 0 ||
        (record['clock'] as int) > 9007199254740991 ||
        record['device'] is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(record['device'] as String)) {
      throw const FormatException('Invalid sync record.');
    }
    if (parts.length < 2 || parts.length > 3 || parts.any((p) => (p as String).isEmpty || p.length > 200)) {
      throw const FormatException('Invalid sync key.');
    }
    final value = record['value'];
    switch (parts[0]) {
      case 'favorite' || 'playlist':
        if (parts.length != 2 || (value != true && value != null) || (parts[0] == 'playlist' && (parts[1] as String).length > 60)) throw const FormatException('Invalid collection.');
      case 'entry':
        if (parts.length != 3 || (parts[1] as String).length > 60 || (value != null && (value is! int || value < 0 || value > 5000))) throw const FormatException('Invalid playlist entry.');
      case 'recent':
        if (parts.length != 2 || (value != null && (value is! int || value < 0 || value > 9007199254740991))) throw const FormatException('Invalid recent track.');
      case 'channel':
        if (parts.length != 2 || int.tryParse(parts[1] as String) == null || (value != null && (value is! String || value.length > 1000))) throw const FormatException('Invalid channel.');
      case 'pref':
        if (parts.length != 2 || !((parts[1] == 'librarySort' && const ['newest','oldest','title','artist','duration'].contains(value)) || (parts[1] == 'repeatMode' && const ['off','all','one'].contains(value)))) throw const FormatException('Invalid shared preference.');
      case 'stats' || 'day':
        if (parts.length != 3 || (parts[1] != 'baseline' && !RegExp(r'^[a-f0-9]{32}$').hasMatch(parts[1] as String)) || value is! Map) throw const FormatException('Invalid listening component.');
        final fields = parts[0] == 'stats' ? const ['title','artist','source','milliseconds','plays','lastListened'] : const ['milliseconds','plays'];
        if (value.keys.any((field) => !fields.contains(field))) throw const FormatException('Unsupported listening field.');
        dataInteger(value['milliseconds']); dataInteger(value['plays']);
        if (parts[0] == 'stats') {
          for (final name in ['title','artist','source']) { dataText(value[name]); }
          if (value['lastListened'] != null && DateTime.tryParse(dataText(value['lastListened'], maximum: 40)) == null) throw const FormatException('Invalid listening date.');
        } else if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(parts[2] as String)) {
          throw const FormatException('Invalid listening day.');
        }
      default: throw const FormatException('Unsupported sync field.');
    }
    if (jsonEncode(record).length > 16000) throw const FormatException('Sync record too large.');
  }

  void _put(List<String> parts, dynamic value, bool seed) {
    final k = key(parts);
    if (jsonEncode((records[k] as Map?)?['value']) == jsonEncode(value)) return;
    final clock = seed ? 0 : (state['clock'] as int) + 1;
    state['clock'] = max(state['clock'] as int, clock);
    final record = <String, dynamic>{'clock': clock, 'device': device, 'value': value};
    validate(k, record);
    records[k] = record;
    dirty.add(k);
  }

  void capture(Map<String, dynamic> snapshot) {
    final previous = state['observed'] as Map?;
    final seed = previous == null;
    final old = previous ?? <String, dynamic>{};
    for (final field in ['favoriteIds','recentIds']) {
      final before = (old[field] as List? ?? []).cast<String>();
      final after = (snapshot[field] as List).cast<String>();
      for (final id in {...before, ...after}) {
        final a = after.indexOf(id), b = before.indexOf(id);
        if (seed || a != b) {
          _put([field == 'favoriteIds' ? 'favorite' : 'recent', id], a < 0 ? null : field == 'favoriteIds' ? true : DateTime.now().millisecondsSinceEpoch - a, seed);
        }
      }
    }
    final beforeLists = old['playlists'] as Map? ?? {};
    final afterLists = snapshot['playlists'] as Map;
    for (final name in {...beforeLists.keys, ...afterLists.keys}.cast<String>()) {
      if (seed || beforeLists.containsKey(name) != afterLists.containsKey(name)) _put(['playlist', name], afterLists.containsKey(name) ? true : null, seed);
      final before = (beforeLists[name] as List? ?? []).cast<String>();
      final after = (afterLists[name] as List? ?? []).cast<String>();
      for (final id in {...before, ...after}) {
        final a = after.indexOf(id);
        if (seed || a != before.indexOf(id)) _put(['entry', name, id], a < 0 ? null : a, seed);
      }
    }
    Map<String, String> channels(Map data) => {for (final c in data['selectedChannels'] as List? ?? []) '${c['id']}': c['title'] as String};
    final beforeChannels = channels(old), afterChannels = channels(snapshot);
    for (final id in {...beforeChannels.keys, ...afterChannels.keys}) {
      if (seed || beforeChannels[id] != afterChannels[id]) _put(['channel', id], afterChannels[id], seed);
    }
    for (final name in ['librarySort','repeatMode']) {
      if (seed || old[name] != snapshot[name]) _put(['pref', name], snapshot[name], seed);
    }
    for (final kind in ['tracks','days']) {
      final before = (old['listening'] as Map?)?[kind] as Map? ?? {};
      final after = (snapshot['listening'] as Map)[kind] as Map;
      for (final id in after.keys.cast<String>()) {
        final value = after[id] as Map, was = before[id] as Map? ?? {};
        // ponytail: exact overlap of pre-sync histories needs event IDs; use a shared max baseline.
        final component = seed ? 'baseline' : device;
        final parts = [kind == 'tracks' ? 'stats' : 'day', component, id];
        final current = (records[key(parts)] as Map?)?['value'] as Map? ?? {};
        final ms = max(0, (value['milliseconds'] as int) - (was['milliseconds'] as int? ?? 0));
        final plays = max(0, (value['plays'] as int) - (was['plays'] as int? ?? 0));
        if (ms > 0 || plays > 0) {
          _put(parts, {...value, 'milliseconds': (current['milliseconds'] as int? ?? 0) + ms, 'plays': (current['plays'] as int? ?? 0) + plays}, seed);
        }
      }
    }
    state['dirty'] = dirty.toList();
    state['observed'] = detached(snapshot);
  }

  /// A restored aggregate may already include the cloud's per-device counters.
  /// Subtract those components before offering its initial shared baseline.
  void reconcileBaseline(Map<String, dynamic> remote) {
    final components = <String, Map<String, int>>{};
    for (final e in remote.entries) {
      validate(e.key, e.value);
      final parts = (jsonDecode(e.key) as List).cast<String>();
      if ((parts.first != 'stats' && parts.first != 'day') || parts[1] == 'baseline') continue;
      final sum = components.putIfAbsent(key([parts.first, parts[2]]), () => {'milliseconds': 0, 'plays': 0});
      for (final field in ['milliseconds', 'plays']) {
        sum[field] = sum[field]! + (((e.value as Map)['value'] as Map)[field] as int);
      }
    }
    for (final e in records.entries.toList()) {
      final parts = (jsonDecode(e.key) as List).cast<String>();
      if ((parts.first != 'stats' && parts.first != 'day') || parts[1] != 'baseline') continue;
      final record = e.value as Map, value = record['value'] as Map;
      final cloud = components[key([parts.first, parts[2]])] ?? {};
      records[e.key] = {...record, 'value': {...value,
        for (final field in ['milliseconds','plays']) field: max(0, (value[field] as int) - (cloud[field] ?? 0)),
      }};
    }
  }

  void merge(Map<String, dynamic> incoming) {
    for (final entry in incoming.entries) { validate(entry.key, entry.value); }
    for (final entry in incoming.entries) {
      final next = Map<String, dynamic>.from(entry.value as Map);
      final old = records[entry.key] as Map?;
      final kind = (jsonDecode(entry.key) as List).first;
      var result = old == null || compare(next, old) > 0 ? next : Map<String, dynamic>.from(old);
      if (old != null && (kind == 'stats' || kind == 'day')) {
        result = {...result, 'value': {...result['value'] as Map,
          for (final field in ['milliseconds','plays']) field: max((old['value'] as Map)[field] as int, (next['value'] as Map)[field] as int)}};
      }
      records[entry.key] = result;
      state['clock'] = max(state['clock'] as int, next['clock'] as int);
    }
  }

  Map<String, dynamic> project(Map<String, dynamic> local) {
    final result = detached(local), favorites = <String>[], recent = <(String, int)>[];
    final playlists = <String, Map<String, (int, Map)>>{};
    final headers = <String, (String, Map)>{};
    final channels = <Map<String, dynamic>>[];
    final tracks = <String, dynamic>{}, days = <String, dynamic>{};
    for (final entry in records.entries) {
      final parts = (jsonDecode(entry.key) as List).cast<String>(), r = entry.value as Map;
      if (parts.first == 'playlist') {
        final canonical = parts[1].trim().toLowerCase();
        final old = headers[canonical];
        if (old == null || compare(r, old.$2) > 0) headers[canonical] = (parts[1], r);
      }
    }
    for (final entry in headers.entries) {
      if (entry.value.$2['value'] == true) playlists[entry.key] = {};
    }
    for (final entry in records.entries) {
      final parts = (jsonDecode(entry.key) as List).cast<String>(), r = entry.value as Map, value = r['value'];
      if (value == null) continue;
      switch (parts.first) {
        case 'favorite': favorites.add(parts[1]);
        case 'recent': recent.add((parts[1], value as int));
        case 'pref': result[parts[1]] = value;
        case 'channel': channels.add({'id': int.parse(parts[1]), 'title': value});
        case 'entry':
          final canonical = parts[1].trim().toLowerCase();
          final list = playlists[canonical];
          if (list != null && (r['clock'] as int) >= (headers[canonical]!.$2['clock'] as int)) {
            final old = list[parts[2]];
            if (old == null || compare(r, old.$2) > 0) list[parts[2]] = (value as int, r);
          }
        case 'stats' || 'day':
          final target = parts.first == 'stats' ? tracks : days, id = parts[2];
          final before = target[id] as Map? ?? {};
          final v = value as Map;
          final newer = (v['lastListened'] as String? ?? '').compareTo(before['lastListened'] as String? ?? '') >= 0;
          target[id] = {...(newer ? v : before),
            'milliseconds': (before['milliseconds'] as int? ?? 0) + (v['milliseconds'] as int),
            'plays': (before['plays'] as int? ?? 0) + (v['plays'] as int)};
      }
    }
    recent.sort((a,b) => b.$2.compareTo(a.$2));

    result['favoriteIds'] = favorites..sort();
    result['recentIds'] = recent.take(100).map((r) => r.$1).toList();
    final ordered = <String, List<String>>{};
    for (final e in playlists.entries) {
      final items = e.value.entries.toList()..sort((a,b) => a.value.$1 == b.value.$1 ? a.key.compareTo(b.key) : a.value.$1.compareTo(b.value.$1));
      ordered[headers[e.key]!.$1] = items.map((item) => item.key).toList();
    }
    result['playlists'] = ordered;
    result['selectedChannels'] = channels..sort((a,b) => (a['id'] as int).compareTo(b['id'] as int));
    result['listening'] = {'tracks': tracks, 'days': days};
    state['observed'] = detached(result);
    return result;
  }
}
