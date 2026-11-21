# Video skip buttons — 0.1.227+228

Based on the supplied **0.1.226+227** source. Music, visualizers, the volume fix,
video track/channel preferences, native playback/capture and existing video
features are retained.

## Behavior

- Named timed chapters offer **Skip Intro**, **Skip Opening**, **Skip Ending**,
  **Skip Outro**, **Skip Recap**, **Skip Credits** or **Skip Preview**. OP/ED,
  numbered OP/ED, NCOP/NCED, bracketed names, opening/ending credits, common
  outro spelling variants (including the label “Outer”), and Japanese
  opening/ending chapter names are recognized. Ordinary words such as Operation,
  Education, Endgame and Outer space do not match the abbreviations.
- Chapter prompts are automatic, device-local and need no import. The button
  appears only inside a valid timed range: start inclusive, end exclusive.
  Playback opening/error, native PiP and the offstage minimized player do not
  expose an active skip overlay.
- The button remains outside the normal control overlay. **Lock and automatic
  control hiding do not hide or disable it.** Tapping it seeks to the range end,
  keeping both the lock and the current playing/paused state. All other locked
  gestures and transport controls remain locked.
- A following chapter is the boundary, not the video end. An ending followed by
  a post-credit scene therefore skips to that scene. A genuinely final ending/
  outro chapter can target EOF, where existing completion/queue behavior applies.
- Saved/manual/AniSkip ranges win over an entire overlapping chapter, including
  before/after the saved interval, so corrected boundaries cannot fall back to a
  wider chapter and skip story content. Existing saved auto-skip semantics are
  unchanged; deriving a chapter prompt does not silently save/auto-skip it.
- Missing, negative, zero-length, out-of-range and conflicting same-time chapter
  metadata do not create invented skip ranges. Chapters are ordered by time;
  duplicate aliases for the same section kind are safe to collapse.
- Repeated clicks cannot queue simultaneous skip requests. A failed seek leaves
  playback/lock intact, shows the existing error notice and permits a retry.
  Activation rechecks the current source/range rather than using a stale frame.
- Chapter ranges are cached on metadata refresh. Hidden HUDs receive stable
  range objects and only refresh when the active range changes, rather than
  rebuilding or sorting chapters on every position event. Older asynchronous
  chapter reads cannot overwrite a newer video/read.

## Videos without marked chapters

No content recognition or arbitrary “skip 90 seconds” heuristic is claimed.
Use the existing **More player controls → Playback → Skip segments** actions:

1. Mark the start, seek to the section end and choose **Mark end and save**.
2. Or choose **Find AniSkip segments**, enter the MyAnimeList ID and episode,
   and import matching opening/ending/recap ranges.

These ranges are saved per video using the existing storage/privacy behavior.
The existing AniSkip lookup is user-requested; this update adds no network call.
Locking does not enable editing or online lookup from the locked overlay.

## Verification and limits

Local verification with Flutter **3.47.1** / Dart **3.13.1**:
**571 Flutter tests passed** (`--concurrency=2`); analyzer **no issues**
(`--no-pub --fatal-infos`). All **46 Node sync/workflow-policy tests** passed,
as did release-note validation, Android source checks and the existing
visualizer regression/source-license integrity checks.

Regression coverage includes recognition/false positives, sorted/malformed
boundaries, saved precedence, post-credit preservation and EOF. Player tests
exercise actual skip-button hit testing in portrait, landscape, desktop and
large text, locked with hidden controls, paused playback, failure/retry,
double activation and unmarked videos. Existing seeking, lock/unlock, queue,
language and lifecycle tests are retained.

Android SDK/Visual Studio C++ native builds and real-device metadata, seeking,
lock, PiP and EOF/queue behavior still require device verification. Widget
tests use the existing fake media backend, not a native decoder.
