# Makatools - user interface (WPF). All real work lives in Core.ps1; this file only wires the window
# in MainWindow.xaml to it. Slow work runs in a second runspace (Start-FuWork) so the window stays
# responsive. Event handlers run after the function that made them has returned, so they cannot see
# its locals: controls are reached through $script:Ui (every x:Name in the window) and state through
# $script: variables.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:UiDir = $PSScriptRoot

# ---------------------------------------------------------------- theme

function Read-FuXaml([string]$File) {
    return [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:UiDir $File)))
}

# 'System' follows the Windows light/dark setting
function Get-FuEffectiveTheme([string]$Mode) {
    if ($Mode -eq 'Light' -or $Mode -eq 'Dark') { return $Mode }
    $light = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue
    if ($light -and $light.AppsUseLightTheme -eq 0) { return 'Dark' }
    return 'Light'
}

function Set-FuTheme([string]$Mode) {
    $res = [Windows.Application]::Current.Resources
    $res.MergedDictionaries.Clear()
    $res.MergedDictionaries.Add((Read-FuXaml ('Colors.{0}.xaml' -f (Get-FuEffectiveTheme $Mode))))
}

function Get-FuBrush([string]$Key) { return [Windows.Application]::Current.Resources[$Key] }

# ---------------------------------------------------------------- small UI helpers

function Set-FuShown($Element, [bool]$Shown) {
    $Element.Visibility = $(if ($Shown) { 'Visible' } else { 'Collapsed' })
}

function Start-FuFade($Element, [double]$To, [int]$Ms = 160) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation($To, [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms)))
    $Element.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

# The dot between details. Script files must stay pure ASCII: PowerShell 5.1 misreads anything else.
function Get-FuSep { return ('  ' + [char]0xB7 + '  ') }

function Get-FuPlural([int]$Count, [string]$One, [string]$Many = ($One + 's')) {
    return ('{0:N0} {1}' -f $Count, $(if ($Count -eq 1) { $One } else { $Many }))
}

# In-window dialog. Returns $true for the Yes button. Runs a nested message loop, so callers can
# simply write: if (-not (Confirm-FuAction ...)) { return }
function Show-FuSheet {
    param([string]$Title, [string]$Text, [string]$Yes = 'OK', [string]$No = '', [ValidateSet('info', 'warn', 'danger', 'good')][string]$Kind = 'info')
    $ui = $script:Ui
    $tones = @{ info = @('AccentSoft', 'Accent', [string][char]0xE946); warn = @('OrangeSoft', 'Orange', [string][char]0xE7BA)
                danger = @('RedSoft', 'Red', [string][char]0xE74D); good = @('GreenSoft', 'Green', [string][char]0xE73E) }
    $t = $tones[$Kind]
    $ui.SheetIconBox.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $t[0])
    $ui.SheetIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $t[1])
    $ui.SheetIcon.Text = $t[2]
    $ui.SheetTitle.Text = $Title
    $ui.SheetText.Text = $Text
    Set-FuShown $ui.SheetText ([bool]$Text)
    $ui.SheetYes.Content = $Yes
    $ui.SheetYes.Style = Get-FuBrush $(if ($Kind -eq 'danger') { 'Danger' } else { 'Primary' })
    # A destructive button is never the Enter default
    $ui.SheetYes.IsDefault = ($Kind -ne 'danger')
    $ui.SheetNo.Content = $No
    Set-FuShown $ui.SheetNo ([bool]$No)

    $script:SheetResult = $false
    $script:SheetFrame = New-Object Windows.Threading.DispatcherFrame
    $ui.Sheet.Visibility = 'Visible'
    Start-FuFade $ui.Sheet 1 140
    $pop = New-Object Windows.Media.Animation.DoubleAnimation(0.96, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
    $pop.EasingFunction = New-Object Windows.Media.Animation.CubicEase
    $ui.SheetScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pop)
    $ui.SheetScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pop)
    $focus = $(if ($Kind -eq 'danger' -and $No) { $ui.SheetNo } else { $ui.SheetYes })
    [void]$focus.Focus()

    [Windows.Threading.Dispatcher]::PushFrame($script:SheetFrame)

    $script:SheetFrame = $null
    $ui.Sheet.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $ui.Sheet.Opacity = 0
    $ui.Sheet.Visibility = 'Collapsed'
    return [bool]$script:SheetResult
}

function Close-FuSheet([bool]$Result) {
    $script:SheetResult = $Result
    if ($script:SheetFrame) { $script:SheetFrame.Continue = $false }
}

# Message boxes and questions. Tests replace these two so nothing waits for a click.
function Show-FuInfo($Text, $Icon = 'Information', $Title = 'Makatools') {
    $kind = $(if ($Icon -eq 'Warning') { 'warn' } elseif ($Icon -eq 'Error') { 'danger' } else { 'info' })
    if ($Kind -eq 'danger') { $kind = 'warn' }   # no red Yes button on a plain OK
    [void](Show-FuSheet -Title $Title -Text $Text -Kind $kind)
}

function Confirm-FuAction($Text, $Title = 'Are you sure?', $Yes = 'Continue', [bool]$Danger = $false) {
    return (Show-FuSheet -Title $Title -Text $Text -Yes $Yes -No 'Cancel' -Kind $(if ($Danger) { 'danger' } else { 'info' }))
}

