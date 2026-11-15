# Music visualizers: implementation and verification

Version: **0.1.213+214**, retaining the **0.1.212+213** positioning fix, **0.1.211+212** Windows SDK fix, **0.1.210+211** Lyrics fix, **0.1.209+210** visualizers and supplied **0.1.208+209** Lyrics redesign.

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

- Selecting Spectrum or Visualizer starts rendering/output analysis automatically
  during active, visible playback. There is no additional Enable button.
  Opening Lyrics alone does not start analysis; switching back stops it.
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
  Capture/rendering stop for pause, buffering, hidden/covered in-app routes or
  dialogs, disposal and system/app reduced motion. Android also stops for lost
  focus/backgrounding; Windows keeps running behind another app but stops when
  Auralis itself is minimized/hidden. Native hosts release on Android pause or
  Windows minimize/hide. Stale renderer input becomes silence.
- Device-local style/preset/FPS preferences are excluded from backup/Worker
  Sync. The selected panel is not persisted; Lyrics remains the default.

## Automated checks

Final 0.1.213 local validation with Flutter **3.47.1** / Dart **3.13.1**:
**546 Flutter tests passed** (`--concurrency=2`); analyzer **no issues** with
`--no-pub --fatal-infos`; all **46 Node sync/workflow-policy tests passed**.
Visualizer bridge, upstream source/license integrity, release-note consistency
and Android source checks passed. The 39-test Python Android tooling suite had
37 passes and the same two missing-`keytool` errors. No native release build,
real-phone performance result or real Windows focus/occlusion test is claimed.

Version 0.1.213 removes the half-resolution Spectrum setting and the animated
renderer’s 960-pixel limit. Spectrum now uses audioMotion's full device pixel
ratio. Animated canvas and render targets are sized in physical display pixels
at initialization and resize, with a desktop 4096-edge/8,388,608-pixel safety
budget for very large surfaces. Ordinary 4K dimensions fit that budget. Phones
use a separate 2048-edge/2,097,152-pixel animated budget. Windows WebView
uses the current Flutter view's pixel ratio and refreshes its surface scale
when display DPI changes; browser resize events also update animated buffers.
The frame limit remains independently selectable.

Phone performance changes retain every mode, preset, palette and FPS choice:

- The bundled HTML is assembled once, with concurrent loads shared and failed
  loads retryable. Individual source-string copies are not permanently cached.
  A WebView memory-pressure callback clears the assembled-document cache.
- Bundled engine scripts are inert until selected. Spectrum evaluates only
  audioMotion; Butterchurn and all 99 presets initialize on animated-mode entry.
  Evaluated script elements release their source text. No network loading.
- FFT Hann/twiddle/bit-reversal tables are precomputed; animated mode skips the
  unused Spectrum FFT. Spectrum's disconnected Web Audio context is suspended.
- Position-only notifications do not rebuild the visualizer pane. Its renderer
  widget is reused behind a repaint boundary, including parent playback ticks.
  Hidden Lyrics retains its real widget subtree and manual reading position,
  rather than rebuilding on each tick or storing a bitmap snapshot.
- Native reads never overlap and skip when the WebView has an in-flight feed.
  Android samples at no more than 30 Hz independently of selectable 20/30/60 FPS
  animation. FPS pacing preserves phase instead of drifting to about 20 FPS
  when a nominal 30 FPS frame arrives slightly early.
- Only animated phone pixels adapt: pressure is evaluated over at least 2.5
  seconds/20 frames; more than 25% slow frames reduces scale by 10%, down to
  75% of the bounded size. Below 5% slow frames recovers 5 percentage points.
  Slow means measured render-call time above 75% of the frame budget or an
  inter-frame interval above 170%. These are heuristics, not GPU timing.
  Spectrum stays at full DPI; no presets or FPS choices are disabled.

