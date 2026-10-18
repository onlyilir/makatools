# Makatools - core logic. No UI code in this file, so it can be unit-tested.
# Every function here either returns data or changes the system; the UI decides when to call them.

if (-not $script:AppRoot) { $script:AppRoot = Split-Path -Parent $PSScriptRoot }

# The version, and the GitHub repository ("owner/name") whose releases the update check reads.
# These are functions so background tasks get them too. An empty repository turns updates off.
function Get-FuVersion { '2.1.0' }
function Get-FuUpdateRepo { 'onlyilir/makatools' }

# ---------------------------------------------------------------- environment

function Test-FuAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Windows 10 and 11 both report major version 10 (11 is build 22000 and later)
function Test-FuSupportedOs {
    return ([Environment]::OSVersion.Version.Major -ge 10)
}

# ---------------------------------------------------------------- security software

# True when any of the given names, commands or paths belongs to antivirus software
# (Norton 360, Microsoft Defender and other common ones). Makatools never disables, stops or
# ends these. The pattern lives inside the function so background jobs get it too.
function Test-FuProtected([string[]]$Text) {
    $pattern = 'Norton|Symantec|NortonLifeLock|Gen Digital|Avast|\bAVG\b|Avira|McAfee|Kaspersky|Bitdefender|\bESET\b|Malwarebytes|Sophos|Trend Micro|Webroot|' +
               'Windows Defender|Microsoft Defender|SecurityHealth|WinDefend|MsMpEng|NisSrv|MpDefender|WdNisSvc|WdFilter|\bSense\b|wscsvc|Security Center'
    foreach ($t in $Text) { if ($t -and $t -match $pattern) { return $true } }
    return $false
}

function Assert-FuNotProtected([string]$What, [string[]]$Text) {
    if (Test-FuProtected $Text) {
        throw "'$What' belongs to your antivirus (for example Norton 360 or Microsoft Defender). Makatools does not change security software. Use the antivirus's own settings instead."
    }
}

# Antivirus products registered with Windows Security Center, and whether each is switched on
function Get-AntivirusStatus {
    try { $products = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop } catch { return }
    foreach ($a in $products) {
        # productState is a bit field; the middle byte is 0x10 or 0x11 when real-time protection is on
        $hex = '{0:X6}' -f [int]$a.productState
        [pscustomobject]@{ Name = $a.displayName; Enabled = ($hex.Substring(2, 2) -in '10', '11') }
    }
}

# ---------------------------------------------------------------- logging

function Get-FuLogPath { Join-Path $script:AppRoot 'Logs\freeutil.log' }

function Write-FuLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        $path = Get-FuLogPath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {
        # Logging must never break an action
    }
}

# Lets a background task report what it is doing (Percent -1 = unknown). The UI hands each task
# a shared $FuProgress table in its runspace; anywhere else this does nothing.
function Set-FuProgress([string]$Text, [int]$Percent = -1) {
    $p = Get-Variable -Name FuProgress -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($p) {
        $p.Text = $Text
        $p.Percent = $Percent
    }
}

function Get-FuLogTail([int]$Lines = 300) {
    $path = Get-FuLogPath
    if (-not (Test-Path -LiteralPath $path)) { return 'No log entries yet.' }
    return ((Get-Content -LiteralPath $path -Tail $Lines) -join "`r`n")
}

# ---------------------------------------------------------------- system summary

