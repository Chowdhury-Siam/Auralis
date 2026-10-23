# Windows native shutdown fix

The first [GitHub Actions run](https://github.com/SiamTest/Auralis/actions/runs/39206678100), commit `634f23b802888603c18e18bb2679de8e0eb2c957`, built TDLib and the Flutter Windows application. DPAPI, TDLib initialization, local decoding/seeking, and simulated-cache loopback playback checks passed. The process then failed with access violation `0xC0000005` in `libmpv-2.dll`, five seconds after printing its report. Packaging and installer generation did not run.

media_kit 1.2.6 returns from `dispose()` before native shutdown, closing the Dart wakeup callback and scheduling `mpv_terminate_destroy` five seconds later. The matching crash time points to that teardown path. An [upstream callback-lifetime report](https://github.com/media-kit/media-kit/issues/1443) describes a related ordering problem on Android; it does not establish the precise Windows instruction that failed here. The original smoke test exited successfully locally, so the CI crash was not reproduced on this machine.

## Subsequent failure and COM diagnosis

The next supplied CI trace still failed at `libmpv-2.dll+0x13fa81`, now inside the `_terminateDestroy` worker. This disproves the first patch as a sufficient fix; callback ordering alone did not resolve CI.

Binary inspection of the pinned development DLL identified the function boundary `0x13fa40..0x13faad`, its `Hotplug uninit` log string, a call at `0x13fa81` through COM vtable slot `0x38`, and a final `CoUninitialize` import. These match WASAPI `hotplug_uninit` and `IMMDeviceEnumerator_UnregisterEndpointNotificationCallback` in the exact mpv build source: [ao_wasapi.c](https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/audio/out/ao_wasapi.c) and [ao_wasapi_changenotify.c](https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/audio/out/ao_wasapi_changenotify.c). This maps the failing native operation; premature COM lifetime expiry is the evidence-based diagnosis being addressed, not a confirmed CI reproduction on this local machine.

Revision `1.2.6+auralis.2` retains the Windows COM MTA before each native player's creation and releases it after native termination and callback closure. Microsoft's [CoIncrementMTAUsage documentation](https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coincrementmtausage) specifies that this keeps MTA resources alive even when MTA worker threads exit, and permits decrementing the returned cookie from another thread. This avoids trying to pair thread-bound COM initialization calls across asynchronous Dart/native threads. No audio-device observation is disabled, no native DLL is replaced, and no crash/exit status is ignored.

## Changes

- Vendor media_kit's MIT Dart runtime as `third_party/media_kit`, retaining upstream notices. The app's path dependency applies the same fix in both the Flutter runner and standalone tests; no pub-cache edits are required.
- On Windows, unregister wakeups, stop event polling, drain queued Dart event handlers, terminate/join libmpv in a worker isolate, then close its Dart callback. `Player.dispose()` waits for this sequence. Other platforms retain upstream teardown behavior.
- Retain a Windows COM usage cookie from initialization through complete destruction, then release it once. Validate HRESULTs and handle creation/initialization failures.
- Print the native smoke report after cleanup. Exercise four create/play/seek/dispose lifecycles in each process.
- CI runs `tool/native_smoke_repeat.dart`, which requires three separate smoke processes to exit successfully. It checks real exit codes, including crashes after printed output; it neither forces process exit nor ignores a failed native test.

## Local verification

With the COM lifetime revision, three native smoke processes exited naturally with code 0, covering 12 player lifecycles. Each process passed DPAPI, TDLib 1.8.68 initialization/close, an explicit `audio-device-list` query, generated WAV playback and seeking, and loopback playback/seeking through the simulated TDLib cache. Each reported `nativeShutdown: {completed: true, cycles: 4}`. Shutdown-cycle messages now identify progress before destruction, while the success report remains after cleanup. Tests used the native binaries and null audio output described in `VERIFICATION.md` and `THIRD_PARTY_NOTICES.md`.

The COM lifetime revision subsequently passed the actual [GitHub runner in run 39232305284](https://github.com/SiamTest/Auralis/actions/runs/39232305284), including source-built TDLib, Flutter Windows compilation, the strict native smoke test and installer creation. This is a teardown fix, not a refresh or licensing audit of the older native libmpv binary. Live Telegram login, audible hardware output, installer installation and an end-to-end app update remain unverified.

## Apply to the existing repository

Keep the existing Windows runner/header fixes. Replace the following paths with this delivery and commit them together:

- `pubspec.yaml` and `pubspec.lock`
- `third_party/media_kit/` (entire supplied directory, including its LICENSE)
- `tool/native_smoke.dart` and `tool/native_smoke_repeat.dart`
- `.github/workflows/windows.yml` and `analysis_options.yaml`
- Updated README, notices and verification documents

Push that new commit to the repository's branch to start a fresh workflow. Clicking **Re-run jobs** on the old failed run builds its old source and cannot pick up the fix. The current connection has READ permission, so this task has not pushed it remotely.
