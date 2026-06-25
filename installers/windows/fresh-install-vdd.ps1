# Fresh VDD install WITH cert trust (the step that makes the UMDF driver bind).
param([string]$AppDir = 'C:\Users\naman\Desktop\dual_display\installers\windows\payload')
Start-Transcript -Path "$env:TEMP\vdd-fresh.log" -Force
$ErrorActionPreference = 'Continue'
$vdd = Join-Path $AppDir 'VDD'
$devcon = Join-Path $vdd 'devcon.exe'
$inf = Join-Path $vdd 'MttVDD.inf'
$dll = Join-Path $vdd 'MttVDD.dll'

Write-Host '--- remove any half-created node ---'
& $devcon remove 'Root\MttVDD' 2>&1 | Out-Host
Start-Sleep 2

Write-Host '--- TRUST the signing cert (TrustedPublisher + Root) ---'
$cert = (Get-AuthenticodeSignature $dll).SignerCertificate
if ($cert) {
    Write-Host "cert: $($cert.Subject)  thumb=$($cert.Thumbprint)"
    foreach ($s in 'TrustedPublisher','Root') {
        $store = Get-Item "Cert:\LocalMachine\$s"; $store.Open('ReadWrite')
        if (-not ($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint)) { $store.Add($cert) }
        $store.Close()
    }
    Write-Host 'cert trusted'
} else { Write-Host 'WARNING: no cert on MttVDD.dll' }

Write-Host '--- config ---'
New-Item -ItemType Directory -Force 'C:\VirtualDisplayDriver' | Out-Null
Copy-Item (Join-Path $vdd 'vdd_settings.xml') 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force

Write-Host '--- add-driver + devcon install ---'
& pnputil.exe /add-driver "$inf" /install 2>&1 | Out-Host
& $devcon install "$inf" 'Root\MttVDD' 2>&1 | Out-Host
Write-Host "devcon exit: $LASTEXITCODE"
Start-Sleep 4

Write-Host '--- kick to spawn monitor ---'
Disable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false -EA SilentlyContinue
Start-Sleep 3
Enable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false -EA SilentlyContinue
Start-Sleep 5

Write-Host '--- result ---'
Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -EA SilentlyContinue | Select-Object Status, Problem, ProblemDescription | Format-List | Out-Host
Get-PnpDevice -Class Monitor -EA SilentlyContinue | Select-Object Status, FriendlyName | Format-Table -AutoSize | Out-Host
Stop-Transcript
