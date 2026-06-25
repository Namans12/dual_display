# Repairs the Windows component/driver store: DISM RestoreHealth then SFC.
# Writes progress to a log we can poll. Run elevated.
$log = 'C:\ProgramData\ExtendedDisplay-repair.log'
New-Item -ItemType Directory -Force 'C:\ProgramData' | Out-Null
"START $(Get-Date -Format o)" | Set-Content $log
"=== DISM /RestoreHealth ===" | Add-Content $log
& DISM.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Add-Content $log
"DISM exit: $LASTEXITCODE" | Add-Content $log
"=== SFC /scannow ===" | Add-Content $log
& sfc.exe /scannow 2>&1 | Add-Content $log
"SFC exit: $LASTEXITCODE" | Add-Content $log
"REPAIR DONE $(Get-Date -Format o)" | Add-Content $log
