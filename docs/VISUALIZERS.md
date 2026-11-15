# Music visualizers: implementation and verification

Version: **0.1.215+216**, retaining the **0.1.214+215** UI lag/energy changes, **0.1.213+214** focus/performance changes, **0.1.212+213** positioning fix, **0.1.211+212** Windows SDK fix, **0.1.210+211** Lyrics fix, **0.1.209+210** visualizers and supplied **0.1.208+209** Lyrics redesign.

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
  Version 0.1.214 selects `SCALING_MODE_AS_PLAYED`, not `NORMALIZED`, to retain
  quiet/loud dynamics. Low output volume can therefore reduce visible response.
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

Final 0.1.215 local verification: **552 Flutter tests passed** with Flutter
**3.47.1** / Dart **3.13.1** (`--concurrency=2`); analyzer **no issues**
(`--no-pub --fatal-infos`); all **46 Node sync/workflow-policy tests passed**.
Node renderer regressions, source/license hashes, release-note consistency and
Android source checks passed. Recorded-audio and 99-preset browser results and
their native-device/perception limitations are detailed below.

## Visible song response in 0.1.215

The 0.1.214 internal-energy tests did not establish convincing visible
real-song synchronization. Review of the supplied 33.7-second recording showed
that authored preset motion still dominated. This version adds a default-on,
device-local **Song-driven motion** switch. Original preset equations and
appearance remain available by turning it off. Spectrum, Lyrics and all presets
and controls remain; playback/native capture and the UI lag fixes are unchanged.

- The existing per-sample FFT also measures positive per-bin spectral change
  in bass/mid/treble. This catches attacks in compressed music without requiring
  a large jump in whole-song RMS. Band energy/noise floors, a 100 ms per-band
  refractory interval and a 110 ms impulse decay suppress noise/repeated held
  notes. There is no generated BPM clock.
- Normal captured song RMS around .05 mapped to approximately .2 under the
  previous linear gain. The new perceptual mapping `3 * sqrt(RMS)` (capped at
  1.8) places it in a more useful range for MilkDrop equations, while maintaining
  quiet/loud contrast, absent-band gating and the existing stale/silence rules.
  Bounded spectral impulses also accent the appropriate preset energy band.
- A copy of each preset's frame equation retains the original equations,
  shaders, shapes and waves and adds bass-driven feedback zoom (at most 1.8%
  per-frame multiplier), up to .04 extra warp and restrained waveform scaling.
  Original vendor assets/preset objects are not edited. Switching the setting
  off reloads the untouched equations; it does not remove the preset.
- Independently of preset behavior, one canvas compositor transform and opacity
  make actual attacks/energy visible. Bass movement is bounded to **3.5%**
  outward scale, smoothed with 18 ms attack/110 ms release. Visibility follows
  absolute energy with 30 ms attack/160 ms release; the small onset contribution
  never exceeds full opacity. It is not a white flash, extra rendering canvas
  or synthetic waveform. Silence fades autonomous motion; pause retains the
  last displayed frame. Histories reset so resume cannot replay a stale beat.
- Rendering supplies positive, bounded real elapsed time explicitly. This
  avoids the pinned engine's zero-delta first-frame FPS singularity. FPS choices
  and phase-preserving pacing remain independent of audio sensitivity.

### Recorded-audio replay

The audio from the user's recording was decoded **locally**, resampled to
44.1 kHz and converted to 1024-sample mono unsigned-byte windows at 30 Hz, then
fed through both the delivered 0.1.214 bridge and revised bridge with controlled
positive frame times. Both compiled engines rendered **1,011 frames per preset**
at 400x300 for the two presets visible in the recording:

| Preset | Previous pixel-brightness/RMS correlation | Revised |
| --- | ---: | ---: |
| Aderrasi + Geiss - Airhandler (Kali Mix) - Canvas Mix | .14 | .54 |
| Aderrasi - Potion of Spirits | .08 | .42 |

The check sampled 64x48 output pixels including canvas opacity/transform,
excluding the first second. New master visibility/RMS correlation was .88;
scale stayed between 1.000 and 1.03314. The quieter 7.5–11.5 s passage averaged
.325 visibility versus .635 at 1–6 s. These figures support improved energy
coupling, **not** perfect beat perception, exact phase alignment or a performance
benchmark. Pixel brightness depends on the preset; the master correlation is
partly inherent to its mapping. Native capture/embedding latency was not tested.

