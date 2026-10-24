# Auralis changes

## 0.1.64

- Added multi-device sync for favorites, playlists, recent music, listening statistics, channel selections and shared preferences on Android and Windows.
- Added a private Cloudflare sync service with live change notifications, offline retries and deletion tracking. Music, Telegram credentials, playback and volume remain local.
- Split release automation into Android/Windows builds, a publisher that waits for both builds of the same commit, and workflow cleanup.
- Successful build runs are cleaned after their artifacts are published. Failed runs become eligible for cleanup ten minutes after completion.
- Added matching release notes in the app and GitHub Releases, a What’s new page, and automatic notes after upgrading.
- Automatic update checks run at startup, on return to the app and every thirty minutes. Installation still requires confirmation.

## 0.1.63

- Rounded the bottom player card and removed its repeat, sleep timer and volume controls.
- Swipe the bottom player left or right to stop playback, clear the playback queue and dismiss it.

## 0.1.62

- Added cover artwork and the Auralis logo to Android system media controls.
- Moved the lyrics back arrow to the top and removed the duplicate menu and source footer.
- Missing embedded lyrics automatically fall back to LRCLIB.

## 0.1.61

- Swipe or scroll over artwork to change songs.
- Added blurred lyrics and a music animation before the first timed line and during timed instrumental gaps.
