; CI capability probe. ISCC.exe's file version need not match ISCmplr.dll.
#if Ver < EncodeVer(6, 7, 0)
  #error Auralis's dark installer requires Inno Setup 6.7 or later.
#endif

[Setup]
AppName=Auralis compiler check
AppVersion=1.0
CreateAppDir=no
Uninstallable=no
Output=no
WizardStyle=modern dark hidebevels includetitlebar
WizardBackColor=#111015
