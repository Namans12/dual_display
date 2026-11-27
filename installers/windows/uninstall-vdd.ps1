# Removes the VirtualDrivers VDD device + config. Invoked elevated by the
# installer's [UninstallRun] section.
param([string]$AppDir = $PSScriptRoot)
$ErrorActionPreference = 'Continue'
$vdd = Join-Path $AppDir 'VDD'

# Stop the app if it is running, then switch ONLY the virtual screen off. (This used
# to apply TOPOLOGY_INTERNAL, which also turned off every real external monitor.)
Get-Process DualSlate, ExtendedDisplay, ExtendedDisplaySender -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
$sender = Join-Path $AppDir 'ExtendedDisplaySender.exe'
if (Test-Path $sender) { & $sender --cleanup | Out-Null }

# A driver install still waiting for a restart (install-vdd.ps1) must not run later.
Unregister-ScheduledTask -TaskName 'DualSlate driver setup' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path $AppDir 'driver-pending.flag'), (Join-Path $AppDir 'driver-failed.flag'),
    (Join-Path $AppDir 'install-vdd.log') -ErrorAction SilentlyContinue

$devcon = Join-Path $vdd 'devcon.exe'
if (Test-Path $devcon) {
    & $devcon remove 'Root\MttVDD'
}

# Also remove the driver package from the Windows driver store so reinstalls
# don't accumulate orphaned oemNN.inf entries. Best-effort.
try {
    $pkg = (pnputil /enum-drivers) -join "`n"
    # Find the published oemNN.inf whose original name is MttVDD.inf.
    # Case-insensitive: pnputil lists it as "mttvdd.inf" (the old case-sensitive match
    # never deleted anything, so packages piled up). Stops at the next "Published Name"
    # so one package's name can't pair with another's.
    $matches = [regex]::Matches($pkg, '(?ims)Published Name:\s*(oem\d+\.inf)(?:(?!Published Name).)*?Original Name:\s*mttvdd\.inf')
    foreach ($m in $matches) {
        & pnputil.exe /delete-driver $m.Groups[1].Value /uninstall /force | Out-Null
    }
} catch {
}

Remove-Item 'C:\VirtualDisplayDriver' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'VDD removed.'
