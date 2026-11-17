param([string]$NewSetup, [string]$Version)
$ErrorActionPreference='Stop'
$old=Join-Path $env:RUNNER_TEMP 'old-GOB-Setup.exe'
Invoke-WebRequest 'https://github.com/motionsamm-lgtm/dropbox-downloader/releases/download/gob-v1.0.1-rc1/GOB-Setup.exe' -OutFile $old -UseBasicParsing
if ((Get-FileHash $old).Hash.ToLowerInvariant() -ne 'c967aa8adc00bafbbd509cc77d43377b4208f96d518500b3ca7ac499e2b0cf47') { throw 'Old installer digest mismatch.' }
$installed=Join-Path $env:RUNNER_TEMP 'GOB Upgrade Test'
function Close-TestApp {
    $until=(Get-Date).AddSeconds(45)
    do {
        $running=@(Get-Process GOB -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $installed 'GOB.exe') })
        foreach($p in $running) { $p.Refresh(); if($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } }
        if(-not $running.Count) { return }
        Start-Sleep -Milliseconds 250
    } while((Get-Date) -lt $until)
    throw 'Installed GUI or helper did not close.'
}
function Install-TestBuild([string]$Setup) {
    $p=Start-Process $Setup -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{0}" /LOG="{1}"' -f $installed,($Setup+'.install.log')) -PassThru
    if(-not $p.WaitForExit(60000) -or $p.ExitCode) { throw 'Installer did not finish successfully.' }
    Close-TestApp
}
$history=Join-Path $env:LOCALAPPDATA 'DropboxDownloader\History'
New-Item -ItemType Directory -Force $history | Out-Null
$sentinel=Join-Path $history 'ci-upgrade-history.txt'
'Existing download history and saved progress must survive updates.' | Set-Content $sentinel
$before=(Get-FileHash $sentinel).Hash
Install-TestBuild $old
$app=Join-Path $installed 'GOB.exe'
if([Reflection.AssemblyName]::GetAssemblyName($app).Version.ToString() -ne '1.0.1.0') { throw 'Old installation was not version 1.0.1.' }
Install-TestBuild $NewSetup
if([Reflection.AssemblyName]::GetAssemblyName($app).Version.ToString() -ne ($Version+'.0')) { throw 'Upgrade did not install requested version.' }
$link=(New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'GOB.lnk'))
if($link.TargetPath -ne $app -or $link.IconLocation -notlike "$app,*") { throw 'Upgrade broke Start menu identity.' }
foreach($mode in @('--self-test','--smoke-test','--smoke-test')) {
    $p=Start-Process $app -ArgumentList $mode -PassThru
    if(-not $p.WaitForExit(30000) -or $p.ExitCode) { throw ('Upgraded app failed '+$mode) }
}
if((Get-FileHash $sentinel).Hash -ne $before) { throw 'Upgrade changed history.' }
$p=Start-Process (Join-Path $installed 'unins000.exe') -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -PassThru
if(-not $p.WaitForExit(60000) -or $p.ExitCode) { throw 'Uninstall failed.' }
if((Get-FileHash $sentinel).Hash -ne $before) { throw 'Uninstall changed history.' }
Write-Host 'PASS: 1.0.1 to new installer upgrade, app version, native shortcut/icon, repeated launches and history-preserving uninstall.'
