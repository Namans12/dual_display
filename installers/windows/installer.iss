; Inno Setup 6 script for Extended Display.
; Prereq: run build-payload.ps1 first to populate payload\.

[Setup]
AppName=Extended Display
AppVersion=0.7.2
AppPublisher=HeySnap
DefaultDirName={autopf}\Extended Display
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=ExtendedDisplaySetup
OutputDir=dist
Compression=lzma2
SolidCompression=yes
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\ExtendedDisplaySender.exe

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
Name: "{autoprograms}\Extended Display"; Filename: "{app}\ExtendedDisplay.exe"
Name: "{autodesktop}\Extended Display"; Filename: "{app}\ExtendedDisplay.exe"; Tasks: desktopicon

[Run]
; Install the VirtualDrivers VDD. The monitor stays INACTIVE until the sender
; extends onto it on demand (CCD topology), so there's no phantom display while
; idle and no elevation needed at run time.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install-vdd.ps1"" -AppDir ""{app}"""; StatusMsg: "Installing the virtual display driver..."; Flags: runhidden waituntilterminated; Tasks: installvdd
Filename: "{app}\ExtendedDisplay.exe"; Description: "Launch Extended Display now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall-vdd.ps1"" -AppDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveVdd"
