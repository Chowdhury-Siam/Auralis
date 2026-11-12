# Auralis changes

## 0.1.177

- Move Settings & diagnostics into Video Settings. Open Video settings from the playback menu to use live diagnostics.

## 0.1.176

- Hide Lyrics & artwork in Video mode Settings and Settings search.

## 0.1.175

- Move manual video refresh to Browse. Refresh the selected video channel and discover new Telegram channels from the same control.

## 0.1.174

- Fade in Now Playing artwork and controls as the panel expands, removing the blank panel pause on mobile and desktop.

## 0.1.173

- Fix the Flutter analyzer warning in the Music Browse layout toggle.

## 0.1.172

- Make the mini-player follow vertical drags with a blurred background and a staged Now Playing reveal. Fade the full artwork and controls in once the panel settles.

## 0.1.171

- Select multiple music channels in Browse. Move Artists to the Library collection menu and remove the Telegram navigation item and Home sync shortcut.

## 0.1.170

- Rename Music Search to Browse and use the same compass icon as Video on mobile and desktop. Show Browse channels or Browse artists above the music collection.

## 0.1.169

- Remove the cloud, Telegram, and Settings shortcuts from mobile Music Home. Let the Music Search field fill the header.

## 0.1.168

- Remove Settings shortcuts from Video Home and Browse on mobile. Let channel search fill the Browse header.

## 0.1.167

- Add Orientation to the default Android portrait controls, remove A–B Loop, and make Fullscreen desktop-only.

## 0.1.166

- Center video loading on play and pause, show brightness and volume on their gesture sides, and move seek feedback above the transport controls.

## 0.1.165

- Start Android videos in landscape in Match video mode. Switch to portrait once portrait playback is ready.

## 0.1.164

- Align video controls and the seek bar to the picture on desktop and mobile.
- Tap Space to play or pause on desktop. Hold Space for 2× speed and release to restore the previous speed.

## 0.1.163

- Redesign the video queue with compact rows, a subtler highlight for the current video, and a visible shuffle toggle.

## 0.1.162

- Remove the chevron from unselected channel rows in Video Browse.

## 0.1.161

- Remove the Music shortcut from Video Home and Library and the Telegram shortcut from the desktop Video sidebar.

## 0.1.160

- Rename the Video Search tab to Browse on phones and desktop. Search channels within Browse.

## 0.1.159

- Dim watched video titles and show their thumbnails in grayscale while keeping the videos available for replay.

## 0.1.158

- Move Playlists, History, and Snapshots into the Video Library options menu.

## 0.1.157

- Open Android videos in landscape or portrait according to the video, with a per-video orientation override.
- Keep Android playback responsive while Telegram buffers. Show Retry when startup stalls.
- Interrupt pending video reads and wait for the Android decoder to shut down before releasing its surface.

## 0.1.156

- Verify the Telegram backup switch by toggling it on phone and desktop layouts.

## 0.1.155

- Keep the backup selection summary and options reachable when resizing at large text sizes.

## 0.1.154

- Update CI widget tests for channel selection and make the Telegram account backup setup deterministic.

## 0.1.153

- Remove the unused Telegram Video field flagged by static analysis.

## 0.1.152

- Wait for Windows video textures and the renderer to shut down before closing the player.

## 0.1.151

- Mark Telegram episodes watched after playback, or change the watched status manually.
- Sync Telegram video history, resume positions, and watched markers between devices.
- Select channels directly from Browse channels. Remove Telegram link opening and video compression.

## 0.1.150

- Group video controls by task and improve the audio, subtitle, decoder, speed, chapters, and queue panels.
- Stop Windows video playback before detaching the video surface and releasing the decoder.

## 0.1.149

- Accept either startup order for concurrent artwork requests in CI.

## 0.1.148

- Synchronize video shutdown assertions with decoder and stream disposal in CI.

## 0.1.147

- Fix the video shutdown test's asynchronous cleanup in CI.

## 0.1.146

- Fix build analysis errors in Video mode.

## 0.1.145

- Simplify first-run setup and Appearance settings.

## 0.1.144

- Remove Web playback, Syncplay, and the Open files, Browse folders, Open stream, and Open playlist actions from Video mode.
- Release the video decoder before closing its Telegram stream and wait for video cleanup on app exit.

## 0.1.143

