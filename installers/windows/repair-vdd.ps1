# One-shot VDD repair with logging: remove ghost devices, reinstall the driver
# + device node fresh, restore config. Run elevated.
param([string]$AppDir = 'C:\Users\naman\Desktop\dual_display\installers\windows\payload')
Start-Transcript -Path "$env:TEMP\vdd-repair.log" -Force
$ErrorActionPreference = 'Continue'
$vdd = Join-Path $AppDir 'VDD'
$devcon = Join-Path $vdd 'devcon.exe'

# 1. Remove any ghost/orphaned VDD devices (adapter + monitor).
Write-Host '--- removing existing MttVDD/monitor instances ---'
& $devcon remove 'Root\MttVDD' 2>&1 | Out-Host
Get-PnpDevice -EA SilentlyContinue |
    Where-Object { $_.InstanceId -like '*MTT1337*' -or $_.InstanceId -like '*MttVDD*' } |
    ForEach-Object {
        Write-Host "pnputil remove $($_.InstanceId)"
        pnputil /remove-device $_.InstanceId 2>&1 | Out-Host
    }
Start-Sleep 2

# 2. Restore config.
$cfgDir = 'C:\VirtualDisplayDriver'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
Copy-Item (Join-Path $vdd 'vdd_settings.xml') (Join-Path $cfgDir 'vdd_settings.xml') -Force
Write-Host 'config restored'

# 3. Add driver to store + create a fresh device node.
Write-Host '--- pnputil /add-driver ---'
& pnputil.exe /add-driver (Join-Path $vdd 'MttVDD.inf') /install 2>&1 | Out-Host
Write-Host "pnputil exit: $LASTEXITCODE"
Write-Host '--- devcon install ---'
& $devcon install (Join-Path $vdd 'MttVDD.inf') 'Root\MttVDD' 2>&1 | Out-Host
Write-Host "devcon exit: $LASTEXITCODE"
Start-Sleep 3

Write-Host '--- result ---'
Get-PnpDevice -Class Display -EA SilentlyContinue | Where-Object FriendlyName -like '*Virtual Display*' |
    Select-Object FriendlyName, Status | Format-List
Stop-Transcript
