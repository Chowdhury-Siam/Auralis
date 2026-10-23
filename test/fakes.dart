import 'dart:async';
import 'dart:io';

import 'package:auralis/player.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:path/path.dart' as p;

// Use a native absolute path outside the fixture settings folder. Dart's
// File.absolute treats a leading forward slash differently on Windows.
String testExportPath(String name) =>
    p.join(Directory.systemTemp.path, 'auralis-test-exports', name);

class FakeAudio extends AudioBackend {
  String? uri;
  final volumes = <double>[];
  @override
  Future<void> open(String uri) async {
    this.uri = uri;
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    notifyListeners();
  }

  @override
  Future<void> toggle() async {
    playing = !playing;
    notifyListeners();
  }

  @override
  Future<void> volume(double value) async {
    volumes.add(value);
  }

  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> shutdown() async {
    dispose();
  }
}

class MemoryVault extends SecretVault {
  MemoryVault() : super(File('unused.dpapi'));
  Map<String, dynamic> data = {};
  @override
  Future<Map<String, dynamic>> read() async => {...data};
  @override
  Future<void> write(Map<String, dynamic> secrets) async {
    data = {...secrets};
  }
}

class MemorySettings extends AppSettings {
  MemorySettings() : super(File('unused'));
  @override
  Future<void> save() async {}
}

class FakeTd extends TdTransport {
  final events = StreamController<Json>.broadcast(sync: true);
  final requests = <Json>[];
  Future<Json?> Function(Json)? onRequest;
  @override
  Stream<Json> get updates => events.stream;
  @override
  Future<void> start(String libraryPath) async {}
  @override
  Future<Json> request(
    Json json, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add(json);
    final custom = await onRequest?.call(json);
    if (custom != null) return custom;
    if (json['@type'] == 'getAuthorizationState') {
      return {'@type': 'authorizationStateWaitTdlibParameters'};
    }
    if (json['@type'] == 'searchChatMessages') {
      return {'messages': [], 'next_from_message_id': 777};
    }
    return {'@type': 'ok'};
  }

  void auth(String state) => events.add({
    '@type': 'updateAuthorizationState',
    'authorization_state': {'@type': state},
  });
  @override
  Future<void> close() async {
    await events.close();
  }
}
