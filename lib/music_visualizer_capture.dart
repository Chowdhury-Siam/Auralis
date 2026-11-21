import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Foreground-only output analysis, separate from Auralis's playback backend.
/// Serializes permission/start/stop and never queues overlapping sample reads.
class MusicVisualizerCapture {
  MusicVisualizerCapture({
    MethodChannel? channel,
    required this.onFrame,
    required this.onError,
    this.canRead,
  }) : _channel = channel ?? const MethodChannel('app.auralis/visualizer');

  final MethodChannel _channel;
  final void Function(Uint8List samples, int sampleRate, String format) onFrame;
  final void Function(String message) onError;
  final bool Function()? canRead;
  Timer? _timer;
  Future<void> _pending = Future.value();
  bool _desired = false, _disposed = false, _reading = false;
  int _generation = 0, _fps = 30;

  void setActive(bool active, {int fps = 30}) {
    if (_disposed || (_desired == active && _fps == fps)) return;
    _fps = fps.clamp(20, 60);
    _desired = active;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    _pending = _pending.then((_) async {
      try {
        await _channel.invokeMethod<void>('stop');
        if (!_desired || _disposed || generation != _generation) return;
        await _channel.invokeMethod<void>('start');
        if (!_desired || _disposed || generation != _generation) {
          await _channel.invokeMethod<void>('stop');
          return;
        }
        _timer = Timer.periodic(
          Duration(microseconds: (1000000 / _fps).ceil()),
          (_) => unawaited(_read(generation)),
        );
      } catch (error) {
        if (!_disposed && generation == _generation) {
          _desired = false;
          onError(
            error is PlatformException && error.message != null
                ? error.message!
                : 'Output audio analysis is unavailable on this device.',
          );
        }
      }
    });
  }

  Future<void> _read(int generation) async {
    if (_reading || !_desired || _disposed || canRead?.call() == false) return;
    _reading = true;
    try {
      final frame = await _channel.invokeMapMethod<String, dynamic>('read');
      if (_disposed || generation != _generation || frame == null) return;
      final samples = frame['samples'], rate = frame['rate'];
      final format = frame['format'] ?? 'uint8';
      final sampleBytes = switch (format) {
        'uint8' => 1,
        'float32le' => 4,
        _ => 0,
      };
      if (sampleBytes > 0 &&
          samples is Uint8List &&
          samples.length >= 128 * sampleBytes &&
          samples.length <= 4096 * sampleBytes &&
          samples.length % sampleBytes == 0 &&
          rate is int &&
          rate >= 8000 &&
          rate <= 192000) {
        onFrame(samples, rate, format);
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        setActive(false);
        onError(
          'Output audio analysis stopped. Check your output device and retry.',
        );
      }
    } finally {
      _reading = false;
    }
  }

  @visibleForTesting
  Future<void> get settled => _pending;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _desired = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    await _pending;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Missing plugins or a closing engine must not interrupt audio playback.
    }
  }
}
