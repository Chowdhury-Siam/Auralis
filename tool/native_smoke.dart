// Runs without a Flutter Windows runner. Never uses a real Telegram account.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart' hide Track;
import 'package:auralis/models.dart';
import 'package:auralis/telegram/stream_proxy.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/telegram/td_transport.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'Usage: dart run tool/native_smoke.dart <libmpv.dll> <tdjson.dll>',
    );
  }
  final dir = await Directory.systemTemp.createTemp('auralis-native-smoke-');
  final report = <String, dynamic>{};
  Player? player;
  TdTransport? td;
  TelegramStreamProxy? proxy;
  try {
    final vault = SecretVault(File('${dir.path}/secrets.dpapi'));
    await vault.write({
      'test': 'round-trip',
      'key': SecretVault.newDatabaseKey(),
    });
    if ((await vault.read())['test'] != 'round-trip') {
      throw StateError('DPAPI round-trip failed');
    }
    report['dpapi'] = 'encrypted credential round-trip passed';
    td = TdTransport();
    await td.start(File(arguments[1]).absolute.path);
    final state = await td.request({'@type': 'getAuthorizationState'});
    if (state['@type'] != 'authorizationStateWaitTdlibParameters') {
      throw StateError('Unexpected TDLib auth state');
    }
    final version = await td.request({'@type': 'getOption', 'name': 'version'});
    report['tdlib'] = {
      'version': version['value'],
      'initialAuthState': state['@type'],
    };
    await td.close();
    td = null;
    final wave = File('${dir.path}/test.wav');
    await wave.writeAsBytes(makeWave());
    MediaKit.ensureInitialized(libmpv: File(arguments[0]).absolute.path);
    player = Player(configuration: const PlayerConfiguration(muted: true));
    final native = player.platform as NativePlayer;
    // Null audio output permits playback verification on headless CI workers.
    await native.setProperty('ao', 'null');
    // Exercise WASAPI device monitoring even with null audio output on CI.
    final devices = await native.getProperty('audio-device-list');
    if (devices.isEmpty) throw StateError('Native audio-device query failed');
    report['deviceMonitoring'] = 'audio-device-list queried before shutdown';
    await player.open(Media(wave.path));
    await waitFor(
      () =>
          player!.state.position.inMilliseconds > 200 &&
          player.state.duration.inSeconds >= 11,
    );
    final position = player.state.position.inMilliseconds;
    final appliedVolumes = <double>[];
    for (final volume in [35.0, 80.0]) {
      await player.setVolume(volume);
      final actual = double.parse(await native.getProperty('volume'));
      if ((actual - volume).abs() > 0.01 || !player.state.playing) {
        throw StateError('Native volume did not change during playback');
      }
      appliedVolumes.add(actual);
    }
    report['volume'] = {
      'duringPlayback': appliedVolumes,
      'output': 'null (muted)',
    };
    await player.pause();
    await player.seek(const Duration(seconds: 7));
    await player.play();
    await waitFor(() => player!.state.position.inMilliseconds >= 6900);
    report['libmpv'] = {
      'durationSeconds': player.state.duration.inSeconds,
      'playedPositionMs': position,
      'seekPositionMs': player.state.position.inMilliseconds,
      'output': 'null (muted)',
    };
    final bytes = await wave.readAsBytes();
    var requests = 0;
    proxy = TelegramStreamProxy((json) async {
      requests++;
      switch (json['@type']) {
        case 'downloadFile':
          return {};
        case 'getFileDownloadedPrefixSize':
          return {'size': bytes.length - (json['offset'] as int)};
        case 'readFilePart':
          final offset = json['offset'] as int;
          return {
            'data': base64Encode(
              bytes.sublist(offset, offset + (json['count'] as int)),
            ),
          };
        default:
          throw StateError('Unexpected stream request');
      }
    });
    final uri = await proxy.uri(
      Track(
        id: 'test',
        title: 'Generated tone',
        artist: 'Test',
        source: 'Simulated TDLib cache',
        fileId: 1,
        size: bytes.length,
        mime: 'audio/wav',
      ),
    );
    await player.open(Media(uri.toString()));
    await waitFor(() => player!.state.position.inMilliseconds > 200);
    await player.seek(const Duration(seconds: 4));
    await waitFor(() => player!.state.position.inMilliseconds >= 3900);
    report['loopbackPlayback'] = {
      'tdSource': 'simulated cache (no account)',
      'requests': requests,
      'seekPositionMs': player.state.position.inMilliseconds,
    };
    stderr.writeln('Native shutdown cycle 1/4 (loopback playback)');
    await player.dispose();
    player = null;
    // Recreate and dispose during active seeking to exercise queued callbacks.
    for (var cycle = 0; cycle < 3; cycle++) {
      player = Player(configuration: const PlayerConfiguration(muted: true));
      await (player.platform as NativePlayer).setProperty('ao', 'null');
      await player.open(Media(wave.path));
      await waitFor(() => player!.state.position.inMilliseconds > 50);
      await player.seek(const Duration(seconds: 4));
      stderr.writeln('Native shutdown cycle ${cycle + 2}/4 (active seek)');
      await player.dispose();
      player = null;
    }
    report['nativeShutdown'] = {'completed': true, 'cycles': 4};
  } finally {
    if (player != null) await player.dispose();
    if (td != null) await td.close();
    if (proxy != null) await proxy.close();
    await dir.delete(recursive: true);
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Native playback did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Uint8List makeWave() {
  const rate = 44100, samples = rate * 12;
  final bytes = Uint8List(44 + samples * 2), data = ByteData(44 + samples * 2);
  void text(int offset, String value) =>
      bytes.setAll(offset, ascii.encode(value));
  text(0, 'RIFF');
  text(8, 'WAVE');
  text(12, 'fmt ');
  text(36, 'data');
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(2 * pi * 440 * i / rate) * 2000).round(),
      Endian.little,
    );
  }
  final view = data.buffer.asUint8List();
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != 0) view[i] = bytes[i];
  }
  return view;
}
