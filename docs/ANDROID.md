# Android build and use

Auralis now shares its Flutter UI and Telegram library/player features between Android and Windows. The Android app ID is `com.auralis.siam`; minimum Android is **7.0 / API 24**. The default APK is **ARM64**, suitable for the Redmi Note 10 Pro. x86_64 is available for emulator testing. There is no 32-bit APK in this milestone.

## Separate GitHub Action

Commit the complete project, including the new `android/` folder, to your repository. Open **Actions → Android APK build**. It runs independently on pushes, pull requests and manual dispatch, with a manual architecture selector. Windows keeps `.github/workflows/windows.yml` and its existing compiled TDLib cache. The Android build never needs Windows build results. Publishing shares the same versioned release: Windows publishes the release, and Android can attach its assets before or after that happens.

The Android workflow installs Java 17, Flutter 3.47.1, Android SDK 36 / build tools 36.0.0, NDK 28.2.13676358 and host build tools. It resolves the lockfile, runs analysis and tests, builds pinned TDLib/OpenSSL for the selected ABI, compiles an optimized release APK with `--release --split-per-abi`, verifies its signing, non-debuggable manifest and required native libraries, checks that the APK contains **only** the requested ABI, checks all native ELF load segments for 16 KiB alignment, and uploads the APK, SHA-256 checksums and native provenance as an Actions artifact. The initial TDLib build is substantial; later compatible runs reuse its ABI-specific cache. Tests and the final APK build always run, including on cache hits.

Download **auralis-android-arm64-v8a-development** or **auralis-android-arm64-v8a-release** from the successful run's **Artifacts** area, extract it and install its APK on your phone. Both saved-key and development-signature release APKs built on `main` or a matching stable `v*` tag also run **Attach Android APK to release**. Custom signing secrets are optional. The publisher adds the built APK, Android checksums, and native provenance to the matching GitHub Release. Release-key builds use `...-release.apk`, `SHA256SUMS-android-<ABI>.txt`, and `auralis-<version>-android-<ABI>-provenance.zip`; builds without a saved key use `...-development-release.apk`, `SHA256SUMS-android-<ABI>-development.txt`, and `auralis-<version>-android-<ABI>-development-provenance.zip`. Android checksums have their own name, so Windows checksums and downloads remain intact. Feature-branch/PR builds stay in Actions artifacts; Google Play upload is not included.

## Automatic GitHub Release attachments

1. Commit this complete source to `main`. Run the signing setup below once for automatic retained-key signing, or keep an existing custom key. Without either, compilation still uses release mode with an explicitly labelled development signature.
2. Open **Actions → Android APK build → Run workflow**, choose `main`, and keep **arm64-v8a** for a phone APK. A push to `main` also runs it automatically. Re-running an old commit still uses that commit's old workflow.
3. Once analysis, tests, native checks, and APK signature/alignment verification succeed, the separate publishing job attaches the built APK to `v<pubspec version>`. An existing version can be completed by a publishing-only change when the Android app sources still match its tag. Different app sources require a new version; tags are never moved. This recovery source uses **0.1.52+53** to avoid the existing 0.1.43 assets/tag.

If Android finishes first for a new version, it creates a **draft**, uploads and verifies its Android assets, and leaves publication to the existing Windows publisher. If Windows finishes first, Android appends its assets to the published release. Both publishing jobs use the same concurrency group. For a brand-new version started manually only on Android, also run the Windows workflow for that same commit to publish the shared draft.

Published assets are not overwritten and tags are not moved. Completed same-version Android releases are left intact on retries. For an unpublished draft, a retry uploads missing files and refreshes differing Android files from the verified build, then checks every remote digest and size. It rechecks that the release is still a draft immediately before replacement; Windows files and other ABI/signing variants are outside the upload list. A failed refresh leaves an unpublished, potentially incomplete draft that the next retry can repair. A partially published release can resume only with matching existing files; a conflicting published file requires a new stable version. ARM64 and x86_64 asset/checksum/provenance names are distinct. Missing signing secrets produce an explicit Actions summary and publish the optimized APK with a development-release filename and Android's temporary debug signature. Development-signature and saved-key assets have separate names and may coexist in the same version. A partially configured signing set fails rather than silently falling back.