function Restart-FuAsAdmin {
    try {
        $launcher = Join-Path $script:AppRoot 'Makatools-Setup.exe'
        $script_ = Join-Path $script:AppRoot 'Makatools.ps1'
        if (Test-Path -LiteralPath $launcher) { Start-Process -FilePath $launcher -Verb RunAs -ArgumentList '--run' -ErrorAction Stop }
        else { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script_`"") -ErrorAction Stop }
        $script:Ui.Window.Close()
    } catch {
        Show-FuToast 'Administrator rights were not granted'
    }
}

function Require-FuAdmin($What) {
    if (Test-FuAdmin) { return $true }
    if (Confirm-FuAction "$What needs administrator rights. Makatools will reopen, and Windows will ask for permission." 'Administrator rights needed' 'Run as Administrator') {
        Restart-FuAsAdmin
    }
    return $false
}

# Shows why an antivirus item is left alone. Returns $true when the caller should stop.
function Test-FuBlockedBySecurity($What, [string[]]$Text) {
    if (-not (Test-FuProtected $Text)) { return $false }
    Show-FuInfo "'$What' is part of your antivirus, such as Norton 360 or Microsoft Defender. Makatools doesn't change security software. Use the antivirus's own settings instead." 'Warning' 'Protected'
    return $true
}

# Modern folder picker: the file dialog in "pick this folder" mode, which needs no extra code to load
function Select-FuFolder([string]$Start) {
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.ValidateNames = $false
    $d.CheckFileExists = $false
    $d.CheckPathExists = $true
    $d.FileName = 'Select this folder'
    $d.Title = 'Choose a folder'
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.InitialDirectory = $Start }
    if ($d.ShowDialog($script:Ui.Window)) { return (Split-Path -Parent $d.FileName) }
    return $null
}

# ---------------------------------------------------------------- the status pill

function Show-FuPill([string]$Text, [bool]$Busy, [bool]$Cancel = $false, [int]$Percent = -1) {
    $ui = $script:Ui
    $ui.TaskText.Text = $Text
    Set-FuShown $ui.TaskBar $Busy
    Set-FuShown $ui.TaskCancel $Cancel
    Set-FuShown $ui.TaskIcon (-not $Busy)
    $ui.TaskBar.IsIndeterminate = ($Percent -lt 0)
    if ($Percent -ge 0) { $ui.TaskBar.Value = [math]::Min(100, $Percent) }
    if ($ui.TaskPill.Visibility -ne 'Visible') {
        $ui.TaskPill.Visibility = 'Visible'
        Start-FuFade $ui.TaskPill 1 150
    }
}

# Short confirmation that disappears by itself
function Show-FuToast([string]$Text) {
    $script:ToastText = $Text
    $script:ToastUntil = (Get-Date).AddSeconds(3.5)
    Show-FuPill $Text $false
    if (-not $script:JobTimer.IsEnabled) { $script:JobTimer.Start() }
}

# ---------------------------------------------------------------- background work

# A second runspace inside this process: it starts in milliseconds, stops at once when cancelled
# and hands back live objects. It gets every loaded function, plus $AppRoot and its own $FuProgress
# table that Core's Set-FuProgress writes to. UI functions come along too; that is harmless, and
# filtering by name once dropped a Core helper by mistake.
function New-FuRunspace($Progress) {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in Get-ChildItem -Path Function:\) {
        # Never a module's function: Windows commands like Get-Volume and Get-ScheduledTask appear here
        # once loaded, and a copy of one is broken outside its module
        if ($f.ScriptBlock -and -not $f.ModuleName) {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.ScriptBlock.ToString())))
        }
    }
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('AppRoot', $script:AppRoot, '')))
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('FuProgress', $Progress, '')))
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'   # shell calls such as emptying the Recycle Bin expect STA
    $rs.Open()
    return $rs
}

# Runs $Work in the background and calls $OnDone with its output when finished.
#   -Quiet      no status pill and no error dialog (quiet reads such as filling a list)
#   -Exclusive  refuses to start while another exclusive task runs (anything that changes the PC)
function Start-FuWork {
    param([string]$Label, [scriptblock]$Work, [object[]]$Arguments = @(), [scriptblock]$OnDone, [scriptblock]$OnFail, [switch]$Quiet, [switch]$Exclusive)
    if ($Exclusive -and @($script:Tasks | Where-Object { $_.Exclusive }).Count) {
        Show-FuInfo 'Another task is still running. Wait for it to finish, or cancel it first.'
        return
    }
    $progress = [hashtable]::Synchronized(@{ Text = ''; Percent = -1 })
    $rs = New-FuRunspace $progress
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Work.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    [void]$script:Tasks.Add(@{ Label = $Label; PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone; OnFail = $OnFail
                               Quiet = [bool]$Quiet; Exclusive = [bool]$Exclusive; Progress = $progress })
    if (-not $script:JobTimer.IsEnabled) { $script:JobTimer.Start() }
    Update-FuTaskPill
}

function Stop-FuWork {
    foreach ($t in @($script:Tasks)) { if (-not $t.Quiet) { [void]$t.PS.BeginStop($null, $null) } }
}

function Update-FuTaskPill {
    $visible = @($script:Tasks | Where-Object { -not $_.Quiet })
    if ($visible.Count) {
        $t = $visible[-1]
        $text = $(if ($t.Progress.Text) { $t.Progress.Text } else { "$($t.Label)..." })
        Show-FuPill $text $true $true ([int]$t.Progress.Percent)
        return
    }
    if ($script:ToastUntil -and (Get-Date) -lt $script:ToastUntil) { return }
    $script:ToastUntil = $null
    if ($script:Ui.TaskPill.Visibility -eq 'Visible') {
        $script:Ui.TaskPill.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $script:Ui.TaskPill.Opacity = 0
        $script:Ui.TaskPill.Visibility = 'Collapsed'
    }
}

# Timer: shows progress and hands finished tasks to their handlers. While a dialog is open,
# finished tasks wait, so one dialog never opens on top of another.
function Invoke-FuTimerTick {
    if (-not $script:SheetFrame) {
        foreach ($task in @($script:Tasks)) {
            if (-not $task.Handle.IsCompleted) { continue }
            [void]$script:Tasks.Remove($task)
            $output = @()
            $reason = $null
            try { $output = @($task.PS.EndInvoke($task.Handle)) }
            catch { $reason = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) }
            $state = [string]$task.PS.InvocationStateInfo.State
            if ($state -eq 'Failed' -and $task.PS.InvocationStateInfo.Reason) { $reason = $task.PS.InvocationStateInfo.Reason.Message }
            $task.PS.Dispose()
            $task.Runspace.Dispose()
            if ($state -eq 'Stopped') {
                if (-not $task.Quiet) { Show-FuToast 'Cancelled' }
                continue
            }
            if ($state -eq 'Failed') {
                if ($task.OnFail) { & $task.OnFail $reason }
                elseif (-not $task.Quiet) { Show-FuInfo "Something went wrong while $($task.Label.ToLower()).`r`n`r`n$reason" 'Warning' 'That didn''t work' }
                continue
            }
            if ($task.OnDone) { & $task.OnDone $output }
        }
    }
    Update-FuTaskPill
    if (-not $script:Tasks.Count -and -not $script:ToastUntil) { $script:JobTimer.Stop() }
}

# ---------------------------------------------------------------- window

function Show-MainForm {
    $window = New-MainForm
    [void][Windows.Application]::Current.Run($window)
    # A cancelled task may still be finishing in its runspace; don't leave a hidden process behind
    [Environment]::Exit(0)
}

# Builds the window without showing it, so tests can drive it.
function New-MainForm {
    if (-not [Windows.Application]::Current) {
        $app = New-Object Windows.Application
        $app.ShutdownMode = 'OnMainWindowClose'
        $app.Add_DispatcherUnhandledException({
            param($s, $e)
            Write-FuLog "Unexpected error: $($e.Exception.Message)" 'ERROR'
            $e.Handled = $true
            Show-FuToast 'Something went wrong. Details are in the Activity Log.'
        })
    }
    [Windows.Application]::Current.Resources = Read-FuXaml 'Theme.xaml'
    Set-FuTheme ([string](Get-FuSettings).Appearance)

    $text = [IO.File]::ReadAllText((Join-Path $script:UiDir 'MainWindow.xaml'))
    $window = [Windows.Markup.XamlReader]::Parse($text)
    $script:Ui = @{ Window = $window }
    foreach ($m in [regex]::Matches($text, 'x:Name="(\w+)"')) {
        $found = $window.FindName($m.Groups[1].Value)
        if ($found) { $script:Ui[$m.Groups[1].Value] = $found }
    }
    $script:Tasks = New-Object System.Collections.ArrayList
    $script:Visited = @{}
    $script:ToastUntil = $null
    $script:SheetFrame = $null
    $script:BackupDir = Join-Path $script:AppRoot 'Backups'
    $script:JobTimer = New-Object Windows.Threading.DispatcherTimer
    $script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:JobTimer.Add_Tick({ Invoke-FuTimerTick })

    $assets = Join-Path (Split-Path -Parent $script:UiDir) 'assets'
    $logoPath = Join-Path $assets 'logo.png'
    if (Test-Path -LiteralPath $logoPath) {
        # OnLoad keeps the file unlocked, so an update can replace it while the app runs
        $logo = New-Object Windows.Media.Imaging.BitmapImage
        $logo.BeginInit()
        $logo.CacheOption = 'OnLoad'
        $logo.UriSource = New-Object Uri($logoPath)
        $logo.EndInit()
        $script:Ui.SideLogo.Source = $logo
        $script:Ui.AboutLogo.Source = $logo
    }
    $icoPath = Join-Path $assets 'Makatools.ico'
    if (Test-Path -LiteralPath $icoPath) {
        $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($icoPath)), 'None', 'OnLoad')
    }
    $window.Title = 'Makatools'
    Set-FuWindowFit $window ([Windows.SystemParameters]::WorkArea.Width) ([Windows.SystemParameters]::WorkArea.Height)
    Connect-FuChrome
    Connect-FuNavigation
    Connect-FuHome
    Connect-FuCleanup
    Connect-FuFilePages
    Connect-FuSystemPages
    Connect-FuSettings

    $window.Add_ContentRendered({
        Start-FuHomeLoad
        if ((Get-FuUpdateRepo) -and -not $script:NoUpdateCheck) { Start-FuUpdateCheck $true }
    })
    $window.Add_Closing({
        param($s, $e)
        if ($script:SheetFrame) { Close-FuSheet $false }
        foreach ($t in @($script:Tasks)) { try { [void]$t.PS.BeginStop($null, $null) } catch { } }
    })
    return $window
}

# Keeps the window on screen: its normal and minimum sizes shrink to fit a small work area
function Set-FuWindowFit($Window, [double]$AreaWidth, [double]$AreaHeight) {
    $Window.MinWidth = [math]::Min(960, $AreaWidth)
    $Window.MinHeight = [math]::Min(620, $AreaHeight)
    $Window.Width = [math]::Min(1120, $AreaWidth)
    $Window.Height = [math]::Min(760, $AreaHeight)
}

function Connect-FuChrome {
    $ui = $script:Ui
    $ui.CapMin.Add_Click({ $script:Ui.Window.WindowState = 'Minimized' })
    $ui.CapMax.Add_Click({
        $w = $script:Ui.Window
        $w.WindowState = $(if ($w.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' })
    })
    $ui.CapClose.Add_Click({ $script:Ui.Window.Close() })
    $ui.Window.Add_StateChanged({
        $m = $script:Ui.Window.WindowState -eq 'Maximized'
        # A maximized custom-frame window hangs over the screen edge by its border width
        $script:Ui.Root.Margin = $(if ($m) { New-Object Windows.Thickness(7) } else { New-Object Windows.Thickness(0) })
        $script:Ui.CapMax.Content = [string][char]$(if ($m) { 0xE923 } else { 0xE922 })
    })
    $ui.SheetYes.Add_Click({ Close-FuSheet $true })
    $ui.SheetNo.Add_Click({ Close-FuSheet $false })
    $ui.TaskCancel.Add_Click({ Stop-FuWork })
    $ui.Window.Add_PreviewKeyDown({
        param($s, $e)
        if ($script:SheetFrame -and $e.Key -eq 'Escape') {
            Close-FuSheet $false
            $e.Handled = $true
        }
    })
    [Windows.Input.KeyboardNavigation]::SetTabNavigation($ui.Sheet, 'Cycle')
}

function Connect-FuNavigation {
    $handler = [Windows.RoutedEventHandler]{
        param($s, $e)
        if ($e.OriginalSource -is [Windows.Controls.RadioButton] -and $e.OriginalSource.GroupName -eq 'Nav') { Show-FuPage ([string]$e.OriginalSource.Tag) }
    }
    $script:Ui.Root.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $handler)
}

function Show-FuPage([string]$Name) {
    $ui = $script:Ui
    foreach ($p in 'Home', 'Cleanup', 'Large', 'Dup', 'Startup', 'Apps', 'Proc', 'Svc', 'Recover', 'Shred', 'Disk', 'Log', 'Settings') {
        $page = $ui["Page$p"]
        if ($p -eq $Name) {
            $page.Visibility = 'Visible'
            $page.Opacity = 0
            Start-FuFade $page 1 170
        } else {
            $page.Visibility = 'Collapsed'
        }
    }
    $first = -not $script:Visited[$Name]
    $script:Visited[$Name] = $true
    switch ($Name) {
        'Cleanup' { if (-not $script:CleanRows -and -not $script:ScanRunning) { Start-FuCleanupScan } }
        'Large'   { if ($first) { $ui.LargePath.Text = $env:USERPROFILE } }
        'Dup'     { if ($first) { $ui.DupPath.Text = $env:USERPROFILE } }
        'Startup' { if ($first) { Start-FuStartupLoad } }
        'Apps'    { if ($first) { Start-FuAppsLoad } }
        'Proc'    { Start-FuProcLoad }
        'Svc'     { if ($first) { Start-FuSvcLoad } }
        'Recover' { Start-FuRecoverLoad }
        'Disk'    { if ($first) { Start-FuDiskLoad } }
        'Log'     { Update-FuLog }
    }
}

# ---------------------------------------------------------------- Home

function Connect-FuHome {
    $ui = $script:Ui
    $ui.HeroClean.Add_Click({ Start-FuOptimize })
    $ui.HeroReview.Add_Click({ $script:Ui.NavCleanup.IsChecked = $true })
    $ui.TileStorage.Add_Click({ $script:Ui.NavLarge.IsChecked = $true })
    $ui.TileMemory.Add_Click({ $script:Ui.NavProc.IsChecked = $true })
    $ui.TileStartup.Add_Click({ $script:Ui.NavStartup.IsChecked = $true })
    $ui.TileHealth.Add_Click({ $script:Ui.NavDisk.IsChecked = $true })
}

function Set-FuHero([string]$Kicker, [string]$Big, [string]$Sub, [bool]$Busy, [string]$Button = '') {
    $ui = $script:Ui
    $ui.HeroKicker.Text = $Kicker
    $ui.HeroBig.Text = $Big
    $ui.HeroSub.Text = $Sub
    Set-FuShown $ui.HeroBar $Busy
    Set-FuShown $ui.HeroClean ([bool]$Button)
    if ($Button) { $ui.HeroClean.Content = $Button }
    Set-FuShown $ui.HeroReview ([bool]$Button)
}

function Start-FuHomeLoad {
    Start-FuWork 'Reading system information' { Get-SystemInfo } -Quiet -OnDone { param($o) Update-FuHomeInfo ($o | Select-Object -First 1) }
    Start-FuWork 'Reading startup programs' { Get-StartupEntries } -Quiet -OnDone { param($o) Update-FuStartupRows @($o); Update-FuStartupTile }
    if (-not $script:ScanRunning) { Start-FuCleanupScan }
}

function Update-FuHomeInfo($Info) {
    if (-not $Info) { return }
    $ui = $script:Ui
    $sys = @($Info.Volumes | Where-Object { $_.Letter -eq $Info.SystemDrive }) | Select-Object -First 1
    if ($sys) {
        $ui.TileStorageValue.Text = (Format-FuSize $sys.Free)
        $ui.TileStorageSub.Text = 'free of {0} on {1}:' -f (Format-FuSize $sys.Size), $sys.Letter
    }
    $usedPct = [int](100 * $Info.MemoryUsed / $Info.MemoryBytes)
    $ui.TileMemoryValue.Text = "$usedPct% used"
    $ui.TileMemorySub.Text = '{0} of {1}' -f (Format-FuSize $Info.MemoryUsed), $Info.MemoryText

    $bad = @($Info.Volumes | Where-Object { $_.Health -and $_.Health -ne 'Healthy' })
    $av = @($Info.Antivirus | Where-Object { $_.Enabled }) | Select-Object -First 1
    $ui.TileHealthValue.Text = $(if ($bad.Count) { 'Check disks' } elseif (-not $av) { 'No antivirus' } else { 'All good' })
    $ui.TileHealthSub.Text = $(if ($av) { "$($av.Name) is on" } else { 'No active antivirus found' })

    $accent = Get-FuBrush 'Accent'
    $red = Get-FuBrush 'Red'
    $orange = Get-FuBrush 'Orange'
    # Tiny system partitions such as System Reserved are nothing a person manages
    $ui.DriveList.ItemsSource = @($Info.Volumes | Where-Object { $_.Size -ge 1GB } | ForEach-Object {
        $pct = $(if ($_.Size -gt 0) { 100 * ($_.Size - $_.Free) / $_.Size } else { 0 })
        [pscustomobject]@{
            Title    = $(if ($_.Label) { "$($_.Label) ($($_.Letter):)" } else { "Drive $($_.Letter):" })
            FreeText = '{0} free of {1}' -f (Format-FuSize $_.Free), (Format-FuSize $_.Size)
            UsedPct  = $pct
            BarBrush = $(if ($pct -ge 95) { $red } elseif ($pct -ge 85) { $orange } else { $accent })
            TagText  = $(if ($_.Health -eq 'Healthy') { '' } else { $_.Health })
            Tone     = $(if ($_.Health -eq 'Healthy' -or -not $_.Health) { '' } else { 'warn' })
        }
    })
    $ui.FactList.ItemsSource = @(
        [pscustomobject]@{ Key = 'Computer'; Value = $Info.Computer }
        [pscustomobject]@{ Key = 'Windows'; Value = $Info.Windows }
        [pscustomobject]@{ Key = 'Processor'; Value = $Info.Processor }
        [pscustomobject]@{ Key = 'Memory'; Value = $Info.MemoryText }
        [pscustomobject]@{ Key = 'Running for'; Value = $Info.Uptime }
    )
}

# Fills the hero from the last scan
function Update-FuHeroFromScan {
    $rows = @($script:CleanRows)
    # What Clean Now would take. It follows the same rule as Invoke-AutoClean, not the ticks on the Cleanup page.
    $ready = @($rows | Where-Object { $_.Source.Recommended -and $_.CanClean -and -not $_.IsOpen -and -not $_.Source.Privacy })
    [double]$bytes = ($ready | ForEach-Object { [double]$_.Source.Bytes } | Measure-Object -Sum).Sum
    $waiting = @($rows | Where-Object { $_.IsOpen -and $_.Source.Recommended })
    $days = Get-FuDaysSinceCleanup
    $kicker = $(if (Test-FuCleanupDue) {
        if ($null -eq $days) { 'Time for a cleanup' } else { "It's been $days days since your last cleanup" }
    } elseif ($null -eq $days) { 'Ready to clean' }
    elseif ($days -eq 0) { 'Cleaned today' }
    elseif ($days -eq 1) { 'Last cleaned yesterday' }
    else { "Last cleaned $days days ago" })
    $sub = 'Temporary files and caches that Windows and your apps rebuild on their own.'
    if ($waiting.Count) {
        [double]$more = ($waiting | ForEach-Object { [double]$_.Source.Bytes } | Measure-Object -Sum).Sum
        $names = @($waiting | ForEach-Object { $_.Title -replace ' (web )?cache$', '' }) -join ', '
        $sub = 'Close {0} to clean {1} more.' -f $names, (Format-FuSize $more)
    }
    if ($bytes -lt 5MB -and -not $waiting.Count) {
        Set-FuHero $kicker 'All tidy' 'There is nothing worth cleaning right now.' $false
    } else {
        Set-FuHero $kicker (Format-FuSize $bytes) $sub $false 'Clean Now'
    }
}

function Start-FuOptimize {
    if (-not (Confirm-FuAction 'Makatools will remove temporary files and caches. Privacy items, the Recycle Bin and apps that are open are left alone. To choose for yourself, use Review Items.' 'Clean up now?' 'Clean Now')) { return }
    Set-FuHero 'Cleaning' $script:Ui.HeroBig.Text 'This usually takes less than a minute.' $true
    Start-FuWork 'Cleaning' { Invoke-AutoClean 'One-click' } -Exclusive -OnDone {
        param($o)
        $r = $o | Select-Object -First 1
        $script:LastFreed = $r
        if ($r) { Set-FuHero 'All done' (Format-FuSize ($r.FreedMB * 1MB)) ('freed. {0} removed{1}.' -f (Get-FuPlural $r.Deleted 'file'), $(if ($r.Skipped) { ", $($r.Skipped) in use were skipped" } else { '' })) $false }
        Start-FuCleanupScan -KeepHero
        Start-FuHomeInfoRefresh
    } -OnFail { param($why) Update-FuHeroFromScan; Show-FuInfo $why 'Warning' 'Cleanup stopped' }
}

function Start-FuHomeInfoRefresh {
    Start-FuWork 'Reading system information' { Get-SystemInfo } -Quiet -OnDone { param($o) Update-FuHomeInfo ($o | Select-Object -First 1) }
}

# ---------------------------------------------------------------- Cleanup

function Connect-FuCleanup {
    $ui = $script:Ui
    $ui.CleanRescan.Add_Click({ Start-FuCleanupScan })
    $ui.CleanGo.Add_Click({ Start-FuCleanSelected })
    $ui.CleanComponents.Add_Click({
        if (-not (Require-FuAdmin 'Cleaning Windows Update leftovers')) { return }
        if (-not (Confirm-FuAction "This removes old versions of Windows files left behind by updates. It's the same as Disk Cleanup's Windows Update Cleanup, and can take 10 minutes or more. Updates installed so far can no longer be uninstalled afterwards." 'Clean up Windows Update leftovers?' 'Clean Up')) { return }
        Start-FuWork 'Cleaning Windows Update leftovers' { Invoke-ComponentCleanup } -Exclusive -OnDone { param($o) Show-FuInfo ($o -join "`r`n") 'Information' 'Finished' }
    })
    # Any tick in any section updates the total
    $ui.CleanSections.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ Update-FuCleanTotal })
}

# Turns a Core cleanup row into a display row
function ConvertTo-FuCleanRow($Row, [bool]$IsAdmin, [string[]]$Open) {
    $title = [string]$Row.Target
    $note = ''
    if ($title -match '^(.*?) \((.*)\)$') {
        $title = $Matches[1]
        $note = ($Matches[2] -replace '^privacy( - )?', '').Trim()
        if ($note) { $note = $note.Substring(0, 1).ToUpper() + $note.Substring(1) }
    }
    $locked = $Row.NeedsAdmin -and -not $IsAdmin
    $isOpen = @($Row.Process | Where-Object { $_ -and $_ -in $Open }).Count -gt 0
    $files = Get-FuPlural $Row.Files 'file'
    $detail = $(if ($isOpen) { "Close $($title -replace ' (web )?cache$', '') first to clean this" } elseif ($note) { "$note$(Get-FuSep)$files" } else { $files })
    [pscustomobject]@{
        Source   = $Row
        Title    = $title
        Detail   = $detail
        SizeText = Format-FuSize $Row.Bytes
        Selected = [bool]($Row.Recommended -and -not $locked -and -not $isOpen)
        CanClean = [bool](-not $locked)
        IsOpen   = [bool]$isOpen
        TagText  = $(if ($isOpen) { 'Open' } else { '' })
        Tone     = $(if ($isOpen) { 'warn' } else { '' })
        Section  = $(if ($locked) { 'Admin' } elseif ($Row.Privacy) { 'Privacy' } elseif ($Row.Recommended) { 'Safe' } else { 'Optional' })
    }
}

function Start-FuCleanupScan {
    param([switch]$KeepHero)
    $script:ScanRunning = $true
    $script:KeepHero = [bool]$KeepHero
    $ui = $script:Ui
    Set-FuShown $ui.CleanLoading $true
    Set-FuShown $ui.CleanSections $false
    if (-not $KeepHero) { Set-FuHero 'Checking your PC' ([string][char]0x2013) 'Looking for temporary files and caches. Nothing is deleted yet.' $true }
    $ui.CleanGo.IsEnabled = $false
    $ui.CleanTotal.Text = 'Scanning'
    Start-FuWork 'Scanning' { Get-CleanupTargets } -Quiet -OnDone {
        param($rows)
        $script:ScanRunning = $false
        Update-FuCleanRows @($rows)
        if (-not $script:KeepHero) { Update-FuHeroFromScan }
    } -OnFail {
        param($why)
        $script:ScanRunning = $false
        $script:Ui.CleanLoadingText.Text = "The scan didn't finish: $why"
        Set-FuHero 'Something went wrong' 'Try again' $why $false
    }
}

function Update-FuCleanRows($Rows) {
    $ui = $script:Ui
    $isAdmin = Test-FuAdmin
    $open = @(Get-FuOpenPrograms $Rows)
    $script:CleanRows = @($Rows | ForEach-Object { ConvertTo-FuCleanRow $_ $isAdmin $open })
    foreach ($s in 'Safe', 'Admin', 'Optional', 'Privacy') {
        $part = @($script:CleanRows | Where-Object { $_.Section -eq $s })
        $ui["List$s"].ItemsSource = $part
        Set-FuShown $ui["Sec$s"] ($part.Count -gt 0)
    }
    Set-FuShown $ui.CleanLoading $false
    Set-FuShown $ui.CleanSections $true
    Update-FuCleanTotal
}

function Update-FuCleanTotal {
    $picked = @($script:CleanRows | Where-Object { $_.Selected })
    [double]$bytes = ($picked | ForEach-Object { [double]$_.Source.Bytes } | Measure-Object -Sum).Sum
    $script:Ui.CleanTotal.Text = $(if ($picked.Count) { '{0} selected' -f (Format-FuSize $bytes) } else { 'Nothing selected' })
    $script:Ui.CleanGo.IsEnabled = ($picked.Count -gt 0)
}

function Start-FuCleanSelected {
    $picked = @($script:CleanRows | Where-Object { $_.Selected })
    if (-not $picked.Count) { return }
    $chosen = @($picked | ForEach-Object { $_.Source })
    $open = @(Get-FuOpenPrograms $chosen)
    if ($open.Count -and -not (Confirm-FuAction ("{0} still open, so some files are in use and can't be cleaned. For a full clean, close {1} first." -f ($open -join ', '), $(if ($open.Count -eq 1) { 'it' } else { 'them' })) 'Clean anyway?' 'Clean Anyway')) { return }
    $privacy = @($chosen | Where-Object { $_.Privacy })
    if ($privacy.Count -and -not (Confirm-FuAction ("You ticked:`r`n  {0}`r`n`r`nClearing cookies signs you out of websites. Clearing history removes your browsing history and address-bar suggestions. This can't be undone." -f (($picked | Where-Object { $_.Source.Privacy } | ForEach-Object { $_.Title }) -join "`r`n  ")) 'Clear private data?' 'Clear' $true)) { return }
    [double]$bytes = ($chosen | ForEach-Object { [double]$_.Bytes } | Measure-Object -Sum).Sum
    if (-not (Confirm-FuAction ('About {0} will be removed. Only files are deleted, and files in use are skipped.' -f (Format-FuSize $bytes)) 'Clean the selected items?' 'Clean')) { return }
    Set-FuHero 'Cleaning' (Format-FuSize $bytes) 'This usually takes less than a minute.' $true
    Start-FuWork 'Cleaning' { param($targets) Invoke-Cleanup $targets } @(,$chosen) -Exclusive -OnDone {
        param($o)
        $r = $o | Select-Object -First 1
        $script:LastFreed = $r
        if ($r) {
            Show-FuToast ('Freed {0}. Removed {1}{2}.' -f (Format-FuSize ($r.FreedMB * 1MB)), (Get-FuPlural $r.Deleted 'file'), $(if ($r.Skipped) { ", $($r.Skipped) in use were skipped" } else { '' }))
        }
        Start-FuCleanupScan
        Start-FuHomeInfoRefresh
    }
}

# ---------------------------------------------------------------- Large Files, Duplicates, Recover, Secure Delete

# Fills a list and shows its empty message when there is nothing to show
function Set-FuRows([string]$Prefix, $Rows, [string]$Empty = '') {
    $ui = $script:Ui
    $all = @($Rows)
    $ui["${Prefix}List"].ItemsSource = $all
    $ui["${Prefix}Empty"].Text = $Empty
    Set-FuShown $ui["${Prefix}Empty"] ($all.Count -eq 0)
}

function Set-FuLoading([string]$Prefix, [string]$Text) {
    $ui = $script:Ui
    $ui["${Prefix}List"].ItemsSource = @()
    $ui["${Prefix}Empty"].Text = $Text
    Set-FuShown $ui["${Prefix}Empty"] $true
}

function Connect-FuFilePages {
    $ui = $script:Ui

    # Large Files
    $ui.LargeChoose.Add_Click({ $f = Select-FuFolder $script:Ui.LargePath.Text; if ($f) { $script:Ui.LargePath.Text = $f } })
    $ui.LargeFind.Add_Click({ Start-FuLargeFind })
    $ui.LargeList.Add_SelectionChanged({
        $n = $script:Ui.LargeList.SelectedItems.Count
        $script:Ui.LargeReveal.IsEnabled = ($n -eq 1)
        $script:Ui.LargeBin.IsEnabled = ($n -gt 0)
    })
    $ui.LargeReveal.Add_Click({
        $row = $script:Ui.LargeList.SelectedItem
        if ($row) { Start-Process explorer.exe "/select,`"$($row.Path)`"" }
    })
    $ui.LargeBin.Add_Click({
        $picked = @($script:Ui.LargeList.SelectedItems)
        if (-not (Confirm-FuAction ('{0} will move to the Recycle Bin, where you can still get {1} back.' -f (Get-FuPlural $picked.Count 'file'), $(if ($picked.Count -eq 1) { 'it' } else { 'them' })) 'Move to the Recycle Bin?' 'Move')) { return }
        $failed = 0
        foreach ($p in $picked) { try { Send-ToRecycleBin $p.Path } catch { $failed++ } }
        $left = @($script:LargeRows | Where-Object { $picked -notcontains $_ })
        $script:LargeRows = $left
        Set-FuRows 'Large' $left 'No files left in this list.'
        Show-FuToast $(if ($failed) { "$failed couldn't be moved" } else { 'Moved to the Recycle Bin' })
    })

    # Duplicates
    $ui.DupChoose.Add_Click({ $f = Select-FuFolder $script:Ui.DupPath.Text; if ($f) { $script:Ui.DupPath.Text = $f } })
    $ui.DupFind.Add_Click({ Start-FuDupFind })
    $ui.DupList.Add_SelectionChanged({ $script:Ui.DupBin.IsEnabled = ($script:Ui.DupList.SelectedItems.Count -gt 0) })
    $ui.DupBin.Add_Click({
        $picked = @($script:Ui.DupList.SelectedItems)
        if (-not (Confirm-FuAction ('{0} will move to the Recycle Bin. The originals are not touched.' -f (Get-FuPlural $picked.Count 'copy' 'copies')) 'Move to the Recycle Bin?' 'Move')) { return }
        $failed = 0
        foreach ($p in $picked) { try { Send-ToRecycleBin $p.Copy } catch { $failed++ } }
        $left = @($script:DupRows | Where-Object { $picked -notcontains $_ })
        $script:DupRows = $left
        Set-FuRows 'Dup' $left 'No duplicates left.'
        Show-FuToast $(if ($failed) { "$failed couldn't be moved" } else { 'Moved to the Recycle Bin' })
    })

    # Recover
    $ui.RecoverSearch.Add_TextChanged({ Update-FuRecoverFilter })
    $ui.RecoverList.Add_SelectionChanged({ $script:Ui.RecoverGo.IsEnabled = ($script:Ui.RecoverList.SelectedItems.Count -gt 0) })
    $ui.RecoverGo.Add_Click({
        $picked = @($script:Ui.RecoverList.SelectedItems)
        $failed = 0
        foreach ($p in $picked) { try { [void](Restore-RecycleBinEntry $p.InfoPath) } catch { $failed++ } }
        Show-FuToast $(if ($failed) { "$failed couldn't be restored" } else { 'Restored {0}' -f (Get-FuPlural $picked.Count 'file') })
        Start-FuRecoverLoad
    })

    # Secure Delete
    $ui.ShredDrop.Add_MouseLeftButtonUp({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Title = 'Choose a file to delete permanently'
        if ($d.ShowDialog($script:Ui.Window)) { Set-FuShredFile $d.FileName }
    })
    $ui.ShredDrop.Add_DragOver({
        param($s, $e)
        $e.Effects = $(if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' })
        $e.Handled = $true
    })
    $ui.ShredDrop.Add_Drop({
        param($s, $e)
        $files = @($e.Data.GetData([Windows.DataFormats]::FileDrop))
        if ($files.Count -eq 1 -and (Test-Path -LiteralPath $files[0] -PathType Leaf)) { Set-FuShredFile $files[0] }
        else { Show-FuToast 'Drop one file at a time' }
    })
    $ui.ShredGo.Add_Click({ Start-FuShred })
}

function Start-FuLargeFind {
    $path = $script:Ui.LargePath.Text
    if (-not (Test-Path -LiteralPath $path)) { Show-FuInfo "That folder doesn't exist." 'Warning' 'Check the folder'; return }
    Set-FuLoading 'Large' 'Looking through your files'
    Start-FuWork 'Looking through your files' { param($root) Get-LargeFiles $root 200 } @(,$path) -OnDone {
        param($o)
        $script:LargeRows = @($o | ForEach-Object {
            [pscustomobject]@{ Title = $_.Name; Detail = $_.Folder; Value = Format-FuSize $_.Bytes; Path = $_.Path; Tip = $_.Path }
        })
        Set-FuRows 'Large' $script:LargeRows 'This folder is empty.'
    }
}

function Start-FuDupFind {
    $path = $script:Ui.DupPath.Text
    if (-not (Test-Path -LiteralPath $path)) { Show-FuInfo "That folder doesn't exist." 'Warning' 'Check the folder'; return }
    Set-FuLoading 'Dup' 'Comparing files. This can take a while.'
    Start-FuWork 'Looking for duplicates' { param($root) Find-DuplicateFiles $root 1048576 } @(,$path) -OnDone {
        param($o)
        $script:DupRows = @(foreach ($g in @($o)) {
            foreach ($copy in $g.Copies) {
                [pscustomobject]@{ Title = Split-Path -Leaf $copy; Detail = "Same as $($g.Keep)"; Value = Format-FuSize ($g.SizeMB * 1MB); Copy = $copy; Tip = $copy }
            }
        })
        Set-FuRows 'Dup' $script:DupRows 'No duplicates found. Nice and tidy.'
    }
}

function Start-FuRecoverLoad {
    Set-FuLoading 'Recover' 'Loading'
    Start-FuWork 'Reading the Recycle Bin' { Get-RecycleBinEntries } -Quiet -OnDone {
        param($o)
        $script:RecoverRows = @($o | Sort-Object -Property Deleted -Descending | ForEach-Object {
            [pscustomobject]@{
                Title = $_.Name
                Detail = ('From {0}' + (Get-FuSep) + 'Deleted {1:d MMM yyyy}') -f (Split-Path -Parent $_.OriginalPath), $_.Deleted
                Value = Format-FuSize ($_.KB * 1KB)
                InfoPath = $_.InfoPath
                Tip = $_.OriginalPath
            }
        })
        Update-FuRecoverFilter
    }
}

function Update-FuRecoverFilter {
    $q = $script:Ui.RecoverSearch.Text
    $rows = @($script:RecoverRows | Where-Object { -not $q -or $_.Title -like "*$q*" -or $_.Detail -like "*$q*" })
    Set-FuRows 'Recover' $rows $(if ($q) { 'No matches.' } else { 'The Recycle Bin is empty. Files removed with Shift+Delete can''t be recovered here.' })
}

function Set-FuShredFile([string]$Path) {
    $script:ShredFile = $Path
    $ui = $script:Ui
    if ($Path) {
        $ui.ShredName.Text = Split-Path -Leaf $Path
        $ui.ShredPathText.Text = ('{0}' + (Get-FuSep) + '{1}') -f (Format-FuSize (Get-Item -LiteralPath $Path -Force).Length), (Split-Path -Parent $Path)
        $ui.ShredIcon.Text = [string][char]0xE8A5
    } else {
        $ui.ShredName.Text = 'Drop a file here'
        $ui.ShredPathText.Text = 'or click to choose one'
        $ui.ShredIcon.Text = [string][char]0xE8E5
    }
    $ui.ShredGo.IsEnabled = [bool]$Path
}

function Start-FuShred {
    $ui = $script:Ui
    $path = $script:ShredFile
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { Set-FuShredFile ''; return }
    $name = Split-Path -Leaf $path
    if (-not (Confirm-FuAction "'$name' will be overwritten and deleted. This can't be undone, and it doesn't go to the Recycle Bin." 'Delete this file permanently?' 'Delete Permanently' $true)) { return }
    $passes = $(if ($ui.Pass7.IsChecked) { 7 } elseif ($ui.Pass3.IsChecked) { 3 } else { 1 })
    $script:ShredName = $name
    Start-FuWork 'Deleting the file' { param($p, $n) Remove-FileSecurely $p $n } @($path, $passes) -Exclusive -OnDone {
        param($o)
        Set-FuShredFile ''
        Show-FuToast "'$script:ShredName' was overwritten and deleted"
    }
}

# ---------------------------------------------------------------- Startup, Apps, Processes, Services, Disks, Log

function Connect-FuSystemPages {
    $ui = $script:Ui

    # Startup: every switch reports here
    $ui.StartupList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        if ($e.OriginalSource -is [Windows.Controls.Primitives.ToggleButton]) { Set-FuStartupSwitch $e.OriginalSource }
    })
    $ui.StartupSearch.Add_TextChanged({ Update-FuStartupFilter })

    # Apps
    $ui.AppsSearch.Add_TextChanged({ Update-FuAppsFilter })
    $ui.AppsList.Add_SelectionChanged({ $script:Ui.AppsUninstall.IsEnabled = [bool]$script:Ui.AppsList.SelectedItem })
    $ui.AppsUninstall.Add_Click({
        $p = $script:Ui.AppsList.SelectedItem
        if (-not $p) { return }
        if (-not (Confirm-FuAction "The app's own uninstaller will open." "Uninstall $($p.Title)?" 'Uninstall')) { return }
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ' + $p.Uninstall) -WindowStyle Hidden -ErrorAction Stop
            Write-FuLog "Uninstall started: $($p.Title)"
        } catch { Show-FuInfo "The uninstaller didn't start. Try Settings > Apps instead.`r`n`r`n$($_.Exception.Message)" 'Warning' "Couldn't start the uninstaller" }
    })

    # Processes
    $ui.ProcSearch.Add_TextChanged({ Update-FuProcFilter })
    $ui.ProcRefresh.Add_Click({ Start-FuProcLoad })
    $ui.ProcList.Add_SelectionChanged({ $script:Ui.ProcEnd.IsEnabled = [bool]$script:Ui.ProcList.SelectedItem })
    $ui.ProcEnd.Add_Click({
        $p = $script:Ui.ProcList.SelectedItem
        if (-not $p) { return }
        if (Test-FuBlockedBySecurity $p.Name @($p.Name, $p.Path)) { return }
        if (-not (Confirm-FuAction "Unsaved work in $($p.Name) will be lost." "End $($p.Name)?" 'End Process' $true)) { return }
        try {
            Stop-FuProcess $p.Id
            Show-FuToast "$($p.Name) has ended"
        } catch { Show-FuInfo $_.Exception.Message 'Warning' "Couldn't end $($p.Name)" }
        Start-FuProcLoad
    })

    # Services
    $ui.SvcSearch.Add_TextChanged({ Update-FuSvcFilter })
    $ui.SvcList.Add_SelectionChanged({
        $s = $script:Ui.SvcList.SelectedItem
        $script:Ui.SvcStart.IsEnabled = ($s -and $s.Status -ne 'Running')
        $script:Ui.SvcStop.IsEnabled = ($s -and $s.Status -eq 'Running')
    })
    $ui.SvcStart.Add_Click({ Set-FuSelectedService 'Start' })
    $ui.SvcStop.Add_Click({ Set-FuSelectedService 'Stop' })

    # Disk tools
    $ui.DiskScan.Add_Click({ Start-FuVolumeTool 'Checking the drive for errors' { param($l) Repair-Volume -DriveLetter $l -Scan 2>&1 | Out-String } })
    $ui.DiskAnalyze.Add_Click({ Start-FuVolumeTool 'Analyzing the drive' { param($l) Optimize-Volume -DriveLetter $l -Analyze -Verbose 4>&1 | Out-String } })
    $ui.DiskOptimize.Add_Click({
        $letter = Get-FuPickedVolume
        if (-not $letter) { return }
        if (-not (Require-FuAdmin 'Optimizing a drive')) { return }
        if (-not (Confirm-FuAction "This can take a long time. Keep the PC on until it finishes." "Optimize drive ${letter}:?" 'Optimize')) { return }
        Start-FuVolumeTool 'Optimizing the drive' { param($l) Optimize-Volume -DriveLetter $l -Verbose 4>&1 | Out-String }
    })

    # Log
    $ui.LogOpen.Add_Click({
        $dir = Split-Path -Parent (Get-FuLogPath)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Start-Process explorer.exe $dir
    })
}

