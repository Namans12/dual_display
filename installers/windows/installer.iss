; Inno Setup 6 script for DualSlate (Extended Display).
; Prereq: run build-payload.ps1 first to populate payload\.

[Setup]
AppName=DualSlate
; Same AppId as the releases named "Extended Display", so this upgrades them in place.
AppId=Extended Display
AppVersion=0.11.0
AppPublisher=HeySnap
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

[Icons]
; Shortcuts point at the settings GUI (the recommended entry point). It manages
; the virtual display, HDR, and starts/stops streaming.
Name: "{autoprograms}\DualSlate"; Filename: "{app}\DualSlate.exe"
Name: "{autodesktop}\DualSlate"; Filename: "{app}\DualSlate.exe"; Tasks: desktopicon

[Run]
; Install the VirtualDrivers VDD. The app loads it while open and switches only its
; screen on while streaming, so there's no extra active display while idle.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install-vdd.ps1"" -AppDir ""{app}"""; StatusMsg: "Installing the virtual display driver..."; Flags: runhidden waituntilterminated; Tasks: installvdd
Filename: "{app}\DualSlate.exe"; Description: "Launch DualSlate now"; Flags: nowait postinstall skipifsilent

[InstallDelete]
; The launcher was ExtendedDisplay.exe before 0.11.1.
Type: files; Name: "{app}\ExtendedDisplay.exe"
; Shortcuts left by releases named "Extended Display".
Type: files; Name: "{autoprograms}\Extended Display.lnk"
Type: files; Name: "{autodesktop}\Extended Display.lnk"

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall-vdd.ps1"" -AppDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveVdd"
