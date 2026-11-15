# Playback UI lag: 0.1.214+215

The supplied Windows recording shows Library → Now Playing → Library activity
without a visualizer on screen. A recording identifies the affected interaction;
it cannot profile Flutter build/raster costs or prove a particular root cause.
No user recording or extracted frames are included in the source distribution.

## Changes without feature removal

- **Separate structural UI notifications from progress.** `PlayerController`
  still sends every existing event to its original listeners. A separate
  `viewChanges` relay excludes audio position/buffer-only events, but includes
  playing, buffering, startup/completion, duration, errors and explicit queue,
  favorites, settings and other controller changes. Statistics recording, sync
  and the playback backend/event timing remain unchanged.
- **Update only the live regions.** Dock/full-player timelines, Lyrics and
  Home's listening-stat card listen locally to the full stream. Library/Daily
  Mix layout, artwork, palette work, cover prewarming and the static backdrop
  no longer rebuild for each progress tick. Lyrics following, seeking and
  live statistics are retained, not throttled or disabled.
- **Keep the origin blur without page-image readback.** The desktop expansion/
  collapse effect now filters one retained real page/display list. It no longer
  uses app-owned `SnapshotWidget`, `PictureRecorder`, `toImageSync` or page-image
  caches. The blur reaches the existing eight-logical-pixel radius. Filter
  strength follows transition progress and disables when settled. Android keeps
  its existing lighter origin transition.
- The mini-player spring geometry, artwork background blur/crossfades,
  hover/swipe/paging effects, library scroll state, transport, Lyrics, translation,
  visualizers and all settings remain. No animation or visualizer feature is
  removed, and reduced motion remains a user choice.

## Regression checks

`test/player_ui_updates_test.dart` checks original event delivery, structural
relay filtering, live seek-bar values with unchanged library/artwork/backdrop
widget identity, real state refresh, local Home statistics and native-event
Lyrics following without a parent rebuild. Desktop/Android UI variants exercise
the progress path. Existing transition tests still verify opening, collapse,
dragging, interruption, navigation and reading/scroll retention.

`test/player_origin_snapshot_test.dart` retains DPR 1/2 pixel checks for the
visible blur, one page/display-list paint across animation frames, resizing,
fresh content after return, disabled settled filtering and safe disposal.
The legacy file/class names remain for compatibility; their implementation no
longer captures page bitmaps. Flutter itself may use snapshot layers for its
own Navigator transitions; the checks target Auralis's player-origin subtree.

## Limits

Final local verification: **551 Flutter tests passed** with Flutter **3.47.1**
and Dart **3.13.1**, analyzer **no issues** (`--no-pub --fatal-infos`), and
renderer energy/source, release-note and Android source checks passed.
The initial full-suite host process ended without a completion/failure summary;
its two confirmed orphan test processes were released and the complete
`--concurrency=2` rerun passed. No failing assertions were suppressed.

Native Android/Windows builds, a live replay of the recorded interaction, and
before/after device frame-time, GPU, battery and memory measurements remain
unverified here. Android SDK and Visual Studio C++ build tools are unavailable.
No FPS improvement or universal lag-free result is claimed from widget tests.
Test release builds on the affected Windows computer and phone, including a
large library and repeated cold/warm open/close, while music and visualizers run.