All **99 selectable presets** were additionally compiled/rendered with the
modified equations; checked bass/mid/treble/zoom/wave-scale/warp outputs remained
finite. No renderer errors occurred. User media, extracted audio and private
replay screenshots/scripts are not shipped in the source ZIP.

Node regressions exercise the real pinned audio classes plus visible transform/
opacity, equation feedback, quiet/loud contrast, spectral attacks at equal
amplitude, held-note stability, silence/stale release, positive elapsed time,
immutable preset source and reversible original appearance. Flutter tests cover
default-on/migration, device-local persistence and reversible settings while
keeping all preset controls. Real Windows/Android song response, performance,
battery and capture latency still require device testing.

## Earlier verification history

Final 0.1.214 local validation with Flutter **3.47.1** / Dart **3.13.1**:
**551 Flutter tests passed** (`--concurrency=2`); analyzer **no issues**
(`--no-pub --fatal-infos`); **46 Node sync/workflow-policy tests passed**.
The real Butterchurn audio/equation-energy bridge regressions, source/license
integrity, release notes and Android source checks passed. The compiled-engine
Chromium energy check is recorded below. Android/Windows native builds and
real-device song response remain unverified; the previous two Python signing
tests still require the missing JDK `keytool`. This includes the UI lag
regressions described in `docs/PERFORMANCE.md`. An initial host run ended
without a failure/completion summary; confirmed orphan test processes were
released and a complete rerun passed.

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
- FFT Hann/twiddle/bit-reversal tables are precomputed. One shared FFT per
  captured frame provides Spectrum bins or animated energy bands; animated mode
  skips Spectrum-only logarithms/smoothing. Spectrum's disconnected Web Audio
  context is suspended.
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

Beat response uses captured waveform data, not an animation clock. Spectrum
retains fast spectral attack (85%) and slower release (30%). The 0.1.213
headroom-limited waveform boost did not preserve sustained song dynamics:
Android normalized capture amplitude, while Butterchurn normalized each band
against a long average and eventually returned a neutral value of 1 in silence.
The new real-audio-pipeline test reproduced the sustained loud/quiet failure
before the 0.1.214 fix.

Version 0.1.214 passes the original waveform to Butterchurn without gain or
clipping. A pinned adapter runs its native audio analysis, then supplies actual
preset-equation `bass`/`mid`/`treb` and attenuated values. Bands use Hann-window
power corrected by its squared-window sum: 20–320, 320–2800 and 2800–11025 Hz.
DC-removed waveform RMS supplies absolute loudness (4x RMS, capped at 1.8),
so quiet and loud passages cannot simply converge to identical levels.
Each band is weighted by its presence and contrast against a two-second
time-based band average (contrast capped at 2, final values at 4). RMS below
.006 and band RMS below .003 reject silence/8-bit quantization noise. The
attenuated values use 45 ms attack/140 ms release. Missing samples start
releasing after 100 ms and reach zero at 250 ms; stop/reset clears all history.
No extra messages or per-animation-frame shared FFTs are added.

Onsets used for preset cycling track full/bass/high-band energy against
300 ms averages, require an energy floor and ratio above 1.35, and are spaced
more than 120 ms apart. Timed changes wait for an onset for at most 1.5 seconds,
then use the normal transition. This is not an exact beat grid or BPM detector.
All 99 presets remain; preset-authored time-driven motion is not removed and
some presets naturally emphasize audio more than others.

The compiled bundled Butterchurn engine was also exercised in Chromium at a
240x160 test surface with controlled synthetic samples and clock increments.
A quiet 90 Hz passage produced preset bass energy **0.233**; a louder passage
produced **1.898** (8.1x), with absent mid/treble values at zero. Silence produced
zero instantaneous bands and released the attenuated bass to approximately
6.1e-10. The actual preset equation globals also received zero bass/mid/treble
in silence. All 99 presets were available and no engine/console errors occurred.
This validates the compiled adapter path, not real-song synchronization on a
phone or native Windows output capture.

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
The Node bridge test executes the exact retained Butterchurn FFT/audio processor
and level classes via `tool/visualizer-audio-fixture.mjs`, not just a sample
receiver stub. It checks actual preset energy for sustained quiet/loud contrast,
independent bass/treble, silence, stale release and unmodified waveforms. It
also checks FFT frequency/tables, fast Spectrum attack/slower release,
onset-aware cycling/fallback, lazy presets, phone pixel-budget
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
