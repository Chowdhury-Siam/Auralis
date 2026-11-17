import 'package:media_kit/media_kit.dart' as mpv;

import 'video_playback_data.dart';

final _japanese = RegExp(
  r'(^|[^a-z0-9])(ja|jp|jpn|jap|japan|japanese)(?=$|[^a-z0-9])|日本語|日本',
  caseSensitive: false,
);
final _english = RegExp(
  r'(^|[^a-z0-9])(en|eng|english)(?=$|[^a-z0-9])|英語',
  caseSensitive: false,
);

int _languageScore(RegExp language, String? tag, String? title) {
  // A region subtag is not the spoken language (for example, en-JP).
  final primary = tag?.trim().split(RegExp('[-_]')).first ?? '';
  if (language.hasMatch(primary)) return 20;
  return language.hasMatch(title ?? '') ? 10 : 0;
}

T? _preferred<T>(Iterable<T> tracks, int Function(T) score) {
  T? preferred;
  var best = 0;
  for (final track in tracks) {
    final value = score(track);
    if (value > best) {
      preferred = track;
      best = value;
    }
  }
  return preferred;
}

String? _primaryLanguage(String? value) {
  final primary = value?.trim().toLowerCase().split(RegExp('[-_]')).first;
  return switch (primary) {
    null || '' || 'und' => null,
    'ja' || 'jp' || 'jpn' || 'japanese' => 'ja',
    'en' || 'eng' || 'english' => 'en',
    'fr' || 'fra' || 'fre' => 'fr',
    'de' || 'deu' || 'ger' => 'de',
    'es' || 'spa' => 'es',
    _ => primary,
  };
}

int _savedTrackScore(
  VideoTrackChoice choice,
  String id,
  String? language,
  String? title,
  bool? isDefault,
) {
  final savedLanguage = _primaryLanguage(choice.language);
  final currentLanguage = _primaryLanguage(language);
  if (savedLanguage != null &&
      currentLanguage != null &&
      savedLanguage != currentLanguage) {
    return 0;
  }
  final savedTitle = choice.title?.trim().toLowerCase() ?? '';
  final currentTitle = title?.trim().toLowerCase();
  final score = savedTitle.isNotEmpty && savedTitle == currentTitle
      ? 40
      : savedLanguage != null && savedLanguage == currentLanguage
      ? 20
      : savedLanguage == null && savedTitle.isEmpty && id == choice.id
      ? 1
      : 0;
  return score == 0
      ? 0
      : score + (id == choice.id ? 2 : 0) + (isDefault == true ? 1 : 0);
}

/// A missing match leaves libmpv's normal default selection unchanged.
mpv.AudioTrack? preferredVideoAudio(
  Iterable<mpv.AudioTrack> tracks, {
  VideoTrackChoice? choice,
}) {
  if (choice?.id == 'no') return mpv.AudioTrack.no();
  final available = tracks.where(
    (track) => int.tryParse(track.id) != null && !track.uri,
  );
  return (choice == null
          ? null
          : _preferred(
              available,
              (track) => _savedTrackScore(
                choice,
                track.id,
                track.language,
                track.title,
                track.isDefault,
              ),
            )) ??
      _preferred(available, (track) {
        final score = _languageScore(_japanese, track.language, track.title);
        return score == 0 ? 0 : score + (track.isDefault == true ? 1 : 0);
      });
}

mpv.SubtitleTrack? preferredVideoSubtitle(
  Iterable<mpv.SubtitleTrack> tracks, {
  VideoTrackChoice? choice,
}) {
  if (choice?.id == 'no') return mpv.SubtitleTrack.no();
  final available = tracks.where(
    (track) => int.tryParse(track.id) != null && !track.uri && !track.data,
  );
  return (choice == null
          ? null
          : _preferred(
              available,
              (track) => _savedTrackScore(
                choice,
                track.id,
                track.language,
                track.title,
                track.isDefault,
              ),
            )) ??
      _preferred(available, (track) {
        final score = _languageScore(_english, track.language, track.title);
        return score == 0 ? 0 : score + (track.isDefault == true ? 1 : 0);
      });
}
