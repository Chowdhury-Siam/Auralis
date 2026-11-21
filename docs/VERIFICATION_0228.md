# Verification — Auralis 0.1.228+229

## Host and scope

Windows 11, Flutter 3.47.1 / Dart 3.13.1. Source baseline:
user-supplied 0.1.226 plus delivered 0.1.227+228. No dependency changes.

- `flutter analyze --no-pub --fatal-infos`: **no issues**.
- `flutter test --no-pub --concurrency=2 --reporter expanded`: **619 passed**,
  **1 intentionally skipped** (opt-in benchmark; run separately and passed).
  Final completion: `02:29 +619 ~1: All tests passed!`.
- Opt-in CPU benchmark/differential/widget workloads: **4 passed**.
- Node sync/accounts/database/deployment/release-policy suites: **47 passed**.
- `python tool/release-notes.py`: bundled notes and version **match 0.1.228**.
- `python tool/verify-android.py --source-only`: **passed**.
- `node tool/verify-visualizer.mjs`: **passed**, including quiet beats, float
  capture, volume compensation, held-note rejection, adaptation/recovery and
  refresh-aware pacing.
- `python tool/verify-visualizer-sources.py`: **passed** source/package/assets/
  licence checks for AudioMotion, Butterchurn and Butterchurn presets.
- Android Python tooling: **39 run; 37 passed, 2 environment errors** because
  JDK `keytool` is absent. The two signing tests were not skipped or reported as
  passing. No real release, account, key, deployment or GitHub resource was
  published by these mocked tooling tests.

## Fixes found while verifying

- New imported-translation tests exercise mismatch/size limits, original
  preservation, restart/account separation, stale dialogs and provider races.
  Bilingual MP3/FLAC/M4A tags round-trip with unchanged audio bytes and unchanged
  source files.
- Gesture tests exercise independent switches and persisted defaults, speed
  hold/release/cancellation, master/lock interaction, pinch/pan separation,
  show-controls fallback and confirmed reset. Full-width control tests cover
  DPR 1/2, device insets, RTL, large text and decoder-aspect updates.
- Most played tests exercise actual Music Library menu ordering, Settings,
  stable count/title/ID comparisons, missing play history, persistence/backups,
  Worker validation and Music/Video independence.
- The initial full run hit a Telegram account layout-test timeout: sign-in had
  started real asynchronous sync, while the test advanced fake animation time
  waiting for the progress indicator to settle. The fixture now awaits that
  real-I/O sync inside its existing `runAsync` block. The isolated rerun passed;
  no assertion, spinner or production feature was disabled.
- Gesture/layout/metadata tests initially exposed failures during implementation;
  those were corrected and rerun rather than omitted from the final suite.

## Measurements and unverified items

The equivalent debug/test CPU workloads measured 60,037.4 → 8,139.6 µs for
2,000-line LRC parsing and 2,526.4 → 110.1 µs for selecting the top track from
10,000 history entries. These are host medians, **not native frame timings**.
See PERFORMANCE_0228.md for methodology and the native follow-up workload.

`flutter doctor -v` confirms no Android SDK and no Visual Studio C++ toolchain.
The Android profile-build attempt fails with “No Android SDK found.” No native
Android/Windows binaries, DevTools frame traces, GPU/battery measurements,
release-playback/input checks or long-session memory-leak measurements are
certified here. There is no 60–120 FPS guarantee.

## Packaging

The complete source ZIP is built from the prior complete source manifest plus
explicitly reviewed changes/new files. Build/test caches, local SDK settings,
temporary/private files and generated registrations are excluded.
Only test-generated baseline documentation screenshots are restored from the
prior delivery. Native/third-party sources, licences, visualizer assets and the
newer origin blur are checked for byte-identical preservation.
The packager checks every ZIP entry, CRC and SHA256 and refuses to overwrite
an existing delivery. No commit, push or public publication was performed.
