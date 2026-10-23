# Windows shutdown patch

Vendored Dart runtime source of media_kit 1.2.6 from the pub.dev package archive, under its original MIT license (see LICENSE). Copyright headers are retained. Publisher screenshots and the optional web HLS asset are omitted for this Windows application. This is third-party code, distinct from Auralis's AGPL application code. No mpvRx or PixelPlayer code is involved.

Changes by Auralis contributors, 19 October 2026:

- Windows `NativePlayer.dispose()` awaits native termination instead of returning and scheduling `mpv_terminate_destroy` five seconds later.
- Unregister the wakeup callback, stop Dart event polling, drain its per-handle event lock, terminate/join the native player in a worker isolate, and only then close the `NativeCallable`.
- Event callbacks queued before disposal return without polling a removed native handle.
- Revision `1.2.6+auralis.2` also retains Windows COM's MTA with `CoIncrementMTAUsage` before player creation, keeping its cookie per native handle. It releases that cookie with `CoDecrementMTAUsage` only after native destruction and callback closure. Both HRESULTs are checked. Null-player/failed-initialization paths release their retained COM reference.
- The first callback-only patch did not fix CI: the supplied second trace still faults at `libmpv-2.dll+0x13fa81`. That address maps to WASAPI hotplug notification unregistration, making COM object lifetime the targeted follow-up. The COM lifetime revision subsequently passed native smoke tests in GitHub run `39232305284`; no failure is suppressed.
- Other platforms retain the upstream disposal path. This app targets Windows x64 only.

The fix applies to both the desktop app and standalone smoke tests via a path dependency. Do not substitute a changed global pub cache or suppress the smoke process's exit code. When upgrading media_kit, compare this patch against the upstream shutdown implementation and rerun native shutdown tests.

Upstream: https://pub.dev/packages/media_kit/versions/1.2.6 and https://github.com/media-kit/media-kit. See also upstream issue https://github.com/media-kit/media-kit/issues/1443 for the callback-lifetime ordering problem (reported on Android; the local patch here is Windows-specific).

Windows COM lifetime API: https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coincrementmtausage. The OS-managed usage cookie supports release from another thread, unlike balancing `CoInitializeEx`/`CoUninitialize` across Dart worker threads.