# --- Startup

function Start-FuStartupLoad {
    if (-not $script:StartupRows) { Set-FuLoading 'Startup' 'Loading' }
    Start-FuWork 'Reading startup programs' { Get-StartupEntries } -Quiet -OnDone {
        param($o)
        Update-FuStartupRows @($o)
        Update-FuStartupTile
    }
}

function ConvertTo-FuStartupRow($Entry) {
    $isOn = $Entry.Status -eq 'On'
    $protected = Test-FuProtected @($Entry.Name, $Entry.Command)
    $kind = $(if ($Entry.Source -eq 'Registry') { 'App' } else { $Entry.Source })
    $first = ([string]$Entry.Name).TrimStart('.', ' ', '_')
    [pscustomobject]@{
        Entry     = $Entry
        Name      = ([string]$Entry.Name -replace '\.lnk$', '')
        Initial   = $(if ($first) { $first.Substring(0, 1).ToUpper() } else { '?' })
        Detail    = ('{0}' + (Get-FuSep) + '{1}') -f $kind, ($Entry.Scope -replace ' \(32-bit\)', '')
        Command   = $Entry.Command
        IsOn      = [bool]$isOn
        CanChange = [bool](-not ($protected -and $isOn))
        TagText   = $(if ($protected) { 'Protected' } else { '' })
        Tone      = $(if ($protected) { 'good' } else { '' })
    }
}

