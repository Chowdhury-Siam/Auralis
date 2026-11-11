import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auralis/video_syncplay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Syncplay exchanges media, applies remote changes and sends local seeks',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peer = Completer<Socket>();
      final published = Completer<Map>();
      final outgoingSeek = Completer<Map>();
      final subscription = server.listen((socket) {
        peer.complete(socket);
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final packet = jsonDecode(line) as Map;
              if (packet['Hello'] case final Map hello) {
                socket.write('${jsonEncode({'Hello': hello})}\r\n');
              }
              if (packet['Set'] case {'file': final Map file}) {
                if (!published.isCompleted) published.complete(file);
              }
              if (packet['State'] case {'playstate': final Map state}
                  when state['doSeek'] == true && !outgoingSeek.isCompleted) {
                outgoingSeek.complete(state);
              }
            });
      });
      addTearDown(() async {
        if (peer.isCompleted) (await peer.future).destroy();
        await subscription.cancel();
        await server.close();
      });

      final remote = Completer<(Duration?, bool?)>();
      final room = VideoSyncplay(
        localPosition: () => (position: 3, paused: false),
        fileInfo: () => {'name': 'Sample episode', 'duration': 120},
        applyRemote: (position, paused) async =>
            remote.complete((position, paused)),
      );
      addTearDown(room.dispose);
      final endpoint = VideoSyncplay.endpoint('127.0.0.1:${server.port}');
      await room.connect(endpoint, username: 'Siam', roomName: 'test room');
      expect(await published.future.timeout(const Duration(seconds: 3)), {
        'name': 'Sample episode',
        'duration': 120,
      });
      expect(room.connected, isTrue);
      expect(room.room, 'test room');
      final socket = await peer.future;
      socket.write('{"State":{"playstate":{"setBy":"Other","paused":true,');
      await socket.flush();
      socket.write('"position":16,"doSeek":true}}}\r\n');
      expect(await remote.future.timeout(const Duration(seconds: 3)), (
        const Duration(seconds: 16),
        true,
      ));
      await Future<void>.delayed(Duration.zero);
      room.sendState(seek: true, target: 28);
      expect(
        (await outgoingSeek.future.timeout(
          const Duration(seconds: 3),
        ))['position'],
        28,
      );
      room.disconnect();
      expect(room.connected, isFalse);
    },
  );

  test('Syncplay address validation accepts IPv6 and rejects credentials', () {
    expect(VideoSyncplay.endpoint('[::1]:8999').port, 8999);
    expect(
      () => VideoSyncplay.endpoint('https://example.com'),
      throwsFormatException,
    );
    expect(
      () => VideoSyncplay.endpoint('user:password@example.com:8999'),
      throwsFormatException,
    );
  });
}
