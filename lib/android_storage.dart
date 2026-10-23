import 'package:flutter/services.dart';

import 'storage.dart';

/// Android's non-exportable AES key lives in Android Keystore, outside backups.
class AndroidSecretVault extends SecretVault {
  AndroidSecretVault(super.file);
  static const _channel = MethodChannel('app.auralis/platform');
  @override
  Future<Uint8List> transform(List<int> bytes, {required bool encrypt}) async {
    final result = await _channel.invokeMethod<Uint8List>(
      encrypt ? 'encrypt' : 'decrypt',
      Uint8List.fromList(bytes),
    );
    if (result == null) {
      throw StateError('Android credential encryption failed.');
    }
    return result;
  }
}
