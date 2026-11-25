# Android efficiency and source removal — 0.1.248

This update is based on the supplied 0.1.247 project. It removes the explicitly retired “On this device” Library source in Music and Video and targets unnecessary work during media playback. It does not claim a measured battery improvement without a physical-phone comparison.

## Implemented changes

| Path | Change | Behavior retained |
| --- | --- | --- |
| Device Library | Remove both source switches, the local Library widget, folder management and persisted source/folder preferences. Ignore legacy keys on upgrade. Remove unused broad Android media-read permissions. | Media files are not deleted. Telegram collections, downloaded Telegram media, explicit video file opening, video playlists/history and all account data remain. |
| Animated seek bar | A render-layer animation listener invalidates painting; the slider, theme, semantics and gesture widgets no longer rebuild every animation frame. Stop the motion when backgrounded or excluded by TickerMode. | Same waveform geometry, amplitude, phase period, thumb and seek interactions; no global frame cap. |
| Hidden player layers | Disable the retained mini-player's tickers while Now Playing covers it. Keep the Video browser offstage and stop its tickers during full video playback. | Existing widget/scroll state is retained; minimizing or closing video reveals the browser again. |
| Video and visualizer listeners | Subscribe to structural playback changes instead of every music position/buffer event. Ignore unchanged native playing, buffering, duration and buffer values. | Track, state, settings, duration and error changes remain immediate. Raw nonduplicate playback events remain available for lyrics, seeking, listening records, Android controls and sync. |
| Home statistics | Use a dedicated relay for changes in the displayed playback second and structural/explicit settings changes. | Listening records still consume every original event. Plays, restores, remote updates and track changes still notify immediately. |
| Settings storage | Encode and hash large snapshots in an isolated top-level computation. Keep write ordering, error propagation and all distinct snapshots. Skip an identical successful write, but recreate a missing file. | Existing save cadence, atomic writes, flushes, recovery snapshots and sync capture hooks remain. No lossy save debounce. |
| Idle sync | Skip projecting and applying an empty response when no operations were sent and the cursor is unchanged. | Existing live notifications, fallback polling intervals, outgoing changes and incoming edits remain. |
| Channel metadata | Accumulate response/image chunks with BytesBuilder instead of boxed integer lists. Decode large catalogue replies off the UI isolate. | Metadata selection, provider fallback, artwork quality, bounds, cache limits and attribution remain. |

All visualizer presets and frame-rate choices, artwork/blur, animations, video shaders, ambient effects, decoder choices, controls, lyrics and synchronization remain available.

## Verification

The added regression tests check:

- source/folder options absent in both modes and legacy preferences retired without deleting a media file;
- the same Slider widget instance through ten animation frames, advancing motion, suspension/resumption with visibility, and working seeking;
- 100 original subsecond/buffer notifications retained, while Home statistics receive one displayed-second update, followed by immediate second-boundary and explicit updates;
- large saves capture detached values, preserve queued A–B–A ordering, skip identical writes and recreate a missing file;
- an idle sync request keeps model identity and application revision unchanged, while a real remote favorite still applies.

Final local checks: **644 tests passed, 24 skipped, zero failures**. Whole-project Dart analysis: **no issues found**. Flutter 3.47.1 / Dart 3.13.1, Linux host, tests run with the normal expanded reporter and CI environment detection. The metadata widget tests, the six previously reported Library regressions, playback/foreground recovery, offline media, lyrics, synchronization, backups and update handling are included in that suite.

These are functional and structural regression checks, not release-build frame profiling or battery measurements. The skipped tests retain their existing platform/opt-in conditions.

## Physical-phone verification still needed

Use the same release build configuration, media, brightness, volume/output, connectivity, display rate and enabled effects on the same phone for both versions. Compare sustained CPU/GPU activity, frame times and battery drain for Music with the screen off, Now Playing/Lyrics with the screen on, ordinary Video, and Video with the same shaders/ambient settings. Verify hardware decoding in Video → Playback information. Repeat a sufficiently long run after warm-up and compare Android battery/Perfetto results. No Android device was connected for this update, so battery percentages, thermal behavior and native release rendering are not measured here.
