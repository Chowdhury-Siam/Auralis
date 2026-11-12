import 'package:media_kit/media_kit.dart' as mpv;

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

/// A missing match leaves libmpv's normal default selection unchanged.
mpv.AudioTrack? preferredVideoAudio(Iterable<mpv.AudioTrack> tracks) =>
    _preferred(tracks, (track) {
      if (track.id == 'auto' || track.id == 'no' || track.uri) return 0;
      final score = _languageScore(_japanese, track.language, track.title);
      return score == 0 ? 0 : score + (track.isDefault == true ? 1 : 0);
    });

mpv.SubtitleTrack? preferredVideoSubtitle(Iterable<mpv.SubtitleTrack> tracks) =>
    _preferred(tracks, (track) {
      if (track.id == 'auto' || track.id == 'no' || track.uri || track.data) {
        return 0;
      }
      final score = _languageScore(_english, track.language, track.title);
      return score == 0 ? 0 : score + (track.isDefault == true ? 1 : 0);
    });
