function Write-DownloadState([string]$Path, $State) {
    $tempPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Compress | Set-Content -LiteralPath $tempPath -Encoding UTF8
        if ([IO.File]::Exists($Path)) {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        } else {
            [IO.File]::Move($tempPath, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
    }
}

function Assert-SaveLocation([string]$Destination, [long]$Size, [bool]$HasPartial) {
    $driveRoot = [IO.Path]::GetPathRoot($Destination)
    if ($driveRoot -match '^[A-Za-z]:\\$') {
        $drive = $null
        try { $drive = [IO.DriveInfo]::new($driveRoot) } catch [ArgumentException] {}
        if ($drive -and $drive.IsReady -and $drive.DriveType -in @([IO.DriveType]::Fixed, [IO.DriveType]::Removable) -and
            -not (Test-ReparsePath $Destination)) {
            if ($drive.DriveFormat -eq 'FAT32' -and $Size -ge 4GB) {
                throw 'FAT32 cannot store a file this large. Choose an NTFS or exFAT save folder.'
            }
            if (-not $HasPartial -and $Size -gt $drive.AvailableFreeSpace) {
                throw 'The save drive does not have enough free space. Free space or choose another save folder.'
            }
        }
    }
    $testPath = Join-Path $Destination ".dropbox-write-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $test = [IO.FileStream]::new($testPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $test.Dispose()
    } catch {
        throw "Windows could not create a file in the save folder. Check permissions, drive space and whether the drive is online. $($_.Exception.GetBaseException().Message)"
    }
}

function Test-ReparsePath([string]$Path) {
    $directory = [IO.DirectoryInfo]::new($Path)
    while ($directory.Parent) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
        $directory = $directory.Parent
    }
    return $false
}

function Get-FilePrefix([string]$Path, [int]$Count) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        return ,($reader.ReadBytes($Count))
    } finally {
        $stream.Dispose()
    }
}

function Confirm-DownloadedFile([string]$Path, $State) {
    $script:downloadStage = 'Verifying the completed download'
    Update-HistoryState 'Running' 'Verifying the completed download.'
    Add-DownloadLog 'Checking the downloaded file before giving it the final name.'
    Write-Host 'Verifying the completed download...'
    if ($State.FolderZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        try { $null = $archive.Entries.Count } finally { $archive.Dispose() }
    } else {
        $count = 4096
        if ($State.Prefix) { $count = [int]$State.SampleLength }
        if ($count -lt 1 -or $count -gt 4096) { throw 'Invalid verification checkpoint.' }
        $bytes = Get-FilePrefix $Path $count
        if ($State.Prefix -and (Get-BytesHash $bytes) -cne $State.Prefix) {
            throw 'Verification failed: the download begins differently from the Dropbox file. The partial was kept.'
        }
        if (-not $State.Prefix -and [Text.Encoding]::UTF8.GetString($bytes) -match '(?is)^\uFEFF?\s*(?:<!doctype\s+html\b|<html\b)') {
            throw 'Verification failed: the saved response is an HTML page. The partial was kept.'
        }
        if ($State.VerifyMp4 -and -not (Test-Mp4Header $bytes)) {
            throw 'Verification failed: the saved file does not have an MP4 header. The partial was kept.'
        }
    }
    if ($State.Checksum) {
        Add-DownloadLog 'Checking the full file against the supplied SHA-256 checksum.'
        Write-Host 'Checking SHA-256. Large files may take a while to read from disk.'
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $State.Checksum) {
            throw 'SHA-256 mismatch. The file was kept as a partial and was not published.'
        }
    }
}

function Test-CompleteCheckpoint([string]$Control, [long]$Size) {
    if ($Size -le 0 -or -not [IO.File]::Exists($Control)) { return $false }
    $record = Get-CheckpointProgress @{ Checkpoint=$Control }
    return [bool]($record -and $record.Total -eq $Size -and $record.Completed -eq $Size)
}

