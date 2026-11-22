# Builds a NON-elevated test copy (asInvoker manifest) for UI verification.
# Run it with --no-driver so it never touches the driver or the sender.
$ErrorActionPreference = 'Stop'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$dir = $PSScriptRoot
$out = Join-Path $dir '..\..\.verification\launcher-test.exe'
& $csc /nologo /target:winexe /out:"$out" /win32manifest:"$dir\app.test.manifest" `
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "$dir\Launcher.cs"
Write-Host "Built test copy: $out"
