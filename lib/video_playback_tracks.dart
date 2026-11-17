part of 'video_playback.dart';

extension _PlaybackTracks on _VideoPlaybackState {
  Future<void> _queueTrackUpdate(Future<void> Function() action) {
    final generation = _trackGeneration;
    return _trackUpdates = _trackUpdates
        .then((_) async {
          if (!_canPlay ||
              !_acceptVideoParams ||
              generation != _trackGeneration) {
            return;
          }
          await action();
        })
        .catchError((Object _) {
          // A missing/unsupported track must not interrupt video playback.
          debugPrint('Video playback: could not select a track.');
        });
  }

  Future<void> _preferVideoTracks() => _queueTrackUpdate(() async {
    final player = _player!;
    final channel = _data.channels[_source.channelId];
    if (_automaticAudio) {
      final audio = preferredVideoAudio(
        player.state.tracks.audio,
        choice: channel?.audio,
      );
      if (audio != null && audio.id != player.state.track.audio.id) {
        await player.setAudioTrack(audio);
      }
    }
    if (!_canPlay || !_acceptVideoParams) return;
    if (_automaticSubtitles) {
      final subtitle = preferredVideoSubtitle(
        player.state.tracks.subtitle,
        choice: channel?.subtitles,
      );
      if (subtitle != null && subtitle.id != player.state.track.subtitle.id) {
        await player.setSubtitleTrack(subtitle);
      }
    }
  });

  Future<void> _selectAudioTrack(mpv.AudioTrack track) {
    _automaticAudio = track.id == 'auto';
    return _queueTrackUpdate(() async {
      if (!track.uri &&
          (track.id == 'no' ||
              track.id == 'auto' ||
              int.tryParse(track.id) != null)) {
        _rememberChannelSettings(
          (settings) => settings.audio = track.id == 'auto'
              ? null
              : VideoTrackChoice(track.id, track.title, track.language),
        );
      }
      final selected = track.id == 'auto'
          ? preferredVideoAudio(_player!.state.tracks.audio) ?? track
          : track;
      await _player!.setAudioTrack(selected);
    });
  }

  Future<void> _selectSubtitleTrack(mpv.SubtitleTrack track) {
    _automaticSubtitles = track.id == 'auto';
    return _queueTrackUpdate(() async {
      if (!track.uri &&
          !track.data &&
          (track.id == 'no' ||
              track.id == 'auto' ||
              int.tryParse(track.id) != null)) {
        _rememberChannelSettings(
          (settings) => settings.subtitles = track.id == 'auto'
              ? null
              : VideoTrackChoice(track.id, track.title, track.language),
        );
      }
      final selected = track.id == 'auto'
          ? preferredVideoSubtitle(_player!.state.tracks.subtitle) ?? track
          : track;
      await _player!.setSubtitleTrack(selected);
    });
  }
}
