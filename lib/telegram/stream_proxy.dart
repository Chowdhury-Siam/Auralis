import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models.dart';
import 'td_transport.dart';

class ByteRange {
  const ByteRange(this.start, this.end);
  final int start, end;
  int get length => end - start + 1;

  static ByteRange parse(String? header, int size) {
    if (size <= 0) throw const FormatException('Unknown file size');
    if (header == null) return ByteRange(0, size - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      throw const FormatException('Only one byte range is supported');
    }
    if (match[1]!.isEmpty) {
      final suffix = int.parse(match[2]!);
      if (suffix <= 0) throw const FormatException('Invalid suffix');
      return ByteRange(max(0, size - suffix), size - 1);
    }
    final start = int.parse(match[1]!);
    final end = match[2]!.isEmpty
        ? size - 1
        : min(size - 1, int.parse(match[2]!));
    if (start >= size || end < start) {
      throw const FormatException('Range out of bounds');
    }
    return ByteRange(start, end);
  }
}

/// A capability URL on IPv4 loopback. No account data or remote file IDs are public.
/// Relays original file bytes without transcoding or adaptive bitrate reduction.
class TelegramStreamProxy {
  TelegramStreamProxy(
    this.request, {
    this.stallTimeout = const Duration(seconds: 45),
    this.releaseAudio,
  });
  final TdRequest request;
  final Duration stallTimeout;
  final Future<void> Function(int fileId)? releaseAudio;
  Future<void> _cleanup = Future.value();
  HttpServer? _server;
  Future<void>? _starting;
  final _token = base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final Map<String, Track> _tracks = {};
  final Map<int, Completer<void>> _ranges = {};
  final _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;
  int _sequence = 0;
  int _sourceGeneration = 0;
  bool _closing = false;
  bool get hasActiveSource => _tracks.isNotEmpty;
  bool isStreaming(int fileId) =>
      _tracks.values.any((track) => track.fileId == fileId);

  Future<Uri> uri(Track track) async {
    if (track.fileId == null || track.size <= 0) {
      throw StateError(
        'Telegram file size is unavailable. Refresh the Library.',
      );
    }
    final generation = ++_sourceGeneration;
    await (_starting ??= _start());
    await _stopDownloads();
    if (_closing || generation != _sourceGeneration) {
      throw StateError('Playback request superseded');
    }
    final key = '${++_sequence}';
    // Old URLs expire when another item is opened; this bounds metadata retention.
    _tracks.clear();
    _tracks[key] = track;
    return Uri.parse('http://127.0.0.1:${_server!.port}/$_token/$key');
  }

