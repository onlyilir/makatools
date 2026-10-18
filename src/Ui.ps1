# Makatools - user interface. All real work lives in Core.ps1; this file only wires buttons to it.
# Slow work runs in a background job (Start-FuWork) so the window stays responsive.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Draw buttons, tabs and lists in the current Windows style rather than the old flat one
[System.Windows.Forms.Application]::EnableVisualStyles()

# On screens scaled above 100%, Windows stretches programs that don't scale themselves, which
# blurs the text. This tells Windows Makatools scales itself (the window uses AutoScaleMode Dpi).
# It must run before the first window is created.
if (-not ('Makatools.NativeDpi' -as [type])) {
    Add-Type -Namespace Makatools -Name NativeDpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
}
[void][Makatools.NativeDpi]::SetProcessDPIAware()

# ---------------------------------------------------------------- UI helpers

function Show-FuInfo($Text, $Icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($Text, 'Makatools', 'OK', $Icon) | Out-Null
}

function Confirm-FuAction($Text) {
    return ([System.Windows.Forms.MessageBox]::Show($Text, 'Please confirm', 'YesNo', 'Question') -eq 'Yes')
}

function Require-FuAdmin($What) {
    if (Test-FuAdmin) { return $true }
    Show-FuInfo "$What needs Administrator rights.`r`n`r`nUse 'Restart as admin' on the Dashboard tab, then try again." 'Warning'
    return $false
}

# Shows why an antivirus item is left alone. Returns $true when the caller should stop.
function Test-FuBlockedBySecurity($What, [string[]]$Text) {
    if (-not (Test-FuProtected $Text)) { return $false }
    Show-FuInfo "'$What' is part of your antivirus (for example Norton 360 or Microsoft Defender).`r`n`r`nMakatools does not change security software. Use the antivirus's own settings instead." 'Warning'
    return $true
}

function Set-FuGrid($Grid, $Items, [string[]]$Hide = @()) {
    $list = New-Object System.Collections.ArrayList
    foreach ($i in @($Items)) { [void]$list.Add($i) }
    $Grid.DataSource = $null
    $Grid.DataSource = $list
    foreach ($h in $Hide) { if ($Grid.Columns[$h]) { $Grid.Columns[$h].Visible = $false } }
}

function New-FuGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $true
    $g.AutoSizeColumnsMode = 'Fill'
    $g.RowHeadersVisible = $false
    $g.BackgroundColor = [System.Drawing.Color]::White
    return $g
}

function New-FuButton($Text, $Handler) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.Add_Click($Handler)
    return $b
}

function New-FuBar {
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'
    $bar.AutoSize = $true
    $bar.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    return $bar
}

function New-FuTab($Tabs, $Title) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Title
    $page.Padding = New-Object System.Windows.Forms.Padding(8)
    [void]$Tabs.TabPages.Add($page)
    return $page
}

function New-FuText([bool]$Mono = $true) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true
    $t.ReadOnly = $true
    $t.ScrollBars = 'Vertical'
    $t.Dock = 'Fill'
    if ($Mono) { $t.Font = New-Object System.Drawing.Font('Consolas', 9) }
    return $t
}

# Window icon: assets\Makatools.ico next to the script, or the icon built into Makatools.exe
function Get-FuIcon {
    $ico = Join-Path $script:AppRoot 'assets\Makatools.ico'
    try {
        if (Test-Path -LiteralPath $ico) { return New-Object System.Drawing.Icon($ico) }
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ((Split-Path -Leaf $exe) -notlike 'powershell*') { return [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- background work

# Slow work runs in a second runspace inside this process: it starts in milliseconds (a
# Start-Job process took about half a second), stops at once when cancelled, and hands back
# live objects. The runspace gets every loaded function, plus $AppRoot and the shared
# $FuProgress table that Core's Set-FuProgress writes to. UI functions come along too; that
# is harmless, and filtering by name once dropped a Core helper by mistake.
function New-FuRunspace {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in Get-ChildItem -Path Function:\) {
        if ($f.ScriptBlock) {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.ScriptBlock.ToString())))
        }
    }
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('AppRoot', $script:AppRoot, '')))
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('FuProgress', $script:FuProgress, '')))
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'   # shell calls such as emptying the Recycle Bin expect STA
    $rs.Open()
    return $rs
}