function Update-FuStartupRows($Entries) {
    $script:StartupRows = @($Entries | Sort-Object -Property @{ Expression = { $_.Status -eq 'Off' } }, Name | ForEach-Object { ConvertTo-FuStartupRow $_ })
    Update-FuStartupFilter
    $on = @($script:StartupRows | Where-Object { $_.IsOn }).Count
    $script:Ui.StartupSub.Text = '{0} on, {1} off. Task Manager sees the same switches.' -f $on, ($script:StartupRows.Count - $on)
}

function Update-FuStartupTile {
    $on = @($script:StartupRows | Where-Object { $_.IsOn }).Count
    $script:Ui.TileStartupValue.Text = Get-FuPlural $on 'app'
    $script:Ui.TileStartupSub.Text = 'start with Windows'
}

function Update-FuStartupFilter {
    $q = $script:Ui.StartupSearch.Text
    $rows = @($script:StartupRows | Where-Object { -not $q -or $_.Name -like "*$q*" -or $_.Command -like "*$q*" })
    $coll = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($r in $rows) { $coll.Add($r) }
    $script:StartupView = $coll
    $script:Ui.StartupList.ItemsSource = $coll
    $script:Ui.StartupEmpty.Text = $(if ($q) { 'No matches.' } else { 'Nothing starts with Windows.' })
    Set-FuShown $script:Ui.StartupEmpty ($rows.Count -eq 0)
}

