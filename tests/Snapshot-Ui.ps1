# Renders every screen of the real window to PNG files, off-screen, without changing anything.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Snapshot-Ui.ps1 -OutDir <folder> [-Theme Light|Dark] [-Scale 1.5] [-RealData] [-Pages Home,Startup]
# By default the screens show made-up sample data, so the pictures are safe to publish.
param(
    [Parameter(Mandatory)][string]$OutDir,
    [ValidateSet('Light', 'Dark')][string]$Theme = 'Light',
    [double]$Scale = 1,
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$RealData,
    [string[]]$Pages = @('Home', 'Cleanup', 'Large', 'Dup', 'Startup', 'Apps', 'Proc', 'Svc', 'Recover', 'Shred', 'Disk', 'Log', 'Settings')
)
$ErrorActionPreference = 'Stop'
$Pages = @($Pages -split ',')   # -File passes a comma list as one string
$repo = Split-Path -Parent $PSScriptRoot
$script:AppRoot = Join-Path ([IO.Path]::GetTempPath()) ('makatools-shot-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:AppRoot, $OutDir -Force | Out-Null
. (Join-Path $repo 'src\Core.ps1')
. (Join-Path $repo 'src\Ui.ps1')

$script:NoUpdateCheck = $true
Set-FuSetting 'Appearance' $Theme
Set-FuSetting 'LastCleanup' (Get-Date).AddDays(-9)
Set-FuSetting 'FirstRun' (Get-Date).AddDays(-30)

if (-not $RealData) {
    function Test-FuAdmin { $false }
    function New-FakeRow($Id, $Target, $Mb, $Files, $Recommended = $true, $NeedsAdmin = $false, $Kind = 'Files', $Process = @(), $Privacy = $false) {
        [pscustomobject]@{ Id = $Id; Target = $Target; Parts = @(); Files = $Files; MB = $Mb; Bytes = [int64]($Mb * 1MB); NeedsAdmin = $NeedsAdmin; Recommended = $Recommended; Kind = $Kind; Process = @($Process); Privacy = $Privacy }
    }
    function Get-CleanupTargets {
        Start-Sleep -Milliseconds 100
        New-FakeRow 'usertemp' 'Temporary files (your account)' 2284.8 2370
        New-FakeRow 'wintemp' 'Temporary files (Windows)' 159.9 214 $true $true
        New-FakeRow 'thumbs' 'Thumbnail cache (rebuilt automatically)' 310.1 15
        New-FakeRow 'dumps' 'Crash dumps (programs)' 28 3
        New-FakeRow 'shaders' 'Graphics shader cache (DirectX, NVIDIA, AMD, Intel)' 659 719
        New-FakeRow 'wudl' 'Windows Update downloads (already installed)' 412 31 $true $true
        New-FakeRow 'browser-Edge' 'Microsoft Edge cache' 316 880 $true $false 'Files' @('msedge-sample')
        New-FakeRow 'browser-Chrome' 'Google Chrome cache' 688 3313 $true $false 'Files' @('powershell')
        New-FakeRow 'discord' 'Discord cache' 331 1442
        New-FakeRow 'recyclebin' 'Recycle Bin (empty it - cannot be undone)' 1840 96 $false $false 'RecycleBin'
        New-FakeRow 'privacy-chrome-history' 'Google Chrome browsing history (privacy)' 32.6 6 $false $false 'Files' @('powershell') $true
        New-FakeRow 'privacy-chrome-cookies' 'Google Chrome cookies (privacy - logs you out of websites)' 2.1 2 $false $false 'Files' @('powershell') $true
        New-FakeRow 'privacy-recent' 'Recently opened files list (privacy)' 0.1 161 $false $false 'Files' @() $true
    }
    function Get-SystemInfo {
        [pscustomobject]@{
            Computer = 'MY-PC'; Windows = 'Windows 11 Pro (10.0.26100)'; Processor = 'AMD Ryzen 7 9700X 8-Core Processor'
            MemoryText = '32.0 GB'; MemoryBytes = 32GB; MemoryUsed = 13.1GB; Uptime = '2 days, 5 hours'
            Antivirus = @([pscustomobject]@{ Name = 'Your antivirus'; Enabled = $true }); SystemDrive = 'C'
            Volumes = @(
                [pscustomobject]@{ Letter = 'C'; Label = 'Windows'; Size = 1TB; Free = 412GB; Health = 'Healthy' }
                [pscustomobject]@{ Letter = 'D'; Label = 'Games'; Size = 2TB; Free = 184GB; Health = 'Healthy' }
            )
        }
    }
    function Get-StartupEntries {
        $e = { param($n, $st, $src, $sc, $c) [pscustomobject]@{ Name = $n; Status = $st; Source = $src; Scope = $sc; Command = $c; Location = ''; ApprovedKey = ''; TaskPath = $null } }
        & $e 'OneDrive' 'On' 'Registry' 'Current user' 'C:\Program Files\Microsoft OneDrive\OneDrive.exe /background'
        & $e 'Discord' 'On' 'Registry' 'Current user' 'C:\Users\me\AppData\Local\Discord\Update.exe --processStart Discord.exe'
        & $e 'Steam' 'On' 'Registry' 'Current user' 'C:\Program Files (x86)\Steam\steam.exe -silent'
        & $e 'Windows Security notification icon' 'On' 'Registry' 'All users' 'C:\Windows\system32\SecurityHealthSystray.exe'
        & $e 'Spotify' 'Off' 'Registry' 'Current user' 'C:\Users\me\AppData\Roaming\Spotify\Spotify.exe /minimized'
        & $e 'Adobe Acrobat Update Task' 'Off' 'Scheduled task' 'All users' 'C:\Program Files (x86)\Common Files\Adobe\ARM\AdobeARM.exe'
        & $e 'Ollama.lnk' 'Off' 'Startup folder' 'Current user' 'C:\Users\me\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'
    }
    function Get-InstalledPrograms {
        foreach ($p in @(@('7-Zip', 'Igor Pavlov', '24.09'), @('Discord', 'Discord Inc.', '1.0.9'), @('Google Chrome', 'Google LLC', '141.0'), @('Microsoft Edge', 'Microsoft Corporation', '141.0'), @('Spotify', 'Spotify AB', '1.2.70'), @('Steam', 'Valve Corporation', '2.10'), @('VLC media player', 'VideoLAN', '3.0.21'))) {
            [pscustomobject]@{ Name = $p[0]; Publisher = $p[1]; Version = $p[2]; Uninstall = 'x' }
        }
    }
    function Get-ProcessList {
        foreach ($p in @(@('chrome', 1840, 42), @('Discord', 612, 58), @('explorer', 288, 96), @('Spotify', 240, 33), @('dwm', 154, 21), @('svchost', 88, 14), @('RuntimeBroker', 41, 9))) {
            [pscustomobject]@{ Id = 1000; Name = $p[0]; MemoryMB = $p[1]; Threads = $p[2]; Path = "C:\Program Files\$($p[0]).exe" }
        }
    }
    function Get-ServiceList {
        foreach ($p in @(@('Audiosrv', 'Windows Audio', 'Running', 'Automatic'), @('BITS', 'Background Intelligent Transfer', 'Stopped', 'Manual'), @('Dnscache', 'DNS Client', 'Running', 'Automatic'), @('Spooler', 'Print Spooler', 'Running', 'Automatic'), @('WSearch', 'Windows Search', 'Running', 'Automatic'), @('wuauserv', 'Windows Update', 'Stopped', 'Manual'))) {
            [pscustomobject]@{ Name = $p[0]; DisplayName = $p[1]; Status = $p[2]; StartType = $p[3] }
        }
    }
    function Get-RecycleBinEntries {
        [pscustomobject]@{ Name = 'Holiday photos.zip'; OriginalPath = 'C:\Users\me\Documents\Holiday photos.zip'; KB = 842000; Deleted = (Get-Date).AddDays(-2); InfoPath = 'x' }
        [pscustomobject]@{ Name = 'Budget 2026.xlsx'; OriginalPath = 'C:\Users\me\Documents\Budget 2026.xlsx'; KB = 62; Deleted = (Get-Date).AddDays(-6); InfoPath = 'y' }
    }
    function Get-DiskHealth {
        [pscustomobject]@{ Disk = 'NVMe SSD 2TB'; Type = 'SSD'; SizeGB = 1907; Health = 'Healthy'; Status = 'OK'; TempC = 41; WearPct = 2; ReadErrs = 0 }
        [pscustomobject]@{ Disk = 'SATA SSD 4TB'; Type = 'SSD'; SizeGB = 3726; Health = 'Healthy'; Status = 'OK'; TempC = 33; WearPct = 0; ReadErrs = 0 }
    }
    function Get-UsableVolumes { [pscustomobject]@{ DriveLetter = 'C'; Size = 1TB }; [pscustomobject]@{ DriveLetter = 'D'; Size = 2TB } }
    function Get-FuOpenPrograms($Rows) { @('powershell') }
    function Get-FuLogEntries {
        [pscustomobject]@{ When = '2026-11-02 18:04'; Message = 'Cleanup: deleted 3120 files, freed 2954 MB, skipped 14' }
        [pscustomobject]@{ When = '2026-10-29 09:31'; Message = "Startup: switched off 'Spotify' (Registry, Current user)" }
        [pscustomobject]@{ When = '2026-10-20 21:12'; Message = 'Moved to Recycle Bin: C:\Users\me\Videos\old-copy.mp4' }
    }
}

function Wait-Ui([int]$Ms) {
    $end = (Get-Date).AddMilliseconds($Ms)
    do {
        [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, 'Background')
        Start-Sleep -Milliseconds 15
    } while ((Get-Date) -lt $end)
}
function Wait-Tasks([int]$Seconds = 60) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ($script:Tasks.Count -and (Get-Date) -lt $end) { Wait-Ui 50 }
}
function Save-Shot([string]$Name) {
    $root = $script:Ui.Root
    $w = [int]($root.ActualWidth * $Scale); $h = [int]($root.ActualHeight * $Scale)
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $Scale), (96 * $Scale), [Windows.Media.PixelFormats]::Pbgra32)
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $rect = New-Object Windows.Rect(0, 0, $root.ActualWidth, $root.ActualHeight)
    $dc.DrawRectangle((Get-FuBrush 'Page'), $null, $rect)
    $dc.DrawRectangle((New-Object Windows.Media.VisualBrush($root)), $null, $rect)
    $dc.Close()
    $bmp.Render($dv)
    $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $f = [IO.File]::Create((Join-Path $OutDir "$Name.png"))
    $png.Save($f)
    $f.Close()
}

