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

# Borderless caption, with Windows-native hit testing for resize and snap behavior.
if (-not ('GobWindow.GobForm' -as [type])) {
    $gobFormSource = @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace GobWindow {
  public class GobForm : Form {
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    const int WM_NCHITTEST=0x84, WM_NCLBUTTONDOWN=0xA1, HTCAPTION=2;
    public int ResizeBorder=7;
    public bool GobMaximized=false;
    protected override void WndProc(ref Message m) {
      if (m.Msg==WM_NCHITTEST && !GobMaximized) {
        base.WndProc(ref m);
        if ((int)m.Result==1) {
          long lp=m.LParam.ToInt64(); int sx=(short)(lp&0xffff), sy=(short)((lp>>16)&0xffff);
          Point p=PointToClient(new Point(sx,sy)); int b=ResizeBorder;
          bool l=p.X<b, r=p.X>=ClientSize.Width-b, t=p.Y<b, bt=p.Y>=ClientSize.Height-b;
          if (t&&l) m.Result=(IntPtr)13; else if(t&&r) m.Result=(IntPtr)14;
          else if(bt&&l) m.Result=(IntPtr)16; else if(bt&&r) m.Result=(IntPtr)17;
          else if(l) m.Result=(IntPtr)10; else if(r) m.Result=(IntPtr)11;
          else if(t) m.Result=(IntPtr)12; else if(bt) m.Result=(IntPtr)15;
        }
        return;
      }
      base.WndProc(ref m);
    }
    public void BeginCaptionDrag() { ReleaseCapture(); SendMessage(Handle,WM_NCLBUTTONDOWN,(IntPtr)HTCAPTION,IntPtr.Zero); }
  }
}
'@
    Add-Type -TypeDefinition $gobFormSource -ReferencedAssemblies @(
        [Windows.Forms.Form].Assembly.Location,
        [Drawing.Color].Assembly.Location
    )
}
$form = New-Object GobWindow.GobForm
$form.Text = 'GOB — Grab Our Bytes'
$form.Icon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'GOB.ico'))
$form.ClientSize = [Drawing.Size]::new(980, 860)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'None'
$form.MinimumSize = [Drawing.Size]::new(780, 840)
$form.AutoScroll = $false
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(15, 17, 21)
$form.ForeColor = [Drawing.Color]::FromArgb(239, 242, 247)
$script:ContentTop = 42

