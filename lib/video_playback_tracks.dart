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
    if (_automaticAudio) {
      final audio = preferredVideoAudio(player.state.tracks.audio);
      if (audio != null && audio.id != player.state.track.audio.id) {
        await player.setAudioTrack(audio);
      }
    } else if (_qualityAudio case final mpv.AudioTrack selected) {
      final audio =
          _matchingAudio(selected, player.state.tracks.audio) ??
          preferredVideoAudio(player.state.tracks.audio);
      if (audio != null && audio.id != player.state.track.audio.id) {
        await player.setAudioTrack(audio);
      }
    }
    if (!_canPlay || !_acceptVideoParams) return;
    if (_automaticSubtitles) {
      final subtitle = preferredVideoSubtitle(player.state.tracks.subtitle);
      if (subtitle != null && subtitle.id != player.state.track.subtitle.id) {
        await player.setSubtitleTrack(subtitle);
      }
    } else if (_qualitySubtitle case final mpv.SubtitleTrack selected) {
      final subtitle =
          _matchingSubtitle(selected, player.state.tracks.subtitle) ??
          preferredVideoSubtitle(player.state.tracks.subtitle);
      if (subtitle != null && subtitle.id != player.state.track.subtitle.id) {
        await player.setSubtitleTrack(subtitle);
      }
    }
    if (!_canPlay || !_acceptVideoParams) return;
    if (_qualitySecondarySubtitle case final mpv.SubtitleTrack selected) {
      final subtitle = _matchingSubtitle(
        selected,
        player.state.tracks.subtitle,
      );
      if (subtitle != null && subtitle.id != _secondarySubtitle) {
        await _native.setProperty('secondary-sid', subtitle.id);
        _secondarySubtitle = subtitle.id;
      }
    }
  });

  Future<void> _selectAudioTrack(mpv.AudioTrack track) {
    _qualityAudio = null;
    _automaticAudio = track.id == 'auto';
    return _queueTrackUpdate(() async {
      final selected = track.id == 'auto'
          ? preferredVideoAudio(_player!.state.tracks.audio) ?? track
          : track;
      await _player!.setAudioTrack(selected);
    });
  }

  Future<void> _selectSubtitleTrack(mpv.SubtitleTrack track) {
    _qualitySubtitle = null;
    _automaticSubtitles = track.id == 'auto';
    return _queueTrackUpdate(() async {
      final selected = track.id == 'auto'
          ? preferredVideoSubtitle(_player!.state.tracks.subtitle) ?? track
          : track;
      await _player!.setSubtitleTrack(selected);
    });
  }
}
