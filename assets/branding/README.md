# Auralis icon

Original A/play artwork authored for Auralis; AGPL-3.0-or-later, like the application. No upstream player artwork is used.

`auralis.svg` is the editable source; `auralis.png` is its 256 px preview. The Windows resource `windows/runner/resources/app_icon.ico` contains PNG frames at 16, 20, 24, 32, 40, 48, 64, 96, 128 and 256 px. Rasterize the SVG at those sizes when changing the icon, preserving transparency.

`Runner.rc` embeds the ICO in the executable; the window and Start menu shortcut use that resource. Inno Setup uses the same ICO for the installer. Rebuild the executable and installer to apply artwork changes.

Android 8+ uses adaptive launcher resources in `mipmap-anydpi-v26`, with a full-bleed dark background and the original A/play vector paths centered in the foreground. This avoids the white wrapper and extra inset that launchers can add to legacy icons. Android 13+ also supplies a monochrome layer for themed icons. The density PNGs remain the fallback for Android 7. Rebuild and install the APK to apply these resources.
