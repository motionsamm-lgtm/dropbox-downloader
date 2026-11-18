$ErrorActionPreference='Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$root\windows\Download-History.ps1"
. "$root\windows\Download-Log.ps1"
$folder=Join-Path $env:RUNNER_TEMP ('gob-control-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$server=Start-Process python -ArgumentList @("`"$PSScriptRoot\control-fixture-server.py`"",'--port',"$port") -PassThru -WindowStyle Hidden
$aria="$root\windows\dist\portable\aria2c.exe"
$pauseJob=$null
try {
 Start-Sleep -Seconds 2
 $script:historyAttemptPath=Join-Path $folder 'attempt.jsonl'
 $script:historyState=@{Status='Running';Message='Control test';Port=0;Token='';EngineId=0;EngineStart='';Metrics=$null}
 Start-DownloadLog (Join-Path $folder 'download.log.txt')
 $base=@('--no-conf=true',"--dir=$folder",'--summary-interval=1','--human-readable=false','--auto-save-interval=1','--max-tries=1','--retry-wait=0','--file-allocation=none')
 $result=Invoke-RecordedTransfer $aria ($base+@('--out=good.part',"http://127.0.0.1:$port/ok"))
 if ($result.ExitCode -ne 0 -or (Get-Item "$folder\good.part").Length -ne 131072) { throw 'A completed RPC transfer did not terminate successfully.' }
 $result=Invoke-RecordedTransfer $aria ($base+@('--out=error.part',"http://127.0.0.1:$port/forbidden"))
 if ($result.ExitCode -eq 0) { throw 'An HTTP failure was incorrectly treated as a completed transfer.' }
 $script:historyState.Checkpoint="$folder\slow.part.aria2"
 $pauseJob=Start-Job -ArgumentList ($script:historyAttemptPath+'.pause') -ScriptBlock {param($marker) Start-Sleep -Seconds 3;[IO.File]::WriteAllText($marker,'pause')}
 $paused=$false
 try { $null=Invoke-RecordedTransfer $aria ($base+@('--out=slow.part',"http://127.0.0.1:$port/slow")) }
 catch { if (-not (Test-DownloadPause)) { throw }; $paused=$true }
 if (-not $paused -or -not [IO.File]::Exists($script:historyState.Checkpoint)) { throw 'Pause did not preserve a control file.' }
 Remove-Item -LiteralPath ($script:historyAttemptPath+'.pause')
 $result=Invoke-RecordedTransfer $aria ($base+@('--out=slow.part','--continue=true','--always-resume=true',"http://127.0.0.1:$port/slow"))
 if ($result.ExitCode -ne 0 -or (Get-Item "$folder\slow.part").Length -ne 67108864) { throw 'Resume failed to complete the interrupted transfer.' }
 $tracked=Join-Path $folder 'tracked.part';$other=Join-Path $folder 'unrelated.prproj'
 [IO.File]::WriteAllText($tracked,'download');[IO.File]::WriteAllText($other,'keep')
 Add-OwnedDownloadFile $tracked
 $owned=@(Get-OwnedDownloadFiles $folder @{Status='Failed'})
 if ($owned.Count -ne 1 -or $owned[0] -ne $tracked) { throw 'The tracked-file list included an unrelated file.' }
 New-Item -ItemType Junction -Path "$folder\junction" -Target $folder | Out-Null
 $blocked=$false
 try { Assert-NoDownloadLinks "$folder\junction\unrelated.prproj" } catch { $blocked=$true }
 if (-not $blocked) { throw 'Junction traversal was not blocked.' }
 [IO.Directory]::Delete("$folder\junction")
 [IO.File]::WriteAllText($script:historyAttemptPath+'.pause','pause')
 $clock=[Diagnostics.Stopwatch]::StartNew()
 try { Wait-DownloadRetry 60; throw 'Pause was ignored during a retry delay.' } catch { if ($_.Exception.Message -notlike '*paused by you*') { throw } }
 if ($clock.Elapsed.TotalSeconds -gt 2) { throw 'Retry cancellation was not prompt.' }
 # Read only the named, trusted function definitions without running a worker.
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile("$root\windows\Dropbox-Downloader.ps1",[ref]$tokens,[ref]$errors)
 foreach($fn in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Get-DownloadProbe','Get-BytesHash','Test-Mp4Header')},$false)) { Invoke-Expression $fn.Extent.Text }
 $fakeCurl=Join-Path $folder 'EmptyCurl.cmd'
 [IO.File]::WriteAllText($fakeCurl,"@echo HTTP/1.1 416 Range Not Satisfiable`r`n@echo Content-Range: bytes */0`r`n@exit /b 0`r`n")
 $sample=Get-DownloadProbe $fakeCurl 'https://www.dropbox.com/empty-fixture' $false $false
 if($sample.Problem -or $sample.Size -ne 0 -or $sample.SampleLength -ne 0) { throw 'Empty-file range proof was not recognised.' }
 $empty=Join-Path $folder 'empty.txt';[IO.File]::WriteAllBytes($empty,[byte[]]@())
 . "$root\windows\Download-Reliability.ps1"
 Confirm-DownloadedFile $empty @{Length=0;Prefix=$sample.Prefix;SampleLength=0;FolderZip=$false;VerifyMp4=$false;Checksum=''}
 Write-Host 'PASS: completion, HTTP failure, graceful pause, checkpoint resume, exact tracked files, junction protection, retry cancellation.'
} finally {
 if ($pauseJob) { $pauseJob | Remove-Job -Force -ErrorAction SilentlyContinue }
 if (-not $server.HasExited) { $server.Kill() };$server.Dispose()
}
