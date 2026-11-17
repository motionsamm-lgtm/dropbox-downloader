@echo off
setlocal
set "DROPBOX_GUI_SCRIPT=%~dp0Dropbox-Downloader-GUI.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $launch = New-Object Diagnostics.ProcessStartInfo; $launch.FileName = Join-Path $PSHOME 'powershell.exe'; $launch.Arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File ' + [char]34 + $env:DROPBOX_GUI_SCRIPT + [char]34; $launch.UseShellExecute = $false; $launch.CreateNoWindow = $true; [Diagnostics.Process]::Start($launch).Dispose()"
if errorlevel 1 pause
endlocal