$caption = New-Object Windows.Forms.Panel
$caption.Dock = 'Top'
$caption.Height = $script:ContentTop
$caption.BackColor = [Drawing.Color]::FromArgb(18, 21, 26)
$caption.Cursor = [Windows.Forms.Cursors]::SizeAll
$form.Controls.Add($caption)
$captionIcon = New-Object Windows.Forms.PictureBox
$captionIcon.Size = [Drawing.Size]::new(22,22)
$captionIcon.Location = [Drawing.Point]::new(14,10)
$captionIcon.SizeMode = 'Zoom'
$captionIcon.Image = $form.Icon.ToBitmap()
$captionIcon.Cursor = [Windows.Forms.Cursors]::SizeAll
$caption.Controls.Add($captionIcon)
$captionTitle = New-Object Windows.Forms.Label
$captionTitle.Text = 'GOB'
$captionTitle.Font = [Drawing.Font]::new('Segoe UI Semibold',10)
$captionTitle.ForeColor = [Drawing.Color]::FromArgb(238,242,247)
$captionTitle.AutoSize = $true
$captionTitle.Location = [Drawing.Point]::new(44,12)
$captionTitle.Cursor = [Windows.Forms.Cursors]::SizeAll
$caption.Controls.Add($captionTitle)
$captionSubtitle = New-Object Windows.Forms.Label
$captionSubtitle.Text = 'GRAB OUR BYTES'
$captionSubtitle.Font = [Drawing.Font]::new('Segoe UI',8)
$captionSubtitle.ForeColor = [Drawing.Color]::FromArgb(133,146,163)
$captionSubtitle.AutoSize = $true
$captionSubtitle.Location = [Drawing.Point]::new(87,14)
$captionSubtitle.Cursor = [Windows.Forms.Cursors]::SizeAll
$caption.Controls.Add($captionSubtitle)
$captionButtons = New-Object Windows.Forms.FlowLayoutPanel
$captionButtons.Dock = 'Right'
$captionButtons.Width = 138
$captionButtons.Height = $script:ContentTop
$captionButtons.FlowDirection = 'RightToLeft'
$captionButtons.WrapContents = $false
$captionButtons.Padding = [Windows.Forms.Padding]::new(0)
$captionButtons.Margin = [Windows.Forms.Padding]::new(0)
$captionButtons.BackColor = $caption.BackColor
$caption.Controls.Add($captionButtons)
$script:gobCustomMaximized = $false
$script:gobRestoreBounds = $form.Bounds
function Set-GobCustomMaximized([bool]$Maximized) {
    if ($Maximized -and -not $script:gobCustomMaximized) {
        $script:gobRestoreBounds = $form.Bounds
        $form.WindowState = [Windows.Forms.FormWindowState]::Normal
        $form.Bounds = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $script:gobCustomMaximized = $true
        $form.GobMaximized = $true
    } elseif (-not $Maximized -and $script:gobCustomMaximized) {
        $script:gobCustomMaximized = $false
        $form.GobMaximized = $false
        $form.WindowState = [Windows.Forms.FormWindowState]::Normal
        $form.Bounds = $script:gobRestoreBounds
    }
}
foreach ($captionSpec in @(@('×','Close'),@('□','Maximize'),@('—','Minimize'))) {
    $captionButton = New-Object Windows.Forms.Button
    $captionButton.Text = $captionSpec[0]
    $captionButton.Tag = $captionSpec[1]
    $captionButton.Size = [Drawing.Size]::new(46,$script:ContentTop)
    $captionButton.Margin = [Windows.Forms.Padding]::new(0)
    $captionButton.FlatStyle = 'Flat'
    $captionButton.FlatAppearance.BorderSize = 0
    $captionButton.BackColor = $caption.BackColor
    $captionButton.ForeColor = [Drawing.Color]::FromArgb(218,224,232)
    $captionButton.Font = [Drawing.Font]::new('Segoe UI',11)
    $captionButton.Cursor = [Windows.Forms.Cursors]::Hand
    $captionButton.Add_Click({
        switch ($this.Tag) {
            'Close' { $form.Close() }
            'Minimize' { $form.WindowState = [Windows.Forms.FormWindowState]::Minimized }
            'Maximize' { Set-GobCustomMaximized (-not $script:gobCustomMaximized) }
        }
    })
    if ($captionSpec[1] -eq 'Close') {
        $captionButton.Add_MouseEnter({ $this.BackColor = [Drawing.Color]::FromArgb(196,48,48); $this.ForeColor = [Drawing.Color]::White })
        $captionButton.Add_MouseLeave({ $this.BackColor = $caption.BackColor; $this.ForeColor = [Drawing.Color]::FromArgb(218,224,232) })
    } else {
        $captionButton.Add_MouseEnter({ $this.BackColor = [Drawing.Color]::FromArgb(43,49,58) })
        $captionButton.Add_MouseLeave({ $this.BackColor = $caption.BackColor })
    }
    $captionButtons.Controls.Add($captionButton)
}
$dragCaption = { if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { $form.BeginCaptionDrag() } }
$caption.Add_MouseDown($dragCaption)
$captionIcon.Add_MouseDown($dragCaption)
$captionTitle.Add_MouseDown($dragCaption)
$captionSubtitle.Add_MouseDown($dragCaption)
$toggleMaximize = { Set-GobCustomMaximized (-not $script:gobCustomMaximized) }
$caption.Add_DoubleClick($toggleMaximize)
$captionIcon.Add_DoubleClick($toggleMaximize)
$captionTitle.Add_DoubleClick($toggleMaximize)
$captionSubtitle.Add_DoubleClick($toggleMaximize)


function Add-Control([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = New-Object "Windows.Forms.$Type"
    $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X, ($Y + $script:ContentTop))
    $control.Size = [Drawing.Size]::new($Width, $Height)
    $form.Controls.Add($control)
    return $control
}

