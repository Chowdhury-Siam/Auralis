import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'player.dart';
import 'telegram/embedded_cover.dart';

/// The existing controller remains the source of truth for UI and system controls.
class AndroidAudioHandler extends BaseAudioHandler {
  AndroidAudioHandler(
    this.player, {
    this.loadArtwork,
    this.artworkDirectory,
    this.artworkChanges,
  }) {
    player.addListener(_sync);
    artworkChanges?.addListener(_sync);
    _sync();
  }
  final PlayerController player;
  final Future<Uint8List?>? Function(Track)? loadArtwork;
  final Directory? artworkDirectory;
  final Listenable? artworkChanges;
  List<Track> _tracks = [];
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _closed = false;
  Object? _artworkIdentity;
  String? _artworkTrackId;
  Uri? _artUri;
  int _artworkGeneration = 0;

  void _syncArtwork() {
    if (artworkDirectory == null) return;
    final track = player.current;
    Future<Uint8List?>? cover;
    try {
      cover = track == null ? null : loadArtwork?.call(track);
    } catch (_) {
      // A failed metadata read must never interrupt system controls.
    }
    final identity = (track?.id, track?.coverPreview, cover);
    if (identity == _artworkIdentity) return;
    _artworkIdentity = identity;
    final generation = ++_artworkGeneration;
    if (_artworkTrackId != track?.id) _artUri = null;
    _artworkTrackId = track?.id;
    if (track != null) {
      unawaited(_loadArtwork(track, cover, generation));
    }
  }

  Future<void> _loadArtwork(
    Track track,
    Future<Uint8List?>? cover,
    int generation,
  ) async {
    // Attach the error handler before waiting on the preview's disk write.
    final safeCover = cover?.then<Uint8List?>(
      (bytes) => bytes,
      onError: (Object _, StackTrace _) => null,
    );
    bool active() => !_closed && generation == _artworkGeneration;
    Future<void> publish(Uint8List? bytes) async {
      if (!active() ||
          bytes == null ||
          bytes.length > maxCoverBytes ||
          !isCoverImage(bytes)) {
        return;
      }
      try {
        final directory = artworkDirectory!;
        await directory.create(recursive: true);
        if (!active()) return;
        // A content-derived path refreshes Android's image cache on upgrades.
        final file = File(p.join(directory.path, '${sha256.convert(bytes)}.art'));
        if (!await file.exists()) {
          final pending = File('${file.path}.$generation.tmp');
          try {
            await pending.writeAsBytes(bytes, flush: true);
            await pending.rename(file.path);
          } finally {
            if (await pending.exists()) await pending.delete();
          }
        }
        if (!active()) return;
        if (_artUri != file.uri) {
          _artUri = file.uri;
          mediaItem.add(_item(player.current!));
          queue.add(_tracks.map(_item).toList());
        }
        // Keep the app-private image cache bounded across app restarts.
        final files = await directory
            .list()
            .where((entry) => entry is File &&
                RegExp(r'^[a-f0-9]{64}\.art$').hasMatch(p.basename(entry.path)))
            .cast<File>()
            .toList();
        final dated = [
          for (final entry in files) (entry, await entry.lastModified()),
        ]..sort((a, b) => a.$2.compareTo(b.$2));
        var excess = files.length - 32;
        for (final (old, _) in dated) {
          if (!active() || excess <= 0) break;
          if (old.uri != _artUri) {
            await old.delete();
            excess--;
          }
        }
      } catch (_) {
        // Keep a usable preview (or no art) if storage is unavailable.
      }
    }
    await publish(track.coverPreview);
    await publish(await safeCover);
  }

  void handleInterruptions(AudioSession session) {
    _subscriptions.addAll([
      session.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(pause());
      }),
      session.becomingNoisyEventStream.listen((_) => unawaited(pause())),
    ]);
  }

  MediaItem _item(Track track) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.source,
    artUri: track.id == player.current?.id ? _artUri : null,
    duration:
        track.id == player.current?.id && player.audio.duration > Duration.zero
        ? player.audio.duration
        : track.duration,
  );

  void _sync() {
    if (_closed) return;
    _syncArtwork();
    if (!listEquals(_tracks, player.queue)) {
      _tracks = List.of(player.queue);
      queue.add(_tracks.map(_item).toList());
    }
    final audio = player.audio, track = player.current;
    final item = track == null ? null : _item(track);
    final previous = mediaItem.value;
    // MediaItem equality compares IDs only; the native duration can arrive later.
    if (previous?.id != item?.id ||
        previous?.duration != item?.duration ||
        previous?.title != item?.title ||
        previous?.artist != item?.artist ||
        previous?.album != item?.album ||
        previous?.artUri != item?.artUri) {
      mediaItem.add(item);
    }
    final processing = track == null
        ? AudioProcessingState.idle
        : player.loading
        ? AudioProcessingState.loading
        : audio.error != null
        ? AudioProcessingState.error
        : audio.buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready;
    final old = playbackState.value;
    final index = track == null ? null : player.index;
    // The system projects the position between updates; don't rebuild its notification each tick.
    if (old.processingState == processing &&
        old.playing == audio.playing &&
        old.queueIndex == index &&
        (old.position - audio.position).inMilliseconds.abs() < 500 &&
        (old.bufferedPosition - audio.buffered).inMilliseconds.abs() < 1000) {
      return;
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          audio.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          const MediaControl(
            androidIcon: 'drawable/ic_media_stop_rounded',
            label: 'Stop',
            action: MediaAction.stop,
          ),
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processing,
        playing: track != null && audio.playing,
        updatePosition: audio.position,
        bufferedPosition: audio.buffered,
        queueIndex: index,
        errorCode: audio.error == null ? null : 1,
        errorMessage: audio.error,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (player.current != null &&
        !player.restoringData &&
        !player.audio.playing) {
      await player.audio.toggle();
    }
  }

  @override
  Future<void> pause() async {
    if (player.audio.playing) await player.audio.toggle();
    await player.flushListeningStats();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> skipToNext() => player.next();
  @override
  Future<void> skipToPrevious() => player.previous();
  @override
  Future<void> skipToQueueItem(int index) => player.playAt(index);
  @override
  Future<void> stop() => player.clear();
  @override
  Future<void> onTaskRemoved() => stop();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_artworkGeneration;
    player.removeListener(_sync);
    artworkChanges?.removeListener(_sync);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }
}
