import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import 'models.dart';
import 'storage.dart';
import 'data_backup.dart';
import 'telegram/stream_proxy.dart';

abstract class AudioBackend extends ChangeNotifier {
  bool playing = false, buffering = false;
  Duration position = Duration.zero,
      duration = Duration.zero,
      buffered = Duration.zero;
  String? error;
  VoidCallback? onCompleted;
  Future<void> open(String uri);
  Future<void> toggle();
  Future<void> seek(Duration value);
  Future<void> volume(double value);
  Future<void> stop();
  Future<void> shutdown();
}

class MpvBackend extends AudioBackend {
  MpvBackend({this.session}) {
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'Auralis',
        bufferSize: 8 * 1024 * 1024,
      ),
    );
    _subscriptions.addAll([
      _player.stream.playing.listen((v) {
        playing = v;
        notifyListeners();
      }),
      _player.stream.buffering.listen((v) {
        buffering = v;
        notifyListeners();
      }),
      _player.stream.position.listen((v) {
        position = v;
        notifyListeners();
      }),
      _player.stream.duration.listen((v) {
        duration = v;
        notifyListeners();
      }),
      _player.stream.buffer.listen((v) {
        buffered = v;
        notifyListeners();
      }),
      _player.stream.error.listen((_) {
        error = 'Audio could not be decoded or the source is unavailable.';
        notifyListeners();
      }),
      _player.stream.completed.listen((v) {
        if (v) onCompleted?.call();
      }),
    ]);
  }
  late final Player _player;
  final AudioSession? session;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  @override
  Future<void> open(String uri) async {
    await _focus();
    // media_kit defaults to five seconds. An uncached Telegram seek can need
    // longer before the loopback proxy receives its first bytes.
    await (_player.platform as NativePlayer).setProperty('network-timeout', '60');
    error = null;
    position = Duration.zero;
    duration = Duration.zero;
    await _player.open(Media(uri));
  }

  @override
  Future<void> toggle() async {
    try {
      error = null;
      if (_player.state.playing) {
        await _player.pause();
        await session?.setActive(false);
      } else {
        await _focus();
        await _player.play();
      }
    } catch (_) {
      error =
          'Could not change playback. Check audio availability and try again.';
      notifyListeners();
    }
  }

  Future<void> _focus() async {
    if (session != null && !await session!.setActive(true)) {
      throw StateError('Audio focus is unavailable.');
    }
  }

  @override
  Future<void> seek(Duration value) async {
    await _player.seek(value);
    position = value;
    notifyListeners();
  }

  @override
  Future<void> volume(double value) => _player.setVolume(value);
  @override
  Future<void> stop() async {
    await _player.stop();
    await session?.setActive(false);
  }

  @override
  Future<void> shutdown() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await session?.setActive(false);
    await _player.dispose();
    dispose();
  }
}

class PlayerController extends ChangeNotifier {
  PlayerController(
    this.audio,
    this.proxy,
    this.settings, {
    DateTime Function()? now,
    Duration Function()? elapsed,
  }) : _now = now ?? DateTime.now,
       _elapsedOverride = elapsed {
    audio.addListener(_audioChanged);
    audio.onCompleted = () => unawaited(_completed());
    _proxyErrors = proxy.errors.listen((value) {
      error = value;
      notifyListeners();
    });
  }
  final DateTime Function() _now;
  final Duration Function()? _elapsedOverride;
  final _watch = Stopwatch()..start();
  Duration get _elapsed => _elapsedOverride?.call() ?? _watch.elapsed;
  Track? _listeningTrack;
  Duration _sampleElapsed = Duration.zero,
      _samplePosition = Duration.zero,
      _lastStatsSave = Duration.zero;
  bool _samplePlaying = false, _qualifiedPlay = false;
  int _sessionListened = 0, _statsRevision = 0, _savedStatsRevision = 0;
  bool restoringData = false;

  void _audioChanged() {
    _recordListening();
    if (!_closed) notifyListeners();
  }

