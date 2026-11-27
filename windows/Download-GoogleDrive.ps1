function Get-GoogleDriveLinkInfo([string]$Link) {
    $uri=$null
    if(-not [Uri]::TryCreate($Link.Trim(),[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.Host -notin @('drive.google.com','www.drive.google.com','docs.google.com') -or $uri.UserInfo -or -not $uri.IsDefaultPort) {
        throw 'Use an HTTPS Google Drive share link.'
    }
    $parts=@($uri.AbsolutePath.Trim('/').Split('/') | Where-Object {$_})
    $id='';$folder=$false
    if($parts.Count -ge 3 -and $parts[0] -eq 'drive' -and $parts[1] -eq 'folders'){$id=$parts[2];$folder=$true}
    elseif($parts.Count -ge 3 -and $parts[1] -eq 'd' -and $parts[0] -in @('file','document','spreadsheets','presentation')){$id=$parts[2]}
    elseif($parts.Count -ge 1 -and $parts[0] -in @('open','uc')){$idPair=$uri.Query.TrimStart('?').Split('&') | Where-Object {$_ -match '^id='} | Select-Object -First 1; if($idPair){$id=[Uri]::UnescapeDataString($idPair.Substring(3))}}
    if($id -notmatch '^[A-Za-z0-9_-]{5,200}$'){throw 'The Google Drive link does not contain a supported file or folder ID.'}
    $resourceKey=''
    foreach($pair in $uri.Query.TrimStart('?').Split('&')){if($pair -match '^resourcekey='){ $resourceKey=[Uri]::UnescapeDataString($pair.Substring(12));break }}
    if($resourceKey -and $resourceKey -notmatch '^[A-Za-z0-9_-]{1,256}$'){throw 'The Google Drive link contains an invalid resource key.'}
    return @{Id=$id;Folder=$folder;ResourceKey=$resourceKey;Original=$uri.AbsoluteUri}
}

function Get-DownloadProvider([string]$Link) {
    $uri=$null
    if([Uri]::TryCreate($Link.Trim(),[UriKind]::Absolute,[ref]$uri) -and $uri.Host -in @('drive.google.com','www.drive.google.com','docs.google.com')){return 'google-drive'}
    return 'dropbox'
}

function Invoke-GoogleDriveJson([string]$Uri,[string]$ItemId,[string]$ResourceKey='') {
    if(-not $GOBDriveApiKey){throw 'Google Drive support is not configured in this GOB build. Check for an app update.'}
    $headers=@{Accept='application/json'}
    if($ResourceKey){$headers['X-Goog-Drive-Resource-Keys']="$ItemId/$ResourceKey"}
    for($attempt=0;$attempt -lt 4;$attempt++) {
        Assert-DownloadActive
        try { return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop }
        catch {
            $response=$_.Exception.Response
            $code=0;if($response){try{$code=[int]$response.StatusCode}catch{}}
            $detail=''
            if($response){try{$reader=[IO.StreamReader]::new($response.GetResponseStream());$raw=$reader.ReadToEnd();$reader.Dispose();$detail=$raw}catch{}}
            $reason=''
            if($detail -match '^\s*\{'){
                try {
                    $parsed=$detail | ConvertFrom-Json -ErrorAction Stop
                    $reason=@($parsed.error.errors)[0].reason
                    if($reason -notmatch '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'){$reason=''}
                } catch {$reason=''}
            }
            $category=if($detail -match '(?i)automated queries'){'provider-blocked'}
                elseif($code -in @(408,429,500,502,503,504) -or $detail -match '(?i)rateLimitExceeded|userRateLimitExceeded|quotaExceeded'){'transient'}
                elseif($code -in @(401,403,404)){'permission'}else{'permanent'}
            if($script:historyState){
                $script:historyState.HttpStatus=$code
                $script:historyState.RetryCount=$attempt
                $script:historyState.FailureCategory=$category
                $script:historyState.ProviderRestricted=($category -eq 'provider-blocked' -or $code -eq 401 -or ($code -eq 429 -and $attempt -eq 3))
            }
            Add-DownloadLog "Drive API attempt $($attempt+1)/4: HTTP $code; category=$category; reason=$reason."
            if($category -eq 'provider-blocked'){throw 'Google Drive blocked automated requests (HTTP 403). Wait for Google to lift the block, then resume.'}
            $isQuota=$detail -match '(?i)rateLimitExceeded|userRateLimitExceeded|dailyLimitExceeded|quotaExceeded|too many requests'
            if($isQuota){
                if($attempt -eq 3){throw 'Google Drive is limiting requests or the project quota is exhausted. Wait a little, then resume.'}
                $wait=[Math]::Min(60,[Math]::Pow(2,$attempt+1));Add-DownloadLog "Google Drive quota limit reached (HTTP $code). Retrying in $wait seconds.";Wait-DownloadRetry $wait;continue
            }
            if($code -in @(401,403)){
                if($detail -match '(?i)API_KEY_[A-Z_]+|SERVICE_DISABLED|accessNotConfigured'){throw 'GOB could not use its Google Drive API configuration. Check for a newer app build or contact the GOB developer.'}
                throw 'Google Drive denied access. Set General access to “Anyone with the link” and allow viewers to download. GOB does not sign in to Google.'
            }
            if($code -eq 404){throw 'Google Drive could not find this item or it is not available publicly. Confirm it exists and set General access to “Anyone with the link”; GOB does not sign in to Google.'}
            if($code -notin @(408,429,500,502,503,504) -or $attempt -eq 3){throw "Google Drive request failed (HTTP $code). Check public sharing, API quota and internet access; saved files were kept."}
            $wait=[Math]::Min(60,[Math]::Pow(2,$attempt+1))
            if($code -eq 429){$wait=30}
            Add-DownloadLog "Google Drive request returned HTTP $code. Retrying in $wait seconds."
            Wait-DownloadRetry $wait
        }
    }
}

function Get-GoogleDriveMetadata([string]$Id,[string]$ResourceKey='') {
    $fields='id,name,mimeType,size,md5Checksum,resourceKey,capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey)'
    $url='https://www.googleapis.com/drive/v3/files/'+[Uri]::EscapeDataString($Id)+'?fields='+[Uri]::EscapeDataString($fields)+'&key='+[Uri]::EscapeDataString($GOBDriveApiKey)
    $item=Invoke-GoogleDriveJson $url $Id $ResourceKey
    if($item.id -cne $Id -or -not $item.name -or -not $item.mimeType){throw 'Google Drive returned incomplete file details.'}
    if($item.capabilities.canDownload -eq $false){throw 'The owner has disabled downloading for this Google Drive item.'}
    return $item
}

function Get-GoogleDriveMediaRequest($Item) {
    if(-not $Item -or $Item.mimeType -like 'application/vnd.google-apps.*'){throw 'This is not a downloadable binary file. Google Docs, Sheets and Slides export is not available yet.'}
    if(-not $GOBDriveApiKey){throw 'Google Drive support is not configured in this GOB build. Check for an app update.'}
    $url='https://www.googleapis.com/drive/v3/files/'+[Uri]::EscapeDataString([string]$Item.id)+'?alt=media&key='+[Uri]::EscapeDataString($GOBDriveApiKey)
    $headers=@()
    $key=[string]$Item.resourceKey
    if($key){$headers+=('--header=X-Goog-Drive-Resource-Keys: {0}/{1}' -f $Item.id,$key)}
    return @{Url=$url;Headers=$headers}
}

function Get-GoogleDriveFolderFields {
    return 'nextPageToken,files(id,name,mimeType,size,md5Checksum,resourceKey,capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey))'
}

function Get-GoogleDriveFolderManifest([string]$Link) {
    $root=Get-GoogleDriveLinkInfo $Link
    if(-not $root.Folder){throw 'Paste a Google Drive folder share link.'}
    $rootMetadata=Get-GoogleDriveMetadata $root.Id $root.ResourceKey
    if($rootMetadata.mimeType -ne 'application/vnd.google-apps.folder'){throw 'This Google Drive link does not point to a folder.'}
    $queue=[Collections.Generic.List[object]]::new();$queue.Add(@{Id=$root.Id;Key=$(if($rootMetadata.resourceKey){$rootMetadata.resourceKey}else{$root.ResourceKey});Remote='';Local='';Depth=0})
    $files=[Collections.Generic.List[object]]::new();$directories=[Collections.Generic.List[object]]::new()
    $seenFolders=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);[void]$seenFolders.Add($root.Id)
    $locals=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for($cursor=0;$cursor -lt $queue.Count;$cursor++) {
        $folder=$queue[$cursor];$token='';$tokens=[Collections.Generic.HashSet[string]]::new();$pages=0
        do {
            Assert-DownloadActive
            $fields=Get-GoogleDriveFolderFields
            $escapedFolderId=$folder.Id.Replace('\','\\').Replace("'","\'")
            $q="'$escapedFolderId' in parents and trashed = false"
            $query='q='+[Uri]::EscapeDataString($q)+'&pageSize=1000&orderBy=name&supportsAllDrives=true&includeItemsFromAllDrives=true&fields='+[Uri]::EscapeDataString($fields)
            if($token){$query+='&pageToken='+[Uri]::EscapeDataString($token)}
            $url='https://www.googleapis.com/drive/v3/files?'+$query+'&key='+[Uri]::EscapeDataString($GOBDriveApiKey)
            $page=Invoke-GoogleDriveJson $url $folder.Id $folder.Key
            if($null -eq $page.files){throw 'Google Drive returned an incomplete folder listing. No child downloads were started.'}
            foreach($listed in $page.files) {
                $item=$listed
                if($item.mimeType -eq 'application/vnd.google-apps.shortcut') {
                    if(-not $item.shortcutDetails.targetId){throw 'Google Drive returned a shortcut without a target.'}
                    $targetKey=[string]$item.shortcutDetails.targetResourceKey
                    $item=Get-GoogleDriveMetadata ([string]$item.shortcutDetails.targetId) $targetKey
                    $item.name=$listed.name
                }
                if(-not $item.id -or -not $item.name -or -not $item.mimeType){throw 'Google Drive returned an item with missing details.'}
                $component=Convert-FolderComponent ([string]$item.name)
                $remote=(@($folder.Remote,[string]$item.name)|Where-Object{$_}) -join '/'
                $local=(@($folder.Local,$component)|Where-Object{$_}) -join '/'
                if($locals.Contains($local)){$local=([IO.Path]::GetFileNameWithoutExtension($local)+'~'+(Get-TextHash $remote).Substring(0,12)+[IO.Path]::GetExtension($local))}
                if(-not $locals.Add($local)){throw 'Two Google Drive items map to the same local path.'}
                if($item.mimeType -eq 'application/vnd.google-apps.folder') {
                    if($folder.Depth -ge 128){throw 'This Google Drive folder is nested more than 128 levels deep.'}
                    if(-not $seenFolders.Add([string]$item.id)){$files.Add(@{Id=$item.id;Remote=$remote;Local=$local;Size=0;State='Skipped';Reason='A folder shortcut points to a folder already included.'});continue}
                    $directories.Add(@{Remote=$remote;Local=$local})
                    $queue.Add(@{Id=[string]$item.id;Key=[string]$item.resourceKey;Remote=$remote;Local=$local;Depth=$folder.Depth+1})
                } else {
                    $workspace=$item.mimeType -like 'application/vnd.google-apps.*'
                    $size=0L;if(-not $workspace){if($null -eq $item.size -or -not [long]::TryParse([string]$item.size,[ref]$size) -or $size -lt 0){throw "Google Drive omitted the size for '$($item.name)'."}}
                    $state=if($workspace){'Needs export'}elseif($item.capabilities.canDownload -eq $false){'Unavailable'}else{'Queued'}
                    $files.Add(@{Id=[string]$item.id;Remote=$remote;Local=$local;Size=$size;MimeType=[string]$item.mimeType;Md5Checksum=[string]$item.md5Checksum;ResourceKey=[string]$item.resourceKey;State=$state})
                }
                if($files.Count+$queue.Count -gt 100000){throw 'This Google Drive folder exceeds the 100,000-item safety limit.'}
            }
            Update-HistoryState 'Running' "Listing Google Drive folder: found $($files.Count) items and $($directories.Count) subfolders."
            $token=[string]$page.nextPageToken
            if($token -and (-not $tokens.Add($token) -or $tokens.Count -gt 10000)){throw 'Google Drive repeated a folder page token. The listing was not marked complete.'}
            $pages++
            if($pages -gt 10000){throw 'Google Drive returned too many folder pages.'}
        } while($token)
    }
    return @{Name=[string]$rootMetadata.name;Files=@($files.ToArray());Directories=@($directories.ToArray())}
}
