# Android verification fix for 0.1.248

The Flutter suite completed successfully in the reported CI run (644 passed, 24 skipped). The subsequent `verify-android.py --source-only` command failed because it still required the broad storage and media-read permissions retired with the On this device Library source.

The source verifier now explicitly rejects those four permissions. Required playback/network/update permissions, private updater paths, backup restrictions, Gradle pinning, signing-file exclusions, APK completeness, native ABI checks and 16 KiB ELF alignment validation remain intact. A regression test injects each retired permission into a temporary manifest and verifies that the source guard rejects it with a clear assertion.

Validated locally:

- `python3 tool/verify-android.py --source-only` — passed.
- `python3 -m unittest discover -s tool -p 'test_android*.py' -v` — 40 tests passed.
- `python3 tool/release-notes.py` — release notes match 0.1.248.
- `python3 tool/verify-visualizer-sources.py` — passed.

Only the verification script, its Python tests and this note change. No Dart application files, manifest, dependencies, workflows or release metadata change. The app version remains 0.1.248+249. The Flutter suite was not rerun for this CI-only correction.
