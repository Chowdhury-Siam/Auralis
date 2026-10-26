# Auralis changes

## 0.1.85

- Added on-demand Japanese-to-English lyrics with a translation button and original/bilingual toggle on phone and desktop. Original lyrics, timestamps and instrumental gaps remain intact.
- Free Google Translate web lookup falls back to the MyMemory API without an API key. The lyrics dialog explains text sharing and free-service limits; unavailable services show a retry message.
- Translations persist in the account-scoped device cache, keyed by original lyric content. Late song/account changes and failed responses cannot replace the original or cache an error.

## 0.1.84

- The desktop sidebar now spans the full window height, keeping its tagline and Settings button at the bottom beside the player bar.

## 0.1.83

- Shutdown now drains pending artwork/lyric cache reads and atomic writes before returning, preventing Windows file-lock failures during cleanup.
- Widget-test cleanup pumps pending real file completions before leaving the fake clock. Added a multiple-cache-instance drain regression without retrying or suppressing failed directory deletion.

## 0.1.82

- Library Refresh now preloads artwork and available embedded/online lyrics in the background, with progress in the library header. Extracted artwork and lyrics persist in an account-scoped device cache for reuse after restart; audio remains temporary.
- Cache work stops on another refresh, channel/account changes or shutdown. Failed and unavailable entries do not stop the remaining library. Explicit lyric import and lookup actions remain available.
- Moved the desktop bottom player to the right of the sidebar and removed its redundant artwork/title preview in wide layouts, keeping the playback controls and seek bar in the main content area.

## 0.1.81

- Smoothed the player card transition with direct finger tracking and one velocity-preserving spring on release, replacing the compounded easing curve. Quick drags are measured before the first expanded frame.
- Cached the fixed background blur and full player layers, paused decorative tickers during the transition, removed the competing page fade and brought player content in earlier to avoid the blank-card flash.
- Added pixel-distance, retained-blur and frame-interval motion checks alongside existing gesture, cancellation, resize and reduced-motion coverage.

## 0.1.80

- Now Playing grows out of the mini-player card and shrinks back into it, with rounded corners, fading content and a blurred page underneath. Tap or drag up to open; use the down arrow or drag down to close. Short drags settle back into place.
- Horizontal mini-player drags follow the finger and spring back in either direction while playback, queue and sleep timer stay active. Seeking and transport buttons keep their own gestures.
- Added transition, drag-cancellation, screen-resize and reduced-motion checks on phone and desktop layouts.

## 0.1.79

- Fixed widget-test shutdown hangs by releasing completed audio-cleanup futures instead of retaining their original async clock. Pending audio deletions remain serialized before replay.
- Updated adaptive Now Playing checks to allow horizontal artwork swipes while still requiring every control to fit without vertical scrolling. Added a regression check for cleanup across test clocks.
- Live sync uses its account controller's HTTP transport, keeping test requests inside the fake client and closing pending handshakes with their connection.

## 0.1.78

- Added Include Telegram account to Account & sync. Auralis remembers the linked Telegram identity and protects its application connection values in the private Worker.
- New devices can connect that Telegram account with a six-digit approval code entered on an already connected device. Each device receives its own Telegram session; session databases, login codes and two-step passwords are not copied to sync.
- Added approval expiry, one-use requests, account isolation, unlink controls and phone-login fallback. Existing playback, artwork, audio cleanup and rounded media-control changes are retained.

## 0.1.77

- Redesigned the Android system media Stop control with a smaller rounded outline, replacing the oversized solid square in the notification and launcher media player. The icon follows Android’s artwork tint and keeps the existing Stop behavior.

## 0.1.76

- Added username/password accounts, saved account switching, sign-out choices and password-confirmed account deletion. Each account keeps its own library and offline edits.
- Added one-use recovery codes and an owner administration page, with revocable sign-ins and encrypted deployment-credential recovery after reinstalling.
- Redesigned Account & sync and Deploy Database, including automatic Worker updates when an app bundles a newer Worker. Existing private-key Workers migrate using the same secret and database.

## 0.1.75

- Played songs are no longer retained as a growing offline audio cache: previous audio files are removed when playback switches, stops or exits normally.
- Audio fragments used to extract embedded artwork or lyrics are cleaned up after reading; image and lyric caches are retained. Active playback and metadata reads are protected from deletion.
- Connecting Telegram while idle clears audio/document cache left by older versions without clearing thumbnails, photos, account data or the library. The current song can still use a temporary playback/seek buffer.

## 0.1.74

- Replaced the clipped next-cover strip in Now Playing with a full-size artwork carousel. Covers follow horizontal swipes and snap completely into view.
- The artwork stays synchronized with playback controls and supports previous/next swipes, queue boundaries and repeat wrapping.

## 0.1.73

- The Now Playing down arrow smoothly reveals the Library and mini-player underneath as the full player slides down and fades away.
- The returning mini-player stays protected from accidental taps until the transition finishes. Reduced motion and interrupted navigation remain supported.

## 0.1.72

- Now Playing slides smoothly upward when opened from the mini-player, navigation or desktop lyrics preview, matching its downward close animation.
- Opening respects reduced motion, and Back or navigation can safely interrupt the transition without restarting playback.

## 0.1.71

- Fixed sync setup URL validation on Android and Windows: explicit ports, credentials, paths, queries and fragments are rejected before network requests.
- Valid HTTPS, libsql and turso database URLs continue to work, with or without a trailing slash.

## 0.1.70

- Fixed the four reported Android/Windows analyzer lints in sync deployment code and its test fixtures by adding required blocks and override annotations.

## 0.1.69

- Added a searchable Telegram country/calling-code picker to phone sign-in on Android and Windows.
- The verification-code page shows the destination number and offers Change number, with editable phone/country fields, cancellation and a new-code action.
- Correcting a number keeps the same Telegram login session and clears stale verification codes. Pasting a full international number remains supported without duplicating the selected calling code.

## 0.1.68

- Added Yutaka-style Cloudflare + Turso setup and redeployment inside Android and Windows Settings.
- The app prepares database tables, uploads its bundled sync Worker, verifies the service and connects the device automatically after deployment.
- Deployment credentials are protected locally and remembered for retries and service updates. Other devices pair using only the service URL and private sync key.
- Added transactional Turso storage with rollback, conflict retries and live notifications after committed changes. Existing sync spaces and unrelated Workers are protected from accidental replacement.

## 0.1.67

- Android and Windows releases can include Auralis's Telegram application credentials from GitHub build secrets, so users no longer enter an API ID or API hash.
- Configured builds initialize Telegram automatically for phone/code sign-in. Existing sessions and restored backups retain their saved API identity; fresh sign-in after logout uses the build identity.
- Release builds validate both Telegram secrets before compiling. Pull-request and local builds without app credentials retain manual API setup.

## 0.1.66

- Kept the bottom player in a single row on short, wide screens so the Library fits in phone landscape mode.
- Updated volume tests to use Now Playing and fixed lyrics import test timing while an online lookup is pending.

## 0.1.65

- Fixed the Android and Windows analyzer failures by updating the timed swipe tests to Flutter's supported gesture API.
- Updated the lyrics animation to the current ticker API and removed a redundant Android audio import.

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
