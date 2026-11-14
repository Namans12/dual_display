# Removes the VirtualDrivers VDD device + config. Invoked elevated by the
# installer's [UninstallRun] section.
param([string]$AppDir = $PSScriptRoot)
$ErrorActionPreference = 'Continue'
$vdd = Join-Path $AppDir 'VDD'

# Collapse to the primary display first so nothing is left extended onto the VDD.
Add-Type -Namespace Win -Name Cfg -MemberDefinition '[DllImport("user32.dll")] public static extern int SetDisplayConfig(uint a, IntPtr b, uint c, IntPtr d, uint f);'
[Win.Cfg]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x81) | Out-Null  # APPLY|TOPOLOGY_INTERNAL

$devcon = Join-Path $vdd 'devcon.exe'
if (Test-Path $devcon) {
    & $devcon remove 'Root\MttVDD'
}

# Also remove the driver package from the Windows driver store so reinstalls
# don't accumulate orphaned oemNN.inf entries. Best-effort.
try {
    $pkg = (pnputil /enum-drivers) -join "`n"
    # Find the published oemNN.inf whose original name is MttVDD.inf.
    $matches = [regex]::Matches($pkg, '(?ms)Published Name:\s*(oem\d+\.inf).*?Original Name:\s*MttVDD\.inf')
    foreach ($m in $matches) {
        & pnputil.exe /delete-driver $m.Groups[1].Value /uninstall /force | Out-Null
    }
} catch {
}

Remove-Item 'C:\VirtualDisplayDriver' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'VDD removed.'