# A switch was flipped: apply it, or put it back
function Set-FuStartupSwitch($Toggle) {
    $row = $Toggle.DataContext
    $want = [bool]$Toggle.IsChecked
    if ($row -isnot [psobject] -or -not $row.Entry) { return }
    if ($row.Entry.Scope -ne 'Current user' -and -not (Require-FuAdmin "Changing '$($row.Name)' for all users")) {
        $Toggle.IsChecked = -not $want
        return
    }
    try {
        Set-StartupEntryState $row.Entry $want
    } catch {
        $Toggle.IsChecked = -not $want
        Show-FuInfo $_.Exception.Message 'Warning' "Couldn't change $($row.Name)"
        return
    }
    $row.Entry.Status = $(if ($want) { 'On' } else { 'Off' })
    $row.IsOn = $want
    $row.CanChange = [bool](-not ((Test-FuProtected @($row.Entry.Name, $row.Entry.Command)) -and $want))
    $on = @($script:StartupRows | Where-Object { $_.IsOn }).Count
    $script:Ui.StartupSub.Text = '{0} on, {1} off. Task Manager sees the same switches.' -f $on, ($script:StartupRows.Count - $on)
    Update-FuStartupTile
    Show-FuToast $(if ($want) { "$($row.Name) will start with Windows" } else { "$($row.Name) won't start with Windows" })
}