function Get-SystemSummary {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $up  = (Get-Date) - $os.LastBootUpTime

    $lines = @(
        "Computer  : $($cs.Name)",
        "Windows   : $($os.Caption) ($($os.Version))",
        "Processor : $($cpu.Name.Trim())",
        ('Memory    : {0:N1} GB' -f ($cs.TotalPhysicalMemory / 1GB)),
        ('Uptime    : {0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes)
    )
    $av = @(Get-AntivirusStatus | ForEach-Object { '{0} ({1})' -f $_.Name, $(if ($_.Enabled) { 'on' } else { 'off' }) })
    $lines += 'Antivirus : ' + $(if ($av.Count) { $av -join ', ' } else { 'none reported by Windows' })
    $lines += ''
    foreach ($v in Get-UsableVolumes) {
        $lines += ('{0}:  {1,8:N1} GB free of {2,8:N1} GB   {3,-6} health: {4}' -f `
            $v.DriveLetter, ($v.SizeRemaining / 1GB), ($v.Size / 1GB), $v.FileSystemType, $v.HealthStatus)
    }
    return ($lines -join "`r`n")
}

# Volumes that are mounted and have a size (skips empty card readers and unmounted drives)
function Get-UsableVolumes {
    Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 }
}

# ---------------------------------------------------------------- cleanup

# Cleanup ticks only caches, temp files, crash logs and update downloads: things Windows and
# programs rebuild on their own. Browser history and cookies are offered as privacy items that
# are never ticked for you. Saved passwords, bookmarks, autofill and the registry are never touched.

# One place a cleanup target deletes from: a folder, a file-name filter, and whether to include subfolders
function New-FuPart([string]$Path, [string]$Filter = '*', [bool]$Recurse = $true) {
    [pscustomobject]@{ Path = $Path; Filter = $Filter; Recurse = $Recurse }
}

# A target has either Parts (several places) or a single Path
function Get-FuTargetParts($Target) {
    if ($Target.Parts) { return @($Target.Parts) }
    return @(New-FuPart $Target.Path)
}

function Get-FuPartFiles($Part) {
    # Folders this account cannot read count as empty
    if (-not $Part.Path -or -not (Test-Path -LiteralPath $Part.Path -ErrorAction SilentlyContinue)) { return }
    $filter = $(if ($Part.Filter) { [string]$Part.Filter } else { '*' })
    $recurse = $(if ($null -ne $Part.Recurse) { [bool]$Part.Recurse } else { $true })
    # Never sweep a whole drive
    if ($filter -eq '*' -and ([string]$Part.Path).TrimEnd('\').Length -le 2) { return }
    Get-ChildItem -LiteralPath $Part.Path -Filter $filter -Recurse:$recurse -File -Force -ErrorAction SilentlyContinue
}

function Measure-FuFolder([string]$Path, [string]$Filter = '*', [bool]$Recurse = $true) {
    $files = 0
    [int64]$bytes = 0
    foreach ($f in Get-FuPartFiles (New-FuPart $Path $Filter $Recurse)) {
        $files++
        $bytes += $f.Length
    }
    [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

# Every installed browser with its profile folders. Chromium browsers (Edge, Chrome, Brave,
# Vivaldi, Opera) use "Default" and "Profile N"; Opera keeps its one profile in the root folder.
# Process is the program name, used to warn when the browser is still open.
function Get-BrowserProfiles {
    $la = $env:LOCALAPPDATA
    $chromium = @(
        @{ Browser = 'Microsoft Edge'; Process = 'msedge';  Root = "$la\Microsoft\Edge\User Data" },
        @{ Browser = 'Google Chrome';  Process = 'chrome';  Root = "$la\Google\Chrome\User Data" },
        @{ Browser = 'Brave';          Process = 'brave';   Root = "$la\BraveSoftware\Brave-Browser\User Data" },
        @{ Browser = 'Vivaldi';        Process = 'vivaldi'; Root = "$la\Vivaldi\User Data" },
        @{ Browser = 'Opera';          Process = 'opera';   Root = "$la\Opera Software\Opera Stable" },
        @{ Browser = 'Opera GX';       Process = 'opera';   Root = "$la\Opera Software\Opera GX Stable" }
    )
    foreach ($r in $chromium) {
        if (-not (Test-Path -LiteralPath $r.Root -ErrorAction SilentlyContinue)) { continue }
        $profiles = @(Get-Item -LiteralPath $r.Root) + @(Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' })
        [pscustomobject]@{ Browser = $r.Browser; Engine = 'Chromium'; Process = $r.Process; Profiles = @($profiles | ForEach-Object { $_.FullName }) }
    }
    $ff = "$la\Mozilla\Firefox\Profiles"
    $ffRoaming = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ff -ErrorAction SilentlyContinue) {
        # Firefox keeps its cache under Local and its cookies under Roaming, in folders of the same name
        $local = @(Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $roaming = @(Get-ChildItem -LiteralPath $ffRoaming -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        [pscustomobject]@{ Browser = 'Firefox'; Engine = 'Firefox'; Process = 'firefox'; Profiles = $local; RoamingProfiles = $roaming }
    }
}

# Parts to clean for one browser. What: 'Cache' (safe), 'History' or 'Cookies' (privacy).
# Firefox history is left out: it shares places.sqlite with the bookmarks.
function Get-BrowserParts($Browser, [ValidateSet('Cache', 'History', 'Cookies')][string]$What) {
    if ($Browser.Engine -eq 'Chromium') {
        $names = switch ($What) {
            'Cache'   { 'Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache', 'DawnCache' }
            'History' { 'History', 'History-journal', 'Visited Links', 'Top Sites', 'Top Sites-journal', 'Shortcuts', 'Shortcuts-journal' }
            'Cookies' { 'Cookies', 'Cookies-journal', 'Network\Cookies', 'Network\Cookies-journal' }
        }
        $dirs = $Browser.Profiles
    } else {
        $names = switch ($What) {
            'Cache'   { 'cache2', 'thumbnails', 'startupCache' }
            'History' { @() }
            'Cookies' { 'cookies.sqlite', 'cookies.sqlite-wal', 'cookies.sqlite-shm' }
        }
        $dirs = $(if ($What -eq 'Cookies') { $Browser.RoamingProfiles } else { $Browser.Profiles })
    }
    foreach ($d in @($dirs)) {
        foreach ($n in $names) {
            $path = Join-Path $d $n
            if ($What -eq 'Cache') {
                if (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue) { New-FuPart $path }
            } elseif (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
                # One exact file: its folder, its name as the filter, no subfolders
                New-FuPart (Split-Path -Parent $path) (Split-Path -Leaf $path) $false
            }
        }
    }
}

# Kind 'Files' deletes the files in Parts; 'RecycleBin' empties the Recycle Bin on the drives in
# Parts; 'WindowsOld' removes the previous Windows installation through Disk Cleanup.
# Recommended targets are ticked after a scan; the rest the user ticks by hand. Process names the
# program that keeps these files in use, so the UI can ask the user to close it first.
function New-CleanupRow($Id, $Target, $Parts, [bool]$NeedsAdmin, [bool]$Recommended = $true, [string]$Kind = 'Files', [string[]]$Process = @(), [bool]$Privacy = $false) {
    Set-FuProgress "Scanning $Target"
    $files = 0
    [int64]$bytes = 0
    foreach ($p in @($Parts)) {
        $m = Measure-FuFolder $p.Path $p.Filter $p.Recurse
        $files += $m.Files
        $bytes += $m.Bytes
    }
    [pscustomobject]@{
        Id          = $Id
        Target      = $Target
        Parts       = @($Parts)
        Files       = $files
        MB          = [math]::Round($bytes / 1MB, 1)
        Bytes       = $bytes
        NeedsAdmin  = $NeedsAdmin
        Recommended = $Recommended
        Kind        = $Kind
        Process     = @($Process)
        Privacy     = $Privacy
    }
}

# The programs among the given rows' Process names that are running right now
function Get-FuOpenPrograms($Rows) {
    $names = @($Rows | ForEach-Object { $_.Process } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $names) { return @() }
    @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
}

# Removes C:\Windows.old with Windows' own Disk Cleanup ("Previous Windows installation(s)"), the
# only supported way: the folder is owned by TrustedInstaller. Needs admin. Uses a private
# sagerun slot (6137) so no other Disk Cleanup options run, and clears it afterwards.
function Remove-WindowsOld {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations'
    if (-not (Test-Path -LiteralPath $key)) { throw "Disk Cleanup's 'Previous Windows installation(s)' option is not available on this PC." }
    Set-ItemProperty -LiteralPath $key -Name 'StateFlags6137' -Value 2 -Type DWord -ErrorAction Stop
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cleanmgr.exe') -ArgumentList '/sagerun:6137' -Wait -WindowStyle Hidden
    } finally {
        Remove-ItemProperty -LiteralPath $key -Name 'StateFlags6137' -ErrorAction SilentlyContinue
    }
    Write-FuLog "Windows.old: Disk Cleanup finished; folder still present: $(Test-Path -LiteralPath "$env:SystemDrive\Windows.old")"
}

# Every cleanup location, in the order shown. Locations with nothing in them are left out.
function Get-CleanupTargets {
    $la = $env:LOCALAPPDATA
    $ra = $env:APPDATA
    $sr = $env:SystemRoot
    $pd = $env:ProgramData

    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add((New-CleanupRow 'usertemp' 'Temporary files (your account)' @(New-FuPart $env:TEMP) $false))
    [void]$rows.Add((New-CleanupRow 'wintemp' 'Temporary files (Windows)' @(New-FuPart "$sr\Temp") $true))
    [void]$rows.Add((New-CleanupRow 'thumbs' 'Thumbnail cache (rebuilt automatically)' @(New-FuPart "$la\Microsoft\Windows\Explorer" 'thumbcache_*.db' $false) $false))
    [void]$rows.Add((New-CleanupRow 'inetcache' 'Internet cache (Windows apps, old Edge)' @(New-FuPart "$la\Microsoft\Windows\INetCache") $false))
    [void]$rows.Add((New-CleanupRow 'wer' 'Error reports (your account)' @(New-FuPart "$la\Microsoft\Windows\WER") $false))
    [void]$rows.Add((New-CleanupRow 'wersys' 'Error reports (Windows)' @(New-FuPart "$pd\Microsoft\Windows\WER") $true))
    [void]$rows.Add((New-CleanupRow 'dumps' 'Crash dumps (programs)' @(New-FuPart "$la\CrashDumps") $false))
    [void]$rows.Add((New-CleanupRow 'dumpssys' 'Crash dumps (Windows)' @((New-FuPart "$sr\Minidump"), (New-FuPart $sr 'MEMORY.DMP' $false), (New-FuPart "$sr\LiveKernelReports" '*.dmp')) $true))
    [void]$rows.Add((New-CleanupRow 'shaders' 'Graphics shader cache (DirectX, NVIDIA, AMD, Intel)' @(
        (New-FuPart "$la\D3DSCache"), (New-FuPart "$la\NVIDIA\DXCache"), (New-FuPart "$la\NVIDIA\GLCache"),
        (New-FuPart "$la\AMD\DxCache"), (New-FuPart "$la\AMD\DxcCache"), (New-FuPart "$la\AMD\GLCache"), (New-FuPart "$la\Intel\ShaderCache")) $false))
    [void]$rows.Add((New-CleanupRow 'wudl' 'Windows Update downloads (already installed)' @(New-FuPart "$sr\SoftwareDistribution\Download") $true))
    [void]$rows.Add((New-CleanupRow 'delivery' 'Delivery Optimization cache' @(New-FuPart "$sr\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") $true))
    [void]$rows.Add((New-CleanupRow 'setuplogs' 'Windows setup and update logs' @((New-FuPart "$sr\Logs\CBS" '*.cab'), (New-FuPart "$sr\Logs\CBS" 'CbsPersist_*.log'), (New-FuPart "$sr\Logs\DISM" '*.log'), (New-FuPart "$sr\Panther" '*.log' $false)) $true))

    $browsers = @(Get-BrowserProfiles)
    foreach ($b in $browsers) {
        $id = 'browser-' + ($b.Browser -replace '\s', '')
        [void]$rows.Add((New-CleanupRow $id "$($b.Browser) cache" @(Get-BrowserParts $b 'Cache') $false $true 'Files' @($b.Process)))
    }

    $apps = @(
        @{ Id = 'discord'; Name = 'Discord cache';         Process = 'Discord';           Paths = "$ra\discord\Cache", "$ra\discord\Code Cache", "$ra\discord\GPUCache" },
        @{ Id = 'teams';   Name = 'Microsoft Teams cache'; Process = 'Teams', 'ms-teams'; Paths = "$ra\Microsoft\Teams\Cache", "$ra\Microsoft\Teams\Code Cache", "$ra\Microsoft\Teams\GPUCache",
                                                                                          "$la\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache" },
        @{ Id = 'spotify'; Name = 'Spotify cache';         Process = 'Spotify';           Paths = "$la\Spotify\Data", "$la\Packages\SpotifyAB.SpotifyMusic_zpdnekdrzrea0\LocalCache\Spotify\Data" },
        @{ Id = 'steam';   Name = 'Steam web cache';       Process = 'steamwebhelper';    Paths = "$la\Steam\htmlcache" },
        @{ Id = 'zoom';    Name = 'Zoom logs';             Process = 'Zoom';              Paths = "$ra\Zoom\logs" }
    )
    foreach ($a in $apps) {
        $parts = foreach ($p in $a.Paths) { New-FuPart $p }
        [void]$rows.Add((New-CleanupRow $a.Id $a.Name $parts $false $true 'Files' @($a.Process)))
    }

    # Removing the previous Windows takes away the option to go back to it, so it is never ticked for you.
    # The folder is partly unreadable without admin, so its size is a lower bound until elevated.
    $old = Join-Path $env:SystemDrive 'Windows.old'
    if (Test-Path -LiteralPath $old -ErrorAction SilentlyContinue) {
        [void]$rows.Add((New-CleanupRow 'windowsold' 'Previous Windows installation, Windows.old (removes the option to go back)' @(New-FuPart $old) $true $false 'WindowsOld'))
    }

    # Emptying the Recycle Bin cannot be undone, so it is never ticked for you
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $binParts = foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        New-FuPart (Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid))
    }
    [void]$rows.Add((New-CleanupRow 'recyclebin' 'Recycle Bin (empty it - cannot be undone)' $binParts $false $false 'RecycleBin'))

    # Privacy: never ticked for you. History and cookies are not junk; clearing cookies logs you out of websites.
    foreach ($b in $browsers) {
        $id = 'privacy-' + ($b.Browser -replace '\s', '')
        $history = @(Get-BrowserParts $b 'History')
        if ($history) { [void]$rows.Add((New-CleanupRow "$id-history" "$($b.Browser) browsing history (privacy)" $history $false $false 'Files' @($b.Process) $true)) }
        $cookies = @(Get-BrowserParts $b 'Cookies')
        if ($cookies) { [void]$rows.Add((New-CleanupRow "$id-cookies" "$($b.Browser) cookies (privacy - logs you out of websites)" $cookies $false $false 'Files' @($b.Process) $true)) }
    }
    [void]$rows.Add((New-CleanupRow 'privacy-recent' 'Recently opened files list (privacy)' @(New-FuPart "$ra\Microsoft\Windows\Recent" '*.lnk' $false) $false $false 'Files' @() $true))

    foreach ($r in $rows) { if ($r.Files -gt 0) { $r } }
}

# What one-click cleanup takes: recommended items only (never privacy items, the
# Recycle Bin or Windows.old), only those the current rights allow, and none that belong to a
# program that is open right now (its files would be in use anyway).
function Select-AutoCleanTargets($Rows, [bool]$IsAdmin = (Test-FuAdmin), [string[]]$OpenPrograms = $null) {
    if ($null -eq $OpenPrograms) { $OpenPrograms = Get-FuOpenPrograms $Rows }
    foreach ($r in @($Rows)) {
        if (-not $r.Recommended -or $r.Privacy -or $r.Kind -ne 'Files') { continue }
        if ($r.NeedsAdmin -and -not $IsAdmin) { continue }
        if (@($r.Process | Where-Object { $_ -and $_ -in $OpenPrograms }).Count) { continue }
        $r
    }
}

# Scans, then cleans the recommended items. Used by the Dashboard's Optimize button and the
# weekly reminder. Returns what was freed and which items were left for open programs.
function Invoke-AutoClean([string]$Reason = 'One-click') {
    $rows = @(Get-CleanupTargets)
    $open = @(Get-FuOpenPrograms $rows)
    $chosen = @(Select-AutoCleanTargets $rows (Test-FuAdmin) $open)
    $waiting = @($rows | Where-Object { $_.Recommended -and @($_.Process | Where-Object { $_ -and $_ -in $open }).Count } | ForEach-Object { $_.Target })
    $r = Invoke-Cleanup $chosen
    Write-FuLog ('{0} cleanup: {1} items, freed {2} MB; left for open programs: {3}' -f $Reason, $chosen.Count, $r.FreedMB, $(if ($waiting) { $waiting -join ', ' } else { 'none' }))
    [pscustomobject]@{ FreedMB = $r.FreedMB; Deleted = $r.Deleted; Skipped = $r.Skipped; Items = $chosen.Count; LeftForOpenPrograms = $waiting }
}

# ---------------------------------------------------------------- settings and the weekly reminder

# Weekly cleanup is a reminder shown when Makatools opens, not a background task: Norton 360
# blocks scheduled tasks that run hidden PowerShell scripts as suspected malware (it flagged a
# test of exactly that as IDP.HELU.PSD11), and could then quarantine Makatools itself.

function Get-FuSettingsPath { Join-Path $script:AppRoot 'Makatools-settings.json' }

# Settings with their defaults filled in. Dates are stored as round-trip strings.
function Get-FuSettings {
    $s = @{ WeeklyReminder = $true; LastCleanup = $null; LastReminder = $null; FirstRun = $null }
    $path = Get-FuSettingsPath
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) { $s[$p.Name] = $p.Value }
        } catch {
            # A damaged settings file falls back to the defaults
        }
    }
    return $s
}

function Set-FuSetting([string]$Name, $Value) {
    $s = Get-FuSettings
    if ($Value -is [datetime]) { $Value = $Value.ToString('o') }
    $s[$Name] = $Value
    try { Set-Content -LiteralPath (Get-FuSettingsPath) -Value ($s | ConvertTo-Json) -Encoding UTF8 } catch { }
}

function ConvertTo-FuDate($Value) {
    if (-not $Value) { return $null }
    try { return [datetime]::Parse([string]$Value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

# $true when it is time to offer a cleanup: the reminder is on, the last cleanup (or, before the
# first one, the first start) was 7+ days ago, and the user was not already asked this week.
function Test-FuCleanupDue([datetime]$Now = (Get-Date)) {
    $s = Get-FuSettings
    if (-not $s.WeeklyReminder) { return $false }
    $since = ConvertTo-FuDate $s.LastCleanup
    if (-not $since) { $since = ConvertTo-FuDate $s.FirstRun }
    if (-not $since) { Set-FuSetting 'FirstRun' $Now; return $false }
    $asked = ConvertTo-FuDate $s.LastReminder
    if ($asked -and ($Now - $asked).TotalDays -lt 7) { return $false }
    return (($Now - $since).TotalDays -ge 7)
}

function Get-FuDaysSinceCleanup([datetime]$Now = (Get-Date)) {
    $since = ConvertTo-FuDate (Get-FuSettings).LastCleanup
    if (-not $since) { return $null }
    return [int][math]::Floor(($Now - $since).TotalDays)
}

# Removes superseded Windows component versions (the same thing as Disk Cleanup's
# "Windows Update Cleanup"). Needs admin and can take 10+ minutes.
# -AnalyzeOnly runs DISM's read-only report instead (used by the admin tests).
function Invoke-ComponentCleanup([switch]$AnalyzeOnly) {
    Set-FuProgress 'Running DISM (this can take a while)'
    $op = $(if ($AnalyzeOnly) { '/AnalyzeComponentStore' } else { '/StartComponentCleanup' })
    $out = & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image $op 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-FuLog "Component cleanup $op finished (exit code $code)"
    return ("Exit code {0}`r`n{1}" -f $code, $out.Trim())
}

# Deletes files only (never folders). Files in use are skipped and counted.
function Invoke-Cleanup($Targets) {
    [int64]$freed = 0
    $deleted = 0
    $skipped = 0
    $all = @($Targets)
    for ($i = 0; $i -lt $all.Count; $i++) {
        $t = $all[$i]
        Set-FuProgress "Cleaning $($t.Target)" ([int](100 * $i / $all.Count))
        $parts = Get-FuTargetParts $t
        if ($t.Kind -eq 'RecycleBin' -or $t.Kind -eq 'WindowsOld') {
            # Only the drives in Parts are emptied
            foreach ($p in $parts) {
                $m = Measure-FuFolder $p.Path
                try {
                    if ($t.Kind -eq 'RecycleBin') { Clear-RecycleBin -DriveLetter ([string]$p.Path).Substring(0, 1) -Force -ErrorAction Stop }
                    else { Remove-WindowsOld }
                    $after = Measure-FuFolder $p.Path
                    $deleted += ($m.Files - $after.Files)
                    $freed += ($m.Bytes - $after.Bytes)
                    $skipped += $after.Files
                } catch {
                    $skipped += $m.Files
                }
            }
            continue
        }
        foreach ($p in $parts) {
            foreach ($f in Get-FuPartFiles $p) {
                $len = $f.Length
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $freed += $len
                    $deleted++
                } catch {
                    $skipped++
                }
            }
        }
    }
    $result = [pscustomobject]@{ FreedMB = [math]::Round($freed / 1MB, 2); Deleted = $deleted; Skipped = $skipped }
    Write-FuLog ('Cleanup: deleted {0} files, freed {1} MB, skipped {2}' -f $deleted, $result.FreedMB, $skipped)
    Set-FuSetting 'LastCleanup' (Get-Date)
    return $result
}

# ---------------------------------------------------------------- startup

# Startup programs are switched on and off the way Task Manager does it: the program's own entry
# is left in place and a flag under Explorer\StartupApproved says whether Windows starts it.
# Task Manager shows the same on/off state, and either tool can switch it back.
# Flag value: 12 bytes; the first byte is even (02, 06) for on, odd (03) for off, and bytes
# 4-11 hold the time it was switched off.

function Get-StartupLocations {
    $approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    @(
        @{ Source = 'Registry';       Scope = 'Current user';       Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKCU:\$approved\Run" },
        @{ Source = 'Registry';       Scope = 'All users';          Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$approved\Run" },
        @{ Source = 'Registry';       Scope = 'All users (32-bit)'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approved\Run32" },
        @{ Source = 'Startup folder'; Scope = 'Current user';       Path = [Environment]::GetFolderPath('Startup');                           Approved = "HKCU:\$approved\StartupFolder" },
        @{ Source = 'Startup folder'; Scope = 'All users';          Path = [Environment]::GetFolderPath('CommonStartup');                     Approved = "HKLM:\$approved\StartupFolder" }
    )
}

# $true unless the StartupApproved flag says off
function Test-StartupApproved([string]$ApprovedKey, [string]$Name) {
    $item = Get-Item -LiteralPath $ApprovedKey -ErrorAction SilentlyContinue
    if (-not $item) { return $true }
    $bytes = $item.GetValue($Name)
    if (-not ($bytes -is [byte[]]) -or $bytes.Length -lt 1) { return $true }
    return (($bytes[0] -band 1) -eq 0)
}

# Lists Run-key programs, Startup-folder shortcuts and scheduled tasks that run at sign-in or
# boot (Microsoft's own tasks are left out). -Locations and -NoTasks exist for tests.
function Get-StartupEntries {
    param([object[]]$Locations = (Get-StartupLocations), [switch]$NoTasks)
    $skip = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider', '(default)')
    foreach ($loc in $Locations) {
        if (-not $loc.Path -or -not (Test-Path -LiteralPath $loc.Path -ErrorAction SilentlyContinue)) { continue }
        if ($loc.Source -eq 'Registry') {
            $item = Get-Item -LiteralPath $loc.Path
            $items = foreach ($n in $item.GetValueNames()) {
                if (-not $n -or $n -in $skip) { continue }
                @{ Name = $n; Command = [string]$item.GetValue($n) }
            }
        } else {
            $items = foreach ($f in Get-ChildItem -LiteralPath $loc.Path -File -Force -ErrorAction SilentlyContinue) {
                if ($f.Name -eq 'desktop.ini') { continue }
                @{ Name = $f.Name; Command = $f.FullName }
            }
        }
        foreach ($i in $items) {
            [pscustomobject]@{
                Name        = $i.Name
                Status      = $(if (Test-StartupApproved $loc.Approved $i.Name) { 'On' } else { 'Off' })
                Source      = $loc.Source
                Scope       = $loc.Scope
                Command     = $i.Command
                Location    = $loc.Path
                ApprovedKey = $loc.Approved
                TaskPath    = $null
            }
        }
    }
    if ($NoTasks) { return }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1]
    foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }
        if (-not ($t.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' })) { continue }
        $cmd = (@($t.Actions) | ForEach-Object { ('{0} {1}' -f $_.Execute, $_.Arguments).Trim() }) -join ' ; '
        [pscustomobject]@{
            Name        = $t.TaskName
            Status      = $(if ([string]$t.State -eq 'Disabled') { 'Off' } else { 'On' })
            Source      = 'Scheduled task'
            Scope       = $(if ($t.Principal.UserId -and $t.Principal.UserId.Split('\')[-1] -eq $me) { 'Current user' } else { 'All users' })
            Command     = $cmd
            Location    = $t.TaskPath
            ApprovedKey = $null
            TaskPath    = $t.TaskPath
        }
    }
}

# Switches a startup entry on or off. Antivirus entries can be switched on but never off.
function Set-StartupEntryState($Entry, [bool]$Enabled) {
    if (-not $Enabled) { Assert-FuNotProtected $Entry.Name @($Entry.Name, $Entry.Command) }
    $word = $(if ($Enabled) { 'on' } else { 'off' })
    if ($Entry.Source -eq 'Scheduled task') {
        if ($Enabled) { Enable-ScheduledTask -TaskPath $Entry.TaskPath -TaskName $Entry.Name -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskPath $Entry.TaskPath -TaskName $Entry.Name -ErrorAction Stop | Out-Null }
    } else {
        if (-not (Test-Path -LiteralPath $Entry.ApprovedKey)) { New-Item -Path $Entry.ApprovedKey -Force -ErrorAction Stop | Out-Null }
        if ($Enabled) {
            $flag = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        } else {
            $flag = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))
        }
        Set-ItemProperty -LiteralPath $Entry.ApprovedKey -Name $Entry.Name -Value $flag -Type Binary -ErrorAction Stop
    }
    Write-FuLog "Startup: switched $word '$($Entry.Name)' ($($Entry.Source), $($Entry.Scope))"
}

# ---------------------------------------------------------------- disk health

function Get-DiskHealth {
    $isAdmin = Test-FuAdmin
    foreach ($d in Get-PhysicalDisk) {
        # Reliability counters need Administrator rights on many systems
        $rel = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $needsAdmin = -not $isAdmin -and -not $rel
        [pscustomobject]@{
            Disk     = $d.FriendlyName
            Type     = $d.MediaType
            SizeGB   = [math]::Round($d.Size / 1GB, 1)
            Health   = $d.HealthStatus
            Status   = ($d.OperationalStatus -join ', ')
            TempC    = $(if ($rel) { $rel.Temperature } elseif ($needsAdmin) { 'needs admin' } else { 'n/a' })
            WearPct  = $(if ($rel) { $rel.Wear } elseif ($needsAdmin) { 'needs admin' } else { 'n/a' })
            ReadErrs = $(if ($rel) { $rel.ReadErrorsTotal } elseif ($needsAdmin) { 'needs admin' } else { 'n/a' })
        }
    }
}

# ---------------------------------------------------------------- large files

function Get-LargeFiles([string]$Root, [int]$Top = 200) {
    Set-FuProgress "Listing every file in $Root"
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object -Property Length -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [pscustomobject]@{
                MB     = [math]::Round($_.Length / 1MB, 1)
                Name   = $_.Name
                Folder = $_.DirectoryName
                Path   = $_.FullName
            }
        }
}

# ---------------------------------------------------------------- duplicates

# Groups files by size first (cheap), then by SHA-256 hash only for same-size files.
function Find-DuplicateFiles([string]$Root, [int64]$MinBytes = 1MB) {
    Set-FuProgress "Listing files in $Root"
    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge $MinBytes } |
        Group-Object -Property Length |
        Where-Object { $_.Count -gt 1 })

    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $sizeGroup = $candidates[$i]
        Set-FuProgress ('Comparing files with the same size ({0} of {1})' -f ($i + 1), $candidates.Count) ([int](100 * $i / $candidates.Count))
        $hashed = foreach ($f in $sizeGroup.Group) {
            $h = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
            if ($h) { [pscustomobject]@{ Path = $f.FullName; Hash = $h.Hash; Bytes = $f.Length } }
        }
        foreach ($hashGroup in ($hashed | Group-Object -Property Hash | Where-Object { $_.Count -gt 1 })) {
            $sorted = $hashGroup.Group | Sort-Object -Property Path
            [pscustomobject]@{
                Hash  = $hashGroup.Name
                SizeMB = [math]::Round($sorted[0].Bytes / 1MB, 2)
                Keep  = $sorted[0].Path
                Copies = @($sorted | Select-Object -Skip 1 | ForEach-Object { $_.Path })
            }
        }
    }
}

# ---------------------------------------------------------------- file deletion

# Moves a file to the Recycle Bin. Recoverable.
function Send-ToRecycleBin([string]$Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path -LiteralPath $Path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    Write-FuLog "Moved to Recycle Bin: $Path"
}

# Overwrites the file's contents with random bytes before deleting it. Not a guarantee on SSDs
# (wear levelling can keep old copies) or on file systems with journaling, so the UI says so.
function Remove-FileSecurely([string]$Path, [int]$Passes = 1) {
    if ($Passes -lt 1 -or $Passes -gt 7) { throw 'Passes must be between 1 and 7.' }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { throw 'Secure delete works on single files, not folders.' }
    $len = $item.Length
    $buffer = New-Object byte[] 65536
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($pass = 0; $pass -lt $Passes; $pass++) {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $remaining = $len
                while ($remaining -gt 0) {
                    $n = [int][math]::Min($buffer.Length, $remaining)
                    $rng.GetBytes($buffer)
                    $fs.Write($buffer, 0, $n)
                    $remaining -= $n
                }
                $fs.Flush($true)
            } finally {
                $fs.Close()
            }
        }
    } finally {
        $rng.Dispose()
    }
    # Rename before delete so the old name is gone from the folder listing
    $dir = Split-Path -Parent $Path
    $newName = [guid]::NewGuid().ToString('N')
    Rename-Item -LiteralPath $Path -NewName $newName
    Remove-Item -LiteralPath (Join-Path $dir $newName) -Force
    Write-FuLog "Secure delete: overwrote and removed $Path ($Passes pass(es))"
}

# ---------------------------------------------------------------- recycle bin recovery

# Reads a $I metadata file from the Recycle Bin (format used by Windows 10 and 11).
function Read-RecycleInfoFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $version = [BitConverter]::ToInt64($bytes, 0)
    $size    = [BitConverter]::ToInt64($bytes, 8)
    $time    = [BitConverter]::ToInt64($bytes, 16)
    if ($version -eq 2) {
        $chars = [BitConverter]::ToInt32($bytes, 24)
        $orig = [System.Text.Encoding]::Unicode.GetString($bytes, 28, $chars * 2)
    } else {
        $orig = [System.Text.Encoding]::Unicode.GetString($bytes, 24, 520)
    }
    [pscustomobject]@{
        OriginalPath = $orig.TrimEnd([char]0)
        Size         = $size
        Deleted      = [DateTime]::FromFileTime($time)
    }
}

# Lists items in the current user's Recycle Bin on every fixed drive.
function Get-RecycleBinEntries {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $dir = Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($info in Get-ChildItem -LiteralPath $dir -Filter '$I*' -File -Force -ErrorAction SilentlyContinue) {
            try {
                $meta = Read-RecycleInfoFile $info.FullName
                [pscustomobject]@{
                    Name         = Split-Path -Leaf $meta.OriginalPath
                    OriginalPath = $meta.OriginalPath
                    KB           = [math]::Round($meta.Size / 1KB, 1)
                    Deleted      = $meta.Deleted
                    InfoPath     = $info.FullName
                }
            } catch { }
        }
    }
}

# Puts a Recycle Bin item back where it came from. If the original name is taken,
# it is restored next to it as "name (restored).ext".
function Restore-RecycleBinEntry([string]$InfoPath) {
    $meta = Read-RecycleInfoFile $InfoPath
    $leaf = Split-Path -Leaf $InfoPath
    $dataPath = Join-Path (Split-Path -Parent $InfoPath) ('$R' + $leaf.Substring(2))
    if (-not (Test-Path -LiteralPath $dataPath)) { throw "The data for '$($meta.OriginalPath)' is missing from the Recycle Bin." }

    $dest = $meta.OriginalPath
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $dest) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($dest)
        $ext  = [System.IO.Path]::GetExtension($dest)
        $dest = Join-Path $parent ("$base (restored)$ext")
    }
    Move-Item -LiteralPath $dataPath -Destination $dest
    Remove-Item -LiteralPath $InfoPath -Force
    Write-FuLog "Restored from Recycle Bin: $dest"
    return $dest
}

# ---------------------------------------------------------------- processes and services

function Get-ProcessList {
    Get-Process | Sort-Object -Property WorkingSet64 -Descending | ForEach-Object {
        $exe = $null
        try { $exe = $_.Path } catch { }
        [pscustomobject]@{
            Id       = $_.Id
            Name     = $_.ProcessName
            MemoryMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
            Threads  = $_.Threads.Count
            Path     = $exe
        }
    }
}

function Stop-FuProcess([int]$Id) {
    $p = Get-Process -Id $Id -ErrorAction Stop
    $name = $p.ProcessName
    $exe = $null
    try { $exe = $p.Path } catch { }
    Assert-FuNotProtected $name @($name, $exe)
    Stop-Process -Id $Id -Force -ErrorAction Stop
    Write-FuLog "Stopped process $name (PID $Id)"
}

function Get-ServiceList {
    Get-Service | Sort-Object -Property DisplayName | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            Status      = [string]$_.Status
            StartType   = [string]$_.StartType
        }
    }
}

function Set-FuServiceState([string]$Name, [ValidateSet('Start', 'Stop')][string]$Action) {
    $svc = Get-Service -Name $Name -ErrorAction Stop
    Assert-FuNotProtected $svc.DisplayName @($svc.Name, $svc.DisplayName)
    if ($Action -eq 'Start') { Start-Service -Name $Name -ErrorAction Stop }
    else { Stop-Service -Name $Name -Force -ErrorAction Stop }
    Write-FuLog "Service $Action`: $Name"
}

# ---------------------------------------------------------------- installed programs

function Get-InstalledPrograms {
    $keys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.UninstallString } |
        Sort-Object -Property DisplayName |
        ForEach-Object {
            [pscustomobject]@{
                Name      = $_.DisplayName
                Publisher = $_.Publisher
                Version   = $_.DisplayVersion
                Uninstall = $_.UninstallString
            }
        }
}

# ---------------------------------------------------------------- updates

# Looks for a newer release of Makatools on GitHub. Returns $null when there is none, when updates
# are not set up, or when the release has no Setup.exe with a published SHA-256. -Release lets
# tests pass a release object instead of asking GitHub.
function Find-FuUpdate([string]$Repo = (Get-FuUpdateRepo), $Release = $null) {
    if (-not $Release) {
        if (-not $Repo) { return $null }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'Makatools' } -TimeoutSec 15 -ErrorAction Stop
    }
    $tag = ([string]$Release.tag_name) -replace '^[vV]', ''
    $newer = $null
    if (-not [version]::TryParse($tag, [ref]$newer) -or $newer -le [version](Get-FuVersion)) { return $null }
    $asset = @($Release.assets | Where-Object { $_.name -eq 'Makatools-Setup.exe' }) | Select-Object -First 1
    if (-not $asset -or -not ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$')) { return $null }
    [pscustomobject]@{
        Version = $tag
        Url     = [string]$asset.browser_download_url
        Sha256  = $Matches[1].ToUpper()
        Notes   = [string]$Release.body
        Page    = [string]$Release.html_url
    }
}

# Downloads the update's Setup.exe and checks it against the SHA-256 GitHub published for it.
# A file that does not match is deleted and never run. Returns the path of the checked file.
function Save-FuUpdate($Update, [string]$Folder = [System.IO.Path]::GetTempPath()) {
    $path = Join-Path $Folder ('Makatools-Setup-{0}.exe' -f $Update.Version)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $web = New-Object System.Net.WebClient
    $web.Headers.Add('User-Agent', 'Makatools')
    try { $web.DownloadFile($Update.Url, $path) } finally { $web.Dispose() }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $Update.Sha256) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw "The downloaded update did not match its published checksum, so it was deleted and not run."
    }
    Write-FuLog "Update $($Update.Version) downloaded and verified: $path"
    return $path
}

# ----------------------------------------------------------------
