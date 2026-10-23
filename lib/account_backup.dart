import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'data_backup.dart';

/// Portable TDLib database plus the key needed to unlock it. Never write this
/// object to a user-selected file without AccountBackup.encrypt.
class TelegramAccount {
  TelegramAccount(this.credentials, this.files);
  final Map<String, dynamic> credentials;
  final Map<String, String> files;
  static const maxDatabaseBytes = 32 * 1024 * 1024;

  static Future<TelegramAccount> capture(
    Directory database,
    Map<String, dynamic> credentials,
  ) async {
    final files = <String, String>{};
    var size = 0;
    await for (final entry in database.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) {
        throw const FormatException('Session contains a link.');
      }
      if (entry is! File) continue;
      size += await entry.length();
      if (size > maxDatabaseBytes) {
        throw const FormatException(
          'Telegram database exceeds the 32 MiB account backup limit.',
        );
      }
      files[p
          .relative(entry.path, from: database.path)
          .split(p.separator)
          .join('/')] = base64Encode(
        await entry.readAsBytes(),
      );
    }
    return fromJson({'credentials': credentials, 'files': files});
  }

  Map<String, dynamic> toJson() => {'credentials': credentials, 'files': files};

  static TelegramAccount fromJson(Object? value) {
    if (value is! Map ||
        value['credentials'] is! Map ||
        value['files'] is! Map) {
      throw const FormatException('Invalid Telegram account backup.');
    }
    final credentials = Map<String, dynamic>.from(value['credentials'] as Map);
    if (credentials.length != 3 ||
        credentials['apiId'] is! int ||
        (credentials['apiId'] as int) <= 0 ||
        credentials['apiHash'] is! String ||
        !RegExp(r'^[a-fA-F0-9]{32}$')
            .hasMatch(credentials['apiHash'] as String) ||
        credentials['databaseKey'] is! String ||
        base64Decode(credentials['databaseKey'] as String).length != 32) {
      throw const FormatException('Invalid Telegram credentials.');
    }
    final files = Map<String, String>.from(value['files'] as Map);
    if (files.isEmpty || files.length > 2048) {
      throw const FormatException('Invalid Telegram database files.');
    }
    var size = 0;
    final seen = <String>{};
    for (final entry in files.entries) {
      final parts = entry.key.split('/');
      if (entry.key.length > 512 ||
          parts.length > 8 ||
          parts.any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                RegExp(r'[\\:\x00-\x1f<>"|?*]').hasMatch(part) ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          ) ||
          !seen.add(entry.key.toLowerCase())) {
        throw const FormatException('Unsafe Telegram database path.');
      }
      size += base64Decode(entry.value).length;
      if (size > maxDatabaseBytes) {
        throw const FormatException('Telegram database exceeds 32 MiB.');
      }
    }
    return TelegramAccount(credentials, files);
  }

  Future<void> write(Directory target) async {
    for (final entry in files.entries) {
      final file = File(p.joinAll([target.path, ...entry.key.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(entry.value), flush: true);
    }
  }
}

class AccountBackup {
  AccountBackup(this.data, this.account);
  final DataBackup data;
  final TelegramAccount? account;
  static final _aad = utf8.encode('auralis-account-backup-v2');
  static final _cipher = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 600000,
    bits: 256,
  );

  static bool isEncrypted(String text) {
    final value = jsonDecode(text);
    return value is Map && value['format'] == 'auralis-account-backup';
  }

  Future<String> encrypt(String password) async {
    if (password.length < 10 || password.length > 1024) {
      throw const FormatException(
        'Use a backup password of 10–1024 characters.',
      );
    }
    final salt = List.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _kdf.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final plain = utf8.encode(
      jsonEncode({'backup': data.encode(), 'telegram': account?.toJson()}),
    );
    try {
      final box = await _cipher.encrypt(plain, secretKey: key, aad: _aad);
      final text = jsonEncode({
        'format': 'auralis-account-backup',
        'version': 2,
        'salt': base64Encode(salt),
        'box': base64Encode(box.concatenation()),
      });
      if (utf8.encode(text).length > DataBackup.maxBytes) {
        throw const FormatException('Backup exceeds 64 MiB.');
      }
      return text;
    } finally {
      plain.fillRange(0, plain.length, 0);
      key.destroy();
    }
  }

  static Future<AccountBackup> decrypt(String text, String password) async {
    if (utf8.encode(text).length > DataBackup.maxBytes) {
      throw const FormatException('Backup exceeds 64 MiB.');
    }
    try {
      final value = jsonDecode(text) as Map<String, dynamic>;
      if (value['format'] != 'auralis-account-backup' ||
          value['version'] != 2 ||
          password.length > 1024) {
        throw const FormatException('Unsupported encrypted backup.');
      }
      final salt = base64Decode(value['salt'] as String);
      final bytes = base64Decode(value['box'] as String);
      if (salt.length != 16 || bytes.length < 28) {
        throw const FormatException('Invalid encrypted backup.');
      }
      final key = await _kdf.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      try {
        final plain = await _cipher.decrypt(
          SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
          secretKey: key,
          aad: _aad,
        );
        try {
          final payload =
              jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
          return AccountBackup(
            DataBackup.parse(payload['backup'] as String),
            payload['telegram'] == null
                ? null
                : TelegramAccount.fromJson(payload['telegram']),
          );
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
      } finally {
        key.destroy();
      }
    } on SecretBoxAuthenticationError {
      throw const FormatException(
        'Incorrect backup password or damaged backup. Nothing was restored.',
      );
    } on TypeError {
      throw const FormatException('Invalid encrypted backup.');
    }
  }
}

// Keep isolate closures outside widget State so no UI/native objects are sent.
Future<String> encryptAccountBackup(
  DataBackup data,
  TelegramAccount account,
  String password,
) => Isolate.run(() => AccountBackup(data, account).encrypt(password));
Future<AccountBackup> decryptAccountBackup(String text, String password) =>
    Isolate.run(() => AccountBackup.decrypt(text, password));