  void _recordListening() {
    final elapsed = _elapsed;
    final gap = elapsed - _sampleElapsed;
    final advancement = audio.position - _samplePosition;
    final wasPlaying = _samplePlaying;
    final track = _listeningTrack;
    _samplePlaying =
        !_closed &&
        !restoringData &&
        !loading &&
        track != null &&
        audio.playing &&
        !audio.buffering &&
        audio.error == null;
    _sampleElapsed = elapsed;
    _samplePosition = audio.position;
    // Count only observed playback advancement, bounded by monotonic active time.
    // Long gaps (e.g. suspended PC) and seeks cannot inflate listening totals.
    if (wasPlaying &&
        track != null &&
        gap > Duration.zero &&
        gap <= const Duration(seconds: 5) &&
        advancement > Duration.zero) {
      final amount = min(gap.inMilliseconds, advancement.inMilliseconds);
      if (amount > 0) {
        _sessionListened += amount;
        final duration = audio.duration > Duration.zero
            ? audio.duration
            : track.duration;
        final threshold = duration > Duration.zero
            ? max(1, min(30000, duration.inMilliseconds ~/ 2))
            : 30000;
        final play = !_qualifiedPlay && _sessionListened >= threshold;
        if (play) _qualifiedPlay = true;
        settings.listening.record(track, amount, play ? 1 : 0, _now());
        _statsRevision++;
      }
    }
    if (_statsRevision != _savedStatsRevision &&
        (!_samplePlaying && wasPlaying ||
            elapsed - _lastStatsSave >= const Duration(seconds: 30))) {
      _lastStatsSave = elapsed;
      unawaited(_saveListening());
    }
  }

  Future<void> _saveListening({bool failOnError = false}) async {
    if (_statsRevision == _savedStatsRevision) return;
    final revision = _statsRevision;
    try {
      await settings.save();
      _savedStatsRevision = max(_savedStatsRevision, revision);
    } catch (_) {
      if (!_closed) {
        error = 'Listening statistics could not be saved. Check application storage.';
        notifyListeners();
      }
      if (failOnError) rethrow;
    }
  }

  Future<void> flushListeningStats({bool failOnError = false}) async {
    _recordListening();
    await _saveListening(failOnError: failOnError);
  }

  Future<void> seek(Duration position) async {
    _recordListening();
    _samplePlaying = false;
    try {
      await audio.seek(position);
    } finally {
      _sampleElapsed = _elapsed;
      _samplePosition = audio.position;
      _samplePlaying =
          !_closed &&
          !loading &&
          _listeningTrack != null &&
          audio.playing &&
          !audio.buffering &&
          audio.error == null;
    }
  }

  Future<void> restoreBackup(DataBackup backup) async {
    if (restoringData) throw StateError('A restore is already running.');
    // Revalidate a detached copy before stopping playback or touching settings.
    final checked = DataBackup.parse(backup.encode());
    await flushListeningStats(failOnError: true);

    restoringData = true;
    try {
      await clear();
      final recovery = utf8.encode(
        DataBackup.create(settings, _now()).encode(),
      );
      await settings.replaceSnapshot(checked.snapshot, recovery);
      _savedStatsRevision = _statsRevision;
      error = null;
      if (!_closed) await setVolume(settings.volume, persist: false);
    } finally {
      restoringData = false;
      if (!_closed) notifyListeners();
    }
  }

  final AudioBackend audio;
  final TelegramStreamProxy proxy;
  final AppSettings settings;

  void refreshSettings() {
    if (!_closed) notifyListeners();
  }
  late final StreamSubscription<String> _proxyErrors;
  final List<Track> queue = [];
  int index = -1, _generation = 0;
  bool loading = false, _closed = false, _pauseAfterOpen = false;
  Timer? _sleepTimer;
  DateTime? sleepUntil;
  bool sleepAfterTrack = false;
  PlaybackRepeat get repeatMode => settings.repeatMode;
  bool get repeat => repeatMode != PlaybackRepeat.off;
  bool get sleepActive => sleepUntil != null || sleepAfterTrack;