# --- Apps

function Start-FuAppsLoad {
    Set-FuLoading 'Apps' 'Loading'
    Start-FuWork 'Reading installed apps' { Get-InstalledPrograms } -Quiet -OnDone {
        param($o)
        $script:AppRows = @($o | ForEach-Object {
            $bits = @($_.Publisher, $_.Version) | Where-Object { $_ }
            [pscustomobject]@{ Title = $_.Name; Detail = ($bits -join (Get-FuSep)); Value = ''; Uninstall = $_.Uninstall; Tip = $_.Uninstall }
        })
        $script:Ui.AppsSub.Text = '{0} on this PC.' -f (Get-FuPlural $script:AppRows.Count 'app')
        Update-FuAppsFilter
    }
}

function Update-FuAppsFilter {
    $q = $script:Ui.AppsSearch.Text
    Set-FuRows 'Apps' @($script:AppRows | Where-Object { -not $q -or $_.Title -like "*$q*" -or $_.Detail -like "*$q*" }) $(if ($q) { 'No matches.' } else { 'No apps found.' })
}

# --- Processes

function Start-FuProcLoad {
    if (-not $script:ProcRows) { Set-FuLoading 'Proc' 'Loading' }
    Start-FuWork 'Reading processes' { Get-ProcessList } -Quiet -OnDone {
        param($o)
        [double]$max = ($o | Measure-Object -Property MemoryMB -Maximum).Maximum
        if ($max -le 0) { $max = 1 }
        $script:ProcRows = @($o | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Path = $_.Path; Threads = $_.Threads; MemoryText = Format-FuSize ($_.MemoryMB * 1MB); MemoryShare = (100 * $_.MemoryMB / $max) }
        })
        $script:Ui.ProcSub.Text = '{0} running, biggest first.' -f (Get-FuPlural $script:ProcRows.Count 'process' 'processes')
        Update-FuProcFilter
    }
}

