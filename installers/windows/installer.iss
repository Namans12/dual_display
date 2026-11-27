; Inno Setup 6 script for DualSlate (Extended Display).
; Prereq: run build-payload.ps1 first to populate payload\.

[Setup]
AppName=DualSlate
; Same AppId as the releases named "Extended Display", so this upgrades them in place.
AppId=Extended Display
AppVersion=0.11.0
AppPublisher=Namans12
AppPublisherURL=https://github.com/Namans12/dual_display
; New installs go to DualSlate; upgrades keep their existing folder (UsePreviousAppDir).
DefaultDirName={autopf}\DualSlate
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=DualSlateSetup
OutputDir=dist
Compression=lzma2
SolidCompression=yes
DisableProgramGroupPage=yes
SetupIconFile=..\..\windows-sender\launcher\app.ico
UninstallDisplayIcon={app}\DualSlate.exe

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"
Name: "installvdd"; Description: "Install the &virtual display driver (gives one clean 2960x1848 120Hz HDR display; recommended)"

[Files]
Source: "payload\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "install-vdd.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall-vdd.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Shortcuts point at the settings GUI (the recommended entry point). It manages
; the virtual display, HDR, and starts/stops streaming.
Name: "{autoprograms}\DualSlate"; Filename: "{app}\DualSlate.exe"
Name: "{autodesktop}\DualSlate"; Filename: "{app}\DualSlate.exe"; Tasks: desktopicon

[Run]
; The virtual display driver is installed from [Code] (CurStepChanged), so that it has
; finished before Setup decides whether a restart is needed.
Filename: "{app}\DualSlate.exe"; Description: "Launch DualSlate now"; Flags: nowait postinstall skipifsilent

[InstallDelete]
; The launcher was ExtendedDisplay.exe before 0.11.1.
Type: files; Name: "{app}\ExtendedDisplay.exe"
; Shortcuts left by releases named "Extended Display".
Type: files; Name: "{autoprograms}\Extended Display.lnk"
Type: files; Name: "{autodesktop}\Extended Display.lnk"
Type: files; Name: "{userdesktop}\Extended Display.lnk"

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall-vdd.ps1"" -AppDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveVdd"

[Code]
// Install the VirtualDrivers VDD (installvdd task). The app loads the driver while it is
// open and switches only its screen on while streaming, so there's no extra active
// display while idle.
var
  DriverStepDone: Boolean;

// Runs install-vdd.ps1 once. Measured: Setup asks NeedRestart BEFORE ssPostInstall, so
// the driver step runs from whichever comes first, and NeedRestart then sees its result.
procedure InstallDriverOnce();
var
  rc: Integer;
begin
  if DriverStepDone or not WizardIsTaskSelected('installvdd') then exit;
  DriverStepDone := True;
  WizardForm.StatusLabel.Caption := 'Installing the virtual display driver...';
  DeleteFile(ExpandConstant('{app}\driver-pending.flag'));  // only this run's result counts
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\install-vdd.ps1') +
    '" -AppDir "' + ExpandConstant('{app}') + '"', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Log('install-vdd.ps1 exit code: ' + IntToStr(rc));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then InstallDriverOnce();
end;

// install-vdd.ps1 leaves this flag when Windows must restart before the display
// driver can attach (it then finishes by itself at the next start). Inno Setup asks
// the user to restart; a silent install with /NORESTART never restarts.
function NeedRestart(): Boolean;
begin
  InstallDriverOnce();
  Result := FileExists(ExpandConstant('{app}\driver-pending.flag'));
  if Result then Log('Virtual display driver: restart needed to finish.');
end;
