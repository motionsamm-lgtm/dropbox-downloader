$script:historyState = $null
$script:historyAttemptPath = $null

function Get-HistoryDirectory {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DropboxDownloader\History'
}

function Get-HistoryLogPath([string]$JobDirectory) {
    return Join-Path $JobDirectory 'download.log.txt'
}

function Read-HistoryState([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 3 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try { return ConvertFrom-Json -InputObject $lines[$i] -ErrorAction Stop }
        catch { Write-Verbose 'Ignoring an unfinished history line.' }
    }
}

function Add-HistoryState([string]$Path, $State) {
    $record = $State
    if ($State.IsFolder -and $State -is [Collections.IDictionary]) {
        $record = @{}
        foreach ($key in $State.Keys) { if ($key -ne 'Children') { $record[$key] = $State[$key] } }
        # Keep changing child rows in one replaceable snapshot, rather than
        # appending the entire file list to History on every progress update.
        Write-DownloadState (Join-Path ([IO.Path]::GetDirectoryName($Path)) 'children-live.json') @($State.Children)
    }
    $record | ConvertTo-Json -Compress -Depth 12 | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Update-HistoryState([string]$Status, [string]$Message, [int]$Port = 0, [string]$Token = '') {
    if (-not $script:historyState) { return }
    $script:historyState.Status = $Status
    $script:historyState.Message = $Message
    $script:historyState.Port = $Port
    $script:historyState.Token = $Token
    $script:historyState.Updated = [DateTime]::UtcNow.ToString('o')
    try { Add-HistoryState $script:historyAttemptPath $script:historyState }
    catch { Write-Warning 'Download history could not be updated.' }
}

function Test-HistoryProcess([int]$ProcessId, [string]$Started) {
    if (-not $ProcessId -or -not $Started) { return $false }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try { return (-not $process.HasExited -and [string]$process.StartTime.ToUniversalTime().Ticks -eq $Started) }
    catch { return $false }
    finally { $process.Dispose() }
}

function Get-HistoryStatus($State) {
    if (-not $State) { return 'Interrupted' }
    if ($State.Status -notin @('Starting', 'Running')) { return [string]$State.Status }
    if ((Test-HistoryProcess $State.ProcessId $State.ProcessStart) -or
        (Test-HistoryProcess $State.EngineId $State.EngineStart)) { return 'Running' }
    if ($State.Status -eq 'Starting' -and [DateTime]::UtcNow -lt ([DateTime]::Parse($State.Updated).ToUniversalTime().AddSeconds(15))) {
        return 'Starting'
    }
    return 'Interrupted'
}

function Test-DownloadPause {
    return (($script:historyAttemptPath -and [IO.File]::Exists($script:historyAttemptPath + '.pause')) -or
        ($script:folderParentId -and -not (Test-HistoryProcess $script:folderParentId $script:folderParentStart)))
}

function Assert-DownloadActive {
    if (Test-DownloadPause) { throw [OperationCanceledException]::new('Download paused by you. Saved progress was kept.') }
}

function Wait-DownloadRetry([int]$Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-DownloadActive
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
}

function Add-OwnedDownloadFile([string]$Path) {
    if (-not $script:historyAttemptPath) { return }
    $record = @{ Path = [IO.Path]::GetFullPath($Path) }
    $ledger = Join-Path ([IO.Path]::GetDirectoryName($script:historyAttemptPath)) 'owned-files.jsonl'
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $ledger -Encoding UTF8
}

function Assert-NoDownloadLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'A saved path contains a link or junction. Inspect it before deleting files manually.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-OwnedDownloadFiles([string]$Directory, $State) {
    $files = @()
    $manifestPath = Join-Path $Directory 'folder-manifest.json'
    if ([IO.File]::Exists($manifestPath)) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in $manifest.Entries) {
            if ($entry.Id -notmatch '^[a-f0-9]{32}$') { throw 'The saved folder manifest is damaged.' }
            $childDirectory = Join-Path (Join-Path $Directory 'children') $entry.Id
            $last = Get-ChildItem -LiteralPath $childDirectory -File -Filter 'attempt-*.jsonl' | Sort-Object Name -Descending | Select-Object -First 1
            $childState = if ($last) { Read-HistoryState $last.FullName } else { $null }
            $files += @(Get-OwnedDownloadFiles $childDirectory $childState)
        }
    }
    $ledger = Join-Path $Directory 'owned-files.jsonl'
    if ([IO.File]::Exists($ledger)) {
        foreach ($line in Get-Content -LiteralPath $ledger -Encoding UTF8) {
            try { $files += [string](ConvertFrom-Json -InputObject $line -ErrorAction Stop).Path }
            catch { throw 'The saved-file list is damaged. No deletion started; inspect the saved-data folder.' }
        }
    }
    # Exact paths from older releases; never a destination-folder wildcard.
    if ($State.Checkpoint -and ([string]$State.Checkpoint).EndsWith('.part.aria2')) {
        $partial = ([string]$State.Checkpoint).Substring(0, ([string]$State.Checkpoint).Length - 6)
        $files += @($partial, [string]$State.Checkpoint, ($partial + '.resume.json'))
    }
    if ($State.Output -and $State.Status -eq 'Completed' -and [IO.File]::Exists([string]$State.Output)) { $files += [string]$State.Output }
    $result = @()
    foreach ($file in ($files | Where-Object { $_ } | Select-Object -Unique)) {
        Assert-NoDownloadLinks $file
        if ([IO.Directory]::Exists($file)) { throw 'A tracked file became a folder. No deletion started.' }
        if ([IO.File]::Exists($file)) { $result += $file }
    }
    return $result
}