function Update-FuProcFilter {
    $q = $script:Ui.ProcSearch.Text
    Set-FuRows 'Proc' @($script:ProcRows | Where-Object { -not $q -or $_.Name -like "*$q*" }) 'No matches.'
}

# --- Services

function Start-FuSvcLoad {
    if (-not $script:SvcRows) { Set-FuLoading 'Svc' 'Loading' }
    Start-FuWork 'Reading services' { Get-ServiceList } -Quiet -OnDone {
        param($o)
        $script:SvcRows = @($o | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Status = $_.Status; StartType = $_.StartType; Tone = $(if ($_.Status -eq 'Running') { 'good' } else { 'none' }) }
        })
        $running = @($script:SvcRows | Where-Object { $_.Status -eq 'Running' }).Count
        $script:Ui.SvcSub.Text = '{0} running, out of {1}.' -f $running, $script:SvcRows.Count
        Update-FuSvcFilter
    }
}

function Update-FuSvcFilter {
    $q = $script:Ui.SvcSearch.Text
    Set-FuRows 'Svc' @($script:SvcRows | Where-Object { -not $q -or $_.DisplayName -like "*$q*" -or $_.Name -like "*$q*" }) 'No matches.'
}

function Set-FuSelectedService([string]$Action) {
    $svc = $script:Ui.SvcList.SelectedItem
    if (-not $svc) { return }
    if (Test-FuBlockedBySecurity $svc.DisplayName @($svc.Name, $svc.DisplayName)) { return }
    if (-not (Require-FuAdmin 'Starting or stopping a service')) { return }
    if ($Action -eq 'Stop' -and -not (Confirm-FuAction 'Apps that depend on this service may stop working.' "Stop $($svc.DisplayName)?" 'Stop Service' $true)) { return }
    $script:SvcActing = '{0}: {1}' -f $svc.DisplayName, $(if ($Action -eq 'Stop') { 'stopped' } else { 'started' })
    Start-FuWork "Changing $($svc.DisplayName)" { param($n, $a) Set-FuServiceState $n $a } @($svc.Name, $Action) -Exclusive -OnDone {
        param($o)
        Show-FuToast $script:SvcActing
        Start-FuSvcLoad
    }
}

# --- Disks

