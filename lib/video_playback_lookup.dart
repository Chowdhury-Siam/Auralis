part of 'video_playback.dart';

extension _VideoPlaybackLookup on _VideoPlaybackState {
  Future<Uint8List> _fetchVideoBytes(
    Uri uri, {
    int maxBytes = 1024 * 1024,
    bool allowRedirects = false,
    bool emptyIfMissing = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'Auralis Video';
    try {
      for (var hop = 0; hop < 4; hop++) {
        if (uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('Unsupported download URL.');
        }
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (allowRedirects && response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) break;
          await response.drain<void>().timeout(const Duration(seconds: 8));
          uri = uri.resolve(location);
          continue;
        }
        if (emptyIfMissing && response.statusCode == 404) return Uint8List(0);
        if (response.statusCode != 200 || response.contentLength > maxBytes) {
          throw const FormatException(
            'The provider did not return a usable file.',
          );
        }
        final buffer = BytesBuilder(copy: false);
        await for (final bytes in response.timeout(
          const Duration(seconds: 8),
        )) {
          if (buffer.length + bytes.length > maxBytes) {
            throw const FormatException('The provider returned too much data.');
          }
          buffer.add(bytes);
        }
        return buffer.takeBytes();
      }
      throw const FormatException('Too many redirects.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, String>?> _lookupForm(
    BuildContext context,
    String title,
    List<(String, String?, bool)> fields, {
    required String? Function(Map<String, String>) validate,
  }) => showAuralisDialog<Map<String, String>>(
    context: context,
    builder: (dialog) {
      final values = <String, String>{};
      String? error;
      return StatefulBuilder(
        builder: (context, update) => AuralisDialog(
          title: Text(title),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (label, hint, secret) in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    maxLength: 160,
                    obscureText: secret,
                    autocorrect: false,
                    onChanged: (text) => values[label] = text.trim(),
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: hint,
                      counterText: '',
                    ),
                  ),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final failure = validate(values);
                if (failure == null) {
                  Navigator.pop(dialog, values);
                } else {
                  update(() => error = failure);
                }
              },
              child: const Text('Search'),
            ),
          ],
        ),
      );
    },
  );

  int? _positive(String? value) {
    final number = int.tryParse(value ?? '');
    return number != null && number > 0 ? number : null;
  }

  Future<void> _findAniSkip(BuildContext context) async {
    final source = _source.id;
    final duration = _duration;
    final values = await _lookupForm(
      context,
      'Find AniSkip segments',
      const [
        ('MyAnimeList ID', 'Example: 16498', false),
        ('Episode', 'Example: 1', false),
      ],
      validate: (values) =>
          _positive(values['MyAnimeList ID']) == null ||
              _positive(values['Episode']) == null
          ? 'Enter a MyAnimeList ID and episode number.'
          : null,
    );
    if (!_canPlay || values == null || _source.id != source) return;
    _notice('Looking up opening, ending, and recap times…');
    try {
      final bytes = await _fetchVideoBytes(
        Uri.https(
          'api.aniskip.com',
          '/v2/skip-times/${values['MyAnimeList ID']}/${values['Episode']}',
          {
            'types': ['op', 'ed', 'mixed-op', 'mixed-ed', 'recap'],
            'episodeLength': (duration.inMilliseconds / 1000).toString(),
          },
        ),
        emptyIfMissing: true,
      );
      if (!_canPlay || _source.id != source) return;
      final payload = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      final found = <VideoSkipSegment>[];
      if (payload case {'found': true, 'results': final List results}) {
        for (final item in results.take(30)) {
          if (item
              case {
                'skipType': final String type,
                'interval': {
                  'startTime': final num start,
                  'endTime': final num end,
                },
              }
              when start.isFinite &&
                  end.isFinite &&
                  start >= 0 &&
                  end > start &&
                  end * 1000 <= duration.inMilliseconds) {
            final label = switch (type) {
              'op' || 'mixed-op' => 'Opening',
              'ed' || 'mixed-ed' => 'Ending',
              'recap' => 'Recap',
              _ => null,
            };
            if (label != null) {
              final from = Duration(milliseconds: (start * 1000).round());
              final until = Duration(milliseconds: (end * 1000).round());
              if (!_segments.any(
                (item) => item.start == from && item.end == until,
              )) {
                found.add(VideoSkipSegment(from, until, label));
              }
            }
          }
        }
      }
      if (found.isEmpty) {
        _notice('No new AniSkip segments match this video.');
        return;
      }
      final available = 30 - _segments.length;
      if (available <= 0) {
        _notice('This video already has 30 skip segments.');
        return;
      }
      _data.setSkipSegments(source, [..._segments, ...found.take(available)]);
      _saveSettings();
      _changed();
      _notice('AniSkip segments added.');
    } catch (_) {
      if (_canPlay && _source.id == source) _notice('AniSkip lookup failed.');
    }
  }

  Future<void> _findWyzieSubtitles(BuildContext context) async {
    final source = _source.id;
    final values = await _lookupForm(
      context,
      'Search subtitles with Wyzie',
      const [
        ('TMDB or IMDb ID', 'Example: tt0944947', false),
        ('Season (optional)', null, false),
        ('Episode (optional)', null, false),
        ('Language code (optional)', 'en', false),
        ('Wyzie API key', null, true),
      ],
      validate: (values) {
        final id = values['TMDB or IMDb ID'] ?? '';
        if (!RegExp(r'^(tt)?[0-9]+$', caseSensitive: false).hasMatch(id)) {
          return 'Enter a TMDB or IMDb ID.';
        }
        final season = values['Season (optional)'] ?? '';
        final episode = values['Episode (optional)'] ?? '';
        if ((season.isNotEmpty || episode.isNotEmpty) &&
            (_positive(season) == null || _positive(episode) == null)) {
          return 'Enter both a season and an episode.';
        }
        if ((values['Wyzie API key'] ?? '').isEmpty) {
          return 'Enter a Wyzie API key.';
        }
        return null;
      },
    );
    if (!_canPlay ||
        !context.mounted ||
        values == null ||
        _source.id != source) {
      return;
    }
    _notice('Searching Wyzie for subtitles…');
    try {
      final bytes = await _fetchVideoBytes(
        Uri.https('sub.wyzie.io', '/search', {
          'id': values['TMDB or IMDb ID']?.toLowerCase(),
          'source': 'all',
          'unzip': 'true',
          'format': 'srt,ass,ssa,vtt',
          'key': values['Wyzie API key'],
          if ((values['Season (optional)'] ?? '').isNotEmpty) ...{
            'season': values['Season (optional)'],
            'episode': values['Episode (optional)'],
          },
          if ((values['Language code (optional)'] ?? '').isNotEmpty)
            'language': values['Language code (optional)'],
        }),
        emptyIfMissing: true,
      );
      if (!_canPlay || !context.mounted || _source.id != source) return;
      final payload = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      final subtitles =
          <_VideoChoice<({Uri uri, String title, String? language})>>[];
      if (payload is List) {
        for (final result in payload.whereType<Map>().take(50)) {
          if (result['url'] case final String url) {
            final uri = Uri.tryParse(url);
            if (uri == null ||
                uri.scheme != 'https' ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty) {
              continue;
            }
            final language = result['language'] is String
                ? result['language'] as String
                : null;
            final title = [
              result['display'] ?? language,
              result['fileName'] ?? result['release'] ?? result['source'],
            ].whereType<String>().where((part) => part.isNotEmpty).join(' · ');
            subtitles.add((
              value: (
                uri: uri,
                title: title.isEmpty ? 'Online subtitles' : title,
                language: language,
              ),
              label: title.isEmpty ? 'Online subtitles' : title,
              selected: false,
            ));
          }
        }
      }
      if (subtitles.isEmpty) {
        _notice('Wyzie returned no matching subtitles.');
        return;
      }
      final selected = await _choose(context, 'Wyzie results', subtitles);
      if (!_canPlay || selected == null || _source.id != source) return;
      final data = await _fetchVideoBytes(
        selected.uri,
        maxBytes: 4 * 1024 * 1024,
        allowRedirects: true,
      );
      if (_canPlay && _source.id == source) {
        await _selectSubtitleTrack(
          mpv.SubtitleTrack.data(
            utf8.decode(data, allowMalformed: true),
            title: selected.title,
            language: selected.language,
          ),
        );
      }
    } catch (_) {
      if (_canPlay && _source.id == source) {
        _notice('Wyzie subtitle lookup or download failed.');
      }
    }
  }
}
