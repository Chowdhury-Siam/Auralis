# Performance audit — 0.1.228+229

## Baseline and scope

Based on the supplied 0.1.226 source and the delivered 0.1.227 skip-button work.
This source-level audit covers the application shell, Music discovery/library,
Now Playing/Lyrics, Video library/player/settings, artwork and playlist photos,
statistics/storage/backups, Telegram transport/streaming/metadata, sync/update/
setup flows, visualizer bridge/capture, and Android/Windows integration.
It is not an exhaustive device-level performance certification.

The newer 0.1.220 asynchronous cached origin blur, 0.1.226 visualizer/volume
fixes, visualizer catalogue, audio samples, native rendering, shadows, blur
radii, transition curves/durations and touch targets are retained. No dependency
updates, rendering-backend switches, global FPS caps, quality reductions or
architecture rewrite were used. Separate requested additions to controls,
gesture settings and translation UI are documented in INPUT_AND_TRANSLATIONS.md.

## Implemented changes

| Area | Finding and implementation |
| --- | --- |
| Video rendering/rebuilds | Position/buffer events rebuilt the whole visible HUD. A local listenable updates only the timeline inside its own repaint boundary. Skip-segment crossings and structural state still refresh the HUD. Ordinary buttons/title retain widget identity across progress updates. |
| Collection animations | Every scroll pixel rebuilt Offstage/TickerMode wrappers. Visibility now changes only at the same visibility threshold; the PageView still animates every frame with the same 240 ms curve, scroll physics, keep-alive and semantics behavior. |
| Lyric parsing | Grouping rescanned all timed lines for each distinct timestamp. A single grouping map preserves insertion order within each timestamp, then sorts timestamp keys. This removes quadratic scans, and reuses the word-timestamp regexp per parse. |
| Home statistics | Selecting one top track sorted and allocated the complete history on every live card update. A linear selection preserves the exact milliseconds/ID tie break and reads current mutable statistics. Full ranked statistics remain available unchanged. |
| Android media controls | Progress ticks scanned queue equality and consulted artwork even when neither changed. Existing structural notifications handle queue/artwork/duration; the original event stream still supplies every progress event to the system playback-state logic. Artwork upgrade, retry, source-generation and shutdown checks remain. |
| Background decoding | JSON payloads at least 256 KiB from settings, lyrics HTTP and sync are decoded in an isolate. Small payloads avoid isolate startup. Schema validation, byte limits, error handling and cache scopes remain in their callers. |
| Sync allocations | Bounded response accumulation uses byte chunks rather than a growing boxed integer list, retaining the original 4 MiB response limit and request semantics. |
| Input work | Repeated pointer moves within the same temporary-speed step no longer queue identical native speed calls; feedback and auto-hide rearming remain. Disabling a hold/keyboard input, locking, backgrounding or disposal restores temporary speed. |
| Marker painting | Equal chapter/bookmark marker lists do not request an unnecessary marker repaint merely because the list was reallocated for a progress update. |

## Audit decisions: preserve existing work

- **Shell/Now Playing:** structural player relays already exclude progress ticks;
  live seek bars, lyrics and stats retain their local event listeners. Artwork
  backdrop crossfades already filter the individual retained covers. The origin
  page already captures asynchronously with generation checks and image disposal.
  These newer implementations were not replaced by older blur implementations.
- **Images/memory:** existing bounded cover jobs, image inspection/decoding,
  32/64-entry metadata caches, preview upgrades, lazy preset pages, photo size/
  dimension limits and explicit image/codec disposal are retained. No speculative
  image-cache enlargement or lower-resolution artwork was introduced.
- **Scrolling:** Music/Video list/grid/pager builders are already lazy. Small,
  intentionally bounded settings/menu/home collections remain eager to preserve
  layout. No fixed row-height assumption was introduced for large text/lyrics.
- **Async/I/O:** streaming is chunked and cancellation-aware; TDLib transport,
  encrypted backups and embedded metadata processing already use isolates.
  Saves retain their ordering and atomic-write behavior, not a potentially
  lossy debounce. Library/network workers retain existing bounded concurrency.
- **Visualizers/platforms:** capture serialization, fresh-sample handling,
  pause/visibility handling, render-size adaptation, refresh-aware web pacing and
  native stop/cleanup are retained byte-for-byte. No native/third-party source,
  presets or licences were changed for this release.
