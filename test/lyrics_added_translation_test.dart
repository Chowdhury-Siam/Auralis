import 'dart:convert';
import 'dart:io';

import 'package:auralis/lyrics.dart';
import 'package:auralis/lyrics_added_translation.dart';
import 'package:auralis/media_cache.dart';
import 'package:auralis/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = Track(
  id: 'one',
  title: 'Song',
  artist: 'Artist',
  source: 'Music',
);

void main() {
  test(
    'plain translations preserve originals, timed gaps and exact timestamps',
    () {
      final source = Lyrics.parse('[00:01.123]日本語\n[00:02]\n[00:04]次の行');
      final text = source.timestampedText;
      final result = addLyricsTranslation(
        source,
        '\uFEFFEnglish\r\n\r\nNext line',
      );
      expect(
        result.lines.map((line) => line.time),
        source.lines.map((line) => line.time),
      );
      expect(result.lines.map((line) => line.text), [
        '日本語\nEnglish',
        '',
        '次の行\nNext line',
      ]);
      expect(source.timestampedText, text);
      expect(result.provider, 'Added translation');
      expect(Lyrics.parse(result.timestampedText).plain, result.plain);
    },
  );

  test('timestamped translations may be reordered but never guessed', () {
    final source = Lyrics.parse('[00:01]一\n[00:03]二');
    final result = addLyricsTranslation(source, '[00:03]Two\n[00:01]One');
    expect(result.lines.map((line) => line.text), ['一\nOne', '二\nTwo']);
    for (final text in [
      '',
      'Only one',
      'One\nTwo\nThree',
      '[00:01]One',
      '[00:02]One\n[00:03]Two',
      '[00:01]One\n[00:03]',
    ]) {
      expect(() => addLyricsTranslation(source, text), throwsFormatException);
    }
    expect(
      () => addLyricsTranslation(Lyrics.parse('Plain'), '[00:01]Timed'),
      throwsFormatException,
    );
    expect(
      () => addLyricsTranslation(
        const Lyrics('', [], instrumental: true),
        'Words',
      ),
      throwsFormatException,
    );
  });

  test('plain originals retain blank lines and identical translations are not doubled', () {
    final source = Lyrics.parse('First\n\nSecond');
    expect(
      addLyricsTranslation(source, 'First\nNext').plain,
      'First\n\nSecond\nNext',
    );
    expect(addLyricsTranslation(source, 'First\nNext').lines, isEmpty);
  });

  test('bilingual metadata enforces UTF8 byte limit', () {
    final source = Lyrics.parse('あ' * 45000);
    expect(
      () => addLyricsTranslation(source, 'い' * 45000),
      throwsFormatException,
    );
  });

  test('translation survives repository restart, scoped to account, track and original', () async {
    final root = await Directory.systemTemp.createTemp('auralis-added-');
    addTearDown(() => root.delete(recursive: true));
    var disk = MediaCache(Directory('${root.path}/a'));
    final source = Lyrics.parse('[00:01]Original\n[00:03]Other');
    final repository = LyricsRepository(cache: () => disk);
    await repository.save(_song, source);
    final result = await repository.addTranslation(
      _song,
      source,
      'Translation\nAnother',
    );
    expect(repository.cached(_song), same(source));
    expect(repository.translated(_song, source), same(result));
    expect(
      await repository.translateJapanese(_song, source, active: () => true),
      same(result),
    );
    repository.close();
    final restored = LyricsRepository(cache: () => disk);
    addTearDown(restored.close);
    final original = (await restored.loadCached(_song))!;
    expect(original.timestampedText, source.timestampedText);
    expect(
      restored.addedTranslation(_song, original)!.timestampedText,
      result.timestampedText,
    );
    expect(
      restored.addedTranslation(_song, Lyrics.parse('Changed source')),
      isNull,
    );
    const other = Track(
      id: 'other',
      title: 'Song',
      artist: 'Artist',
      source: 'Music',
    );
    expect(restored.addedTranslation(other, original), isNull);
    disk = MediaCache(Directory('${root.path}/b'));
    expect(restored.addedTranslation(_song, original), isNull);
    expect(await restored.loadCached(_song), isNull);
    await expectLater(
      restored.addTranslation(_song, original, 'Wrong account'),
      throwsStateError,
    );
  });

  test(
    'corrupt optional translation does not discard saved original',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'auralis-added-invalid-',
      );
      addTearDown(() => root.delete(recursive: true));
      final disk = MediaCache(root);
      final repository = LyricsRepository(cache: () => disk);
      addTearDown(repository.close);
      await disk.write(
        _song,
        'lyrics',
        utf8.encode(
          jsonEncode({
            'plain': 'Original',
            'lines': [
              [1000, 'Original'],
            ],
            'addedTranslation': 'Mismatched\nExtra',
          }),
        ),
      );
      final original = (await repository.loadCached(_song))!;
      expect(original.plain, 'Original');
      expect(repository.addedTranslation(_song, original), isNull);
    },
  );

  test(
    'replaced sources and closed repositories reject stale additions',
    () async {
      final repository = LyricsRepository();
      final old = Lyrics.parse('Old');
      await repository.save(_song, old);
      await repository.save(_song, Lyrics.parse('New'));
      await expectLater(
        repository.addTranslation(_song, old, 'Stale'),
        throwsStateError,
      );
      repository.close();
      await expectLater(
        repository.addTranslation(_song, old, 'Closed'),
        throwsStateError,
      );
    },
  );
}