$title = Add-Control Label 'GOB — Grab Our Bytes' 24 16 612 36
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 20)
$null = Add-Control Label 'Download a file or a folder as separate, resumable files.' 26 57 608 24

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
        $status.Text = 'Detected shared folder. GOB will list and download its files separately.'
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
$folderFiles = Add-Control Button 'Show files' 325 785 125 30

# Keep the form fluid without Anchor/manual-layout conflicts. The download engine
# and all existing transfer and history handlers remain unchanged.
function Resize-Layout {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $right = $w - 28
    $gap = 9
    $paste.Left = $right - 84
    $browse.Left = $paste.Left
    $start.Left = $right - $start.Width
    $linkBox.Width = [Math]::Max(260, $paste.Left - $linkBox.Left - $gap)
    $directory.Width = [Math]::Max(260, $browse.Left - $directory.Left - $gap)
    $nameBox.Width = [Math]::Max(300, $right - $nameBox.Left)
    $checksum.Width = [Math]::Max(260, $right - $checksum.Left)
    $status.Width = [Math]::Max(260, $start.Left - $status.Left - $gap)
    $heading.Width = [Math]::Max(500, $right - $heading.Left)
    $history.Width = $heading.Width
    $actionsTop = $h - 116
    $history.Height = [Math]::Max(90, [Math]::Min(220, $actionsTop - $history.Top - 70))
    $progress.Top = $history.Bottom + 12
    $detail.Top = $progress.Bottom + 8
    foreach ($button in @($resume,$openLog,$markDone,$pause)) { $button.Top = $actionsTop }
    $middleTop = $h - 74
    $bottomTop = $h - 32
    $savedFolder.Top = $middleTop
    $clearPartial.Top = $middleTop
    $updateButton.Top = $middleTop
    $removeDownload.Top = $bottomTop
    $deleteDownload.Top = $bottomTop
    $folderFiles.Top = $bottomTop
    $resume.Left = 26
    $openLog.Left = 187
    $markDone.Left = 325
    $pause.Left = $right - $pause.Width
    $savedFolder.Left = 27
    $clearPartial.Left = 187
    $updateButton.Left = $right - $updateButton.Width
    $removeDownload.Left = 27
    $deleteDownload.Left = 187
    $folderFiles.Left = 325
    $notify.Left = [int](($w - $notify.Width) / 2)
    $brutal.Left = $right - $brutal.Width
    $heading.Width = $history.Width
    $progress.Width = $history.Width
    $detail.Width = $history.Width
    $columnWidths = @([int]($history.Width*.29),[int]($history.Width*.15),[int]($history.Width*.12),[int]($history.Width*.15),[int]($history.Width*.11))
    for ($i=0; $i -lt 5; $i++) { $history.Columns[$i].Width = [Math]::Max(70,$columnWidths[$i]) }
    $columnTotal = 0
    for ($i=0; $i -lt 5; $i++) { $columnTotal += $history.Columns[$i].Width }
    $history.Columns[5].Width = [Math]::Max(85,$history.Width - $columnTotal - 4)
}
$form.Add_Resize({
    try { Resize-Layout }
    catch { if ($detail) { $detail.Text = 'Layout adjustment failed: ' + $_.Exception.Message } }
    foreach ($button in $captionButtons.Controls) {
        if ($button.Tag -eq 'Maximize') {
            $button.Text = if ($script:gobCustomMaximized) { '❐' } else { '□' }
        }
    }
})
function Set-UiTheme([Windows.Forms.Control]$Control) {
    $Control.BackColor = [Drawing.Color]::FromArgb(28,32,39)
    $Control.ForeColor = [Drawing.Color]::FromArgb(239,242,247)
    if ($Control -is [Windows.Forms.Button]) {
        $Control.FlatStyle = 'Flat'
        $Control.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(62,70,82)
        $Control.BackColor = [Drawing.Color]::FromArgb(36,42,51)
    } elseif ($Control -is [Windows.Forms.TextBox] -or $Control -is [Windows.Forms.NumericUpDown]) {
        $Control.BackColor = [Drawing.Color]::FromArgb(20,23,28)
        $Control.ForeColor = [Drawing.Color]::FromArgb(245,247,251)
    } elseif ($Control -is [Windows.Forms.ListView]) {
        $Control.BackColor = [Drawing.Color]::FromArgb(20,23,28)
        $Control.ForeColor = [Drawing.Color]::FromArgb(239,242,247)
        $Control.BorderStyle = 'FixedSingle'
    } elseif ($Control -is [Windows.Forms.ProgressBar]) {
        $Control.BackColor = [Drawing.Color]::FromArgb(20,23,28)
    }
}
foreach ($control in $form.Controls) { Set-UiTheme $control }
$caption.BackColor = [Drawing.Color]::FromArgb(18,21,26)
$captionButtons.BackColor = $caption.BackColor
$captionTitle.BackColor = $caption.BackColor
$captionSubtitle.BackColor = $caption.BackColor
$captionIcon.BackColor = $caption.BackColor
$start.BackColor = [Drawing.Color]::FromArgb(10,105,232)
$start.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(10,105,232)
$script:jobs = @{}
$script:activeJob = $false
$historyRoot = Get-HistoryDirectory
[void][IO.Directory]::CreateDirectory($historyRoot)