# Runs $Work in the background and calls $OnDone with its output when finished.
function Start-FuWork {
    param([string]$Label, [scriptblock]$Work, [object[]]$Arguments = @(), [scriptblock]$OnDone)
    if ($script:Job) { Show-FuInfo 'Another task is still running. Wait for it or press Cancel task.'; return }
    $script:FuProgress.Text = ''
    $script:FuProgress.Percent = -1
    $rs = New-FuRunspace
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Work.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $script:Job = @{ Label = $Label; PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
    $script:OnDone = $OnDone
    $script:StatusLabel.Text = "$Label..."
    $script:ProgressBar.Style = 'Marquee'
    $script:ProgressBar.Visible = $true
    $script:CancelButton.Enabled = $true
    $script:JobTimer.Start()
}

function Stop-FuWork {
    if ($script:Job) { [void]$script:Job.PS.BeginStop($null, $null) }
}

# ---------------------------------------------------------------- main window

function Show-MainForm {
    $form = New-MainForm
    [void][System.Windows.Forms.Application]::Run($form)
}

# Builds the window without showing it, so tests can drive it.
function New-MainForm {
    $script:BackupDir = Join-Path $script:AppRoot 'Backups'
    $script:Job = $null
    $script:FuProgress = [hashtable]::Synchronized(@{ Text = ''; Percent = -1 })
    # Event handlers run after the Add-*Tab function that made them has returned, so they cannot
    # see its local variables. Controls and scriptblocks a handler needs are kept here instead.
    $script:Ui = @{}

    $form = New-Object System.Windows.Forms.Form
    # Sizes below are written for 100% scaling (96 DPI); WinForms scales them up on larger settings
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.Text = 'Makatools ' + (Get-FuVersion)
    $form.Size = New-Object System.Drawing.Size(1040, 700)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $icon = Get-FuIcon
    if ($icon) { $form.Icon = $icon }
    $script:Form = $form

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs)
    $script:Ui.Tabs = $tabs

    $status = New-Object System.Windows.Forms.StatusStrip
    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    if (Test-FuAdmin) { $script:StatusLabel.Text = 'Running as Administrator' }
    else { $script:StatusLabel.Text = 'Limited mode: some actions need Administrator rights' }
    $script:CancelButton = New-Object System.Windows.Forms.ToolStripButton
    $script:CancelButton.Text = 'Cancel task'
    $script:CancelButton.Enabled = $false
    $script:CancelButton.Add_Click({
        if ($script:Job) { Stop-FuWork; $script:StatusLabel.Text = 'Cancelling...' }
    })
    $script:StatusLabel.Spring = $true
    $script:StatusLabel.TextAlign = 'MiddleLeft'
    $script:ProgressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:ProgressBar.Size = New-Object System.Drawing.Size(160, 16)
    $script:ProgressBar.MarqueeAnimationSpeed = 30
    $script:ProgressBar.Visible = $false
    [void]$status.Items.Add($script:StatusLabel)
    [void]$status.Items.Add($script:ProgressBar)
    [void]$status.Items.Add($script:CancelButton)
    $form.Controls.Add($status)

    # Shows the task's progress, then hands its output to the waiting handler when it finishes
    $script:JobTimer = New-Object System.Windows.Forms.Timer
    $script:JobTimer.Interval = 150
    $script:JobTimer.Add_Tick({
        $task = $script:Job
        if (-not $task) { $script:JobTimer.Stop(); return }
        $p = $script:FuProgress
        if ($p.Text) { $script:StatusLabel.Text = '{0}: {1}' -f $task.Label, $p.Text }
        if ($p.Percent -ge 0) {
            $script:ProgressBar.Style = 'Continuous'
            $script:ProgressBar.Value = [math]::Min(100, [math]::Max(0, [int]$p.Percent))
        } else {
            $script:ProgressBar.Style = 'Marquee'
        }
        if (-not $task.Handle.IsCompleted) { return }

        $script:JobTimer.Stop()
        $output = @()
        $reason = $null
        try { $output = @($task.PS.EndInvoke($task.Handle)) }
        catch { $reason = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) }
        $state = [string]$task.PS.InvocationStateInfo.State
        if ($state -eq 'Failed' -and $task.PS.InvocationStateInfo.Reason) { $reason = $task.PS.InvocationStateInfo.Reason.Message }
        $task.PS.Dispose()
        $task.Runspace.Dispose()
        $script:Job = $null
        $script:CancelButton.Enabled = $false
        $script:ProgressBar.Visible = $false
        if ($state -eq 'Stopped') { $script:StatusLabel.Text = 'Cancelled'; return }
        if ($state -eq 'Failed') {
            $script:StatusLabel.Text = 'Task failed'
            Show-FuInfo "The task failed.`r`n$reason" 'Error'
            return
        }
        $script:StatusLabel.Text = 'Ready'
        & $script:OnDone $output
    })

    Add-DashboardTab $tabs
    Add-CleanupTab $tabs
    Add-StartupTab $tabs
    Add-ProcessTab $tabs
    Add-ServiceTab $tabs
    Add-ProgramsTab $tabs
    Add-DuplicatesTab $tabs
    Add-RecycleTab $tabs
    Add-ShredTab $tabs
    Add-DiskTab $tabs
    Add-LargeFilesTab $tabs
    Add-LogTab $tabs

    $form.Add_Shown({
        $script:Ui.Tabs.SelectedIndex = 0
        $script:Ui.Tabs.Focus()   # otherwise the read-only dashboard text gets focus and shows all selected
        $busy = & $script:Ui.ReminderCheck
        if (-not $busy -and (Get-FuUpdateRepo) -and -not $script:NoUpdateCheck) { & $script:Ui.UpdateCheck $true }
    })
    # Weekly reminder: offers a cleanup when the last one was a week or more ago.
    # Returns $true when a cleanup was started.
    $script:Ui.ReminderCheck = {
        if (-not (Test-FuCleanupDue)) { return $false }
        Set-FuSetting 'LastReminder' (Get-Date)
        $days = Get-FuDaysSinceCleanup
        $q = $(if ($null -eq $days) { 'Makatools has not cleaned up this PC yet. Clean up now?' } else { "It has been $days days since Makatools last cleaned up. Clean up now?" })
        return [bool](& $script:Ui.RunOptimize $q 'Weekly reminder')
    }
    $form.Add_FormClosing({ if ($script:Job) { $script:Job.PS.Stop() } })
    return $form
}

