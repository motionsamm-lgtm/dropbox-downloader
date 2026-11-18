$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
trap {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'GOB could not open')
    break
}
. (Join-Path $PSScriptRoot 'Download-History.ps1')
. (Join-Path $PSScriptRoot 'Download-Log.ps1')
. (Join-Path $PSScriptRoot 'Download-Notifications.ps1')
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'GOB — Grab Our Bytes'
$form.Icon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'GOB.ico'))
$form.ClientSize = [Drawing.Size]::new(660, 830)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(245, 247, 251)

function Add-Control([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = New-Object "Windows.Forms.$Type"
    $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X, $Y)
    $control.Size = [Drawing.Size]::new($Width, $Height)
    $form.Controls.Add($control)
    return $control
}

$title = Add-Control Label 'GOB — Grab Our Bytes' 24 16 612 36
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 20)
$null = Add-Control Label 'Download a file or save a shared folder as a ZIP.' 26 57 608 24

$null = Add-Control Label 'Dropbox link' 26 79 310 21
$linkBox = Add-Control TextBox '' 26 102 515 28
$paste = Add-Control Button 'Paste link' 550 98 84 33
$paste.Add_Click({
    if ([Windows.Forms.Clipboard]::ContainsText()) { $linkBox.Text = [Windows.Forms.Clipboard]::GetText().Trim() }
})
$null = Add-Control Label 'Output filename (optional)' 26 145 608 22
$nameBox = Add-Control TextBox '' 26 169 608 28
$null = Add-Control Label 'Save folder' 26 209 350 21
$directory = Add-Control TextBox (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads') 26 232 515 28
$browse = Add-Control Button 'Browse' 550 228 84 33
$browse.Add_Click({
    $picker = New-Object Windows.Forms.FolderBrowserDialog
    try {
        if ([IO.Directory]::Exists($directory.Text)) { $picker.SelectedPath = $directory.Text }
        if ($picker.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $directory.Text = $picker.SelectedPath }
    } finally { $picker.Dispose() }
})
$subfolderOption = Add-Control CheckBox 'Create filename subfolder' 26 267 220 25
$subfolderOption.Checked = $false
$notify = Add-Control CheckBox 'Show notifications' 262 267 165 25
$notify.Checked = $true
$brutal = Add-Control CheckBox 'Brutal' 457 267 155 25
$brutal.Checked = $true
$null = Add-Control Label 'Connections' 26 303 107 20
$connections = Add-Control NumericUpDown '' 26 326 95 26
$connections.Minimum = 1
$connections.Maximum = 4
$connections.Value = 4
$null = Add-Control Label 'Cap in MiB/s (0 = off)' 140 303 166 20
$limit = Add-Control NumericUpDown '0' 140 326 95 26
$limit.Maximum = 999
$onePass = Add-Control CheckBox 'One pass (start from zero)' 301 326 278 25
$null = Add-Control Label 'Expected SHA-256 (optional)' 26 368 235 21
$checksum = Add-Control TextBox '' 262 365 372 26
$checksum.MaxLength = 64
$status = Add-Control Label '' 26 410 424 45
$status.ForeColor = [Drawing.Color]::FromArgb(59, 74, 98)
$start = Add-Control Button 'Start download' 468 406 166 41
$start.FlatStyle = 'Flat'
$start.BackColor = [Drawing.Color]::FromArgb(0, 87, 219)
$start.ForeColor = [Drawing.Color]::White

function Update-TransferControls {
    $kind = Get-DropboxLinkKind $linkBox.Text
    $isFile = $kind -ne 'Folder'
    $onePass.Enabled = $isFile
    $connections.Enabled = $isFile -and -not $brutal.Checked -and -not $onePass.Checked
    $limit.Enabled = -not $brutal.Checked
    if ($kind -eq 'Folder') {
        $status.Text = 'Detected shared folder. Dropbox will supply a ZIP in one stream.'
    } elseif ($kind -eq 'File') {
        $status.Text = 'Detected a single file.'
        if ($onePass.Checked) { $status.Text += ' One pass starts from zero.' }
        elseif ($brutal.Checked) { $status.Text += ' Brutal uses up to 16 connections.' }
    } elseif ($linkBox.Text.Trim()) {
        $status.Text = 'Link type unclear. Copy a whole folder link or a link to an individual file.'
    } else { $status.Text = 'Paste a Dropbox link to detect the download type.' }
}
$linkBox.Add_TextChanged({ Update-TransferControls })
$brutal.Add_CheckedChanged({ Update-TransferControls })
$onePass.Add_CheckedChanged({ Update-TransferControls })
Update-TransferControls

$heading = Add-Control Label 'Download history' 26 465 608 24
$heading.Font = [Drawing.Font]::new('Segoe UI Semibold', 11)
$history = Add-Control ListView '' 26 492 608 138
$history.View = 'Details'
$history.FullRowSelect = $true
$history.MultiSelect = $false
$history.HideSelection = $false
[void]$history.Columns.Add('Download', 161)
[void]$history.Columns.Add('Status', 93)
[void]$history.Columns.Add('Progress', 78)
[void]$history.Columns.Add('Speed', 92)
[void]$history.Columns.Add('ETA', 71)
[void]$history.Columns.Add('Started', 95)
$progress = Add-Control ProgressBar '' 26 642 608 12
$detail = Add-Control Label '' 26 660 608 38
$resume = Add-Control Button 'Resume selected' 26 705 153 30
$openLog = Add-Control Button 'Open text log' 187 705 130 30
$resume.Enabled = $false
$openLog.Enabled = $false
$markDone = Add-Control Button 'Mark complete' 325 705 125 30
$markDone.Enabled = $false
$pause = Add-Control Button 'Pause download' 458 705 176 30
$removeDownload = Add-Control Button 'Remove from list...' 27 785 150 30
$deleteDownload = Add-Control Button 'Delete files...' 187 785 130 30
$script:jobs = @{}
$script:activeJob = $false
$historyRoot = Get-HistoryDirectory
[void][IO.Directory]::CreateDirectory($historyRoot)

function Show-UiError([string]$Message) {
    [void][Windows.Forms.MessageBox]::Show($form, $Message, 'GOB — Grab Our Bytes')
}

function Get-SelectedDownload {
    if ($history.SelectedItems.Count) { return $script:jobs[[string]$history.SelectedItems[0].Name] }
}

function Update-SelectedDownload {
    $selected = Get-SelectedDownload
    $resume.Enabled = $false
    $openLog.Enabled = $false
    $markDone.Enabled = $false
    $pause.Enabled = $false
    $removeDownload.Enabled = $false
    $deleteDownload.Enabled = $false
    if (-not $selected) {
        $progress.Style = 'Continuous'
        $progress.Value = 0
        $detail.Text = 'Start a download or select an entry from History.'
        return
    }

    $state = $selected.State
    $stage = $selected.Status
    $resume.Enabled = (-not $script:gobUpdating -and -not $script:activeJob -and $stage -in @('Paused','Failed','Interrupted','File found'))
    $pause.Enabled = $stage -in @('Starting','Running','Verifying')
    $pause.Text = if ($stage -eq 'Pausing') { 'Saving progress...' } else { 'Pause download' }
    $removeDownload.Enabled = -not $script:activeJob -and -not $script:gobUpdating
    $deleteDownload.Enabled = -not $script:activeJob -and -not $script:gobUpdating
    $openLog.Enabled = $state.SummaryPath -and [IO.File]::Exists($state.SummaryPath)
    $markDone.Enabled = -not $script:activeJob -and $stage -eq 'File found'
    $metrics = $selected.Metrics
    if ($stage -eq 'Completed') {
        $progress.Style = 'Continuous'
        $progress.Value = 100
        $detail.Text = 'Completed. File verified and saved.'
        if ($state.Manual) {
            $detail.Text = 'Completed. Marked complete by you.'
        } elseif ($selected.RecordedFinished) {
            $detail.Text += '  ' + $selected.RecordedFinished
        } elseif ($state.Updated) {
            $detail.Text += '  ' + [DateTime]::Parse($state.Updated).ToLocalTime().ToString('dd MMM, HH:mm:ss')
        }
    } elseif ($stage -eq 'Running' -and $metrics) {
        $progress.Style = 'Continuous'
        $progress.Value = [int][Math]::Floor($metrics.Percent)
        $detail.Text = "$($metrics.ProgressText)   |   $($metrics.SpeedText)   |   ETA $($metrics.EtaText)"
        if ($metrics.Estimated) { $detail.Text += '  (from saved pieces)' }
        if ($state.RecoveryMode) { $detail.Text += '   |   Recovery: 1 connection' }
    } else {
        $fraction = if ($stage -eq 'Verifying') { 99.9 } else { $selected.LastPercent }
        $progress.Style = 'Continuous'
        $progress.Value = [int][Math]::Floor([double]$fraction)
        if ($stage -in @('Starting', 'Running') -and -not $fraction) { $progress.Style = 'Marquee' }
        $detail.Text = if ($stage -eq 'File found') {
            'A final file exists. Resume checks for a saved verification record, or use Mark complete after checking the file.'
        } elseif ($stage -eq 'Interrupted') {
            'Interrupted. Resume from History with the original link and settings.'
        } else { [string]$state.Message }
    }
}

function Update-DownloadHistory {
    $script:activeJob = $false
    foreach ($entry in (Get-ChildItem -LiteralPath $historyRoot -Directory | Sort-Object CreationTimeUtc)) {
        $jobPath = Join-Path $entry.FullName 'job.json'
        if (-not [IO.File]::Exists($jobPath)) { continue }
        if (-not $script:jobs.ContainsKey($entry.Name)) {
            try { $job = Get-Content -LiteralPath $jobPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { continue }
            $row = [Windows.Forms.ListViewItem]::new([string]$job.DisplayName)
            $row.Name = $entry.Name
            foreach ($column in 1..4) { [void]$row.SubItems.Add('') }
            [void]$row.SubItems.Add([DateTime]::Parse($job.Created).ToLocalTime().ToString('dd MMM, HH:mm'))
            [void]$history.Items.Insert(0, $row)
            $script:jobs[$entry.Name] = @{ Job = $job; Directory = $entry.FullName; Row = $row }
        }
        $record = $script:jobs[$entry.Name]
        $last = Get-ChildItem -LiteralPath $entry.FullName -File -Filter 'attempt-*.jsonl' |
            Sort-Object Name -Descending | Select-Object -First 1
        $record.State = $null
        if ($last) { $record.State = Read-HistoryState $last.FullName }
        $record.Attempt = $last
        $record.Status = Get-HistoryStatus $record.State
        $workerAlive = (Test-HistoryProcess $record.State.ProcessId $record.State.ProcessStart) -or
            (Test-HistoryProcess $record.State.EngineId $record.State.EngineStart)
        if ($last -and [IO.File]::Exists($last.FullName + '.pause') -and
            $record.Status -in @('Starting','Running','Pausing')) {
            $record.Status = if ($workerAlive) { 'Pausing' } else { 'Interrupted' }
        }
        $record.RecordedFinished = $null
        if ($record.Status -in @('Failed','Interrupted') -and $record.State.Output -and
            [IO.File]::Exists([string]$record.State.Output)) {
            $record.RecordedFinished = Get-RecordedCompletion $record.State
            $record.Status = if ($record.RecordedFinished) { 'Completed' } else { 'File found' }
        }
        $record.Row.SubItems[1].Text = $record.Status
        $record.Metrics = $null
        $progressText = ([string][char]0x2014)
        $speedText = ([string][char]0x2014)
        $etaText = ([string][char]0x2014)
        if ($record.Status -eq 'Completed') { $progressText = '100%' }
        if ($record.Status -eq 'Running') {
            $metrics = $record.State.Metrics
            if (-not $metrics -and $record.State.Port) {
                # A previous release used RPC and may be waiting after finishing.
                $legacy = Get-LiveTransfer $record.State
                if ($legacy.status -in @('complete','error','removed')) {
                    if (-not $record.LegacyStopSent) {
                        $record.LegacyStopSent = (Invoke-TransferRpc $record.State 'aria2.shutdown' @()) -eq 'OK'
                    }
                }
                $metrics = Get-ProgressMetrics $record
            }
            if ($metrics) {
                $metrics = @{ Total=$metrics.Total; Completed=$metrics.Completed; Speed=$metrics.Speed; Estimated=$metrics.Estimated }
            }
            if (-not $record.State.Port -and $record.State.Message -match '^(All bytes received|Verifying|Saving the verified)') {
                $record.Status = 'Verifying'
                $record.Row.SubItems[1].Text = 'Verifying'
                $progressText = '99.9%'
            }
            if ($metrics) {
                $metrics.Percent = 0
                if ($metrics.Total -gt 0) {
                    $metrics.Percent = [Math]::Max(0, [Math]::Min(99.9, 100 * [double]$metrics.Completed / $metrics.Total))
                    $progressText = '{0:N1}%' -f $metrics.Percent
                } else { $progressText = '{0:N1} GiB' -f ($metrics.Completed / 1GB) }
                if ($metrics.Speed -gt 0) {
                    $speedText = '{0:N1} MiB/s' -f ($metrics.Speed / 1MB)
                    if ($metrics.Total -gt 0) {
                        $seconds = [Math]::Max(0, ($metrics.Total - $metrics.Completed) / $metrics.Speed)
                        $etaText = ([TimeSpan]::FromSeconds($seconds)).ToString('hh\:mm\:ss')
                        if ($seconds -ge 86400) { $etaText = '>24 h' }
                    }
                }
                $metrics.ProgressText = $progressText
                $metrics.SpeedText = $speedText
                $metrics.EtaText = $etaText
                $record.Metrics = $metrics
                $record.LastPercent = $metrics.Percent
            }
        }
        $record.Row.SubItems[2].Text = $progressText
        $record.Row.SubItems[3].Text = $speedText
        $record.Row.SubItems[4].Text = $etaText
        if ($record.Status -in @('Running', 'Starting','Verifying','Pausing')) { $script:activeJob = $true }
    }
    $start.Enabled = -not $script:activeJob -and -not $script:gobUpdating
    Update-SelectedDownload
}

function Start-HistoryAttempt([string]$Directory) {
    if ($script:gobUpdating) { throw 'Wait until the GOB update has finished.' }
    if ($script:activeJob) { throw 'A download is already running.' }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff')
    $id = [Guid]::NewGuid().ToString('N')
    $attempt = Join-Path $Directory "attempt-$stamp-$id.jsonl"
    $logPath = Get-HistoryLogPath $Directory
    Add-HistoryState $attempt @{
        Status = 'Starting'; Message = 'Starting the background download.'; Updated = [DateTime]::UtcNow.ToString('o')
        SummaryPath = $logPath; SharedSummary = $true
    }
    try {
        if (-not [IO.File]::Exists((Join-Path $PSScriptRoot 'aria2c.exe'))) {
            throw 'Put aria2c.exe in the downloader folder. See README.txt.'
        }
        $arguments = '--worker "{0}"' -f $attempt
        $launch = [Diagnostics.ProcessStartInfo]::new()
        $launch.FileName = $GOBExecutable
        $launch.Arguments = $arguments
        $launch.UseShellExecute = $false
        $launch.CreateNoWindow = $true
        [Diagnostics.Process]::Start($launch).Dispose()
    } catch {
        $reason = if ([IO.File]::Exists((Join-Path $PSScriptRoot 'aria2c.exe'))) {
            'Windows could not start the background worker.'
        } else { 'The download engine is missing. Put aria2c.exe in the downloader folder.' }
        Start-DownloadLog $logPath
        Finish-DownloadLog $reason
        Add-HistoryState $attempt @{
            Status = 'Failed'; Message = $reason; Updated = [DateTime]::UtcNow.ToString('o')
            SummaryPath = $logPath; SharedSummary = $true
        }
        throw
    } finally {
        Update-DownloadHistory
        $key = [IO.Path]::GetFileName($Directory)
        if ($script:jobs.ContainsKey($key)) {
            $script:jobs[$key].Row.Selected = $true
            $script:jobs[$key].Row.EnsureVisible()
        }
    }
}

$start.Add_Click({
    try {
        if ($script:activeJob) { return }
        if (-not $linkBox.Text.Trim()) { throw 'Paste a Dropbox link first.' }
        if (-not [IO.Directory]::Exists($directory.Text.Trim())) { throw 'Choose an existing save folder.' }
        $kind = Get-DropboxLinkKind $linkBox.Text
        if (-not $kind) { throw 'The link type could not be detected. Copy a Dropbox file link, the whole shared folder link, or open the MP4 and copy its URL.' }
        $key = [Guid]::NewGuid().ToString('N')
        $jobDirectory = Join-Path $historyRoot $key
        [void][IO.Directory]::CreateDirectory($jobDirectory)
        $secret = ConvertTo-SecureString -String $linkBox.Text.Trim() -AsPlainText -Force
        try { $protectedLink = ConvertFrom-SecureString -SecureString $secret }
        finally { $secret.Dispose() }
        $display = $nameBox.Text.Trim()
        if (-not $display) {
            $display = 'Dropbox download'
            if ($kind -eq 'Folder') { $display = 'Shared folder ZIP' }
            $uri = $null
            if ($kind -eq 'File' -and [Uri]::TryCreate($linkBox.Text.Trim(), [UriKind]::Absolute, [ref]$uri)) {
                $filename = [Uri]::UnescapeDataString($uri.Segments[-1])
                if ($filename -match '\.[A-Za-z0-9]{1,10}$') { $display = $filename }
            }
        }
        $job = @{
            ProtectedLink = $protectedLink
            DisplayName = $display
            Created = [DateTime]::UtcNow.ToString('o')
            Name = $nameBox.Text.Trim()
            Destination = [IO.Path]::GetFullPath($directory.Text.Trim())
            FolderZip = $kind -eq 'Folder'
            AutoDetect = $true
            Subfolder = $subfolderOption.Checked
            Notifications = $notify.Checked
            Brutal = $brutal.Checked
            OnePass = $onePass.Checked -and $kind -eq 'File'
            Checksum = $checksum.Text.Trim()
            Connections = [int]$connections.Value
            SpeedLimit = [int]$limit.Value
        }
        $temporary = Join-Path $jobDirectory 'job.tmp'
        $job | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
        [IO.File]::Move($temporary, (Join-Path $jobDirectory 'job.json'))
        Start-HistoryAttempt $jobDirectory
    } catch { Show-UiError $_.Exception.Message }
})
$resume.Add_Click({
    try {
        $selected = Get-SelectedDownload
        if (-not $selected -or $selected.Status -notin @('Paused', 'Failed', 'Interrupted', 'File found')) { return }
        if ($selected.Status -ne 'File found' -and ($selected.Job.FolderZip -or $selected.Job.OnePass)) {
            $choice = [Windows.Forms.MessageBox]::Show($form,
                'This transfer uses one stream and must start from zero. Start it again?',
                'Restart download', 'YesNo', 'Question', 'Button2')
            if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
        }
        Start-HistoryAttempt $selected.Directory
    } catch { Show-UiError $_.Exception.Message }
})
$markDone.Add_Click({
    try {
        Update-DownloadHistory
        $selected = Get-SelectedDownload
        if ($script:activeJob -or -not $selected -or $selected.Status -ne 'File found' -or -not $selected.Attempt) { return }
        $choice = [Windows.Forms.MessageBox]::Show($form,
            "Have you checked that the saved file is complete?`n`n$($selected.State.Output)",
            'Mark complete', 'YesNo', 'Question', 'Button2')
        if ($choice -ne [Windows.Forms.DialogResult]::Yes -or -not [IO.File]::Exists([string]$selected.State.Output)) { return }
        Add-HistoryState $selected.Attempt.FullName @{
            Status='Completed'; Manual=$true; Output=$selected.State.Output
            SummaryPath=$selected.State.SummaryPath; Updated=[DateTime]::UtcNow.ToString('o')
            Message='Marked complete by you.'
        }
        Update-DownloadHistory
    } catch { Show-UiError $_.Exception.Message }
})
$pause.Add_Click({
    try {
        $selected = Get-SelectedDownload
        if (-not $selected.Attempt -or $selected.Status -notin @('Starting','Running','Verifying')) { return }
        [IO.File]::WriteAllText($selected.Attempt.FullName + '.pause', [DateTime]::UtcNow.ToString('o'))
        Update-DownloadHistory
    } catch { Show-UiError $_.Exception.Message }
})
function Remove-SelectedDownload([bool]$DeleteFiles) {
    Update-DownloadHistory
    if ($script:activeJob -or $script:gobUpdating) { throw 'Pause the active download and wait for Paused before removing downloads.' }
    $selected = Get-SelectedDownload
    if (-not $selected) { return }
    $files = @()
    if ($DeleteFiles) { $files = @(Get-OwnedDownloadFiles $selected.Directory $selected.State) }
    $message = if ($DeleteFiles) {
        "Move $($files.Count) tracked file(s) for this download to Recycle Bin and remove it from History? Other files stay untouched. Empty Recycle Bin later to reclaim space."
    } else { 'Remove this download from History? Its downloaded files and saved progress stay on disk.' }
    $choice = [Windows.Forms.MessageBox]::Show($form, $message, 'Remove download', 'YesNo', 'Question', 'Button2')
    if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
    if ($DeleteFiles) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($file in $files) {
            Assert-NoDownloadLinks $file
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
    }
    Start-DownloadLog (Get-HistoryLogPath $selected.Directory)
    Add-DownloadLog $(if ($DeleteFiles) { 'Removed from History. Tracked download files were moved to Recycle Bin.' } else {
        'Removed from History. Downloaded files and saved progress were kept.' })
    $archive = Join-Path $historyRoot 'Removed'
    [void][IO.Directory]::CreateDirectory($archive)
    $id = [IO.Path]::GetFileName($selected.Directory)
    [IO.Directory]::Move($selected.Directory, (Join-Path $archive $id))
    $history.Items.Remove($selected.Row)
    $script:jobs.Remove($id)
    Update-DownloadHistory
}
$removeDownload.Add_Click({ try { Remove-SelectedDownload $false } catch { Show-UiError $_.Exception.Message } })
$deleteDownload.Add_Click({ try { Remove-SelectedDownload $true } catch { Show-UiError $_.Exception.Message } })
function Open-SelectedLog {
    $selected = Get-SelectedDownload
    if ($selected.State.SummaryPath -and [IO.File]::Exists($selected.State.SummaryPath)) {
        try { Invoke-Item -LiteralPath $selected.State.SummaryPath }
        catch { Show-UiError 'Windows could not open the download log.' }
    }
}
$savedFolder = Add-Control Button 'Saved data folder' 27 745 150 30
$savedFolder.Add_Click({
    $selected = Get-SelectedDownload
    if ($selected.State.Output) { Invoke-Item -LiteralPath ([IO.Path]::GetDirectoryName($selected.State.Output)) }
})
$clearPartial = Add-Control Button 'Clear partials...' 187 745 130 30
$clearPartial.Add_Click({
    try {
        if ($script:activeJob) { throw 'Wait until the active download stops before clearing data.' }
        $selected = Get-SelectedDownload
        if (-not $selected.State.Output) { return }
        $folder = [IO.Path]::GetDirectoryName($selected.State.Output)
        $filename = [regex]::Escape([IO.Path]::GetFileName($selected.State.Output))
        $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
            $_.Name -match ('^' + $filename + '\.[0-9a-f]{16}\.part(?:\.aria2|\.resume\.json)?$')
        })
        if (-not $files.Count) { throw 'No saved partial files were found for this output name.' }
        $choice = [Windows.Forms.MessageBox]::Show($form,
            'Move the partial downloads for this output to Recycle Bin? Resume will start from zero.',
            'Clear saved progress', 'YesNo', 'Question', 'Button2')
        if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($file in $files) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
        $detail.Text = 'Saved partials moved to Recycle Bin. Empty Recycle Bin to reclaim storage.'
    } catch { Show-UiError $_.Exception.Message }
})
$openLog.Add_Click({ Open-SelectedLog })
$history.Add_SelectedIndexChanged({ Update-SelectedDownload })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try { Update-DownloadHistory }
    catch { $detail.Text = 'History refresh failed. The background transfer can still continue.' }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($eventArgs.CloseReason -ne [Windows.Forms.CloseReason]::UserClosing) { return }
    try { Update-DownloadHistory } catch { Write-Verbose 'Could not refresh before closing.' }
    if (-not $script:activeJob) { return }
    $choice = [Windows.Forms.MessageBox]::Show($form,
        'Close the window and keep downloading in the background?',
        'Download in progress', 'YesNo', 'Question', 'Button2')
    if ($choice -ne [Windows.Forms.DialogResult]::Yes) { $eventArgs.Cancel = $true }
})

