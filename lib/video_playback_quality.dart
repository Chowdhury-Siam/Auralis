part of 'video_playback.dart';

extension _PlaybackQuality on _VideoPlaybackState {
  String get _videoQualityLabel =>
      _selectedVideoQuality?.label ?? _originalVideoQualityLabel;

  String get _originalVideoQualityLabel {
    final track = _source.telegram;
    return track == null
        ? videoResolutionLabel(_player?.state.width, _player?.state.height)
        : videoResolutionLabel(track.videoWidth, track.videoHeight);
  }

  Future<void> _qualityPanel(BuildContext context) async {
    if (!_canPlay || _opening || _player == null) return;
    final sourceId = _source.id;
    final qualities =
        _source.telegram?.videoQualities ?? const <VideoQuality>[];
    final original = _originalVideoQualityLabel;
    // File IDs are session-only. Nothing from this panel is saved to settings.
    final selected = await showAuralisDialog<int>(
      context: context,
      builder: (dialog) => _VideoPanel(
        title: 'Quality',
        icon: Icons.high_quality_outlined,
        detail: qualities.isEmpty
            ? 'Only the original quality is available for this video.'
            : 'Available source resolutions · no upscaling',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _VideoMenuRow(
              label: original == 'Original'
                  ? 'Original'
                  : 'Original · $original',
              icon: Icons.movie_outlined,
              selected: _selectedVideoQuality == null,
              onTap: () => Navigator.pop(dialog, 0),
            ),
            for (final quality in qualities)
              _VideoMenuRow(
                label: quality.label,
                detail: quality.codec.isEmpty
                    ? null
                    : quality.codec.toUpperCase(),
                icon: Icons.high_quality_outlined,
                selected: quality.fileId == _selectedVideoQuality?.fileId,
                onTap: () => Navigator.pop(dialog, quality.fileId),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !_canPlay || _source.id != sourceId || _opening) {
      return;
    }
    final quality = qualities
        .where((value) => value.fileId == selected)
        .firstOrNull;
    if (quality?.fileId == _selectedVideoQuality?.fileId) return;
    await (_openingTask = _changeVideoQuality(quality));
  }

  Future<void> _changeVideoQuality(VideoQuality? quality) async {
    final player = _player!;
    final previous = _selectedVideoQuality;
    final position = _position;
    final playing = player.state.playing;
    final rate = player.state.rate, volume = player.state.volume;
    _qualitySecondarySubtitle ??= player.state.tracks.subtitle
        .where((track) => track.id == _secondarySubtitle)
        .firstOrNull;
    _qualityAudio ??= _automaticAudio ? null : player.state.track.audio;
    _qualitySubtitle ??= _automaticSubtitles
        ? null
        : player.state.track.subtitle;
    _saveProgress();
    _opening = _loading = true;
    _acceptVideoParams = false;
    _trackGeneration++;
    _startupTimeout?.cancel();
    _changed();

    Future<void> openQuality(VideoQuality? value) async {
      _acceptVideoParams = false;
      _trackGeneration++;
      _startupTimeout?.cancel();
      await _trackUpdates;
      if (!_canPlay) return;
      await player.stop();
      if (!_canPlay) return;
      final original = _source.telegram!;
      final track = value == null
          ? original
          : Track(
              id: original.id,
              title: original.title,
              artist: original.artist,
              source: original.source,
              duration: original.duration,
              fileId: value.fileId,
              size: value.size,
              mime: 'video/mp4',
              videoWidth: value.width,
              videoHeight: value.height,
            );
      final uri = await widget.proxy.uri(track);
      if (!_canPlay) return;
      _error = null;
      _selectedVideoQuality = value;
      // mpv track IDs can change between re-encodes; restore by metadata after
      // the new track list arrives, rather than applying stale numeric IDs.
      await player.setAudioTrack(mpv.AudioTrack.auto());
      await player.setSubtitleTrack(mpv.SubtitleTrack.auto());
      await _native.setProperty('secondary-sid', 'no');
      _secondarySubtitle = 'no';
      await _native.setProperty('start', 'none');
      if (!_canPlay) return;
      _acceptVideoParams = true;
      _armVideoStartupTimeout(track);
      await player.open(
        mpv.Media(uri.toString(), start: position),
        play: playing,
      );
      if (!_canPlay || _error != null) {
        if (_canPlay) throw StateError('Quality could not be played');
        return;
      }
      await player.setRate(rate);
      if (!_canPlay) return;
      await player.setVolume(volume);
      await _preferVideoTracks();
      if (!_canPlay) return;
      _positionReady = position > Duration.zero;
      await _applyOrientation();
      unawaited(_updateRefreshRate());
    }

    try {
      await openQuality(quality);
    } catch (_) {
      if (!_canPlay) return;
      try {
        await openQuality(previous);
        if (_canPlay) {
          _notice(
            'That quality is unavailable. Restored the previous quality.',
          );
        }
      } catch (_) {
        if (_canPlay) {
          _acceptVideoParams = false;
          _error = null;
          _setError(
            'Could not change video quality. Retry to play the original.',
          );
        }
      }
    } finally {
      _opening = _loading = false;
      _changed();
    }
  }
}

mpv.AudioTrack? _matchingAudio(
  mpv.AudioTrack selected,
  List<mpv.AudioTrack> tracks,
) {
  if (selected.id == 'no' || selected.uri) return selected;
  return tracks
          .where(
            (track) =>
                track.id != 'auto' &&
                track.id != 'no' &&
                track.language == selected.language &&
                track.title == selected.title,
          )
          .firstOrNull ??
      tracks
          .where(
            (track) =>
                selected.language != null &&
                track.language == selected.language &&
                track.id != 'auto' &&
                track.id != 'no',
          )
          .firstOrNull;
}

mpv.SubtitleTrack? _matchingSubtitle(
  mpv.SubtitleTrack selected,
  List<mpv.SubtitleTrack> tracks,
) {
  if (selected.id == 'no' || selected.uri || selected.data) return selected;
  return tracks
          .where(
            (track) =>
                track.id != 'auto' &&
                track.id != 'no' &&
                track.language == selected.language &&
                track.title == selected.title,
          )
          .firstOrNull ??
      tracks
          .where(
            (track) =>
                selected.language != null &&
                track.language == selected.language &&
                track.id != 'auto' &&
                track.id != 'no',
          )
          .firstOrNull;
}