function Complete-SavedDownload([string]$Target, [string]$Marker, [string]$SourceKey, [string]$Checksum) {
    $state = Get-Content -LiteralPath $Marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.SourceKey -cne $SourceKey) {
        throw 'A completed transfer is waiting to be saved under this filename. Use its original link or choose a different output name.'
    }
    $name = [IO.Path]::GetFileName($Target)
    if ([string]$state.PartialName -notmatch ('^' + [regex]::Escape($name) + '\.[0-9a-f]{16}\.part$')) {
        throw 'The saved completion record has an invalid partial filename.'
    }
    $partial = Join-Path ([IO.Path]::GetDirectoryName($Target)) $state.PartialName
    $control = "$partial.aria2"
    $alreadyMoved = -not [IO.File]::Exists($partial) -and [IO.File]::Exists($Target)
    $candidate = if ($alreadyMoved) { $Target } else { $partial }
    if (-not [IO.File]::Exists($candidate) -or
        ([IO.File]::Exists($control) -and -not ($state.CompleteCheckpoint -and (Test-CompleteCheckpoint $control $state.Length)))) {
        throw 'The completed file is missing or has an unfinished aria2 checkpoint. Files were kept for inspection.'
    }
    $file = Get-Item -LiteralPath $candidate
    if ($file.Length -ne $state.Length -or [string]$file.LastWriteTimeUtc.Ticks -ne $state.LastWriteTicks) {
        throw 'The completed partial changed after transfer. It was kept for inspection.'
    }
    if ($Checksum -and $Checksum -ne $state.Checksum) {
        $state.Checksum = $Checksum
    }
    Confirm-DownloadedFile $candidate $state
    $script:downloadStage = 'Saving the verified file'
    Update-HistoryState 'Running' 'Saving the verified file under its final name.'
    Write-Host 'Saving the verified file in its destination folder...'
    for ($attempt = 1; -not $alreadyMoved -and $attempt -le 4; $attempt++) {
        try {
            [IO.File]::Move($partial, $Target)
            break
        } catch {
            $win32 = $_.Exception.GetBaseException().HResult -band 0xFFFF
            if (Test-Path -LiteralPath $Target) {
                throw 'Another file already exists at the final path. The completed partial was kept.'
            }
            if ($win32 -notin @(5, 32, 33) -or $attempt -eq 4) {
                throw "The download finished, but Windows could not rename it (error $win32). The completed file was kept. Close apps using it, then Start / Resume with the same link and name to save it without downloading again."
            }
            Add-DownloadLog 'Windows had the completed file locked. Retrying the final rename.'
            Write-Host 'Windows has the completed file locked. Retrying the final rename...' -ForegroundColor Yellow
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    $savedSize = [long]$state.Length
    Update-HistoryState 'Completed' 'Download complete. The verified file was saved.'
    Remove-Item -LiteralPath $Marker, "$partial.resume.json", $control -ErrorAction SilentlyContinue
    Add-DownloadLog ("Saved the final file. Verified size: {0:N2} GiB ({1:N0} bytes)." -f ($savedSize / 1GB), $savedSize)
    Finish-DownloadLog 'Download complete. The verified file was saved under its final name.'
    Show-DownloadNotification 'Completed' 'File verified and saved.'
    Write-Host "Download complete: $Target" -ForegroundColor Green
}

function Find-RefreshedPartial([string]$Directory, [string]$Name, [string]$SourceKey, $Probe) {
    $pattern = '^' + [regex]::Escape($Name) + '\.[0-9a-f]{16}\.part\.resume\.json$'
    $existing = @(
        Get-ChildItem -LiteralPath $Directory -File -Filter '*.resume.json' | Where-Object { $_.Name -match $pattern } |
            ForEach-Object {
                $state = $null
                try { $state = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
                catch { Write-Verbose 'Ignoring an unreadable resume record.' }
                $partial = $_.FullName.Substring(0, $_.FullName.Length - '.resume.json'.Length)
                if ($state.SourceKey -ceq $SourceKey -and
                    ((Test-Path -LiteralPath $partial) -or (Test-Path -LiteralPath "$partial.aria2"))) {
                    @{ Path = $partial; State = $state }
                }
            }
    )
    $matchesFound = @(
        $existing | Where-Object {
            $Probe.Tag -and $_.State.Tag -ceq $Probe.Tag -and
            $_.State.Size -eq $Probe.Size -and $_.State.Prefix -eq $Probe.Prefix -and
            (Test-Path -LiteralPath $_.Path -PathType Leaf) -and
            (Test-Path -LiteralPath "$($_.Path).aria2" -PathType Leaf)
        }
    )
    if ($matchesFound.Count -gt 1) { throw 'Multiple matching checkpoints exist for this filename. Use the exact link that started the desired download.' }
    if ($matchesFound.Count -eq 1) { return [IO.Path]::GetFileName($matchesFound[0].Path) }
    if ($existing.Count) {
        throw 'A checkpoint exists, but Dropbox did not prove the refreshed link is the same file. Use the original link or choose a new output name. Saved files were kept.'
    }
}
