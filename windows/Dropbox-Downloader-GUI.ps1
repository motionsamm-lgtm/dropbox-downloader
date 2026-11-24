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

# Borderless shell with native edge hit-testing: GOB owns the caption visuals,
# while Windows still handles normal drag/resize/maximize snapping.
if (-not ('GobWindow.GobForm' -as [type])) {
    $windowsUiReferences = @([Windows.Forms.Form].Assembly.Location, [Drawing.Color].Assembly.Location)
    Add-Type -ReferencedAssemblies $windowsUiReferences -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace GobWindow {
  public class GobCard : Panel {
    public Color Surface = Color.FromArgb(16,17,19);
    public Color Stroke = Color.FromArgb(42,43,46);
    public int CornerRadius = 14;
    public GobCard() { BackColor=Color.FromArgb(9,9,10); DoubleBuffered=true; SetStyle(ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true); }
    protected override void OnPaintBackground(PaintEventArgs e) {
      e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      int d=CornerRadius*2; Rectangle r=new Rectangle(0,0,Width-1,Height-1);
      using(var bg=new SolidBrush(BackColor)) e.Graphics.FillRectangle(bg,ClientRectangle);
      using(var path=new System.Drawing.Drawing2D.GraphicsPath()) {
        path.AddArc(r.X,r.Y,d,d,180,90); path.AddArc(r.Right-d,r.Y,d,d,270,90);
        path.AddArc(r.Right-d,r.Bottom-d,d,d,0,90); path.AddArc(r.X,r.Bottom-d,d,d,90,90); path.CloseFigure();
        using(var b=new SolidBrush(Surface)) e.Graphics.FillPath(b,path);
        using(var p=new Pen(Stroke,1)) e.Graphics.DrawPath(p,path);
      }
    }
    protected override void OnPaint(PaintEventArgs e) { base.OnPaint(e); }
  }
  public class GobProgressBar : ProgressBar {
    public Color TrackColor=Color.FromArgb(47,48,52);
    public Color BarColor=Color.FromArgb(145,182,255);
    public GobProgressBar() { SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true); Minimum=0; Maximum=100; }
    public new int Value { get { return base.Value; } set { base.Value=value; Invalidate(); } }
    protected override void OnPaint(PaintEventArgs e) {
      e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      Rectangle r=ClientRectangle; if(r.Width<2||r.Height<2)return;
      r.Inflate(-1,-2); int rad=Math.Max(2,r.Height/2);
      using(var path=new System.Drawing.Drawing2D.GraphicsPath()) {
        path.AddArc(r.X,r.Y,rad*2,rad*2,90,180); path.AddArc(r.Right-rad*2,r.Y,rad*2,rad*2,270,180); path.CloseFigure();
        using(var b=new SolidBrush(TrackColor)) e.Graphics.FillPath(b,path);
        e.Graphics.SetClip(path);
        int fill;
        if(Style==ProgressBarStyle.Marquee) {
          int segment=Math.Max(24,r.Width/4); int travel=Math.Max(1,r.Width+segment);
          int offset=(Environment.TickCount/14)%travel-segment; fill=segment;
          Rectangle f=new Rectangle(r.X+offset,r.Y,fill,r.Height);
          using(var fb=new SolidBrush(BarColor)) e.Graphics.FillRectangle(fb,f);
        } else {
          int range=Math.Max(1,Maximum-Minimum); fill=(int)Math.Round(r.Width*Math.Max(0,Math.Min(1,(Value-Minimum)/(double)range)));
          if(fill>0) { Rectangle f=new Rectangle(r.X,r.Y,Math.Min(fill,r.Width),r.Height); using(var fb=new SolidBrush(BarColor)) e.Graphics.FillRectangle(fb,f); }
        }
        e.Graphics.ResetClip();
      }
    }
  }
  public class GobForm : Form {
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("dwmapi.dll", PreserveSig=true)] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    const int WM_NCHITTEST=0x84, WM_NCLBUTTONDOWN=0xA1, HTCAPTION=2;
    const int DWMWA_WINDOW_CORNER_PREFERENCE=33, DWMWCP_ROUND=2;
    public int ResizeBorder=7;
    protected override void OnHandleCreated(EventArgs e) {
      base.OnHandleCreated(e);
      try { int preference=DWMWCP_ROUND; DwmSetWindowAttribute(Handle,DWMWA_WINDOW_CORNER_PREFERENCE,ref preference,sizeof(int)); }
      catch { /* Older Windows versions do not expose DWM corner preferences. */ }
    }
    protected override void WndProc(ref Message m) {
      if (m.Msg==WM_NCHITTEST && WindowState!=FormWindowState.Maximized) {
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
}

$form = New-Object GobWindow.GobForm
$form.Text = 'GOB — Grab Our Bytes'
$form.Icon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'GOB.ico'))
$form.ClientSize = [Drawing.Size]::new(1160, 900)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'None'
$form.MinimumSize = [Drawing.Size]::new(980, 740)
$form.AutoScroll = $false
$form.AutoScrollMinSize = [Drawing.Size]::new(0, 0)
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(9, 9, 10)
$form.ForeColor = [Drawing.Color]::FromArgb(235, 235, 239)
$script:ContentTop = 42

