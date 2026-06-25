# COMPLETE removal of the VDD so a post-reboot install is genuinely fresh.
# Removes: device nodes, every MttVDD/MikeTheTech driver-store package, the
# config dir, and VDD registry keys. Run elevated. REBOOT after this.
param([string]$AppDir = 'C:\Users\naman\Desktop\dual_display\installers\windows\payload')
Start-Transcript -Path "$env:TEMP\vdd-nuke.log" -Force
$ErrorActionPreference = 'Continue'
$devcon = Join-Path $AppDir 'VDD\devcon.exe'

Write-Host '--- remove device nodes ---'
if (Test-Path $devcon) { & $devcon remove 'Root\MttVDD' 2>&1 | Out-Host }
Get-PnpDevice -EA SilentlyContinue |
    Where-Object { $_.InstanceId -like '*MTT1337*' -or $_.InstanceId -like '*MttVDD*' -or
                   $_.InstanceId -eq 'ROOT\DISPLAY\0000' -or $_.InstanceId -eq 'ROOT\DISPLAY\0001' -or
                   ($_.Class -eq 'Display' -and $_.InstanceId -like 'ROOT\*') } |
    ForEach-Object { Write-Host "remove $($_.InstanceId)"; pnputil /remove-device $_.InstanceId 2>&1 | Out-Host }

Write-Host '--- delete every MttVDD/MikeTheTech driver package ---'
$d = (pnputil /enum-drivers) -join "`n"
$infs = [regex]::Matches($d, '(?ms)Published Name:\s*(oem\d+\.inf).*?(Original Name:\s*MttVDD\.inf|Provider Name:\s*MikeTheTech)') |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
foreach ($o in $infs) { Write-Host "delete-driver $o"; & pnputil.exe /delete-driver $o /uninstall /force 2>&1 | Out-Host }

Write-Host '--- remove config + registry ---'
Remove-Item 'C:\VirtualDisplayDriver' -Recurse -Force -EA SilentlyContinue
foreach ($k in 'HKLM:\SOFTWARE\VirtualDisplayDriver','HKLM:\SOFTWARE\MikeTheTech','HKLM:\SOFTWARE\Zako') {
    if (Test-Path $k) { Write-Host "remove reg $k"; Remove-Item $k -Recurse -Force -EA SilentlyContinue }
}
Write-Host 'NUKE COMPLETE — reboot now.'
Stop-Transcript