- **Startup/update/setup:** existing deferred sync/Telegram/updater initialization
  remains; large settings decoding is the targeted startup change. Full settings
  serialization, sync record merging and very large library sorting can still
  consume UI CPU and remain candidates for device profiling, not claimed fixes.

## Measured locally

Flutter **3.47.1**, Dart **3.13.1**, Windows host, Flutter test/debug VM.
These are **CPU microbenchmarks, not app frame times or release-build timings**.
The same deterministic inputs are used for both implementations, with warm-up,
seven measured trials and the median per-operation time. The legacy parser
fixture preserves the delivered algorithm; differential tests compare its exact
output against the optimized parser, including simultaneous lines and offsets.

| Equivalent workload | Before | After | Local ratio |
| --- | ---: | ---: | ---: |
| Parse reverse-ordered 2,000-line LRC | 60,037.4 µs | 8,139.6 µs | 7.4× faster |
| Select top track from 10,000 history entries | 2,526.4 µs | 110.1 µs | 22.9× faster |

Reproduce:

```text
flutter test --no-pub --concurrency=1 --reporter expanded --dart-define=AURALIS_BENCHMARK=true test/performance_workloads_test.dart
```

Wall-time ratios vary with host, VM warm-up and load and are not CI thresholds.
Deterministic regression checks also verify:

- unchanged Video title/button identity through 11 position updates, a live
  slider value on each update, and disappearance of the skip prompt at its end;
- unchanged collection visibility-wrapper identity during ordinary swipe pixels,
  while paging and hit testing still work;
- no artwork callback/queue-object churn through 200 Android progress events,
  while system position still updates;
- valid/malformed small and large JSON produces equivalent results/errors;
- independent gesture persistence/defaults, speed restoration, safe fallback,
  full-width DPR/safe-inset layout, translation alignment and audio preservation.

## Verification and limits

Final suite results are recorded in VERIFICATION_0228.md.
The benchmark above passed all four workloads. The optional benchmark is skipped
in ordinary full-suite runs to avoid flaky performance assertions.

No Android SDK or Visual Studio C++ build toolchain is available on this host.
Therefore native profile/release builds, Flutter DevTools UI/raster traces,
GPU counters, shader/pipeline compilation stalls, battery usage, peak/steady
GPU texture memory, long-session leak measurements and real-device input/
playback/export checks are **not verified**. Automated widget tests do not prove
that no visual differences or native regressions exist.

The principal remaining native risks are full-window blur/video ambient effects,
WebView/preset GPU cost, decoder/hardware acceleration and integrated-GPU driver
behavior, cold graphics-pipeline compilation, large library/sync processing and
OS thermal/power/refresh policies. No device bottleneck or leak is claimed to have
been measured without a trace. Neither “lag-free” nor guaranteed 60–120 FPS is
claimed.

## Required Android/Windows profiling follow-up

1. Build the supplied baseline and this version with the same Flutter/toolchains,
   dependencies, media, data, window/DPR, power mode and display refresh setting.
   Use a physical Android phone (including low-end hardware) and Windows on an
   integrated GPU, then a capable 90/120 Hz device where available.
2. Run `flutter run --profile -d <device>` and attach Flutter DevTools. Record
   cold and warm startup, 60 seconds of library scrolling, repeated player
   open/close/navigation, lyrics following, rapid seeking, gesture drags and
   visualizer/preset changes, both with and without concurrent sync.
3. Record UI/raster frame distributions (p50/p90/p99, over-budget frames),
   CPU samples and allocations. Use 16.67/11.11/8.33 ms frame budgets at
   60/90/120 Hz respectively. Inspect graphics-pipeline compilation and use
   Android Perfetto/GPU tools or Windows GPUView/WPA for native/WebView costs.
4. Take comparable memory snapshots after warm-up and 20–50 repeated interaction
   cycles; compare retained controllers/listeners/images/textures after GC.
   Verify pause/resume, minimize/PiP, source/account changes and disposal.
5. Recheck visuals, safe areas/RTL/accessibility, exact animation timing, native
   inputs and lossless metadata exports on release builds. Report the actual
   before/after device numbers; do not extrapolate the host CPU ratios to FPS.
