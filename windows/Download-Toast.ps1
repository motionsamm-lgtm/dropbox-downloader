param([Parameter(Mandatory=$true)][string]$Data)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies ([Windows.Forms.Form].Assembly.Location) -TypeDefinition @'
public class QuietDownloadToast : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x80;
            return cp;
        }
    }
}
'@
$eventData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Data)) | ConvertFrom-Json
$toast = New-Object QuietDownloadToast
$toast.ShowInTaskbar = $false
$toast.FormBorderStyle = 'None'
$toast.TopMost = $true
$toast.StartPosition = 'Manual'
$toast.BackColor = [Drawing.Color]::FromArgb(245,247,251)
$toast.ForeColor = [Drawing.Color]::FromArgb(32,43,63)
$toast.ClientSize = [Drawing.Size]::new(358,122)
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$toast.Location = [Drawing.Point]::new(($area.Right-376),($area.Bottom-140))

$accent = New-Object Windows.Forms.Panel
$accent.BackColor = [Drawing.Color]::FromArgb(0,87,219)
$accent.Dock = 'Left'
$accent.Width = 6
$toast.Controls.Add($accent)
$title = New-Object Windows.Forms.Label
$title.Text = 'Download ' + ([string]$eventData.Kind).ToLowerInvariant()
$title.Font = [Drawing.Font]::new('Segoe UI Semibold',12)
$title.Location = [Drawing.Point]::new(18,11)
$title.Size = [Drawing.Size]::new(320,25)
$toast.Controls.Add($title)
$file = New-Object Windows.Forms.Label
$file.Text = [string]$eventData.Name
$file.AutoEllipsis = $true
$file.Location = [Drawing.Point]::new(19,39)
$file.Size = [Drawing.Size]::new(320,21)
$file.Font = [Drawing.Font]::new('Segoe UI',10)
$toast.Controls.Add($file)
$detail = New-Object Windows.Forms.Label
$detail.Text = if ($eventData.Detail) { [string]$eventData.Detail } else { 'Open Dropbox Downloader to follow progress.' }
$detail.Location = [Drawing.Point]::new(19,65)
$detail.Size = [Drawing.Size]::new(320,44)
$detail.Font = [Drawing.Font]::new('Segoe UI',9)
$toast.Controls.Add($detail)
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 4500
$timer.Add_Tick({ $toast.Close() })
$toast.Add_Shown({ $timer.Start() })
try { [Windows.Forms.Application]::Run($toast) }
finally { $timer.Dispose(); $toast.Dispose() }
