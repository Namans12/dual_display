@echo off
REM One-time setup: installs the virtual display driver (VDD). Needs admin (UAC).
set "HERE=%~dp0"
echo Installing the virtual display driver...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%HERE%install-vdd.ps1','-AppDir','%HERE%'"
echo.
echo If a UAC prompt appeared, approve it. When it finishes, you can close this
echo window and launch ExtendedDisplay.exe.
pause
