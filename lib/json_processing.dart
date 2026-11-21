import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

/// Small replies avoid isolate startup overhead. Large settings/sync payloads
/// decode off the UI isolate; errors and JSON values retain the same semantics.
Future<dynamic> decodeJsonBytes(Uint8List bytes) {
  if (bytes.length < 256 * 1024) {
    return Future.sync(() => jsonDecode(utf8.decode(bytes)));
  }
  return Isolate.run(() => jsonDecode(utf8.decode(bytes)));
}