$caption = New-Object Windows.Forms.Panel
$caption.Dock = 'Top'
$caption.Height = $script:ContentTop
$caption.BackColor = [Drawing.Color]::FromArgb(13, 13, 15)
$caption.Cursor = [Windows.Forms.Cursors]::SizeAll
$form.Controls.Add($caption)
$captionIcon = New-Object Windows.Forms.PictureBox
$captionIcon.Size = [Drawing.Size]::new(24,24)
$captionIcon.Location = [Drawing.Point]::new(13,9)
$captionIcon.SizeMode = 'Zoom'
$logoPath = Join-Path $PSScriptRoot 'GOB.png'
if ([IO.File]::Exists($logoPath)) {
    $logoStream = [IO.MemoryStream]::new([IO.File]::ReadAllBytes($logoPath))
    try {
        $logoSource = [Drawing.Image]::FromStream($logoStream)
        $captionIcon.Image = [Drawing.Bitmap]::new($logoSource)
        $logoSource.Dispose()
    } finally { $logoStream.Dispose() }
} else { $captionIcon.Image = $form.Icon.ToBitmap() }
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
            'Maximize' {
                if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Maximized) {
                    $form.WindowState = [Windows.Forms.FormWindowState]::Normal
                    $this.Text = '□'
                } else {
                    $form.WindowState = [Windows.Forms.FormWindowState]::Maximized
                    $this.Text = '❐'
                }
            }
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
$toggleMaximize = {
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Maximized) { $form.WindowState = [Windows.Forms.FormWindowState]::Normal }
    else { $form.WindowState = [Windows.Forms.FormWindowState]::Maximized }
}
$caption.Add_DoubleClick($toggleMaximize)
$captionIcon.Add_DoubleClick($toggleMaximize)
$captionTitle.Add_DoubleClick($toggleMaximize)
$captionSubtitle.Add_DoubleClick($toggleMaximize)

function Add-Control([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = if ($Type -eq 'ProgressBar') { New-Object GobWindow.GobProgressBar } else { New-Object "Windows.Forms.$Type" }
    $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X, ($Y + $script:ContentTop))
    $control.Size = [Drawing.Size]::new($Width, $Height)
    $form.Controls.Add($control)
    return $control
}

$title = Add-Control Label 'Transfers' 24 16 612 36
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 20)
$subtitle = Add-Control Label 'Download files and folders. Pick up where you left off.' 26 57 608 24

$linkLabel = Add-Control Label 'Dropbox link' 26 79 310 21
$linkBox = Add-Control TextBox '' 26 102 515 28
$paste = Add-Control Button 'Paste link' 550 98 84 33
$paste.Add_Click({
    if ([Windows.Forms.Clipboard]::ContainsText()) { $linkBox.Text = [Windows.Forms.Clipboard]::GetText().Trim() }
})
$nameLabel = Add-Control Label 'Output filename (optional)' 26 145 608 22
$nameBox = Add-Control TextBox '' 26 169 608 28
$directoryLabel = Add-Control Label 'Save folder' 26 209 350 21
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
$connectionsLabel = Add-Control Label 'Connections' 26 303 107 20
$connections = Add-Control NumericUpDown '' 26 326 95 26
$connections.Minimum = 1
$connections.Maximum = 4
$connections.Value = 4
$limitLabel = Add-Control Label 'Speed cap · MiB/s (0 = off)' 140 303 190 20
$limit = Add-Control NumericUpDown '0' 140 326 95 26
$limit.Maximum = 999
$onePass = Add-Control CheckBox 'One pass (start from zero)' 301 326 278 25
$checksumLabel = Add-Control Label 'Expected SHA-256 (optional)' 26 368 235 21
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