- Trim, center-crop, and compress local videos to MP4 with presets, audio removal, progress, and cancellation.
- Save and reorder video playlists, discover local M3U and M3U8 files in browsed folders, and reopen videos from persistent playback history.
- Capture frames to a snapshot library with preview, PNG export, and deletion. Remember subtitle styling and ambient lighting, and import skip segments from marked chapters.

## 0.1.142

- Browse pinned local video folders with grid and list views, queue selection, sorting, and resume markers. Open videos shared to Auralis from Android.
- Resolve video website URLs with yt-dlp and set resolution, frame rate, codec, container, audio bitrate, and HDR preferences.
- Add HDR Toys processing presets for GPU-next, an optional Android GPU-next renderer, and Android display refresh-rate matching.

## 0.1.141

- Keep video playback running in a mini-player while browsing Video mode, and import M3U playlists into the video queue.
- Add Syncplay rooms, Wyzie subtitle search, AniSkip lookups, and editable skip segments with seekbar markers and optional automatic skipping.
- Add custom mpv command buttons, Lua and JavaScript script loading, mpv configuration editing, live playback statistics, and black-bar detection.

## 0.1.140

- Rework Video playback with mpvRx-style portrait and landscape controls, editable control layouts, playback gestures, chapters, bookmarks, and per-video resume.
- Open Telegram videos, local files, and HTTP streams in a shared player with an editable queue, dual subtitles, frame controls, and Android picture in picture.
- Add Anime4K presets, ambient lighting, decoder settings, and video processing controls.

## 0.1.139

- Give Music Library a split collection selector and a themed toolbar for shuffle, refresh, and sorting. Keep search in its own field and retain the optional collection tabs.

## 0.1.138

- Match Video Search to Music’s browse layout with themed channel tiles and a list toggle. Highlight the active Library channel in both views.

## 0.1.137

- Give the Library search field and collection selector their own cards, with a gap between them on phones and desktops.

## 0.1.136

- Redesign the Android and Windows mini-player with round artwork, a compact tinted layout, and circular playback controls. Keep seeking available below the Android controls and inline on Windows.
- Connect the linked Telegram account automatically after an Auralis password sign-in when an updated, already connected device is online. Keep Telegram two-step verification when Telegram requires it.

## 0.1.135

- Let Video Library and channel results scroll behind the floating navigation bar, matching Music. Keep the last item above the bar when fully scrolled.

## 0.1.134

- Use one Auralis layout for in-app dialogs, including Telegram sign-in, playlists, lyrics, backups, sync accounts, video controls, and updates.
- Match menu choices, selected rows, search fields, cards, buttons, chips, tooltips, and notifications to the active artwork theme.

## 0.1.133

- Mark the selected channel in Video Search and automatically load all playable videos as Telegram pages arrive.
- Upgrade cached low-resolution previews when sharper artwork is available. Preload neighboring covers, use sharper artwork on high-density displays, and keep blur, swipe, and player transitions.
- Use the active artwork theme across app dialogs, menus, notifications, and video controls.

## 0.1.132

- Remove the channel dropdowns from Video Library and Search. Find channels by name in Video Search.
- Open a channel's videos inside Search with the same compact rows, square artwork, and sort order as Library. Library remembers the last channel opened.

## 0.1.131

- Fall back to the public GitHub release and its published checksums if the Releases API is unavailable. Keep platform, installer size, and SHA-256 checks.
- Show a more specific update-check error and add a GitHub Releases button for manual downloads.

## 0.1.130

- Find Telegram channels by name in Video Search and open them in Library. Filter the channel picker to switch channels from either tab.
- Use square thumbnails in Video Library and apply the shared Library sort order. Title (A–Z) is the default when no order is saved.

## 0.1.129

- Refresh Telegram channels on entering Video, returning to the app, or tapping Refresh. The open channel picker updates when a new channel arrives.
- Load recent videos from channel history while Telegram search catches up, and add newly posted videos to the open Library.
- Use compact rows with smaller thumbnails in Video Library.

## 0.1.128

- Center and style Video dialogs for choosing channels, opening Telegram links, and changing playback speed, audio tracks, or subtitles.
- Keep Video Search results separate from the Library's channel videos. List channels on Video Home once a playable video is found.

## 0.1.127

