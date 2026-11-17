$script:notifyEnabled = $false
$script:notifyName = ''

function Show-DownloadNotification([string]$Kind, [string]$Detail) {
    if (-not $script:notifyEnabled) { return }
    try {
        $json = @{Kind=$Kind; Name=$script:notifyName; Detail=$Detail} | ConvertTo-Json -Compress
        $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $GOBExecutable
        $start.Arguments = '--notify {0}' -f $data
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        [Diagnostics.Process]::Start($start).Dispose()
    } catch { Add-DownloadLog 'The desktop notification could not be displayed.' }
}
