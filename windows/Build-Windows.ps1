$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$archive = Join-Path $env:RUNNER_TEMP 'aria2.zip'
Invoke-WebRequest 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip' -OutFile $archive
Expand-Archive $archive (Join-Path $env:RUNNER_TEMP 'aria2') -Force
$aria = (Get-ChildItem (Join-Path $env:RUNNER_TEMP 'aria2') -Recurse -Filter aria2c.exe | Select-Object -First 1).FullName
$portable = Join-Path $PSScriptRoot 'dist\portable'
New-Item -ItemType Directory -Force $portable | Out-Null
Copy-Item $aria (Join-Path $portable 'aria2c.exe')
Copy-Item ../assets/windows/GOB.ico $portable
Copy-Item ../assets/windows/GOB.png $portable
Copy-Item README.txt $portable
foreach ($script in Get-ChildItem -Filter *.ps1) {
    $parseErrors = $null; $tokens = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
# Assemble readable, fixed application entry points. These are normal embedded
# application resources, not arbitrary external scripts or encoded commands.
function Read-Component([string]$Name) {
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name)).TrimStart([char]0xFEFF)
    $text = [regex]::Replace($text, '(?m)^\. \(Join-Path \$PSScriptRoot ''[^'']+\.ps1''\)\r?\n', '')
    $text = $text.Replace('$PSScriptRoot', '$GOBRoot')
    # Hosted entry points return their exit status to the native application.
    $text = [regex]::Replace($text, '(?m)\bexit ([01])\b', '$global:GobExitCode = $1; return')
    return $text
}
$common = @('Download-Reliability.ps1','Download-Log.ps1','Download-History.ps1','Download-Notifications.ps1','Download-Folder.ps1')
$dependencyText = ($common | ForEach-Object { Read-Component $_ }) -join "`r`n"
$worker = Read-Component 'Dropbox-Downloader.ps1'
$worker = $worker -replace '^param\([^\r\n]*\)\r?\n', ''
$entries = @{
    gui = $dependencyText + "`r`n" + (Read-Component 'Dropbox-Downloader-GUI.ps1')
    worker = 'param([string]$JobFile, [string]$HistoryAttempt)' + "`r`n" + $dependencyText + "`r`n" + $worker
    notify = Read-Component 'Download-Toast.ps1'
    update = Read-Component 'GOB-Update.ps1'
    test = $dependencyText + @'

if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Unexpected scripting engine.' }
if (-not (Get-Command Find-TransferReadout -ErrorAction Stop)) { throw 'Download functions unavailable.' }
$metrics = Find-TransferReadout '[#abcdef 1MiB/2MiB(50%) CN:4 DL:1MiB ETA:1s]'
if ($metrics.Total -ne 2097152 -or $metrics.Completed -ne 1048576 -or $metrics.Connections -ne 4) { throw 'Transfer progress parsing failed.' }
$quoted = Quote-TransferArgument 'C:\a path\pod.mp4'
if ($quoted -notmatch '^".*"$') { throw 'Windows argument quoting failed.' }
if (-not [IO.File]::Exists((Join-Path $GOBRoot 'aria2c.exe'))) { throw 'Download engine missing.' }
& (Join-Path $GOBRoot 'aria2c.exe') --version | Out-Null
if ($LASTEXITCODE) { throw 'Download engine did not start.' }
Get-Process -Id 2147483646 -ErrorAction SilentlyContinue | Out-Null
'@
}
$resources = @()
foreach ($entry in $entries.Keys) {
    $source = Join-Path $env:RUNNER_TEMP ($entry+'.ps1')
    [IO.File]::WriteAllText($source, $entries[$entry], [Text.UTF8Encoding]::new($true))
    $errors = $null; $tokens = $null
    [void][Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $resources += ('/resource:{0},{1}.ps1' -f $source,$entry)
}
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sma = [Management.Automation.PSObject].Assembly.Location
& $csc /nologo /target:winexe /platform:x64 /win32icon:../assets/windows/GOB.ico /out:dist/portable/GOB.exe @resources /reference:System.Windows.Forms.dll /reference:System.Core.dll "/reference:$sma" Launcher.cs
if ($LASTEXITCODE) { throw 'Windows EXE compilation failed.' }
$check = Start-Process .\dist\portable\GOB.exe -ArgumentList '--self-test' -PassThru -Wait
if ($check.ExitCode) { Get-Content "$env:LOCALAPPDATA\GOB\startup.log.txt" -ErrorAction SilentlyContinue; throw 'Native GOB component test failed.' }
$smoke = Start-Process .\dist\portable\GOB.exe -ArgumentList '--smoke-test' -PassThru
$seenWindow = $false
$wrongChild = $false
$until = (Get-Date).AddSeconds(25)
while (-not $smoke.HasExited -and (Get-Date) -lt $until) {
    $smoke.Refresh()
    if ($smoke.MainWindowTitle -like 'GOB*') { $seenWindow = $true }
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($smoke.Id)"
    if ($children.Name -contains 'powershell.exe') { $wrongChild = $true }
    Start-Sleep -Milliseconds 150
}
if (-not $smoke.HasExited) { Stop-Process -Id $smoke.Id; throw 'GOB GUI did not close after smoke test.' }
$smoke.WaitForExit()
if ($smoke.ExitCode -or -not $seenWindow -or $wrongChild) {
    Get-Content "$env:LOCALAPPDATA\GOB\startup.log.txt" -ErrorAction SilentlyContinue
    throw 'Native GUI ownership or startup test failed.'
}
Compress-Archive -Path .\dist\portable\* -DestinationPath .\dist\GOB-Windows-Portable.zip -Force
$inno = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
if (-not (Test-Path $inno)) { throw 'Inno Setup 6 is required to build the installer.' }
& $inno GOB-Setup.iss
if ($LASTEXITCODE) { throw 'GOB installer compilation failed.' }
Copy-Item .\dist\GOB-Setup.exe .\dist\GOB.exe -Force
Write-Host 'Native host, embedded app logic, GUI ownership, engine and installer build passed.'