- Match Video to Music with shared Home cards, channel browsing tiles, desktop sidebar and all three navigation styles; use the same saved appearance settings in both interfaces.
- Give Video Search a compact search field and channel grid, keep channel searches in Search, and adapt Home, Search and Library to narrow screens and large text.

## 0.1.126

- Add Music and Video interfaces with separate navigation, a startup choice in setup and General settings, and Home hold to switch between modes.

## 0.1.125

- Hold Home to open Telegram Video. Browse a channel or paste a message link, then stream with fullscreen, seek gestures, speed, and audio and subtitle track controls.

## 0.1.124

- Retry missing local thumbnails and confirm lyrics are saved to disk before counting them. Tap the Library cache totals to see which tracks still need artwork or lyrics.

## 0.1.123

- Sync recently played tracks and qualified plays promptly, send listening progress every five seconds, and refresh open listening stats when another device syncs.

## 0.1.122

- Merge the full cloud copy with the existing local sync document and keep pending changes for the next upload.
- Add playback repeat and library sort order to General and move the setup shortcut to About.

## 0.1.121

- Removed standalone CSV and JSON exports and the Backup & Restore section from Listening stats.

## 0.1.120

- Show listening time or play count for every timeline period and wrap monthly bars on narrow screens.

## 0.1.119

- Redesigned Backup & Restore with a compact dialog and distinct export, restore, and recovery actions.

## 0.1.118

- Fixed cloud sync reverting corrected listening-stat titles and artists when a backup restored names without changing listening time or play counts.

## 0.1.117

- Added a dedicated Export Backup page with section switches, a live selection count, and Select all and Deselect all controls.
- Selective backups restore the sections they contain and keep other local data. Full backups and password-protected Telegram backups remain supported.

## 0.1.116

- Added Home with a Daily Mix, recently played music, and a listening stats preview.
- Added a Search tab with song, artist, and channel search, plus grid and list views for browsing channels and artists.
- Redesigned Listening Stats with time ranges, an interactive timeline, track and artist rankings, and listening habits.
- Put sync status and manual sync first in Account & sync, with separate sections for Telegram, the Worker, and account management.

## 0.1.115

- Fixed HTTP 503 on Turso-backed sync by using a Workers-compatible fetch call and rejecting Turso redirects explicitly. Deploy the updated Worker to apply the repair.
- Worker logs now show the database operation stage and the upstream HTTP status when available.

## 0.1.114

- Fixed a sync stall where separately received listening counters could block favorites, playlists, and other library changes from reaching another device.
- Account & sync now offers **Sync now** for a two-way sync and shows clearer messages when a Worker rejects the request or its database is unavailable.

## 0.1.113

- Replaced the full-width update banner with a compact floating card on Android and Windows. It shows download progress and release notes. Dismiss it to hide the notice for the current session.

## 0.1.112

- Hold or right-click **Find lyrics online** to search LRCLIB by song name or artist, then choose the matching track.

## 0.1.111

- Connect to your Worker Sync account on the first screen, create an account, or skip setup and connect later in Settings.
- Redesigned optional setup with clearer progress, interactive previews for library and navigation styles, and a shortcut to skip the remaining steps.
- Fixed the navigation test to match the three phone tabs and removed a missed tap from the lyrics settings test.

## 0.1.110

- Removed the Now Playing shortcut from phone and narrow-window navigation. Tap the mini-player to open the full player.
- Worker validation opens owner account setup when no owner exists. Worker update warnings clear when checks succeed, and the Worker base URL shows public health status after updating.

## 0.1.109

- Removed the Now Playing shortcut from the desktop sidebar. Open the full player from the mini-player.
- Reduced rendering work when opening and closing Now Playing by reusing the blurred background and cover artwork across animation frames.

## 0.1.108

- Now Playing carries the visible cover from the mini-player into the full artwork position, and back when collapsed. The expanding panel keeps its existing spring motion, while the cover follows the same progress instead of entering from beneath the screen.

## 0.1.107

- Kept artwork and lyric cache keys stable when Telegram file or thumbnail IDs change. Existing cache entries are read and migrated without deleting saved files.
- Saved artwork warming now notifies the player when a prior cover lookup missed. Explicit refresh can retry a thumbnail that failed earlier, and a cached lyric miss no longer hides words subsequently saved to disk.
- Changed the Library tooltip to describe saved cache totals and retrying uncached media, without claiming that the original artwork or lyrics are unavailable.

