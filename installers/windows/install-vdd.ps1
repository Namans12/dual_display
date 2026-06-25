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

# Add to the driver store (native exe: check the exit code, since $ErrorAction
# does not catch native failures).
& pnputil.exe /add-driver "$inf" /install
if ($LASTEXITCODE -ne 0) { throw "pnputil /add-driver failed (exit $LASTEXITCODE)" }

# Create the root-enumerated device node — only if absent, so reinstalls never
# stack duplicate displays.
$existing = Get-PnpDevice -FriendlyName '*Virtual Display Driver*' -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host 'VDD device already present; refreshed driver + config only.'
} else {
    & $devcon install "$inf" 'Root\MttVDD'
    if ($LASTEXITCODE -ne 0) { throw "devcon install failed (exit $LASTEXITCODE)" }
}
# The monitor is created inactive; the sender extends onto it on demand. No
# phantom display while idle.
Write-Host 'VDD installed.'