# The original transfer workers and history code stay intact. This only arranges
# their existing controls into two resizable, themed surfaces.
function Resize-Layout {
    if (-not $leftCard -or -not $rightCard -or $leftCard.IsDisposed) { return }
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $margin = 24
    $gap = 18
    $available = [Math]::Max(820, $w - ($margin * 2) - $gap)
    $leftWidth = [int][Math]::Min(500, [Math]::Max(380, $available * 0.405))
    $rightWidth = [Math]::Max(420, $available - $leftWidth)
    $panelTop = 136
    $panelHeight = [Math]::Max(650, $h - $panelTop - 24)
    $leftCard.Location = [Drawing.Point]::new($margin, $panelTop)
    $leftCard.Size = [Drawing.Size]::new($leftWidth, $panelHeight)
    $rightCard.Location = [Drawing.Point]::new(($margin + $leftWidth + $gap), $panelTop)
    $rightCard.Size = [Drawing.Size]::new($rightWidth, $panelHeight)

    $inner = $leftWidth - 44
    $fieldButton = 82
    $leftHeading.Location = [Drawing.Point]::new(22, 20)
    $linkLabel.Location = [Drawing.Point]::new(22, 62)
    $linkBox.Location = [Drawing.Point]::new(22, 84)
    $linkBox.Size = [Drawing.Size]::new([Math]::Max(180, $inner - $fieldButton - 9), 35)
    $paste.Location = [Drawing.Point]::new(($leftWidth - 22 - $fieldButton), 83)
    $paste.Size = [Drawing.Size]::new($fieldButton, 36)
    $nameLabel.Location = [Drawing.Point]::new(22, 137)
    $nameBox.Location = [Drawing.Point]::new(22, 160)
    $nameBox.Size = [Drawing.Size]::new($inner, 35)
    $directoryLabel.Location = [Drawing.Point]::new(22, 211)
    $directory.Location = [Drawing.Point]::new(22, 234)
    $directory.Size = [Drawing.Size]::new([Math]::Max(180, $inner - $fieldButton - 9), 35)
    $browse.Location = [Drawing.Point]::new(($leftWidth - 22 - $fieldButton), 233)
    $browse.Size = [Drawing.Size]::new($fieldButton, 36)
    $subfolderOption.Location = [Drawing.Point]::new(22, 291)
    $subfolderOption.Size = [Drawing.Size]::new(190, 27)
    $notify.Location = [Drawing.Point]::new(218, 291)
    $notify.Size = [Drawing.Size]::new([Math]::Max(110, $inner - 196), 27)
    $brutal.Location = [Drawing.Point]::new(22, 326)
    $brutal.Size = [Drawing.Size]::new(180, 27)
    $settingsHeading.Location = [Drawing.Point]::new(22, 371)
    $connectionsLabel.Location = [Drawing.Point]::new(22, 405)
    $connections.Location = [Drawing.Point]::new(22, 428)
    $connections.Size = [Drawing.Size]::new(116, 31)
    $limitLabel.Location = [Drawing.Point]::new(158, 405)
    $limit.Location = [Drawing.Point]::new(158, 428)
    $limit.Size = [Drawing.Size]::new(116, 31)
    $onePass.Location = [Drawing.Point]::new(22, 472)
    $onePass.Size = [Drawing.Size]::new($inner, 27)
    $checksumLabel.Location = [Drawing.Point]::new(22, 517)
    $checksum.Location = [Drawing.Point]::new(22, 540)
    $checksum.Size = [Drawing.Size]::new($inner, 35)
    $status.Location = [Drawing.Point]::new(22, 594)
    $status.Size = [Drawing.Size]::new($inner, 50)
    $start.Location = [Drawing.Point]::new(($leftWidth - 22 - 172), ([Math]::Min(675, $panelHeight - 60)))
    $start.Size = [Drawing.Size]::new(172, 42)

    $rightInner = $rightWidth - 40
    $rightHeading.Location = [Drawing.Point]::new(20, 20)
    $rightHeading.Size = [Drawing.Size]::new($rightInner, 28)
    $history.Location = [Drawing.Point]::new(20, 61)
    $history.Size = [Drawing.Size]::new($rightInner, [Math]::Max(190, [Math]::Min(330, $panelHeight - 335)))
    $historyEmpty.Location = [Drawing.Point]::new(20, 85)
    $historyEmpty.Size = [Drawing.Size]::new($rightInner, [Math]::Max(130, [Math]::Min(260, $history.Height - 24)))
    $progress.Location = [Drawing.Point]::new(20, ($history.Bottom + 16))
    $progress.Size = [Drawing.Size]::new($rightInner, 9)
    $detail.Location = [Drawing.Point]::new(20, ($progress.Bottom + 10))
    $detail.Size = [Drawing.Size]::new($rightInner, 42)
    $actionsY = [Math]::Max(($detail.Bottom + 12), ($panelHeight - 162))
    $buttonGap = 6
    $rowButtonWidths = @(112, 108, 108, [Math]::Max(112, $rightInner - 112 - 108 - 108 - ($buttonGap * 3)))
    $rowButtons = @($resume, $openLog, $markDone, $pause)
    $x = 20
    for ($i = 0; $i -lt $rowButtons.Count; $i++) {
        $rowButtons[$i].Location = [Drawing.Point]::new($x, $actionsY)
        $rowButtons[$i].Size = [Drawing.Size]::new($rowButtonWidths[$i], 34)
        $x += $rowButtonWidths[$i] + $buttonGap
    }
    $row2Y = $actionsY + 42
    $savedFolder.Location = [Drawing.Point]::new(20, $row2Y)
    $savedFolder.Size = [Drawing.Size]::new(130, 34)
    $clearPartial.Location = [Drawing.Point]::new(156, $row2Y)
    $clearPartial.Size = [Drawing.Size]::new(124, 34)
    $updateButton.Location = [Drawing.Point]::new(286, $row2Y)
    $updateButton.Size = [Drawing.Size]::new([Math]::Max(132, $rightInner - 266), 34)
    $row3Y = $row2Y + 42
    $removeDownload.Location = [Drawing.Point]::new(20, $row3Y)
    $removeDownload.Size = [Drawing.Size]::new(142, 34)
    $deleteDownload.Location = [Drawing.Point]::new(168, $row3Y)
    $deleteDownload.Size = [Drawing.Size]::new(126, 34)
    $folderFiles.Location = [Drawing.Point]::new(300, $row3Y)
    $folderFiles.Size = [Drawing.Size]::new([Math]::Max(104, $rightInner - 280), 34)

    $columnFractions = @(0.23,0.15,0.13,0.14,0.12)
    $columnTotal = 0
    for ($i=0; $i -lt 5; $i++) {
        $history.Columns[$i].Width = [Math]::Max(50, [int]($rightInner * $columnFractions[$i]))
        $columnTotal += $history.Columns[$i].Width
    }
    $history.Columns[5].Width = [Math]::Max(65, $rightInner - $columnTotal - 4)
}
$form.Add_Resize({
    Resize-Layout
    foreach ($button in $captionButtons.Controls) {
        if ($button.Tag -eq 'Maximize') {
            $button.Text = if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Maximized) { '❐' } else { '□' }
        }
    }
})
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
    $historyEmpty.Visible = ($history.Items.Count -eq 0)
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