The APK build keeps read-only repository permission. Only the guarded publishing job receives `contents: write`, and it downloads the tested artifact from its own successful Android build. Publication is never authorized on pull requests or feature branches.

## Signing and upgrades

### One-time automatic setup

1. Create a [fine-grained GitHub token](https://github.com/settings/personal-access-tokens/new), restricted to **Chowdhury-Siam/Auralis**, with repository **Secrets: Read and write**. Add it to this repository's **Settings → Secrets and variables → Actions** as `ANDROID_SIGNING_SETUP_TOKEN`.
2. Commit this complete source to `main`, then open **Actions → Set up Android signing → Run workflow** on `main`.
3. The action generates a private RSA-4096 key with a random password and saves the key/alias/password together in the encrypted `ANDROID_SIGNING_IDENTITY` repository secret. It then starts a fresh **Android APK build** on `main`, which reads that identity and produces `auralis-0.1.52-android-arm64-v8a-release.apk`. Future builds reuse it automatically. No manual keytool command or four-secret setup is needed.

You can remove or revoke `ANDROID_SIGNING_SETUP_TOKEN` after successful setup; normal builds only need the saved identity. GitHub's default workflow token cannot manage repository secrets, so that one-time Secrets permission is needed. See [GitHub's repository secret API](https://docs.github.com/en/rest/actions/secrets#create-or-update-a-repository-secret). A separate build is queued after setup because repository secrets are read when a workflow is queued, as documented in [Secrets reference](https://docs.github.com/en/actions/reference/security/secrets).

Setup runs serialize and only run from `main`; reruns preserve existing identities and complete legacy signing sets. An incomplete legacy set fails rather than replacing an existing key. Private keys/passwords are never uploaded as artifacts, stored in Actions caches, committed or placed in job outputs. Secret components are registered for masking; native/GitHub command output is suppressed. Temporary signing files are cleaned after use. Preserve `ANDROID_SIGNING_IDENTITY`; deleting it loses this workflow's retained key. Existing custom signing secrets take precedence if both methods are present.

Without any signing identity, CI still builds an optimized, non-debuggable release APK, signed with the runner's temporary development key and labelled **development-release**. This fallback requires no secrets but does not guarantee matching certificates on later clean runners. Switching from an old debug/development APK to a new retained signing key can require uninstalling once; back up your account/settings before doing so. Once installed with the retained key, later same-key APK updates preserve app data. The final optimized APK size must be measured from a real build; no fixed reduction is promised.

### Existing custom key (optional)

To optionally use your own release key, create one private signing key, keep it securely and reuse it for all updates:

```bash
keytool -genkeypair -v -keystore auralis-release.jks -alias auralis -keyalg RSA -keysize 4096 -validity 10000
```

For custom release signing, add all four **repository Actions secrets** (otherwise leave all four unset):

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the complete private `.jks` file, as a single line |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Alias, e.g. `auralis` |
| `ANDROID_KEY_PASSWORD` | Key password |

A partially configured legacy set fails explicitly. Pull requests build optimized release-mode APKs with temporary development signatures and receive no release signing secrets. Signing files are temporary, ignored by Git and removed in an `always()` cleanup step. Do not commit keys, `key.properties`, Telegram credentials, sessions or local SDK paths.

## Android behavior

- The same Library, Telegram channel selection, covers, queue, playlists/favorites/recent music, lyrics, repeat/sleep timer, listening stats, export and Backup & Restore are available in the responsive interface.
- `audio_service` provides a media playback foreground service and notification/lock-screen/headset controls. It keeps the Flutter engine available while audio plays with the screen off. Calls/audio interruptions and headphone removal pause playback; it does not resume unexpectedly after a call. Swiping the app from Recents stops playback and clears the queue. Android force-stop and manufacturer battery restrictions can still stop the app.
- Credentials and the TDLib database key are encrypted with a non-exportable AES-256-GCM key in Android Keystore, with a fresh IV and authentication tag for every write. App data stays in Android's private support directory. OS backup/device-transfer of this data is disabled because the key is tied to the installation/device. Login codes and two-factor passwords are never saved.
- Stats are flushed when the app pauses as well as at the existing checkpoints. Pausing the UI does not stop background music. Process death may still lose the latest unsaved samples; playback queue/timers are session-only.
- Export and Backup & Restore use Android's system **Create document / Open document** picker, supporting Downloads and document providers without broad storage permissions. Selected document URIs are read/written via the content resolver on a worker thread. Local automatic recovery copies still use app-private files. Backup size/schema/integrity validation and confirmation are shared with Windows. Account backups now optionally include the closed TDLib database, API details and database key, encrypted with a user-chosen backup password. Restoring re-encrypts the credentials with this installation’s Keystore key and reconnects Telegram. Legacy settings-only backups remain supported. Music files are excluded; revoked/expired sessions still need a new login. See the [backup guide](GUIDE.md#listening-stats-export-and-backups).
- The Windows EXE installer/updater is disabled on Android. Install a newer APK signed with the same private key to upgrade; existing app data remains in place during an ordinary same-key upgrade. This milestone does not add an Android self-updater, Play Store upload or local music importing.

## Local build on Linux

Install Java 17, Flutter 3.47.1, Git, a C/C++ compiler, CMake, Ninja, Perl, gperf, OpenSSL and zlib development headers, plus Android command-line tools. Set `ANDROID_HOME` to your Android SDK. Use a CI environment variable in automation so Flutter does not need to detect the host through a cloud metadata service.

```bash
sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358'
flutter pub get --enforce-lockfile
flutter analyze --no-pub --fatal-infos
flutter test --no-pub --reporter expanded
python3 -m unittest discover -s tool -p test_android_tools.py
bash tool/build-tdlib-android.sh arm64-v8a
flutter build apk --release --split-per-abi --target-platform android-arm64
python3 tool/verify-android.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk arm64-v8a
```

For a local release signed with a retained custom key, create the ignored `android/key.properties` with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`, using an absolute keystore path or a path relative to `android/`. Then build with `--release`. Keep the same application ID and signing key across upgrades, and increment `pubspec.yaml` for each app update.

To test on a connected x86_64 emulator, build TDLib for x86_64 and use `--split-per-abi --target-platform android-x64`; the output is `app-x86_64-debug.apk`. The native Android Keystore test can then run with `cd android && ./gradlew connectedDebugAndroidTest -Ptarget-platform=android-x64`. This is an actual device/emulator test; host bridge tests alone do not verify Android cryptography or hardware playback. See VERIFICATION.md for what was run for this delivery and THIRD_PARTY_NOTICES.md for native distribution limits.


### CI SDK command-line setup

The Android workflow explicitly runs the commit-pinned android-actions/setup-android action after Java setup and before invoking sdkmanager. This provisions the command-line tools, accepts SDK licenses and adds sdkmanager to PATH; the following step installs the pinned Android 36/build tools/NDK packages. The apt-get output in the reported failure was successful; exit 127 came from the missing sdkmanager command. That SDK setup correction did not require an app version bump; see pubspec.yaml for the current app version. Commit the complete corrected source and run the Android APK build workflow on that commit; rerunning the previous commit uses its old workflow.


### Flutter 3.47.1 / Gradle compatibility

The Gradle wrapper pins 8.14.3 with the official distribution SHA-256. Flutter 3.47.1 enforces Gradle 8.14.0 or newer, so the previous 8.13 wrapper failed while applying the Flutter app plugin. AGP stays at 8.13.2, Kotlin at 2.2.20 and Java at 17. The existing android.newDsl=false and android.builtInKotlin=false settings remain; the generic AGP 9 migration hint was not the reported root failure. Dependency validation remains enabled. Android source verification now rejects Gradle below 8.14 before native/APK build work.


### Single-architecture APK verification fix

Flutter's `--target-platform android-arm64` flag selects the compiled Flutter target,
but an APK built without ABI splitting can still package native libraries from
other ABIs supplied by dependencies such as libmpv. That causes
`tool/verify-android.py` to fail with `Unexpected ABI in the APK.` even after
Gradle successfully completes `assembleDebug`. Always combine the chosen
`--target-platform` with `--split-per-abi` and copy the ABI-specific output
(`app-arm64-v8a-release.apk` or `app-x86_64-release.apk` for release-mode builds).
The existing strict native ELF, ABI, signing and ZIP alignment checks remain enabled.
Flutter adds an ABI offset to the Android APK version code when splitting;
release updates still require a consistent signing key and increasing version codes.
This is a packaging/CI-only correction; the application version is unchanged.


## Recovering an Android asset conflict

`Existing asset differs: auralis-0.1.43-android-arm64-v8a-debug.apk` means that a file with that version/ABI/signing name already exists with different bytes. Rebuilding identical source is not guaranteed to reproduce APK bytes, especially when a fresh runner generates a different development signing key. The former publisher rejected this in drafts as well as published releases.

Commit the complete **0.1.52+53** source to `main` and let both workflows run for that commit. It targets a new `v0.1.52` release without deleting or moving `v0.1.43`. Re-running an old 0.1.43 job still uses its old script/version. The corrected publisher can also refresh only its own conflicting Android assets while a release remains a draft, with local checksum/provenance validation and post-upload GitHub digest/size checks. Published downloads remain protected. Signing stays optional; the draft retry fix does not make development keys consistent between runners. Use a persistent release key for Android updates that preserve installed app data.


## 0.1.49 source update

The 0.1.49+50 source includes the explicit loopback-domain attributes required by
Android release lint, the Now Playing control and artwork effects update, and
cached artwork backdrops. The Reduce motion setting is retired; its old saved
value no longer disables the visuals. Platform accessibility preferences still
apply. Existing backups remain compatible.

Commit this complete source to main and start a fresh workflow run. A new run
builds and targets v0.1.49; retrying an old 0.1.48 job still runs its old checkout.
The Android publisher now explains a source/tag conflict and asks for a version
bump, rather than reporting a raw git diff traceback. Existing releases and tags
are preserved.


## 0.1.50 lyrics artwork background

The immersive lyrics view now shares the current artwork's blurred background
with Now Playing. The existing line focus blur, scrolling motion blur, highlight
transitions, synced/static modes, seeking, and controls are preserved. The same
cached backdrop is reused between cover and lyrics views. This source targets a
new v0.1.50 release so existing v0.1.49 tags and downloads remain unchanged.


## 0.1.51 playback timeline

The buffered-ahead overlay is no longer shown on the shared seek bar in Now
Playing, the lyrics view, or the player dock. The played waveform, seek thumb,
timestamps, and seeking remain. Audio buffering and all artwork/lyric blur and
motion effects are preserved. This source targets v0.1.51.


## 0.1.52 Android identity, updates, and credential recovery

The Android namespace, application ID, and Kotlin package are `com.auralis.siam`.
Android treats this as a separate app from `app.auralis.auralis`. Install the new
package manually once. Keep the old app until any available password-protected
account backup and settings backup have been restored. A settings-only backup
cannot transfer a Telegram sign-in, and a device-encrypted vault cannot be
copied between packages or devices. If the old key is already unreadable, sign
in to the new package again using your Telegram API details and verification.

Android now has App updates in Settings, update banners, manual checks, and
optional automatic checking/downloading at startup, on resuming after six hours,
and every six hours while the app runs. Installation always requires Android's
confirmation; it never silently installs. Android may first ask to allow Auralis
to install updates from this source. Returning from that permission screen
continues the verified installation automatically.

The updater selects the signed release APK for arm64-v8a or x86_64 from the
configured public GitHub repository. Temporary development-signed APKs are not
used for automatic updates. Keep using the same retained signing identity from
the existing signing workflow. SHA-256 and download size are checked in Dart;
native code checks the checksum again, package ID, expected release version,
newer Android version code, same signing certificate, and native architecture.
Only the private APK update-cache folder is shared with the system installer.

Android credential saves now verify that the current device key can decrypt the
ciphertext before replacing the saved file. An unreadable local session offers
Sign in again with an explicit confirmation. Its protected vault and database
are set aside, while music and settings are kept; a fresh local key/sign-in can
then be created. Portable password-protected account backups remain supported.

Validation: the source checker validates the new application ID and restricted
update provider; regression tests cover Android asset selection, automatic
verified download without silent install, installer retries, native bridge
arguments, credential read-back failure, and fresh-session recovery. A full APK
build and device installation test are still required in CI/on Android.
