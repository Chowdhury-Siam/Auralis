import 'package:flutter/services.dart';

import 'storage.dart';

/// Android's non-exportable AES key lives in Android Keystore, outside backups.
class AndroidSecretVault extends SecretVault {
  AndroidSecretVault(super.file);
  static const _channel = MethodChannel('app.auralis/platform');
  @override
  Future<void> resetProtection() =>
      _channel.invokeMethod<void>('resetCredentialKey');

  @override
  Future<Uint8List> transform(List<int> bytes, {required bool encrypt}) async {
    final result = await _channel.invokeMethod<Uint8List>(
      encrypt ? 'encrypt' : 'decrypt',
      Uint8List.fromList(bytes),
    );
    if (result == null) {
      throw StateError('Android credential encryption failed.');
    }
    if (encrypt) {
      // Never persist ciphertext that the current device key cannot read back.
      final plain = await _channel.invokeMethod<Uint8List>('decrypt', result);
      try {
        if (plain == null || plain.length != bytes.length) {
          throw StateError('Android could not verify the saved credentials.');
        }
        var difference = 0;
        for (var i = 0; i < bytes.length; i++) {
          difference |= plain[i] ^ bytes[i];
        }
        if (difference != 0) {
          throw StateError('Android could not verify the saved credentials.');
        }
      } finally {
        if (plain != null) plain.fillRange(0, plain.length, 0);
      }
    }
    return result;
  }
}
