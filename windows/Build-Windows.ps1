$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$archive = Join-Path $env:RUNNER_TEMP 'aria2.zip'
Invoke-WebRequest 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip' -OutFile $archive
Expand-Archive $archive (Join-Path $env:RUNNER_TEMP 'aria2') -Force
Copy-Item (Get-ChildItem (Join-Path $env:RUNNER_TEMP 'aria2') -Recurse -Filter aria2c.exe | Select-Object -First 1).FullName .
foreach ($script in Get-ChildItem -Filter *.ps1) {
    $parseErrors = $null
    $tokens = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
& .\aria2c.exe --version
if ($LASTEXITCODE) { throw 'aria2 failed to start.' }
Copy-Item ../assets/GOB.ico .
Compress-Archive -Path *.ps1,*.txt,aria2c.exe,GOB.ico -DestinationPath payload.zip -Force
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
New-Item -ItemType Directory -Force dist | Out-Null
& $csc /nologo /target:winexe /win32icon:../assets/GOB.ico /out:dist/GOB.exe /resource:payload.zip,payload /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll Launcher.cs
if ($LASTEXITCODE) { throw 'Windows EXE compilation failed.' }
$check = Start-Process .\dist\GOB.exe -ArgumentList '--self-test' -PassThru -Wait
if ($check.ExitCode) { throw 'Packaged EXE self-test failed.' }
