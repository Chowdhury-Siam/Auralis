# Third-party notices and native provenance

Auralis's original source is AGPL-3.0-or-later. Third-party components retain their own terms. This source delivery contains no PixelPlayer or mpvRx app source/assets and contains no native DLLs.

| Component | Terms / source |
|---|---|
| Flutter and generated Windows host | BSD-3-Clause; [Flutter](https://github.com/flutter/flutter), retained text in `docs/FLUTTER-LICENSE.txt`. |
| Dart SDK | BSD-style SDK notices; distributed by Flutter. |
| media_kit 1.2.6+auralis.2, media_kit_video 2.0.1, and media_kit_libs_windows_video 1.0.11 | MIT; [media-kit](https://github.com/media-kit/media-kit), retained text in `docs/MEDIA-KIT-LICENSE.txt` and `third_party/media_kit/LICENSE`. The vendored runtime includes Windows COM/shutdown fixes documented in `third_party/media_kit/AURALIS_PATCH.md`; upstream copyright headers are retained. Native libraries have separate terms. |
| ffi 2.2.0, path 1.9.1, path_provider 2.1.6 | BSD-3-Clause; [Dart native packages](https://github.com/dart-lang/native), [Dart core packages](https://github.com/dart-lang/core), [Flutter packages](https://github.com/flutter/packages). Dart/Flutter include package notices in the generated Flutter license asset. |
| package_info_plus 10.2.1, crypto 3.0.7 | BSD-3-Clause; [plus_plugins](https://github.com/fluttercommunity/plus_plugins), [Dart core](https://github.com/dart-lang/core/tree/main/pkgs/crypto). Used for installed-version metadata and update integrity. Transitive package notices are included by Flutter. |
| cryptography 2.9.0 | Apache-2.0; [cryptography](https://github.com/dint-dev/cryptography). AES-GCM and PBKDF2 for password-protected account backups. Flutter includes its license in the generated notices asset. |
| file_selector 1.1.0 and platform implementations; cross_file 0.3.5+5 | BSD-3-Clause; [Flutter packages](https://github.com/flutter/packages/tree/main/packages/file_selector), [cross_file](https://github.com/flutter/packages/tree/main/packages/cross_file). Native file dialogs and file objects; package notices are included by Flutter. |
| media_kit_libs_android_video 1.3.8 | MIT wrapper; [media-kit](https://github.com/media-kit/media-kit). Downloads native video build v1.1.7 for Android; native mpv/FFmpeg licenses are separate. See Android provenance below. |
| audio_service 0.18.19 and audio_session 0.2.4 | MIT; [audio_service](https://github.com/ryanheise/audio_service), [audio_session](https://github.com/ryanheise/audio_session). Flutter includes package/transitive notices in its license asset. |
| TDLib 1.8.68 | Boost Software License 1.0; full text in `docs/TDLIB-LICENSE.txt`. Build revision: `a94b83d67ab4c8397c6245e541b31a4131ea2f79`. |
| OpenSSL and zlib | Dependency-specific licenses copied by `tool/build-tdlib.ps1` into `native/licenses/`; versions/build inputs follow vcpkg revision `664933b8d385dfc01f4e0cdff4c7c74e71f6a740`. |
| libmpv and FFmpeg native playback | Build-dependent GPL/LGPL and dependency terms. Do not infer native binary licensing from the MIT wrapper. See below. |

## Playback binary selected by the pinned plugin

The package's Windows CMake manifest downloads:

- Archive: `mpv-dev-x86_64-20230924-git-652a1dd.7z`
- [Exact archive](https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z)
- Upstream plugin MD5: `a832ef24b3a6ff97cd2560b5b9d04cd8`
- Independently recorded SHA-256: `dce982222d7a23e4a1c6f0fb6cc39f6e899a6714624b95ea49cff6558ee97572`
- [Native build recipe repository](https://github.com/media-kit/libmpv-win32-video-build).
- [mpv licensing explanation](https://github.com/mpv-player/mpv/blob/master/Copyright), [FFmpeg licensing](https://ffmpeg.org/legal.html).

The archive contains a native DLL and headers, not a complete corresponding-source distribution. The build recipe repository includes external codec/library recipes. Its current HEAD alone does not establish every source revision/configuration used for the 2023 binary. **Complete corresponding native source and exact build-input verification remain unfinished.** Before public binary distribution, rebuild playback from fully pinned sources, preserve every dependency's required notices, provide complete corresponding source/build instructions under the applicable GPL/LGPL terms, and audit updates/security. A URL to a generic upstream HEAD or this app's source alone is insufficient.

The video plugin also downloads [ANGLE 1.0.1](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/tag/v1.0.1) for Windows video rendering. Its archive SHA-256 is `cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a`.

## Test-only TDLib binary

Local native smoke tests used the `tdjson` 1.8.68 CPython 3.12 Windows x64 wheel from PyPI, checksum-verified as SHA-256 `0ce9a92d2ceaa2020eaf83af4310b411b015a340b26b35931aa873d690afd8bd`. Its DLLs remain outside this source deliverable in the task scratch folder; the Python binding is not a dependency of Auralis. The tested native library reported version 1.8.68. This does not verify the separate MSVC source-build script or its dependency versions.

CI builds TDLib from its pinned public source instead. Preserve its generated `native/build-manifest.json` and `native/licenses/` alongside any bundle. Flutter package notices are in the generated application `NOTICES` asset and accessible through Settings → Licenses; native notices are also supplied as files by the packaging script.

## Optional lyrics service

[LRCLIB](https://lrclib.net/docs) is an optional HTTPS service, not bundled app code or a runtime package dependency. Auralis independently implements its API client and line-timed LRC parser. Online lookup is explicitly requested in the lyrics view and sends song title/artist/duration only. Retrieved or pasted song lyrics retain their respective owners' rights; the Auralis source license does not relicense that content. Only original synthetic lyric text is included in tests/screenshots. No PixelPlayer code or assets are reused.


## Android native provenance

`tool/build-tdlib-android.sh` builds the same TDLib revision as Windows (`a94b83d67ab4c8397c6245e541b31a4131ea2f79`) and OpenSSL 3.5.4 (`c1eeb9406b6142148f267594197d853403d10208`) with NDK 28.2.13676358, Android API 24, static OpenSSL/C++ and 16 KiB ELF alignment. Android supplies system zlib. The script retains TDLib/OpenSSL licenses and a build manifest under `native/android/`; the workflow includes them with the APK artifact. Binary inputs and signing files are excluded from this source ZIP.

The Android media_kit plugin downloads v1.1.7 native archives from [libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.7), verifies the upstream package's checksums and packages libmpv/FFmpeg/helper libraries. Its MIT wrapper does not relicense native codec libraries. As with the Windows milestone above, a complete native corresponding-source/security/license audit is still required before public binary distribution; this task does not claim a Play Store-ready or audited codec distribution. The workflow checks all packaged ELF libraries for the requested ABI and 16 KiB load alignment before retaining APK artifacts. No mpvRx/PixelPlayer source or assets are included.