  Future<void> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closing) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.listen((r) => unawaited(_handle(r)));
  }

  Future<void> _handle(HttpRequest incoming) async {
    final response = incoming.response;
    final segments = incoming.uri.pathSegments;
    final track = segments.length == 2 && segments[0] == _token
        ? _tracks[segments[1]]
        : null;
    if (track == null || _closing) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    if (incoming.method != 'GET' && incoming.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set('Cache-Control', 'no-store');
    try {
      response.headers.contentType = ContentType.parse(track.mime);
    } on FormatException {
      response.headers.contentType = ContentType.binary;
    }
    response.headers.set('X-Content-Type-Options', 'nosniff');
    late ByteRange range;
    try {
      range = ByteRange.parse(incoming.headers.value('range'), track.size);
    } on FormatException {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set('Content-Range', 'bytes */${track.size}');
      await response.close();
      return;
    }
    response.statusCode = incoming.headers.value('range') != null
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    response.contentLength = range.length;
    if (response.statusCode == HttpStatus.partialContent) {
      response.headers.set(
        'Content-Range',
        'bytes ${range.start}-${range.end}/${track.size}',
      );
    }
    if (incoming.method == 'HEAD') {
      await response.close();
      return;
    }

    final fileId = track.fileId!;
    // A seek owns the new download offset immediately. An abandoned socket or
    // pending cache read from an old range must never hold up the new request.
    final previous = _ranges[fileId];
    if (previous != null && !previous.isCompleted) previous.complete();
    final cancelled = Completer<void>();
    _ranges[fileId] = cancelled;
    void cancel() {
      if (!cancelled.isCompleted) cancelled.complete();
    }

    var disconnected = false;
    unawaited(
      response.done.then<void>(
        (_) {
          disconnected = true;
          cancel();
        },
        onError: (Object _) {
          disconnected = true;
          cancel();
        },
      ),
    );
    bool active() =>
        !disconnected &&
        !_closing &&
        !cancelled.isCompleted &&
        _ranges[fileId] == cancelled &&
        _tracks[segments[1]] != null;
    Future<T> current<T>(Future<T> operation) => Future.any([
      operation,
      cancelled.future.then<T>(
        (_) => throw StateError('Playback range superseded'),
      ),
    ]);
    try {
      // TDLib's newest downloadFile offset replaces the previous one. Old reads
      // may finish later, but cannot retarget the download or report a seek error.
      await current(
        request({
          '@type': 'downloadFile',
          'file_id': fileId,
          'priority': 32,
          'offset': range.start,
          'limit': range.length,
          'synchronous': false,
        }),
      );
      var offset = range.start;
      var deadline = DateTime.now().add(stallTimeout);
      while (offset <= range.end && active()) {
        final prefix = await current(
          request({
            '@type': 'getFileDownloadedPrefixSize',
            'file_id': fileId,
            'offset': offset,
          }),
        );
        if (!active()) break;
        final available = (prefix['size'] as num).toInt();
        if (available <= 0) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Telegram buffer stalled');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        final count = min(128 * 1024, min(available, range.end - offset + 1));
        final data = await current(
          request({
            '@type': 'readFilePart',
            'file_id': fileId,
            'offset': offset,
            'count': count,
          }),
        );
        if (!active()) break;
        final bytes = base64Decode(data['data'] as String);
        if (bytes.length != count) {
          throw StateError('Incomplete Telegram cache read');
        }
        response.add(bytes);
        await current(response.flush());
        offset += count;
        deadline = DateTime.now().add(stallTimeout);
      }
    } on SocketException {
      // The player closes its old request when seeking or changing tracks.
    } on HttpException {
      // A disconnected playback request must not stop the server.
    } catch (_) {
      if (active() && !_errors.isClosed) {
        _errors.add(
          'Telegram could not fill the audio buffer. Try the track again.',
        );
      }
    } finally {
      cancel();
      if (_ranges[fileId] == cancelled) _ranges.remove(fileId);
      try {
        await response.close();
      } catch (_) {
        /* client already disconnected */
      }
    }
  }

  Future<void> close() async {
    _closing = true;
    await _server?.close(force: true);
    await stop();
    await _errors.close();
  }

  Future<void> stop() async {
    ++_sourceGeneration;
    await _stopDownloads();
  }

  Future<void> _stopDownloads() {
    final files = _tracks.values.map((t) => t.fileId).whereType<int>().toSet();
    _tracks.clear();
    for (final cancelled in _ranges.values) {
      if (!cancelled.isCompleted) cancelled.complete();
    }
    _ranges.clear();
    // New sources wait for earlier cleanup, including a quick replay of the
    // same file. A late delete must never remove a new playback buffer.
    return _cleanup = _cleanup.then((_) async {
      for (final id in files) {
        if (releaseAudio case final release?) {
          try {
            await release(id);
          } catch (_) {
            /* Disconnect or logout may already have closed the file cache. */
          }
          continue;
        }
        for (final operation in [
          {'@type': 'cancelDownloadFile', 'file_id': id, 'only_if_pending': false},
          {'@type': 'deleteFile', 'file_id': id},
        ]) {
          try {
            await request(operation);
          } catch (_) {
            /* Startup cleanup retries files left behind after disconnection. */
          }
        }
      }
    });
  }
}
