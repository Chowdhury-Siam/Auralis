# Auralis Windows video shutdown patch

The package is based on the published [media_kit_video 2.0.1 archive](https://pub.dev/packages/media_kit_video/versions/2.0.1), SHA-256 `afaa509e7b7e0bf247557a3a740cde903a52c34ace9810f94500e127bd7b043d`. See [LICENSE](LICENSE).

The original Windows plugin replied to `VideoOutputManager.Dispose` while the output and its mpv render context still had queued work. The native player could destroy the mpv core as soon as it received that reply. The patched plugin orders output operations on one worker and replies on the Windows platform thread after Flutter acknowledges texture removal and the render worker frees the mpv context. Resized textures remain alive until Flutter acknowledges their removal too.

The existing Windows COM lifetime fix in `third_party/media_kit` still applies. Android plugin code is unchanged.