# Two focused surfaces replace the old wall-to-wall form: setup on the left,
# live downloads and their actions on the right. Controls keep their existing
# event handlers and download state.
$leftCard = New-Object GobWindow.GobCard
$rightCard = New-Object GobWindow.GobCard
$leftCard.TabStop = $false
$rightCard.TabStop = $false
$leftCard.Surface = [Drawing.Color]::FromArgb(16,17,19)
$rightCard.Surface = [Drawing.Color]::FromArgb(16,17,19)
$form.Controls.Add($leftCard)
$form.Controls.Add($rightCard)
$leftHeading = New-Object Windows.Forms.Label
$leftHeading.Text = 'New download'
$leftHeading.Font = [Drawing.Font]::new('Segoe UI Semibold', 15)
$leftHeading.ForeColor = [Drawing.Color]::FromArgb(240,240,243)
$leftHeading.BackColor = [Drawing.Color]::Transparent
$leftHeading.AutoSize = $true
$leftCard.Controls.Add($leftHeading)
$settingsHeading = New-Object Windows.Forms.Label
$settingsHeading.Text = 'Transfer settings'
$settingsHeading.Font = [Drawing.Font]::new('Segoe UI Semibold', 11)
$settingsHeading.ForeColor = [Drawing.Color]::FromArgb(220,220,225)
$settingsHeading.BackColor = [Drawing.Color]::Transparent
$settingsHeading.AutoSize = $true
$leftCard.Controls.Add($settingsHeading)
$heading.Visible = $false
$rightHeading = New-Object Windows.Forms.Label
$rightHeading.Text = 'Downloads'
$rightHeading.Font = [Drawing.Font]::new('Segoe UI Semibold', 15)
$rightHeading.ForeColor = [Drawing.Color]::FromArgb(240,240,243)
$rightHeading.BackColor = [Drawing.Color]::Transparent
$rightHeading.AutoSize = $true
$rightCard.Controls.Add($rightHeading)
$historyEmpty = New-Object Windows.Forms.Label
$historyEmpty.Text = 'Your downloads will appear here.' + [Environment]::NewLine + 'Paste a Dropbox link to get started.'
$historyEmpty.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$historyEmpty.Font = [Drawing.Font]::new('Segoe UI', 10)
$historyEmpty.ForeColor = [Drawing.Color]::FromArgb(137,140,148)
$historyEmpty.BackColor = [Drawing.Color]::FromArgb(19,20,22)
$historyEmpty.Enabled = $false
$historyEmpty.Visible = $false
$rightCard.Controls.Add($historyEmpty)

