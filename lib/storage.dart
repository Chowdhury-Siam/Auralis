import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'models.dart';
import 'listening.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _CryptDart = int Function(
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);

/// DPAPI binds encrypted secrets to the current Windows user and machine.
class WindowsProtector {
  Uint8List transform(List<int> bytes, {required bool encrypt}) {
    if (!Platform.isWindows) throw UnsupportedError('Windows DPAPI required');
    final crypt = DynamicLibrary.open('crypt32.dll')
        .lookupFunction<_CryptNative, _CryptDart>(
          encrypt ? 'CryptProtectData' : 'CryptUnprotectData',
        );
    final free = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    input.ref.length = bytes.length;
    input.ref.data = calloc<Uint8>(max(1, bytes.length));
    input.ref.data.asTypedList(bytes.length).setAll(0, bytes);
    try {
      // CRYPTPROTECT_UI_FORBIDDEN: never allow an OS credential prompt here.
      if (crypt(input, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
        throw const FileSystemException(
          'Windows could not unlock the credential vault',
        );
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      input.ref.data.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(input.ref.data);
      if (output.ref.data != nullptr) free(output.ref.data.cast());
      calloc.free(input);
      calloc.free(output);
    }
  }
}

class SecretVault {
  SecretVault(this.file, [WindowsProtector? protector])
    : protector = protector ?? WindowsProtector();
  final File file;
  final WindowsProtector protector;

  Future<Map<String, dynamic>> read() async {
    if (!await file.exists()) return {};
    final plain = await transform(await file.readAsBytes(), encrypt: false);
    try {
      return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<void> write(Map<String, dynamic> secrets) async {
    final bytes = utf8.encode(jsonEncode(secrets));
    try {
      await atomicWrite(file, await transform(bytes, encrypt: true));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<Uint8List> transform(List<int> bytes, {required bool encrypt}) async =>
      protector.transform(bytes, encrypt: encrypt);

  // Called only after the user chooses a fresh sign-in for an unreadable vault.
  Future<void> resetProtection() async {}

  static String newDatabaseKey() =>
      base64Encode(List.generate(32, (_) => Random.secure().nextInt(256)));
}

Future<void> atomicWrite(File file, List<int> data) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsBytes(data, flush: true);
  // Dart's rename replaces an existing ordinary file on Windows.
  await temporary.rename(file.path);
}

class AppSettings {
  AppSettings(this.file);
  final File file;
  Map<String, dynamic> syncState = {};
  String? lastSeenRelease;
  void Function(Map<String, dynamic>)? captureSync;
  void Function()? onSaved;
  bool reducedMotion = false;
  bool automaticUpdates = true;
  double volume = 70;
  bool automaticLyrics = true, automaticTranslation = true, keepArtwork = true;
  int artworkPreload = 10;
  LyricsSource lyricsFirst = LyricsSource.lrclib;
  LyricsSource? lyricsFallback = LyricsSource.lyricsOvh;
  TranslationSource translationFirst = TranslationSource.google;
  TranslationSource? translationFallback = TranslationSource.myMemory;
  TranslationDirection translationDirection =
      TranslationDirection.japaneseEnglish;
  LibrarySort librarySort = LibrarySort.newest;
  List<MusicChat> selectedChannels = [];
  Set<String> favoriteIds = {};
  Map<String, List<String>> playlists = {};
  List<String> recentIds = [];
  PlaybackRepeat repeatMode = PlaybackRepeat.off;
  ListeningStats listening = ListeningStats();

  static List<String> _ids(Object? value, int limit) => value is List
      ? value
            .whereType<String>()
            .where((id) => id.isNotEmpty && id.length <= 200)
            .toSet()
            .take(limit)
            .toList()
      : [];

  Future<void> _saving = Future.value();

  Future<void> load() async {
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    applyJson(json);
    syncState = json['_sync'] is Map<String, dynamic>
        ? json['_sync'] as Map<String, dynamic>
        : {};
    lastSeenRelease = json['_lastSeenRelease'] as String?;
  }

  Map<String, dynamic> _diskJson(Map<String, dynamic> snapshot) => {
    ...snapshot,
    '_sync': syncState,
    '_lastSeenRelease': lastSeenRelease,
  };

  void applyJson(Map<String, dynamic> json) {
    listening = ListeningStats.fromJson(json['listening']);
    // Retire the app-specific toggle, including settings restored from old backups.
    // The platform accessibility preference is still respected by the UI.
    reducedMotion = false;
    automaticUpdates = json['automaticUpdates'] != false;
    volume = (json['volume'] as num? ?? 70).toDouble().clamp(0, 100);
    automaticLyrics = json['automaticLyrics'] != false;
    automaticTranslation = json['automaticTranslation'] != false;
    keepArtwork = json['keepArtwork'] != false;
    artworkPreload = json['artworkPreload'] is int
        ? (json['artworkPreload'] as int).clamp(0, 50)
        : 10;
    lyricsFirst = LyricsSource.values.firstWhere(
      (v) => v.name == json['lyricsFirst'],
      orElse: () => LyricsSource.lrclib,
    );
    lyricsFallback =
        json.containsKey('lyricsFallback') && json['lyricsFallback'] == null
        ? null
        : LyricsSource.values.firstWhere(
            (v) => v.name == json['lyricsFallback'],
            orElse: () => LyricsSource.lyricsOvh,
          );
    if (lyricsFallback == lyricsFirst) lyricsFallback = null;
    translationFirst = TranslationSource.values.firstWhere(
      (v) => v.name == json['translationFirst'],
      orElse: () => TranslationSource.google,
    );
    translationFallback =
        json.containsKey('translationFallback') &&
            json['translationFallback'] == null
        ? null
        : TranslationSource.values.firstWhere(
            (v) => v.name == json['translationFallback'],
            orElse: () => TranslationSource.myMemory,
          );
    if (translationFallback == translationFirst) translationFallback = null;
    translationDirection = TranslationDirection.values.firstWhere(
      (v) => v.name == json['translationDirection'],
      orElse: () => TranslationDirection.japaneseEnglish,
    );
    librarySort = LibrarySort.values.firstWhere(
      (value) => value.name == json['librarySort'],
      orElse: () => LibrarySort.newest,
    );
    favoriteIds = _ids(json['favoriteIds'], 10000).toSet();
    recentIds = _ids(json['recentIds'], 100);
    repeatMode = PlaybackRepeat.values.firstWhere(
      (value) => value.name == json['repeatMode'],
      orElse: () => PlaybackRepeat.off,
    );
    playlists = {};
    final saved = json['playlists'];
    if (saved is Map) {
      final names = <String>{};
      for (final entry in saved.entries.take(100)) {
        final name = entry.key;
        if (name is String &&
            name.trim().isNotEmpty &&
            name.length <= 60 &&
            names.add(name.trim().toLowerCase())) {
          playlists[name.trim()] = _ids(entry.value, 5000);
        }
      }
    }
    selectedChannels = [
      for (final entry in (json['selectedChannels'] as List? ?? []))
        if (entry is Map && entry['id'] is int && entry['title'] is String)
          MusicChat(entry['id'] as int, entry['title'] as String),
    ];
  }

  Map<String, dynamic> toJson() => {
    // Preserve the version-1 backup schema without persisting the retired toggle.
    'reducedMotion': false,
    'automaticUpdates': automaticUpdates,
    'volume': volume,
    'automaticLyrics': automaticLyrics,
    'automaticTranslation': automaticTranslation,
    'lyricsFirst': lyricsFirst.name,
    'lyricsFallback': lyricsFallback?.name,
    'translationFirst': translationFirst.name,
    'translationFallback': translationFallback?.name,
    'translationDirection': translationDirection.name,
    'artworkPreload': artworkPreload,
    'keepArtwork': keepArtwork,
    'librarySort': librarySort.name,
    'favoriteIds': favoriteIds.toList(),
    'playlists': playlists,
    'recentIds': recentIds,
    'repeatMode': repeatMode.name,
    'listening': listening.toJson(),
    'selectedChannels': [
      for (final channel in selectedChannels)
        {'id': channel.id, 'title': channel.title},
    ],
  };

  Future<void> replaceSnapshot(
    Map<String, dynamic> snapshot,
    List<int> recovery,
  ) {
    final next = _saving.then((_) async {
      await atomicWrite(
        File('${file.parent.path}/auralis-before-restore.json'),
        recovery,
      );
      final oldSync = jsonDecode(jsonEncode(syncState)) as Map<String, dynamic>;
      try {
        captureSync?.call(snapshot);
        await atomicWrite(file, utf8.encode(jsonEncode(_diskJson(snapshot))));
        applyJson(snapshot);
      } catch (_) {
        syncState = oldSync;
        rethrow;
      }
      onSaved?.call();
    });
    _saving = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> save() {
    final snapshot = toJson();
    captureSync?.call(snapshot);
    final data = utf8.encode(jsonEncode(_diskJson(snapshot)));
    // Serialize writes so a quick series of slider changes cannot race renames.
    final next = _saving.then((_) async {
      await atomicWrite(file, data);
      onSaved?.call();
    });
    _saving = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
