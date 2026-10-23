# Verification record — Windows x64, 19 October 2026

Local environment: Windows 11 24H2 (10.0.26100.9550), Flutter 3.47.1 (framework `6655482ec0`), Dart 3.13.1. The original records below describe local tests. The subsequent GitHub Actions failure and local shutdown regression results are recorded at the end.

## Automated tests

Original milestone: **12 tests passed**. The release/updater follow-up adds version, integrity, redirect, installer-handoff and packaging coverage; its final results are recorded below.

- Audio-message/document parsing, metadata, and non-audio document exclusion.
- Serialized atomic settings persistence, volume clamping, Windows DPAPI encryption/decryption and tamper rejection.
- Duplicate queue entries, active-entry reorder tracking, next/previous, repeat and clear.
- Concurrent source opens, capability URL expiration, and a new seek superseding a stalled range.
- Full/open-ended/suffix range parsing and invalid/multipart rejection.
- Real localhost HTTP responses: buffered byte delivery, exact body bytes, Content-Range, HEAD, forbidden capability and 416 responses.
- Stalled-buffer error and request termination.
- Phone/code/2FA request construction, encrypted-database parameters, chat updates, document pagination, and invalid credential rejection. These authorization tests use a **fake transport**.
- Flutter navigation, empty states, sign-in entry, queue, now-playing and settings at 1280×800, 760×650 and 520×560 logical pixels, without layout exceptions. Previews use locally installed Segoe UI and Flutter Material icons.

`flutter analyze --no-pub --fatal-infos`: final result recorded as clean after the last source formatting/check pass. PowerShell's parser accepted both build/packaging scripts. Parsing does not demonstrate that native compilation or packaging succeeds.

## Native smoke test

Command: `dart run tool/native_smoke.dart <libmpv-2.dll> <tdjson.dll>`.

Final measured run:

```json
{
  "dpapi": "encrypted credential round-trip passed",
  "tdlib": {
    "version": "1.8.68",
    "initialAuthState": "authorizationStateWaitTdlibParameters"
  },
  "libmpv": {
    "durationSeconds": 12,
    "playedPositionMs": 250,
    "seekPositionMs": 7049,
    "output": "null (muted)"
  },
  "loopbackPlayback": {
    "tdSource": "simulated cache (no account)",
    "requests": 19,
    "seekPositionMs": 4050
  }
}
```

The test used a generated WAV, actual native decoding, actual time progression, pause/resume, seeking, and real HTTP between libmpv and Auralis's proxy. The proxy's TDLib **file-cache responses were simulated**. This verifies the playback/proxy path, not authenticated Telegram networking. Output was routed to a null audio device; audible hardware output was not checked. The local native binaries were checksum-verified; provenance is in `THIRD_PARTY_NOTICES.md`.

Paused libmpv time updates did not immediately advance the smoke-test state until playback resumed. The UI backend now updates the displayed seek position when the seek command succeeds. The successful seek measurements above were taken during resumed playback.

## Build attempt and outstanding work

`flutter build windows --release` failed before compilation with:

```text
Unable to find suitable Visual Studio toolchain. Please run `flutter doctor` for more details.
```

Flutter Doctor confirmed Visual Studio is not installed. The signed Microsoft Build Tools bootstrapper was attempted with a project-local install location. It returned code 1602 / `0x80070642`, with the installer log reporting that elevation may have been declined. No compiler installation was completed. No executable or installer was produced, launched, or tested.

The first GitHub Actions run subsequently compiled TDLib and the Flutter Windows app, but failed during native shutdown before packaging. No complete build/package/publish run has passed yet. ZIP/source/checksum packaging and tag matching have separately been tested with fixture files. A live Telegram account login, chat pagination against Telegram, actual channel downloads, real-network buffer recovery/seeking, and fresh-machine installation remain required. Complete the native license/source and security audit before public binary release. Do not treat this record as evidence those outstanding checks passed.

## Release and updater follow-up

Final local check: `flutter analyze --no-pub --fatal-infos` found no issues, and `flutter test --no-pub --reporter expanded` passed **all 22 tests**. This includes the real helper test and fixture packaging test described below. All three PowerShell scripts parsed successfully; the updated workflow structure was parsed separately.

Configured public update repository: `SiamTest/Auralis`. The GitHub connection reports READ permission. The repository was initially empty; the user subsequently uploaded the source and ran CI. This task has not pushed source, started CI, or published a release.

New automated checks cover:

- Numeric stable-version ordering; rejecting prerelease/malformed tags, older releases, drafts, incorrect asset names/URLs, missing digests and invalid sizes.
- Download byte counts, digest validation, tampered/truncated files, safe GitHub CDN redirects and blocking other hosts, rate limits, missing releases, and preference persistence.
- Rehash before install, helper-before-exit ordering, and cancelling the helper if application exit is cancelled.
- A **real hidden Windows PowerShell helper** invoked with a harmless `.cmd` installer stand-in: it waited for a separate process to exit, verified the file, passed arguments/paths containing spaces, and rejected an incorrect hash. It installed no software. This test found and fixed reliance on PowerShell module discovery; helper hashing now uses .NET directly.
- Real PowerShell ZIP/source/checksum packaging with temporary marker files and a temporary Git repository, validating pubspec-based names and rejecting a mismatched tag. The fixture's EXE/DLL marker files were never executed and are not application builds.
- The Settings update controls at the existing three interface sizes.

Actual downloaded release installation, Inno Setup compilation, app restart after a real update, and automatic publication against GitHub remain unverified. The source changes do not remove the original compiler and native redistribution-audit limitations. Full setup and release instructions are in `UPDATES.md`.

## GitHub failure and Windows shutdown follow-up

