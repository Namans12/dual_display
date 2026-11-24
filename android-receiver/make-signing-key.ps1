# Creates the shared DualSlate release key (run ONCE, on one machine), see docs/signing.md.
# Writes, outside the repo:
#   %USERPROFILE%\.dualslate\dualslate-release.jks   the key (back it up!)
#   %USERPROFILE%\.dualslate\signing.properties      where it is + its password
# The password is asked for here and never passed on the command line.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE '.dualslate'
$jks = Join-Path $dir 'dualslate-release.jks'
$props = Join-Path $dir 'signing.properties'
if (Test-Path $jks) { throw "A key already exists at $jks - not overwriting it. Delete it yourself only if you are sure." }

$keytool = @("$env:JAVA_HOME\bin\keytool.exe", 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe') |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $keytool) { throw 'keytool not found: set JAVA_HOME to a JDK (Android Studio: C:\Program Files\Android\Android Studio\jbr).' }

function Read-Plain([string]$prompt) {
    $s = Read-Host $prompt -AsSecureString
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
$p1 = Read-Plain 'Choose a password for the DualSlate signing key (at least 8 characters)'
$p2 = Read-Plain 'Type it again'
if ($p1 -ne $p2) { throw 'The two passwords differ - nothing was created.' }
if ($p1.Length -lt 8) { throw 'Use at least 8 characters - nothing was created.' }

New-Item -ItemType Directory -Force $dir | Out-Null
# keytool reads the passwords from environment variables (:env), not from the command line.
$env:DS_STOREPASS = $p1
try {
    & $keytool -genkeypair -keystore $jks -storetype PKCS12 -alias dualslate -keyalg RSA -keysize 4096 `
        -validity 10000 -dname 'CN=DualSlate' -storepass:env DS_STOREPASS -keypass:env DS_STOREPASS
    if ($LASTEXITCODE -ne 0) { throw "keytool failed ($LASTEXITCODE)" }
    $esc = $p1.Replace('\', '\\')
    Set-Content -Path $props -Encoding ASCII -Value @(
        '# DualSlate release signing - keep this folder private and backed up.',
        'storeFile=dualslate-release.jks',
        'keyAlias=dualslate',
        "storePassword=$esc"
    )
    # Only the current user may read the folder.
    icacls $dir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
    Write-Host "`nCreated $jks and $props"
    & $keytool -list -v -keystore $jks -storepass:env DS_STOREPASS | Select-String 'SHA256:'
    Write-Host "`nNext: back up the whole $dir folder (password manager / USB stick). Copy it to ~/.dualslate on the Mac."
} finally {
    Remove-Item Env:DS_STOREPASS -ErrorAction SilentlyContinue
    $p1 = $p2 = $null
}