Beat response uses real captured waveform data, not an animation clock:
Spectrum uses fast spectral attack (85%) and slower release (30%).
Animated mode tracks RMS energy, a 180 Hz low-pass bass band and the remaining
high band against moving averages. Onsets require an energy floor, a ratio
above 1.35 and more than 120 ms since the preceding onset. A 120 ms decaying
envelope gives at most 30% visual-input emphasis, limited by available sample
headroom. Spectrum source samples and actual audio playback are unchanged.
Silence stays silent. Timed preset changes wait for a real onset for at most
1.5 seconds beyond their interval, then use the normal transition. This is
transient-sensitive visualization, not an exact beat grid or BPM detector.

The updated lazy-loading document was executed in Chromium: no engines at
boot; only audioMotion after Spectrum selection; Butterchurn and all 99 presets
after Visualizer selection; evaluated source elements cleared. Both modes
matched physical pixels for a 600x400 CSS panel at DPR 1/1.25/2/3. A simulated
phone 2000x1500 CSS surface at DPR 2 used a 1672x1254 animated buffer within
its pixel ceiling. No engine or console errors occurred. These checks do not
measure real-phone frame times, battery use or native capture latency.

Actual bundled engine dimensions were checked in Chromium at simulated
pixel ratios 1, 1.25, 2 and 3. For both Spectrum and Visualizer, a 940x620 CSS
panel at 1.25 produced 1175x775 drawing pixels; a 600x400 panel at 2 produced
1200x800, rather than a half-resolution or 960-capped buffer. All eight
mode/density dimension checks passed with no engine or console errors.
These are browser sizing checks, not a native WebView/device performance test.

Visualizers now start automatically on panel selection, not on app startup or
in Lyrics. Readiness, active playback, buffering, route visibility and
reduced-motion guards still apply. Android's system permission
cannot be bypassed; denial shows an error with user-requested Retry rather than
repeated prompts. Output-mix privacy/permission details remain in settings and
error UI. Tests cover automatic selection/start, return-to-Lyrics stop, and
permission denial/retry, in addition to existing lifecycle protections.

Windows focus handling now distinguishes `inactive` (another app is in front)
from `hidden`/minimized. The pane ignores Windows view-focus loss and allows
the inactive lifecycle state. The native runner no longer stops WASAPI on
`WM_ACTIVATEAPP`; it stops on `WM_SIZE/SIZE_MINIMIZED` or hide instead.
The browser visibility fallback remains Android-only, so desktop occlusion
does not explicitly cancel rendering. Minimize/hidden lifecycle messages still
deactivate both desktop capture and rendering. New tests exercise both modes
through focus loss/return, minimize, unfocused restoration, in-app dialogs and
pause; a source guard checks the native message policy. Actual WebView2
occlusion/throttling behavior and the native build still need Windows testing.

Version 0.1.212 fixes renderer sizing and panel alignment. audioMotion's low-
resolution buffer had no explicit CSS width/height, so at devicePixelRatio 1
a 1000x700 panel displayed only a 500x350 spectrum in its upper-left corner.
The spectrum canvas now fills its containing panel regardless of buffer
resolution. Butterchurn's caller-owned canvas now receives the same bounded
dimensions/aspect as its internal renderer instead of retaining 300x150.
Mode switches and the surface ResizeObserver refresh the active engine
immediately. Selectors, control rows and wrapped preset titles are centered;
the renderer widget stretches across the available panel width.

The actual bundled engines were checked in Chromium across simulated pixel
ratios 1, 1.25, 2 and 3, with panel sizes 592x420, 320x240 and 1200x660,
rendering synthetic input and switching Spectrum/Visualizer/Spectrum. All 12
mode/size checks filled the CSS panel; animated canvas aspect matched the
panel (bounded to 960 pixels on its longest side), with no renderer errors.
Node bridge checks now cover both renderers' dimensions, expanded resizing and
mode-switch restoration; Flutter regressions check centered selector rows,
centered control rows and full-width renderer layout.