function Show-UiError([string]$Message) {
    [void][Windows.Forms.MessageBox]::Show($form, $Message, 'GOB — Grab Our Bytes')
}

function Get-SelectedDownload {
    if ($history.SelectedItems.Count) { return $script:jobs[([string]$history.SelectedItems[0].Name).Split(':')[0]] }
}

function Update-SelectedDownload {
    $selected = Get-SelectedDownload
    $resume.Enabled = $false
    $openLog.Enabled = $false
    $markDone.Enabled = $false
    $pause.Enabled = $false
    $removeDownload.Enabled = $false
    $deleteDownload.Enabled = $false
    $folderFiles.Enabled = $false
    if (-not $selected) {
        $progress.Style = 'Continuous'
        $progress.Value = 0
        $detail.Text = 'Start a download or select an entry from History.'
        return
    }

    $state = $selected.State
    $stage = $selected.Status
    $resume.Enabled = (-not $script:gobUpdating -and -not $script:activeJob -and $stage -in @('Paused','Failed','Interrupted','File found'))
    $folderFiles.Enabled = $selected.Job.FolderMode -eq 'files'
    $folderFiles.Text = if ($selected.ShowChildren) { 'Hide files' } else { 'Show files' }
    $pause.Enabled = $stage -in @('Starting','Running','Verifying')
    $pause.Text = if ($stage -eq 'Pausing') { 'Saving progress...' } elseif ($selected.Job.FolderMode -eq 'files') { 'Pause folder' } else { 'Pause download' }
    $removeDownload.Enabled = -not $script:activeJob -and -not $script:gobUpdating
    $deleteDownload.Enabled = -not $script:activeJob -and -not $script:gobUpdating
    $openLog.Enabled = $state.SummaryPath -and [IO.File]::Exists($state.SummaryPath)
    $markDone.Enabled = -not $script:activeJob -and $stage -eq 'File found'
    $metrics = $selected.Metrics
    if ($stage -eq 'Completed') {
        $progress.Style = 'Continuous'
        $progress.Value = 100
        $detail.Text = if ($state.IsFolder) { [string]$state.Message } else { 'Completed. File verified and saved.' }
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
        if ($state.IsFolder) { $detail.Text += '   |   ' + $state.CompletedFileCount + '/' + $state.FileCount + ' files'; if ($state.FileCount -gt 500) { $detail.Text += ' (first 500 rows shown)' } }
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

function Update-FolderRows($Record) {
    if (-not $Record.ChildRows) { $Record.ChildRows = @{} }
    $wanted = @()
    if ($Record.ShowChildren) {
        $offset = 1
        foreach ($child in $Record.State.Children) {
            $key = $Record.Row.Name + ':' + $child.Id
            $wanted += $key
            if (-not $Record.ChildRows.ContainsKey($key)) {
                $row = [Windows.Forms.ListViewItem]::new('  ' + [string]$child.Name)
                $row.Name = $key
                foreach ($column in 1..5) { [void]$row.SubItems.Add('') }
                [void]$history.Items.Insert($Record.Row.Index + $offset, $row)
                $Record.ChildRows[$key] = $row
            }
            $Record.ChildRows[$key].SubItems[1].Text = [string]$child.Status
            $offset++
        }
    }
    foreach ($key in @($Record.ChildRows.Keys)) {
        if ($key -notin $wanted) { $history.Items.Remove($Record.ChildRows[$key]); $Record.ChildRows.Remove($key) }
    }
}
$folderFiles.Add_Click({
    $selected = Get-SelectedDownload
    if ($selected) { $selected.ShowChildren = -not $selected.ShowChildren; Update-DownloadHistory }
})
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
        if ($record.State.IsFolder) {
            try {
                $children = @(Get-Content -LiteralPath (Join-Path $entry.FullName 'children-live.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
                $record.State | Add-Member -NotePropertyName Children -NotePropertyValue $children -Force
            } catch { $record.State | Add-Member -NotePropertyName Children -NotePropertyValue @() -Force }
        }
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
        Update-FolderRows $record
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
            if ($kind -eq 'Folder') { $display = 'Dropbox folder' }
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
            FolderMode = if ($kind -eq 'Folder') { 'files' } else { '' }
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
        if ($selected.Status -ne 'File found' -and (($selected.Job.FolderZip -and $selected.Job.FolderMode -ne 'files') -or $selected.Job.OnePass)) {
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
    } else { 'Remove this download (including all files in a folder job) from History? Downloaded files and saved progress stay on disk.' }
    $choice = [Windows.Forms.MessageBox]::Show($form, $message, 'Remove download', 'YesNo', 'Question', 'Button2')
    if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
    if ($DeleteFiles) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($file in $files) {
            Assert-NoDownloadLinks $file
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file, 'AllDialogs', 'SendToRecycleBin', 'ThrowException')
        }
    }
    $script:summaryPath = Get-HistoryLogPath $selected.Directory
    Add-DownloadLog $(if ($DeleteFiles) { 'Removed from History. Tracked download files were moved to Recycle Bin.' } else {
        'Removed from History. Downloaded files and saved progress were kept.' })
    $archive = Join-Path $historyRoot 'Removed'
    [void][IO.Directory]::CreateDirectory($archive)
    $id = [IO.Path]::GetFileName($selected.Directory)
    [IO.Directory]::Move($selected.Directory, (Join-Path $archive $id))
    foreach ($childRow in $selected.ChildRows.Values) { $history.Items.Remove($childRow) }
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
        $files = if ($selected.Job.FolderMode -eq 'files') {
            @(Get-OwnedDownloadFiles $selected.Directory $selected.State | Where-Object { $_ -match '\.part(?:\.aria2|\.resume\.json)?$' } | ForEach-Object { Get-Item -LiteralPath $_ })
        } else {
            @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
                $_.Name -match ('^' + $filename + '\.[0-9a-f]{16}\.part(?:\.aria2|\.resume\.json)?$')
            })
        }
        if (-not $files.Count) { throw 'No saved partial files were found for this output name.' }
        $choice = [Windows.Forms.MessageBox]::Show($form,
            'Move the partial downloads for this output to Recycle Bin? Resume will start from zero.',
            'Clear saved progress', 'YesNo', 'Question', 'Button2')
        if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($file in $files) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file.FullName, 'AllDialogs', 'SendToRecycleBin', 'ThrowException')
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
    if ($GobSmokeTest) { return }
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
Set-UiTheme $savedFolder
Set-UiTheme $clearPartial
Set-UiTheme $updateButton
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
    Resize-Layout
    Update-DownloadHistory
    if ($history.Items.Count) { $history.Items[0].Selected = $true }
    $timer.Start()
    [void]$form.ShowDialog()
} finally {
    $updateTimer.Dispose()
    $timer.Dispose()
    $form.Dispose()
    if ($guiLocked) { $guiLock.ReleaseMutex() }
    $guiLock.Dispose()
}