function Invoke-TransferRpc($State, [string]$Method, [object[]]$Arguments) {
    if (-not $State.Port -or -not $State.Token) { return }
    try {
        $request = [Net.WebRequest]::Create("http://127.0.0.1:$($State.Port)/jsonrpc")
        $request.Proxy = $null
        $request.ServicePoint.Expect100Continue = $false
        $request.KeepAlive = $false
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $request.Timeout = 850
        $request.ReadWriteTimeout = 850
        $parameters = @("token:$($State.Token)")
        if ($Arguments.Count -gt 0) { $parameters += $Arguments }
        $payload = @{
            jsonrpc = '2.0'
            id = 'download'
            method = $Method
            params = $parameters
        } | ConvertTo-Json -Compress -Depth 4
        $data = [Text.Encoding]::UTF8.GetBytes($payload)
        $request.ContentLength = $data.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($data, 0, $data.Length) } finally { $stream.Dispose() }
        $response = $request.GetResponse()
        try {
            $reader = [IO.StreamReader]::new($response.GetResponseStream())
            try { $reply = $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
        } finally { $response.Dispose() }
        if ($null -ne $reply.result) { return $reply.result }
    } catch { Write-Verbose 'Live progress is unavailable while aria2 starts or retries.' }
}

function Get-LiveTransfer($State) {
    return Invoke-TransferRpc $State 'aria2.tellStatus' @([string]$State.Gid)
}

function Quote-TransferArgument([string]$Value) {
    # Windows native argv rules for quotes and trailing backslashes.
    return '"' + [regex]::Replace($Value, '(\\*)("|$)', '$1$1$2').Replace('"', '\"') + '"'
}

function Read-CheckpointNumber([byte[]]$Bytes, [int]$Offset, [int]$Count) {
    $number = 0L
    for ($i = 0; $i -lt $Count; $i++) { $number = $number * 256L + $Bytes[$Offset + $i] }
    return $number
}

function Get-CheckpointProgress($State) {
    try {
        $path = $State.Checkpoint
        if (-not $path -and $State.Output) {
            # Older workers did not record the exact path. Use only an unambiguous match.
            $name = [regex]::Escape([IO.Path]::GetFileName($State.Output))
            $candidates = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($State.Output)) -File -Filter '*.aria2' |
                Where-Object { $_.Name -match "^$name\.[0-9a-f]{16}\.part\.aria2$" })
            if ($candidates.Count -eq 1) { $path = $candidates[0].FullName }
        }
        if (-not $path) { return }
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($file.Length -lt 34 -or $file.Length -gt 1048576) { return }
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $reader = [IO.BinaryReader]::new($stream)
            $bytes = $reader.ReadBytes([int]$file.Length)
        } finally { $stream.Dispose() }
        if ($bytes.Length -lt 34 -or $bytes[0] -ne 0 -or $bytes[1] -ne 1) { return }
        $hashLength = Read-CheckpointNumber $bytes 6 4
        if ($hashLength -ne 0) { return } # Only aria2 v1 HTTP control files.
        $pieceLength = Read-CheckpointNumber $bytes 10 4
        $total = Read-CheckpointNumber $bytes 14 8
        $bitfieldLength = Read-CheckpointNumber $bytes 30 4
        if ($pieceLength -le 0 -or $total -le 0 -or $bitfieldLength -gt $bytes.Length - 34) { return }
        $pieces = [long][Math]::Ceiling($total / [double]$pieceLength)
        if ([Math]::Ceiling($pieces / 8.0) -ne $bitfieldLength) { return }
        $complete = 0L
        for ($index = 0; $index -lt $bitfieldLength; $index++) {
            $mask = $bytes[34 + $index]
            if (-not $mask) { continue }
            for ($bit = 0; $bit -lt 8; $bit++) {
                $piece = $index * 8 + $bit
                if ($piece -lt $pieces -and ($mask -band (128 -shr $bit))) {
                    $complete += [Math]::Min($pieceLength, $total - $piece * $pieceLength)
                }
            }
        }
        return @{ Total = $total; Completed = $complete; Saved = $file.LastWriteTimeUtc; Path = $path }
    } catch { Write-Verbose 'The checkpoint is unavailable or currently being saved.' }
}

