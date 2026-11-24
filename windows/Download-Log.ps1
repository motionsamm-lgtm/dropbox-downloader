$script:summaryPath = $null
$script:summaryFinished = $false
$script:summaryTimer = $null
$script:downloadStage = 'Checking the download settings'

function Add-DownloadLog([string]$Message) {
    if (-not $script:summaryPath) { return }
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:summaryPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning 'The text log could not be written. This does not stop the download.'
        $script:summaryPath = $null
    }
}

function Start-DownloadLog([string]$Path) {
    $script:summaryPath = $Path
    $script:summaryFinished = $false
    $script:summaryTimer = [Diagnostics.Stopwatch]::StartNew()
    if (-not [IO.File]::Exists($Path)) {
        Add-DownloadLog 'Download history. Share links and local paths are omitted.'
    }
    $label = 'GOB'
    if ($GOBExecutable -and [IO.File]::Exists($GOBExecutable)) {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($GOBExecutable)
        $label += ' ' + $info.FileMajorPart + '.' + $info.FileMinorPart + '.' + $info.FileBuildPart
    }
    Add-DownloadLog "--- Attempt started ($label) ---"
    if ($script:summaryPath) { Write-Host "Text log: $([IO.Path]::GetFileName($Path))" }
}

function Get-HttpMeaning([string]$Code,[string]$Provider='Dropbox') {
    switch ($Code) {
        '401' { "$Provider asked for sign-in." }
        '403' { if($Provider -eq 'Google Drive'){'Google Drive refused access. Check public sharing and API quota.'}else{'Dropbox refused access to a download request. Its temporary address may have expired.'} }
        '404' { "$Provider could not find the requested file or address." }
        '408' { "$Provider timed out waiting for a request." }
        '410' { "A temporary $Provider download address was no longer available." }
        '416' { "$Provider refused a request for part of the file." }
        '429' { "$Provider asked the downloader to slow down." }
        { $_ -match '^5' } { "$Provider had a server-side problem." }
        default { "$Provider rejected a request." }
    }
}

function Add-ProbeLog([string]$Problem,[string]$Provider='Dropbox') {
    $status = [regex]::Match($Problem, 'HTTP ([45][0-9]{2})')
    if ($status.Success) {
        $code = $status.Groups[1].Value
        Add-DownloadLog "Link check returned HTTP ${code}. $(Get-HttpMeaning $code $Provider)"
    } elseif ($Problem -match 'byte range|range and total size') {
        Add-DownloadLog 'The link check could not confirm a usable response for resuming.'
    } else {
        Add-DownloadLog "$Provider did not return the expected file during the link check."
    }
}

function Add-TransferLog([string]$NativeLog,[string]$Provider='Dropbox') {
    if (-not $NativeLog -or -not [IO.File]::Exists($NativeLog)) { return }
    try {
        $codes = @{}
        foreach ($line in [IO.File]::ReadLines($NativeLog)) {
            $status = [regex]::Match($line, '(?i)response status is not successful\.\s*status\s*=\s*([45][0-9]{2})\b')
            if ($status.Success) {
                $code = $status.Groups[1].Value
                $codes[$code] = 1 + [int]$codes[$code]
            }
        }
        foreach ($code in ($codes.Keys | Sort-Object)) {
            Add-DownloadLog "HTTP $code appeared during the transfer ($($codes[$code]) report(s)). $(Get-HttpMeaning $code $Provider)"
        }
    } catch {
        Add-DownloadLog 'Detailed connection errors were unavailable for this attempt.'
    }
}

function Get-ExitMeaning([int]$Code) {
    switch ($Code) {
        2 { 'The connection timed out.' }
        3 { 'The download address could not be found.' }
        4 { 'The download address repeatedly could not be found.' }
        5 { 'The transfer was too slow to continue.' }
        6 { 'The network connection failed.' }
        7 { 'The transfer was stopped before it finished.' }
        8 { 'The server did not accept a resume request.' }
        9 { 'The save drive ran out of space.' }
        10 { 'The checkpoint is incompatible with this aria2 version or configuration.' }
        13 { 'A file already exists at the working path.' }
        { $_ -in @(15, 16, 17, 18) } { 'The downloader could not read or write its working files.' }
        19 { 'The downloader could not look up the server address.' }
        22 { 'The server sent an unexpected HTTP response.' }
        23 { 'The server redirected the request too many times.' }
        24 { 'The server refused authorization.' }
        29 { 'The server was temporarily unavailable.' }
        default { 'The download engine stopped unexpectedly.' }
    }
}

function Finish-DownloadLog([string]$Result) {
    if ($script:summaryFinished -or -not $script:summaryPath) { return }
    Add-DownloadLog "Result: $Result"
    Add-DownloadLog ("Elapsed time for this attempt: {0:hh\:mm\:ss}." -f $script:summaryTimer.Elapsed)
    $script:summaryFinished = $true
}
