; Custom desktop layout adapted from Yutaka. Build with Inno Setup 6.7+.
#if Ver < EncodeVer(6, 7, 0)
  #error Auralis's dark installer requires Inno Setup 6.7 or later.
#endif
#ifndef MyAppName
  #define MyAppName "Auralis"
#endif
#define MyAppExeName "auralis.exe"
#ifndef AuralisVersion
  #error Run tool/package.ps1 -Installer to supply AuralisVersion.
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif
#ifndef IconFile
  #define IconFile "..\windows\runner\resources\app_icon.ico"
#endif
#ifndef BrandDir
  #define BrandDir "installer-assets"
#endif

[Setup]
; Keep this ID stable so existing installs upgrade in place.
#ifdef InstallerTestAppId
AppId={#InstallerTestAppId}
#else
AppId={{F86EBC1E-B48E-4A7B-BDF7-098A2336DAB8}
#endif
AppName={#MyAppName}
AppVersion={#AuralisVersion}
AppPublisher=Auralis contributors
AppPublisherURL=https://github.com/Chowdhury-Siam/Auralis
DefaultDirName={localappdata}\Programs\Auralis
DefaultGroupName={#MyAppName}
UsePreviousAppDir=yes
DisableStartupPrompt=yes
DisableWelcomePage=yes
; Use the real directory page under the custom shell so Inno validates and
; commits the inline install location before copying files.
DisableDirPage=no
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=auralis-{#AuralisVersion}-windows-x64-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoDescription=Auralis Installer
VersionInfoProductName=Auralis
VersionInfoCompany=Auralis
Compression=lzma2
SolidCompression=yes
WizardStyle=modern dark hidebevels
WizardBackColor=#111015
WizardImageFile={#BrandDir}\windows-sidebar.bmp
WizardImageBackColor=#111015
WizardSmallImageFile={#BrandDir}\windows-icon.bmp
WizardSmallImageBackColor=#111015
WizardImageStretch=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=Welcome to Auralis
WelcomeLabel2=Your music, your space.%n%nInstall Auralis on this computer to get started. Your existing Telegram sign-in, collections and settings stay in place during an upgrade.%n%nClick Next to continue.
FinishedHeadingLabel=Auralis is ready
FinishedLabel=Auralis has been installed on your computer.%n%nOpen the app and make yourself at home.
BeveledLabel=Auralis  {#AuralisVersion}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "..\LICENSE"; DestName: "LICENSE.txt"; Flags: dontcopy
Source: "{#BrandDir}\windows-sidebar.bmp"; Flags: dontcopy
Source: "{#BrandDir}\windows-icon.bmp"; Flags: dontcopy
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Open once and let setup close automatically. Scripted non-update installs
; remain quiet; update installs retain their existing automatic restart.
Filename: "{app}\auralis.exe"; Flags: nowait skipifsilent runasoriginaluser; Check: not IsAuralisUpdate
Filename: "{app}\auralis.exe"; Flags: nowait; Check: IsAuralisUpdate

[Code]
const
  BackgroundColor = $00151011;
  SurfaceColor = $001E1719;
  OutlineColor = $003E3136;
  TextColor = $00FFF3F6;
  MutedColor = $00B5A4AA;
  AccentColor = $00FFB5C7;

var
  Shell, Header, Sidebar, ProgressTrack, ProgressFill: TPanel;
  Headline, PhaseLabel, DetailLabel: TNewStaticText;
  FolderEdit: TNewPathEdit;
  ShortcutCheck: TNewCheckBox;
  BrowseButton, ActionButton, DismissButton, TitleClose, LicenseButton: TNewButton;
  InstallationFinished: Boolean;
#ifdef InstallerTestAppId
  ShortcutStateLabel: TNewStaticText;
#endif

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

function ReleaseCapture: Boolean;
  external 'ReleaseCapture@user32.dll stdcall';

procedure DragHeader(Sender: TObject);
begin
  ReleaseCapture;
  SendMessage(WizardForm.Handle, $00A1, 2, 0);
end;

function PanelAt(Parent: TWinControl; X, Y, W, H: Integer; Color: TColor): TPanel;
begin
  Result := TPanel.Create(WizardForm);
  Result.Parent := Parent;
  Result.StyleElements := [];
  Result.BevelOuter := bvNone;
  Result.Color := Color;
  Result.SetBounds(ScaleX(X), ScaleY(Y), ScaleX(W), ScaleY(H));
end;

function LabelAt(Parent: TWinControl; Text: String; X, Y, W, H, Size: Integer; Color: TColor; Bold: Boolean): TNewStaticText;
begin
  Result := TNewStaticText.Create(WizardForm);
  Result.Parent := Parent;
  Result.StyleElements := [];
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.Caption := Text;
  Result.Font.Name := 'Segoe UI';
  Result.Font.Size := Size;
  Result.Font.Color := Color;
  if Bold then Result.Font.Style := [fsBold];
  Result.SetBounds(ScaleX(X), ScaleY(Y), ScaleX(W), ScaleY(H));
end;

function ButtonAt(Text: String; X, Y, W, H: Integer; Click: TNotifyEvent): TNewButton;
begin
  Result := TNewButton.Create(WizardForm);
  Result.Parent := Shell;
  Result.Caption := Text;
  Result.Font.Size := 11;
  Result.SetBounds(ScaleX(X), ScaleY(Y), ScaleX(W), ScaleY(H));
  Result.OnClick := Click;
end;

procedure DismissClicked(Sender: TObject);
begin
  if InstallationFinished then
    WizardForm.NextButton.OnClick(WizardForm.NextButton)
  else
    WizardForm.CancelButton.OnClick(WizardForm.CancelButton);
end;

procedure LicenseClicked(Sender: TObject);
var
  ErrorCode: Integer;
begin
  ExtractTemporaryFile('LICENSE.txt');
  if not ShellExecAsOriginalUser('open', ExpandConstant('{tmp}\LICENSE.txt'), '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode) then
    MsgBox('The AGPL license is also included in the installed Auralis folder.', mbInformation, MB_OK);
end;

procedure BrowseClicked(Sender: TObject);
var
  Folder: String;
begin
  Folder := FolderEdit.Text;
  if BrowseForFolder('Choose where to install Auralis', Folder, True) then
    FolderEdit.Text := Folder;
end;

procedure FolderChanged(Sender: TObject);
begin
  WizardForm.DirEdit.Text := FolderEdit.Text;
end;

procedure ApplyDesktopTaskArgument(Argument: String; var Selected: Boolean);
var
  Tasks: TArrayOfString;
  I: Integer;
  Task: String;
begin
  Tasks := StringSplit(Argument, [','], stExcludeEmpty);
  for I := 0 to GetArrayLength(Tasks) - 1 do begin
    Task := Lowercase(Trim(Tasks[I]));
    if (Task = 'desktopicon') or (Task = '*desktopicon') then Selected := True
    else if Task = '!desktopicon' then Selected := False;
  end;
end;

function InitialDesktopShortcut: Boolean;
var
  Previous, Tasks: String;
begin
  Previous := GetPreviousData('DesktopShortcut', '');
  if Previous = '' then
    Result := FileExists(ExpandConstant('{autodesktop}\{#MyAppName}.lnk'))
  else
    Result := Previous = '1';
  Tasks := ExpandConstant('{param:tasks|__auralis_default__}');
  if Tasks <> '__auralis_default__' then begin
    Result := False;
    ApplyDesktopTaskArgument(Tasks, Result);
  end;
  ApplyDesktopTaskArgument(ExpandConstant('{param:mergetasks|}'), Result);
end;

#ifdef InstallerTestAppId
procedure ShortcutStateChanged(Sender: TObject);
begin
  // Observe the VCL property in the isolated fixture, not BM_GETCHECK's
  // native button state beneath the dark style hook.
  if ShortcutCheck.Checked then
    ShortcutStateLabel.Caption := 'TEST DESKTOP SHORTCUT: 1'
  else
    ShortcutStateLabel.Caption := 'TEST DESKTOP SHORTCUT: 0';
  Log('Auralis GUI check: ' + ShortcutStateLabel.Caption);
end;
#endif

procedure ActionClicked(Sender: TObject);
begin
  if InstallationFinished then begin
    WizardForm.NextButton.OnClick(WizardForm.NextButton);
    Exit;
  end;
  if WizardForm.CurPageID = wpPreparing then begin
    // Preserve Inno's close-app/restart decisions without reapplying options.
    WizardForm.NextButton.OnClick(WizardForm.NextButton);
    Exit;
  end;
  if (Length(FolderEdit.Text) < 3) or
     ((Copy(FolderEdit.Text, 2, 2) <> ':\') and (Copy(FolderEdit.Text, 1, 2) <> '\\')) then begin
    PhaseLabel.Caption := 'INSTALLATION NOT STARTED';
    DetailLabel.Caption := 'Choose an absolute folder path for Auralis.';
    WizardForm.ActiveControl := FolderEdit;
    Exit;
  end;
  WizardForm.DirEdit.Text := FolderEdit.Text;
  WizardForm.NextButton.OnClick(WizardForm.NextButton);
end;

procedure ShellKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = 27 then begin
    Key := 0;
    if DismissButton.Enabled then DismissClicked(Sender);
  end;
end;

procedure InitializeWizard;
var
  Image: TBitmapImage;
begin
  if WizardSilent then Exit;
  WizardForm.BorderStyle := bsNone;
  WizardForm.BorderIcons := [biSystemMenu, biMinimize];
  WizardForm.ClientWidth := ScaleX(960);
  WizardForm.ClientHeight := ScaleY(640);
  WizardForm.Position := poScreenCenter;
  WizardForm.Color := BackgroundColor;
  WizardForm.OuterNotebook.Hide;
  WizardForm.MainPanel.Hide;
  WizardForm.Bevel.Hide;
  WizardForm.Bevel1.Hide;
  WizardForm.BeveledLabel.Hide;
  WizardForm.BackButton.Hide;
  // ClickToStartPage checks NextButton.CanFocus before skipping the welcome
  // page. Keep the engine's button visible and enabled, outside the custom
  // layout. Hiding it here or in CurPageChanged strands setup on wpWelcome.
  WizardForm.NextButton.Left := ScaleX(980);
  WizardForm.NextButton.TabStop := False;
  WizardForm.NextButton.Default := False;
  // MainForm.Close also checks CancelButton.CanFocus. Keep the native
  // cancel button available to the engine without showing it in our layout.
  WizardForm.CancelButton.Left := ScaleX(1080);
  WizardForm.CancelButton.TabStop := False;
  WizardForm.KeyPreview := True;
  WizardForm.OnKeyDown := @ShellKeyDown;
  Shell := PanelAt(WizardForm, 0, 0, 960, 640, BackgroundColor);
  Header := PanelAt(Shell, 0, 0, 960, 76, SurfaceColor);
  Header.OnClick := @DragHeader;
  PanelAt(Shell, 0, 76, 960, 1, OutlineColor);
  Sidebar := PanelAt(Shell, 0, 77, 244, 563, SurfaceColor);
  PanelAt(Shell, 244, 77, 1, 563, OutlineColor);
  ExtractTemporaryFile('windows-sidebar.bmp');
  ExtractTemporaryFile('windows-icon.bmp');
  Image := TBitmapImage.Create(WizardForm);
  Image.Parent := Header;
  Image.SetBounds(ScaleX(22), ScaleY(18), ScaleX(38), ScaleY(38));
  Image.Stretch := True;
  Image.Bitmap.LoadFromFile(ExpandConstant('{tmp}\windows-icon.bmp'));
  LabelAt(Header, 'Auralis', 74, 15, 300, 26, 14, TextColor, True);
  LabelAt(Header, 'DESKTOP SETUP  ·  {#AuralisVersion}', 75, 43, 300, 20, 8, MutedColor, False);
  Image := TBitmapImage.Create(WizardForm);
  Image.Parent := Sidebar;
  Image.SetBounds(0, 0, ScaleX(244), ScaleY(563));
  Image.Stretch := True;
  Image.Bitmap.LoadFromFile(ExpandConstant('{tmp}\windows-sidebar.bmp'));
  Headline := LabelAt(Shell, 'Your music.' + #13#10 + 'Your space.', 290, 118, 620, 104, 26, TextColor, True);
  LabelAt(Shell, 'Bring your Telegram music library closer.', 292, 235, 610, 46, 12, MutedColor, False);
  LabelAt(Shell, 'Install location', 292, 306, 600, 22, 10, MutedColor, False);
  FolderEdit := TNewPathEdit.Create(WizardForm);
  FolderEdit.Parent := Shell;
  FolderEdit.SetBounds(ScaleX(292), ScaleY(334), ScaleX(477), ScaleY(36));
  FolderEdit.Text := WizardForm.DirEdit.Text;
  FolderEdit.OnChange := @FolderChanged;
  BrowseButton := ButtonAt('Browse…', 781, 333, 132, 38, @BrowseClicked);
  ShortcutCheck := TNewCheckBox.Create(WizardForm);
  ShortcutCheck.Parent := Shell;
  ShortcutCheck.SetBounds(ScaleX(292), ScaleY(384), ScaleX(610), ScaleY(24));
  ShortcutCheck.Caption := 'Create a desktop shortcut';
  ShortcutCheck.Checked := InitialDesktopShortcut;
#ifdef InstallerTestAppId
  // Keep fixture telemetry outside the visible layout. Production builds
  // contain neither this control nor its event handler.
  ShortcutStateLabel := LabelAt(WizardForm, '', 980, 200, 240, 24, 10, TextColor, False);
  ShortcutCheck.OnClick := @ShortcutStateChanged;
  ShortcutStateChanged(ShortcutCheck);
#endif
  PhaseLabel := LabelAt(Shell, 'READY TO INSTALL', 292, 446, 620, 24, 10, AccentColor, True);
  ProgressTrack := PanelAt(Shell, 292, 478, 621, 6, OutlineColor);
  ProgressFill := PanelAt(ProgressTrack, 0, 0, 0, 6, AccentColor);
  DetailLabel := LabelAt(Shell, 'Auralis opens automatically when installation finishes.', 292, 504, 620, 38, 10, MutedColor, False);
  LicenseButton := ButtonAt('View license', 292, 560, 150, 48, @LicenseClicked);
  DismissButton := ButtonAt('Cancel', 619, 560, 132, 48, @DismissClicked);
  ActionButton := ButtonAt('Install Auralis', 767, 560, 146, 48, @ActionClicked);
  ActionButton.Default := True;
  TitleClose := ButtonAt('×', 890, 18, 44, 38, @DismissClicked);
  TitleClose.Hint := 'Close installer';
  TitleClose.ShowHint := True;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = wpSelectTasks);
  // Inno creates TasksList immediately before asking whether to skip this
  // page. Earlier calls from the directory page act on an empty task list.
  if Result and not WizardSilent then begin
    if ShortcutCheck.Checked then WizardSelectTasks('desktopicon')
    else WizardSelectTasks('!desktopicon');
#ifdef InstallerTestAppId
    if ShortcutCheck.Checked <> WizardIsTaskSelected('desktopicon') then
      RaiseException('Native desktop task does not match the custom checkbox');
    if WizardIsTaskSelected('desktopicon') then
      Log('Auralis GUI check: native desktop task = selected')
    else
      Log('Auralis GUI check: native desktop task = deselected');
#endif
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  // Store the engine's final selection, including command-line silent installs.
  if WizardIsTaskSelected('desktopicon') then
    SetPreviousData(PreviousDataKey, 'DesktopShortcut', '1')
  else
    SetPreviousData(PreviousDataKey, 'DesktopShortcut', '0');
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Ready, Preparing, Finished: Boolean;
begin
  if WizardSilent then Exit;
  WizardForm.BackButton.Hide;
  Ready := (CurPageID = wpSelectDir) or (CurPageID = wpReady);
  Preparing := CurPageID = wpPreparing;
  Finished := CurPageID = wpFinished;
  FolderEdit.Enabled := Ready;
  BrowseButton.Enabled := Ready;
  LicenseButton.Enabled := Ready or (CurPageID = wpFinished);
  ShortcutCheck.Enabled := Ready;
  ActionButton.Enabled := Ready or (CurPageID = wpFinished) or (Preparing and WizardForm.NextButton.Enabled);
  DismissButton.Enabled := CurPageID <> wpInstalling;
  TitleClose.Enabled := DismissButton.Enabled;
  if Ready then begin
    FolderEdit.Text := WizardForm.DirEdit.Text;
    PhaseLabel.Caption := 'READY TO INSTALL';
    WizardForm.ActiveControl := ActionButton;
  end;
  if CurPageID = wpInstalling then begin
    Headline.Caption := 'Getting Auralis' + #13#10 + 'ready for you.';
    PhaseLabel.Caption := 'INSTALLING AURALIS';
    DetailLabel.Caption := 'Copying the app and creating your shortcuts…';
  end;
  if Finished then begin
    // Normally skipped. Inno can still require this page for restart choices;
    // expose those native controls instead of concealing the OS decision.
    InstallationFinished := True;
    Headline.Caption := 'Finishing' + #13#10 + 'installation.';
    DetailLabel.Caption := 'Review Windows restart information before finishing.';
    ProgressFill.Width := ProgressTrack.Width;
    ActionButton.Caption := 'Finish';
    DismissButton.Hide;
    PhaseLabel.Caption := 'INSTALLATION COMPLETE';
    WizardForm.WizardBitmapImage2.Hide;
    WizardForm.FinishedHeadingLabel.Hide;
    WizardForm.FinishedLabel.SetBounds(0, 0, ScaleX(621), ScaleY(100));
    WizardForm.YesRadio.SetBounds(0, ScaleY(110), ScaleX(621), ScaleY(28));
    WizardForm.NoRadio.SetBounds(0, ScaleY(142), ScaleX(621), ScaleY(28));
  end;
  // Keep Inno's prerequisite/error and close-app choices visible when needed.
  // These OS decisions must never be hidden behind the custom shell.
  WizardForm.OuterNotebook.Visible := Preparing or Finished;
  if Preparing or Finished then begin
    WizardForm.OuterNotebook.SetBounds(ScaleX(292), ScaleY(288), ScaleX(621), ScaleY(244));
    WizardForm.InnerNotebook.SetBounds(0, 0, ScaleX(621), ScaleY(244));
    WizardForm.OuterNotebook.BringToFront;
  end;
  if Preparing then begin
    Headline.Caption := 'Preparing Auralis' + #13#10 + 'for installation.';
    PhaseLabel.Caption := 'CHECKING INSTALLATION';
    DetailLabel.Caption := 'Review the installation details above to continue.';
    ActionButton.Caption := 'Continue';
  end else if Ready then ActionButton.Caption := 'Install Auralis';
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if WizardSilent or (MaxProgress = 0) then Exit;
  ProgressFill.Width := Round((CurProgress / MaxProgress) * ProgressTrack.Width);
  PhaseLabel.Caption := 'INSTALLING AURALIS · ' + IntToStr(Round((CurProgress / MaxProgress) * 100)) + '%';
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  // Let the installer finish its transaction; close/cancel are disabled meanwhile.
  Cancel := CurPageID <> wpInstalling;
  if InstallationFinished then Confirm := False;
end;