## 0.1.106

- Removed the desktop Now Playing side panel so Library and Telegram use the available width. The bottom player and full Now Playing page remain available.
- Moved the compact Library collection dropdown into the right end of the search bar, with room for search clearing and bounded labels on narrow windows.

## 0.1.105

- Account & sync now fills the Worker URL as soon as deployment or a saved connection updates it, including when returning from Deploy Database. Unrelated updates preserve a Worker URL being edited.
- Owner sign-in, account recovery, account switching and restored owner sessions recover all saved deployment fields and the automatic-update preference from the encrypted recovery vault. If that recovery copy is missing, a signed-in owner can replenish it from complete saved local credentials. Other accounts cannot recover those credentials.

## 0.1.104

- Separated Windows updater test fixture compilation from the 30-second executable handoff check. Cold PowerShell/.NET startup now has a bounded setup allowance, and compilation, launch and missing-output failures report their own diagnostics. Fixture arguments are published only after the complete file is written.

- Accepted regional Turso database hostnames in the app and bundled Worker while retaining strict endpoint checks. The bundled Worker version advances so automatic updates can install the matching fix.

- Matched setup direction, lyric-source and translator dropdowns to the app’s rounded, themed choice menus. Menus are anchored below their fields, bounded in width and mark the current choice; field labels stay visible and setup busy states disable selection.

## 0.1.103

- Restored the original artwork hover zoom, lift and pointer-following tilt. The animation now wraps the carousel viewport so the rounded cover and its clipping area move together, preserving the full artwork. Reduced motion and artwork navigation remain supported.

## 0.1.102

- Removed the decorative artwork zoom, lift and tilt on mouse hover. Now Playing keeps the full rounded cover inside its carousel at every pointer position; artwork swipe and wheel navigation are unchanged.

## 0.1.101

- Replaced the expandable lyrics settings panel with a regular scrolling card. Removed artwork preload and retention controls from Settings and setup; saved artwork is kept automatically and old switches are ignored on restore.
- Saved covers now load independently of the two-job metadata limit. Uncached visible requests wait for a slot instead of completing with no cover; upcoming queue artwork is decoded from saved files without starting another library caching pass.
- Cache checks decode images to reject damaged files. Refresh retries missing artwork and reports actual saved artwork/lyric totals, preserving existing valid files.

## 0.1.100

- Expressive and Classic navigation pills now float over the page. Music and other scrolling content remain visible through the surrounding margins and the gap beside Search, with no reserved solid strip behind the pills.
- Bottom scroll padding keeps the last item reachable above navigation and the mini-player, including the gesture inset.

## 0.1.99

- Restyled every Settings category with compact rounded cards, themed icon tiles, clearer actions and grouped update status. Library and preference choices use bounded rounded menus with a checkmark for the selected item.
- Matched active shuffle and repeat colors to the favorite button, and removed the redundant Settings shortcut from Now Playing. Settings remains available through the normal app navigation.

## 0.1.98

- Fixed the dark strip above Now Playing by extending its artwork background into the top system inset while keeping player and lyric controls inside the safe area.
- Library, navigation and the mini-player retain their safe positions during opening, collapse and rotation; the volume overlay also stays below the top inset.

## 0.1.97

- Fixed the refresh-cache widget test’s Windows CI shutdown hang by running refresh filesystem work outside the fake clock and pumping until cleanup actually completes.
- The regression still verifies partial caches, repeated refreshes, disk reuse after restart and unchanged existing files. Incremental app caching behavior is unchanged.

## 0.1.96

- Library Refresh now checks the saved cache first and queues only tracks missing artwork or lyrics. The progress total counts those tracks, and a fully cached library has no caching pass.
- Cached artwork and lyrics are reused without rewriting their files. Missing or invalid entries can be retried; cache keys still isolate accounts and changed song metadata.

## 0.1.95

- Matched Settings to Auralis with its compact header, accent-colored back control and icon tiles, quieter rounded category surfaces, and the same search-field shape as Library.
- Settings uses the active artwork color scheme throughout; category search, navigation and existing controls remain available.

## 0.1.94

- Fixed the compact Library collection dropdown overflowing in narrow windows when Recently played or another long label is selected. The pill keeps its natural width when space permits and constrains the selected text when needed.
- Added a regression check using Flutter’s wide fallback test font, which reproduces the Windows CI failure. Setup screenshot tests now load the Windows font on Windows and the Linux font on Linux.

