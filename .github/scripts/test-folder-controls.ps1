$ErrorActionPreference='Stop'
$root=(Resolve-Path "$PSScriptRoot\..\..").Path
. "$root\windows\Download-History.ps1"
. "$root\windows\Download-Log.ps1"
. "$root\windows\Download-Reliability.ps1"
. "$root\windows\Download-Notifications.ps1"
. "$root\windows\Download-Folder.ps1"
$testRoot=Join-Path $env:RUNNER_TEMP ('gob-folder-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$fixtureCode=@'
using System;using System.IO;using System.Collections.Generic;using System.Web.Script.Serialization;using System.Threading;
class Fixture {
 static JavaScriptSerializer json=new JavaScriptSerializer();
 static void Write(string attempt,string status,string output,long size) {
  var state=new Dictionary<string,object>{{"Status",status},{"Output",output},{"Message","Fixture "+status},{"Updated",DateTime.UtcNow.ToString("o")},{"Metrics",new Dictionary<string,object>{{"Total",size},{"Completed",status=="Completed"?size:0},{"Speed",0}}}};
  File.AppendAllText(attempt,json.Serialize(state)+Environment.NewLine);
 }
 static void Main(string[] args) {
  string attempt=args[1];var job=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(Path.GetDirectoryName(attempt),"job.json")));
  string name=(string)job["Name"],output=Path.Combine((string)job["Destination"],name);long size=Convert.ToInt64(job["ExpectedSize"]);
  File.AppendAllText(output+".starts","1");Write(attempt,"Running",output,size);
  int rounds=Environment.GetEnvironmentVariable("GOB_FIXTURE_SLOW")=="1"?60:3;
  for(int n=0;n<rounds;n++){Thread.Sleep(100);if(File.Exists(attempt+".pause")){Write(attempt,"Paused",output,size);return;}}
  if(Environment.GetEnvironmentVariable("GOB_FIXTURE_FAIL")==name){Write(attempt,"Failed",output,size);return;}
  File.WriteAllBytes(output,new byte[size]);Write(attempt,"Completed",output,size);
 }
}
'@
$codePath=Join-Path $testRoot 'Fixture.cs';[IO.File]::WriteAllText($codePath,$fixtureCode)
$GOBExecutable=Join-Path $testRoot 'Fixture.exe'
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:winexe "/out:$GOBExecutable" /reference:System.Web.Extensions.dll $codePath
if($LASTEXITCODE){throw 'Could not build the isolated worker fixture.'}
function New-Case([string]$Name) {
 $dir=Join-Path $testRoot $Name;$out=Join-Path $dir 'saved';[void][IO.Directory]::CreateDirectory($out)
 $entries=@()
 foreach($file in @('a.bin','nested/b.bin')) {
  $id=[Guid]::NewGuid().ToString('N');$childDir=Join-Path (Join-Path $dir 'children') $id;[void][IO.Directory]::CreateDirectory($childDir)
  $target=Join-Path $out $file.Replace('/',[IO.Path]::DirectorySeparatorChar);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
  @{Name=[IO.Path]::GetFileName($target);Destination=[IO.Path]::GetDirectoryName($target);ExpectedSize=512;ParentWorkerId=$PID;ParentWorkerStart='';Connections=4;SpeedLimit=0} | ConvertTo-Json | Set-Content (Join-Path $childDir 'job.json') -Encoding UTF8
  $entries+=@{Id=$id;Remote=$file;Local=$file;Size=512}
 }
 Write-DownloadState (Join-Path $dir 'folder-manifest.json') @{Schema=1;Root=$out;Entries=$entries}
 return @{Directory=$dir;Output=$out;Job=@{Name=$Name;Destination=$dir;Brutal=$true;Connections=4;SpeedLimit=0}}
}
function Set-Attempt($Case) {
 $script:historyAttemptPath=Join-Path $Case.Directory ('attempt-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
 $script:historyState=@{Status='Running';Updated='';Message='';Port=0;Token='';SummaryPath=(Get-HistoryLogPath $Case.Directory);SharedSummary=$true;Metrics=$null}
 Start-DownloadLog $script:historyState.SummaryPath
}
$case=New-Case 'Recovery';Set-Attempt $case
$env:GOB_FIXTURE_FAIL='b.bin'
try {Invoke-FolderDownload $case.Job 'unused';throw 'An incomplete folder was incorrectly completed.'}
catch {if($_.Exception.Message -notlike '*Some folder files did not finish*'){throw}}
if(@($script:historyState.Children|Where-Object Status -eq 'Completed').Count -ne 1){throw 'Folder completion count was incorrect.'}
Remove-Item Env:\GOB_FIXTURE_FAIL
Set-Attempt $case;Invoke-FolderDownload $case.Job 'unused'
if($script:historyState.Status -ne 'Completed'){throw 'The folder did not recover.'}
if((Get-Content -LiteralPath (Join-Path $case.Output 'a.bin.starts') -Raw).Length -ne 1){throw 'Resume redownloaded a completed file.'}
if((Get-Content -LiteralPath (Join-Path $case.Output 'nested\b.bin.starts') -Raw).Length -ne 2){throw 'Resume did not retry the failed file.'}
$owned=@(Get-OwnedDownloadFiles $case.Directory $script:historyState)
if($owned.Count -ne 2 -or @($owned|Where-Object {$_ -like '*.starts'}).Count){throw 'Folder deletion selected unrelated files.'}
$case=New-Case 'Pause';Set-Attempt $case;$env:GOB_FIXTURE_SLOW='1'
$pause=Start-Job -ArgumentList ($script:historyAttemptPath+'.pause') -ScriptBlock {param($path) Start-Sleep -Seconds 1;[IO.File]::WriteAllText($path,'pause')}
try {
 try {Invoke-FolderDownload $case.Job 'unused';throw 'Folder pause was ignored.'} catch {if($_.Exception.Message -notlike '*paused by you*'){throw}}
 if(@($script:historyState.Children|Where-Object Status -eq 'Paused').Count -ne 2){throw 'Not every active file acknowledged pause.'}
} finally {$pause|Remove-Job -Force -ErrorAction SilentlyContinue;Remove-Item Env:\GOB_FIXTURE_SLOW -ErrorAction SilentlyContinue}
Write-Host 'PASS: folder aggregation, completed-file preservation, failed-file retry, tracked-file deletion and whole-folder pause.'