Final 0.1.212 local validation: **535 Flutter tests passed** with
`--concurrency=2`, followed by a fresh **10/10 visualizer test** pass after
centering pause/reduced-motion labels; analyzer **no issues**. An initial
parallel run ended before producing a completion summary; orphan test
processes from this workspace were released before the successful rerun.
Node renderer/resize checks, release-note validation, Android source checks,
and upstream distribution/source hashes passed. Browser console reported no
errors during the sizing checks. Native WebView embedding and device output
capture were not reverified locally; the native hosts are unchanged.

The 0.1.210 Windows CI build exposed a native source collision: Windows SDK
RPC headers define `small` as `char`, so the 16-bit PCM local declaration
expanded into invalid C++. Version 0.1.211 renames it to `pcm_sample`, retaining
the same decoding and normalization. A source regression test rejects these
SDK-reserved names in PCM declarations even on hosts without native compilers.
It failed on the previous source before the rename. This is a source guard,
not a substitute for a successful MSVC build. The plugin CMP0175 messages
reported by CI are development warnings, not the fatal compilation error;
unrelated plugin build scripts are unchanged.

Final 0.1.211 local checks: **535 Flutter tests passed**, analyzer **no issues**,
and release-note, Android source, visualizer bridge and source-integrity checks
passed. MSVC and the Windows SDK remain unavailable locally, so the actual
Windows release build must be rerun in CI; no native-build success is claimed.

The 0.1.209 Windows delivery passed 533 Flutter tests, but Linux CI exposed
an offscreen empty-Lyrics Import button with taller DejaVu Sans metrics.
Version 0.1.210 puts recovery actions before the longer help text and uses the
bundled DejaVu font in Lyrics tests on every host. Import tests explicitly
require a hittable button; a short-phone/large-text regression also verifies
scrolling to Import. No missed-tap warnings are suppressed.
The exact original CI missed-tap failure was reproduced on Windows after
switching the fixture to the bundled CI font. After the layout fix, all 36
Lyrics tests passed with that font.

Final 0.1.210 local verification: **534 Flutter tests passed**, analyzer **no
issues**, all **46 Node sync/workflow-policy tests passed**, and release-note,
Android source, visualizer bridge and distribution/source-integrity checks
passed. The full Flutter run completed separately after an earlier combined
validation command exceeded its shell timeout. A new Linux CI run is still
required; the CI-font reproduction was performed on the Windows host.

Previous delivery results: analyzer **no issues**; **533 Flutter tests passed**;
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
and desktop, automatic panel activation, preference persistence, stale/non-overlapping
reads, permission retry, mode/expansion controls, renderer failure/retry,
buffering, route coverage, focus, lifecycle and reduced motion.
Document tests cover shared loads, cache flags/clear, failure retry and an
in-flight clear/failure race. Widget/channel regressions cover Android's read
cap at 60 FPS, renderer reuse across parent ticks, backpressure and frozen
hidden Lyrics with retained manual scroll position.
The Node bridge test uses synthetic test tones to check FFT frequency,
cached FFT tables, fast attack/slower release, actual-input transient emphasis,
headroom/silence, onset-aware cycling/fallback, lazy presets, phone pixel-budget
adaptation/recovery, FPS pacing, pause and cleanup.
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
4. On Windows, place another app in front and minimize that front app: both
   modes should keep running without capture restart. Minimize/hide Auralis
   itself and verify stop/resume. On Android verify focus/background stop.
   On both platforms pause, buffer, cover with in-app dialogs, enable reduced
   motion, switch to Lyrics/Video and close during permission/loading. Confirm
   capture is released where required, no stale frames resume and music is unaffected.
5. Test denied/revoked permission, unsupported output effects, missing WebView2,
   GPU/context loss and output-device changes; Lyrics must remain usable.
6. Preserve corresponding-source/notices obligations, including the existing
   native playback limitations in `THIRD_PARTY_NOTICES.md`.
