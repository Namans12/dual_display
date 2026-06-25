# Assembles installers/windows/payload/ with everything ExtendedDisplaySetup bundles:
#   ExtendedDisplaySender.exe, ExtendedDisplayReceiver.apk, ffmpeg.exe,
#   platform-tools (adb), VDD\ (VirtualDrivers IddCx display driver + devcon + config).
# FFmpeg (GPL build) and the VDD are downloaded at packaging time so the repo
# never redistributes them.

[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..\.."),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'payload'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) 'extdisplay-payload'
New-Item -ItemType Directory -Force $payload | Out-Null
New-Item -ItemType Directory -Force $temp | Out-Null

function Get-WithRetry {
    param([string]$Url, [string]$OutFile)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "Downloading $Url (attempt $attempt)"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -MaximumRedirection 5
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

# 1. Sender exe
$exe = Join-Path $RepoRoot 'windows-sender\build\Release\ExtendedDisplaySender.exe'
if (-not (Test-Path $exe)) {
    throw "Sender not built. Run: cmake --build windows-sender/build --config Release"
}
Copy-Item $exe $payload -Force
Write-Host "OK ExtendedDisplaySender.exe"

# 2. Receiver APK (prefer release)
$apkRelease = Join-Path $RepoRoot 'android-receiver\app\build\outputs\apk\release\app-release.apk'
$apkDebug = Join-Path $RepoRoot 'android-receiver\app\build\outputs\apk\debug\app-debug.apk'
$apk = if (Test-Path $apkRelease) { $apkRelease } elseif (Test-Path $apkDebug) { $apkDebug } else {
    throw "No APK found. Run: ./gradlew :app:assembleRelease in android-receiver/"
}
Copy-Item $apk (Join-Path $payload 'ExtendedDisplayReceiver.apk') -Force
Write-Host "OK ExtendedDisplayReceiver.apk ($([System.IO.Path]::GetFileName($apk)))"

# 3. FFmpeg (full GPL build: includes ddagrab + nvenc/qsv/amf/x264)
if ($Force -or -not (Test-Path (Join-Path $payload 'ffmpeg.exe'))) {
    $zip = Join-Path $temp 'ffmpeg.zip'
    Get-WithRetry 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' $zip
    $dest = Join-Path $temp 'ffmpeg'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive $zip $dest
    $ffmpegExe = Get-ChildItem -Path $dest -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
    if (-not $ffmpegExe) { throw "ffmpeg.exe not found inside the downloaded archive" }
    Copy-Item $ffmpegExe.FullName (Join-Path $payload 'ffmpeg.exe') -Force
}
Write-Host "OK ffmpeg.exe"

# 4. Android platform-tools (adb)
$pt = Join-Path $payload 'platform-tools'
if ($Force -or -not (Test-Path (Join-Path $pt 'adb.exe'))) {
    $zip = Join-Path $temp 'platform-tools.zip'
    Get-WithRetry 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' $zip
    $dest = Join-Path $temp 'platform-tools'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive $zip $dest
    New-Item -ItemType Directory -Force $pt | Out-Null
    foreach ($file in 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll') {
        $src = Get-ChildItem -Path $dest -Recurse -Filter $file | Select-Object -First 1
        if (-not $src) { throw "$file not found inside platform-tools archive" }
        Copy-Item $src.FullName $pt -Force
    }
}
Write-Host "OK platform-tools"

# 5. VirtualDrivers VDD (IddCx 1.10 indirect display driver, SignPath-signed,
#    free). We bundle just the signed driver files + devcon + our config.
$vdd = Join-Path $payload 'VDD'
if ($Force -or -not (Test-Path (Join-Path $vdd 'MttVDD.inf'))) {
    # Resolve the latest release's VDD.Control zip from the GitHub API.
    # Set $env:GITHUB_TOKEN to lift the 60-req/hour unauthenticated rate limit.
    $ghHeaders = @{ 'User-Agent' = 'extdisplay-build' }
    if ($env:GITHUB_TOKEN) { $ghHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/VirtualDrivers/Virtual-Display-Driver/releases/latest' -Headers $ghHeaders
    $asset = $rel.assets | Where-Object { $_.name -like 'VDD.Control*.zip' } | Select-Object -First 1
    if (-not $asset) { throw "VDD.Control zip not found in the latest release" }
    $zip = Join-Path $temp 'vdd.zip'
    Get-WithRetry $asset.browser_download_url $zip
    $dest = Join-Path $temp 'vdd'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive $zip $dest
    $driverDir = Get-ChildItem -Path $dest -Recurse -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'MttVDD.inf') } | Select-Object -First 1
    if (-not $driverDir) { throw "MttVDD.inf not found inside the VDD archive" }
    $devcon = Get-ChildItem -Path $dest -Recurse -Filter 'devcon.exe' | Select-Object -First 1
    if (-not $devcon) { throw "devcon.exe not found inside the VDD archive" }
    New-Item -ItemType Directory -Force $vdd | Out-Null
    Copy-Item (Join-Path $driverDir.FullName '*') $vdd -Force   # MttVDD.inf/.dll/.cat
    Copy-Item $devcon.FullName $vdd -Force
}
# Always ship OUR configured settings (2960x1848@120 + HDR), overriding the default.
Copy-Item (Join-Path $PSScriptRoot 'vdd_settings.xml') (Join-Path $vdd 'vdd_settings.xml') -Force
Write-Host "OK VDD (VirtualDrivers IddCx driver + devcon + config)"

Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
Write-Host "`nPayload ready: $payload"
Write-Host "Next: compile the installer with ISCC.exe installer.iss"
