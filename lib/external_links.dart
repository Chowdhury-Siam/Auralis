import 'dart:io';

import 'package:flutter/services.dart';

Future<void> openExternalLink(String value) async {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Use an HTTPS link.');
  }
  if (Platform.isAndroid) {
    await const MethodChannel('app.auralis/platform')
        .invokeMethod<void>('openExternalUrl', value);
    return;
  }
  final result = Platform.isWindows
      ? await Process.run('rundll32', ['url.dll,FileProtocolHandler', value])
      : await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [value]);
  if (result.exitCode != 0) {
    throw const FileSystemException('Could not open the browser.');
  }
}
