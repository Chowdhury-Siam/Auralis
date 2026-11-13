import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Device-local references only; original paths and image bytes never enter
/// portable backups or Worker Sync. Music accounts have separate namespaces.
class PlaylistPhotos {
  final _photos = <String, String>{};
  final _generations = <String, int>{};
  static final _token = RegExp(r'^[a-f0-9]{64}\.png$');
  static bool validToken(String value) => _token.hasMatch(value);
  static String _key(String mode, String scope, String name) =>
      sha256.convert(utf8.encode(jsonEncode([mode, scope, name]))).toString();

  String? photo(String mode, String scope, String name) =>
      _photos[_key(mode, scope, name)];

  void set(String mode, String scope, String name, String? token) {
    final key = _key(mode, scope, name);
    if (token == null) {
      _photos.remove(key);
    } else if (validToken(token)) {
      if (_photos.length >= 1000 && !_photos.containsKey(key)) {
        throw StateError('Too many saved playlist photos.');
      }
      _photos[key] = token;
    } else {
      throw const FormatException('Invalid playlist photo reference.');
    }
  }

  int begin(String mode, String scope, String name) {
    final key = _key(mode, scope, name);
    return _generations[key] = (_generations[key] ?? 0) + 1;
  }

  bool current(String mode, String scope, String name, int generation) =>
      _generations[_key(mode, scope, name)] == generation;

  void rename(String mode, String scope, String old, String name) {
    if (old == name) return;
    begin(mode, scope, old);
    final token = photo(mode, scope, old);
    set(mode, scope, old, null);
    set(mode, scope, name, token);
  }

  void remove(String mode, String scope, String name) {
    begin(mode, scope, name);
    set(mode, scope, name, null);
  }

  bool uses(String token) => _photos.containsValue(token);
  Map<String, String> toJson() => Map.of(_photos);

  void load(Object? raw) {
    _photos.clear();
    _generations.clear();
    if (raw is! Map) return;
    for (final entry in raw.entries.take(1000)) {
      if (entry.key is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String) &&
          entry.value is String &&
          validToken(entry.value as String)) {
        _photos[entry.key as String] = entry.value as String;
      }
    }
  }
}
