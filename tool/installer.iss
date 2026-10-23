[Code]
function IsAuralisUpdate: Boolean;
begin
  Result := ExpandConstant('{param:AURALISUPDATE|0}') = '1';
end;

#ifndef AuralisVersion
  #error Run tool/package.ps1 -Installer to supply AuralisVersion.
#endif

[Setup]
AppId={{F86EBC1E-B48E-4A7B-BDF7-098A2336DAB8}
AppName=Auralis
AppVersion={#AuralisVersion}
AppPublisher=Auralis contributors
DefaultDirName={localappdata}\Programs\Auralis
DefaultGroupName=Auralis
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=auralis-{#AuralisVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
LicenseFile=..\LICENSE
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\auralis.exe
CloseApplications=yes
RestartApplications=no

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Auralis"; Filename: "{app}\auralis.exe"

[Run]
Filename: "{app}\auralis.exe"; Description: "Open Auralis"; Flags: nowait postinstall skipifsilent; Check: not IsAuralisUpdate
Filename: "{app}\auralis.exe"; Flags: nowait; Check: IsAuralisUpdate