  String? error;
  Track? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;

  void toggleRepeat() {
    settings.repeatMode = PlaybackRepeat
        .values[(repeatMode.index + 1) % PlaybackRepeat.values.length];
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      await settings.save();
    } catch (_) {
      if (!_closed) {
        error = 'Changes are active for this session, but could not be saved. Check that application storage is writable.';
        notifyListeners();
      }
    }
  }

  Future<void> toggleFavorite(Track track) async {
    if (!settings.favoriteIds.remove(track.id)) {
      if (settings.favoriteIds.length >= 10000) {
        throw StateError('Favorites is full. Remove a track first.');
      }
      settings.favoriteIds.add(track.id);
    }
    notifyListeners();
    await _persist();
  }

  String _playlistName(String value, {String? replacing}) {
    final name = value.trim();
    if (name.isEmpty || name.length > 60) {
      throw ArgumentError('Use a playlist name from 1 to 60 characters.');
    }
    if (settings.playlists.keys.any(
      (key) => key != replacing && key.toLowerCase() == name.toLowerCase(),
    )) {
      throw ArgumentError('A playlist with that name already exists.');
    }
    return name;
  }

  Future<String> createPlaylist(String value) async {
    final name = _playlistName(value);
    if (settings.playlists.length >= 100) {
      throw StateError('You can save up to 100 playlists.');
    }
    settings.playlists[name] = [];
    notifyListeners();
    await _persist();
    return name;
  }

  Future<String> renamePlaylist(String previous, String value) async {
    if (!settings.playlists.containsKey(previous)) {
      throw StateError('Playlist no longer exists.');
    }
    final name = _playlistName(value, replacing: previous);
    settings.playlists = {
      for (final entry in settings.playlists.entries)
        (entry.key == previous ? name : entry.key): entry.value,
    };
    notifyListeners();
    await _persist();
    return name;
  }

  Future<void> deletePlaylist(String name) async {
    settings.playlists.remove(name);
    notifyListeners();
    await _persist();
  }

  Future<void> addToPlaylist(String name, Track track) async {
    final ids = settings.playlists[name];
    if (ids == null) throw StateError('Playlist no longer exists.');
    if (ids.contains(track.id)) return;
    if (ids.length >= 5000) throw StateError('This playlist is full.');
    ids.add(track.id);
    notifyListeners();
    await _persist();
  }

  Future<void> removeFromPlaylist(String name, Track track) async {
    settings.playlists[name]?.remove(track.id);
    notifyListeners();
    await _persist();
  }

  Future<void> clearRecent() async {
    settings.recentIds.clear();
    notifyListeners();
    await _persist();
  }

  void playNext(Track track) {
    queue.insert(index + 1, track);
    notifyListeners();
  }

  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero || duration > const Duration(hours: 24)) {
      throw ArgumentError('Choose a duration between one second and 24 hours.');
    }
    cancelSleepTimer();
    sleepUntil = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () => unawaited(_finishSleep()));
    notifyListeners();
  }

  void sleepAtTrackEnd() {
    if (current == null) throw StateError('Play a track first.');
    cancelSleepTimer();
    sleepAfterTrack = true;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepUntil = null;
    sleepAfterTrack = false;
    _pauseAfterOpen = false;
    if (!_closed) notifyListeners();
  }

  Future<void> _finishSleep() async {
    cancelSleepTimer();
    _pauseAfterOpen = loading;
    try {
      if (audio.playing) await audio.toggle();
    } catch (_) {
      if (!_closed) {
        error = 'Could not pause playback when the sleep timer ended.';
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _completed() async {
    if (_closed) return;
    await flushListeningStats();
    _sessionListened = 0;
    _qualifiedPlay = false;
    if (sleepAfterTrack) {
      await _finishSleep();
    } else if (repeatMode == PlaybackRepeat.one && current != null) {
      try {
        await seek(Duration.zero);
        if (!audio.playing) await audio.toggle();
      } catch (_) {
        if (!_closed) {
          error = 'Could not repeat this track.';
          notifyListeners();
        }
      }
    } else {
      await next(automatic: true);
    }
  }

  Future<void> playAt(int target) async {
    if (restoringData) return;
    if (target < 0 || target >= queue.length) return;
    _pauseAfterOpen = false;
    index = target;
    await _open(queue[target]);
  }

  Future<void> play(Track track, {List<Track>? from}) async {
    if (restoringData) return;
    _pauseAfterOpen = false;
    if (from != null) {
      queue
        ..clear()
        ..addAll(from);
      index = queue.indexWhere((t) => t.id == track.id);
    } else {
      index = queue.indexWhere((t) => t.id == track.id);
      if (index < 0) {
        queue.add(track);
        index = queue.length - 1;
      }
    }
    if (index < 0) return;
    await _open(track);
  }

  Future<void> _open(Track track) async {
    await flushListeningStats();
    _samplePlaying = false;
    _listeningTrack = null;
    var opened = false;
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final uri = (await proxy.uri(track)).toString();
      if (generation != _generation) return;
      await audio.open(uri);
      if (generation != _generation || _closed) return;
      if (_pauseAfterOpen && audio.playing) {
        _pauseAfterOpen = false;
        await audio.toggle();
      }
      opened = true;
      settings.recentIds = [
        track.id,
        ...settings.recentIds.where((id) => id != track.id),
      ].take(100).toList();
      await _persist();
    } catch (_) {
      if (generation == _generation) error = 'Could not open this track. Check the Telegram connection and native libraries.';
    } finally {
      if (generation == _generation) {
        loading = false;
        if (opened) {
          _listeningTrack = track;
          _sessionListened = 0;
          _qualifiedPlay = false;
          _sampleElapsed = _elapsed;
          _samplePosition = audio.position;
          _samplePlaying =
              audio.playing && !audio.buffering && audio.error == null;
        }
        notifyListeners();
      }
    }
  }

  void enqueue(Track track) {
    queue.add(track);
    notifyListeners();
  }

  Future<void> next({bool automatic = false}) async {
    if (queue.isEmpty) return;
    if (index + 1 < queue.length) {
      await playAt(index + 1);
    } else if (repeatMode != PlaybackRepeat.off) {
      await playAt(0);
    } else if (!automatic && current == null) {
      await playAt(0);
    }
  }

  Future<void> previous() async {
    if (audio.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
    } else if (index > 0) {
      await playAt(index - 1);
    }
  }

  void reorder(int oldIndex, int newIndex) {
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    if (index == oldIndex) {
      index = newIndex;
    } else if (oldIndex < index && newIndex >= index) {
      index--;
    } else if (oldIndex > index && newIndex <= index) {
      index++;
    }
    notifyListeners();
  }

  void shuffle() {
    final upcoming = queue.skip(index + 1).toList()..shuffle(Random.secure());
    queue.replaceRange(index + 1, queue.length, upcoming);
    notifyListeners();
  }

  Future<void> setVolume(double value, {bool persist = true}) async {
    final volume = value.clamp(0.0, 100.0);
    settings.volume = volume;
    notifyListeners();
    try {
      await audio.volume(volume);
      if (persist) await settings.save();
    } catch (_) {
      error = 'Could not apply or save the volume setting.';
      notifyListeners();
    }
  }

  Future<void> clear() async {
    await flushListeningStats();
    _samplePlaying = false;
    _listeningTrack = null;
    cancelSleepTimer();
    ++_generation;
    loading = false;
    await audio.stop();
    await proxy.stop();
    queue.clear();
    index = -1;
    notifyListeners();
  }

  Future<void> shutdown() async {
    await flushListeningStats();
    _closed = true;
    _watch.stop();
    cancelSleepTimer();
    ++_generation;
    await _proxyErrors.cancel();
    audio.removeListener(_audioChanged);
    await audio.shutdown();
    await proxy.close();
    dispose();
  }
}