$window = New-MainForm
if ($Width) { $window.Width = $Width }
if ($Height) { $window.Height = $Height }
$window.WindowStartupLocation = 'Manual'
$window.Left = -6000
$window.Top = 100
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Show()
Wait-Ui 400
Wait-Tasks
Wait-Ui 300

foreach ($p in $Pages) {
    $nav = $(if ($p -eq 'Settings') { $script:Ui.NavSettings } else { $script:Ui["Nav$p"] })
    $nav.IsChecked = $true
    Wait-Ui 150
    if (-not $RealData) {
        if ($p -eq 'Large') {
            $script:LargeRows = @(@('Family video.mp4', 'C:\Users\me\Videos', 6.2GB), @('Game backup.iso', 'C:\Users\me\Downloads', 4.4GB), @('Project archive.zip', 'C:\Users\me\Documents', 1.8GB), @('Installer.exe', 'C:\Users\me\Downloads', 812MB)) | ForEach-Object {
                [pscustomobject]@{ Title = $_[0]; Detail = $_[1]; Value = Format-FuSize $_[2]; Path = 'x'; Tip = 'x' }
            }
            Set-FuRows 'Large' $script:LargeRows ''
        }
        if ($p -eq 'Dup') {
            $script:DupRows = @(@('Holiday photos (1).zip', 'C:\Users\me\Pictures\Holiday photos.zip', 842MB), @('Setup copy.exe', 'C:\Users\me\Downloads\Setup.exe', 96MB)) | ForEach-Object {
                [pscustomobject]@{ Title = $_[0]; Detail = "Same as $($_[1])"; Value = Format-FuSize $_[2]; Copy = 'x'; Tip = 'x' }
            }
            Set-FuRows 'Dup' $script:DupRows ''
        }
    }
    Wait-Tasks
    Wait-Ui 350
    Save-Shot ('{0}-{1}' -f $Theme.ToLower(), $p.ToLower())
}

# The in-window dialog, on top of whichever page was last
$script:Ui.NavCleanup.IsChecked = $true
Wait-Ui 300
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(450)
$timer.Add_Tick({ $timer.Stop(); Save-Shot ('{0}-sheet' -f $Theme.ToLower()); Close-FuSheet $false })
$timer.Start()
[void](Show-FuSheet -Title 'Clear private data?' -Text "Clearing cookies signs you out of websites. Clearing history removes your browsing history and address-bar suggestions. This can't be undone." -Yes 'Clear' -No 'Cancel' -Kind 'danger')

# The status pill while something runs
$script:Ui.NavHome.IsChecked = $true
Show-FuPill 'Scanning Google Chrome cache' $true $true 40
Set-FuHero 'Cleaning' '2.3 GB' 'This usually takes less than a minute.' $true
Wait-Ui 350
Save-Shot ('{0}-busy' -f $Theme.ToLower())

$window.Close()
Remove-Item -LiteralPath $script:AppRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "Screens saved to $OutDir"
