# GitHub Releases and application updates

Configured repository: **[Chowdhury-Siam/Auralis](https://github.com/Chowdhury-Siam/Auralis)**. Current source target is **v0.1.43**, including visible Up Next previews in medium windows, the Android Gradle compatibility fix, the Yutaka-style direct Windows installer handoff and encrypted Telegram account backup, the plain-Dart native smoke compilation fix, .lrc file import, embedded music-file lyrics, the app-matching lyrics theme, the fixed one-page Now Playing layout, Android platform support and a separate Android APK workflow, listening stats, CSV/JSON export, Backup & Restore, favorites, persistent playlists and recently played, Play next, repeat one, duration/end-of-track sleep timers, the reference-style immersive lyrics page and all earlier fixes. Commit the complete source to main to run the updated Windows build and stable publisher; rerunning an older commit cannot apply it. No source or release was pushed/published from this workspace.

The Windows release flow below remains independent. Android builds run in `.github/workflows/android.yml` and upload APK artifacts; see [ANDROID.md](ANDROID.md). They do not edit Windows tags/releases or run the Windows publisher.

The canonical repository changed to `Chowdhury-Siam/Auralis` on 23 October 2026. Historical run and release links below retain their original repository for provenance. Builds that still embed the previous repository must be replaced with a new build to change their update source; source edits cannot change an already installed binary.

## Release flow

1. Upload the complete project as the repository root, including `.github`, `pubspec.lock`, tests, native notices and the vendored runtime. A push to `main` runs the Windows build/test/package job and, after success, the stable publisher. A manual run on `main` does the same. Other branches and pull requests produce artifacts only.
2. Analysis, automated tests, native smoke tests and installer packaging must succeed. The job packages a portable ZIP, per-user Inno Setup installer, application source ZIP from the committed revision, and `SHA256SUMS.txt`.
3. The publisher reads the stable version from `pubspec.yaml`. For the current `0.1.24+25`, it creates `v0.1.24` at the exact tested commit if that tag is absent. No manual tag is required. An existing tag must already resolve to the tested commit; it is never moved. Explicit stable tag builds remain supported and must match `pubspec.yaml`.
4. Using the publishing job's `GITHUB_TOKEN` with `contents: write`, it creates an unpublished draft with `--prerelease=false`. It resolves the draft-aware CLI lookup's numeric `databaseId`, checks that the corresponding REST release has the intended tag and remains a non-prerelease draft, then uploads all four assets. It refreshes metadata by numeric ID, verifies GitHub's SHA-256 asset digests, then publishes with `--draft=false --prerelease=false`. It never uses the published-only by-tag REST route to verify a draft. The newest stable version is marked Latest; releasing an older version preserves a newer Latest. Build permissions remain read-only, and publishing jobs serialize to avoid concurrent tag/asset updates.
5. Published versions are immutable. A later push with the same version reports that it is already stable and skips release mutation. For the next app update, bump `pubspec.yaml` to a new stable version, such as `0.1.25+26`, and commit to `main`; it automatically publishes `v0.1.25` after successful checks. A build-number-only change does not create a new stable release. An existing published prerelease is not silently overwritten; use a new stable version.

Optional tag-based release after completing the native distribution audit:

```powershell
git tag v0.1.24
git push origin v0.1.24
```

Tags such as `v0.1.3-beta`, mismatched versions, pull requests, other branches and mismatched checkout commits cannot publish. Existing drafts may resume only at their original tested tag/commit; a failed digest check leaves the draft unpublished. GitHub API permission/network errors fail explicitly instead of being treated as a missing release. An `untagged-…` URL is normal for an unpublished draft; it is not a reason to delete or move the version tag. The failed `v0.1.3` draft may remain; the new source uses `v0.1.24` because the existing version tag points to the previous tested commit.

Expected assets for `v0.1.24`:

```text
auralis-0.1.24-windows-x64.zip
auralis-0.1.24-windows-x64-setup.exe
auralis-0.1.24-source.zip
SHA256SUMS.txt
```

GitHub Actions and repository/org policies must permit the publish job's write token. No Telegram credentials or personal access token need to be committed or added to the app. **Windows compilation, native smoke tests and installer compilation passed in run 39232305284. Actual stable publication, installation and in-app update execution remain unverified.** The local machine still lacks Visual Studio C++ Build Tools and Inno Setup. Publisher behavior is tested with a process-local fake GitHub CLI; it makes no external mutations during tests.

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
- Automatic checks are enabled initially, run ten seconds after startup and every six hours while the app is open, and can be disabled in Settings. Settings also has a manual Check now button. No background scheduled task/service is installed.
- Checks use the configured public repository's latest stable GitHub Release. Drafts, prereleases, same/older versions, wrong asset names, missing SHA-256 digests, oversized files, and download URLs from another repository are not accepted.
- A new version shows a banner. Download retrieves that exact Windows x64 installer using HTTPS and verifies its byte count and the SHA-256 digest reported by GitHub. Redirects are limited to GitHub's specified download hosts. Incomplete or corrupt downloads are not executable candidates.
- Installation requires **Install and restart**, followed by confirmation. The file is hashed again before handoff. Following Yutaka's Windows updater, Auralis launches the verified setup.exe directly as a detached process with no shell or PowerShell helper. It passes its PID, installation directory and log path as separate arguments, then runs the shared orderly audio/TDLib shutdown and required process exit. Inno Setup waits up to 90 seconds for that process before beginning setup and aborts if waiting fails. Complete the visible setup wizard; the update-only Run entry reopens Auralis after success.
- Update errors do not replace the installed version. Windows launch/closing errors are shown in Settings with the retained download folder. Installer diagnostics are written to `installer.log` in that folder. A failed installer may require reopening Auralis manually. Settings, the DPAPI vault and Telegram database/cache remain in the user's application-data directory; they are not inside the installation folder or removed by an update.

This is **automatic update detection with user-confirmed installation**, not forced or silent replacement without the user's approval. Downloading also requires the user's click. The installer displays its ordinary setup wizard, with no reboot request or administrator elevation for a per-user install. Installing into an administrator-protected custom location is not supported by the updater.

Update files are stored under the app support directory's `updates/release-*` folders. Existing downloads/logs are retained; automatic cleanup and resuming a download across process restarts are not implemented. An interrupted download can be retried from Settings.

## Trust and current limits

GitHub's digest detects corrupted/mismatched downloads; it is **not** an independent publisher signature. A compromised repository/release publisher can publish a malicious installer and matching hash. Releases are currently unsigned; Authenticode signing and a separate signed update manifest are not implemented. Keep repository release permissions and GitHub accounts secure. The updater does not embed a GitHub token and supports public repositories only.

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
