# Music visualizers: implementation and verification

Version: **0.1.209+210**, based on the supplied **0.1.208+209** source.

## Scope

The redesigned Lyrics view retains its original Lyrics subtree offstage while
Spectrum or Visualizer occupies the content panel. Lyrics is the default.
Desktop artwork, the compact phone header, lyrics search/translation/import,
reading state and transport remain available. Expansion hides artwork/header,
not transport. The Music playback backend and the separate Video feature set
are unchanged.

The offline renderer uses audioMotion-analyzer 4.5.4 and Butterchurn 2.6.7 with
the 99-preset base pack from butterchurn-presets 2.4.7. Source, licenses,
distribution hashes and build materials are retained under
`third_party/visualizer/`. No Feishin application code is bundled.

## Audio and privacy

- A session-local Enable action is required before constructing the renderer.
- Android uses the output-mix `android.media.audiofx.Visualizer(0)` effect.
  Its required `RECORD_AUDIO` permission is labeled microphone by Android;
  the bridge never instantiates `AudioRecord` or opens an input device.
  Device/OEM restrictions can make this effect unavailable.
- Windows uses shared-mode WASAPI loopback on the default console render
  endpoint. Other output routing or device changes can require Retry.
- Both approaches can include other apps sharing the observed output.
- Only bounded mono unsigned waveform samples and sample rate enter the local
  WebView. No media URLs, credentials, microphone stream, recording or upload.
- The local HTML has a network-denying CSP; WebView permissions and popups are
  denied. Butterchurn requires local dynamic shader/preset evaluation.
- Capture reads do not overlap. Lifecycle cancellation discards late frames.
  Capture/rendering stop for pause, buffering, hidden/covered routes, lost focus,
  backgrounding, disposal and system/app reduced motion. Native hosts also
  release on pause/deactivation. Stale renderer input becomes silence.
- Device-local style/preset/FPS preferences are excluded from backup/Worker
  Sync. The enable decision itself is not persisted.

## Automated checks

Delivery results: analyzer **no issues**; **533 Flutter tests passed**;
release-note validation, Android source checks, offline distribution/source
integrity checks, Node visualizer bridge checks and all nine Node release-policy
tests passed. The separate Python tooling suite ran 39 tests: 37 passed and two
were blocked by missing JDK `keytool`.

Use Flutter **3.47.1** and Dart **3.13.1**:

```sh
flutter pub get
flutter analyze --no-pub --fatal-infos
flutter test --no-pub
python tool/release-notes.py
python tool/verify-android.py --source-only
python tool/verify-visualizer-sources.py
node tool/verify-visualizer.mjs
```

The visualizer widget/channel tests cover default Lyrics retention on phone
and desktop, explicit consent, preference persistence, stale/non-overlapping
reads, permission retry, mode/expansion controls, renderer failure/retry,
buffering, route coverage, focus, lifecycle and reduced motion.
The Node bridge test uses synthetic test tones to check FFT frequency,
actual-input rendering, stale-input silence, cycling, pause and cleanup.
Synthetic samples are test-only, not app playback.

Actual bundled spectrum and Butterchurn engines were also executed in the
in-app Chromium browser using synthetic waveform input: the base pack exposed
99 presets and no console errors were reported. This is not a native host or
real-device output-capture test.

## Verification limits and device checklist

Android SDK and Visual Studio's C++ toolchain are absent in the delivery
environment. Neither native host was compiled; real output capture, GPU
embedding, WebView lifecycle, performance/battery and device permission flows
must still be verified on Android and Windows.
The Python tooling suite also has two key-generation tests blocked by missing
JDK `keytool`; those failures are unrelated to visualizer source checks.

Before distributing binaries, test both platforms:

1. Open Lyrics: verify the supplied redesign, import, search, translation,
   timed/static reading and playback controls.
2. Switch modes, grant/deny permission, Retry, and verify actual music response.
   Confirm no mic/input device opens and no renderer network requests occur.
3. Exercise spectrum styles/palettes/FPS and preset search/previous/next/random,
   cycling, expand/collapse, narrow layouts and window resizing.
4. Pause, buffer, cover with dialogs, lose focus, background, enable reduced
   motion, switch to Lyrics/Video and close the page during permission/loading.
   Confirm capture is released, no stale frames resume and music is unaffected.
5. Test denied/revoked permission, unsupported output effects, missing WebView2,
   GPU/context loss and output-device changes; Lyrics must remain usable.
6. Preserve corresponding-source/notices obligations, including the existing
   native playback limitations in `THIRD_PARTY_NOTICES.md`.
