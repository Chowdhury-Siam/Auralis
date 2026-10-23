import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'player.dart';

/// The existing controller remains the source of truth for UI and system controls.
class AndroidAudioHandler extends BaseAudioHandler {
  AndroidAudioHandler(this.player) {
    player.addListener(_sync);
    _sync();
  }
  final PlayerController player;
  List<Track> _tracks = [];
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _closed = false;

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
    duration:
        track.id == player.current?.id && player.audio.duration > Duration.zero
        ? player.audio.duration
        : track.duration,
  );

  void _sync() {
    if (_closed) return;
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
        previous?.album != item?.album) {
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
          MediaControl.stop,
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
    _closed = true;
    player.removeListener(_sync);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }
}
