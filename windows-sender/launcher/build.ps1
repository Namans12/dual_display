# Compiles Launcher.cs into ExtendedDisplay.exe with the elevation manifest.
$ErrorActionPreference = 'Stop'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$dir = $PSScriptRoot
$out = Join-Path $dir 'ExtendedDisplay.exe'

& $csc /nologo /target:winexe /out:"$out" `
    /win32manifest:"$dir\app.manifest" `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll `
    "$dir\Launcher.cs"

if (Test-Path $out) {
    Write-Host "Built: $out"
    # Drop a copy next to the sender exe so it runs straight from the dev tree
    # (the launcher resolves the sender in its own folder first).
    $rel = Join-Path $dir '..\build\Release\ExtendedDisplay.exe'
    if (Test-Path (Split-Path $rel)) { Copy-Item $out $rel -Force -EA SilentlyContinue; Write-Host "Copied to build\Release." }
} else {
    Write-Host "BUILD FAILED"
}
