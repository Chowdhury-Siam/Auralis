import 'package:auralis/video_playback_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const duration = Duration(minutes: 24);

  test(
    'recognizes intro, OP/opening, ED/ending, end, outro and common aliases',
    () {
      const names = {
        'Intro': 'Intro',
        'Introduction': 'Intro',
        'OP': 'Opening',
        'op1': 'Opening',
        'OP 02 - Theme': 'Opening',
        '[OP] Artist - song': 'Opening',
        '(NCOP) Creditless': 'Opening',
        'Opening credits': 'Opening',
        'Opening Theme': 'Opening',
        '01 - Opening': 'Opening',
        'Chapter 2: OP': 'Opening',
        'ED': 'Ending',
        'ed2': 'Ending',
        '[NCED]': 'Ending',
        'Ending': 'Ending',
        'End': 'Ending',
        'End Credits': 'Ending',
        'Outro': 'Outro',
        'Outtro': 'Outro',
        'Outer': 'Outro',
        'Recap': 'Recap',
        'Previously on: last episode': 'Recap',
        'Credits': 'Credits',
        'Next episode preview': 'Preview',
        'オープニング': 'Opening',
        'エンディング': 'Ending',
      };
      for (final entry in names.entries) {
        expect(
          videoSkipChapterLabel('  ${entry.key}  '),
          entry.value,
          reason: entry.key,
        );
      }
      for (final name in [
        '',
        'Story',
        'Operation',
        'Education',
        'Endgame',
        'Endless summer',
        'Outer space',
        'Part A',
        'Chapter 3',
        'Main episode',
        'Reopening the case',
        'Hope',
        'Episode 2',
      ]) {
        expect(videoSkipChapterLabel(name), isNull, reason: name);
      }
    },
  );

  test('chapter timings are sorted, bounded and keep post-credit scenes', () {
    final segments = videoChapterSegments(const [
      VideoBookmark(Duration(minutes: 22), 'ED'),
      VideoBookmark(Duration(minutes: 1), 'OP'),
      VideoBookmark(Duration(minutes: 23), 'Post-credit scene'),
      VideoBookmark(Duration.zero, 'Story'),
      VideoBookmark(Duration(minutes: 2, seconds: 30), 'Part A'),
    ], duration);
    expect(segments, hasLength(2));
    expect(segments[0].start, const Duration(minutes: 1));
    expect(segments[0].end, const Duration(minutes: 2, seconds: 30));
    expect(segments[0].buttonLabel, 'Skip Opening');
    expect(segments[1].start, const Duration(minutes: 22));
    expect(segments[1].end, const Duration(minutes: 23));
    expect(segments[1].buttonLabel, 'Skip Ending');
  });

  test(
    'invalid and conflicting chapter markers never create invented ranges',
    () {
      final segments = videoChapterSegments(const [
        VideoBookmark(Duration(seconds: -5), 'Intro'),
        VideoBookmark(Duration.zero, 'OP'),
        VideoBookmark(Duration.zero, 'Story'), // Ambiguous metadata.
        VideoBookmark(Duration(seconds: 10), 'Intro'),
        VideoBookmark(
          Duration(seconds: 10),
          'Introduction',
        ), // Same kind is OK.
        VideoBookmark(Duration(seconds: 20), 'Story'),
        VideoBookmark(Duration(minutes: 24), 'ED'), // Already at EOF.
        VideoBookmark(Duration(minutes: 25), 'Outro'),
      ], duration);
      expect(segments, hasLength(1));
      expect(segments.single.start, const Duration(seconds: 10));
      expect(segments.single.end, const Duration(seconds: 20));
      expect(videoChapterSegments(const [], duration), isEmpty);
      expect(
        videoChapterSegments(const [
          VideoBookmark(Duration.zero, 'Opening'),
        ], Duration.zero),
        isEmpty,
      );
    },
  );

  test('final ending targets EOF only when no following chapter exists', () {
    final segments = videoChapterSegments(const [
      VideoBookmark(Duration.zero, 'Story'),
      VideoBookmark(Duration(minutes: 22), 'Ending'),
    ], duration);
    expect(segments.single.end, duration);
    expect(
      videoActiveSkipSegment(const [], segments, duration, duration),
      isNull,
    );
  });

  test('saved/manual/AniSkip timings win, and current objects stay stable', () {
    const chapter = VideoSkipSegment(
      Duration.zero,
      Duration(seconds: 90),
      'OP',
    );
    const saved = VideoSkipSegment(
      Duration(seconds: 10),
      Duration(seconds: 70),
      'Opening',
    );
    for (var i = 10; i < 70; i++) {
      expect(
        videoActiveSkipSegment(
          const [saved],
          const [chapter],
          Duration(seconds: i),
          duration,
        ),
        same(saved),
      );
    }
    expect(
      videoActiveSkipSegment(
        const [saved],
        const [chapter],
        const Duration(seconds: 70),
        duration,
      ),
      isNull,
    );
    expect(
      videoActiveSkipSegment(
        const [saved],
        const [chapter],
        const Duration(seconds: 5),
        duration,
      ),
      isNull,
      reason: 'Corrected saved timings override the whole overlapping chapter.',
    );
    expect(
      videoActiveSkipSegment(
        const [saved],
        const [chapter],
        const Duration(seconds: 90),
        duration,
      ),
      isNull,
    );
    expect(
      videoActiveSkipSegment(
        const [saved],
        const [chapter],
        const Duration(seconds: -1),
        duration,
      ),
      isNull,
    );
    expect(
      videoActiveSkipSegment(
        const [saved],
        const [chapter],
        const Duration(seconds: 10),
        Duration.zero,
      ),
      isNull,
    );
    expect(
      const VideoSkipSegment(
        Duration.zero,
        Duration(seconds: 30),
        'Sponsor break',
      ).buttonLabel,
      'Skip Sponsor break',
    );
  });

  test('out-of-range or malformed saved timings are not offered', () {
    expect(
      videoActiveSkipSegment(
        const [
          VideoSkipSegment(
            Duration(seconds: -1),
            Duration(seconds: 20),
            'Intro',
          ),
          VideoSkipSegment(
            Duration(seconds: 20),
            Duration(seconds: 10),
            'Intro',
          ),
          VideoSkipSegment(Duration.zero, Duration(hours: 1), 'Intro'),
        ],
        const [],
        const Duration(seconds: 5),
        duration,
      ),
      isNull,
    );
  });
}
