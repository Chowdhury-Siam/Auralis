# Video input and added translations — 0.1.228+229

## Most played Music sorting

Music Library → Sort Library → Most played ranks tracks by the existing qualified
play counts, highest first, then title (case-insensitive) and track ID for ties.
Tracks without recorded plays remain included. This does not fabricate earlier
play history or count every tap as a completed play. The preference is also in
Music settings and persists in settings/backups/sync. Recently played and manually
ordered playlists keep their intentional order, as with the other sort choices.
Video retains its independent existing sort options and does not use Music play
counts. Existing sync Workers need the bundled Worker update to accept the new
preference; automatic updates use the existing deployment-permission rules.

## Video

Video settings → Player settings → Customize each gesture contains independent
switches for surface taps, side/center double-taps, horizontal seeking, vertical
volume/Android brightness, pinch zoom, zoomed-video panning, pointer speed hold,
mouse hover, keyboard shortcuts, desktop Space hold, and the time-label tap.
Keyboard/hover switches remain available on Android for external input devices.
The existing touch master switch and lock still apply. Back, unlock and ordinary
buttons are not disabled by the keyboard/surface switches. A small Show controls
button remains when tapping cannot reveal hidden controls. Timed skip prompts
still work with hidden/locked controls.

Defaults retain the original seek-zone width (36% per side), swipe range
(240 seconds or the shorter video duration), sensitivities (1×), boost (2×),
Space delay (400 ms) and hide timeout (4 seconds). The customization panel also
offers a never-auto-hide choice. Reset is confirmed and affects only gestures,
seek interval and side swapping, not other Music/Video settings.

Top/bottom bars use the entire player viewport with independent safe-area
insets and a 10-logical-pixel minimum margin. Controls do not follow decoder
texture dimensions; the picture still uses the selected aspect/fit behavior.

## Lyrics

Lyrics → translation menu → Translate with DeepL → Add translation (or the
translation menu's direct Add translation action) accepts pasted text/LRC.
Plain translations need one nonempty line per nonempty original lyric row.
LRC translations must retain the original timestamps; ordering may differ.
No timing guesses are made. Blank timed gaps remain empty. Original and
translation use the existing paired-line bilingual display and synchronization,
not a replacement of the original or a new two-column layout.

Added translations take priority over automatic providers, including late
responses. They are bounded in memory and persist with the original in the
device-local lyrics cache, scoped to account/track/source text.

For Telegram audio, Add & save song exports a separate audio file with both
languages in the standard lyrics tag. The ordinary save/publish action offers
an Include translation choice and Cancel. MP3/FLAC/M4A use the existing lossless
metadata writer; audio samples are not re-encoded. Re-publishing still requires
the existing explicit Telegram confirmation. No Telegram post is changed just
by adding a translation.

Tests cover alignment/validation, UTF8 size limits, source preservation,
restart/account separation, stale dialogs, automatic-provider priority, phone/
desktop display, metadata export and byte-preserving MP3/FLAC/M4A round trips.
Actual device gesture feel and playback/export integration still need native
Android/Windows testing; see the performance audit for environment limits.
