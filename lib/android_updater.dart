import 'dart:io';

import 'package:flutter/services.dart';

/// The native bridge only exposes this app's private update cache and installer.
class AndroidUpdateBridge {
  const AndroidUpdateBridge();
  static const _channel = MethodChannel('app.auralis/platform');

  Future<({String abi, Directory directory})> info() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('updateInfo');
    final abi = value?['abi'];
    final path = value?['directory'];
    if (!const ['arm64-v8a', 'x86_64'].contains(abi) ||
        path is! String ||
        path.isEmpty) {
      throw StateError('Android update information is unavailable.');
    }
    return (abi: abi as String, directory: Directory(path));
  }

  Future<void> install(File file, String version, String sha256) async {
    final result = await _channel.invokeMethod<bool>('installUpdate', {
      'path': file.path,
      'version': version,
      'sha256': sha256,
    });
    if (result != true) {
      throw StateError('Android did not open the update installer.');
    }
  }
}
