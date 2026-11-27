# Anonymous shared-link adapter. The Dropbox web endpoint is unversioned;
# reject incomplete/unknown responses instead of silently claiming success.
function Get-PublicFolderAddress([string]$Link) {
    $uri=$null
    if (-not [Uri]::TryCreate($Link,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.Host -notin @('dropbox.com','www.dropbox.com') -or $uri.UserInfo -or -not $uri.IsDefaultPort) {
        throw 'Use an HTTPS Dropbox shared-folder link.'
    }
    $parts=@($uri.AbsolutePath.Split('/') | Where-Object { $_ })
    $modern=$parts.Count -ge 4 -and $parts[0] -eq 'scl' -and $parts[1] -eq 'fo'
    $legacy=$parts.Count -ge 3 -and $parts[0] -eq 'sh'
    if (-not $modern -and -not $legacy) { throw 'This is not a shared-folder link.' }
    $query=@{}
    foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
        $kv=$pair.Split('=',2)
        if ($kv.Length -eq 2) { $query[[Uri]::UnescapeDataString($kv[0])]=[Uri]::UnescapeDataString($kv[1]) }
    }
    $offset=if($modern){4}else{3}
    $subpath=if($parts.Count -gt $offset){'/'+(($parts[$offset..($parts.Count-1)] | ForEach-Object {[Uri]::UnescapeDataString($_)}) -join '/')}else{''}
    return @{Url=$uri.AbsoluteUri.Replace('https://dropbox.com/','https://www.dropbox.com/');Key=$parts[$offset-2];Hash=$parts[$offset-1];Rlkey=[string]$query['rlkey'];Subpath=$subpath}
}
function Convert-FolderComponent([string]$Name) {
    if (-not $Name -or $Name -in @('.','..') -or $Name -match '[/\\\x00-\x1f\x7f]') { throw 'Dropbox returned an unsafe filename.' }
    $local=[regex]::Replace($Name.Normalize(), '[~<>:"|?*]', [Text.RegularExpressions.MatchEvaluator]{param($m) '~'+([int][char]$m.Value).ToString('x4')})
    $local=[regex]::Replace($local,'[. ]+$',[Text.RegularExpressions.MatchEvaluator]{param($m) (($m.Value.ToCharArray() | ForEach-Object {'~'+([int]$_).ToString('x4')}) -join '')})
    if($local -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'){$local='~reserved-'+$local}
    if([Text.Encoding]::UTF8.GetByteCount($local) -gt 100){$local=$local.Substring(0,[Math]::Min(40,$local.Length))+'~'+(Get-TextHash $Name).Substring(0,16)}
    return $local
}
function Get-PublicFolderManifest([string]$Link) {
    $root=Get-PublicFolderAddress $Link
    $session=[Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $page=Invoke-WebRequest -UseBasicParsing -Uri $root.Url -WebSession $session -TimeoutSec 30 -MaximumRedirection 0
    $token=$session.Cookies.GetCookies([Uri]'https://www.dropbox.com/')['__Host-js_csrf']
    if(-not $token){$token=$session.Cookies.GetCookies([Uri]'https://www.dropbox.com/')['t']}
    if(-not $token){throw 'Dropbox requires sign-in or its public folder interface changed. GOB could not confirm a full file list.'}
    $queue=[Collections.Generic.List[object]]::new()
    $queue.Add(@{Hash=$root.Hash;Subpath=$root.Subpath;Remote='';Local=''})
    $files=[Collections.Generic.List[object]]::new();$directories=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $locals=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for($index=0;$index -lt $queue.Count;$index++) {
        $dir=$queue[$index];$voucher='';$vouchers=[Collections.Generic.HashSet[string]]::new();$count=0
        do {
            Assert-DownloadActive
            $fields=@{t=$token.Value;link_key=$root.Key;secure_hash=$dir.Hash;rlkey=$root.Rlkey;sub_path=$dir.Subpath;link_type='s'}
            if($voucher){$fields.voucher=$voucher}
            $form=($fields.GetEnumerator() | ForEach-Object {[Uri]::EscapeDataString([string]$_.Key)+'='+[Uri]::EscapeDataString([string]$_.Value)}) -join '&'
            $response=$null
            for($retry=0;$retry -lt 4;$retry++) {
                try {
                    $response=Invoke-WebRequest -UseBasicParsing -Uri 'https://www.dropbox.com/list_shared_link_folder_entries' -Method Post -Body $form -ContentType 'application/x-www-form-urlencoded' -WebSession $session -Headers @{'X-Requested-With'='XMLHttpRequest';Origin='https://www.dropbox.com';Referer=$root.Url} -TimeoutSec 30 -MaximumRedirection 0
                    break
                } catch {
                    $code=if($_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{0}
                    if($retry -eq 3 -or $code -notin @(400,403,408,429,500,502,503,504)){throw 'Dropbox refused the public folder listing. Check the share permissions and try again. Saved downloads were kept.'}
                    $wait=[Math]::Min(120,5*[Math]::Pow(2,$retry))
                    $retryAfter=$_.Exception.Response.Headers['Retry-After']
                    $seconds=0;if([int]::TryParse($retryAfter,[ref]$seconds)){$wait=[Math]::Min(120,[Math]::Max(5,$seconds))}
                    Add-DownloadLog "Folder listing will retry after HTTP $code in $wait seconds."
                    Wait-DownloadRetry $wait
                }
            }
            if($response.Content.Length -gt 8388608){throw 'Dropbox returned an oversized folder page. No files were started.'}
            try{$data=ConvertFrom-Json -InputObject $response.Content -ErrorAction Stop}catch{throw 'Dropbox returned a web page instead of the expected folder listing.'}
            if($null -eq $data.entries -or $data.has_more_entries -isnot [bool]){throw 'Dropbox returned an unknown folder response. GOB cannot confirm a complete list.'}
            foreach($entry in $data.entries) {
                if($entry.is_dir -isnot [bool]){throw 'Dropbox omitted a file type from the folder listing.'}
                $component=Convert-FolderComponent ([string]$entry.filename)
                $remote=(@($dir.Remote,$entry.filename) | Where-Object {$_}) -join '/'
                $local=(@($dir.Local,$component) | Where-Object {$_}) -join '/'
                if(-not $seen.Add($remote)){throw 'Dropbox repeated an entry. Retry to get a consistent folder snapshot.'}
                if($locals.Contains($local)){$local+='~'+(Get-TextHash $remote).Substring(0,12)}
                if(-not $locals.Add($local)){throw 'Two Dropbox filenames map to the same local path.'}
                if($seen.Count -gt 100000){throw 'This folder exceeds the 100,000-entry safety limit.'}
                $address=Get-PublicFolderAddress ([string]$entry.href)
                if($address.Key -cne $root.Key){throw 'Dropbox returned an entry outside the shared folder.'}
                $count++
                if($entry.is_dir) {
                    if($remote.Split('/').Count -gt 128){throw 'This folder is nested more than 128 levels deep.'}
                    $directories.Add(@{Remote=$remote;Local=$local})
                    $queue.Add(@{Hash=$address.Hash;Subpath=('/'+((@($root.Subpath.Trim('/'),$remote) | Where-Object {$_}) -join '/'));Remote=$remote;Local=$local})
                } else {
                    if($null -eq $entry.bytes -or [double]$entry.bytes -lt 0 -or [double]$entry.bytes -ne [long]$entry.bytes){throw 'Dropbox omitted an exact file size.'}
                    $files.Add(@{Remote=$remote;Local=$local;Url=$address.Url;Size=[long]$entry.bytes})
                }
            }
            Update-HistoryState 'Running' "Listing folder: found $($files.Count) files and $($directories.Count) subfolders."
            if(-not $data.has_more_entries) {
                if($null -ne $data.total_num_entries -and [long]$data.total_num_entries -ne $count){throw 'Dropbox changed the folder count during listing. Retry for a complete snapshot.'}
                break
            }
            $voucher=[string]$data.next_request_voucher
            if(-not $voucher -or -not $vouchers.Add($voucher) -or $vouchers.Count -gt 4096){throw 'Dropbox did not provide a usable next folder page. The listing was not marked complete.'}
        }while($true)
    }
    return @{Files=@($files.ToArray());Directories=@($directories.ToArray())}
}

function Test-FolderZip([string]$Path,$Entries) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $actual=@($archive.Entries | Where-Object {-not $_.FullName.EndsWith('/')})
        if($actual.Count -ne @($Entries).Count){return $false}
        $expected=@{}
        foreach($entry in $Entries){$expected[[string]$entry.Local.Replace('\','/').ToLowerInvariant()]=[long]$entry.Size}
        foreach($item in $actual){$key=[string]$item.FullName.Replace('\','/').ToLowerInvariant();if(-not $expected.ContainsKey($key) -or [long]$item.Length -ne $expected[$key]){return $false};[void]$expected.Remove($key)}
        return $expected.Count -eq 0
    } finally {$archive.Dispose()}
}

function Complete-FolderZip($Job,$Manifest,[string]$RootPath,[string]$ArchivePath,[string]$JobDirectory) {
    $entries=@($Manifest.Entries)
    $expected=@{};$expectedDirectories=@{}
    foreach($entry in $entries){
        if($entry.Local -match '(^|[/\\])\.\.?([/\\]|$)' -or [IO.Path]::IsPathRooted($entry.Local)){throw 'The folder manifest contains an unsafe path. No ZIP was created.'}
        $expected[[string]$entry.Local.Replace('\','/').ToLowerInvariant()]=[long]$entry.Size
        $parts=@($entry.Local.Replace('\','/').Split('/'))
        for($i=1;$i -lt $parts.Count;$i++){$expectedDirectories[($parts[0..($i-1)] -join '/').ToLowerInvariant()]=$true}
        $file=Join-Path $RootPath $entry.Local.Replace('/',[IO.Path]::DirectorySeparatorChar)
        Assert-NoDownloadLinks $file
        if(-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -ne [long]$entry.Size){throw 'A folder file changed or is missing. No ZIP was created; the other files were kept.'}
    }
    $actualFiles=@(Get-ChildItem -LiteralPath $RootPath -File -Recurse -Force)
    if($actualFiles.Count -ne $expected.Count){throw 'The download folder contains extra or missing files. No ZIP was created; your files were kept.'}
    foreach($item in $actualFiles){
        Assert-NoDownloadLinks $item.FullName
        $relative=$item.FullName.Substring($RootPath.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Replace('\','/').ToLowerInvariant()
        if(-not $expected.ContainsKey($relative) -or [long]$item.Length -ne $expected[$relative]){throw 'The download folder contains extra or changed files. No ZIP was created; your files were kept.'}
    }
    foreach($dir in $Manifest.Directories){
        $relative=[string]$dir.Local.Replace('\','/').ToLowerInvariant()
        if($relative -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted($relative)){throw 'The folder manifest contains an unsafe directory. No ZIP was created.'}
        $parts=@($relative.Split('/'))
        for($i=1;$i -le $parts.Count;$i++){$expectedDirectories[($parts[0..($i-1)] -join '/') ]=$true}
    }
    $actualDirectories=@(Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force)
    if($actualDirectories.Count -ne $expectedDirectories.Count){throw 'The download folder contains extra or missing directories. No ZIP was created; your files were kept.'}
    foreach($dir in @(Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force)){
        Assert-NoDownloadLinks $dir.FullName
        $relative=$dir.FullName.Substring($RootPath.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Replace('\','/')
        if($relative -match '(^|/)\.\.?(/|$)' -or -not $expectedDirectories.ContainsKey($relative.ToLowerInvariant())){throw 'The download folder contains an unsafe or unexpected directory. No ZIP was created.'}
    }
    $total=($entries | Measure-Object -Property Size -Sum).Sum
    if($null -eq $total){$total=0L}
    Assert-SaveLocation $Job.Destination ([long]$total) $false
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $jobKey=[IO.Path]::GetFileName($JobDirectory)
    $temporary="$ArchivePath.GOB-$jobKey.assembling.zip"
    if([IO.File]::Exists($temporary)){
        Assert-NoDownloadLinks $temporary
        [IO.File]::Delete($temporary)
    }
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory($RootPath,$temporary,[IO.Compression.CompressionLevel]::Optimal,$false)
        if(-not (Test-FolderZip $temporary $entries)){throw 'The assembled ZIP did not match the downloaded folder. The source files were kept.'}
        Assert-DownloadActive
        if([IO.File]::Exists($ArchivePath) -or [IO.Directory]::Exists($ArchivePath)){throw 'A file already exists at the ZIP destination. Your downloaded folder was kept.'}
        $archiveHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        Assert-DownloadActive
        Write-DownloadState (Join-Path $JobDirectory 'folder-zip-ready.json') @{ Hash = $archiveHash }
        [IO.File]::Move($temporary,$ArchivePath)
        $script:historyState.Output=$ArchivePath
        try {
            foreach($entry in $entries){[IO.File]::Delete((Join-Path $RootPath $entry.Local.Replace('/',[IO.Path]::DirectorySeparatorChar)))}
            $dirs=@(Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)
            foreach($dir in $dirs){[IO.Directory]::Delete($dir.FullName,$false)}
            [IO.Directory]::Delete($RootPath,$false)
        } catch { Add-DownloadLog 'The verified ZIP is saved. The original folder was kept because safe cleanup could not be confirmed.' }
        return 'The ZIP was verified and saved.'
    } catch {
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
        throw
    }
}

function Invoke-FolderDownload($Job,[string]$Link) {
    if ($Job.Checksum) { throw 'Expected SHA-256 applies to a single file. Leave it blank for a folder download.' }
    $directory=[IO.Path]::GetDirectoryName($script:historyAttemptPath)
    $manifestPath=Join-Path $directory 'folder-manifest.json'
    $rootPath=$null
    $children=@()
    if([IO.File]::Exists($manifestPath)) {
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        Add-DownloadLog 'Listing the entire shared folder before starting resumable file transfers.'
        $provider=if($Job.Provider){[string]$Job.Provider}else{Get-DownloadProvider $Link}
        $discovered=if($provider -eq 'google-drive'){Get-GoogleDriveFolderManifest $Link}else{Get-PublicFolderManifest $Link}
        Assert-DownloadActive
        $unsupported=@($discovered.Files | Where-Object {$_.State -in @('Needs export','Unavailable','Skipped')})
        if($unsupported.Count){$workspace=@($unsupported | Where-Object {$_.State -eq 'Needs export'}).Count;$blocked=$unsupported.Count-$workspace;throw "Folder listing found $($unsupported.Count) item(s) GOB cannot download yet ($workspace Google Workspace document(s), $blocked restricted or repeated folder shortcut(s)). No files were started."}
        $name=if($Job.Name){Convert-FolderComponent $Job.Name}elseif($discovered.Name){Convert-FolderComponent $discovered.Name}else{'Dropbox folder'}
        $outputMode=if($Job.FolderOutput -eq 'zip'){'zip'}else{'folder'}
        $archiveName=if($outputMode -eq 'zip'){if($name -match '\.zip$'){$name}else{"$name.zip"}}else{''}
        $folderName=if($outputMode -eq 'zip'){[IO.Path]::GetFileNameWithoutExtension($archiveName)}else{$name}
        $wrapperPath=if($outputMode -eq 'zip' -and $Job.Subfolder){Join-Path $Job.Destination $folderName}else{''}
        $rootPath=if($wrapperPath){Join-Path $wrapperPath 'Files'}else{Join-Path $Job.Destination $folderName}
        $archivePath=if($outputMode -eq 'zip'){if($wrapperPath){Join-Path $wrapperPath $archiveName}else{Join-Path $Job.Destination $archiveName}}else{''}
        Assert-NoDownloadLinks $rootPath
        if((Test-Path -LiteralPath $rootPath) -or ($wrapperPath -and (Test-Path -LiteralPath $wrapperPath)) -or ($archivePath -and (Test-Path -LiteralPath $archivePath))){throw 'A file or folder already exists at that destination. Choose a new output name.'}
        $entries=@()
        foreach($entry in $discovered.Files) {
            $id=[Guid]::NewGuid().ToString('N')
            $childDirectory=Join-Path (Join-Path $directory 'children') $id
            [void][IO.Directory]::CreateDirectory($childDirectory)
            $relative=$entry.Local.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $target=Join-Path $rootPath $relative
            Assert-NoDownloadLinks $target
            $childLink=if($provider -eq 'google-drive'){$Link}else{$entry.Url}
            $secret=ConvertTo-SecureString -String $childLink -AsPlainText -Force
            try{$protected=ConvertFrom-SecureString $secret}finally{$secret.Dispose()}
            $driveFile=if($provider -eq 'google-drive'){@{Id=$entry.Id;Name=[IO.Path]::GetFileName($target);MimeType=$entry.MimeType;Size=$entry.Size;Md5Checksum=$entry.Md5Checksum;ResourceKey=$entry.ResourceKey}}else{$null}
            $child=@{ProtectedLink=$protected;Provider=$provider;DriveFile=$driveFile;DisplayName=$entry.Remote;Created=$Job.Created;Name=[IO.Path]::GetFileName($target);Destination=[IO.Path]::GetDirectoryName($target);FolderZip=$false;AutoDetect=$false;Subfolder=$false;Notifications=$false;Brutal=$Job.Brutal;OnePass=$false;Checksum='';Connections=4;SpeedLimit=$Job.SpeedLimit;ParentWorkerId=$PID;ParentWorkerStart=[string]([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks);ExpectedSize=$entry.Size;ParentFolder=$true}
            $child | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $childDirectory 'job.json') -Encoding UTF8
            $entries+=@{Id=$id;Remote=$entry.Remote;Local=$entry.Local;Size=$entry.Size;DriveFile=$driveFile}
        }
        $manifest=[pscustomobject]@{Schema=1;Root=$rootPath;Entries=@($entries);Directories=@($discovered.Directories);CreatedRoot=$false;OutputMode=$outputMode;ArchivePath=$archivePath;WrapperPath=$wrapperPath}
        Write-DownloadState $manifestPath $manifest
        Add-DownloadLog "Complete folder snapshot saved: $($entries.Count) files. Completed files will be kept on Resume."
    }
    $rootPath=[string]$manifest.Root
    if(-not $manifest.OutputMode){$manifest | Add-Member -NotePropertyName OutputMode -NotePropertyValue 'folder' -Force}
    $archivePath=[string]$manifest.ArchivePath
    if($manifest.OutputMode -eq 'zip' -and $archivePath -and [IO.File]::Exists($archivePath)){
        Assert-NoDownloadLinks $archivePath
        $proofPath = Join-Path $directory 'folder-zip-ready.json'
        if (-not [IO.File]::Exists($proofPath)) {
            throw 'A file already exists at the ZIP destination. Your saved files were kept.'
        }
        $proof = Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($proof.Hash -cne (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash) {
            throw 'The existing ZIP does not match this download. Your saved files were kept.'
        }
        $script:historyState.IsFolder=$true;$script:historyState.Output=$archivePath
        Update-HistoryState 'Completed' 'Completed. The saved ZIP was verified after the previous attempt stopped.'
        Finish-DownloadLog 'Folder ZIP verified after a previous interruption.'
        Show-DownloadNotification 'Completed' 'The verified folder ZIP is ready.'
        return
    }
    Assert-NoDownloadLinks $rootPath
    if(-not [IO.Directory]::Exists($rootPath)){
        if($manifest.CreatedRoot){throw 'The saved folder moved or is unavailable. Restore it before resuming.'}
        [void][IO.Directory]::CreateDirectory($rootPath)
    }
    $manifest | Add-Member -NotePropertyName CreatedRoot -NotePropertyValue $true -Force
    Write-DownloadState $manifestPath $manifest
    foreach($folder in $manifest.Directories){$path=Join-Path $rootPath $folder.Local.Replace('/',[IO.Path]::DirectorySeparatorChar);Assert-NoDownloadLinks $path;[void][IO.Directory]::CreateDirectory($path)}
    foreach($entry in $manifest.Entries){
        if($entry.Local -match '(^|[/\\])\.\.?([/\\]|$)' -or [IO.Path]::IsPathRooted($entry.Local)){throw 'The saved folder manifest contains an unsafe path.'}
        $parent=[IO.Path]::GetDirectoryName((Join-Path $rootPath $entry.Local.Replace('/',[IO.Path]::DirectorySeparatorChar)))
        Assert-NoDownloadLinks $parent;[void][IO.Directory]::CreateDirectory($parent)
    }
    $script:historyState.IsFolder=$true
    $script:historyState.Output=$rootPath
    $script:historyState.Children=@()
    $active=@{};$pending=[Collections.Generic.Queue[object]]::new();$states=@{}
    $parentStart=[string]([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
    foreach($entry in $manifest.Entries) {
        if($entry.Id -notmatch '^[a-f0-9]{32}$' -or $entry.Local -match '(^|[/\\])\.\.?([/\\]|$)' -or [IO.Path]::IsPathRooted($entry.Local)){throw 'The saved folder manifest contains an unsafe path.'}
        $childDirectory=Join-Path (Join-Path $directory 'children') $entry.Id
        $attempt=Get-ChildItem -LiteralPath $childDirectory -Filter 'attempt-*.jsonl' -File | Sort-Object Name -Descending | Select-Object -First 1
        $state=if($attempt){Read-HistoryState $attempt.FullName}else{$null}
        if($state -and $state.Status -eq 'Completed') {
            $target=Join-Path $rootPath $entry.Local.Replace('/',[IO.Path]::DirectorySeparatorChar)
            Assert-NoDownloadLinks $target
            if(-not [IO.File]::Exists($target) -or (Get-Item -LiteralPath $target).Length -ne [long]$entry.Size){throw 'A completed folder file moved or changed. Inspect the saved folder before resuming.'}
            $states[$entry.Id]=$state
        } else {$pending.Enqueue($entry)}
    }
    $parallel=if($Job.Brutal){[Math]::Max(1,[Math]::Min(3,@($manifest.Entries).Count))}else{1}
    Show-DownloadNotification 'Started' 'Downloading the shared folder as separate files.'
    $lastNote=[DateTime]::MinValue
    try {
        do {
            $pausing=Test-DownloadPause
            while(-not $pausing -and $active.Count -lt $parallel -and $pending.Count) {
                $entry=$pending.Dequeue();$childDirectory=Join-Path (Join-Path $directory 'children') $entry.Id
                $childPath=Join-Path $childDirectory 'job.json'
                $child=Get-Content -LiteralPath $childPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $child.ParentWorkerId=$PID;$child.ParentWorkerStart=$parentStart
                $child.Connections=if($script:historyState.RecoveryMode){1}elseif($Job.Brutal){[int][Math]::Floor(16 / $parallel)}else{[int]$Job.Connections}
                $child.Brutal=$Job.Brutal -and -not $script:historyState.RecoveryMode
                $child.SpeedLimit=if($Job.Brutal){0}else{[int]$Job.SpeedLimit}
                $child | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $childPath -Encoding UTF8
                $attempt=Join-Path $childDirectory ('attempt-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff')+'-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
                Add-HistoryState $attempt @{Status='Starting';Updated=[DateTime]::UtcNow.ToString('o');Message='Starting folder file.'}
                $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$GOBExecutable;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
                $start.Arguments='--worker '+(Quote-TransferArgument $attempt)
                $process=[Diagnostics.Process]::Start($start)
                $active[$entry.Id]=@{Entry=$entry;Attempt=$attempt;Process=$process}
                Add-DownloadLog "Started file $($states.Count + $active.Count) of $(@($manifest.Entries).Count)."
            }
            foreach($id in @($active.Keys)) {
                $item=$active[$id]
                if($pausing){[IO.File]::WriteAllText($item.Attempt+'.pause','pause')}
                $state=Read-HistoryState $item.Attempt
                if($state){
                    $states[$id]=$state
                    if($state.RecoveryMode -and -not $script:historyState.RecoveryMode){
                        $parallel=1;$script:historyState.RecoveryMode=$true
                        Add-DownloadLog 'A folder file needed recovery. Reducing the queue to one file and one connection for subsequent transfers.'
                    }
                }
                if($item.Process.HasExited) {
                    $item.Process.Dispose();$active.Remove($id)
                    if(-not $state -or $state.Status -notin @('Completed','Paused','Failed')){$states[$id]=@{Status='Interrupted';Message='This file stopped before completion was confirmed.'}}
                    Add-DownloadLog "Folder file $($item.Entry.Remote) ended with status $($states[$id].Status). $($states[$id].Message)"
                }
            }
            $done=0L;$total=0L;$speed=0L;$finished=0;$views=@()
            foreach($entry in $manifest.Entries) {
                $state=$states[$entry.Id];$total+=[long]$entry.Size
                $stage=if($state){[string]$state.Status}else{'Queued'}
                if($stage -eq 'Completed'){$done+=[long]$entry.Size;$finished++}
                elseif($state.Metrics){$done+=[Math]::Min([long]$entry.Size,[long]$state.Metrics.Completed);if($active.ContainsKey($entry.Id)){$speed+=[long]$state.Metrics.Speed}}
                if ($views.Count -lt 500) { $views+=@{Id=$entry.Id;Name=$entry.Remote;Status=$stage; Size=[long]$entry.Size; Completed=$state.Metrics.Completed; Message=[string]$state.Message} }
            }
            $script:historyState.Children=$views
            $script:historyState.FileCount=@($manifest.Entries).Count
            $script:historyState.CompletedFileCount=$finished
            $script:historyState.Metrics=@{Total=$total;Completed=$done;Speed=$speed;Connections=$active.Count;Estimated=$false}
            $message="$finished of $(@($manifest.Entries).Count) files complete."
            Update-HistoryState $(if($pausing){'Pausing'}else{'Running'}) $message
            if(([DateTime]::UtcNow-$lastNote).TotalSeconds -ge 30){Add-DownloadLog ('Folder progress: '+$message+(' {0:N2} of {1:N2} GiB; {2:N1} MiB/s.' -f ($done/1GB),($total/1GB),($speed/1MB)));$lastNote=[DateTime]::UtcNow}
            if($active.Count){Start-Sleep -Milliseconds 300}
        } while($active.Count -or ($pending.Count -and -not (Test-DownloadPause)))
        Assert-DownloadActive
        if($finished -ne @($manifest.Entries).Count){
            $failed = $manifest.Entries | Where-Object { $states[$_.Id].Status -in @('Failed','Interrupted') } | Select-Object -First 1
            $reason = if ($failed) { $states[$failed.Id].Message } else { 'Some folder files did not finish.' }
            throw "$reason Resume keeps completed files and retries unfinished ones."
        }
        if($manifest.OutputMode -eq 'zip'){
            Update-HistoryState 'Verifying' 'Every file is complete. Assembling and checking the ZIP.'
            $archiveResult=Complete-FolderZip $Job $manifest $rootPath $archivePath $directory
            Update-HistoryState 'Completed' "Completed. All $finished files were verified and saved as a ZIP. $archiveResult"
            Finish-DownloadLog "Folder ZIP complete. All $finished files verified. $archiveResult"
            Show-DownloadNotification 'Completed' 'The folder ZIP is verified and ready.'
        } else {
            $script:historyState.Output=$rootPath
            Update-HistoryState 'Completed' "Completed. All $finished folder files were saved and verified."
            Finish-DownloadLog "Folder complete. All $finished files were saved and verified."
            Show-DownloadNotification 'Completed' 'Every file in the folder finished.'
        }
    } finally {
        foreach($item in $active.Values) {
            [IO.File]::WriteAllText($item.Attempt+'.pause','pause')
            while (-not $item.Process.WaitForExit(1000)) { Update-HistoryState 'Pausing' 'Waiting for folder files to save their checkpoints.' }
            $item.Process.Dispose()
        }
    }
}
