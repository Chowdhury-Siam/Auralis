# Windows desktop installer

Auralis uses the same custom desktop layout as Yutaka, with Auralis's existing
A/play icon, charcoal surfaces, purple accent, and music artwork. The setup
screen combines install location, Browse and an optional desktop shortcut.
Setup opens directly to this screen. Click Install once; Auralis opens and
setup closes automatically after a successful installation. No Next, Launch or
Done click is needed on the normal path. Folder and shortcut choices are
optional and stay inline. View license opens the included AGPL license.

The installer keeps Auralis's existing application ID, default per-user folder,
Start menu shortcut and release filename. Inno Setup still validates paths,
handles files in use, registers the uninstaller and remembers the installation
folder and shortcut preference. Settings, Telegram credentials and databases
remain in the user's app-data folder. The installer does not remove user data.

For updates started by Auralis, setup retains the PID wait before accessing app
files and the existing automatic restart after installation. Updates also close
setup automatically. The previous installation folder and shortcut choice are
reused. Silent non-update installs do not launch the app; silent update installs
retain their automatic restart. Genuine file-in-use, path-error or Windows
restart decisions remain available when needed.

## Build

Use Windows with Flutter's Windows toolchain, PowerShell 7.4+ and Inno Setup
6.7+. Build the complete Flutter/native bundle, then run:

```powershell
./tool/package.ps1 -Installer
```

Set `ISCC_PATH` to an explicit `ISCC.exe` if needed. The package script compiles
a capability probe before the real installer. The existing Windows workflow
uses a compatible installed compiler or downloads the official Inno Setup
6.7.3 installer, verifies its Authenticode signature, installs it in an explicit
runner-tools directory, and checks its capabilities. Generated branding is
checked in; the release runner needs no graphics dependencies.

Regenerate the sidebar and header icon with Pillow and Segoe UI or DejaVu Sans:

```bash
python3 tool/render-installer-branding.py
```

## Verification

The Windows workflow compiles the actual installer around a small fixture app
and a unique installation ID, then checks controls, Close/Cancel, invalid/custom
paths, Browse, shortcut choices and their persistence, install/upgrade, data
preservation, previous-folder reuse, one-click installation/upgrade, automatic app opening/installer closing and silent-mode behavior. It uninstalls only
the temporary fixture. It does not open the real app or read its account data.
Run the same check on Windows with:

```powershell
python tool/check-windows-installer.py --compiler "$env:ISCC_PATH" --logs artifacts/installer-ui-check
```

The source editing environment has no Windows, Inno Setup or Flutter SDK.
Artwork generation, Python syntax, workflow YAML, Dart syntax and 17 portable
regressions for the adapted GUI checker's input/polling helpers were verified
locally. The installer executable, actual Windows GUI and app upgrade have not
been built or run here; the Windows CI check must pass on the committed source.