# Update checks run in a separate process so network delays never freeze the GUI.
$updateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GOB'
$updateStatePath = Join-Path $updateRoot 'update-state.json'
$updateButton = Add-Control Button 'Check for updates' 445 745 175 30
$script:updateAvailable = $false
$script:updateCheck = $null
$script:lastUpdateCheck = [DateTime]::MinValue
$script:lastUpdateMessage = ''
function Start-GobUpdate([string]$Mode) {
    $args = '--update {0} {1}' -f $Mode, $PID
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GOBExecutable
    $startInfo.Arguments = $args
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $script:updateCheck = [Diagnostics.Process]::Start($startInfo)
    $script:lastUpdateCheck = Get-Date
}
$updateButton.Add_Click({
    if ($script:updateCheck -and -not $script:updateCheck.HasExited) { return }
    if ($script:updateAvailable) {
        if ($script:activeJob) { Show-UiError 'Pause or finish the active download before updating GOB.'; return }
        $script:gobUpdating = $true
        Start-GobUpdate 'Install'
        $updateButton.Enabled = $false
        $updateButton.Text = 'Downloading update...'
    } else { Start-GobUpdate 'Check'; $updateButton.Text = 'Checking...' }
})
$updateTimer = New-Object Windows.Forms.Timer
$updateTimer.Interval = 1500
$updateTimer.Add_Tick({
    try {
        if (-not $script:updateCheck -or $script:updateCheck.HasExited) {
            if ((Get-Date) - $script:lastUpdateCheck -gt [TimeSpan]::FromHours(1)) { Start-GobUpdate 'Check' }
        }
        if (Test-Path -LiteralPath $updateStatePath) {
            $updateState = Get-Content -LiteralPath $updateStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($updateState.status -eq 'Available') {
                $script:updateAvailable = $true
                $updateButton.Text = 'Update GOB '+$updateState.version
                if ($script:lastUpdateMessage -ne $updateState.version) {
                    $script:lastUpdateMessage = $updateState.version
                    $detail.Text = $updateState.message
                    [void][Windows.Forms.MessageBox]::Show($form, $updateState.message+' Use the Update GOB button when your download has stopped.', 'GOB update available')
                }
            } elseif ($updateState.status -eq 'Ready') { $form.Close() }
            elseif ($updateState.status -in @('Current','Error','Installed')) {
                $script:gobUpdating = $false
                $updateButton.Enabled = $true
                $updateButton.Text = if ($script:updateAvailable) { 'Retry update' } else { 'Check for updates' }
            }
        }
    } catch { Write-Verbose 'Update status is temporarily unavailable.' }
})
if (-not $GobSmokeTest) { $updateTimer.Start() }

$guiLock = [Threading.Mutex]::new($false, 'Local\DropboxDownloaderHistoryWindow')
$guiLocked = $false
try {
    try { $guiLocked = $guiLock.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $guiLocked = $true }
    if (-not $guiLocked) { Show-UiError 'The downloader window is already open.'; return }
    Update-DownloadHistory
    if ($history.Items.Count) { $history.Items[0].Selected = $true }
    $timer.Start()
    if ($GobSmokeTest) {
        $smokeTimer = New-Object Windows.Forms.Timer
        $smokeTimer.Interval = 700
        $smokeTimer.Add_Tick({ $smokeTimer.Stop(); $form.Close() })
        $form.Add_Shown({ $smokeTimer.Start() })
    }
    [void]$form.ShowDialog()
    if ($GobSmokeTest) { $smokeTimer.Dispose() }
} finally {
    $updateTimer.Dispose()
    $timer.Dispose()
    $form.Dispose()
    if ($guiLocked) { $guiLock.ReleaseMutex() }
    $guiLock.Dispose()
}
