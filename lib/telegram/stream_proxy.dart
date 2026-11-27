import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models.dart';
import 'td_transport.dart';
import 'video_stream_cache.dart';

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
    this.videoCache,
    this.cancelPreload,
  });
  final TdRequest request;
  final Duration stallTimeout;
  final VideoStreamCache? videoCache;
  final Future<void> Function(int fileId)? cancelPreload;
  static const _videoWindow = 8 * 1024 * 1024;
  final Future<void> Function(int fileId)? releaseAudio;
  Future<void>? _cleanup;
  HttpServer? _server;
  Future<void>? _starting;
  Future<void>? _interruption;
  final _token = base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final Map<String, Track> _tracks = {};
  final Map<int, Completer<void>> _ranges = {};
  int? _preloadId;
  int _preloadSize = 0, _preloadLimit = 0, _preloadGeneration = 0;
  bool _preloadPaused = false;
  Future<void>? _preloadWork;
  final _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;
  final _expired = StreamController<Track>.broadcast();
  Stream<Track> get expiredReferences => _expired.stream;
  int _sequence = 0;
  int _sourceGeneration = 0;
  bool _closing = false, _acceptReads = true;
  bool get hasActiveSource => _tracks.isNotEmpty;
  bool get hasPreload => _preloadId != null && !_preloadPaused;
  bool isPreloading(int fileId) => _preloadId == fileId;
  bool isStreaming(int fileId) =>
      _tracks.values.any((track) => track.fileId == fileId);

  Future<Uri> uri(Track track) async {
    if (track.fileId == null || track.size <= 0) {
      throw StateError(
        'Telegram file size is unavailable. Refresh the Library.',
      );
    }
    final generation = ++_sourceGeneration;
    if (_interruption case final pending?) await pending;
    if (_closing || generation != _sourceGeneration) {
      throw StateError('Playback request superseded');
    }
    await (_starting ??= _start());
    if (isPreloading(track.fileId!)) {
      _preloadId = null;
      _preloadGeneration++;
    } else {
      unawaited(preload(null));
    }
    await _stopDownloads();
    if (_closing || generation != _sourceGeneration) {
      throw StateError('Playback request superseded');
    }
    final key = '${++_sequence}';
    // Old URLs expire when another item is opened; this bounds metadata retention.
    _tracks.clear();
    _tracks[key] = track;
    _acceptReads = true;
    return Uri.parse('http://127.0.0.1:${_server!.port}/$_token/$key');
  }

  /// TDLib takes a byte budget. Use the average bitrate for ten seconds,
  /// with a small fallback for unknown runtimes and a cap below the full file.
  Future<void> preload(Track? track, {Duration? duration}) {
    final runtime = duration ?? track?.duration ?? Duration.zero;
    final size = track?.size ?? 0;
    final estimate = runtime > Duration.zero
        ? size * 10000000 ~/ runtime.inMicroseconds
        : 1024 * 1024;
    final partial = runtime > const Duration(seconds: 10)
        ? size - min<int>(512 * 1024, max<int>(1, size ~/ 2))
        : size ~/ 2;
    final limit = min<int>(
      min<int>(16 * 1024 * 1024, partial),
      max<int>(1, estimate),
    );
    final id = _closing || limit <= 0 ? null : track?.fileId;
    if (id == _preloadId &&
        (id == null || limit == _preloadLimit && size == _preloadSize)) {
      return _preloadWork ?? Future<void>.value();
    }
    final previous = _preloadId;
    _preloadId = id;
    _preloadSize = size;
    _preloadLimit = limit;
    return _updatePreload(previous == id ? null : previous);
  }

  Future<void> pausePreload(bool paused) {
    if (_preloadPaused == paused) return Future<void>.value();
    _preloadPaused = paused;
    return _preloadId == null ? Future<void>.value() : _updatePreload(null);
  }

  Future<void> _updatePreload(int? release) {
    final id = _preloadId, size = _preloadSize, limit = _preloadLimit;
    final generation = ++_preloadGeneration;
    final pending = _preloadWork;
    bool current(int fileId) =>
        generation == _preloadGeneration && !_closing && !isStreaming(fileId);
    late final Future<void> work;
    work =
        () async {
          await pending;
          if (release != null &&
              !isStreaming(release) &&
              !isPreloading(release)) {
            await _releaseFile(release);
          }
          if (id == null || !current(id)) return;
          try {
            if (_preloadPaused) {
              if (cancelPreload case final cancel?) {
                await cancel(id);
              } else {
                await _cancelDownload(id);
              }
              return;
            }
            final cached = videoCache?.contiguousPrefix(id, size, limit) ?? 0;
            if (cached >= limit) return;
            final start = cached + max<int>(0, await _downloaded(id, cached));
            if (current(id) && start < limit) {
              await _download(id, start, limit - start, priority: 2);
            }
          } catch (_) {
            // Foreground playback can still open the next video.
          }
        }().whenComplete(() {
          if (identical(_preloadWork, work)) _preloadWork = null;
        });
    return _preloadWork = work;
  }

  Future<Json> _cancelDownload(int id) => request({
    '@type': 'cancelDownloadFile',
    'file_id': id,
    'only_if_pending': false,
  });

  Future<int> _downloaded(int id, int offset) async {
    final result = await request({
      '@type': 'getFileDownloadedPrefixSize',
      'file_id': id,
      'offset': offset,
    });
    return (result['size'] as num? ?? 0).toInt();
  }

  Future<Json> _download(int id, int offset, int limit, {int priority = 32}) =>
      request({
        '@type': 'downloadFile',
        'file_id': id,
        'priority': priority,
        'offset': offset,
        'limit': limit,
        'synchronous': false,
      });

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
    if (track == null || _closing || !_acceptReads) {
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
        _acceptReads &&
        !cancelled.isCompleted &&
        _ranges[fileId] == cancelled &&
        _tracks[segments[1]] != null;
    // Forward cancellation only to the pending operation. Racing every read
    // against the range's lifetime future retains completed chunk results.
    Completer<void>? pendingCancellation;
    unawaited(
      cancelled.future.then<void>((_) {
        final pending = pendingCancellation;
        if (pending != null && !pending.isCompleted) pending.complete();
      }),
    );
    Future<T> current<T>(Future<T> operation) async {
      final signal = pendingCancellation = Completer<void>();
      if (cancelled.isCompleted) signal.complete();
      try {
        return await Future.any([
          operation,
          signal.future.then<T>(
            (_) => throw StateError('Playback range superseded'),
          ),
        ]);
      } finally {
        pendingCancellation = null;
      }
    }

    try {
      final cache = videoCache;
      if (cache == null) {
        await current(_download(fileId, range.start, range.length));
      }
      var offset = range.start, downloadEnd = range.start;
      var retried = false;
      var deadline = DateTime.now().add(stallTimeout);
      Future<void> fillWindow() async {
        final length = min(_videoWindow, range.end - offset + 1);
        await current(_download(fileId, offset, length));
        downloadEnd = offset + length;
      }

      while (offset <= range.end && active()) {
        var count = min(VideoStreamCache.pageSize, range.end - offset + 1);
        if (cache != null) {
          count = min(
            count,
            VideoStreamCache.pageSize - offset % VideoStreamCache.pageSize,
          );
          final hit = await current(
            cache.read(fileId, track.size, offset, count),
          );
          if (!active()) break;
          if (hit != null) {
            response.add(hit);
            await current(response.flush());
            offset += hit.length;
            deadline = DateTime.now().add(stallTimeout);
            continue;
          }
        }
        // Check TDLib before moving the download offset. The next episode
        // may already have this range, even if its download was parked.
        final available = await current(_downloaded(fileId, offset));
        if (!active()) break;
        if (cache != null &&
            (available <= 0 && offset >= downloadEnd ||
                offset < downloadEnd &&
                    downloadEnd < range.end + 1 &&
                    downloadEnd - offset <= 512 * 1024)) {
          await fillWindow();
          if (!active()) break;
        }
        if (available <= 0) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Telegram buffer stalled');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        count = min(count, available);
        Uint8List bytes;
        try {
          final data = await current(
            request({
              '@type': 'readFilePart',
              'file_id': fileId,
              'offset': offset,
              'count': count,
            }),
          );
          if (!active()) break;
          bytes = base64Decode(data['data'] as String);
          if (bytes.length != count) throw const FormatException('Short read');
        } catch (_) {
          if (cache == null || retried || !active()) rethrow;
          retried = true;
          await fillWindow();
          continue;
        }
        retried = false;
        cache?.store(fileId, track.size, offset, bytes);
        response.add(bytes);
        await current(response.flush());
        offset += count;
        deadline = DateTime.now().add(stallTimeout);
      }
    } on SocketException {
      // The player closes its old request when seeking or changing tracks.
    } on HttpException {
      // A disconnected playback request must not stop the server.
    } catch (failure) {
      if (active() && !_errors.isClosed) {
        final message = failure is TdException
            ? failure.message.toLowerCase()
            : '';
        if (videoCache != null &&
            (message.contains('file_reference') ||
                message.contains('file reference') ||
                message.contains('file_id') ||
                message.contains('file id'))) {
          _expired.add(track);
        } else {
          _errors.add('Telegram could not fill the playback buffer.');
        }
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
    await _expired.close();
  }

  /// Unblocks the player without deleting the Telegram buffer. The next
  /// source starts a new listener after the player has released this one.
  Future<void> interrupt() =>
      _interruption ??= _interrupt().whenComplete(() => _interruption = null);

  Future<void> _interrupt() async {
    ++_sourceGeneration;
    try {
      await _starting;
    } finally {
      final server = _server;
      _server = null;
      _starting = null;
      _cancelRanges();
      await server?.close(force: true);
    }
  }

  Future<void> stop({bool keepPreload = false}) async {
    ++_sourceGeneration;
    if (keepPreload) {
      unawaited(pausePreload(true));
      await _stopDownloads();
      return;
    }
    final preloadCleanup = preload(null);
    await _stopDownloads();
    await preloadCleanup;
  }

  Future<void> _stopDownloads() {
    final files = _tracks.values.map((t) => t.fileId).whereType<int>().toSet();
    _tracks.clear();
    _cancelRanges();
    // New sources wait for earlier cleanup, including a quick replay of the
    // same file. A late delete must never remove a new playback buffer.
    late final Future<void> cleanup;
    cleanup = (_cleanup ?? Future<void>.value())
        .then((_) async {
          for (final id in files) {
            if (!isPreloading(id)) await _releaseFile(id);
          }
        })
        .whenComplete(() {
          // Keep only pending work. Retaining a completed future also retains its
          // originating zone, which may already have stopped running during tests.
          if (identical(_cleanup, cleanup)) _cleanup = null;
        });
    return _cleanup = cleanup;
  }

  Future<void> _releaseFile(int id) async {
    if (releaseAudio case final release?) {
      try {
        await release(id);
      } catch (_) {
        // The Telegram session may have closed.
      }
      return;
    }
    for (final operation in [
      {'@type': 'cancelDownloadFile', 'file_id': id, 'only_if_pending': false},
      {'@type': 'deleteFile', 'file_id': id},
    ]) {
      try {
        await request(operation);
      } catch (_) {
        // Startup cleanup retries files left after disconnection.
      }
    }
  }

  void endVideoReads() {
    _acceptReads = false;
    _cancelRanges();
  }

  void _cancelRanges() {
    for (final cancelled in _ranges.values) {
      if (!cancelled.isCompleted) cancelled.complete();
    }
    _ranges.clear();
  }
}
