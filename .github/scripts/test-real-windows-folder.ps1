$ErrorActionPreference='Stop'
$root=(Resolve-Path "$PSScriptRoot\..\..").Path
. "$root\windows\Download-History.ps1"
. "$root\windows\Download-Reliability.ps1"
$directory=Join-Path $env:RUNNER_TEMP ('gob-real-folder-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$url='https://www.dropbox.com/scl/fo/hsynj5331wvy39wer5egb/h?rlkey=oxhfrqft9ufoo3y0es4a2f8wz&dl=0'
$secret=ConvertTo-SecureString $url -AsPlainText -Force
try{$protected=ConvertFrom-SecureString $secret}finally{$secret.Dispose()}
@{ProtectedLink=$protected;DisplayName='Public press kit';Name='Public press kit';Created=[DateTime]::UtcNow.ToString('o');Destination=$directory;FolderZip=$true;FolderMode='files';AutoDetect=$true;Subfolder=$false;Notifications=$false;Brutal=$true;OnePass=$false;Checksum='';Connections=4;SpeedLimit=0} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'job.json') -Encoding UTF8
$exe="$root\windows\dist\portable\GOB.exe"
function Invoke-Case([string]$Attempt,[bool]$Pause) {
 $process=Start-Process $exe -ArgumentList @('--worker',('"'+$Attempt+'"')) -PassThru
 try {
  if($Pause){Start-Sleep -Seconds 2;[IO.File]::WriteAllText($Attempt+'.pause','pause')}
  if(-not $process.WaitForExit(360000)){throw 'Native folder worker did not finish within six minutes.'}
  $state=Read-HistoryState $Attempt
  if(-not $state){throw 'Native folder worker wrote no history.'}
  return $state
 }finally{if(-not $process.HasExited){$process.Kill()};$process.Dispose()}
}
$first=Join-Path $directory 'attempt-001.jsonl';$state=Invoke-Case $first $true
if($state.Status -notin @('Paused','Completed')){Get-Content (Join-Path $directory 'download.log.txt');throw "First native folder run ended as $($state.Status)."}
$second=Join-Path $directory 'attempt-002.jsonl';$state=Invoke-Case $second $false
if($state.Status -ne 'Completed'){Get-Content (Join-Path $directory 'download.log.txt');throw "Native folder resume ended as $($state.Status)."}
$manifest=Get-Content (Join-Path $directory 'folder-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($entry in $manifest.Entries){
 $target=Join-Path $manifest.Root $entry.Local.Replace('/',[IO.Path]::DirectorySeparatorChar)
 if((Get-Item -LiteralPath $target).Length -ne $entry.Size){throw 'A native folder output did not match its listed byte count.'}
}
$unrelated=Join-Path $manifest.Root 'unrelated-project.prproj';[IO.File]::WriteAllText($unrelated,'keep')
$owned=@(Get-OwnedDownloadFiles $directory $state)
if($owned -contains $unrelated){throw 'The native folder deletion list included an unrelated file.'}
Write-Host "PASS: native GOB.exe discovered, paused/resumed and verified $(@($manifest.Entries).Count) real Dropbox files; deletion excludes unrelated files."
