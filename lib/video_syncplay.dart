import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

typedef SyncplayPosition = ({double position, bool paused});

/// Syncplay's newline-delimited client protocol, as used by mpvRx.
class VideoSyncplay extends ChangeNotifier {
  VideoSyncplay({
    required this.localPosition,
    required this.fileInfo,
    required this.applyRemote,
  });

  final SyncplayPosition Function() localPosition;
  final Map<String, Object> Function() fileInfo;
  final Future<void> Function(Duration? position, bool? paused) applyRemote;
  Socket? _socket;
  Timer? _heartbeat, _handshake;
  int _generation = 0, _clientCounter = 0, _nextCounter = 0, _serverCounter = 0;
  num? _serverTime;
  double _rtt = 0;
  bool connected = false, connecting = false, _applying = false;
  String? room, user, error;
  Set<String> users = {};

  static Uri endpoint(String input) {
    final value = input.trim();
    final address = value.contains('://')
        ? value
        : value.split(':').length > 2 && !value.startsWith('[')
        ? 'syncplay://[$value]'
        : 'syncplay://$value';
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.scheme != 'syncplay' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const {'', '/'}.contains(uri.path) ||
        uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
      throw const FormatException('Enter a Syncplay server and optional port.');
    }
    return uri;
  }

  Future<void> connect(
    Uri endpoint, {
    required String username,
    required String roomName,
    String password = '',
  }) async {
    disconnect();
    final generation = _generation;
    connecting = true;
    user = username;
    room = roomName;
    notifyListeners();
    try {
      final socket = await Socket.connect(
        endpoint.host,
        endpoint.hasPort ? endpoint.port : 8999,
        timeout: const Duration(seconds: 10),
      );
      if (generation != _generation) {
        socket.destroy();
        return;
      }
      _socket = socket;
      unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      socket.setOption(SocketOption.tcpNoDelay, true);
      _handshake = Timer(const Duration(seconds: 10), () {
        if (generation == _generation && connecting) {
          disconnect(reason: 'The Syncplay server did not respond.');
        }
      });
      unawaited(_read(socket, generation));
      _send({
        'Hello': {
          'username': username,
          'room': {'name': roomName},
          'version': '1.2.255',
          'realversion': '1.2.7',
          'features': <String, Object>{},
          if (password.isNotEmpty)
            'password': md5.convert(utf8.encode(password)).toString(),
        },
      });
    } catch (_) {
      if (generation == _generation) {
        disconnect(reason: 'Could not connect to the Syncplay server.');
      }
    }
  }

  Future<void> _read(Socket socket, int generation) async {
    try {
      await for (final line in _lines(
        socket.timeout(const Duration(seconds: 30)),
      )) {
        if (generation != _generation) return;
        final packet = jsonDecode(line);
        if (packet is! Map) throw const FormatException('Invalid packet');
        await _receive(packet, generation);
      }
      if (generation == _generation) {
        disconnect(reason: 'The Syncplay server closed the connection.');
      }
    } catch (_) {
      if (generation == _generation) {
        disconnect(reason: 'The Syncplay connection was interrupted.');
      }
    }
  }

  static Stream<String> _lines(Stream<Uint8List> stream) async* {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      var start = 0;
      while (start < chunk.length) {
        final newline = chunk.indexOf(10, start);
        final end = newline < 0 ? chunk.length : newline;
        if (bytes.length + end - start > 65536) {
          throw const FormatException('Syncplay packet is too large');
        }
        bytes.add(Uint8List.sublistView(chunk, start, end));
        if (newline >= 0) {
          final line = utf8.decode(bytes.takeBytes()).trim();
          if (line.isNotEmpty) yield line;
        }
        start = end + 1;
      }
    }
    if (bytes.isNotEmpty) throw const FormatException('Incomplete packet');
  }

  Future<void> _receive(Map packet, int generation) async {
    if (packet['Error'] case final Map failure) {
      final message = failure['message'];
      disconnect(
        reason: message is String && message.length <= 240
            ? message
            : 'The Syncplay server rejected this connection.',
      );
      return;
    }
    if (packet['Hello']
        case {
          'username': final String acceptedUser,
          'room': {'name': final String acceptedRoom},
        }
        when connecting) {
      if (acceptedUser.isEmpty || acceptedRoom.isEmpty) {
        throw const FormatException('Invalid Syncplay login');
      }
      _handshake?.cancel();
      connecting = false;
      connected = true;
      user = acceptedUser;
      room = acceptedRoom;
      users = {acceptedUser};
      _heartbeat = Timer.periodic(
        const Duration(seconds: 1),
        (_) => sendState(),
      );
      updateFile();
      sendState();
      notifyListeners();
    }
    if (!connected) return;
    if (packet['List'] case final Map rooms) {
      if (rooms[room] case final Map members) {
        users = members.keys.whereType<String>().toSet();
        notifyListeners();
      }
    }
    if (packet['Set'] case {'user': final Map updates}) {
      for (final entry in updates.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final data = entry.value as Map;
        if (data['room'] case {'name': final String name} when name != room) {
          continue;
        }
        if (data['event'] case {'left': true}) {
          users.remove(entry.key);
        } else if (data['event'] case {'joined': true}) {
          users.add(entry.key as String);
        }
      }
      notifyListeners();
    }
    if (packet['State'] case final Map state) {
      if (state['ping'] case final Map ping) {
        if (ping['latencyCalculation'] case final num stamp) {
          _serverTime = stamp;
        }
        if (ping['clientLatencyCalculation'] case final num stamp) {
          _rtt = (_now - stamp).clamp(0.0, 4.0);
        }
      }
      if (state['ignoringOnTheFly'] case final Map counters) {
        if (counters['server'] case final int counter when counter > 0) {
          _serverCounter = counter;
          _clientCounter = 0;
        } else if (counters['client'] == _clientCounter) {
          _clientCounter = 0;
        }
      }
      if (state['playstate'] case final Map play when _clientCounter == 0) {
        if (play['setBy'] != user &&
            (play['setBy'] != 'Nobody' || users.length > 1)) {
          final local = localPosition();
          final paused = play['paused'] is bool ? play['paused'] as bool : null;
          Duration? seek;
          if (play['position'] case final num position
              when position.isFinite && position >= 0 && position < 31536000) {
            final adjusted = position + (paused == false ? _rtt / 2 : 0);
            if (play['doSeek'] == true ||
                (local.position - adjusted).abs() > 2) {
              seek = Duration(milliseconds: (adjusted * 1000).round());
            }
          }
          final pause = paused == local.paused ? null : paused;
          if (seek != null || pause != null) {
            _applying = true;
            try {
              await applyRemote(seek, pause);
            } finally {
              if (generation == _generation) _applying = false;
            }
          }
        }
      }
      if (generation == _generation && _serverCounter != 0) sendState();
    }
  }

  double get _now => DateTime.now().millisecondsSinceEpoch / 1000;

  void updateFile() {
    if (!connected) return;
    _send({
      'Set': {'file': fileInfo()},
    });
    _send({'List': null});
  }

  void sendState({bool? seek, double? target, bool? paused}) {
    if (!connected || _applying) return;
    final position = localPosition();
    if (seek != null) _clientCounter = ++_nextCounter;
    _send({
      'State': {
        'ping': {
          'clientLatencyCalculation': _now,
          'clientRtt': _rtt,
          if (_serverTime != null) 'latencyCalculation': _serverTime,
        },
        if (_clientCounter == 0 || _serverCounter != 0 || seek != null)
          'playstate': {
            'position': target ?? position.position,
            'paused': paused ?? position.paused,
            'doSeek': ?seek,
          },
        if (_clientCounter != 0 || _serverCounter != 0)
          'ignoringOnTheFly': {
            if (_clientCounter != 0) 'client': _clientCounter,
            if (_serverCounter != 0) 'server': _serverCounter,
          },
      },
    });
    _serverCounter = 0;
  }

  void _send(Map<String, Object?> message) {
    try {
      _socket?.write('${jsonEncode(message)}\r\n');
    } catch (_) {
      disconnect(reason: 'The Syncplay connection was interrupted.');
    }
  }

  void disconnect({String? reason}) {
    _generation++;
    _socket?.destroy();
    _socket = null;
    _heartbeat?.cancel();
    _handshake?.cancel();
    _clientCounter = _nextCounter = _serverCounter = 0;
    _serverTime = null;
    _rtt = 0;
    _applying = connected = connecting = false;
    room = user = null;
    users = {};
    error = reason;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