function Get-ProgressMetrics($Record) {
    $transfer = Get-LiveTransfer $Record.State
    if ([long]$transfer.totalLength -gt 0) {
        return @{
            Total = [long]$transfer.totalLength
            Completed = [long]$transfer.completedLength
            Speed = [long]$transfer.downloadSpeed
            Connections = $transfer.connections
            Estimated = $false
        }
    }
    $checkpoint = Get-CheckpointProgress $Record.State
    if (-not $checkpoint) { return }
    $previous = $Record.CheckpointSample
    if (-not $previous -or $previous.Path -ne $checkpoint.Path) {
        $Record.CheckpointSample = $checkpoint
        $Record.CheckpointSpeed = 0
    } elseif ($checkpoint.Saved -gt $previous.Saved) {
        $seconds = ($checkpoint.Saved - $previous.Saved).TotalSeconds
        $Record.CheckpointSpeed = [Math]::Max(0, ($checkpoint.Completed - $previous.Completed) / $seconds)
        $Record.CheckpointSample = $checkpoint
    }
    $speed = 0
    if (([DateTime]::UtcNow - $checkpoint.Saved).TotalSeconds -lt 12) { $speed = $Record.CheckpointSpeed }
    return @{ Total = $checkpoint.Total; Completed = $checkpoint.Completed; Speed = $speed; Estimated = $true }
}

