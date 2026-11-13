# Video mode port from mpvRx 3.0.2.1

Auralis 0.1.144+145 builds on the Video mode port from the supplied Auralis 0.1.142 Android CI-fix archive. The reference archive declares mpvRx 3.0.2.1 in `app/build.gradle.kts`. Auralis uses its Flutter theme and libmpv player for Telegram and local videos.

## Using the additions

- All Library collections share the rounded search-and-content panel. Playlists can be found by their name or video titles, History by video title or channel, and Snapshots by frame title or filename. Each section keeps its own filter. Searching does not change saved queues, history or frame files; clear a playlist filter to restore drag-to-reorder handles.
- **Playlists** creates named video lists and lets you add files, reorder entries, rename lists, and remove items. Save the current queue to a named playlist. Telegram entries store chat and message IDs and resolve again through TDLib when reopened. Access to an Android document depends on the provider's persisted read grant.
- **Save video frame** adds a PNG to **Snapshots**, where it can be previewed, exported, or deleted. **Player settings** controls whether the capture includes rendered subtitles.
- **History** lists opened local and Telegram videos and shows saved resume positions. Episodes are marked watched at the end of playback or with the check button beside the episode. Update the Auralis sync Worker to share Telegram history, resume positions, and watched markers between devices.

## Review of partially implemented areas

| Area | Auralis coverage after this update | Remaining mpvRx differences |
| --- | --- | --- |
| Subtitles | Embedded and external tracks, secondary tracks, Wyzie lookup, delay, and persistent supported style and position settings | Sidecar discovery, custom font catalog, drag and pinch on subtitle text, broader provider coverage |
| Skip segments | Manual ranges, AniSkip, seekbar markers, automatic skipping of saved segments, and import from recognized chapter titles | Broader lookup providers and configurable chapter classification |
| Gestures | Tap controls, double-tap seek, horizontal scrub, vertical volume/brightness, hold for speed, and pinch/pan | Per-gesture action mapping and subtitle-specific touch targets |
| Player controls | Editable portrait/landscape control layouts, custom command buttons, bookmarks, chapters, frame steps, and sleep timer | Dedicated frame-review timeline and richer custom button action types |
| HDR | Android GPU-next option, HDR Toys profiles, tone mapping, and refresh-rate matching | Physical HDR output and device/profile compatibility remain unverified |
| Ambient rendering | Texture-based blurred letterbox fill with thermal throttling and persisted mode | Reference shader-based modes and finer controls |
| Background playback | In-app mini-player, continued playback setting, and Android PiP | Unified video foreground service, notification transport controls, and explicit video decoder suspension |
| Scripting | Manual Lua/JavaScript loading, saved mpv/input configuration, and command buttons | Persistent script catalog, modules/options folder workflow, and native script bridge |

## Verification

The Android workflow still uses SDK-provided Ninja and a checksum-verified gperf fallback on TDLib cache misses. The TDLib build script matches the supplied CI-fix archive byte for byte.

Host checks passed for Android tooling, release policy, release notes, and the sync worker. A synthetic FFmpeg clip test verified trim duration, H.264 output, audio removal, and 480×480 crop and resize. Flutter and the Android SDK were unavailable in the delivery workspace. The added Flutter tests, full GitHub Actions APK assembly, and playback/export on an actual Android device still need to run.

For the first ARM64 device check, open a Telegram video and close it using the player Back button and the mini-player Close button. Switch to Music and reopen Video mode. Exit the app with video playing, repeat while opening a video, and check the resume position after relaunch. Reopen a saved playlist and export a snapshot.
