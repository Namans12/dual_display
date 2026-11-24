# Installs the bundled VirtualDrivers VDD and applies our 2960x1848@120 + HDR
# settings. Invoked elevated by the installer's [Run] section (installvdd task).
param([string]$AppDir = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$vdd = Join-Path $AppDir 'VDD'
$inf = Join-Path $vdd 'MttVDD.inf'
$dll = Join-Path $vdd 'MttVDD.dll'
$devcon = Join-Path $vdd 'devcon.exe'
if (-not (Test-Path $inf)) { throw "VDD driver files missing in $vdd" }

# Trust the SignPath signing cert so the install is non-interactive. The driver
# is signed; a missing cert means a broken/tampered payload, so fail loudly.
$cert = (Get-AuthenticodeSignature $dll).SignerCertificate
if (-not $cert) { throw "MttVDD.dll is not signed; refusing to install a broken payload." }
foreach ($storeName in 'TrustedPublisher', 'Root') {
    $store = Get-Item "Cert:\LocalMachine\$storeName"
    $store.Open('ReadWrite')
    # Don't add a duplicate on every reinstall.
    if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
        $store.Add($cert)
    }
    $store.Close()
}

# The driver reads its config from C:\VirtualDisplayDriver\vdd_settings.xml.
$cfgDir = 'C:\VirtualDisplayDriver'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
Copy-Item (Join-Path $vdd 'vdd_settings.xml') (Join-Path $cfgDir 'vdd_settings.xml') -Force

$taskName = 'DualSlate driver setup'
$pendingFlag = Join-Path $AppDir 'driver-pending.flag'

# Device nodes are found by hardware ID, never by name: a node whose driver did not
# attach has no friendly name, and the old name-based check then stacked a duplicate.
function Get-VddNodes { @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }) }
function Test-Bound($node) {
    [bool](Get-PnpDeviceProperty -InstanceId $node.InstanceId -KeyName DEVPKEY_Device_DriverInfPath -ErrorAction SilentlyContinue).Data
}
function Remove-UnboundNodes {
    foreach ($n in Get-VddNodes) {
        if (-not (Test-Bound $n)) { & pnputil.exe /remove-device "$($n.InstanceId)" | Out-Null }
    }
}

# Add to the driver store (native exe: check the exit code, since $ErrorAction does not
# catch native failures). 3010 = success, restart recommended.
& pnputil.exe /add-driver "$inf" /install
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw "pnputil /add-driver failed (exit $LASTEXITCODE)" }

Remove-UnboundNodes  # leftovers of an earlier failed attempt
$bound = @(Get-VddNodes | Where-Object { Test-Bound $_ })
if ($bound.Count -gt 0) {
    Write-Host 'VDD device already present; refreshed driver + config only.'
    # Exactly one virtual display: drop extra nodes so reinstalls never stack displays.
    $bound | Select-Object -Skip 1 | ForEach-Object { & pnputil.exe /remove-device "$($_.InstanceId)" | Out-Null }
} else {
    & $devcon install "$inf" 'Root\MttVDD'
    Start-Sleep -Seconds 2
    if (-not (Get-VddNodes | Where-Object { Test-Bound $_ })) {
        # Measured: after the driver was uninstalled, Windows keeps the old package
        # pending deletion and refuses to attach a fresh copy ("no compatible drivers")
        # until it restarts. Finish automatically at the next start (as SYSTEM, which may
        # install drivers) and let the installer ask for a restart.
        Remove-UnboundNodes
        # The ScheduledTasks cmdlets, not schtasks.exe: Windows PowerShell 5.1 mangles the
        # quoted paths in /TR, and the task was silently never created (measured).
        $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AppDir `"$AppDir`""
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
            -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
        Set-Content -Path $pendingFlag -Value 'The virtual display driver finishes installing at the next restart.'
        Write-Host 'VDD: Windows needs a restart to finish installing the driver; scheduled for the next start.'
        return
    }
}

# Installed: clear any pending-restart leftovers.
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $pendingFlag -ErrorAction SilentlyContinue

# Leave the driver unloaded: DualSlate loads it while the app is open and switches only
# its screen on while streaming. Otherwise Windows may show the new monitor as an active
# extra display right after install. Real monitors are not touched.
Start-Sleep -Seconds 2
Get-VddNodes | Where-Object { $_.Status -eq 'OK' } |
    Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
Write-Host 'VDD installed (unloaded until DualSlate is opened).'