Inspected [run 39206678100](https://github.com/SiamTest/Auralis/actions/runs/39206678100), commit `634f23b802888603c18e18bb2679de8e0eb2c957`. Analysis, automated tests, pinned TDLib compilation, and Flutter Windows release compilation passed. Native smoke playback checks printed successfully at 06:42:25 UTC; libmpv crashed at 06:42:30 UTC with access violation `0xC0000005`. The overall native step failed; a printed report did not mean a successful process exit. No installer was generated by that run.

The included media_kit Windows teardown patch removes its deferred five-second destruction and awaits native termination before releasing the callback. Details, affected files and application instructions are in `NATIVE_SHUTDOWN_FIX.md`.

Final local verification of the patch:

- Locked dependency resolution succeeded with vendored media_kit 1.2.6+auralis.1.
- `flutter analyze --fatal-infos`: no issues. Vendored upstream code is excluded from application style lints; the patched runtime was compiled and exercised by the native smoke processes.
- `flutter test`: all 22 tests passed, including responsive UI, settings, Telegram/proxy behavior, updater integrity/helper and packaging fixtures.
- `dart run tool/native_smoke_repeat.dart <libmpv-2.dll> <tdjson.dll>`: all three child processes exited naturally with code 0, each after four player lifecycles (12 total). Each passed real native DPAPI, TDLib initialization/close, muted local WAV playback/seeking, and loopback playback/seeking with a simulated Telegram cache.
- Updated workflow YAML parsed successfully: 13 build steps and a tag-only publisher dependent on successful build.

The original failure was not reproduced by the unpatched local smoke run. These results support the shutdown fix but do not establish that the GitHub-specific crash is resolved: the patched commit has not run there. The connection remains READ-only. No new executable/installer was built locally, no remote commit was pushed, and no release was published.

## TDLib build cache follow-up

The workflow now uses pinned `actions/cache/restore` and `actions/cache/save` to reuse the compiled TDLib/dependency DLLs, notices and manifest. An exact hit skips compilation; a miss builds from the existing pinned source. Saving happens immediately after native compilation succeeds, before later app-build/test/package steps. Cache keys include the Windows image version and build-script/workflow hashes; there is no prefix fallback.

Verification for this configuration-only change:

- Official `actionlint` 1.7.12 Windows x64 executable, downloaded from its project release and SHA-256 checked against its release checksum file: workflow passed without findings.
- Parsed YAML and checked restore/build/save order, matching cache payload/key, miss-only compilation/save, required source/image invalidation, unconditional native smoke tests and preserved tag-only publishing.
- Executed the actual new PowerShell image-identification block with a valid fixture value: wrote the expected step output. Missing image metadata failed explicitly without producing an ambiguous key.
- Confirmed GitHub's Windows runner environment configuration exports `ImageVersion`.

No application source or native code changed in this follow-up; the previous app/native checks were not rerun. Real cache upload/download, a cache hit and speedup remain unverified on GitHub because the API connection has READ permission and no authenticated Chrome session is exposed to the browser tool. The currently running old workflow cannot adopt this change midway through. Its outputs were not cached by that old workflow. The first new run needs to build TDLib to seed its cache.

## Persistent native failure and COM lifetime follow-up

The user subsequently supplied a strict smoke-process failure inside `_terminateDestroy`, again at native offset `0x13fa81`. The earlier callback-ordering fix was insufficient. Native disassembly/string/import analysis maps that operation to WASAPI hotplug notification unregistration. See `NATIVE_SHUTDOWN_FIX.md` for evidence and primary source links.

Current vendored runtime: media_kit `1.2.6+auralis.2`. Each Windows player retains an OS-managed MTA usage cookie before creation and releases it only after native destruction and callback closure. HRESULTs and native initialization failures are checked. The strict smoke test additionally queries `audio-device-list` explicitly and prints shutdown-cycle progress; it still requires natural exit code 0.

Local follow-up checks: static analysis reported no issues; all 22 existing app/UI/Telegram/proxy/update/packaging tests passed. The final native repeat run passed all three processes, four player lifecycles each (12 total), including device monitoring, decoding, seek, loopback proxy and shutdown. Tests used the same pinned libmpv binary, real Windows COM lifetime APIs, and the test TDLib binary described in the notices.

The original and intermediate unpatched local probes also exited cleanly. The exact CI crash remains unreproduced locally; this follow-up is a targeted fix awaiting the actual GitHub runner, not a claim that CI now passes. Full app compilation, installer creation/installation, audible device output and live Telegram playback remain unverified here. TDLib caching is included. No remote commit or release was made with the READ-only connection.

## Successful Windows CI and stable publication follow-up

Verified [run 39232305284](https://github.com/SiamTest/Auralis/actions/runs/39232305284) at commit `dc73a962847272f45d5b0faa83f53718480048b1`: analysis, tests, source-built TDLib, Flutter Windows release compilation, strict native repeat tests and Inno Setup packaging all succeeded. The non-expired `auralis-windows-x64` artifact was 58,469,012 bytes. The TDLib cache was saved successfully (12,851,116 bytes); the first native compilation took 53 minutes 20 seconds. `publish` was skipped because the old workflow required a version tag and this was a `main` push. No releases existed when the publishing follow-up was inspected.

The current revision publishes successful `main` builds automatically, deriving the stable tag from `pubspec.yaml` and creating it at the tested checkout commit. It also supports matching explicit version tags, marks releases with `prerelease=false`, verifies every server asset digest before publishing, serializes publishers and never replaces a published version or moves an existing tag. Older versions do not displace a newer stable Latest. Other branches, PRs and source/version mismatches cannot publish.

Local verification of this release-only change:

- All **36 tests passed**, including 14 new publisher tests executing the actual PowerShell publisher with a process-local fake GitHub CLI. Coverage includes main/tag publication, tested tag creation, exact commit validation, same-version immutability, later API pages, permission errors, mismatched existing tags, existing prereleases, draft recovery, digest failure, older-version Latest protection, feature branches and PR rejection.
- Static analysis found no issues. Official `actionlint` accepted the updated workflow, and PowerShell parsed the publisher/fixture without errors.
- Workflow structure checks verified dependency on successful build, main/tag gating, serialized publishing, limited write permissions, preserved exact-match TDLib caching and unconditional native smoke tests.
- Actual read-only GitHub CLI queries verified paginated release-list parsing and exact-tag lookup. No mock call contacted or mutated GitHub.

The app/native implementation is unchanged from the successful CI source; only publishing configuration/script, tests and documentation changed. This edit invalidates the workflow-hashed TDLib cache once. Actual tag creation, asset upload and publication still require GitHub verification: the connection is READ-only, so no commit, tag or release was created by this task. Installer installation, audible hardware output, live Telegram authentication/playback, real app updates and the native corresponding-source/security audit remain outstanding.

## Original-quality streaming requirement

Reviewed the selected-message file ID, TDLib download/cache reads, HTTP proxy and native playback path. The app relays original file bytes to the decoder without an encoder, bitrate cap, adaptive-quality selection or alternative-file fallback. The existing implementation already met this transport requirement; no quality mode or conversion layer was added.

Strengthened the real localhost HTTP regression test: a complete 600,000-byte synthetic original spans multiple TDLib reads after simulated buffering; its streamed length and SHA-256 must equal the source. MIME type, original file ID, exact seek range, suffix, HEAD and rejection behavior are checked in the same test. All five focused streaming tests passed. The TDLib cache responses remain simulated; this is byte-integrity evidence for the transport, not a live Telegram account test or a measurement of decoded hardware output.

The original source file's encoding quality cannot be improved by transport. Bit-perfect Windows/DAC output, exclusive audio mode, actual audible output and live-account playback remain unverified. The source policy and limits are documented in README.md. The runtime change in this follow-up is a documentation comment only; native playback/release workflow behavior is unchanged.

## Original Windows icon follow-up

Replaced Flutter's stock `windows/runner/resources/app_icon.ico` with an original violet A/play mark, authored as `assets/branding/auralis.svg`. The same ICO is now selected by Inno Setup. The existing executable resource, window icon and Start menu target already refer to that application icon. Version is now `0.1.1+2`, including Telegram client metadata and fallback About strings, so the artwork can ship as a newer stable update.

Verification for this change:

- Visually inspected the rendered artwork. Parsed all ten ICO entries and decoded their PNG frames at 16, 20, 24, 32, 40, 48, 64, 96, 128 and 256 px; each has the expected dimensions and transparency.
- The actual Windows `LoadImageW`/`GetIconInfo` APIs successfully loaded all ten sizes as 32-bit icon bitmaps. This checks native icon compatibility, including the 256 px PNG frame.
- Static analysis found no issues; all **36 tests passed**. `tool/package.ps1 -ValidateOnly` returned `0.1.1`.

The new executable and installer have not been compiled or launched locally because the Visual Studio toolchain is still unavailable. The earlier successful CI build predates this artwork. A rebuild/reinstall is required; Windows may retain an old pinned shortcut's cached icon until it is unpinned and pinned again. No remote source or release was changed through the READ-only connection. Playback, updater logic, workflow and TDLib source/cache settings were not changed by the icon fix.

## Display name capitalization

Changed the navigation header from `auralis` to `Auralis`, matching the existing window title, application title, About dialog and installer. The existing responsive UI test passed at all three recorded sizes, and its refreshed library preview was visually checked. This is a display-text-only correction; package identifiers, executable filenames, stored data and release asset names retain their existing values. No new Windows executable was built for this correction.

## Channel-only Telegram browser

Version `0.1.2+3` exposes only TDLib chats whose type is `chatTypeSupergroup` with `is_channel=true`, using [TDLib's explicit channel flag](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1chat_type_supergroup.html). Private/bot conversations, basic groups, ordinary supergroups, secret chats and missing channel metadata are excluded at ingestion. Title updates can rename an existing channel but cannot insert a hidden chat. Main and archived chat lists still load incrementally; the visible list and search contain channels only. Search, counts, empty states, header, channel icons, sign-in description, browse error and back navigation now refer to channels.

All **37 tests passed**, and static analysis found no issues. The new fake-transport regression covers mixed chat types, unknown/missing flags, title updates for excluded/unknown chats, channel renaming/sorting, main/archive load requests, newly loaded channels/groups, replacement metadata and logout clearing. The existing responsive UI test additionally checks the connected channel-only empty state and labels at all three sizes. Its first attempt failed because the test mutated authorization state without notifying the UI; the fixture now uses the service's notification path, and the complete rerun passed.

These are simulated Telegram updates, not a live-account test. No new executable or installer was built locally, and no remote source or release was changed. This update only filters Auralis's browser; it does not delete or modify Telegram conversations. On an early page containing no channels, use Load more to continue loading the underlying lists. Playback and the native/TDLib cache workflow are unchanged.

## Selected-channel Library and Telegram artwork

Version `0.1.3+4` changes Telegram into a channel-selection screen and Library into the combined music collection from those selections. Selected IDs/titles persist in settings. The Library scans both audio and document filters automatically to the end of every selected channel's history, ignores non-audio documents, deduplicates message IDs, shows incremental results/partial errors, and invalidates late responses after selection changes, sign-out or disposal. Pagination uses each response's own cursor rather than shared mutable service state. Empty filtered document pages do not stop older-page loading; a repeated cursor reports a partial error rather than looping forever. Current TDLib pagination semantics were checked against its [searchChatMessages reference](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1search_chat_messages.html).

Local-file import, Ctrl+O, path-backed playback, stored local references and the file-selector dependency are removed. Legacy local-path settings are ignored; music files are never deleted. Locked dependency resolution removed the unused picker and its eight transitive packages, and regenerated the Windows plugin registration. The native playback/TDLib versions and workflow/cache configuration remain unchanged.

Track metadata now retains Telegram cover-thumbnail file IDs, selecting the largest supplied variant; channel metadata retains photo file IDs and handles rename, photo-change and photo-removal updates. Artwork appears in track rows, queued rows, Now Playing, the player bar and channel selection. The image loader deduplicates requests, bounds its request cache to 128 entries, uses low-priority TDLib downloads, checks completed local files, and invalidates results on sign-out. Flutter decodes at bounded display sizes; failed downloads and decoding errors retain generated artwork. Library Refresh retries artwork. TDLib's [audio cover fields](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1audio.html) and [downloadFile completion/priority behavior](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1download_file.html) were verified in its primary documentation.

All **51 tests passed**. Coverage added in this follow-up:

- Multi-channel selection/persistence, automatic restart reload, complete audio/document pagination, empty non-audio pages, duplicate messages, deselection, partial failures, non-channel saved IDs, repeated cursors, save failure rollback, sign-out and disposal with in-flight requests.
- Cover/document-thumbnail parsing, low-priority shared image downloads, channel photo updates/removal, missing/incomplete/failed downloads, retry, bounded cache and sign-out invalidation.
- UI integration selects two channels, opens their combined Library, searches by channel, enqueues/plays via the real loopback proxy and fake audio backend, verifies channel photos plus Library/Now Playing/player-bar image widgets, and deselects a source. Responsive checks cover 1280×800, 760×650 and 520×560. Real Flutter file-image decoding uses the original app icon as a local fixture; `docs/screenshots/channel-library.png` is explicitly fixture data, not live account evidence. Image tests flush real file callbacks after widgets mount; early fixture attempts staying on placeholders were corrected before the successful run.

The earlier Windows CI build predates this revision. A new Windows executable/installer has not been compiled or launched locally, and no source or release was pushed. Live-account indexing, actual channel photos/covers, rate-limit behavior, very large libraries, hardware output and installation remain unverified. Full-size embedded cover extraction and live message-change monitoring are not implemented: absent Telegram thumbnails keep generated artwork, and Refresh discovers newly posted music. Channel choices persist across sign-out; tracks clear until connected, and saved channels are resolved and type-checked through TDLib before indexing. Queued/playing tracks are independent of later channel deselection. The previous native redistribution audit limits remain.

## Unnecessary TDLib cache miss and stable-key migration

Read-only GitHub inspection of [run 39261767369](https://github.com/SiamTest/Auralis/actions/runs/39261767369), commit `a7248a6e308049bee23198f94fdf2545fe50bac6`, confirmed a running source build after the Restore action completed. The cache API listed the previous `tdlib-windows-2022-x64-release-v1-20261012.333.1-dd3ad69f…` cache on main, size 12,851,116 bytes. Repository comparison with `dc73a962847272f45d5b0faa83f53718480048b1` showed the native builder was unchanged; only publishing conditions/concurrency changed in the workflow. Because v1 hashed the whole workflow, an unrelated release edit changed the native cache key.

The new v2 primary key hashes only the native build script plus the existing runner-image/platform/configuration dimensions. An unchanged-builder guard permits migration from the two audited v1 keys, including the key the running job will save if it succeeds. Source byte hashing reproduced both old keys using Windows CRLF checkout bytes; the single-builder Actions hash is `3bd38120fd24502f920e57bbec0cad701d81e9e660707d0fe01a37997fcc506a`. The exact combined workflow/builder digests are `dd3ad69f2b8c1b8b18a240341b323fc8f51a81540224546fa0fa684874f27af8` and `5e62127ef1534812a40462b89b368b2e085b49310a07c06b6c1b83ee6dc91b46`.

The old fallback uses the full audited key, and the build condition checks the returned match exactly rather than trusting any prefix hit. Native script edits disable migration; a different image cannot match the same full key. Accepted legacy data is saved under the new primary key before later Flutter/test/package steps. Missing compatible caches still build from pinned source. Every path retains the native smoke tests and stable-publisher gating. Implementation follows the pinned [official cache action semantics](https://github.com/actions/cache/blob/0057852bfaa89a56745cba8c7296529d2fc39830/restore/README.md).

Verification: official actionlint 1.7.12 accepted the workflow. The YAML/PowerShell self-check verified native-only invalidation, migration guard/key provenance, identical payload paths, exact acceptance checks, early save, image output/missing-image rejection, unconditional native smoke tests, serialized main/tag stable publishing and read/write permission boundaries. Recomputed native/script hashes match both audited revisions; a mutated builder fails the migration fingerprint. The application/native code and dependency pins are unchanged by this cache follow-up; the existing 51-test/static-analysis results were not rerun. The source ZIP was repackaged and its extracted version validation checked.

No remote source, cache, job or release was modified. The inspected run was still in progress at the final status check and cannot adopt this edit. Actual v2 migration/upload/hit behavior awaits a new GitHub run. Cache availability and identical runner images are required for reuse; a green Restore action alone is not proof of a cache hit.

## Draft release lookup failure and numeric-ID repair

Inspected [run 39264104723](https://github.com/SiamTest/Auralis/actions/runs/39264104723), tested commit `e591fccf62391c062badc531e95a018394bc0351`. The build job `118099174243` succeeded: native cache restore/migration completed, TDLib compilation was skipped, and the stable v2 cache was saved (12,851,052 bytes). Flutter Windows release compilation, strict native smoke checks and installer packaging all passed. This verifies the cache migration on GitHub and the selected-channel/artwork revision's build; it does not establish live-account behavior or successful installation.

Publish job `118101473647` created a draft at the user's supplied `untagged-af24c1ad21d4c1a4aba1` URL and completed the upload command, then failed at the REST `releases/tags/v0.1.3` lookup before digest verification/publication. GitHub's [by-tag endpoint](https://docs.github.com/en/rest/releases/releases#get-a-release-by-tag-name) describes published releases. The [CLI's draft lookup](https://github.com/cli/cli/blob/trunk/pkg/cmd/release/shared/fetch.go) resolves the pending draft tag with GraphQL, then obtains its metadata by numeric ID. The earlier fake API incorrectly returned draft data from the published-only route, missing this real failure; the fixture now rejects that route with HTTP 404.

The publisher now resolves `databaseId` using `gh release view`, validates a positive numeric ID and the intended stable-draft identity before uploading, then reads fresh assets using the numeric-ID REST route after upload. Every SHA-256 must still match before stable publication. Lookup failures, malformed IDs, wrong draft tags and already-published objects stop before upload/edit. Published-version immutability, exact tested tag/commit validation, early-failure handling, older-version Latest protection and draft recovery remain covered.

The actual `refs/tags/v0.1.3` points to `e591fccf62391c062badc531e95a018394bc0351`. Version is therefore bumped to `0.1.4+5`, including Telegram client metadata and fallback About text, so a new source commit does not try to move that existing tag. No old tag or draft was removed. The stable TDLib key and native sources/dependency pins are unchanged; this publishing repair does not invalidate the native cache.

Local verification: all **56 tests passed**, including 19 actual-PowerShell publisher fixture scenarios. New regressions enforce draft by-tag 404 behavior, numeric lookup and pre/post-upload metadata ordering, and rejection of bad IDs, wrong tags, lookup errors and drafts that became published. Static analysis found no issues, and both publisher/fixture scripts parsed successfully. Fixtures never contacted GitHub or installed software.

The fixed publisher/version has not run on GitHub. This task used read-only API/log access and did not create, edit, upload, delete or publish any remote release/tag. The read-only connection does not expose private draft metadata; the draft creation/upload evidence comes from the actual publisher log. A new commit with this fix is required; rerunning the failed old job uses its old script. Fresh-machine installation, actual update execution, live-account behavior and the native corresponding-source/security audit remain outstanding.


## Embedded artwork and Library sorting — v0.1.5+6

The user's screenshot showed procedural fallback artwork for 548 indexed tracks. The prior implementation relied on supplied Telegram thumbnails and did not inspect embedded music pictures; the historical artwork limits above describe that earlier revision. This revision adds a bounded independent Dart reader for MP3 ID3v2.2/2.3/2.4, FLAC PICTURE and MP4/M4A covr metadata. Tiny Telegram album/document/channel previews are also parsed and displayed. A missing thumbnail can fall back to embedded art; a malformed or unsupported picture retains a preview or procedural fallback. No artwork-search service, new Dart package, native library or audio transcoding is added.

The reader caps aggregate metadata reads at 4 MiB, validates ranges and lengths, skips audio payloads, and parses on a worker isolate. It supports ID3 UTF-16 descriptions, extended headers and unsynchronisation, plus extended MP4 box lengths. Cover jobs are limited to two concurrently and 64 cached results; photo/thumbnail requests retain their existing 128-entry bound. Missing covers retry on TDLib file updates. Files registered with the playback proxy use only already downloaded ranges, avoiding a change to TDLib's single active download offset. Pending results are invalidated on sign-out/refresh. Metadata requests use low priority and deadlines.

Library now has a compact Sort Library menu with Newest first, Oldest first, Title (A–Z), Artist (A–Z) and Duration (shortest first). Dates come from Telegram message timestamps across selected channels. Unknown dates/durations sort after known values; case-insensitive title/artist comparisons use deterministic tie breaks. The selected enum name persists in settings; absent/invalid values default to newest. Search applies before sorting, and starting playback from the Library uses that visible order. Changing the sort leaves an existing queue and playing item unchanged.

Local verification: all **75 tests passed**, including ten embedded-parser cases, bounded range download/sharing, cached-art extraction during playback with no download mutation, retry on file progress, failed-thumbnail fallback, sign-out cancellation, a two-job concurrency limit, and thumbnails with unknown audio size. Parsing tests verify exact picture bytes for ID3/FLAC/M4A, a virtual 100 MiB MP4 whose audio payload must never be requested, malformed/truncated/oversized data and 300 deterministic random inputs. Additional tests cover mini previews, sorted dates/case/ties/unknown fields, saved/invalid sort settings and menu selection at 1280×800, 760×650 and 520×560. The connected UI test renders embedded artwork from an MP3 with no TDLib thumbnail into both Library rows, Now Playing and the player bar; its screenshot is docs/screenshots/channel-library.png. The artwork is an original SVG/PNG fixture, with independently generated silent MPEG frames, not a real account or copied album image. Static analysis is clean. The complete ZIP is checked for required files, archive integrity and extracted packaging version validation.

The source version is 0.1.5+6, including Telegram client/About metadata. Native dependencies, TDLib builder and stable cache workflow are unchanged. This revision has not been built into an EXE/installer or published from here. No live account or the user's actual music files were accessed, so live cover availability, network timing and real-library performance remain unverified. Music with no artwork or unsupported embedded containers still needs the fallback; native redistribution/security audit and installation/update execution remain outstanding.


## Expanded build caching — v0.1.6+7

Added image/SDK/dependency/native-source scoped caches for Windows/CMake build intermediates, Flutter compilation and native hook output. The final runner Release directory is excluded; the full release-build command always runs. Its source-dependent primary key has a compatible prefix fallback for UI edits. The existing Flutter SDK/Pub caches remain enabled. Conditional vcpkg caches persist downloads/tools and ABI-checked binary packages when the compiled TDLib cache misses, and save non-cancelled partial progress even if TDLib source compilation fails. Existing TDLib builder bytes and stable/legacy cache keys are unchanged. No runtime credentials, sessions, package-config/plugin links, dist assets or raw TDLib object trees are added to caches.

Verification: actionlint accepted the workflow. The native-cache provenance self-check still reproduces both audited legacy keys, verifies exact compiled-DLL cache acceptance/early save, exercises valid/missing runner-image outputs in PowerShell and confirms serialized stable publishing. Three new bundled regressions validate Windows compatibility/source key separation, exclusion of the final bundle, unconditional checks/build/package commands, matching restore/save paths and keys, vcpkg condition/order/failed-build save behavior, and execute the actual cache-directory setup in PowerShell. All **78 tests passed**; static analysis is clean. The existing YAML parser was promoted from a transitive dependency to a pinned development dependency for the workflow tests, with no package-version changes. Version/client/About metadata is 0.1.6+7/0.1.6. The complete/source archives are rebuilt, integrity-checked and version-validated after extraction.

The workflow has not been uploaded or run from here. No cache or remote job was edited, and no build-time improvement is claimed as measured. The next GitHub run must populate new entries before cross-run reuse can be verified. The current screenshot's already running job uses its original workflow. Cache transfer overhead, branch/image compatibility and eviction can affect gains. This revision's Windows executable/installer, actual stable publication, installation/update execution and live Telegram behavior remain unverified here; prior native audit limits still apply.


## Windows update-exit acknowledgement repair — v0.1.7+8

The screenshot shows Installed: 0.1.3 and a checksum-verified download followed by a handoff failure. The Windows embedder's [SystemExitApplication implementation](https://api.flutter.dev/windows-embedder/platform__handler_8cc_source.html) requests the framework's asynchronous decision for cancelable exits but immediately acknowledges the method with response: cancel. The old callback treated that acknowledgement as the final decision, returned false and killed the waiting installer helper. This is a confirmed code defect consistent with the screenshot; the old generic message did not preserve the exact exception from that attempt.

The updater now awaits the shared, memoized audio/Telegram/session-lock cleanup directly and only then asks the Flutter engine for required exit. It does not force-kill the application or skip native cleanup. Normal window close shares the same cleanup future. Cleanup errors prevent required exit and leave the updater able to report the failure. Existing helper process waiting and installer rehashing are unchanged. Error states now distinguish a changed installer, failure to launch the helper and failure/cancellation while closing, and explain manual recovery.

Local verification: all **81 tests passed**; static analysis is clean. Two new tests use a non-exiting Flutter binding to prove cleanup finishes before the required-exit request and cleanup failure never requests exit. An updater regression covers helper-launch and cleanup exceptions, helper cancellation, retained verified download and manual-recovery guidance. The real hidden Windows PowerShell helper fixture again waits for a harmless stand-in process, preserves spaced paths and rejects a bad checksum; it never runs a real installer. The existing metadata/download/hash/cancel regressions still pass. Full project/source archives are integrity-checked and extracted version validation targets 0.1.7.

Read-only GitHub metadata confirmed the current public stable release is v0.1.5 with installer digest 28f6f2d13cd11a407d0c45fad5b00d4fd1ab99880874d40000901387b022338e. A read-only hash of the already downloaded installer matches. Only update-file metadata and hash were inspected; no Telegram credentials/session contents were read or changed. No installer was launched, no remote release modified and no new binary built. Affected v0.1.3 users need a one-time manual installer launch because the fix cannot patch the old running updater in place. The source fix awaits a GitHub Windows build and real installation/update/restart verification; previous live-account and native distribution audit limits remain.


## Live volume and mouse-wheel control — v0.1.8+9

Previously the volume slider changed only the saved/UI value during dragging and sent the actual native volume command on release. The volume group now handles vertical mouse-wheel signals over both the speaker and slider: up increases by five percentage points and down decreases by five. Flutter's pointer-signal resolver claims only a handled vertical signal; horizontal signals and scrolling elsewhere do not change volume. Values are clamped to 0–100 in the shared controller. The tooltip displays the current percentage and scroll hint, and the slider has a Volume accessibility label. Existing compact-window visibility is unchanged.

Every drag change now reaches the audio backend immediately and notifies the UI. The final drag value is saved on release, avoiding settings writes on every pointer movement; wheel changes apply and persist directly. Backend/settings errors remain handled. This changes playback gain only, without re-encoding or altering the original Telegram file bytes.

Local verification: all **84 tests passed**; analysis found no issues. New tests send actual mouse-wheel events over the icon and slider, verify opposite directions, zero/100 clamping and ignored horizontal/outside events. A held mouse drag changes backend volume in both directions before release and saves once on release; a real temporary settings file restores the saved level. Playback remains active in the control tests. The native smoke test now sets libmpv volume to 35 then 80 during generated-audio playback and reads both values back from libmpv, rejecting stopped playback or incorrect values. All three strict smoke processes passed and exited naturally, including four shutdown cycles per process, original seek/proxy checks, DPAPI and pre-account TDLib checks. Native output was null/muted; no audible/hardware loudness assessment or real Telegram account was used.

The version/client/About metadata is 0.1.8+9/0.1.8. The native builder, dependency lock and cache workflow are unchanged. Source and complete ZIPs are integrity-checked and their extracted version validated. No new Windows runner EXE/installer was built or published here. Audible device output, installation/update execution, live-account behavior and the previous native distribution/security audit remain unverified.


## Sort-popup placement and appearance — v0.1.9+10

The sort popup now opens under the icon with a small gap, rather than centering its selected row over the button. Removed the initialValue alignment input while retaining the checked state, avoiding selection-dependent vertical placement and the route's large gray selected-row highlight. Added a rounded clipped dark surface, subtle border/shadow, and purple text for the checked option. Existing sort values, saved preferences and selection behavior are unchanged.

Verification: the two targeted UI tests passed at 1280×800, 760×650 and 520×560. Added assertions verify the first option is below the sort button and the menu's first/last options remain within window bounds, including reopening with a different selected option. Selection still changes Library order while preserving the queue/playing item. Static analysis is clean. The refreshed test-rendered preview docs/screenshots/sort-menu.png was visually inspected. No new dependencies/native changes; the prior 84-test and three-native-smoke results belong to the preceding volume revision and were not repeated for this appearance/placement edit. Version/client/About metadata is 0.1.9+10/0.1.9. The full/source ZIPs are integrity-checked and extracted version validated.

This revision still needs a GitHub Windows executable/installer build. No binary was installed, remote release modified or live account used here; previous update/install/hardware/native audit limitations remain.


## Animated player and adaptive sizing — v0.1.10+11

Read the user's local Yutaka 16 source as a sizing reference: it uses bottom navigation under 900 logical pixels, a desktop rail at 900 and an expanded rail at 1180. No Yutaka code/assets were copied or modified. Auralis independently follows that navigation pattern, stacks metadata/controls below 600, keeps volume/repeat accessible in narrow mode, tightens headers/rail in short windows and shows a bounded Now Playing side panel only with sufficient width/height. Full-page cover size adapts to screen size. Concise singular/plural Library count labels keep the compact toolbar on one line.

Added a custom animated Slider track for a traveling wave in the played segment, preserving native Slider seek semantics, buffered indicator and thumb. The two-second ticker is isolated to a repaint boundary, stops when paused/buffering/disabled/hidden by TickerMode and honors both app/system reduced motion (straight track). This is decorative animation, not PCM waveform or frequency analysis. The bottom cover/title/artist is a keyboard-accessible InkWell that opens the current Now Playing page; seek/transport controls do not navigate. No native audio bridge, stream bytes, buffering or volume behavior was replaced.

Windows runner source converts a 360×480 logical client minimum to DPI-aware outer bounds and centers/shrinks startup size to the monitor work area. This is a native-source change, so the Windows build-intermediate compatibility key changes as intended; the TDLib builder/stable key remains unchanged. No local MSVC toolchain is available: these native sizing changes have not been compiled/executed here and need the GitHub Windows build. Actual monitor/DPI resizing and performance remain unverified.

Local verification: **87 tests passed** and static analysis is clean. New tests confirm wave phase advances while playing, freezes while paused, and schedules no frames for app/system reduced motion. The connected-layout test covers Library, Telegram, queue, Now Playing, settings, mouse/keyboard seeking, current-track navigation without stopping playback, visible volume and correct navigation mode at 360×480, 520×560, 760×650, 900×480, 1000×700, 1280×800 and 1920×1080, plus 130% text. Original fixture images and fake Telegram/audio data are used. Compact/desktop screenshots capture an actual animated seek frame and were visually inspected. No audible output or live account was used.

The new layout fixture exposed synchronous artwork completion for zero-size files notifying listeners during build. Cover-job notifications now defer to a microtask; the fixture covers that path and existing image tests still pass. An initial visual test waited on font loading under the simulated clock; fonts were moved to setup and image fixtures preloaded before mounting. Those harness waits were corrected before the successful suite.

The app/client/About version is 0.1.10+11/0.1.10. The complete/source ZIPs include the new seek widget, regression test and both previews; integrity and extracted version validation pass. No new runtime packages or native libraries were introduced. No Windows EXE/installer was built, installed or published here; prior update/install, live-account and native distribution/security audit limitations remain.


## Selected Telegram channels first — v0.1.11+12

The Telegram browser now sorts selected channel IDs ahead of unselected IDs, then sorts titles alphabetically within each group. The ID set comes from persisted settings and rebuilds with selection changes. Search filtering still applies to both groups; channels are not duplicated or added to Telegram. Existing channel photos/title updates, selection persistence, indexing and Library behavior are unchanged.

Verification: both targeted UI tests passed and analysis is clean. The connected-channel test selects the alphabetically later channel first and checks that it moves above the earlier unselected channel; selecting both restores alphabetical order within the selected group, and deselecting one moves it below the remaining selected channel. Existing music-index/search/cover/sort and responsive UI checks remain in that same test. This small ordering change did not rerun the preceding full 87-test/native checks. Source/client/About metadata is 0.1.11+12/0.1.11. The source and complete ZIPs are integrity-checked and version-validated after extraction.

No Windows executable/installer was built or published here. The preceding native sizing changes still await GitHub compilation and hardware verification; earlier installation/live-account/native audit limits remain.

## 2026-10-19 — v0.1.12 lyrics view

- All **95 Flutter tests passed** after this implementation. Static analysis is clean. Eight added tests cover timed/plain parsing, repeated/translated timestamps, bounds, privacy-safe request fields, HTTP failures/redirect rejection, cache eviction, line seeking, automatic following/manual scroll, stale song results, loading/error/not-found/instrumental states, paste entry and adaptive UI. Existing playback, channel selection, updater, packaging and workflow tests still pass.
- Live HTTPS probe used the actual LyricsRepository client with LRCLIB's public API documentation example (I Want to Live / Borislav Slavov / 233 seconds). It returned **47 synced lines / 1040 plain-text characters**. No lyric content was printed or stored in the source, and no Telegram account was used. This proves the provider/client request worked at verification time, not coverage for every song.
- Rendered and inspected docs/screenshots/lyrics-1280.png and lyrics-360.png. They use original synthetic lyric text and procedural artwork. Synced/Static controls, active-line centering and the existing bottom transport remain visible. Reduced-motion following, user scrolling/resume and clicking a line to seek are exercised with the fake audio backend.
- No native playback code, dependency pin, TDLib builder or workflow cache key was changed. The earlier native smoke results remain historical evidence; they were not rerun for this Dart lyrics UI change. No EXE/installer was built, uploaded or installed here because Windows C++ Build Tools are absent. GitHub access remains read-only.
- Limits: lookup is opt-in per uncached song; provider availability, metadata/recording matches and timing accuracy vary. Pasted/results cache is session-only and bounded. Embedded lyric tags, persistent lyrics, word-level karaoke, automatic translation, live Telegram-account playback, hardware animation performance and installation remain unverified or unimplemented.

## 2026-10-19 — v0.1.13 logout/API reset

- The complete **101-test suite passed**. Six new tests cover logout followed by a second phone/code/2FA flow with different API details, fresh client parameters, retained database key, no app-side folder deletion, the playback proxy's stable request forwarding, native-close-before-reply ordering, rejected logout, credential-write failure/recovery, restart with no saved API details, late channel responses and the actual Settings-to-blank-API-form UI. The final error-message branch was also checked in the targeted six-test rerun; static analysis is clean.
- A real native TDLib probe created and gracefully closed three independent clients sequentially in one Dart process. Each returned authorizationStateWaitTdlibParameters. The process exited normally. No account or API credentials were used; this checks native recreation/closure, not server logout or authentication.
- Logout removes saved API ID/hash only after Telegram accepts the request. Rejected logout preserves the active account/configuration/selection. The database key remains, and a vault-write failure is visible/recoverable. A signed-out startup does not silently reuse old API settings. The sign-in form waits for TDLib's closed state before a fresh client can start. The existing TDLib bridge, pinned native builder, dependency versions and compiled-DLL cache key are unchanged.
- Main's streaming proxy now resolves the service's current client for each request, avoiding a captured reference to the old connection. Late channel lookup results are discarded after logout/client replacement. Explicit logout clears old channel selections; normal volume/motion/update preferences are retained.
- Source/client/About metadata is 0.1.13+14/0.1.13. The complete archive is integrity-checked, extracted and version-validated. No EXE/installer was built or published here. Installing the new GitHub build, two real Telegram-account sign-ins, network-dependent logout completion and existing native redistribution/security limits still need verification.


## 2026-10-20 — v0.1.14 reference-style lyrics

- Matched the supplied lyrics screenshot/video with a solid teal canvas, rounded song/artwork pill, cyan current line centered vertically, blurred/faded neighboring lines, lavender play/pause control, wave seek pill, separate Synced/Static buttons and Back/options controls. The lyrics page takes the full player area; Back restores the normal player controls and navigation.
- Reused the existing lyrics repository, timestamp parsing and wave seek widget. Click-to-seek, buffering, lookup consent, plain/pasted/instrumental/error states and the session cache remain covered. Manual scrolling pauses following and reveals unblurred readable lines; Follow song restores focus. User/system reduced motion disables transition animation and the wave ticker.
- Verification environment: Linux x64, Flutter 3.47.1, Dart 3.13.1, original locked dependencies. Static analysis with fatal infos passed. The full suite passed **80 tests**, with **23 Windows-only checks skipped**, no failures. All **six lyrics widget tests** also passed in the final targeted rerun. The new checks cover multiline centering at 360×480, 390×844 and 1280×800, active/neighbor blur, seeking, playback toggling, large text, system reduced motion, immersive controls and Back navigation.
- The existing Windows-only test-font loader caused Library layout assertions on Linux, including a failure reproduced in the untouched source ZIP. The three UI test files now use an available DejaVu Sans fallback on Linux; Windows continues to use Segoe UI. No production typography change was made outside the lyrics page.
- Visually inspected test-rendered lyrics screenshots at 360×480, 390×844 and 1280×800, using original test text and procedural artwork. Fixed the Back icon contrast and mode-button font after the first render. Screenshots are included under docs/screenshots. The final source archive was checked for ZIP integrity and contains project files at its root, excluding local build/cache files.
- Source/client/About versions are 0.1.14+15 / 0.1.14. No Windows EXE/installer was built, installed or published here. Native audio/TDLib playback, real account behavior and animation performance on hardware were not reverified by these Linux widget tests.


## 2026-10-20 — v0.1.15 collections and playback features

- Reviewed the user-supplied PixelPlayer source archive's feature descriptions and added six independently written Dart equivalents: favorites, saved playlists, recently played, Play next, repeat one and sleep timers. No PixelPlayer source, assets, dependencies or native components are bundled. The existing Telegram-only playback model and reference-style lyrics page remain included.
- Favorites, playlist names/ordered message IDs, the last 100 unique successfully opened track IDs and the repeat mode are saved through the existing serialized settings writer. Duplicate playlist entries are ignored, names are validated, malformed settings fields are filtered/bounded, and failed saves report session-only state. Collections deliberately resolve stable IDs against the current loaded/authorized Library instead of persisting stale TDLib file IDs. Collections remain local across sign-out; they are not downloaded music or cloud synchronization.
- Play next preserves the active queue index, including duplicate tracks. Repeat one restarts completion without blocking manual Next. Timed sleep pauses rather than toggling a paused player on; end-of-track sleep takes priority over repeat. Cancellation, queue clear and shutdown cancel pending timers. A deadline firing while an audio open is pending still pauses the source when ready. Timers are session-only, do not wake a closed/suspended computer and require actual Windows/native behavior checks.
- Added eight regression tests covering real settings round-trips, malformed/bounded input, ordered playlists/history, duplicate queue entries, repeat-one/manual-next behavior, timer expiry/cancellation/end-of-track precedence, pending-open expiry, save failures and the complete UI flow for recent order, favorite, Play next, playlist creation/addition/rename/removal/deletion and timer set/cancel.
- Full verification on Linux x64 with Flutter 3.47.1, Dart 3.13.1 and the unchanged locked dependencies: **88 tests passed, 23 Windows-only checks skipped, no failures**. Static analysis with fatal infos passed. Existing adaptive, lyrics, logout, updater and channel/proxy tests are included in those results.
- Visually inspected collection frames at 360×480 and 1280×800, plus the compact sleep-timer dialog. Compact Library headers omit redundant counts and collapse the collection chips in playlist detail to keep tracks visible. Refresh remains in the small header. Sleep is reachable from the playback bar; Cancel timer stays in the dialog's fixed action area. Up-next tiles now have a Material surface for visible ink in the desktop side panel. Test images use original synthetic metadata/procedural covers, not a real account.
- Source/client/About metadata is 0.1.15+16 / 0.1.15. The source ZIP was integrity-checked, keeps project files at its root and excludes build/cache/runtime files and the reference archive. No Windows EXE/installer, native audio, real Telegram session, hardware timing, installation, remote commit or release was produced/verified here.


## 2026-10-20 — v0.1.16 listening stats, export and Backup & Restore

- Added local listening time, qualified plays, unique tracks/artists, top-ten track/artist rankings and seven days of calendar-day activity. A qualified play requires 30 seconds or half of a shorter known-duration track, once per opened/repeated/replayed session. Existing recent history is not retroactively estimated. Controller sampling credits positive media-position advancement bounded by monotonic elapsed time, excluding app seeks, paused/buffering intervals and event gaps above five seconds. Samples split at local midnight. Metadata is limited to 1000 characters per stats label so recorded data remains restorable. Stats checkpoint every 30 seconds of events and flush at pause, completion, track change, clear, shutdown and file operations. Abrupt exits can lose the latest unsaved samples.
- Added a header chart button and Settings entries for Listening stats and Backup & Restore. Stats use an explicit refreshable snapshot. UTF-8 CSV exports separate track/day rows (alternate aggregations), quote metadata correctly and neutralize spreadsheet-formula prefixes. Stats JSON exports preserve the complete stats model. Restorable backups are a separate versioned JSON format with SHA-256 integrity and a 64 MiB input cap. Integrity is not authentication or encryption.
- Backups include stats, favorite/message IDs, ordered playlists, recent music, channel selections and preferences. Credentials, sessions, audio/artwork, lyrics, queue and timers are excluded. Restore validates a detached snapshot before side effects, previews counts for confirmation, stops/clears playback, writes a portable pre-restore recovery copy and atomically replaces settings through the serialized writer. The recovery-copy action uses the same validation/preview. Failed writes retain current in-memory/on-disk settings; no recursive app-data deletion is involved. Channel/message references still require account access.
- Reused the existing settings writer, checksum dependency and playback events. Added official Flutter file_selector 1.1.0 for native open/save dialogs with pinned transitive packages in pubspec.lock and regenerated Windows plugin registration. No new tracking service, database, periodic polling timer or custom Windows dialog bridge was added.
- Final Linux x64 verification with Flutter 3.47.1 / Dart 3.13.1: **97 tests passed, 23 Windows-only checks skipped, no failures**. Static analysis with fatal infos found no issues. Nine added regression tests cover deterministic playback clocks, pauses/buffering/seeks/suspension, short-track/repeat/manual replay qualification, midnight splitting, metadata bounds, Unicode/CSV/formula safety, stats round-trips, corruption/version/schema rejection, real-file exports, real-file restore/recovery and failed writes, file-picker cancellation, restore preview cancellation/confirmation, and compact Settings access. The rest of the existing suite covers prior player/lyrics/collections/logout/update/proxy behavior.
- Visually inspected test-rendered stats views at 360×480 and 1280×800 and the direct compact Backup & Restore page. Screenshots use original synthetic metadata and fixture artwork. Native OS file dialogs are represented by an injectable chooser in widget tests; actual Windows dialogs, native playback accuracy, a Windows EXE/installer build, real Telegram accounts, hardware performance and installation/publication were not verified in this revision. Source/client/About metadata is 0.1.16+17 / 0.1.16. The source ZIP keeps files at its root and excludes local caches/builds/runtime data and the reference archive.


## 2026-10-20 — v0.1.17 Android host and independent APK workflow

- Added the Android application host (app.auralis.auralis, Android 7/API 24 minimum, ARM64 by default, optional x86_64), Gradle wrapper and branded launcher resources. The shared Flutter features remain in one project; the Windows workflow and pinned Windows TDLib builder are unchanged. Updated source/client/About versions to 0.1.17+18 / 0.1.17.
- Android loads libtdjson.so through the existing isolate bridge. The independent Linux builder pins the same TDLib revision as Windows plus OpenSSL 3.5.4 and NDK 28.2.13676358, prepares host-generated schemas, builds static crypto/C++ and requests 16 KiB alignment. An initial cross-compile exposed an OpenSSL discovery issue; explicit target include/static-library paths fixed configuration, and actual ARM64 TDLib C++ compilation began. Compiled binaries, licenses and build provenance are cached per ABI/builder hash in the workflow.
- Reused libmpv through media_kit_libs_android_audio 1.3.8. Added audio_service 0.18.19 for a media foreground service/system controls and audio_session 0.2.4 for focus and interruption/headphone handling. Media commands share the existing controller/queue/seek tracking. Metadata updates include durations arriving after open. Background UI pauses flush stats without stopping music. The Windows installer/updater is instantiated only on Windows.
- Added Android Keystore AES-256-GCM encryption with fresh IVs and authenticated ciphertext, retaining the existing serialized/atomic credential-file writes. OS backups/device transfers are excluded. Android exports/restores use system document intents and content-resolver streams, with bounded reads and file I/O on a worker thread. No broad storage permission is requested. The existing backup schema, confirmation and automatic local recovery copy are reused; credentials/music/session data remain excluded.
- Added .github/workflows/android.yml as a separate push/PR/manual Android build action. It defaults to ARM64, resolves the lockfile, analyzes/tests, builds/caches native TDLib, compiles and verifies the APK, checks required native libraries/ABI/16 KiB ELF alignment, checks APK signing/ZIP alignment and uploads artifacts/checksums/provenance. It does not depend on Windows, publish releases or change Windows assets. Signing secrets are optional for development builds and all required for release builds; PRs never use release signing keys. Native release builds reject absent signing configuration; temporary signing files are removed in an always cleanup step.
- Verification before the build environment reset: the full Flutter suite passed **101 tests**, with **23 Windows-only tests skipped** and no failures. Static analysis with fatal infos found no issues. All **four new Android bridge/media/workflow tests** passed again after the metadata-duration update. They cover encrypted-byte storage contracts/failure retention, Unicode/content-URI export and cancellation/recovery reads, media commands/queue/seeks/stop, and independent workflow configuration. These mock the Android channel; they are not a device Keystore or playback test.
- All **five Python checks passed**, including real keytool keystore preparation/password-failure cleanup, signing defaults, native ELF ABI/alignment rejection and required APK-library validation. Source XML/workflow YAML and shell syntax were checked. A real Android Keystore instrumentation test is included for connected device/emulator runs, but was not run here.
- The local build environment was reset during ARM64 TDLib compilation and Android Gradle dependency/configuration work. No finished native libtdjson.so or APK was produced or verified; no phone/emulator installation, background playback, audio focus, Android document picker or live Telegram account was tested. The separate GitHub Action has not been pushed/run from this task. Its first successful build and device testing remain required. Earlier native corresponding-source/security audit limits still apply.
- The final source ZIP contains the complete project at its root, including the Android wrapper/host/workflow/docs/tests, and excludes SDKs, native source/build/cache trees, generated SDK paths, signing keys, runtime data and the reference archive. Existing Windows features remain included. Flutter's environment detector initially attempted a cloud metadata probe and was blocked by automatic approval review; inspecting its source established that explicit CI mode skips that probe, allowing subsequent host checks without metadata access.


## 2026-10-20 — v0.1.18 Now Playing fits one screen

- Replaced Now Playing's outer SingleChildScrollView with a bounded LayoutBuilder/Column. Both the full page and desktop side panel use the same layout. Short windows place artwork beside song details; taller windows place artwork above them. Artwork uses only the remaining space. Title is bounded to two lines and artist/source to one, retaining their text for semantics.
- Song actions remain visible in a fixed row. A scale-down fit handles narrow panels/wider fallback fonts without wrapping or overflow. The full-page playback/seek/volume controls remain in the existing fixed transport bar. Up Next shows zero to three rows according to the space/text scale and exposes a Queue button for the full existing queue. Queue navigation does not stop playback.
- Extended the existing adaptive widget regression with a long track title, 576 upcoming tracks, assertions that Now Playing contains no Scrollable, a swipe that leaves artwork position unchanged, visible actions/Queue access and working Queue navigation. Viewports include 360×480, 390×844, 520×560, 760×650, 900×480, 1000×700, 1280×800 and 1920×1080, plus 130% text. The first full regression run caught a small action-row overflow with a wider fallback font; the shared action-row fit fixes it.
- Original synthetic song/queue metadata and fixture artwork were rendered and visually inspected at compact and desktop sizes. New snapshots are docs/screenshots/now-playing-360.png and now-playing-1920.png. The user's music screenshot is a reference only and is not bundled.
- Source/client/About metadata is 0.1.18+19 / 0.1.18. Android support, its independent workflow, stats/export/backup and previous features remain included. No Windows executable, Android APK, native build, installation or live account was produced/reverified for this layout change; previous Android build/device verification limits remain.

- Final Linux/Flutter 3.47.1 verification: **101 tests passed, 23 Windows-only tests skipped, no failures**. Static analysis with fatal infos found no issues. The locked dependency resolution and source ZIP integrity/version/exclusion checks passed.


## 2026-10-20 — v0.1.19 embedded lyrics and app theme

The immersive lyrics page previously offered only LRCLIB lookup/paste and hardcoded teal/cyan colors. It now automatically tries the music file’s embedded metadata when opened or changing songs, using the existing bounded artwork container walker and TDLib range reader. Supported tags: ID3v2.2–2.4 ULT/USLT, SLT/SYLT with millisecond timestamps and lyric content, custom LYRICS/UNSYNCEDLYRICS/SYNCEDLYRICS text frames, FLAC Vorbis comments with those names, and MP4/M4A ©lyr UTF-8/UTF-16 data atoms. Text tags containing LRC use existing synchronization; plain tags display Static mode. Source attribution distinguishes embedded lyrics from pasted/provider results. Cached/pasted lyrics take precedence, and stale async results cannot replace a later track. The existing options menu includes an explicit file-read retry; this never triggers LRCLIB lookup.

The reader shares the 4 MiB metadata budget and 20-second TDLib deadline, skips audio payloads, reads at most 128 KiB per TDLib part, validates sizes/encodings and falls back safely on malformed/absent tags. It does not move a streaming file’s download offset: unavailable metadata ranges require retry after downloading. The 256 KiB / 2000-entry lyrics limits still apply. Ogg/Opus/WMA, sidecars, encrypted/compressed ID3 frames and MPEG-frame SYLT timestamps are not supported. No new dependency or external automatic lyric lookup was added. Live-account files and the user’s actual embedded tags remain unverified.

Lyrics background/surfaces/highlights now match Auralis’s charcoal/violet palette, including controls and secondary text. Desktop 1280×800 and narrow 360×480 synthetic test screenshots were visually checked; no layout overflow was observed. The existing one-page Now Playing layout and independent Android workflow remain included.

Verification: the complete Flutter suite passed **111 tests**, with **23 Windows-only checks skipped** on Linux; fatal-info static analysis is clean. Added coverage checks ID3 versions, Latin-1/UTF-8/UTF-16 Japanese text, descriptions, custom tags, millisecond SYLT, FLAC/M4A tags, invalid/oversized/truncated metadata, metadata-only byte reads, cached streaming ranges, sign-out invalidation, automatic display, stale track results, pasted-lyrics precedence, manual file retry and app palette matching. Updated screenshots contain only original synthetic lyrics. Source/client/About metadata is 0.1.19+20 / 0.1.19. Complete source ZIP integrity and required Android/Windows files were checked. No executable, APK, installation or release was built/published for this revision; the separate GitHub Actions build those from the updated source.


## 2026-10-20 — v0.1.20 import LRC lyrics

Added Import .lrc file to the lyrics options menu and empty state. It attaches the chosen file to the current song in the existing bounded session cache, supports the existing LRC offsets/repeated timestamps/translations and displays imported-source attribution. Plain text uses Static mode. No file is uploaded or written back to the music file, and imported lyrics are not included in backups. Cache eviction or closing the app requires importing again.

Windows uses file_selector with an .lrc extension filter. Android reuses the Storage Access Framework picker and protected selected-document reader; the picker can show all file types for providers without an LRC MIME type. The shared byte reader accepts an explicit limit, retaining 64 MiB for backups and enforcing 256 KiB for LRC files, including in the Android native bridge before accumulating file contents. UTF-8 (optional BOM) and BOM-marked UTF-16 LE/BE are supported; other encodings may require conversion. Parser limits remain 2000 lyric entries. Empty/oversized/undecodable files report an import error and preserve existing lyrics. Cancellation is harmless; a picker/read result after the song or lyrics generation changed is discarded. No dependency added.

Verification: **29 relevant Flutter tests passed**, covering lyrics parsing/views, Android document-channel handling and backup/export regression. New checks cover Unicode encodings and BOMs, timestamps, size/line limits, actual bounded local reads, automatic Synced mode/source attribution, cancellation, invalid-input preservation and discarding a previous-song selection. The Android channel test verifies the smaller native read-limit argument and oversized-return rejection. Fatal-info analysis is clean. Complete source ZIP integrity/required platform files and version 0.1.20+21 were checked. The previous revision's full 111-test pass is recorded above; this change reruns the affected suites. Native Android picker/device execution and Windows picker execution remain unverified in this Linux environment. No APK/EXE or release was built/published for this change; the existing independent GitHub Actions remain included.


## 2026-10-20 — v0.1.21 standalone native smoke compilation

The supplied Windows CI log fails before native playback starts: tool/native_smoke.dart imports storage.dart, which imported Flutter services for AndroidSecretVault. Running under plain Dart cannot load dart:ui. Moved the Android vault unchanged to lib/android_storage.dart and updated its app/test consumers; shared storage now imports dart:typed_data directly and no Flutter libraries. Windows DPAPI, vault paths, Android encryption and persisted formats are unchanged. The Windows workflow now compiles the standalone smoke script before automated tests/native build, on cache hits as well as misses. The original repeated real-native smoke step remains required.

Verification: plain Dart 3.13.1 successfully compiled the actual tool/native_smoke.dart to a kernel file on Linux (exit 0), directly checking the failed import graph without loading Windows DLLs. Storage/core, Android vault/document bridge and backup/export suites passed **18 tests**, with one Windows-only case skipped; workflow cache contracts passed **2 tests**, with one Windows-only case skipped. The workflow test now requires the new compile check even on cache hits. Fatal-info analysis is clean. Source/client/About versions are 0.1.21+22 / 0.1.21. Complete ZIP integrity, new module and platform/workflow files were checked. Windows DLL execution, all three real-native smoke processes, installation and Android device execution were not rerun in this Linux environment; the Windows action must verify those after committing this source. No release or executable was built/published here.


## 2026-10-20 — Android sdkmanager CI correction (v0.1.21 unchanged)

The supplied Ubuntu Actions log shows successful apt-get installation followed by sdkmanager: command not found (exit 127). Added the official android-actions/setup-android action at verified v3 commit 9fc6c4e9069bf8d3d10b2204b1fb8f6ef7065407 after Java setup and before Flutter/package installation. It provisions command-line tools, accepts SDK licenses and exposes sdkmanager on PATH. Explicit packages: platform-tools avoids the action's legacy default tools package. Existing Android 36/build-tools 36.0.0/NDK 28.2.13676358 installation and independent ARM64-default build remain unchanged. This is workflow/test/documentation only, so source version stays 0.1.21+22; the Windows native-smoke fix and all app features remain included.

Verification: **4 Android platform tests passed**. The workflow contract parses YAML and checks the immutable setup-action pin, unconditional execution, platform-tools package selection and ordering before the existing sdkmanager invocation. Source ZIP integrity and required platform files checked. The GitHub-hosted action and APK build were not executed locally; commit this corrected source and start a new Android workflow run on that commit. Rerunning the failed older commit does not pick up workflow edits.


## 2026-10-20 — v0.1.22 Install and restart handoff

The user reported failure after downloading, at Install and restart. The local Windows helper launch previously returned a detached process handle and immediately shut down Auralis, without confirming PowerShell had loaded the helper. Script-start failure could therefore close the application without an installer. The helper also used PowerShell's ambient LASTEXITCODE after invoking a GUI installer; the revised helper starts the GUI executable through ProcessStartInfo, waits for that process and reads its own ExitCode explicitly.

The app now clears stale readiness/error files, starts the helper and requires an atomically written acknowledgement matching the helper PID within 15 seconds before requesting existing graceful shutdown/required exit. Missing/wrong readiness, early errors and timeout stop the helper and keep the application open. Retry clears old files. Once the app exits, the helper rechecks SHA-256, starts the exact verified installer with quoted /DIR and /LOG arguments, and reports nonzero exit codes through update-error.txt. Inno installer output goes to installer.log. Existing update-only installer restart behavior, integrity checks, trusted URL rules and user data remain unchanged. Error UI includes the download folder for manual recovery. An older installed updater cannot gain this fix until one manual installation replaces it.

Verification: the **complete Flutter suite passed 117 tests**, with **23 Windows-only checks skipped** on Linux; fatal-info analysis is clean. Added tests cover readiness success/missing/wrong PID/early error, no application exit on helper failure and successful retry. Existing download-integrity, redirect, cleanup, cancellation, exit ordering, UI, Android, lyrics and backup tests remain passing. The Windows handoff test now compiles a harmless Windows GUI executable that records arguments and returns controlled codes, replacing the CMD fixture; it tests acknowledgement, no installation before parent exit, spaced paths, tamper rejection and an actual GUI exit code 7. That test cannot run on Linux and must pass in the Windows action. A real Inno upgrade, Windows/device runtime and the user's exact installed version/failure log remain unverified here; these changes address observed handoff weaknesses without claiming a reproduced device-specific failure.

Source/client/About metadata is 0.1.22+23 / 0.1.22. Complete source ZIP integrity, both independent workflows and prior Android SDK setup fix were checked. No executable/APK was built or release published locally. Commit the complete source, allow Windows CI to build/publish the new installer, then manually install that build once if the current updater cannot hand off successfully. Keep the existing installation/application-data folders and Telegram session.


## 2026-10-20 — v0.1.23 Android Gradle compatibility

The supplied Android job reached assembleDebug and failed while applying dev.flutter.flutter-gradle-plugin because the wrapper used Gradle 8.13.0, below Flutter 3.47.1's enforced 8.14.0 minimum. The generic AGP 9/new DSL tip was not the failing constraint: settings.gradle.kts pins AGP 8.13.2 and both Flutter DSL opt-out flags already exist.

Updated the wrapper distribution to Gradle 8.14.3 and official SHA-256 bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531, verified against the official services.gradle.org checksum endpoint and the downloaded binary ZIP. AGP 8.13.2, Kotlin plugin 2.2.20, Java 17, NDK and API targets remain unchanged. No dependency-validation bypass flag was added. Android source verification now checks the wrapper minimum and requires a pinned distribution checksum; a regression fixture using 8.13 is rejected before native/APK compilation.

Verification: all **6 Python Android build-tool tests passed**, including the new old-Gradle rejection case and existing source/signing/APK ABI checks. The actual project wrapper validated/unpacked the official Gradle ZIP and completed ./gradlew --version successfully on Java 17, reporting Gradle 8.14.3. Direct Java network access is unavailable in this environment, so the checksum-verified official ZIP was prefetched into the wrapper's ordinary download cache; the project's distribution URL/checksum were retained and the wrapper performed its own extraction/validation. A full Android APK build and plugin dependency resolution were not performed locally; rerun the Android action on the updated source to verify those. The previous complete Flutter suite pass remains recorded above; this revision changes build configuration/validation and version metadata, without app behavior changes.

Source/client/About metadata is 0.1.23+24 / 0.1.23. Complete ZIP integrity, the matching wrapper URL/checksum, source version and independent Windows/Android workflows were checked. Prior updater, standalone smoke and Android SDK setup repairs remain included. No executable/APK or release was built/published here.


## 2026-10-20 — v0.1.24 visible Up Next in smaller windows

The screenshots showed a medium desktop window with only the Up Next heading/count and no preview songs. The prior sizing formula reserved 520 scaled pixels before allocating any row, while choosing the artwork layout from the entire page height. That preserved a large stacked cover/details area and gave the preview zero rows even when rearranging the current song could make room.

Now Playing now budgets queue previews first using a smaller cover/details allowance, then chooses horizontal versus stacked artwork from the remaining height and available width. This fixes the shared full-page and side-panel layout without adding page scrolling. The preview stays bounded at three songs and the full Queue action remains available. At extreme short heights that cannot fit a preview, the heading says Queue instead of Up Next. Metadata truncation, favorite/lyrics/playlist/sleep controls and transport behavior remain included.

Verification: the complete Flutter suite passed **117 tests**, with **23 Windows-only cases skipped**, and fatal-info static analysis is clean. The existing adaptive regression now asserts that medium desktop viewports expose a hit-testable first upcoming row fully inside the page; it includes 1000×700 and 1018×680 (matching the screenshot's approximate client size), alongside 360×480, 390×844, 520×560, 760×650, 900×480, 1280×800 and 1920×1080, plus 130% text. Existing no-Scrollable, drag-does-not-move-artwork, visible controls and Queue navigation assertions remain passing. Actual 1000×700, 360×480 and 1920×1080 synthetic widget screenshots were visually inspected. The 1000×700 frame shows all three upcoming rows; screenshots contain only original fixture artwork/metadata, not the user's music or desktop. Native desktop/device resizing and a compiled EXE/APK were not run for this change.

Source/client/About metadata is 0.1.24+25 / 0.1.24. Complete source ZIP integrity, the new medium-window screenshot, both independent workflows and previous Gradle/updater/SDK fixes were checked. No release or executable was published locally.


## Android single-ABI APK packaging correction (CI only)

The Android build log confirmed successful Flutter/Gradle `assembleDebug` but failed
`tool/verify-android.py` with `ValueError: Unexpected ABI in the APK.` The native
libraries supplied by media dependencies can include additional ABIs even when
Flutter compilation uses `--target-platform android-arm64` or `android-x64`.
The workflow now adds Flutter's documented `--split-per-abi` and copies the
actual `app-$ABI-$mode.apk` output before verification. This deliberately
preserves strict checks against mixed ABIs, missing TDLib/libmpv/Flutter
libraries, ELF 16 KiB load alignment, APK signing and zip alignment.

Local checks: all **8 Python Android tooling tests passed** (two new regression
tests for the workflow output and mixed-ABI native archive); Android source
verification passed; workflow YAML and extracted Bash syntax parsed correctly.
The build container does not have Flutter/Dart or an Android SDK, so an actual
APK build, Flutter widget tests and Android device installation were not run
locally. Re-run the Android GitHub Action to confirm an ABI-pure debug/release
APK and its other post-build checks. The app code and app version are unchanged.


## 0.1.34+35 lyrics scroll-cache argument fix — 20 October 2026

Replaced the integer passed to `scrollCacheExtent` in `lib/lyrics_view.dart` with `const ScrollCacheExtent.pixels(800)`, as required by Flutter’s typed cache-extent API. The existing rendering import supplies this type. Source inspection found no other cache-extent arguments in the project. Flutter and Dart are not installed in this editing environment, so the analyzer and Flutter tests could not be run locally; rerun the existing Android and Windows CI checks.


## 0.1.35+36 responsive Now Playing layout — 20 October 2026

The supplied Linux CI log reports four widget-test failures: the responsive UI test (77px bottom overflow), compact collection controls (14px right overflow), return from lyrics (120px bottom overflow), and adaptive Now Playing at 360×480 (14px right overflow). The inspector errors shown afterward occur while describing already-deactivated overflow render objects; they are not evidence here of a separate app disposal defect.

The hero now decides its layout from its own constraints after the queue preview is allocated. Short layouts place artwork/title above the five action buttons instead of squeezing those buttons beside artwork into a 226px row. Actions wrap across the available width; narrow portrait layouts use icon buttons with their existing tooltips. Portrait artwork uses the space remaining after metadata/actions rather than forcing a percentage height above a non-shrinking details column. Extremely short panels retain the title while the artist remains available in the player bar. The companion sidebar cover also flexes around its fixed text/actions. Queue previews, every action, playback controls, and the no-page-scroll behavior remain covered by existing tests.

The adaptive test additionally requires all five action buttons and artwork bounds to stay within the page across its existing nine sizes; the responsive Library expectation now reports its viewport size. Version metadata in pubspec, About, and the Telegram client is 0.1.35+36 / 0.1.35. The previous typed ScrollCacheExtent fix remains included.

Local verification: all modified Dart files parse with the tree-sitter Dart grammar, and the packaged ZIP is checked for integrity and an exact expected file diff. This is syntax checking, not Flutter type analysis or runtime layout validation. Flutter/Dart are unavailable locally and the matching SDK could not be retrieved, so no widget-test or analyzer pass is claimed for this revision. Rerun `flutter analyze --no-pub --fatal-infos` and `flutter test --no-pub --reporter expanded` in the existing Android and Windows workflows. No APK/EXE build or release was performed locally.


## 0.1.36+37 Telegram channel-browser overflow — 21 October 2026

The supplied follow-up CI logs show that the earlier Now Playing, collection, lyrics-return and responsive UI failures are cleared. Linux reports 117 passed, 23 skipped, and one failure; Windows reports 140 passed and the same one failure. Both fail in the adaptive test on the Telegram destination at 360×480 with a 4px bottom RenderFlex overflow.

The authenticated Telegram page previously laid out the search, guidance, wrapping channel actions, and error banners as fixed children above an Expanded channel list. On the short phone viewport those header children alone exceeded the available height. Search remains fixed, while the guidance/actions/errors and lazy channel rows now share a bounded CustomScrollView using slivers. The empty state participates in that same scroll area. This avoids relying on a smaller font or an arbitrary four-pixel spacing reduction and leaves the controls reachable when rows wrap.

The existing adaptive test still rejects layout exceptions at every size. It additionally scrolls to the fixture channel in Telegram and requires that row to be hit-testable, checking usable channel access as well as the absence of overflow. All earlier Now Playing containment and no-page-scroll assertions remain included. Source/About/Telegram version metadata is 0.1.36+37 / 0.1.36.

Local verification: modified Dart syntax was checked with the tree-sitter Dart grammar; the source ZIP was checked for integrity and an exact expected six-file diff from 0.1.35. Flutter is not installed in this editing environment, so neither flutter analyze nor flutter test ran locally. The CI results above are the user's supplied results for the previous revision, not a claimed pass for 0.1.36. Rerun the existing analysis and complete test steps on Android/Linux and Windows. No APK/EXE build or release was performed locally.


## 0.1.37+38 Now Playing tile ink surface — 21 October 2026

The supplied Windows and Linux logs both fail the adaptive test at 390×844 on Now Playing: a ListTile detects an opaque decorated ancestor between itself and its nearest Material. This is an ink/background painting assertion, rather than another RenderFlex overflow. Windows reports 140 passed and one failure; Linux reports 117 passed, 23 skipped, and one failure.

The local Now Playing panel helper is used by both the hero and Up Next panels. Its existing colored/bordered Container now wraps its contents in Material(type: MaterialType.transparency). Up Next rows therefore paint their tile backgrounds and interaction effects onto a surface above the opaque decoration. This follows Flutter's documented transparent-Material solution, preserves all existing panel geometry, and fixes every preview row through the shared helper. Other ListTile sites were inspected: Library track rows already have their own Material, while playlists, Telegram, settings, updates, and statistics have no intervening colored decoration on their tile-to-Material path.

The existing adaptive test exercises 390×844 with upcoming tracks and retains its strict exception checks. No test was disabled or made to ignore this assertion; all previous tests and the Telegram scroll regression are unchanged. Source/About/Telegram version metadata is 0.1.37+38 / 0.1.37.

Local checks: modified Dart syntax, archive integrity, and an exact five-file diff from 0.1.36 were verified. Flutter is unavailable locally, so no analyzer or widget-test pass is claimed. Rerun the existing static analysis and complete Flutter test steps in both workflows. No binary build or release was performed locally.

Reference: https://api.flutter.dev/flutter/material/Ink-class.html (transparent Material above opaque graphics).


## 0.1.37+38 test-only action hit-target correction — 21 October 2026

The supplied Windows and Linux logs now fail at the adaptive test's assertion that the entire `now-playing-actions` widget is hit-testable. That key identifies a Wrap layout. Finder.hitTestable() probes the target element's centre by default; the centre of a left-aligned or multi-row Wrap can be unused space rather than a button. This assertion therefore tests a layout coordinate that is not intended to be interactive.

The assertion now requires `buttons.hitTestable()` to find all five actual action buttons, using the existing descendant finder for IconButton and FilledButton. This verifies five intended tap targets instead of one arbitrary point in the surrounding layout. Existing five-button presence checks, artwork/button bounds, layout-exception checks, no-scroll checks, Queue navigation, preview visibility, and the Telegram channel reachability check remain unchanged. No error is swallowed and no test is skipped.

This revision changes only the adaptive test and release/verification notes. Every application source file, pubspec, platform file, and workflow is byte-identical to 0.1.37+38; there is no application-version increment.

Local checks: the modified Dart test parses with the tree-sitter Dart grammar; source ZIP integrity and an exact three-file diff from the preceding 0.1.37 archive were verified. Flutter is unavailable locally, so neither a Flutter test pass nor an analyzer pass is claimed. Rerun the complete existing CI checks.

Reference: https://api.flutter.dev/flutter/flutter_test/Finder/hitTestable.html (default Alignment.center and relative target coordinates).


## 0.1.37+38 CI-only Android release attachments — 21 October 2026

The supplied release screenshot shows Windows ZIP/installer, source and checksums, but no APK. The Android workflow and its documentation explicitly built Actions artifacts only and had no GitHub Release publication job. No inference about whether the Android native build succeeded or the repository's signing secrets are configured is made from that screenshot.

Android now exports its signing state and has a separate publisher after a successful signed build on main or a matching stable version tag. Build permission stays contents: read; publishing alone receives contents: write. The publisher downloads the APK/provenance from the same successful run, verifies the artifact checksum, creates a deterministic provenance archive and ABI-specific checksums, and appends those three assets without clobbering any existing file. It verifies GitHub's SHA-256 digests and byte sizes. Public APK publication is skipped for debug builds, with the signing requirement explained in the Actions summary. Existing APK ABI, native ELF, signing and ZIP-alignment gates remain intact.

Windows remains the shared release publisher. Android can stage verified assets in a draft if it finishes first, or append to the existing stable release if Windows finishes first. Both publishing jobs use the existing stable-release repository concurrency group; Windows workflow and publisher code are unchanged. Existing tags are never moved. When a publishing-only commit fills an older version's release, the publisher compares the Android/runtime sources, lockfile, pubspec, assets, notices, and native builder against the release tag and rejects changed app sources. Identical completed Android publications are preserved; partial same-artifact retries only upload missing names. Separate per-ABI provenance/checksum names avoid collisions with Windows assets.

Local validation: all **20 Python Android tooling/publisher tests passed**, including real temporary Git histories and real temporary signing-key handling. GitHub calls are replaced by a process-local stand-in; tests publish nothing. Cases cover Windows-first and Android-first order, draft handling, completed and partial retries, preserving existing Windows/Android assets, app-source mismatch, CI-only source compatibility, PR/branch/tag/signing guards, tampered artifacts, missing notices, metadata/API failures and server digest mismatch. Workflow YAML, cross-workflow release locking, read/write permission boundaries, signed/event guards and default ARM64 were checked. Android source verification passed; Python modules and the modified Dart workflow test parse successfully.

Application source, pubspec/version, Android project, Windows workflow and Windows publisher are unchanged. The test-only action hit-target correction and all earlier fixes remain included. Flutter, Dart, Android SDK, GitHub CLI and PowerShell are unavailable in this editing container, so the complete Flutter/Windows suites, an actual APK build and real GitHub upload were not run locally. Commit this source and run the current Android workflow on main; an old-run rerun will not adopt changed workflow code. Configure all four signing secrets before expecting a public APK attachment.


## 0.1.37+38 CI-only optional Android release signing — 21 October 2026

Per the user's request, custom signing is optional for GitHub Release attachments. Main and stable-tag builds now publish in both modes: all four signing secrets configured selects the existing release-key build; all four absent selects the existing debug-key build and publishes its explicitly named `debug.apk`. The publisher receives the actual build signing state and downloads the matching release/development artifact rather than requiring a signed output or hard-coding the release artifact name. Unknown signing states and unsupported ABIs still fail, and PR/feature-branch publication remains disallowed. Partially configured custom signing remains an explicit configuration error. APK checksum, signature, native ABI/ELF, zip-alignment, provenance and server digest checks remain enabled.

Debug checksums and provenance receive a debug suffix; release-key asset names remain compatible with the previous revision. This permits both modes to coexist under the same version without replacing each other's files or Windows downloads. Existing release/tag guards, source compatibility checks, retry behavior and shared draft handling are retained.

Validation: all **23 Python Android tooling/publisher tests passed**. Three additional cases exercise publishing without custom signing, the absent-signing-state debug default, and coexistence of debug and release assets. Existing misuse/signing-state, metadata, integrity, immutability, retry and source compatibility tests remain active. Workflow YAML, mode-specific artifact selection, permissions, publishing event guards, shell syntax and modified Dart test syntax were checked; Android source verification passed. GitHub calls were simulated and no APK was uploaded from this workspace. Flutter/Android builds and the full Flutter suite still require CI. Application source, Android project, Windows workflow/publisher and pubspec/version are unchanged at 0.1.37+38.


## 0.1.39+40 responsive Now Playing and lyric motion blur — 23 October 2026

Now Playing follows the supplied reference's large rounded cover, next-cover peek, left-aligned track details, three transport pills, and grouped shuffle/repeat/favorite controls, using Auralis's violet/charcoal theme. Phones use a stacked layout and compact windows move artwork beside metadata. Wider PC/landscape pages place artwork beside the full controls and reserve an Up Next row when there is room. The full page owns its seek and playback controls, so it does not repeat the smaller bottom dock. Phones use the header's Back, Settings, and Queue actions here; normal navigation and the dock return in Library. Incoming-only page fades avoid shrinking the outgoing player while those elements reappear.

Automatic synced-lyric line changes use a single 480 ms controller shared with the follow-scroll duration and a bounded vertical blur pulse (up to 3.5 sigma). Only the lyric viewport is filtered. The lazy list is retained as AnimatedBuilder's child, and ImageFiltered is disabled once motion settles. Initial positioning, manual browsing, and user/system reduced motion stay sharp. Navigation/disposal cancels the animation; rapid line changes restart the same controller rather than accumulating work.

Validation in a Linux editing environment with Flutter 3.47.1 / Dart 3.13.1:

- Locked dependency resolution succeeded; pubspec.lock is unchanged and no dependency was added.
- Flutter analysis with --no-pub --fatal-infos found no issues.
- Full Flutter suite: 119 passed, 23 existing Windows-only cases skipped, zero failures.
- The focused adaptive/lyrics suite passed all 15 tests. Adaptive coverage checks 360×480, 390×844, 520×560, 760×650, 844×390, 900×480, 915×412, 1000×700, 1018×680, 1280×800, and 1920×1080. Additional cases use 130%, 180%, and 200% text. Assertions cover bounds, hit testing, no page scrolling, one seek control, play/pause, favorite/repeat actions, seeking, queue access, and return navigation.
- The lyric regression observes an active blur during line changes, restart on rapid advances, a sharp settled/centered line, unblurred manual browsing, and no ongoing animation under either reduced-motion setting.
- All 8 Python Android tooling tests passed.
- Updated Now Playing screenshots at 360, 390, 844, 1000, 1280, and 1920 pixels wide are automated test renders with synthetic tracks and original fixture artwork. Representative compact phone, tall phone, landscape, and desktop frames were visually inspected.

These checks do not build an APK/EXE or verify a live Telegram account, native device playback, or frame-time performance on physical hardware. Run the existing platform CI workflows to build v0.1.39. Optional Android signing and release publishing are unchanged.