# ---------------------------------------------------------------- tabs

function Add-DashboardTab($Tabs) {
    $page = New-FuTab $Tabs 'Dashboard'
    $text = New-FuText
    $text.Font = New-Object System.Drawing.Font('Consolas', 10)
    $script:Ui.DashText = $text
    $script:Ui.DashRefresh = {
        $days = Get-FuDaysSinceCleanup
        $last = $(if ($null -eq $days) { 'not yet' } elseif ($days -eq 0) { 'today' } elseif ($days -eq 1) { 'yesterday' } else { "$days days ago" })
        $script:Ui.DashText.Text = "Makatools $(Get-FuVersion)    Last cleanup: $last`r`n`r`n" + (Get-SystemSummary)
        $script:StatusLabel.Text = 'Dashboard refreshed'
    }
    $bar = New-FuBar
    $logo = Join-Path $script:AppRoot 'assets\logo.png'
    if (Test-Path -LiteralPath $logo) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image = [System.Drawing.Image]::FromFile($logo)
        $pic.SizeMode = 'Zoom'
        $pic.Size = New-Object System.Drawing.Size(64, 64)
        $pic.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
        [void]$bar.Controls.Add($pic)
    }
    # Asks, then scans and cleans the recommended items. Returns $true when the cleanup started.
    $script:Ui.RunOptimize = {
        param([string]$Question, [string]$Reason)
        if (-not (Confirm-FuAction ($Question + "`r`n`r`nThese are the items the Cleanup tab ticks for you. Privacy items, the Recycle Bin and programs that are open are left alone."))) { return $false }
        Start-FuWork 'Optimizing' ([scriptblock]::Create("Invoke-AutoClean '$Reason'")) -OnDone {
            param($o)
            $r = $o | Select-Object -First 1
            if (-not $r) { return }
            $msg = 'Freed {0:N1} MB ({1} files from {2} places).' -f $r.FreedMB, $r.Deleted, $r.Items
            if ($r.Skipped) { $msg += "`r`n{0} files were in use and were skipped." -f $r.Skipped }
            if (@($r.LeftForOpenPrograms).Count) { $msg += "`r`n`r`nLeft alone because the program is open (close it and run again to clean these):`r`n  " + (@($r.LeftForOpenPrograms) -join "`r`n  ") }
            Show-FuInfo $msg
            & $script:Ui.DashRefresh
        }
        return $true
    }
    $optimize = New-FuButton 'Optimize now' { [void](& $script:Ui.RunOptimize 'Clean temp files, caches and other leftovers now?' 'One-click') }
    $optimize.Font = New-Object System.Drawing.Font($optimize.Font, [System.Drawing.FontStyle]::Bold)
    [void]$bar.Controls.Add($optimize)
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.DashRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'Check for updates' { & $script:Ui.UpdateCheck $false }))
    [void]$bar.Controls.Add((New-FuButton 'Restart as admin' {
        if (Test-FuAdmin) { Show-FuInfo 'Already running as Administrator.'; return }
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $script:AppRoot 'Makatools.ps1')`"")
            $script:Form.Close()
        } catch { Show-FuInfo "Elevation was cancelled.`r`n$($_.Exception.Message)" 'Warning' }
    }))
    [void]$page.Controls.Add($text)
    [void]$page.Controls.Add($bar)
    & $script:Ui.DashRefresh

    # Update check. Quiet = the automatic check at start-up: says nothing unless there is an update.
    $script:Ui.UpdateCheck = {
        param([bool]$quiet)
        $script:Ui.UpdateQuiet = $quiet
        if (-not (Get-FuUpdateRepo)) {
            if (-not $quiet) { Show-FuInfo "Makatools $(Get-FuVersion).`r`n`r`nAutomatic updates are not set up in this copy yet." }
            return
        }
        # A failed check (offline, GitHub down) comes back as an object with Error, so the automatic
        # check at start-up can stay silent instead of showing "task failed" every time
        Start-FuWork 'Checking for updates' { try { Find-FuUpdate } catch { [pscustomobject]@{ Error = $_.Exception.Message } } } -OnDone {
            param($o)
            $u = $o | Select-Object -First 1
            if ($u -and $u.Error) {
                if (-not $script:Ui.UpdateQuiet) { Show-FuInfo "Could not check for updates. Check the internet connection and try again.`r`n`r`n$($u.Error)" 'Warning' }
                return
            }
            if (-not $u) {
                if (-not $script:Ui.UpdateQuiet) { Show-FuInfo "You have the latest version ($(Get-FuVersion))." }
                return
            }
            $notes = $(if ($u.Notes) { "`r`n`r`nWhat's new:`r`n" + $u.Notes.Substring(0, [math]::Min(600, $u.Notes.Length)) } else { '' })
            if (-not (Confirm-FuAction ("Makatools {0} is available (you have {1}).`r`n`r`nDownload and install it now? Makatools closes while the update installs.{2}" -f $u.Version, (Get-FuVersion), $notes))) { return }
            Start-FuWork 'Downloading update' { param($update) Save-FuUpdate $update } @(,$u) {
                param($o)
                $path = [string]($o | Select-Object -First 1)
                if (-not $path) { return }
                Start-Process -FilePath $path
                $script:Form.Close()
            }
        }
    }
}

function Add-CleanupTab($Tabs) {
    $page = New-FuTab $Tabs 'Cleanup'
    $script:CleanupRows = @()
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = 'Fill'
    $list.CheckOnClick = $true
    $list.IntegralHeight = $false
    $script:Ui.CleanupList = $list

    $script:Ui.CleanupShow = {
        param($rows)
        $script:CleanupRows = @($rows)
        $script:Ui.CleanupList.Items.Clear()
        $isAdmin = Test-FuAdmin
        [int64]$total = 0
        foreach ($r in $script:CleanupRows) {
            $admin = ''
            if ($r.NeedsAdmin -and -not $isAdmin) { $admin = '  [needs admin]' }
            $i = $script:Ui.CleanupList.Items.Add(('{0}  -  {1} MB in {2} files{3}' -f $r.Target, $r.MB, $r.Files, $admin))
            # Tick the safe ones that can actually be cleaned with the current rights
            if ($r.Recommended -and ($isAdmin -or -not $r.NeedsAdmin)) {
                $script:Ui.CleanupList.SetItemChecked($i, $true)
                $total += $r.Bytes
            }
        }
        $script:StatusLabel.Text = 'Scan complete. {0:N0} MB ticked. Review the list, then press Clean.' -f ($total / 1MB)
    }
    $script:Ui.CleanupScan = { Start-FuWork 'Scanning' { Get-CleanupTargets } -OnDone $script:Ui.CleanupShow }

    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Scan' { & $script:Ui.CleanupScan }))
    [void]$bar.Controls.Add((New-FuButton 'Clean ticked locations' {
        $chosen = @()
        foreach ($i in $script:Ui.CleanupList.CheckedIndices) { $chosen += $script:CleanupRows[$i] }
        if ($chosen.Count -eq 0) { Show-FuInfo 'Tick at least one location first.'; return }
        $open = @(Get-FuOpenPrograms $chosen)
        if ($open.Count -and -not (Confirm-FuAction ("These programs are open: {0}.`r`n`r`nTheir files are in use, so not all of them can be cleaned. Close them first for a full clean.`r`n`r`nClean anyway?" -f ($open -join ', ')))) { return }
        $privacy = @($chosen | Where-Object { $_.Privacy })
        if ($privacy.Count -and -not (Confirm-FuAction ("You ticked privacy items:`r`n  {0}`r`n`r`nClearing cookies signs you out of websites. Clearing history removes your browsing history and address-bar suggestions. This cannot be undone.`r`n`r`nContinue?" -f (($privacy | ForEach-Object { $_.Target }) -join "`r`n  ")))) { return }
        $mb = ($chosen | Measure-Object -Property MB -Sum).Sum
        if (-not (Confirm-FuAction ("Delete the files in the ticked locations (about {0:N1} MB)?`r`n`r`nOnly files are removed. Files in use are skipped.`r`nLocations that need admin are skipped when not elevated." -f $mb))) { return }
        $onDone = {
            param($output)
            $r = $output | Select-Object -First 1
            if ($r) { Show-FuInfo ("Freed {0:N1} MB. Deleted {1} files, skipped {2} in use." -f $r.FreedMB, $r.Deleted, $r.Skipped) }
            & $script:Ui.CleanupScan
        }
        Start-FuWork 'Cleaning' { param($targets) Invoke-Cleanup $targets } @(,$chosen) $onDone
    }))
    [void]$bar.Controls.Add((New-FuButton 'Windows component cleanup' {
        if (-not (Require-FuAdmin 'Windows component cleanup')) { return }
        if (-not (Confirm-FuAction "Remove old versions of Windows components left behind by updates?`r`n`r`nThis is the same as Disk Cleanup's 'Windows Update Cleanup'. It can take 10 minutes or more. Updates installed so far can no longer be uninstalled afterwards.")) { return }
        Start-FuWork 'Windows component cleanup (this can take 10+ minutes)' { Invoke-ComponentCleanup } -OnDone { param($o) Show-FuInfo ($o -join "`r`n") }
    }))
    # A reminder when Makatools opens, not a hidden background task (antivirus treats those as malware)
    $weekly = New-Object System.Windows.Forms.CheckBox
    $weekly.Text = 'Remind me to clean up when it has been a week'
    $weekly.AutoSize = $true
    $weekly.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
    $weekly.Checked = [bool](Get-FuSettings).WeeklyReminder
    $script:Ui.CleanupWeekly = $weekly
    $weekly.Add_Click({ Set-FuSetting 'WeeklyReminder' ([bool]$script:Ui.CleanupWeekly.Checked) })
    [void]$bar.Controls.Add($weekly)
    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Ticked for you: caches and leftovers that rebuild themselves. Privacy items (history, cookies) are never ticked for you. Passwords, bookmarks and the registry are never touched.'
    $note.AutoSize = $true
    [void]$bar.Controls.Add($note)
    [void]$page.Controls.Add($list)
    [void]$page.Controls.Add($bar)
}

function Add-StartupTab($Tabs) {
    $page = New-FuTab $Tabs 'Startup'
    $grid = New-FuGrid
    $script:Ui.StartupGrid = $grid
    $script:StartupItems = @()
    $script:Ui.StartupRefresh = {
        # Programs that start with Windows first, then the ones already switched off
        $script:StartupItems = @(Get-StartupEntries | Sort-Object -Property @{ Expression = { $_.Status -eq 'Off' } }, Name)
        Set-FuGrid $script:Ui.StartupGrid $script:StartupItems @('Location', 'ApprovedKey', 'TaskPath')
        $on = @($script:StartupItems | Where-Object { $_.Status -eq 'On' }).Count
        $script:StatusLabel.Text = '{0} startup entries: {1} on, {2} off' -f $script:StartupItems.Count, $on, ($script:StartupItems.Count - $on)
    }
    # Switches the selected entry on or off. Same flag as Task Manager, so nothing is deleted.
    $script:Ui.StartupSet = {
        param([bool]$enable)
        if ($script:Ui.StartupGrid.SelectedRows.Count -eq 0) { Show-FuInfo 'Select an entry first.'; return }
        $entry = $script:StartupItems[$script:Ui.StartupGrid.SelectedRows[0].Index]
        $want = $(if ($enable) { 'On' } else { 'Off' })
        if ($entry.Status -eq $want) { Show-FuInfo "'$($entry.Name)' is already $($want.ToLower())."; return }
        if (-not $enable -and (Test-FuBlockedBySecurity $entry.Name @($entry.Name, $entry.Command))) { return }
        if ($entry.Scope -ne 'Current user' -and -not (Require-FuAdmin 'Changing startup entries for all users')) { return }
        if (-not $enable) {
            $what = $(if ($entry.Source -eq 'Scheduled task') { 'This scheduled task will not run until you switch it back on.' } else { 'It will not start with Windows from your next sign-in.' })
            if (-not (Confirm-FuAction "Switch off '$($entry.Name)'?`r`n`r`n$($entry.Command)`r`n`r`n$what Nothing is deleted; you can switch it back on here or in Task Manager.")) { return }
        }
        try { Set-StartupEntryState $entry $enable }
        catch { Show-FuInfo "Could not change it.`r`n$($_.Exception.Message)" 'Error' }
        & $script:Ui.StartupRefresh
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.StartupRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'Switch off' { & $script:Ui.StartupSet $false }))
    [void]$bar.Controls.Add((New-FuButton 'Switch on' { & $script:Ui.StartupSet $true }))
    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Programs, Startup-folder shortcuts and sign-in tasks. Switching off works like Task Manager: nothing is deleted. Antivirus entries are never switched off.'
    $note.AutoSize = $true
    [void]$bar.Controls.Add($note)
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ if ($script:Ui.StartupGrid.Rows.Count -eq 0) { & $script:Ui.StartupRefresh } })
}

function Add-ProcessTab($Tabs) {
    $page = New-FuTab $Tabs 'Processes'
    $grid = New-FuGrid
    $script:Ui.ProcessGrid = $grid
    $script:ProcessRows = @()
    $script:Ui.ProcessShow = {
        param($rows)
        $script:ProcessRows = @($rows)
        Set-FuGrid $script:Ui.ProcessGrid $script:ProcessRows
        $script:StatusLabel.Text = '{0} processes' -f $script:ProcessRows.Count
    }
    $script:Ui.ProcessRefresh = { Start-FuWork 'Loading processes' { Get-ProcessList } -OnDone $script:Ui.ProcessShow }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.ProcessRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'End selected process' {
        if ($script:Ui.ProcessGrid.SelectedRows.Count -eq 0) { Show-FuInfo 'Select a process first.'; return }
        $p = $script:ProcessRows[$script:Ui.ProcessGrid.SelectedRows[0].Index]
        if (Test-FuBlockedBySecurity $p.Name @($p.Name, $p.Path)) { return }
        if (-not (Confirm-FuAction "End '$($p.Name)' (PID $($p.Id))?`r`n`r`nUnsaved work in that program will be lost.")) { return }
        try { Stop-FuProcess $p.Id } catch { Show-FuInfo "Could not end it.`r`n$($_.Exception.Message)" 'Error' }
        & $script:Ui.ProcessRefresh
    }))
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ if ($script:Ui.ProcessGrid.Rows.Count -eq 0) { & $script:Ui.ProcessRefresh } })
}

function Add-ServiceTab($Tabs) {
    $page = New-FuTab $Tabs 'Services'
    $grid = New-FuGrid
    $script:Ui.ServiceGrid = $grid
    $script:ServiceRows = @()
    $script:Ui.ServiceRefresh = {
        $script:ServiceRows = @(Get-ServiceList)
        Set-FuGrid $script:Ui.ServiceGrid $script:ServiceRows
        $script:StatusLabel.Text = '{0} services' -f $script:ServiceRows.Count
    }
    $script:Ui.ServiceAct = {
        param($action)
        if ($script:Ui.ServiceGrid.SelectedRows.Count -eq 0) { Show-FuInfo 'Select a service first.'; return }
        if (-not (Require-FuAdmin 'Starting or stopping services')) { return }
        $svc = $script:ServiceRows[$script:Ui.ServiceGrid.SelectedRows[0].Index]
        if (Test-FuBlockedBySecurity $svc.DisplayName @($svc.Name, $svc.DisplayName)) { return }
        if ($action -eq 'Stop' -and -not (Confirm-FuAction "Stop '$($svc.DisplayName)'?`r`nPrograms that depend on it may stop working.")) { return }
        try { Set-FuServiceState $svc.Name $action } catch { Show-FuInfo "Could not $action it.`r`n$($_.Exception.Message)" 'Error' }
        & $script:Ui.ServiceRefresh
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.ServiceRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'Start' { & $script:Ui.ServiceAct 'Start' }))
    [void]$bar.Controls.Add((New-FuButton 'Stop' { & $script:Ui.ServiceAct 'Stop' }))
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ if ($script:Ui.ServiceGrid.Rows.Count -eq 0) { & $script:Ui.ServiceRefresh } })
}

function Add-ProgramsTab($Tabs) {
    $page = New-FuTab $Tabs 'Installed Programs'
    $grid = New-FuGrid
    $script:Ui.ProgramGrid = $grid
    $script:ProgramRows = @()
    $script:Ui.ProgramRefresh = {
        $script:ProgramRows = @(Get-InstalledPrograms)
        Set-FuGrid $script:Ui.ProgramGrid $script:ProgramRows
        $script:StatusLabel.Text = '{0} programs' -f $script:ProgramRows.Count
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.ProgramRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'Uninstall selected' {
        if ($script:Ui.ProgramGrid.SelectedRows.Count -eq 0) { Show-FuInfo 'Select a program first.'; return }
        $p = $script:ProgramRows[$script:Ui.ProgramGrid.SelectedRows[0].Index]
        if (-not (Confirm-FuAction "Uninstall '$($p.Name)'?`r`n`r`nThe program's own uninstaller will open.")) { return }
        try { Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ' + $p.Uninstall) } catch { Show-FuInfo "Could not start the uninstaller.`r`n$($_.Exception.Message)" 'Error' }
        Write-FuLog "Uninstall started: $($p.Name)"
    }))
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ if ($script:Ui.ProgramGrid.Rows.Count -eq 0) { & $script:Ui.ProgramRefresh } })
}

function Add-DuplicatesTab($Tabs) {
    $page = New-FuTab $Tabs 'Duplicates'
    $grid = New-FuGrid
    $script:Ui.DupGrid = $grid
    $script:DupRows = @()
    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Text = $env:USERPROFILE
    $pathBox.Width = 420
    $script:Ui.DupPath = $pathBox
    $script:Ui.DupShow = {
        param($groups)
        $rows = foreach ($g in @($groups)) {
            foreach ($copy in $g.Copies) {
                [pscustomobject]@{ SizeMB = $g.SizeMB; Copy = $copy; KeptOriginal = $g.Keep }
            }
        }
        $script:DupRows = @($rows)
        Set-FuGrid $script:Ui.DupGrid $script:DupRows
        $script:StatusLabel.Text = '{0} duplicate copies found. Nothing was deleted.' -f $script:DupRows.Count
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add($pathBox)
    [void]$bar.Controls.Add((New-FuButton 'Browse...' {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $script:Ui.DupPath.Text = $dlg.SelectedPath }
    }))
    [void]$bar.Controls.Add((New-FuButton 'Find duplicates' {
        if (-not (Test-Path -LiteralPath $script:Ui.DupPath.Text)) { Show-FuInfo 'That folder does not exist.' 'Warning'; return }
        Start-FuWork 'Looking for duplicates (this can take a while)' { param($root) Find-DuplicateFiles $root 1048576 } @(,$script:Ui.DupPath.Text) $script:Ui.DupShow
    }))
    [void]$bar.Controls.Add((New-FuButton 'Send selected copies to Recycle Bin' {
        if ($script:Ui.DupGrid.SelectedRows.Count -eq 0) { Show-FuInfo 'Select one or more copies first.'; return }
        $picked = @($script:Ui.DupGrid.SelectedRows | ForEach-Object { $script:DupRows[$_.Index] })
        if (-not (Confirm-FuAction ("Move {0} copies to the Recycle Bin? The kept originals are not touched." -f $picked.Count))) { return }
        $failed = 0
        foreach ($p in $picked) {
            try { Send-ToRecycleBin $p.Copy } catch { $failed++ }
        }
        $script:DupRows = @($script:DupRows | Where-Object { $picked -notcontains $_ })
        Set-FuGrid $script:Ui.DupGrid $script:DupRows
        if ($failed -gt 0) { Show-FuInfo "$failed copies could not be moved." 'Warning' }
    }))
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
}

function Add-RecycleTab($Tabs) {
    $page = New-FuTab $Tabs 'Recover Deleted'
    $grid = New-FuGrid
    $script:Ui.RecycleGrid = $grid
    $script:RecycleRows = @()
    $script:Ui.RecycleRefresh = {
        $script:RecycleRows = @(Get-RecycleBinEntries)
        Set-FuGrid $script:Ui.RecycleGrid $script:RecycleRows
        $script:StatusLabel.Text = '{0} items in the Recycle Bin' -f $script:RecycleRows.Count
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.RecycleRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'Restore selected' {
        if ($script:Ui.RecycleGrid.SelectedRows.Count -eq 0) { Show-FuInfo 'Select an item first.'; return }
        $item = $script:RecycleRows[$script:Ui.RecycleGrid.SelectedRows[0].Index]
        try {
            $dest = Restore-RecycleBinEntry $item.InfoPath
            Show-FuInfo "Restored to:`r`n$dest"
        } catch { Show-FuInfo "Could not restore it.`r`n$($_.Exception.Message)" 'Error' }
        & $script:Ui.RecycleRefresh
    }))
    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Recovers files that went to the Recycle Bin. Files deleted with Shift+Delete or secure delete cannot be recovered here.'
    $note.AutoSize = $true
    [void]$bar.Controls.Add($note)
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ if ($script:Ui.RecycleGrid.Rows.Count -eq 0) { & $script:Ui.RecycleRefresh } })
}

function Add-ShredTab($Tabs) {
    $page = New-FuTab $Tabs 'Secure Delete'
    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Width = 480
    $script:Ui.ShredPath = $pathBox
    $passes = New-Object System.Windows.Forms.NumericUpDown
    $passes.Minimum = 1
    $passes.Maximum = 7
    $passes.Value = 1
    $script:Ui.ShredPasses = $passes
    $warn = New-Object System.Windows.Forms.Label
    $warn.AutoSize = $true
    $warn.Text = 'Overwrites the file with random data, then deletes it. This is permanent. On SSDs and journaled file systems, old copies can survive, so it is not a guarantee.'
    $warn.MaximumSize = New-Object System.Drawing.Size(900, 0)
    $bar = New-FuBar
    [void]$bar.Controls.Add($warn)
    [void]$bar.Controls.Add($pathBox)
    [void]$bar.Controls.Add((New-FuButton 'Browse file...' {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        if ($dlg.ShowDialog() -eq 'OK') { $script:Ui.ShredPath.Text = $dlg.FileName }
    }))
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Passes:'
    $label.AutoSize = $true
    [void]$bar.Controls.Add($label)
    [void]$bar.Controls.Add($passes)
    [void]$bar.Controls.Add((New-FuButton 'Shred file permanently' {
        $path = $script:Ui.ShredPath.Text
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Show-FuInfo 'Pick an existing file first.' 'Warning'; return }
        $name = Split-Path -Leaf $path
        if (-not (Confirm-FuAction "PERMANENTLY destroy '$name'?`r`n`r`nThis cannot be undone and it does not use the Recycle Bin.")) { return }
        try {
            Remove-FileSecurely $path ([int]$script:Ui.ShredPasses.Value)
            Show-FuInfo "'$name' was overwritten and deleted."
            $script:Ui.ShredPath.Text = ''
        } catch { Show-FuInfo "Could not shred it.`r`n$($_.Exception.Message)" 'Error' }
    }))
    [void]$page.Controls.Add($bar)
}

function Add-DiskTab($Tabs) {
    $page = New-FuTab $Tabs 'Disk Health'
    $grid = New-FuGrid
    $script:Ui.DiskGrid = $grid
    $out = New-FuText
    $out.Height = 160
    $out.Dock = 'Bottom'
    $script:Ui.DiskOut = $out
    $volBox = New-Object System.Windows.Forms.ComboBox
    $volBox.DropDownStyle = 'DropDownList'
    $volBox.Width = 80
    foreach ($v in Get-UsableVolumes) { [void]$volBox.Items.Add([string]$v.DriveLetter) }
    if ($volBox.Items.Count -gt 0) { $volBox.SelectedIndex = 0 }
    $script:Ui.DiskVolume = $volBox
    $script:Ui.DiskRefresh = { Set-FuGrid $script:Ui.DiskGrid @(Get-DiskHealth) }
    $script:Ui.DiskShowOutput = { param($o) $script:Ui.DiskOut.Text = ($o -join "`r`n") }
    $script:Ui.DiskRunVolume = {
        param($label, $work)
        if (-not (Require-FuAdmin $label)) { return }
        $letter = [string]$script:Ui.DiskVolume.SelectedItem
        Start-FuWork $label $work @(,$letter) $script:Ui.DiskShowOutput
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh disks' { & $script:Ui.DiskRefresh }))
    [void]$bar.Controls.Add($volBox)
    [void]$bar.Controls.Add((New-FuButton 'Scan volume for errors (read-only)' {
        & $script:Ui.DiskRunVolume 'Scanning volume' { param($l) Repair-Volume -DriveLetter $l -Scan 2>&1 | Out-String }
    }))
    [void]$bar.Controls.Add((New-FuButton 'Analyze fragmentation (read-only)' {
        & $script:Ui.DiskRunVolume 'Analyzing volume' { param($l) Optimize-Volume -DriveLetter $l -Analyze -Verbose 4>&1 | Out-String }
    }))
    [void]$bar.Controls.Add((New-FuButton 'Optimize' {
        $letter = [string]$script:Ui.DiskVolume.SelectedItem
        if (-not (Require-FuAdmin 'Optimizing a volume')) { return }
        if (-not (Confirm-FuAction "Optimize drive ${letter}:? This can take a long time. Do not turn off the PC during it.")) { return }
        Start-FuWork 'Optimizing' { param($l) Optimize-Volume -DriveLetter $l -Verbose 4>&1 | Out-String } @(,$letter) $script:Ui.DiskShowOutput
    }))
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($out)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ if ($script:Ui.DiskGrid.Rows.Count -eq 0) { & $script:Ui.DiskRefresh } })
}

function Add-LargeFilesTab($Tabs) {
    $page = New-FuTab $Tabs 'Large Files'
    $grid = New-FuGrid
    $script:Ui.LargeGrid = $grid
    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Text = $env:USERPROFILE
    $pathBox.Width = 420
    $script:Ui.LargePath = $pathBox
    $script:Ui.LargeShow = {
        param($o)
        Set-FuGrid $script:Ui.LargeGrid $o
        $script:StatusLabel.Text = 'Search complete. Nothing was deleted.'
    }
    $bar = New-FuBar
    [void]$bar.Controls.Add($pathBox)
    [void]$bar.Controls.Add((New-FuButton 'Browse...' {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $script:Ui.LargePath.Text = $dlg.SelectedPath }
    }))
    [void]$bar.Controls.Add((New-FuButton 'Find 200 largest files' {
        if (-not (Test-Path -LiteralPath $script:Ui.LargePath.Text)) { Show-FuInfo 'That folder does not exist.' 'Warning'; return }
        Start-FuWork 'Searching' { param($root) Get-LargeFiles $root 200 } @(,$script:Ui.LargePath.Text) $script:Ui.LargeShow
    }))
    [void]$page.Controls.Add($grid)
    [void]$page.Controls.Add($bar)
}

function Add-LogTab($Tabs) {
    $page = New-FuTab $Tabs 'Activity Log'
    $text = New-FuText
    $script:Ui.LogText = $text
    $script:Ui.LogRefresh = { $script:Ui.LogText.Text = Get-FuLogTail 300 }
    $bar = New-FuBar
    [void]$bar.Controls.Add((New-FuButton 'Refresh' { & $script:Ui.LogRefresh }))
    [void]$bar.Controls.Add((New-FuButton 'Open log folder' {
        $dir = Split-Path -Parent (Get-FuLogPath)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Start-Process explorer.exe $dir
    }))
    [void]$page.Controls.Add($text)
    [void]$page.Controls.Add($bar)
    $page.Add_Enter({ & $script:Ui.LogRefresh })
}
