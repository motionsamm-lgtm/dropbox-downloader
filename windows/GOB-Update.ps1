param([ValidateSet('Check','Install')][string]$Mode='Check',[int]$GuiPid=0,[string]$RequestId='')
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GOB'
[void][IO.Directory]::CreateDirectory($root)
$statePath=Join-Path $root 'update-state.json'
function Save-State($value) {
    $value['requestId'] = $RequestId
    $value['updatedAt'] = [DateTime]::UtcNow.ToString('o')
    $temp=$statePath+'.tmp'
    $value | ConvertTo-Json -Compress | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $statePath -Force
}
if ($RequestId -notmatch '^[a-f0-9]{32}$') { $RequestId=[Guid]::NewGuid().ToString('N') }
try {
    if ($Mode -eq 'Check') {
        Save-State @{status='Checking';message='Checking for GOB updates...'}
    } else {
        Save-State @{status='Downloading';message='Downloading and checking the update...'}
    }
    $manifest=Invoke-RestMethod 'https://github.com/motionsamm-lgtm/dropbox-downloader/releases/latest/download/gob-update.json' -TimeoutSec 20
    if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid update version.' }
    if ([version]$manifest.version -le [version]'1.2.0') { Save-State @{status='Current';version=$manifest.version;message="GOB $($manifest.version) is up to date."}; exit 0 }
    $asset=$manifest.assets.windows
    if ($asset.sha256 -notmatch '^[a-f0-9]{64}$' -or $asset.size -le 0 -or $asset.size -gt 314572800 -or
        $asset.url -notmatch '^https://github\.com/motionsamm-lgtm/dropbox-downloader/releases/download/[^/]+/GOB(?:-Setup)?\.exe$') { throw 'Invalid update manifest.' }
    if ($Mode -eq 'Check') { Save-State @{status='Available';version=$manifest.version;message="GOB $($manifest.version) is available."}; exit 0 }
    Save-State @{status='Downloading';version=$manifest.version;message='Downloading and checking the update...'}
    $staged=Join-Path $root ('GOB-update-'+$manifest.version+'.exe')
    Invoke-WebRequest $asset.url -OutFile $staged -TimeoutSec 300 -UseBasicParsing
    if ((Get-Item -LiteralPath $staged).Length -ne $asset.size -or (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) {
        Remove-Item -LiteralPath $staged -ErrorAction SilentlyContinue
        throw 'The update checksum did not match. Your installed app was kept.'
    }
    Save-State @{status='Ready';message='Update downloaded. Closing GOB to finish installation.'}
    if ($GuiPid -gt 0) { Wait-Process -Id $GuiPid -ErrorAction SilentlyContinue }
    Save-State @{status='Installed';message='Update launched.'}
    Start-Process -FilePath $staged -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /GOBWAITPID={0}' -f $PID)
} catch {
    $detail=$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail='Unknown updater error.' }
    if ($detail.Length -gt 240) { $detail=$detail.Substring(0,240)+'...' }
    Save-State @{status='Error';message='Could not check for updates. Check your internet connection and try again.';details=$detail}
    exit 1
}