## 0.1.93

- Redesigned Settings as a searchable directory with compact grouped rows and rounded outer corners, followed by focused General, Appearance, Lyrics & artwork, Data & sync, Privacy & security, App updates and About pages.
- Search recognizes settings/features and provider names. Category Back returns to the filtered directory; another Back returns to Library. Existing media controls, setup, backups, stats, sync, update installation and sign-out remain available, with the floating player retained.

## 0.1.92

- Added a first-run setup with a welcome screen, Telegram connection/channel selection, optional Android notification and battery settings, backup restore, lyrics/translation and artwork preferences, library layout and navigation choices, and a completion screen. Existing installs keep their library; setup can be reopened from Settings.
- Added compact collection navigation and expressive/classic floating navigation styles, with a configurable corner radius. Appearance choices persist and are included in backups; desktop retains its sidebar.
- Copy lyrics & open DeepL now includes available LRC timestamps, preserving milliseconds, offsets and multiline originals. Plain lyrics still copy as plain text. Both translation menus share a compact rounded surface.

## 0.1.91

- Android Install update now starts installation directly from the update banner and Settings, without a second Auralis confirmation dialog. Android 12+ uses a self-update install session that requests no further confirmation when the device permits it. Download and pre-install SHA-256 checks, APK validation, install permission handling and retry remain in place. A system confirmation remains available when Android requires it.

## 0.1.90

- Made Listening Stats compact with tighter totals, a seven-day chart, tabbed rankings and expandable backup controls. Settings groups lyrics, artwork and updates into compact sections.
- Removed volume sliders. Android uses the device volume buttons; desktop Up/Down keys change playback volume and show a temporary on-screen percentage while preserving text editing and dialog navigation.
- The mini-player floats over the page with content visible behind its margins and sideways movement. Desktop layouts include artwork and track information. Now Playing keeps its smooth collapse into the same retained player card.
- Shuffle is a visible on/off mode, with selected styling and restoration of upcoming order when disabled. Playback and queued additions are preserved.
- Current-song lyrics and bilingual translation load automatically. Choose primary/fallback lyric and translation providers, including disabling a fallback, and Japanese–English direction in Settings. Original lyrics, imports, timestamps, cache reuse and the DeepL website option remain available.
- Artwork preloads and decodes the current song plus the next 10 queued songs by default. The window follows queue changes and can be adjusted. Saved artwork is kept indefinitely by default; temporary artwork can be selected without retaining music files.

## 0.1.89

- Fixed the pause and layout jump when Now Playing lands in the mini-player. The original page and player bar stay mounted, and the card and cached background blur fade away to reveal the real controls before the spring finishes.
- The spring now settles at a pixel-based tolerance, avoiding an invisible tail that kept the mini-player locked. Opening, dragging, cancellation, navigation and reduced motion keep the same playback behavior.

## 0.1.88

- Lyrics automatically fall back from LRCLIB exact lookup to LRCLIB search and then lyrics.ovh when a source is missing, empty, unavailable, invalid or timed out. Embedded lyrics remain first, and both translation options remain available.
- Search results are checked against title, artist and duration to avoid unrelated songs/versions. Successful source attribution persists with the lyric cache, and each request has a bounded timeout and response size.
- Find lyrics online retries the sources explicitly. Failed retries keep the existing lyrics; imported lyrics, newer requests and account changes stop stale fallback results from being saved.

## 0.1.87

- Kept both translation options in the translate button and Lyrics options: Translate in Auralis restores the cached Japanese-to-English Google/MyMemory flow, while Translate with DeepL keeps the free website workflow in both directions.
- In-app translations retain original text, timestamps, offline cache reuse and original/bilingual toggling. DeepL copies only the original lyrics and leaves results in the browser. Both choices require no API key.

## 0.1.86

- Replaced the Google/MyMemory lyric translation path with DeepL’s free website, as requested. Translate copies original lyrics and opens the selected Japanese–English or English–Japanese page in the browser, with no API key.
- The dialog explains copying and browser results. Cancellation leaves the clipboard unchanged; stale song changes and browser failures are handled without replacing the original lyrics. Removed the unused online translation client and its cache path.

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