function Get-DropboxLinkKind([string]$Link) {
    $uri = $null
    if (-not [Uri]::TryCreate($Link.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or -not $uri.IsDefaultPort) { return }
    if ($uri.Host -match '^(?:[a-z0-9-]+\.)*dl\.dropboxusercontent\.com$') { return 'File' }
    if ($uri.Host -notin @('dropbox.com','www.dropbox.com')) { return }
    if ($uri.AbsolutePath -match '^/(scl/fi|s)/[^/]+/[^/]+$' -or
        $uri.AbsolutePath -match '^/(?:scl/fo|sh)/[^/]+/[^/]+/(?:[^/]+/)*[^/]+$') { return 'File' }
    if ($uri.AbsolutePath -match '^/(scl/fo|sh)/[^/]+/[^/]+/?$' -and
        $uri.Query -notmatch '(?:^\?|&)(?:preview|select)=') { return 'Folder' }
}

function Convert-AriaSize([string]$Value) {
    $match = [regex]::Match($Value, '^(\d+(?:\.\d+)?)([KMGT]?i?B)?$')
    if (-not $match.Success) { return 0L }
    $power = switch -Regex ($match.Groups[2].Value) {
        '^K' {1}; '^M' {2}; '^G' {3}; '^T' {4}; default {0}
    }
    return [long]([double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * [Math]::Pow(1024,$power))
}

function Find-TransferReadout([string]$Text) {
    $samples = [regex]::Matches($Text, '\[#[0-9a-f]+\s+([^/\s]+)/(\d+(?:\.\d+)?(?:[KMGT]?i?B)?)(?:\((\d+)%\))?\s+CN:(\d+)\s+DL:([^\s\]]+)[^\r\n\]]*\]', 'IgnoreCase')
    if (-not $samples.Count) { return }
    $sample = $samples[$samples.Count - 1]
    $total = Convert-AriaSize $sample.Groups[2].Value
    $done = Convert-AriaSize $sample.Groups[1].Value
    if ($sample.Groups[3].Success -and $sample.Groups[1].Value -match '[KMGT]') {
        $percent = [int]$sample.Groups[3].Value
        $done = [long]($total * $percent / 100.0)
    }
    return @{End=($sample.Index+$sample.Length); Total=$total; Completed=$done; Speed=(Convert-AriaSize $sample.Groups[5].Value); Connections=[int]$sample.Groups[4].Value}
}

function Invoke-RecordedTransfer([string]$Executable, [string[]]$Arguments) {
    Assert-DownloadActive
    # Private loopback RPC permits a graceful shutdown: aria2 saves its control
    # file before the worker acknowledges Paused. It is never network exposed.
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $token = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    $Arguments += @('--enable-rpc=true', '--rpc-listen-all=false', '--rpc-allow-origin-all=false',
        "--rpc-listen-port=$port", "--rpc-secret=$token")
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = ($Arguments | ForEach-Object { Quote-TransferArgument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $engine = [Diagnostics.Process]::Start($start)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $buffer = New-Object char[] 4096
    $tail = ''
    $latest = $null
    $lastDisplay = -1000
    $lastNote = -30000
    $lastPercent = -10
    $lastConnections = -1
    $reportedSuccess = $false
    $sawResultsTable = $false
    $record = @{ State = $script:historyState }
    $pauseClock = $null
    $lastShutdown = -5000
    $terminalCode = $null
    $lastRpc = -1000
    try {
        if (-not $engine.HasExited) {
            $script:historyState.EngineId = $engine.Id
            $script:historyState.EngineStart = [string]$engine.StartTime.ToUniversalTime().Ticks
            Update-HistoryState 'Running' $script:historyState.Message
        }
        $read = $engine.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        while ($true) {
            if ($clock.ElapsedMilliseconds - $lastRpc -ge 1000 -and -not $engine.HasExited) {
                $lastRpc = $clock.ElapsedMilliseconds
                $stats = Invoke-TransferRpc @{Port=$port;Token=$token} 'aria2.getGlobalStat' @()
                if ($stats -and [int]$stats.numStopped -gt 0 -and [int]$stats.numActive -eq 0 -and [int]$stats.numWaiting -eq 0) {
                    $stopped = @(Invoke-TransferRpc @{Port=$port;Token=$token} 'aria2.tellStopped' @(0, 10))
                    if ($stopped.Count -eq 1 -and $stopped[0].status -in @('complete','error','removed')) {
                        $terminalCode = if ($stopped[0].status -eq 'complete') { 0 } elseif ($stopped[0].errorCode) { [int]$stopped[0].errorCode } else { 1 }
                        $reportedSuccess = $stopped[0].status -eq 'complete'
                        $null = Invoke-TransferRpc @{Port=$port;Token=$token} 'aria2.shutdown' @()
                    }
                }
            }
            if (Test-DownloadPause) {
                if (-not $pauseClock) {
                    $pauseClock = [Diagnostics.Stopwatch]::StartNew()
                    Update-HistoryState 'Pausing' 'Pausing. Waiting for the engine to save its checkpoint.' $port $token
                    Add-DownloadLog 'Pause requested. Stopping the engine and saving progress; automatic retries are cancelled.'
                }
                if ($pauseClock.ElapsedMilliseconds - $lastShutdown -ge 1000 -and -not $engine.HasExited) {
                    $method = if ($pauseClock.Elapsed.TotalSeconds -ge 15) { 'aria2.forceShutdown' } else { 'aria2.shutdown' }
                    $null = Invoke-TransferRpc @{Port=$port;Token=$token} $method @()
                    $lastShutdown = $pauseClock.ElapsedMilliseconds
                }
                if ($pauseClock.Elapsed.TotalSeconds -ge 30 -and -not $engine.HasExited) {
                    Add-DownloadLog 'The engine did not stop within 30 seconds. Stopped it; Resume will check the last saved checkpoint.'
                    $engine.Kill()
                }
            }
            if ($read -and $read.Wait(250)) {
                $count = $read.Result
                if ($count -eq 0) {
                    $read = $null
                } else {
                    $tail += [string]::new($buffer,0,$count)
                    if ($tail -match '(?im)^Download Results:[ \t]*\r?$') { $sawResultsTable = $true }
                    if ($sawResultsTable -and $tail -match '(?im)^[ \t]*[0-9a-f]{6,16}\|[ \t]*OK[ \t]*\|[^\r\n]*[\r\n]') {
                        $reportedSuccess = $true
                    }
                    $sample = Find-TransferReadout $tail
                    if ($sample) {
                        $tail = $tail.Substring($sample.End)
                        $latest = $sample
                        $latest.Seen = $clock.ElapsedMilliseconds
                    }
                    if ($tail.Length -gt 2048) { $tail = $tail.Substring($tail.Length-2048) }
                    # Keep only a possible incomplete last readout, so old samples do not appear fresh.
                    $boundary = [Math]::Max($tail.LastIndexOf([char]13),$tail.LastIndexOf([char]10))
                    if ($boundary -ge 0) { $tail = $tail.Substring($boundary+1) }
                    $read = $engine.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
                }
            }
            if (-not $read -and $engine.WaitForExit(250)) { break }
            $elapsed = $clock.ElapsedMilliseconds
            if ($elapsed - $lastDisplay -lt 1000) { continue }
            $lastDisplay = $elapsed
            $metrics = $latest
            if (-not $latest -or $elapsed - $latest.Seen -gt 5000 -or $latest.Total -le 0) {
                $metrics = Get-ProgressMetrics $record
                if (-not $metrics -and $latest -and $elapsed - $latest.Seen -le 5000) { $metrics = $latest }
            }
            $script:historyState.Metrics = $metrics
            if (-not $pauseClock) { Update-HistoryState 'Running' $script:historyState.Message }
            if ($metrics -and $metrics.Total -gt 0) {
                $percent = [int][Math]::Floor(100 * $metrics.Completed / [double]$metrics.Total)
                if ($null -ne $metrics.Connections -and $metrics.Connections -ne $lastConnections) {
                    Add-DownloadLog "Active connections: $($metrics.Connections)."
                    $lastConnections = $metrics.Connections
                }
                if ($elapsed - $lastNote -ge 30000 -or $percent -ge $lastPercent + 10) {
                    Add-DownloadLog ('Progress: {0}% ({1:N2} of {2:N2} GiB); {3:N1} MiB/s; {4} connections.' -f
                        $percent, ($metrics.Completed/1GB), ($metrics.Total/1GB), ($metrics.Speed/1MB), $(if ($null -ne $metrics.Connections) {$metrics.Connections} else {'unknown'}))
                    $lastNote = $elapsed
                    $lastPercent = $percent
                }
            } elseif ($elapsed - $lastNote -ge 30000) {
                Add-DownloadLog 'Transfer is active. Dropbox has not reported measurable progress yet.'
                $lastNote = $elapsed
            }
        }
        $exitCode = if ($null -ne $terminalCode) { $terminalCode } else { $engine.ExitCode }
        if ($reportedSuccess -or ($null -ne $terminalCode -and $terminalCode -eq 0) -or (-not $pauseClock -and $exitCode -eq 0)) {
            $script:historyState.EngineFinished = $true
        }
        Assert-DownloadActive
        Add-DownloadLog ("Transfer attempt ended after {0:hh\:mm\:ss}. Engine exit code: {1}." -f $clock.Elapsed,$exitCode)
        if ($exitCode -eq 0) {
            $script:historyState.EngineFinished = $true
            Update-HistoryState 'Running' 'All bytes received. Checking the saved file.'
        }
        return @{ExitCode=$exitCode; ReportedSuccess=$reportedSuccess}
    } finally {
        $engine.Dispose()
        $script:historyState.EngineId = 0
        $script:historyState.EngineStart = ''
        $script:historyState.Metrics = $null
    }
}

function Get-RecordedCompletion($State) {
    if ($State.SharedSummary -or -not $State.Output -or -not [IO.File]::Exists([string]$State.Output) -or
        -not $State.SummaryPath -or -not [IO.File]::Exists([string]$State.SummaryPath)) { return }
    $line = Get-Content -LiteralPath $State.SummaryPath -Tail 30 -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\[[^\]]+\] Result: Download complete\. The verified file was saved under its final name\.$' } |
        Select-Object -Last 1
    if ($line -match '^\[([^\]]+)\]') { return $Matches[1] }
}

function Test-PriorEngineCompletion([string]$Attempt, [string]$Control) {
    if (-not $Attempt) { return $false }
    $prior = Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Attempt)) -File -Filter 'attempt-*.jsonl' |
        Where-Object FullName -ne $Attempt | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $prior) { return $false }
    $state = Read-HistoryState $prior.FullName
    if (-not $state -or $state.Checkpoint -ne $Control) { return $false }
    $partial = $Control.Substring(0,$Control.Length-'.aria2'.Length)
    $file = Get-Item -LiteralPath $partial -ErrorAction SilentlyContinue
    if (-not $file -or -not $state.Updated -or
        $file.LastWriteTimeUtc -gt ([DateTime]::Parse($state.Updated).ToUniversalTime().AddSeconds(2))) { return $false }
    if ($state.SharedSummary) { return ($state.EngineFinished -eq $true) }
    if (-not $state.SummaryPath -or -not [IO.File]::Exists([string]$state.SummaryPath)) { return $false }
    return [bool](Get-Content -LiteralPath $state.SummaryPath -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '(The download engine finished receiving the file\.|Engine exit code: 0\.)$' } |
        Select-Object -First 1)
}
