# Full clean reinstall of the VDD: remove device, DELETE the (corrupt) driver
# package from the store, then add fresh files + recreate the device node.
# Run elevated.
param([string]$AppDir = 'C:\Users\naman\Desktop\dual_display\installers\windows\payload')
Start-Transcript -Path "$env:TEMP\vdd-clean.log" -Force
$ErrorActionPreference = 'Continue'
$vdd = Join-Path $AppDir 'VDD'
$devcon = Join-Path $vdd 'devcon.exe'
$inf = Join-Path $vdd 'MttVDD.inf'

Write-Host '--- remove device node ---'
& $devcon remove 'Root\MttVDD' 2>&1 | Out-Host
Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -like '*MTT1337*' -or $_.InstanceId -like '*MttVDD*' -or $_.InstanceId -eq 'ROOT\DISPLAY\0000' } |
    ForEach-Object { pnputil /remove-device $_.InstanceId 2>&1 | Out-Host }
Start-Sleep 2

Write-Host '--- delete every MikeTheTech/MttVDD driver package from the store ---'
$d = (pnputil /enum-drivers) -join "`n"
$infs = [regex]::Matches($d, '(?ms)Published Name:\s*(oem\d+\.inf).*?(Original Name:\s*MttVDD\.inf|Provider Name:\s*MikeTheTech)') |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
foreach ($o in $infs) {
    Write-Host "delete-driver $o"
    & pnputil.exe /delete-driver $o /uninstall /force 2>&1 | Out-Host
}
Start-Sleep 2

Write-Host '--- fresh add-driver from payload ---'
& pnputil.exe /add-driver "$inf" /install 2>&1 | Out-Host
Write-Host "add-driver exit: $LASTEXITCODE"

Write-Host '--- create device node ---'
& $devcon install "$inf" 'Root\MttVDD' 2>&1 | Out-Host
Write-Host "devcon exit: $LASTEXITCODE"
Start-Sleep 4

Write-Host '--- kick (disable/enable) to spawn the monitor ---'
Disable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false -EA SilentlyContinue
Start-Sleep 3
Enable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false -EA SilentlyContinue
Start-Sleep 5

Write-Host '--- result: monitors ---'
Get-PnpDevice -Class Monitor -EA SilentlyContinue | Select-Object Status, FriendlyName | Format-Table -AutoSize | Out-Host
Stop-Transcript
