$script:notifyEnabled = $false
$script:notifyName = ''

function Show-DownloadNotification([string]$Kind, [string]$Detail) {
    if (-not $script:notifyEnabled) { return }
    try {
        $json = @{Kind=$Kind; Name=$script:notifyName; Detail=$Detail} | ConvertTo-Json -Compress
        $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $toast = Join-Path $PSScriptRoot 'Download-Toast.ps1'
        $start.Arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Data {1}' -f $toast,$data
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        [Diagnostics.Process]::Start($start).Dispose()
    } catch { Add-DownloadLog 'The desktop notification could not be displayed.' }
}
