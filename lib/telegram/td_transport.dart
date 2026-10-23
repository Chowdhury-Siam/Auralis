import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef Json = Map<String, dynamic>;
typedef TdRequest = Future<Json> Function(Json request);

class TdException implements Exception {
  TdException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'Telegram ($code): $message';
}

/// One receiver isolate owns the native client and preserves update ordering.
class TdTransport {
  final _updates = StreamController<Json>.broadcast();
  final _pending = <String, Completer<Json>>{};
  final _closed = Completer<void>();
  ReceivePort? _receive;
  SendPort? _send;
  Isolate? _isolate;
  int _sequence = 0;
  bool _closing = false;
  Stream<Json> get updates => _updates.stream;

  Future<void> start(String libraryPath) async {
    final ready = Completer<void>();
    _receive = ReceivePort();
    _receive!.listen((dynamic event) {
      if (event is SendPort) {
        _send = event;
        ready.complete();
      } else if (event is Map) {
        final json = Map<String, dynamic>.from(event);
        if (json.containsKey('bridgeError')) {
          final error = StateError(
            'TDLib could not load. Reinstall the complete Auralis package for your device.',
          );
          if (!ready.isCompleted) ready.completeError(error);
          _failPending(error);
          return;
        }
        final extra = json['@extra'];
        final pending = _pending.remove(extra);
        if (pending != null) {
          if (json['@type'] == 'error') {
            pending.completeError(
              TdException(json['code'] as int, json['message'] as String),
            );
          } else {
            pending.complete(json);
          }
        }
        if (!_updates.isClosed) _updates.add(json);
        if (json['@type'] == 'updateAuthorizationState' &&
            json['authorization_state']?['@type'] ==
                'authorizationStateClosed') {
          if (!_closed.isCompleted) _closed.complete();
        }
      }
    });
    _isolate = await Isolate.spawn(_tdWorker, [
      libraryPath,
      _receive!.sendPort,
    ]);
    try {
      await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      _isolate?.kill(priority: Isolate.immediate);
      _receive?.close();
      rethrow;
    }
  }

  Future<Json> request(
    Json value, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_send == null || _closing) throw StateError('Telegram is disconnected');
    final key = '${++_sequence}';
    final pending = Completer<Json>();
    _pending[key] = pending;
    _send!.send({...value, '@extra': key});
    try {
      return await pending.future.timeout(timeout);
    } finally {
      _pending.remove(key);
    }
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _send?.send({'@type': 'close'});
    try {
      if (_send != null) {
        await _closed.future.timeout(const Duration(seconds: 8));
      }
    } finally {
      _failPending(StateError('Telegram was closed'));
      _isolate?.kill(priority: Isolate.immediate);
      _receive?.close();
      _send = null;
      await _updates.close();
    }
  }
}

void _tdWorker(List<dynamic> arguments) {
  final output = arguments[1] as SendPort;
  try {
    final library = _loadLibrary(arguments[0] as String);
    final create = library.lookupFunction<Int32 Function(), int Function()>(
      'td_create_client_id',
    );
    final send = library
        .lookupFunction<
          Void Function(Int32, Pointer<Utf8>),
          void Function(int, Pointer<Utf8>)
        >('td_send');
    final receive = library
        .lookupFunction<
          Pointer<Utf8> Function(Double),
          Pointer<Utf8> Function(double)
        >('td_receive');
    final execute = library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)
        >('td_execute');
    final log = jsonEncode({
      '@type': 'setLogVerbosityLevel',
      'new_verbosity_level': 0,
    }).toNativeUtf8();
    execute(log);
    calloc.free(log);
    final client = create();
    final input = ReceivePort();
    output.send(input.sendPort);
    input.listen((dynamic event) {
      final pointer = jsonEncode(event).toNativeUtf8();
      try {
        send(client, pointer);
      } finally {
        calloc.free(pointer);
      }
    });
    Timer? timer;
    timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      // Nonblocking receive, bounded batch; no native waits on Flutter's UI isolate.
      for (var i = 0; i < 64; i++) {
        final pointer = receive(0);
        if (pointer == nullptr) break;
        final event = jsonDecode(pointer.toDartString()) as Json;
        if (event['@client_id'] != client) continue;
        output.send(event);
        if (event['@type'] == 'updateAuthorizationState' &&
            event['authorization_state']?['@type'] ==
                'authorizationStateClosed') {
          timer?.cancel();
          input.close();
          break;
        }
      }
    });
  } catch (_) {
    // Never forward native errors that could embed request payloads or secrets.
    output.send({'bridgeError': true});
  }
}

DynamicLibrary _loadLibrary(String path) {
  if (!Platform.isWindows) return DynamicLibrary.open(path);
  path = File(path).absolute.path.replaceAll('/', r'\');
  final kernel = DynamicLibrary.open('kernel32.dll');
  final load = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>, Uint32),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>, int)
      >('LoadLibraryExW');
  final free = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FreeLibrary');
  final name = File(path).absolute.path.toNativeUtf16();
  Pointer<Void> handle = nullptr;
  try {
    // Resolve dependencies from this DLL's directory and trusted system folders.
    handle = load(name, nullptr, 0x00000100 | 0x00001000);
    if (handle == nullptr) throw StateError('TDLib dependency missing');
    return DynamicLibrary.open(path);
  } finally {
    calloc.free(name);
    if (handle != nullptr) free(handle);
  }
}
