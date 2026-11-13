import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../storage.dart';
import 'telegram_service.dart';

class ChannelLibrary extends ChangeNotifier {
  ChannelLibrary(this.telegram, this.settings) : _ready = telegram.ready {
    telegram.addListener(_authorizationChanged);
    if (_ready) unawaited(refresh());
  }

  final TelegramService telegram;
  final AppSettings settings;
  final List<Track> tracks = [];
  final _trackCounts = <int, int>{};

  bool loading = false, saving = false, _disposed = false, _ready;
  bool _refreshAfterSave = false;
  int _generation = 0;
  String? error;

  int? trackCount(int channelId) => _trackCounts[channelId];

  bool selected(int id) => settings.selectedChannels.any((c) => c.id == id);

  Future<void> select(MusicChat channel, bool selected) async {
    if (saving || _disposed) return;
    final previous = settings.selectedChannels;
    final selection = [
      for (final c in previous)
        if (c.id != channel.id) c,
      if (selected) channel,
    ];
    settings.selectedChannels = selection;
    saving = true;
    error = null;
    notifyListeners();
    String? saveError;
    try {
      await settings.save();
    } catch (_) {
      // Sign-out or sync may already have replaced this selection.
      if (identical(settings.selectedChannels, selection)) {
        settings.selectedChannels = previous;
      }
      saveError = 'Could not save your channel selection. Please try again.';
    } finally {
      saving = false;
    }
    if (_disposed) return;
    if (saveError == null || _refreshAfterSave) {
      await _refresh(selectionError: saveError);
    } else {
      error = saveError;
      notifyListeners();
    }
  }

  void _authorizationChanged() {
    if (_ready == telegram.ready) return;
    _ready = telegram.ready;
    if (_ready) {
      unawaited(refresh());
    } else {
      ++_generation;
      loading = false;
      tracks.clear();
      _trackCounts.clear();
      error = null;
      notifyListeners();
    }
  }

  Future<void> refresh() => _refresh();

  Future<void> _refresh({String? selectionError}) async {
    if (_disposed) return;
    if (saving) {
      // Reconnect and sync can request a refresh while selection is saving.
      _refreshAfterSave = true;
      return;
    }
    _refreshAfterSave = false;
    final generation = ++_generation;
    tracks.clear();
    _trackCounts.clear();
    error = selectionError;
    final channels = List<MusicChat>.of(settings.selectedChannels);
    loading = telegram.ready && channels.isNotEmpty;
    notifyListeners();
    if (!loading) return;
    final ids = <String>{};
    for (final selected in channels) {
      final start = tracks.length;
      try {
        final channel = await telegram.channel(selected.id);
        if (_disposed || generation != _generation) return;
        if (channel == null) throw StateError('Channel unavailable');
        for (final documents in [false, true]) {
          var cursor = 0;
          final cursors = <int>{0};
          do {
            final page = await telegram.music(
              channel.id,
              channel.title,
              before: cursor,
              documents: documents,
            );
            if (_disposed || generation != _generation) return;
            tracks.addAll(page.tracks.where((t) => ids.add(t.id)));
            notifyListeners();
            cursor = page.nextMessageId;
            if (cursor != 0 && !cursors.add(cursor)) {
              throw StateError('Telegram repeated a page cursor');
            }
          } while (cursor != 0);
        }
        _trackCounts[channel.id] = tracks.length - start;
        notifyListeners();
      } catch (_) {
        if (_disposed || generation != _generation) return;
        final message =
            'Could not load all music from ${selected.title}. Check channel access and refresh in Browse.';
        error = error == null ? message : '$error\n$message';
        notifyListeners();
      }
    }
    if (!_disposed && generation == _generation) {
      loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    telegram.removeListener(_authorizationChanged);
    super.dispose();
  }
}
