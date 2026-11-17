param([string]$Version)
$ErrorActionPreference='Stop'
$zip=Join-Path $env:RUNNER_TEMP 'old-portable.zip'
Invoke-WebRequest 'https://github.com/motionsamm-lgtm/dropbox-downloader/releases/download/gob-v1.0.1-rc1/GOB-Windows-Portable.zip' -OutFile $zip -UseBasicParsing
if((Get-FileHash $zip).Hash.ToLowerInvariant() -ne '212cb83f18faeb1f1b0da706af50e2e96628e716b34aec832335cda1d3c05190') { throw 'Old client hash mismatch.' }
$old=Join-Path $env:RUNNER_TEMP 'Old GOB Client'
Expand-Archive $zip $old
$app=Join-Path $old 'GOB.exe'
$state=Join-Path $env:LOCALAPPDATA 'GOB\update-state.json'
$history=Join-Path $env:LOCALAPPDATA 'DropboxDownloader\History'
New-Item -ItemType Directory -Force $history | Out-Null
$sentinel=Join-Path $history 'ci-live-update-history.txt'
'Existing history' | Set-Content $sentinel
$before=(Get-FileHash $sentinel).Hash
# Keep a stand-in GUI process alive while the original updater starts waiting for it.
$dummy=Start-Process cmd.exe -ArgumentList '/c ping -n 60 127.0.0.1 >nul' -PassThru
$check=Start-Process $app -ArgumentList ('--update Check {0}' -f $dummy.Id) -PassThru
if(-not $check.WaitForExit(60000) -or $check.ExitCode) { throw 'Old native client could not check the production feed.' }
$result=Get-Content $state -Raw | ConvertFrom-Json
if($result.status -ne 'Available' -or $result.version -ne $Version) { throw 'Old client did not discover the published update.' }
$install=Start-Process $app -ArgumentList ('--update Install {0}' -f $dummy.Id) -PassThru
if(-not $install.WaitForExit(180000) -or $install.ExitCode) { throw 'Old native client could not launch the verified update.' }
$installed=Join-Path $env:LOCALAPPDATA 'Programs\GOB\GOB.exe'
$until=(Get-Date).AddSeconds(120)
$actual=''
do {
    try { $actual=[Reflection.AssemblyName]::GetAssemblyName($installed).Version.ToString() } catch { $actual='' }
    if($actual -eq ($Version+'.0')) { break }
    Start-Sleep -Milliseconds 500
} while((Get-Date) -lt $until)
if($actual -ne ($Version+'.0')) { throw 'Live updater did not install the published version.' }
if((Get-FileHash $sentinel).Hash -ne $before) { throw 'Live update changed history.' }
Write-Host ('PASS: actual native 1.0.1 client discovered, downloaded, verified and installed GOB '+$Version+' from the public production feed.')
