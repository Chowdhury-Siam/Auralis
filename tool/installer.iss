[Code]
function IsAuralisUpdate: Boolean;
begin
  Result := ExpandConstant('{param:AURALISUPDATE|0}') = '1';
end;

function OpenProcess(Access: LongWord; Inherit: BOOL; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

function InitializeSetup: Boolean;
var
  AppProcess: THandle;
  AppPid: Integer;
begin
  Result := True;
  if not IsAuralisUpdate then Exit;
  AppPid := StrToIntDef(ExpandConstant('{param:AURALISPID|0}'), 0);
  if AppPid <= 0 then Exit; { Allows a manually launched verified installer. }
  AppProcess := OpenProcess($00100000, False, AppPid); { SYNCHRONIZE }
  if AppProcess = 0 then
  begin
    Result := DLLGetLastError = 87; { ERROR_INVALID_PARAMETER: already exited. }
    if not Result then
      MsgBox('Cannot wait for Auralis to close. Close it and run this installer again.', mbError, MB_OK);
    Exit;
  end;
  try
    Result := WaitForSingleObject(AppProcess, 90000) = 0;
  finally
    CloseHandle(AppProcess);
  end;
  if not Result then
    MsgBox('Auralis did not close. Close Auralis and run this installer again.', mbError, MB_OK);
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
