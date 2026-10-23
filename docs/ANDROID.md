# Android build and use

Auralis now shares its Flutter UI and Telegram library/player features between Android and Windows. The Android app ID is `app.auralis.auralis`; minimum Android is **7.0 / API 24**. The default APK is **ARM64**, suitable for the Redmi Note 10 Pro. x86_64 is available for emulator testing. There is no 32-bit APK in this milestone.

## Separate GitHub Action

Commit the complete project, including the new `android/` folder, to your repository. Open **Actions → Android APK build**. It runs independently on pushes, pull requests and manual dispatch, with a manual architecture selector. Windows keeps `.github/workflows/windows.yml` and its existing compiled TDLib cache. The Android build never needs Windows build results. Publishing shares the same versioned release: Windows publishes the release, and Android can attach its assets before or after that happens.

The Android workflow installs Java 17, Flutter 3.47.1, Android SDK 36 / build tools 36.0.0, NDK 28.2.13676358 and host build tools. It resolves the lockfile, runs analysis and tests, builds pinned TDLib/OpenSSL for the selected ABI, compiles an ABI-split APK with `--split-per-abi`, verifies its signing and required native libraries, checks that the APK contains **only** the requested ABI, checks all native ELF load segments for 16 KiB alignment, and uploads the APK, SHA-256 checksums and native provenance as an Actions artifact. The initial TDLib build is substantial; later compatible runs reuse its ABI-specific cache. Tests and the final APK build always run, including on cache hits.

Download **auralis-android-arm64-v8a-development** or **auralis-android-arm64-v8a-release** from the successful run's **Artifacts** area, extract it and install its APK on your phone. Both release-key and development/debug APKs built on `main` or a matching stable `v*` tag also run **Attach Android APK to release**. Custom signing secrets are optional. The publisher adds the built APK, Android checksums, and native provenance to the matching GitHub Release. Release-key builds use `...-release.apk`, `SHA256SUMS-android-<ABI>.txt`, and `auralis-<version>-android-<ABI>-provenance.zip`; builds without custom keys use `...-debug.apk`, `SHA256SUMS-android-<ABI>-debug.txt`, and `auralis-<version>-android-<ABI>-debug-provenance.zip`. Android checksums have their own name, so Windows checksums and downloads remain intact. Feature-branch/PR builds stay in Actions artifacts; Google Play upload is not included.

## Automatic GitHub Release attachments

1. Commit this complete source to `main`. Signing secrets are optional; leave all four unset to build and publish a development/debug APK, or configure all four below to use your own release key.
2. Open **Actions → Android APK build → Run workflow**, choose `main`, and keep **arm64-v8a** for a phone APK. A push to `main` also runs it automatically. Re-running an old commit still uses that commit's old workflow.
3. Once analysis, tests, native checks, and APK signature/alignment verification succeed, the separate publishing job attaches the built APK to `v<pubspec version>`. The existing **v0.1.37** release can be filled without an app-version bump when the app sources still match that tag; publishing-only changes are allowed, different app sources are rejected.

If Android finishes first for a new version, it creates a **draft**, uploads and verifies its Android assets, and leaves publication to the existing Windows publisher. If Windows finishes first, Android appends its assets to the published release. Both publishing jobs use the same concurrency group. For a brand-new version started manually only on Android, also run the Windows workflow for that same commit to publish the shared draft.

Published assets are not overwritten and tags are not moved. Completed same-version Android releases are left intact on retries; interrupted uploads can resume from the same verified artifact. ARM64 and x86_64 asset/checksum/provenance names are distinct. Missing signing secrets produce an explicit Actions summary and publish the development APK with its debug filename. The APK still has Android's default debug signature; no custom keystore or secrets are required. Debug and release-key assets have separate names and may coexist in the same version. A partially configured signing set fails rather than silently falling back.

The APK build keeps read-only repository permission. Only the guarded publishing job receives `contents: write`, and it downloads the tested artifact from its own successful Android build. Publication is never authorized on pull requests or feature branches.

## Signing and upgrades

With no signing secrets, CI produces a **development/debug APK**, signed by the runner's debug key. This is for testing. Different clean runners can generate different debug keys; an APK with a different key cannot update an existing installation. Preserve/export your app data before uninstalling a development build. Published development APKs remain explicitly labeled `debug`; configuring a persistent release key is optional and provides consistent upgrade signing.

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

No secrets means a development APK; a partially configured set fails explicitly. Pull requests always build development APKs without release signing secrets. Signing files are temporary, ignored by Git and removed in an `always()` cleanup step. Release builds never silently use debug signing. Do not commit keys, `key.properties`, Telegram credentials, sessions or local SDK paths.

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
flutter build apk --debug --split-per-abi --target-platform android-arm64
python3 tool/verify-android.py build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk arm64-v8a
```

For a local release, create the ignored `android/key.properties` with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`, using an absolute keystore path or a path relative to `android/`. Then build with `--release`. Keep the same application ID and signing key across upgrades, and increment `pubspec.yaml` for each app update.

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
(`app-arm64-v8a-debug.apk` or `app-x86_64-debug.apk` for development builds).
The existing strict native ELF, ABI, signing and ZIP alignment checks remain enabled.
Flutter adds an ABI offset to the Android APK version code when splitting;
release updates still require a consistent signing key and increasing version codes.
This is a packaging/CI-only correction; the application version is unchanged.
