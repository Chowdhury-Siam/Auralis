# 0.1.247 validation

Implemented against the supplied 0.1.246 source, preserving existing playback, Telegram and collection code paths.

Completed locally:

- Static Dart analysis of `app.dart`, `telegram_video_view.dart`, `local_media_view.dart`, `library_widgets.dart`, both new metadata modules and both new test files: no issues found, using Flutter 3.47.1 framework sources and the Dart 3.13.1 analyzer.
- Seven metadata service tests executed with the standalone Dart test runner: passed. These cover normalization and season matching, ambiguous titles and conflicting years, AniList priority, request deduplication, persistent caches, TV/film fallback parsing, manual-selection races, offline behavior and artwork disk reuse.
- Added widget tests for phone, desktop, large text, manual selection and stale responses after a channel switch. These are included for CI; they were not executed locally.

The full Flutter suite and the six originally reported widget failures were not re-run locally. Automatic approval review stopped Flutter setup when it attempted a cloud instance metadata request. Offline checks proceeded without that endpoint. The keyboard fix now supplies keyboard visibility from above Scaffold to the common Library layout and both local-source panes; it does not weaken any of the existing failing test assertions.

Run the normal CI checks in the project environment:

```sh
flutter pub get
flutter analyze --no-pub --fatal-infos
flutter test --no-pub --reporter expanded
```

Metadata parsing uses mocked catalogue responses in the service tests. Live API/image availability and final on-device rendering still require network/device verification. Failed metadata requests leave video browsing and playback available.

## Subsequent validation

Version 0.1.248 now runs the complete Flutter regression suite in CI mode, avoiding automatic cloud-environment detection. This includes the metadata widget tests and the six Library regressions originally reported with 0.1.246. Final results and physical-device limits are recorded in [PERFORMANCE_0248.md](PERFORMANCE_0248.md).