function Start-FuDiskLoad {
    Start-FuWork 'Reading disks' {
        [pscustomobject]@{
            Disks = @(Get-DiskHealth | ForEach-Object {
                [pscustomobject]@{ Disk = [string]$_.Disk; Type = [string]$_.Type; SizeGB = $_.SizeGB; Health = [string]$_.Health; TempC = $_.TempC; WearPct = $_.WearPct; ReadErrs = $_.ReadErrs }
            })
            Letters = @(Get-UsableVolumes | Where-Object { $_.Size -ge 1GB } | ForEach-Object { [string]$_.DriveLetter })
        }
    } -Quiet -OnDone { param($o) Update-FuDisks ($o | Select-Object -First 1) }
}

function Format-FuReading($Value, [string]$Suffix) {
    if ($Value -is [string]) { return $(if ($Value -eq 'needs admin') { 'Needs admin' } else { [string][char]0x2013 }) }
    if ($null -eq $Value) { return [string][char]0x2013 }
    return "$Value$Suffix"
}

function Update-FuDisks($Data) {
    if (-not $Data) { return }
    $ui = $script:Ui
    $ui.DiskList.ItemsSource = @($Data.Disks | ForEach-Object {
        # Some drives report 0 degrees when they don't report temperature at all
        $temp = $(if ($_.TempC -is [string] -or $_.TempC) { $_.TempC } else { $null })
        [pscustomobject]@{
            Title    = $_.Disk
            Detail   = ('{0}' + (Get-FuSep) + '{1}') -f $(if ($_.Type -and $_.Type -ne 'Unspecified') { $_.Type } else { 'Drive' }), (Format-FuSize ($_.SizeGB * 1GB))
            TagText  = $_.Health
            Tone     = $(if ($_.Health -eq 'Healthy') { 'good' } elseif ($_.Health -eq 'Warning') { 'warn' } else { 'bad' })
            TempText = Format-FuReading $temp ([string][char]0xB0 + 'C')
            WearText = Format-FuReading $_.WearPct '%'
            ErrText  = Format-FuReading $_.ReadErrs ''
        }
    })
    $ui.DiskSub.Text = $(if (Test-FuAdmin) { 'How your drives are doing.' } else { 'How your drives are doing. Run as administrator to see temperature and wear.' })
    $ui.VolumePick.Children.Clear()
    $first = $true
    foreach ($l in @($Data.Letters)) {
        $r = New-Object Windows.Controls.RadioButton
        $r.Content = "${l}:"
        $r.Tag = $l
        $r.GroupName = 'Volume'
        $r.Style = Get-FuBrush 'Segment'
        $r.IsChecked = $first
        $first = $false
        [void]$ui.VolumePick.Children.Add($r)
    }
}

function Get-FuPickedVolume {
    foreach ($r in $script:Ui.VolumePick.Children) { if ($r.IsChecked) { return [string]$r.Tag } }
    return $null
}

function Start-FuVolumeTool([string]$Label, [scriptblock]$Work) {
    $letter = Get-FuPickedVolume
    if (-not $letter) { return }
    if (-not (Require-FuAdmin $Label)) { return }
    Start-FuWork $Label $Work @(,$letter) -Exclusive -OnDone {
        param($o)
        $script:Ui.DiskOutput.Text = (($o -join "`r`n").Trim())
        Set-FuShown $script:Ui.DiskOutput $true
    }
}

# --- Log

function Update-FuLog {
    Set-FuRows 'Log' @(Get-FuLogEntries 300) 'Nothing yet. Changes Makatools makes will appear here.'
}

# ---------------------------------------------------------------- Settings and updates

function Connect-FuSettings {
    $ui = $script:Ui
    $s = Get-FuSettings
    $mode = $(if ($s.Appearance) { [string]$s.Appearance } else { 'System' })
    $ui["Theme$mode"].IsChecked = $true
    foreach ($name in 'System', 'Light', 'Dark') {
        $ui["Theme$name"].Tag = $name
        $ui["Theme$name"].Add_Click({
            param($sender)
            Set-FuSetting 'Appearance' ([string]$sender.Tag)
            Set-FuTheme ([string]$sender.Tag)
        })
    }
    $ui.ReminderSwitch.IsChecked = [bool]$s.WeeklyReminder
    $ui.ReminderSwitch.Add_Click({ Set-FuSetting 'WeeklyReminder' ([bool]$script:Ui.ReminderSwitch.IsChecked) })

    $isAdmin = Test-FuAdmin
    Set-FuShown $ui.AdminChip (-not $isAdmin)
    Set-FuShown $ui.SettingsAdmin (-not $isAdmin)
    if ($isAdmin) {
        $ui.AdminTitle.Text = 'Running as administrator'
        $ui.AdminText.Text = 'All tools and cleanup items are available.'
    }
    $ui.AdminChip.Add_Click({ Restart-FuAsAdmin })
    $ui.SettingsAdmin.Add_Click({ Restart-FuAsAdmin })

    $ui.AboutVersion.Text = 'Version {0}' -f (Get-FuVersion)
    $ui.SettingsUpdate.Add_Click({ Start-FuUpdateCheck $false })
    $ui.UpdateChip.Add_Click({ if ($script:PendingUpdate) { Confirm-FuUpdate $script:PendingUpdate } })
    $ui.OpenGitHub.Add_Click({
        $repo = Get-FuUpdateRepo
        if ($repo) { Start-Process "https://github.com/$repo" }
    })
}

# Quiet = the automatic check at start-up: says nothing unless there is an update
function Start-FuUpdateCheck([bool]$Quiet) {
    $script:UpdateQuiet = $Quiet
    if (-not (Get-FuUpdateRepo)) {
        if (-not $Quiet) { Show-FuInfo "Automatic updates are not set up in this copy of Makatools $(Get-FuVersion)." }
        return
    }
    # A failed check (offline, GitHub down) comes back as an object with Error, so the automatic
    # check can stay silent
    Start-FuWork 'Checking for updates' { try { Find-FuUpdate } catch { [pscustomobject]@{ Error = $_.Exception.Message } } } -Quiet -OnDone {
        param($o)
        $u = $o | Select-Object -First 1
        if ($u -and $u.Error) {
            if (-not $script:UpdateQuiet) { Show-FuInfo "Check the internet connection and try again.`r`n`r`n$($u.Error)" 'Warning' "Couldn't check for updates" }
            return
        }
        if (-not $u) {
            if (-not $script:UpdateQuiet) { Show-FuInfo "Version $(Get-FuVersion) is the latest." 'Information' "You're up to date" }
            return
        }
        $script:PendingUpdate = $u
        $script:Ui.UpdateChip.Content = "Update to $($u.Version)"
        Set-FuShown $script:Ui.UpdateChip $true
        Confirm-FuUpdate $u
    }
}

function Confirm-FuUpdate($Update) {
    $notes = $(if ($Update.Notes) { "`r`n`r`n" + $Update.Notes.Substring(0, [math]::Min(500, $Update.Notes.Length)) } else { '' })
    if (-not (Show-FuSheet -Title "Makatools $($Update.Version) is ready" -Text ("You have version $(Get-FuVersion). Makatools will close, update and reopen by itself.$notes") -Yes 'Update Now' -No 'Later')) { return }
    Start-FuWork 'Downloading the update' {
        param($update, $folder)
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        Save-FuUpdate $update $folder
    } @($Update, (Join-Path $script:AppRoot 'Updates')) -Exclusive -OnDone {
        param($o)
        $path = [string]($o | Select-Object -First 1)
        try {
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw 'The downloaded file is gone. Antivirus software may have removed it.' }
            Start-Process -FilePath $path -ArgumentList '--update' -ErrorAction Stop
            $script:Ui.Window.Close()
        } catch { Show-FuUpdateFallback $_.Exception.Message }
    } -OnFail { param($why) Show-FuUpdateFallback $why }
}

# If the update can't run here (antivirus, no connection), offer the download page
function Show-FuUpdateFallback([string]$Why) {
    if (Show-FuSheet -Title "The update didn't start" -Text "$Why`r`n`r`nYou can download the new version from the Makatools page on GitHub instead." -Yes 'Open Download Page' -No 'Not Now' -Kind 'warn') {
        Start-Process "https://github.com/$(Get-FuUpdateRepo)/releases/latest"
    }
}