function Move-ToCard([Windows.Forms.Control]$Control, [Windows.Forms.Control]$Container) {
    $Control.Parent = $Container
}
$leftControls = @($linkLabel,$linkBox,$paste,$nameLabel,$nameBox,$directoryLabel,$directory,$browse,
    $subfolderOption,$notify,$brutal,$connectionsLabel,$connections,$limitLabel,$limit,$onePass,
    $checksumLabel,$checksum,$status,$start)
$rightControls = @($heading,$history,$progress,$detail,$resume,$openLog,$markDone,$pause,
    $removeDownload,$deleteDownload,$folderFiles,$savedFolder,$clearPartial,$updateButton)
foreach ($control in $leftControls) { Move-ToCard $control $leftCard }
foreach ($control in $rightControls) { Move-ToCard $control $rightCard }

function Set-GobButton([Windows.Forms.Button]$Button, [bool]$Primary = $false) {
    $Button.UseVisualStyleBackColor = $false
    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(55,56,60)
    $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(43,44,48)
    $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(55,57,62)
    $Button.BackColor = [Drawing.Color]::FromArgb(35,36,39)
    $Button.ForeColor = [Drawing.Color]::FromArgb(230,230,235)
    $Button.Font = [Drawing.Font]::new('Segoe UI', 9)
    $Button.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $Button.BackColor = [Drawing.Color]::FromArgb(201,220,255)
        $Button.ForeColor = [Drawing.Color]::FromArgb(24,36,58)
        $Button.FlatAppearance.BorderColor = $Button.BackColor
        $Button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(221,234,255)
        $Button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(178,204,245)
        $Button.Font = [Drawing.Font]::new('Segoe UI Semibold', 9)
    }
}
foreach ($control in $form.Controls) {
    if ($control -is [Windows.Forms.Label]) {
        $control.BackColor = [Drawing.Color]::Transparent
        $control.ForeColor = [Drawing.Color]::FromArgb(177,179,185)
    }
}
foreach ($control in $leftControls + $rightControls) {
    if ($control -is [Windows.Forms.Label]) {
        $control.BackColor = [Drawing.Color]::Transparent
        $control.ForeColor = [Drawing.Color]::FromArgb(177,179,185)
    } elseif ($control -is [Windows.Forms.TextBox] -or $control -is [Windows.Forms.NumericUpDown]) {
        $control.BackColor = [Drawing.Color]::FromArgb(28,29,32)
        $control.ForeColor = [Drawing.Color]::FromArgb(242,242,245)
        $control.Font = [Drawing.Font]::new('Segoe UI', 10)
        $control.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    } elseif ($control -is [Windows.Forms.CheckBox]) {
        $control.UseVisualStyleBackColor = $false
        $control.BackColor = [Drawing.Color]::FromArgb(16,17,19)
        $control.ForeColor = [Drawing.Color]::FromArgb(219,220,225)
        $control.FlatStyle = [Windows.Forms.FlatStyle]::Standard
    } elseif ($control -is [Windows.Forms.Button]) {
        Set-GobButton $control
    }
}
$history.BackColor = [Drawing.Color]::FromArgb(19,20,22)
$history.ForeColor = [Drawing.Color]::FromArgb(228,229,233)
$history.BorderStyle = [Windows.Forms.BorderStyle]::None
$history.OwnerDraw = $true
$history.GridLines = $false
$history.Font = [Drawing.Font]::new('Segoe UI', 9)
$history.Add_DrawColumnHeader({
    param($sender,$e)
    $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(25,26,29))
    try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $history.Font,
        [Drawing.Rectangle]::new($e.Bounds.X+9,$e.Bounds.Y,$e.Bounds.Width-12,$e.Bounds.Height),
        [Drawing.Color]::FromArgb(157,160,168), [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)
})
$history.Add_DrawItem({ param($sender,$e) })
$history.Add_DrawSubItem({
    param($sender,$e)
    $selectedRow = $history.SelectedIndices.Contains($e.ItemIndex)
    $rowColor = if ($selectedRow) { [Drawing.Color]::FromArgb(42,45,52) } elseif (($e.ItemIndex % 2) -eq 1) { [Drawing.Color]::FromArgb(22,23,26) } else { [Drawing.Color]::FromArgb(19,20,22) }
    $textColor = if ($selectedRow) { [Drawing.Color]::FromArgb(246,247,250) } else { [Drawing.Color]::FromArgb(220,221,225) }
    $brush = New-Object Drawing.SolidBrush $rowColor
    try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $history.Font,
        [Drawing.Rectangle]::new($e.Bounds.X+8,$e.Bounds.Y,$e.Bounds.Width-12,$e.Bounds.Height),
        $textColor, [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)
})
Set-GobButton $start $true
$title.ForeColor = [Drawing.Color]::FromArgb(245,245,247)
$title.BackColor = [Drawing.Color]::Transparent
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 25)
$subtitle.ForeColor = [Drawing.Color]::FromArgb(145,147,154)
$subtitle.BackColor = [Drawing.Color]::Transparent
$subtitle.Font = [Drawing.Font]::new('Segoe UI', 10)
$caption.BackColor = [Drawing.Color]::FromArgb(13,13,15)
$captionButtons.BackColor = $caption.BackColor
$captionTitle.BackColor = $caption.BackColor
$captionSubtitle.BackColor = $caption.BackColor
$captionIcon.BackColor = $caption.BackColor
$form.Add_Shown({ Resize-Layout })

$script:updateAvailable = $false
$script:updateCheck = $null
$script:lastUpdateCheck = [DateTime]::MinValue
$script:lastUpdateMessage = ''
function Start-GobUpdate([string]$Mode) {
    Remove-Item -LiteralPath $updateStatePath -Force -ErrorAction SilentlyContinue; $args = '--update {0} {1}' -f $Mode, $PID
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
    } else { Start-GobUpdate 'Check'; $updateButton.Text = 'Checking...'; $detail.Text = 'Checking for GOB updates...' }
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
                $updateButton.Text = if ($script:updateAvailable) { 'Retry update' } else { 'Check for updates' }; $detail.Text = [string]$updateState.message; if ($updateState.details) { $detail.Text += ' ' + [string]$updateState.details }
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
