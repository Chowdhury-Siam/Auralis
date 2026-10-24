# GitHub Releases and application updates

Repository: **[Chowdhury-Siam/Auralis](https://github.com/Chowdhury-Siam/Auralis)**.
Current source target: **v0.1.70** (`0.1.70+71`).

Android and Windows build independently; **Publish Auralis release** waits for both
successful artifacts from the same trusted main commit. **Clean completed Auralis
runs** removes green runs after publication and failures after a minimum ten-minute
retention period. Build artifacts needed for an unpublished release are retained.

See [RELEASE_PIPELINE.md](RELEASE_PIPELINE.md) for the authoritative current flow,
release notes, update notices, signing, retries and cleanup timing. That flow
supersedes older same-workflow publisher instructions. See [SYNC.md](SYNC.md) for
one-time multi-device sync deployment and pairing. No GitHub/Cloudflare deployment
or release was performed from this workspace.

## TDLib build cache

The workflow restores `native/*.dll`, `native/licenses/` and `native/build-manifest.json`. The stable v2 key includes Windows 2022/x64/Release, the runner image version and `hashFiles('tool/build-tdlib.ps1')`. That script contains the TDLib/vcpkg pins and native compiler configuration. Changing those native inputs or the runner image invalidates the cache; edits to UI, app version or release/publishing steps do not. Native options belong in the native build script; bump the cache namespace when changing assumptions outside that script.

The earlier v1 key also hashed the entire workflow. [Run 39261767369](https://github.com/SiamTest/Auralis/actions/runs/39261767369) at `a7248a6e308049bee23198f94fdf2545fe50bac6` rebuilt TDLib even though a 12,851,116-byte v1 cache existed. Comparing that revision with successful run `39232305284` confirmed an identical native builder and workflow differences only in the publisher. The release edit changed the combined workflow/builder hash, explaining the miss. A green Restore step means the action completed; it does not by itself establish a hit.

To avoid another full build just to rename the key, the migration step recognizes two audited v1 keys: `dd3ad69f…` from the previously successful build and `5e62127e…` from the running release-workflow revision. Migration is enabled only when the current Windows builder's `hashFiles` is exactly `3bd38120fd24502f920e57bbec0cad701d81e9e660707d0fe01a37997fcc506a`. Both old combined hashes were reproduced from the exact repository files with Windows checkout line endings, and both native builders match. Every key includes the current runner image. A changed builder disables migration.

The previous-cache restore first requests the exact `5e62127e…` key, then the full `dd3ad69f…` key as a fallback. Only an exact recognized key may skip compilation; an unexpected prefix extension is rejected by the build condition. A stable-key hit skips native compilation and saving. A recognized legacy hit skips compilation and saves the payload under the stable key. If all acceptable entries miss, the pinned source build runs and is saved immediately afterward. The source, payload paths and archive-version inputs are preserved. Native smoke tests still run for every path.

GitHub controls cache scope, quotas and eviction, so a missing cache or changed image can still cause compilation; no fixed timing is promised. The migration is a compatibility bridge and can be removed after the relevant images have stable-key caches. To force a fresh cache, change the `tdlib-...-v2` namespace and remove/disable legacy migration for that change. The cached payload contains build outputs and notices only, with no credentials, sessions or downloaded music.

The currently running job cannot adopt a new workflow midway through; let it finish before committing the update if you want to preserve its work. This task cannot upload the fix through the READ-only connection. The complete project ZIP includes it; replacing only `.github/workflows/windows.yml` also applies this configuration fix. Actual GitHub migration/hit behavior still needs a new run.

Implementation follows the official [restore](https://github.com/actions/cache/blob/0057852bfaa89a56745cba8c7296529d2fc39830/restore/README.md) and [save](https://github.com/actions/cache/blob/0057852bfaa89a56745cba8c7296529d2fc39830/save/README.md) actions, pinned to that commit.

## Application update flow

- Auralis reads its installed version from Windows package metadata, using `package_info_plus`; it does not assume the source's version is the installed version.
- Automatic checks are enabled initially, run three seconds after startup, on resume (at most once per five minutes) and every thirty minutes while the app is open, and can be disabled in Settings. Settings also has a manual Check now button. No background scheduled task/service is installed.
- Checks use the configured public repository's latest stable GitHub Release. Drafts, prereleases, same/older versions, wrong asset names, missing SHA-256 digests, oversized files, and download URLs from another repository are not accepted.
- A new version shows a banner. Download retrieves that exact Windows x64 installer using HTTPS and verifies its byte count and the SHA-256 digest reported by GitHub. Redirects are limited to GitHub's specified download hosts. Incomplete or corrupt downloads are not executable candidates.
- Installation requires **Install and restart**, followed by confirmation. The file is hashed again before handoff. Following Yutaka's Windows updater, Auralis launches the verified setup.exe directly as a detached process with no shell or PowerShell helper. It passes its PID, installation directory and log path as separate arguments, then runs the shared orderly audio/TDLib shutdown and required process exit. Inno Setup waits up to 90 seconds for that process before beginning setup and aborts if waiting fails. Complete the visible setup wizard; the update-only Run entry reopens Auralis after success.
- Update errors do not replace the installed version. Windows launch/closing errors are shown in Settings with the retained download folder. Installer diagnostics are written to `installer.log` in that folder. A failed installer may require reopening Auralis manually. Settings, the DPAPI vault and Telegram database/cache remain in the user's application-data directory; they are not inside the installation folder or removed by an update.

This is **automatic update detection with user-confirmed installation**, not forced or silent replacement without the user's approval. Downloading also requires the user's click. The installer displays its custom Auralis setup window, with no reboot request or administrator elevation for a per-user install. Installing into an administrator-protected custom location is not supported by the updater.

Update files are stored under the app support directory's `updates/release-*` folders. Existing downloads/logs are retained; automatic cleanup and resuming a download across process restarts are not implemented. An interrupted download can be retried from Settings.

## Trust and current limits

GitHub's digest detects corrupted/mismatched downloads; it is **not** an independent publisher signature. A compromised repository/release publisher can publish a malicious installer and matching hash. Windows installers are currently unsigned; Authenticode signing and a separate signed update manifest are not implemented. Keep repository release permissions and GitHub accounts secure. The updater does not embed a GitHub token and supports public repositories only.

The default update source is `Chowdhury-Siam/Auralis`. CI explicitly builds with `--dart-define=AURALIS_RELEASE_REPOSITORY=$env:GITHUB_REPOSITORY`, so an intentional fork uses its own repository; local builds default to Chowdhury-Siam/Auralis. Changing the source requires rebuilding the app. Users cannot enter arbitrary executable URLs in Settings.

The original native playback corresponding-source/security audit remains outstanding. **Resolve native source/licenses and codec updates before public binary distribution.** This revision publishes automatically from successful `main` builds as requested; technical checks and a stable-release flag do not substitute for that audit. The application source ZIP contains this project, not complete corresponding source for every prebuilt native playback dependency. See `THIRD_PARTY_NOTICES.md`.

Primary documentation: [GitHub release API](https://docs.github.com/en/rest/releases/releases), [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create), [Inno Setup command-line parameters](https://jrsoftware.org/ishelp/topic_setupcmdline.htm).


## Additional build caches

The workflow reuses these public build inputs and intermediates:

| Cache | Reused work and compatibility |
| --- | --- |
| Flutter SDK | Existing action cache, pinned Flutter version/architecture/revision; cache restore/extraction still takes time. |
| Pub packages | Existing action cache, explicitly enabled; its key includes the lockfile. `pub get --enforce-lockfile` still checks the graph and integrity. |
| Compiled TDLib | Existing stable v2 native-builder/image key and audited legacy migration, unchanged. A matching DLL cache skips source compilation. |
| vcpkg binaries/downloads | New conditional fallback when TDLib must compile. Persists downloaded source/tools and compiled OpenSSL/zlib/gperf packages; vcpkg checks package ABIs before reuse. The primary key includes the native builder hash and runner image; fallback is restricted to the same Windows image/architecture. |
| Windows build intermediates | New cache for CMake/MSVC output, libmpv archive/extraction and Flutter Windows build output; excludes the final runner Release directory. Reconfiguration and the release build always run. |
| Dart/native hook intermediates | New cache for `.dart_tool/flutter_build`, `hooks_runner`, `native_assets` and Windows native-asset build output; reused with the Windows intermediates. Package configuration and generated plugin symlinks are recreated. |

The Windows/Dart compatibility prefix includes runner image, exact Flutter SDK key, lockfile, Windows native source/configuration and vendored media_kit. The primary key adds application source/assets/pubspec hashes. UI/version edits can restore the previous compatible build while receiving a new entry; native input or dependency changes use a new compatibility prefix. Workflow-only edits do not invalidate these caches or the stable TDLib cache. Compiler/Flutter input checks remain responsible for deciding which intermediate outputs can be reused. The build target and original-quality playback behavior are unchanged.

vcpkg cache directories are created as absolute paths before the native builder runs. Its download cache uses VCPKG_DOWNLOADS and its binary cache uses VCPKG_DEFAULT_BINARY_CACHE, following [Microsoft's environment configuration](https://learn.microsoft.com/en-us/vcpkg/users/config-environment) and [binary-cache ABI behavior](https://learn.microsoft.com/en-us/vcpkg/users/binarycaching). Both are ignored by Git. The builder script itself is untouched, preserving existing TDLib hits. The dependency cache saves non-cancelled partial progress even if TDLib fails; Windows intermediates are saved immediately after a successful Windows build, before smoke tests/packaging. [Restore/save actions](https://github.com/actions/cache/blob/0057852bfaa89a56745cba8c7296529d2fc39830/restore/README.md) use identical paths and primary keys.

No cache hit skips analysis, tests, the Windows build, native smoke tests, packaging or release digest verification. Final installers, dist output, Telegram sessions/credentials, generated plugin links and package configuration are outside these new caches. Inno Setup continues to use the runner's installed copy when present. Raw TDLib object/build trees are intentionally excluded: they can be much larger than its final DLL/dependency cache and increase upload/eviction pressure.

These new entries first fill on a run using the updated workflow. Cache transfer, Flutter startup, dependency checks, changed-code compilation and tests still take time. GitHub can evict or scope caches by branch/availability; misses rebuild normally. More caching does not guarantee a shorter run, and cross-run reuse/timings have not been measured for this revision. See [GitHub cache matching, access and eviction rules](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).


## Recovery from the v0.1.3 updater failure

If Settings shows Installed: 0.1.3, Download ready / SHA-256 verified, followed by Could not start the update, close Auralis and run the installer manually once. The latest public release checked for this repair is [v0.1.5](https://github.com/SiamTest/Auralis/releases/tag/v0.1.5), including embedded covers and Library sorting. [Its Windows installer](https://github.com/SiamTest/Auralis/releases/download/v0.1.5/auralis-0.1.5-windows-x64-setup.exe) has GitHub SHA-256 `28f6f2d13cd11a407d0c45fad5b00d4fd1ab99880874d40000901387b022338e`; the already downloaded copy was independently hashed and matches. No installer was executed here. Downloaded installers live under `%APPDATA%/Auralis/Auralis/updates/release-*/`. Installing to the same application directory preserves settings/session data; do not delete the application-data folder or sign out just to update. If previously using the portable ZIP, use the new installed shortcut afterward.

The old application cannot acquire a source-code fix before it updates. v0.1.24 contains the handoff repair for future builds: finish the existing audio/TDLib/session-lock cleanup, then request a required engine exit. Windows' cancelable-exit acknowledgement can arrive before its asynchronous framework shutdown decision; comparing that acknowledgement with exit incorrectly killed the waiting installer helper. Cleanup is shared with normal window close and runs once. If cleanup fails, the process remains and the helper is stopped; the updater distinguishes cleanup failure, helper launch failure and installer-integrity failure with actionable recovery messages. The helper still waits for process termination and rehashes the installer before execution. SHA-256 checking does not replace code signing; installation and end-to-end update/restart remain unverified here.


## Install and restart recovery and diagnostics

An installed application keeps its existing update code until replaced. If that version cannot install updates, close Auralis and run the newly built Windows setup.exe manually once, choosing the existing installation folder. Keep the application-data folder; signing out or deleting settings is unnecessary. Future updates then use the repaired handoff. A source ZIP alone cannot repair the already-installed executable.

v0.1.43 removes the failing PowerShell helper/readiness handshake entirely. It follows Yutaka’s direct Windows executable launch, retaining exact release asset selection, trusted HTTPS redirects, byte-count/SHA-256 verification and a second SHA-256 check immediately before launch. The setup wizard waits for the original Auralis PID in `InitializeSetup`; timeout or process-access failure aborts setup. If Auralis cannot finish closing, cancel the installer and retry. The installer is retained for manual recovery, with `installer.log` beside it. Old `update-error.txt` files belong to earlier helpers and are no longer produced.

The native Windows launch regression uses a harmless GUI fixture in a path containing spaces, an apostrophe and an ampersand, and checks that separate arguments arrive intact. It never installs software or accesses a Telegram account. The Windows action compiles the actual Inno installer during packaging; real Windows installation and update/restart still need device verification. Linux tests alone cannot establish that result.


## Android draft retry recovery — v0.1.44

The Android publisher distinguishes unpublished drafts from published releases. A regenerated APK can differ between CI runs, including when the runner creates a new debug signing key. Missing draft files are uploaded and differing files owned by the current Android version/ABI/signing variant can be replaced, after rechecking the release is still a draft. Unchanged assets are skipped. The three current Android outputs (APK, native provenance ZIP and their checksum file) are verified against GitHub SHA-256 and sizes afterward. Windows release files, tags and other Android variants are outside this replacement list. Published partial-release conflicts report that a new version is required; completed published Android variants remain untouched on retries.

The source is bumped to **0.1.44+45** for a fresh tag/asset set after the reported v0.1.43 collision. Commit this complete source to `main` so Windows and Android build the same revision; an old workflow rerun will not acquire the change. Draft refresh uses GitHub CLI's [documented replace option](https://cli.github.com/manual/gh_release_upload), which deletes the old same-name draft asset before uploading its replacement; failure can leave the draft incomplete until retry. Existing publisher concurrency serializes both platform workflows. No release or tag was mutated from this workspace.

## 0.1.62 media artwork and lyrics

Android system players receive the current album cover and Auralis notification icon. The lyrics page has a top back button and one options menu, with no source footer. Missing embedded lyrics automatically fall back to LRCLIB on opening the page, using song metadata only. Late online responses cannot overwrite newer imported or pasted lyrics. Shared Android/Windows version: 0.1.62+63.

## 0.1.63 compact player dock

The bottom player is a rounded inset card. Repeat, sleep timer and volume are removed from the dock. Horizontal swiping fully stops audio and its stream, cancels sleep timing, clears the playback queue and hides the card. Short swipes snap back and seeking remains independent. Shared Android/Windows version: 0.1.63+64.
