param([string]$JobFile, [string]$HistoryAttempt)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Download-Reliability.ps1')
. (Join-Path $PSScriptRoot 'Download-Log.ps1')
. (Join-Path $PSScriptRoot 'Download-History.ps1')
. (Join-Path $PSScriptRoot 'Download-Notifications.ps1')
. (Join-Path $PSScriptRoot 'Download-GoogleDrive.ps1')
. (Join-Path $PSScriptRoot 'Download-Folder.ps1')

function Get-TextHash([string]$Text) {
    return Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-Mp4Header([byte[]]$Bytes) {
    $offset = 0
    while ($offset + 8 -le $Bytes.Length) {
        $boxSize = [long]$Bytes[$offset] * 16777216 + [long]$Bytes[($offset + 1)] * 65536 +
                   [long]$Bytes[($offset + 2)] * 256 + $Bytes[($offset + 3)]
        $boxType = [Text.Encoding]::ASCII.GetString($Bytes, $offset + 4, 4)
        if ($boxType -eq 'ftyp') {
            return ($boxSize -ge 16 -and $offset + 16 -le $Bytes.Length)
        }
        if ($boxType -notin @('free', 'skip', 'wide') -or $boxSize -lt 8 -or
            $offset + $boxSize -gt $Bytes.Length) {
            return $false
        }
        $offset += [int]$boxSize
    }
    return $false
}

function Test-ZipHeader([byte[]]$Bytes) {
    return ($Bytes.Length -ge 4 -and $Bytes[0] -eq 80 -and $Bytes[1] -eq 75 -and
            $Bytes[2] -in @(3, 5, 7) -and $Bytes[3] -eq $Bytes[2] + 1)
}

function Get-DownloadProbe([string]$Curl, [string]$Url, [bool]$VerifyMp4, [bool]$FolderZip, [bool]$OnePass = $false, [string[]]$Headers=@(), [string]$Provider='Dropbox') {
    $sample = [IO.Path]::GetTempFileName()
    try {
        $lastByte = 4095
        $probeOptions = @()
        foreach($header in $Headers){$probeOptions+=@('--header',($header -replace '^--header=',''))}
        if ($FolderZip -or $OnePass) { $probeOptions += @('--limit-rate', '16K') }
        $headers = & $Curl --disable @probeOptions --silent --globoff --location --max-redirs 10 --proto '=https' --proto-redir '=https' --max-time 20 --max-filesize 65536 --range "0-$lastByte" --dump-header - --output $sample $Url
        $probeExit = $LASTEXITCODE
        $blocks = ($headers -join "`n") -split '(?m)(?=^HTTP/)'
        $response = $blocks[-1]
        $status = [regex]::Match($response, '^HTTP/\S+\s+(\d{3})').Groups[1].Value
        if (-not $status) { $status = 'unavailable' }
        if ($status -eq '416' -and $response -match '(?im)^Content-Range:[ \t]*bytes \*/0[ \t]*\r?$') {
            return @{ Size = 0L; Prefix = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'; SampleLength = 0; Tag = '' }
        }
        if ($FolderZip -and $status -eq '200' -and $probeExit -in @(0, 28, 63)) {
            $zipType = $response -match '(?im)^Content-Type:[ \t]*application/(?:x-zip-compressed|zip)(?:[ \t]*;|[ \t]*\r?$)'
            $zipName = $response -match '(?im)^Content-Disposition:[^\r\n]*\bfilename\*?=[^\r\n;]*\.zip"?[ \t]*(?:;|\r?$)'
            if ($zipType -or $zipName) {
                $length = [regex]::Match($response, '(?im)^Content-Length:[ \t]*(\d+)[ \t]*\r?$')
                $size = 0
                if ($length.Success) { $size = [long]$length.Groups[1].Value }
                return @{ Size = $size }
            }
            return @{ Problem = "$Provider did not identify the folder response as a ZIP archive." }
        }
        if ($OnePass -and $status -eq '200' -and $probeExit -in @(0, 28, 63)) {
            $length = [regex]::Match($response, '(?im)^Content-Length:[ \t]*(\d+)[ \t]*\r?$')
            $isPage = $response -match '(?im)^Content-Type:[ \t]*(text/html|application/xhtml\+xml|application/(?:problem\+)?json)'
            if ($length.Success -and [long]$length.Groups[1].Value -gt 0 -and -not $isPage) {
                return @{ Size = [long]$length.Groups[1].Value }
            }
            return @{ Problem = 'The one-pass response was a web page or had no reliable file size.' }
        }
        if (-not $FolderZip -and -not $OnePass -and $status -eq '200') {
            $zipResponse = $response -match '(?im)^Content-Type:[ \t]*application/(?:x-zip-compressed|zip)' -or
                $response -match '(?im)^Content-Disposition:[^\r\n]*\bfilename[^\r\n]*\.zip(?:[";\s]|$)'
            return @{ Problem = "$Provider ignored the byte range. Use One pass only if you want a new download from zero."; ZipResponse = $zipResponse }
        }
        if ($status -ne '206' -or $probeExit -ne 0) {
            $delay = 0
            if ($status -in @('408', '429', '500', '502', '503', '504') -or
                ($status -in @('unavailable', '206') -and $probeExit -in @(5, 6, 7, 18, 28, 52, 55, 56))) {
                $delay = 10
                if ($status -in @('429', '503')) { $delay = 30 }
                $retryAfter = [regex]::Match($response, '(?im)^Retry-After:[ \t]*([^\r\n]+)').Groups[1].Value.Trim()
                $seconds = 0L
                $date = [DateTimeOffset]::MinValue
                if ([long]::TryParse($retryAfter, [ref]$seconds) -and $seconds -ge 0) {
                    $delay = [int][Math]::Max(1, [Math]::Min(121, $seconds))
                } elseif ([DateTimeOffset]::TryParse($retryAfter, [ref]$date)) {
                    $seconds = [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds)
                    $delay = [int][Math]::Max(1, [Math]::Min(121, $seconds))
                }
            }
            $problem = if($Provider -eq 'Google Drive' -and $status -eq '403'){'Google Drive denied this file request. Check Anyone with the link access; API quota or key restrictions may also block it.'}else{"$Provider returned HTTP $status, curl $probeExit. No usable byte range."}
            if ($delay -gt 120) { $problem += " $Provider requested a longer wait. Try again later." }
            return @{ Problem = $problem; RetryDelay = $delay }
        }
        $range = [regex]::Match($response, '(?im)^Content-Range:\s*bytes 0-(\d+)/(\d+)[ \t]*\r?$')
        if (-not $range.Success) { return @{ Problem = "$Provider did not report the byte range and total size." } }
        $end = [long]$range.Groups[1].Value
        $size = [long]$range.Groups[2].Value
        if ($end -gt $lastByte -or $end -ge $size -or (Get-Item -LiteralPath $sample).Length -ne $end + 1) {
            return @{ Problem = "$Provider returned an incomplete or invalid byte range." }
        }
        if ($response -match '(?im)^Content-Type:\s*(text/html|application/xhtml\+xml)') {
            return @{ Problem = "$Provider returned a web page." }
        }
        if ($VerifyMp4) {
            $bytes = [IO.File]::ReadAllBytes($sample)
            if (-not (Test-Mp4Header $bytes)) {
                if (Test-ZipHeader $bytes) {
                    return @{ Problem = "$Provider returned a ZIP archive." }
                }
                return @{ Problem = 'The returned bytes did not contain a recognizable MP4 header.' }
            }
        }
        if ($FolderZip -and -not (Test-ZipHeader ([IO.File]::ReadAllBytes($sample)))) {
            return @{ Problem = "$Provider did not return ZIP bytes for the folder." }
        }
        if ($FolderZip) { return @{ Size = $size } }
        $tag = [regex]::Match($response, '(?im)^ETag:[ \t]*("[^"\r\n]*")[ \t]*\r?$').Groups[1].Value
        return @{ Size = $size; Prefix = (Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash.ToLowerInvariant(); Tag = $tag; SampleLength = [int]($end + 1) }
    } finally {
        Remove-Item -LiteralPath $sample -ErrorAction SilentlyContinue
    }
}


function Get-FileProbeWithRetry([string]$Curl, [string]$Url, [bool]$VerifyMp4, [string[]]$Headers=@(), [string]$Provider='Dropbox') {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $probe = Get-DownloadProbe $Curl $Url $VerifyMp4 $false $false $Headers $Provider
        if (-not $probe.RetryDelay -or $probe.RetryDelay -gt 120 -or $attempt -eq 2) {
            return $probe
        }
        Add-ProbeLog $probe.Problem $Provider
        Add-DownloadLog "Waiting $($probe.RetryDelay) seconds before checking the link again."
        Write-Host ("{0} Checking again in {1}s." -f $probe.Problem, $probe.RetryDelay) -ForegroundColor Yellow
        Wait-DownloadRetry $probe.RetryDelay
    }
}

function Assert-SameSource($Expected, $Actual,[string]$Provider='Dropbox') {
    if ($Expected.Size -ne $Actual.Size -or $Expected.Prefix -ne $Actual.Prefix -or
        ($Expected.Tag -and $Actual.Tag -and $Expected.Tag -cne $Actual.Tag)) {
        throw "$Provider is returning a different file. Saved progress was kept. Use a new output name to download the changed file."
    }
}

function Assert-ResumePair([string]$Partial, [string]$Control) {
    if ((Test-Path -LiteralPath $Partial -PathType Leaf) -xor (Test-Path -LiteralPath $Control -PathType Leaf)) {
        throw 'A partial file or its aria2 checkpoint is missing. The saved files were kept. Restore the matching pair, or choose a new output name.'
    }
}

function Get-TransferFailure([int]$Code, [bool]$IsDirect,[string]$Provider='Dropbox') {
    switch ($Code) {
        7 { return 'Download stopped. Start again with the same link, filename and save folder to resume.' }
        8 { return "$Provider stopped accepting resume requests. Progress was kept. Try the same share link again later." }
        9 { return 'The save drive ran out of space. Free space there, then resume with the same settings.' }
        10 { return 'The aria2 checkpoint uses a different piece size. Keep the files together and use the aria2 build that started the download.' }
        13 { return 'A file already exists at the working path. It was kept.' }
        { $_ -in @(3, 4, 24) } {
            if ($IsDirect) {
                return "The direct $Provider address may have expired or lost access. The partial was kept. A different direct address cannot reuse this checkpoint."
            }
            return "$Provider could not find or authorize the file. Check the share link and its download permissions. Any saved progress was kept."
        }
        default {
            return "aria2 stopped with exit code $Code. Any saved progress was kept. Use the same link, filename and save folder to resume."
        }
    }
}

$backgroundLock = $null
$backgroundLocked = $false
try {
    if ($HistoryAttempt) {
        $script:historyAttemptPath = $HistoryAttempt
        $current = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $script:historyState = @{
                ProcessId = $PID
                ProcessStart = [string]$current.StartTime.ToUniversalTime().Ticks
                SummaryPath = ''
                SharedSummary = $true
                EngineFinished = $false
                Output = ''
                Status = ''
                Updated = ''
                Message = ''
                Port = 0
                Token = ''
                Gid = ''
                Checkpoint = ''
                Metrics = $null
            }
        } finally { $current.Dispose() }
        Update-HistoryState 'Running' 'Opening the saved download settings.'
        $preJobPath = Join-Path ([IO.Path]::GetDirectoryName($HistoryAttempt)) 'job.json'
        $preJob = Get-Content -LiteralPath $preJobPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($preJob.ParentFolder -eq $true) {
            $script:folderParentId = [int]$preJob.ParentWorkerId
            $script:folderParentStart = [string]$preJob.ParentWorkerStart
            if (-not (Test-HistoryProcess $script:folderParentId $script:folderParentStart)) { throw 'The folder worker is no longer active. Resume the folder from History.' }
        } else {
            $backgroundLock = [Threading.Mutex]::new($false, 'Local\DropboxDownloaderBackgroundTransfer')
            try { $backgroundLocked = $backgroundLock.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $backgroundLocked = $true }
            if (-not $backgroundLocked) { throw 'Another background transfer is already running.' }
        }
        $jobDirectory = [IO.Path]::GetDirectoryName($HistoryAttempt)
        $JobFile = Join-Path $jobDirectory 'job.json'
        Start-DownloadLog (Get-HistoryLogPath $jobDirectory)
        $script:historyState.SummaryPath = $script:summaryPath
        Update-HistoryState 'Running' 'Opening the saved download settings.'
        Assert-DownloadActive
    }
    $aria = Join-Path $PSScriptRoot 'aria2c.exe'
    if (-not [IO.File]::Exists($aria)) {
        throw 'Put aria2c.exe next to Start-Downloader.cmd. See README.txt.'
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'

    Write-Host 'GOB 1.2.0'
    $folderZip = $false
    $subfolder = $false
    $brutal = $false
    $onePass = $false
    $checksum = ''
    $speedLimit = 0
    $provider = 'dropbox'
    $driveFile = $null
    $driveHeaders = @()
    $destination = $PSScriptRoot
    if ($JobFile) {
        try {
            $job = Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } finally {
            if (-not $HistoryAttempt) { Remove-Item -LiteralPath $JobFile -ErrorAction SilentlyContinue }
        }
        if ($HistoryAttempt) {
            $secretLink = ConvertTo-SecureString -String $job.ProtectedLink
            try { $inputLink = [Net.NetworkCredential]::new('', $secretLink).Password }
            finally { $secretLink.Dispose() }
        } else {
            $inputLink = ([string]$job.Link).Trim()
        }
        $name = ([string]$job.Name).Trim()
        $destination = [IO.Path]::GetFullPath([string]$job.Destination)
        if (-not [IO.Directory]::Exists($destination)) { throw 'Choose an existing save folder.' }
        $folderZip = $job.FolderZip -eq $true
        $subfolder = $job.Subfolder -eq $true
        if ($HistoryAttempt) {
            $script:notifyEnabled = $job.Notifications -eq $true
            $script:notifyName = [string]$job.DisplayName
        }
        $provider = if($job.Provider){[string]$job.Provider}else{Get-DownloadProvider $inputLink}
        if($script:historyState){$script:historyState.Provider=$provider}
        if ($job.AutoDetect) {
            $kind = Get-DropboxLinkKind $inputLink
            if (-not $kind) { throw 'The link type could not be detected. Paste a Dropbox or Google Drive file or folder share link.' }
            $folderZip = $kind -eq 'Folder'
        }
        $brutal = $job.Brutal -eq $true
        $onePass = -not $folderZip -and $job.OnePass -eq $true
        $checksum = ([string]$job.Checksum).Trim()
        if ($checksum -and $checksum -notmatch '^[0-9a-f]{64}$') { throw 'SHA-256 must contain exactly 64 hexadecimal characters.' }
        $connections = [string]$job.Connections
        $speedLimit = [int]$job.SpeedLimit
        if ($speedLimit -lt 0 -or $speedLimit -gt 999) { throw 'Choose a valid speed limit.' }
    } else {
        $inputLink = (Read-Host 'Paste the Dropbox or Google Drive file or folder link').Trim()
        $provider = Get-DownloadProvider $inputLink
    }
    if ($HistoryAttempt -and $folderZip -and $job.FolderMode -eq 'files') {
        Invoke-FolderDownload $job $inputLink
        exit 0
    }
    $share = $null
    if($provider -eq 'google-drive') {
        $driveLink=Get-GoogleDriveLinkInfo $inputLink
        $driveId=if($job.ParentFolder -and $job.DriveFile.Id){[string]$job.DriveFile.Id}else{$driveLink.Id}
        $driveResourceKey=if($job.ParentFolder -and $job.DriveFile.ResourceKey){[string]$job.DriveFile.ResourceKey}else{$driveLink.ResourceKey}
        $driveFile=Get-GoogleDriveMetadata $driveId $driveResourceKey
        if($driveFile.mimeType -eq 'application/vnd.google-apps.folder'){
            if($HistoryAttempt -and $job.FolderMode -eq 'files'){Invoke-FolderDownload $job $inputLink;exit 0}
            throw 'Google Drive folders download as individual files. Start from the folder link in the GOB app.'
        }
        if($driveFile.mimeType -like 'application/vnd.google-apps.*'){throw 'This is a Google Docs, Sheets or Slides file. Workspace export is not available yet; use a downloadable binary file link.'}
        if($driveFile.capabilities.canDownload -eq $false){throw 'The owner has disabled downloading for this Google Drive item.'}
        if(-not $name){$name=[string]$driveFile.name}
        $request=Get-GoogleDriveMediaRequest $driveFile
        $share=[Uri]$request.Url
        $driveHeaders=@($request.Headers)
        $isDirect=$true
        $isSharedFolderVideo=$false
        $modes=@('Google Drive media')
    } else {
        if (-not [Uri]::TryCreate($inputLink, [UriKind]::Absolute, [ref]$share) -or
            $share.Scheme -ne 'https' -or $share.UserInfo -or -not $share.IsDefaultPort) {
            throw 'Paste a valid HTTPS Dropbox or Google Drive link.'
        }
        $isDirect = $share.Host -match '^(?:[a-z0-9-]+\.)*dl\.dropboxusercontent\.com$'
        $isSharedFolderVideo = $share.AbsolutePath -match '^/(?:scl/fo|sh)/[^/]+/[^/]+/(?:[^/]+/)*[^/]+$'
    }
    if ($provider -eq 'dropbox' -and $folderZip) {
        if ($share.Host -notin @('dropbox.com', 'www.dropbox.com') -or
            $share.AbsolutePath -notmatch '^/(scl/fo|sh)/[^/]+/[^/]+/?$') {
            throw 'In Folder ZIP mode, paste the Dropbox link to the whole shared folder.'
        }
    } elseif ($provider -eq 'dropbox' -and -not $isDirect) {
        if ($share.Host -notin @('dropbox.com', 'www.dropbox.com') -or
            (-not $isSharedFolderVideo -and $share.AbsolutePath -notmatch '^/(scl/fi|s)/[^/]+/[^/]+$')) {
            throw 'Open the MP4 inside the shared folder and copy its URL, or paste a Dropbox file share link.'
        }
    }
    $verifyMp4 = $share.AbsolutePath -match '\.mp4$' -or $name -match '\.mp4$'
    if($provider -eq 'dropbox') {
      $modes = @('dl=1')
      if ($isSharedFolderVideo) { $modes += 'raw=1' }
      if ($isDirect) {
          $modes = @('direct address')
      } else {
        $direct = [UriBuilder]::new($share)
        $direct.Fragment = ''
        $query = $share.Query.TrimStart('?').Split('&') | Where-Object {
            $_ -and $_ -notmatch '^(dl|raw)(=|$)'
        }
      }
    }

    $sourceKey = if($provider -eq 'google-drive'){Get-TextHash ('google-drive:{0}:{1}' -f $driveId,$driveResourceKey)}else{Get-TextHash $share.AbsoluteUri}
    if ($provider -eq 'dropbox' -and -not $isDirect) {
        $stableQuery = $query | Where-Object { $_ -notmatch '^st(=|$)' }
        $sourceKey = Get-TextHash ($share.GetLeftPart([UriPartial]::Path) + '?' + ($stableQuery -join '&'))
    }
    $streamOnly = $folderZip -or $onePass
    $providerName = if($provider -eq 'google-drive'){'Google Drive'}else{'Dropbox'}
    if($script:historyState){$script:historyState.Provider=$provider}

    if (-not $JobFile) {
        $name = (Read-Host 'Output filename [Podcast-19.mp4]').Trim()
    }
    if (-not $name) {
        if ($folderZip) { $name = 'Dropbox-Folder.zip' }
        elseif ($isDirect -or -not $JobFile) { $name = 'Podcast-19.mp4' }
        else { $name = [Uri]::UnescapeDataString($share.Segments[-1]) }
    }
    if ($folderZip -and -not $name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
        $name += '.zip'
    }
    if ($verifyMp4 -and -not $name.EndsWith('.mp4', [StringComparison]::OrdinalIgnoreCase)) {
        $name += '.mp4'
    }
    if (-not $folderZip -and -not [IO.Path]::GetExtension($name)) {
        $sourceExtension = [IO.Path]::GetExtension([Uri]::UnescapeDataString($share.Segments[-1]))
        if ($sourceExtension -match '^\.[A-Za-z0-9]{1,10}$') { $name += $sourceExtension }
    }
    if ($name.Length -gt 120 -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        ($name -match '(^\.|\.$|^(CON|PRN|AUX|NUL|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(?:\.|$))' -and -not $job.ParentFolder)) {
        throw 'Use a regular Windows filename with an extension, such as Podcast-19.mp4.'
    }
    if (-not $JobFile) {
        $connections = (Read-Host 'Connections [4] (enter 1 if parallel requests fail)').Trim()
    }
    if ($streamOnly) { $connections = '1' }
    if (-not $connections) { $connections = '4' }
    if ($connections -notin @('1', '2', '3', '4') -and -not ($job.ParentFolder -and [int]$connections -ge 1 -and [int]$connections -le 16)) { throw 'Choose 1, 2, 3 or 4.' }
    $normalSpeedLimit = $speedLimit
    if ($brutal) {
        $speedLimit = 0
        if (-not $streamOnly) { $connections = if ($job.ParentFolder) { [string]$job.Connections } else { '16' } }
    }


    if ($subfolder) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($name).TrimEnd([char[]]@(' ','.'))
        if (-not $stem) { throw 'Choose a filename that can also be used as a subfolder name.' }
        $destination = Join-Path $destination $stem
        if ([IO.Directory]::Exists($destination) -and
            (([IO.File]::GetAttributes($destination)) -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The selected subfolder is a redirect. Choose a different filename or destination.'
        }
        [void][IO.Directory]::CreateDirectory($destination)
    }
    $target = Join-Path $destination $name
    $lockKey = Get-TextHash ($target.ToUpperInvariant())
    $lock = [Threading.Mutex]::new($false, "Local\DropboxDownloader-$lockKey")
    $locked = $false
    try {
        try { $locked = $lock.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another instance is downloading to this filename.' }
        if ($HistoryAttempt) {
            $script:historyState.Output = $target
            Update-HistoryState 'Running' "Checking the $providerName link and save folder."
        } else {
            Start-DownloadLog (Join-Path $destination "$name.$($sourceKey.Substring(0, 16)).log.txt")
        }
        $typeText = if ($folderZip) { 'shared folder ZIP' } elseif ($onePass) { 'single file (one pass)' } else { 'single file (resumable)' }
        Add-DownloadLog "Job type: $typeText. Brutal: $brutal. Speed cap in MiB/s: $speedLimit (0 = off). Subfolder: $subfolder."
        Show-DownloadNotification 'Started' ''
        $readyMarker = Join-Path $destination ".dropbox-$($lockKey.Substring(0, 16)).ready.json"
        if (Test-Path -LiteralPath $readyMarker -PathType Leaf) {
            Add-DownloadLog 'Found a completed download waiting to be saved. Finishing it locally.' 
            Complete-SavedDownload $target $readyMarker $sourceKey $checksum
            if ($JobFile -and -not $HistoryAttempt) { $null = Read-Host 'Press Enter to close' }
            return
        }

        $script:downloadStage = "Checking the $providerName link"
        if (Test-Path -LiteralPath $target) {
            throw 'That output already exists. Choose a different output filename.'
        }

        $size = $null
        foreach ($mode in $modes) {
            if ($isDirect) {
                $url = $share.AbsoluteUri
            } else {
                $direct.Query = (@($query) + $mode) -join '&'
                $url = $direct.Uri.AbsoluteUri
            }
            Write-Host "Checking $providerName response ($mode)..."
            if ($streamOnly) {
                $probe = Get-DownloadProbe $curl $url $verifyMp4 $folderZip $onePass $driveHeaders $providerName
            } else {
                $probe = Get-FileProbeWithRetry $curl $url $verifyMp4 $driveHeaders $providerName
            }
            if($provider -eq 'google-drive' -and $driveFile.md5Checksum){$probe.Tag='"'+([string]$driveFile.md5Checksum).ToLowerInvariant()+'"'}
            if (-not $probe.Problem) {
                $size = $probe.Size
                break
            }
            if (-not $streamOnly -and $probe.Problem -match 'ignored the byte range') {
                if ($probe.ZipResponse -and $isSharedFolderVideo -and -not $job.ParentFolder) {
                    throw 'Dropbox returned a folder ZIP. Paste the whole folder share link so GOB can list its files instead.'
                }
                if ($isSharedFolderVideo -and $mode -ne 'raw=1') { continue }
                $probe = Get-DownloadProbe $curl $url $verifyMp4 $false $true $driveHeaders $providerName
                if (-not $probe.Problem) {
                    $streamOnly = $true
                    $onePass = $true
                    $connections = '1'
                    $size = $probe.Size
                    Add-DownloadLog "$providerName ignored ranges. Using a new one-stream partial. Existing checkpoints were kept."
                    break
                }
            }
            Add-ProbeLog $probe.Problem $providerName
            Write-Host $probe.Problem -ForegroundColor Yellow
            if ($probe.RetryDelay) { break }
        }
        if ($null -eq $size) {
            if ($folderZip) { throw "No download started. Check that $providerName can download this shared folder as a ZIP." }
            throw 'No download started. Any saved progress was kept. Check the link in your browser and retry with the same download settings.'
        }
        if ($job.ParentFolder -eq $true -and [long]$job.ExpectedSize -ne $size) { throw 'This folder file changed size after listing. Saved files were kept. Download the changed folder under a new name.' }
        if ($provider -eq 'google-drive' -and [long]$driveFile.size -ne [long]$size){throw 'Google Drive returned a different file size than its metadata. Saved files were kept.'}
        if ($size -gt 0) { Add-DownloadLog ("$providerName reported a file size of {0:N2} GiB." -f ($size / 1GB)) }
        $script:downloadStage = 'Preparing the saved checkpoint and destination'
        $identity = Get-TextHash "$url|${size}"
        $partialName = "$name.$($identity.Substring(0, 16)).part"
        if ($streamOnly) {
            $partialName = "$name.$([Guid]::NewGuid().ToString('N').Substring(0, 16)).part"
        } elseif (-not $isDirect -and
            -not (Test-Path -LiteralPath (Join-Path $destination $partialName)) -and
            -not (Test-Path -LiteralPath (Join-Path $destination "$partialName.aria2"))) {
            $refreshed = Find-RefreshedPartial $destination $name $sourceKey $probe
            if ($refreshed) {
                $partialName = $refreshed
                Write-Host "Resuming from a checkpoint that matches this refreshed $providerName link."
            }
        }
        $partial = Join-Path $destination $partialName
        $control = "$partial.aria2"
        foreach ($owned in @($partial, $control, ($partial + '.resume.json'))) { Add-OwnedDownloadFile $owned }
        if ($HistoryAttempt) { $script:historyState.Checkpoint = $control }
        $priorFinished = [IO.File]::Exists($partial) -and -not [IO.File]::Exists($control) -and
            ($size -le 0 -or (Get-Item -LiteralPath $partial).Length -eq $size) -and
            (Test-PriorEngineCompletion $HistoryAttempt $control)
        if (-not $priorFinished) { Assert-ResumePair $partial $control }
        $hasCheckpoint = Test-Path -LiteralPath $control -PathType Leaf
        Assert-SaveLocation $destination $size ($hasCheckpoint -or $priorFinished)
        if ($hasCheckpoint) { Add-DownloadLog 'Found saved progress. The download will resume from its checkpoint.' }
        if ($streamOnly) { Add-DownloadLog 'This transfer uses a single stream and starts from the beginning.' }
        $sourceState = "$partial.resume.json"
        if (-not $streamOnly) {
            if ($hasCheckpoint -and (Test-Path -LiteralPath $sourceState -PathType Leaf)) {
                $savedProbe = Get-Content -LiteralPath $sourceState -Raw -Encoding UTF8 | ConvertFrom-Json
                Assert-SameSource $savedProbe $probe $providerName
            } else {
                $savedProbe = $probe
            }
            if (-not $savedProbe.Tag -and $probe.Tag) { $savedProbe = $probe }
            Write-DownloadState $sourceState @{
                Size = $probe.Size
                Prefix = $probe.Prefix
                Tag = $savedProbe.Tag
                SourceKey = $sourceKey
            }
        }

        if ($folderZip) {
            Write-Host 'Downloading a folder ZIP in one stream. If interrupted, start the ZIP again.'
        } elseif ($onePass) {
            Write-Host 'One pass: starting from byte zero in a separate partial. Existing checkpoints stay available.'
        } else {
            Write-Host ("$providerName confirmed byte ranges. File size: {0:N2} GiB." -f ($size / 1GB))
            Write-Host 'To resume later, use the same link, output filename and save folder.'
        }
        if ($brutal) { Write-Host "Brutal mode: up to $connections connection(s), no speed cap." }
        $brutalActive = $brutal
        $options = @(
            '--no-conf=true'
            '--continue=true'
            '--always-resume=true'
            '--allow-overwrite=false'
            '--auto-file-renaming=false'
            '--auto-save-interval=5'
            '--file-allocation=none'
            '--retry-wait=5'
            '--timeout=30'
            '--summary-interval=0'
            "--dir=$destination"
            "--out=$partialName"
        )
        if ($streamOnly) {
            $options = $options | Where-Object { $_ -notin @('--continue=true', '--always-resume=true') }
            $options += @('--continue=false', '--always-resume=false')
        }
        if ($JobFile) { $options += '--console-log-level=warn' }
        $options += $driveHeaders
        $currentConnections = [int]$connections
        $recoverable = @(2, 5, 6, 8, 19, 22, 23, 29)
        if (-not $isDirect) { $recoverable += @(3, 4, 24) }
        $completeCheckpoint = Test-CompleteCheckpoint $control $size
        if ($completeCheckpoint -or $priorFinished) { Add-DownloadLog 'Saved transfer records show all bytes arrived. Verifying the file locally.' }
        for ($attempt = 0; -not $completeCheckpoint -and -not $priorFinished -and $attempt -lt 6; $attempt++) {
            Assert-DownloadActive
            $reportedSuccess = $false
            $maxTries = if ($streamOnly) { 1 } elseif ($brutalActive) { 4 } else { 12 }
            $transferOptions = $options + @(
                "--max-tries=$maxTries"
                "--max-connection-per-server=$currentConnections"
                "--split=$currentConnections"
            )
            if ($speedLimit -gt 0) { $transferOptions += "--max-download-limit=${speedLimit}M" }
            $script:downloadStage = 'Downloading the file'
            $modeLabel = if ($brutalActive) { 'Brutal' } elseif ($brutal) { 'Recovery' } else { 'Normal' }
            Add-DownloadLog "Starting transfer attempt $($attempt + 1) with up to $currentConnections connection(s). Mode: $modeLabel. Speed cap: $speedLimit MiB/s (0 = off)."
            if ($HistoryAttempt) {
                $transferOptions = @($transferOptions | Where-Object { $_ -ne '--summary-interval=0' })
                $transferOptions += @('--summary-interval=2', '--show-console-readout=true', '--enable-color=false',
                    '--truncate-console-readout=false', '--human-readable=false', "--stop-with-process=$PID")
                Update-HistoryState 'Running' "Downloading with up to $currentConnections connection(s). Mode: $modeLabel."
            }
            $nativeLog = $null
            if ($script:summaryPath) {
                try {
                    $nativeLog = [IO.Path]::GetTempFileName()
                $transferOptions += @("--log=$nativeLog", '--log-level=warn')
                } catch {
                    Add-DownloadLog 'Detailed connection logging was unavailable.'
                }
            }
            try {
                if ($HistoryAttempt) {
                    $outcome = Invoke-RecordedTransfer $aria ($transferOptions + @($url))
                    $downloadExit = $outcome.ExitCode
                    $reportedSuccess = $outcome.ReportedSuccess
                } else {
                    & $aria @transferOptions $url
                    $downloadExit = $LASTEXITCODE
                }
            } finally {
                Add-TransferLog $nativeLog $providerName
                if ($nativeLog) { Remove-Item -LiteralPath $nativeLog -ErrorAction SilentlyContinue }
            }
            $completeCheckpoint = Test-CompleteCheckpoint $control $size
            $cleanPartial = [IO.File]::Exists($partial) -and -not [IO.File]::Exists($control) -and
                ($size -le 0 -or (Get-Item -LiteralPath $partial).Length -eq $size)
            if ($downloadExit -eq 0 -or ($reportedSuccess -and $cleanPartial) -or $completeCheckpoint) {
                if ($downloadExit -ne 0) {
                    Add-DownloadLog "aria2 returned code $downloadExit, but its final result or checkpoint shows completion. Verifying before saving."
                }
                if ($HistoryAttempt) { $script:historyState.EngineFinished = $true }
                Update-HistoryState 'Running' 'All bytes received. Checking the saved file.'
                Add-DownloadLog 'The download engine finished receiving the file.'
                break
            }
            Add-DownloadLog "$(Get-ExitMeaning $downloadExit) (aria2 code $downloadExit)"
            if ($streamOnly) { throw "One-stream download stopped with aria2 exit code $downloadExit. Its partial was kept. A new one-pass attempt starts from zero." }
            if ($downloadExit -notin $recoverable -or $attempt -eq 5) {
                throw (Get-TransferFailure $downloadExit $isDirect $providerName)
            }

            Assert-ResumePair $partial $control
            if ($brutalActive) {
                $brutalActive = $false
                $currentConnections = 1
                $speedLimit = $normalSpeedLimit
                if ($HistoryAttempt) { $script:historyState.RecoveryMode = $true }
                Add-DownloadLog 'Brutal switched off for this run after a retryable error. Recovery uses one connection and the normal retry settings.'
            } else {
                $currentConnections = [Math]::Max(1, [int][Math]::Floor($currentConnections / 2))
            }
            $delay = [int][Math]::Min(60, 5 * [Math]::Pow(2, $attempt))
            if ($downloadExit -in @(22, 29)) { $delay = [Math]::Max(30, $delay) }
            Add-DownloadLog "Keeping the checkpoint and reopening the link after ${delay}s. The next attempt will use up to $currentConnections connection(s)."
            Write-Host "Transfer interrupted (aria2 $downloadExit). Retrying with $currentConnections connection(s) in ${delay}s." -ForegroundColor Yellow
            $retryMessage = if ($brutal -and -not $brutalActive) {
                "Brutal paused. Resuming with one connection in ${delay}s."
            } else {
                "Waiting ${delay}s before retrying with up to $currentConnections connection(s)."
            }
            Update-HistoryState 'Running' $retryMessage
            Wait-DownloadRetry $delay
            $freshProbe = Get-FileProbeWithRetry $curl $url $verifyMp4 $driveHeaders $providerName
            if($provider -eq 'google-drive' -and $driveFile.md5Checksum){$freshProbe.Tag='"'+([string]$driveFile.md5Checksum).ToLowerInvariant()+'"'}
            if ($freshProbe.Problem) {
                Add-ProbeLog $freshProbe.Problem $providerName
                throw "$providerName could not reopen the link. $($freshProbe.Problem) Any saved progress was kept."
            }
            Assert-SameSource $savedProbe $freshProbe $providerName
        }
        $script:downloadStage = 'Confirming that all bytes arrived'
        if (-not (Test-Path -LiteralPath $partial -PathType Leaf) -or
            ($size -gt 0 -and (Get-Item -LiteralPath $partial).Length -ne $size) -or
            ((Test-Path -LiteralPath $control) -and -not $completeCheckpoint)) {
            throw 'Completion could not be confirmed. Inspect the partial file before using it.'
        }
        $completed = Get-Item -LiteralPath $partial
        Write-DownloadState $readyMarker @{
            SourceKey = $sourceKey
            PartialName = $partialName
            Length = $completed.Length
            LastWriteTicks = [string]$completed.LastWriteTimeUtc.Ticks
            FolderZip = $folderZip
            VerifyMp4 = $verifyMp4
            Prefix = $probe.Prefix
            SampleLength = $probe.SampleLength
            Checksum = $checksum
            DriveMd5 = if($provider -eq 'google-drive'){[string]$driveFile.md5Checksum}else{''}
            Provider = $provider
            CompleteCheckpoint = $completeCheckpoint
        }
        Complete-SavedDownload $target $readyMarker $sourceKey $checksum
    } finally {
        if ($locked) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
} catch {
    $failure = $_.Exception.Message
    if (Test-DownloadPause) {
        $message = 'Paused by you. Saved progress was kept. Resume continues where the server supports it.'
        Add-DownloadLog $message
        Finish-DownloadLog $message
        Update-HistoryState 'Paused' $message
        exit 0
    }
    $safeReason = switch -Regex ($failure) {
        'SHA-256 mismatch' { 'The checksum did not match. The file was kept as a partial.'; break }
        'Windows could not rename' { 'Windows blocked the final rename. The completed partial was kept for a local retry.'; break }
        'not have enough free space|ran out of space' { 'The save drive did not have enough free space.'; break }
        'FAT32' { 'The save drive is FAT32 and cannot hold a file this large.'; break }
        'could not create a file in the save folder' { 'Windows could not write to the chosen save folder.'; break }
        'different file|did not prove|changed after transfer' { 'The downloader could not confirm that the file matched the saved checkpoint.'; break }
        'missing|checkpoint uses a different' { 'The saved checkpoint or partial could not be used safely.'; break }
        'already exists|Another instance' { 'The output name was already in use.'; break }
        'Download stopped\.' { 'Stopped before completion. Use the same settings to resume.'; break }
        default { "Stopped during: $script:downloadStage. See the preceding entries for details." }
    }
    $diagnostic = [regex]::Replace($failure, '(?i)https?://[^\s]+', '[share link]')
    $diagnostic = [regex]::Replace($diagnostic, '(?i)\b[A-Z]:\\[^\r\n]*', '[local path omitted]')
    Add-DownloadLog ("Reason: " + $diagnostic)
    Finish-DownloadLog $safeReason
    Update-HistoryState 'Failed' $safeReason
    Show-DownloadNotification 'Failed' $safeReason
    Write-Host $failure -ForegroundColor Red
    if ($JobFile -and -not $HistoryAttempt) { $null = Read-Host 'Press Enter to close' }
    exit 1
} finally {
    if ($script:historyState -and $script:historyState.Status -in @('Running', 'Starting')) {
        Update-HistoryState 'Interrupted' 'The worker stopped before completion was confirmed.'
        Show-DownloadNotification 'Failed' 'The download was interrupted. Check History to resume.'
    }
    Finish-DownloadLog 'Ended before completion was confirmed. Check the last recorded step.'
    if ($backgroundLocked) { $backgroundLock.ReleaseMutex() }
    if ($backgroundLock) { $backgroundLock.Dispose() }
}
if ($JobFile -and -not $HistoryAttempt) { $null = Read-Host 'Press Enter to close' }
