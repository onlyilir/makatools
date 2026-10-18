# Makatools tests. Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
# Works in a temp folder and a throwaway HKCU key; does not touch real user files.
# Exits 1 if any test fails.
# -ResultFile also writes everything to a file (for elevated runs, whose window closes).
param([switch]$SkipUi, [string]$ResultFile)
if ($ResultFile) { Start-Transcript -LiteralPath $ResultFile -Force | Out-Null }

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('makatools-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:AppRoot = $tmp
. (Join-Path $repo 'src\Core.ps1')

$script:Passed = 0
$script:Failed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        Write-Host "FAIL  $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-TestFile([string]$Path, [int]$Bytes, [int]$Seed = 1) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $data = New-Object byte[] $Bytes
    (New-Object System.Random $Seed).NextBytes($data)
    [System.IO.File]::WriteAllBytes($Path, $data)
}
# Builds a Windows 10/11 ($I v2) Recycle Bin metadata file
function New-RecycleInfoBytes([string]$OriginalPath, [int64]$Size, [datetime]$When) {
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([int64]2); $w.Write([int64]$Size); $w.Write([int64]$When.ToFileTime())
    $w.Write([int32]($OriginalPath.Length + 1))
    $w.Write([System.Text.Encoding]::Unicode.GetBytes($OriginalPath + [char]0))
    $w.Flush()
    return $ms.ToArray()
}

# ---------------------------------------------------------------- core

Test-Case 'Test-FuAdmin returns a bool' { Assert ((Test-FuAdmin) -is [bool]) 'not a bool' }

Test-Case 'Test-FuSupportedOs is true on this machine' { Assert (Test-FuSupportedOs) 'reported unsupported' }

Test-Case 'Write-FuLog writes to the temp log' {
    Write-FuLog 'hello from tests'
    $log = Join-Path $tmp 'Logs\freeutil.log'
    Assert (Test-Path -LiteralPath $log) 'log file missing'
    Assert ((Get-Content -LiteralPath $log -Raw) -match 'hello from tests') 'message not in log'
}

Test-Case 'Measure-FuFolder counts files and bytes' {
    $d = Join-Path $tmp 'measure'
    New-TestFile (Join-Path $d 'a.bin') 10
    New-TestFile (Join-Path $d 'sub\b.bin') 20
    $m = Measure-FuFolder $d
    Assert ($m.Files -eq 2) "files = $($m.Files)"
    Assert ($m.Bytes -eq 30) "bytes = $($m.Bytes)"
    Assert ((Measure-FuFolder (Join-Path $tmp 'nope')).Files -eq 0) 'missing folder not zero'
}

Test-Case 'Invoke-Cleanup deletes files and keeps folders' {
    $d = Join-Path $tmp 'clean'
    New-TestFile (Join-Path $d 'a.tmp') 100
    New-TestFile (Join-Path $d 'sub\b.tmp') 100
    $r = Invoke-Cleanup @([pscustomobject]@{ Path = $d })
    Assert ($r.Deleted -eq 2) "deleted = $($r.Deleted)"
    Assert ($r.Skipped -eq 0) "skipped = $($r.Skipped)"
    Assert (Test-Path -LiteralPath (Join-Path $d 'sub')) 'subfolder was removed'
    Assert (@(Get-ChildItem -LiteralPath $d -Recurse -File).Count -eq 0) 'files remain'
}

Test-Case 'Invoke-Cleanup with Parts only deletes files matching the filter' {
    $d = Join-Path $tmp 'parts'
    New-TestFile (Join-Path $d 'thumbcache_32.db') 100
    New-TestFile (Join-Path $d 'keep.db') 100
    New-TestFile (Join-Path $d 'sub\thumbcache_64.db') 100
    $r = Invoke-Cleanup @([pscustomobject]@{ Parts = @(New-FuPart $d 'thumbcache_*.db' $false) })
    Assert ($r.Deleted -eq 1) "deleted = $($r.Deleted)"
    Assert (Test-Path -LiteralPath (Join-Path $d 'keep.db')) 'non-matching file deleted'
    Assert (Test-Path -LiteralPath (Join-Path $d 'sub\thumbcache_64.db')) 'went into subfolder despite Recurse=false'
}

Test-Case 'Cleanup never sweeps a whole drive' {
    Assert (@(Get-FuPartFiles (New-FuPart 'C:\')).Count -eq 0) 'C:\ returned files'
    Assert (@(Get-FuPartFiles (New-FuPart 'C:')).Count -eq 0) 'C: returned files'
    Assert (@(Get-FuPartFiles (New-FuPart '')).Count -eq 0) 'empty path returned files'
}

Test-Case 'Get-CleanupTargets returns measured rows; Recycle Bin is never pre-ticked' {
    $rows = @(Get-CleanupTargets)
    Assert ($rows.Count -ge 1) 'no rows'
    foreach ($r in $rows) {
        Assert ($r.Id -and $r.Target -and @($r.Parts).Count -ge 1) "row $($r.Id) incomplete"
        Assert ($r.Files -gt 0) "empty row $($r.Id) was listed"
        foreach ($p in $r.Parts) { Assert (([string]$p.Path).TrimEnd('\').Length -gt 2 -or $p.Filter -ne '*') "row $($r.Id) targets a drive root" }
    }
    $bin = $rows | Where-Object { $_.Id -eq 'recyclebin' }
    if ($bin) { Assert (-not $bin.Recommended -and $bin.Kind -eq 'RecycleBin') 'recycle bin is recommended' }
    Write-Host ('      found: ' + (($rows | ForEach-Object { '{0} {1}MB' -f $_.Id, $_.MB }) -join ', ')) -ForegroundColor DarkGray
}

Test-Case 'Privacy cleanup removes history and cookies only, never passwords or bookmarks' {
    $d = Join-Path $tmp 'browser'
    foreach ($f in 'Default\History', 'Default\History-journal', 'Default\Network\Cookies', 'Default\Cookies', 'Default\Login Data', 'Default\Bookmarks', 'Default\Web Data', 'Default\Cache\data_0') {
        New-TestFile (Join-Path $d "chromium\$f") 100
    }
    foreach ($f in 'places.sqlite', 'key4.db', 'logins.json') { New-TestFile (Join-Path $d "ff-local\p1\$f") 100 }
    foreach ($f in 'cookies.sqlite', 'places.sqlite', 'logins.json') { New-TestFile (Join-Path $d "ff-roaming\p1\$f") 100 }
    $chromium = [pscustomobject]@{ Browser = 'Test'; Engine = 'Chromium'; Process = 'x'; Profiles = @(Join-Path $d 'chromium\Default') }
    $firefox = [pscustomobject]@{ Browser = 'Test FF'; Engine = 'Firefox'; Process = 'y'; Profiles = @(Join-Path $d 'ff-local\p1'); RoamingProfiles = @(Join-Path $d 'ff-roaming\p1') }
    Assert (@(Get-BrowserParts $firefox 'History').Count -eq 0) 'Firefox history parts exist (would hit bookmarks)'
    $r = Invoke-Cleanup @(
        [pscustomobject]@{ Parts = @(Get-BrowserParts $chromium 'History') },
        [pscustomobject]@{ Parts = @(Get-BrowserParts $chromium 'Cookies') },
        [pscustomobject]@{ Parts = @(Get-BrowserParts $firefox 'Cookies') })
    Assert ($r.Deleted -eq 5) "deleted $($r.Deleted), expected 5"
    foreach ($kept in 'chromium\Default\Login Data', 'chromium\Default\Bookmarks', 'chromium\Default\Web Data', 'chromium\Default\Cache\data_0',
                      'ff-local\p1\places.sqlite', 'ff-roaming\p1\places.sqlite', 'ff-roaming\p1\logins.json', 'ff-local\p1\key4.db') {
        Assert (Test-Path -LiteralPath (Join-Path $d $kept)) "$kept was deleted"
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $d 'chromium\Default\Network\Cookies'))) 'Chromium cookies left'
    Assert (-not (Test-Path -LiteralPath (Join-Path $d 'ff-roaming\p1\cookies.sqlite'))) 'Firefox cookies left'
}

Test-Case 'Privacy items and Recycle Bin are never ticked; browser rows know their program' {
    $rows = @(Get-CleanupTargets)
    foreach ($r in $rows | Where-Object { $_.Privacy -or $_.Kind -ne 'Files' }) { Assert (-not $r.Recommended) "$($r.Id) is recommended" }
    foreach ($r in $rows | Where-Object { $_.Id -like 'browser-*' }) { Assert (@($r.Process).Count -ge 1) "$($r.Id) has no Process" }
}

Test-Case 'Get-FuOpenPrograms finds running programs only' {
    $open = @(Get-FuOpenPrograms @([pscustomobject]@{ Process = @('powershell') }, [pscustomobject]@{ Process = @('no-such-program-xyz') }, [pscustomobject]@{ Process = @() }))
    Assert ($open -contains 'powershell') 'powershell not found'
    Assert ($open -notcontains 'no-such-program-xyz') 'phantom program found'
}

Test-Case 'Select-AutoCleanTargets takes only safe, allowed, closed items' {
    $rows = @(
        [pscustomobject]@{ Id = 'safe';    Recommended = $true;  Privacy = $false; Kind = 'Files';      NeedsAdmin = $false; Process = @() },
        [pscustomobject]@{ Id = 'admin';   Recommended = $true;  Privacy = $false; Kind = 'Files';      NeedsAdmin = $true;  Process = @() },
        [pscustomobject]@{ Id = 'open';    Recommended = $true;  Privacy = $false; Kind = 'Files';      NeedsAdmin = $false; Process = @('chrome') },
        [pscustomobject]@{ Id = 'privacy'; Recommended = $false; Privacy = $true;  Kind = 'Files';      NeedsAdmin = $false; Process = @() },
        [pscustomobject]@{ Id = 'bin';     Recommended = $false; Privacy = $false; Kind = 'RecycleBin'; NeedsAdmin = $false; Process = @() },
        [pscustomobject]@{ Id = 'old';     Recommended = $false; Privacy = $false; Kind = 'WindowsOld'; NeedsAdmin = $true;  Process = @() }
    )
    $user = @(Select-AutoCleanTargets $rows $false @('chrome') | ForEach-Object { $_.Id })
    Assert (($user -join ',') -eq 'safe') "as user: $($user -join ',')"
    $admin = @(Select-AutoCleanTargets $rows $true @() | ForEach-Object { $_.Id })
    Assert (($admin -join ',') -eq 'safe,admin,open') "as admin, nothing open: $($admin -join ',')"
}

Test-Case 'Recycle Bin: emptying one drive leaves the others alone' {
    # Uses a second fixed drive whose bin is empty, so nothing of the user's is touched
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sys = $env:SystemDrive.Substring(0, 1)
    $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.Name.Substring(0, 1) -ne $sys -and $_.AvailableFreeSpace -gt 100MB -and
        @(Get-ChildItem -LiteralPath (Join-Path $_.Name ('$Recycle.Bin\' + $sid)) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }).Count -eq 0
    } | Select-Object -First 1
    if (-not $drive) { Write-Host '      SKIP: no second drive with an empty Recycle Bin' -ForegroundColor Yellow; return }
    $letter = $drive.Name.Substring(0, 1)
    $bin = Join-Path $drive.Name ('$Recycle.Bin\' + $sid)
    $sysBin = Join-Path "${sys}:\" ('$Recycle.Bin\' + $sid)
    $sysBefore = @(Get-ChildItem -LiteralPath $sysBin -Force -ErrorAction SilentlyContinue).Count
    $dir = Join-Path $drive.Name ('makatools-test-' + [guid]::NewGuid().ToString('N'))
    try {
        New-TestFile (Join-Path $dir 'binned.txt') 5000
        Send-ToRecycleBin (Join-Path $dir 'binned.txt')
        Assert (@(Get-ChildItem -LiteralPath $bin -Filter '$R*' -Force).Count -eq 1) "file did not reach the $letter`: Recycle Bin"
        $r = Invoke-Cleanup @([pscustomobject]@{ Kind = 'RecycleBin'; Target = 'bin'; Parts = @(New-FuPart $bin) })
        Assert (@(Get-ChildItem -LiteralPath $bin -Filter '$R*' -Force -ErrorAction SilentlyContinue).Count -eq 0) "$letter`: bin not emptied"
        Assert ($r.Deleted -ge 1 -and $r.FreedMB -ge 0) "result: $($r.Deleted) deleted"
        Assert (@(Get-ChildItem -LiteralPath $sysBin -Force -ErrorAction SilentlyContinue).Count -eq $sysBefore) "$sys`: bin was touched"
        Write-Host "      emptied the $letter`: bin; $sys`: bin untouched ($sysBefore items)" -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'Invoke-Cleanup records when the last cleanup happened' {
    Assert ((Get-FuDaysSinceCleanup) -eq 0) "days since cleanup: $(Get-FuDaysSinceCleanup)"
}

Test-Case 'Weekly reminder: due after a week, asks at most once a week, can be switched off' {
    Remove-Item -LiteralPath (Get-FuSettingsPath) -ErrorAction SilentlyContinue
    $now = Get-Date
    Assert (-not (Test-FuCleanupDue $now)) 'due on first start'
    Assert (-not (Test-FuCleanupDue $now.AddDays(6))) 'due after 6 days'
    Assert (Test-FuCleanupDue $now.AddDays(8)) 'not due after 8 days without a cleanup'
    Set-FuSetting 'LastReminder' $now.AddDays(8)
    Assert (-not (Test-FuCleanupDue $now.AddDays(10))) 'asked again 2 days after the last reminder'
    Assert (Test-FuCleanupDue $now.AddDays(16)) 'not asked again a week after the last reminder'
    Set-FuSetting 'LastCleanup' $now.AddDays(15)
    Assert (-not (Test-FuCleanupDue $now.AddDays(16))) 'due a day after a cleanup'
    Set-FuSetting 'WeeklyReminder' $false
    Assert (-not (Test-FuCleanupDue $now.AddDays(60))) 'due although switched off'
    Set-Content -LiteralPath (Get-FuSettingsPath) -Value '{ this is not json'
    Assert ((Get-FuSettings).WeeklyReminder -eq $true) 'damaged settings file not ignored'
    Remove-Item -LiteralPath (Get-FuSettingsPath)
}

Test-Case 'Find-FuUpdate picks only newer releases with a checksum' {
    $v = [version](Get-FuVersion)
    $newer = '{0}.{1}.{2}' -f $v.Major, $v.Minor, ($v.Build + 1)
    $hash = 'AB' * 32
    $rel = { param($tag, $digest, $name = 'Makatools-Setup.exe') [pscustomobject]@{ tag_name = $tag; body = 'notes'; html_url = 'https://example.invalid/r'; assets = @([pscustomobject]@{ name = $name; browser_download_url = 'https://example.invalid/s.exe'; digest = $digest }) } }
    $u = Find-FuUpdate -Release (& $rel "v$newer" "sha256:$($hash.ToLower())")
    Assert ($u -and $u.Version -eq $newer -and $u.Sha256 -eq $hash) 'newer release not offered'
    Assert (-not (Find-FuUpdate -Release (& $rel "v$(Get-FuVersion)" "sha256:$hash"))) 'same version offered'
    Assert (-not (Find-FuUpdate -Release (& $rel 'v1.0.0' "sha256:$hash"))) 'older version offered'
    Assert (-not (Find-FuUpdate -Release (& $rel "v$newer" $null))) 'release without checksum offered'
    Assert (-not (Find-FuUpdate -Release (& $rel "v$newer" "sha256:$hash" 'Other.exe'))) 'release without Setup.exe offered'
    Assert (-not (Find-FuUpdate -Release (& $rel 'latest' "sha256:$hash"))) 'non-version tag offered'
    Assert (-not (Find-FuUpdate -Repo '')) 'update check ran with no repository'
}

Test-Case 'Save-FuUpdate keeps a matching download and deletes a mismatched one' {
    $src = Join-Path $tmp 'update-src.exe'
    New-TestFile $src 4096 11
    $good = [pscustomobject]@{ Version = '9.9.9'; Url = ([uri]$src).AbsoluteUri; Sha256 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash }
    $dl = Join-Path $tmp 'downloads'
    New-Item -ItemType Directory -Path $dl | Out-Null
    $path = Save-FuUpdate $good $dl
    Assert (Test-Path -LiteralPath $path) 'verified download missing'
    Remove-Item -LiteralPath $path
    $bad = [pscustomobject]@{ Version = '9.9.8'; Url = $good.Url; Sha256 = ('00' * 32) }
    $msg = $null
    try { Save-FuUpdate $bad $dl | Out-Null } catch { $msg = $_.Exception.Message }
    Assert ($msg -match 'checksum') "no checksum error: $msg"
    Assert (@(Get-ChildItem -LiteralPath $dl).Count -eq 0) 'mismatched download was kept'
}

Test-Case 'Remove-FileSecurely removes the file and keeps the folder' {
    $d = Join-Path $tmp 'shred'
    $f = Join-Path $d 'secret.txt'
    New-TestFile $f 70000
    Remove-FileSecurely $f 2
    Assert (-not (Test-Path -LiteralPath $f)) 'file still there'
    Assert (Test-Path -LiteralPath $d) 'folder removed'
    Assert (@(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) 'renamed leftover remains'
}

Test-Case 'Remove-FileSecurely rejects bad pass counts and folders' {
    $f = Join-Path $tmp 'shred\keep.txt'
    New-TestFile $f 10
    foreach ($bad in 0, 8) {
        $threw = $false
        try { Remove-FileSecurely $f $bad } catch { $threw = $true }
        Assert $threw "passes=$bad did not throw"
    }
    Assert (Test-Path -LiteralPath $f) 'file was deleted despite bad pass count'
    $threw = $false
    try { Remove-FileSecurely (Join-Path $tmp 'shred') 1 } catch { $threw = $true }
    Assert $threw 'folder did not throw'
}

Test-Case 'Find-DuplicateFiles finds one group with one copy' {
    $d = Join-Path $tmp 'dups'
    New-TestFile (Join-Path $d 'a.bin') 5000 7
    New-TestFile (Join-Path $d 'sub\b.bin') 5000 7
    New-TestFile (Join-Path $d 'c.bin') 5000 99
    $groups = @(Find-DuplicateFiles $d 1000)
    Assert ($groups.Count -eq 1) "groups = $($groups.Count)"
    Assert (@($groups[0].Copies).Count -eq 1) "copies = $(@($groups[0].Copies).Count)"
    Assert ($groups[0].Keep -like '*a.bin') "kept $($groups[0].Keep)"
}

Test-Case 'Get-LargeFiles sorts biggest first' {
    $d = Join-Path $tmp 'large'
    New-TestFile (Join-Path $d 'small.bin') 100
    New-TestFile (Join-Path $d 'big.bin') 9000
    $r = @(Get-LargeFiles $d 1)
    Assert ($r.Count -eq 1 -and $r[0].Name -eq 'big.bin') 'wrong top file'
}

Test-Case 'Read-RecycleInfoFile parses v2 metadata' {
    $when = Get-Date -Year 2026 -Month 3 -Day 4 -Hour 5 -Minute 6 -Second 7 -Millisecond 0
    $info = Join-Path $tmp 'bin\$IABC123.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $info) -Force | Out-Null
    [System.IO.File]::WriteAllBytes($info, (New-RecycleInfoBytes 'C:\Users\x\Documents\notes.txt' 1234 $when))
    $m = Read-RecycleInfoFile $info
    Assert ($m.OriginalPath -eq 'C:\Users\x\Documents\notes.txt') "path = $($m.OriginalPath)"
    Assert ($m.Size -eq 1234) "size = $($m.Size)"
    Assert ($m.Deleted -eq $when) "time = $($m.Deleted)"
}

Test-Case 'Restore-RecycleBinEntry restores, and renames on collision' {
    $bin = Join-Path $tmp 'bin2'
    $orig = Join-Path $tmp 'restore\photo.jpg'
    foreach ($round in 1, 2) {
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $info = Join-Path $bin "`$IR$round.jpg"
        $data = Join-Path $bin "`$RR$round.jpg"
        New-TestFile $data 50 $round
        [System.IO.File]::WriteAllBytes($info, (New-RecycleInfoBytes $orig 50 (Get-Date)))
        $dest = Restore-RecycleBinEntry $info
        Assert (-not (Test-Path -LiteralPath $info)) "round ${round}: info file left"
        Assert (-not (Test-Path -LiteralPath $data)) "round ${round}: data file left"
        Assert (Test-Path -LiteralPath $dest) "round ${round}: restored file missing"
        if ($round -eq 1) { Assert ($dest -eq $orig) "round 1 went to $dest" }
        else { Assert ($dest -eq (Join-Path $tmp 'restore\photo (restored).jpg')) "round 2 went to $dest" }
    }
}

Test-Case 'Get-RecycleBinEntries does not throw' { $null = @(Get-RecycleBinEntries) }

# Startup locations pointing at a throwaway key and folder instead of the real ones
function New-TestStartupLocations {
    $run = 'HKCU:\Software\MakatoolsTest\Run'
    New-Item -Path $run -Force | Out-Null
    New-ItemProperty -Path $run -Name 'Fake App' -Value 'C:\fake\app.exe /min' -Force | Out-Null
    New-ItemProperty -Path $run -Name 'Norton Fake' -Value 'C:\Program Files\Norton\Suite\fake.exe' -Force | Out-Null
    $folder = Join-Path $tmp 'StartupFolder'
    New-TestFile (Join-Path $folder 'Fake Tool.lnk') 10
    New-TestFile (Join-Path $folder 'desktop.ini') 10
    @(
        @{ Source = 'Registry';       Scope = 'Current user'; Path = $run;    Approved = 'HKCU:\Software\MakatoolsTest\Approved\Run' },
        @{ Source = 'Startup folder'; Scope = 'Current user'; Path = $folder; Approved = 'HKCU:\Software\MakatoolsTest\Approved\StartupFolder' }
    )
}

Test-Case 'Startup entries: switch off and on like Task Manager, nothing deleted' {
    try {
        $locs = New-TestStartupLocations
        $entries = @(Get-StartupEntries -Locations $locs -NoTasks)
        Assert ($entries.Count -eq 3) "found $($entries.Count), expected 3 (desktop.ini must be skipped)"
        Assert (@($entries | Where-Object { $_.Status -ne 'On' }).Count -eq 0) 'entries without a flag should be On'
        foreach ($name in 'Fake App', 'Fake Tool.lnk') {
            $e = $entries | Where-Object { $_.Name -eq $name }
            Set-StartupEntryState $e $false
            $flag = (Get-Item -LiteralPath $e.ApprovedKey).GetValue($name)
            Assert ($flag.Length -eq 12 -and $flag[0] -eq 3) "$name off flag wrong: $($flag -join ',')"
            Assert ([DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($flag, 4)) -gt (Get-Date).ToUniversalTime().AddMinutes(-5)) "$name off time wrong"
            Assert ((@(Get-StartupEntries -Locations $locs -NoTasks) | Where-Object { $_.Name -eq $name }).Status -eq 'Off') "$name not reported Off"
            Set-StartupEntryState $e $true
            Assert ((Get-Item -LiteralPath $e.ApprovedKey).GetValue($name)[0] -eq 2) "$name on flag wrong"
            Assert ((@(Get-StartupEntries -Locations $locs -NoTasks) | Where-Object { $_.Name -eq $name }).Status -eq 'On') "$name not reported On"
        }
        Assert (Get-ItemProperty -Path 'HKCU:\Software\MakatoolsTest\Run' -Name 'Fake App' -ErrorAction SilentlyContinue) 'Run value was deleted'
        Assert (Test-Path -LiteralPath (Join-Path $tmp 'StartupFolder\Fake Tool.lnk')) 'startup shortcut was deleted'
        # A flag Task Manager wrote as 06 also means on
        Set-ItemProperty -LiteralPath 'HKCU:\Software\MakatoolsTest\Approved\Run' -Name 'Fake App' -Value ([byte[]](6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Type Binary
        Assert (Test-StartupApproved 'HKCU:\Software\MakatoolsTest\Approved\Run' 'Fake App') '06 flag read as off'
    } finally {
        Remove-Item -Path 'HKCU:\Software\MakatoolsTest' -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'Startup entries: scheduled sign-in task switches off and on' {
    $name = 'MakatoolsTestTask'
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
        Register-ScheduledTask -TaskPath '\MakatoolsTest\' -TaskName $name -Action $action -Trigger $trigger -User $me -ErrorAction Stop | Out-Null
        $e = @(Get-StartupEntries -Locations @()) | Where-Object { $_.Name -eq $name }
        Assert $e 'test task not listed'
        Assert ($e.Source -eq 'Scheduled task' -and $e.Status -eq 'On' -and $e.Scope -eq 'Current user') "listed as $($e.Source)/$($e.Status)/$($e.Scope)"
        Set-StartupEntryState $e $false
        Assert ([string](Get-ScheduledTask -TaskPath '\MakatoolsTest\' -TaskName $name).State -eq 'Disabled') 'task not disabled'
        Set-StartupEntryState $e $true
        Assert ([string](Get-ScheduledTask -TaskPath '\MakatoolsTest\' -TaskName $name).State -eq 'Ready') 'task not enabled'
    } finally {
        Unregister-ScheduledTask -TaskPath '\MakatoolsTest\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Test-Case 'Test-FuProtected recognises Norton and Defender, not ordinary apps' {
    foreach ($t in 'Norton Antivirus', 'C:\Program Files\Norton\Suite\NortonUI.exe', 'NortonSvc', 'MsMpEng', 'WinDefend', 'SecurityHealthSystray', 'Microsoft Defender Antivirus Service') {
        Assert (Test-FuProtected @($t)) "not protected: $t"
    }
    foreach ($t in 'Spotify', 'Discord', 'C:\Program Files\Steam\steam.exe', 'AVGO driver', 'OneDrive', $null) {
        Assert (-not (Test-FuProtected @($t))) "wrongly protected: $t"
    }
}

Test-Case 'Startup entries: antivirus entries are never switched off' {
    try {
        $locs = New-TestStartupLocations
        $e = @(Get-StartupEntries -Locations $locs -NoTasks) | Where-Object { $_.Name -eq 'Norton Fake' }
        $msg = $null
        try { Set-StartupEntryState $e $false } catch { $msg = $_.Exception.Message }
        Assert ($msg -match 'antivirus') "did not refuse: $msg"
        Assert (Test-StartupApproved $e.ApprovedKey 'Norton Fake') 'antivirus entry was switched off'
    } finally {
        Remove-Item -Path 'HKCU:\Software\MakatoolsTest' -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'Get-AntivirusStatus and the dashboard list the antivirus' {
    $av = @(Get-AntivirusStatus)
    Assert ($av.Count -ge 1) 'no antivirus reported'
    Assert ((Get-SystemSummary) -match 'Antivirus : .+\((on|off)\)') 'summary lacks antivirus line'
    Write-Host ('      ' + (($av | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ', ')) -ForegroundColor DarkGray
}

Test-Case 'Get-StartupEntries reads the real startup list' {
    $all = @(Get-StartupEntries)
    foreach ($e in $all) {
        Assert ($e.Name -and $e.Status -in 'On', 'Off' -and $e.Source) "incomplete entry: $($e.Name)"
        if ($e.Source -ne 'Scheduled task') { Assert $e.ApprovedKey "no flag key for $($e.Name)" }
    }
    Write-Host ('      ' + (($all | Group-Object Source | ForEach-Object { '{0}: {1} ({2} off)' -f $_.Name, $_.Count, @($_.Group | Where-Object Status -eq 'Off').Count }) -join ', ')) -ForegroundColor DarkGray
}

Test-Case 'Get-ProcessList includes this process' {
    $rows = @(Get-ProcessList)
    Assert (@($rows | Where-Object { $_.Id -eq $PID }).Count -eq 1) 'own PID missing'
}

Test-Case 'Get-ServiceList returns services' { Assert (@(Get-ServiceList).Count -gt 10) 'too few services' }

Test-Case 'Get-InstalledPrograms returns programs' {
    $rows = @(Get-InstalledPrograms)
    Assert ($rows.Count -gt 0) 'none found'
    Assert ($rows[0].Name -and $rows[0].Uninstall) 'row missing Name/Uninstall'
}

Test-Case 'Get-DiskHealth returns at least one disk' {
    $rows = @(Get-DiskHealth)
    Assert ($rows.Count -ge 1) 'no disks'
    Assert ($null -ne $rows[0].TempC) 'TempC empty'
}

Test-Case 'Get-SystemSummary mentions Windows' { Assert ((Get-SystemSummary) -match 'Windows') 'no Windows line' }

# ---------------------------------------------------------------- admin only
# Run elevated to include these: they need Administrator rights and change nothing of the user's.

if (Test-FuAdmin) {
    Test-Case 'Admin: disk reliability counters are readable' {
        $rows = @(Get-DiskHealth)
        Assert (@($rows | Where-Object { $_.TempC -eq 'needs admin' }).Count -eq 0) 'still says needs admin'
        Write-Host ('      ' + (($rows | ForEach-Object { '{0}: {1} C, wear {2}' -f $_.Disk, $_.TempC, $_.WearPct }) -join '; ')) -ForegroundColor DarkGray
    }

    Test-Case 'Admin: all-users startup entry switches off and on' {
        $run = 'HKLM:\Software\MakatoolsTest\Run'
        try {
            New-Item -Path $run -Force | Out-Null
            New-ItemProperty -Path $run -Name 'Fake Machine App' -Value 'C:\fake\machine.exe' -Force | Out-Null
            $locs = @(@{ Source = 'Registry'; Scope = 'All users'; Path = $run; Approved = 'HKLM:\Software\MakatoolsTest\Approved\Run' })
            $e = @(Get-StartupEntries -Locations $locs -NoTasks)[0]
            Set-StartupEntryState $e $false
            Assert ((@(Get-StartupEntries -Locations $locs -NoTasks)[0]).Status -eq 'Off') 'not off'
            Set-StartupEntryState $e $true
            Assert ((@(Get-StartupEntries -Locations $locs -NoTasks)[0]).Status -eq 'On') 'not on'
        } finally {
            Remove-Item -Path 'HKLM:\Software\MakatoolsTest' -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'Admin: DISM runs (read-only component store report)' {
        $out = Invoke-ComponentCleanup -AnalyzeOnly
        Assert ($out -match '^Exit code 0') ($out.Substring(0, [math]::Min(300, $out.Length)))
        $line = ($out -split "`r?`n" | Where-Object { $_ -match 'Component Store Cleanup Recommended|Reclaimable' }) -join '; '
        Write-Host "      $line" -ForegroundColor DarkGray
    }
} else {
    Write-Host 'SKIP  admin-only tests (run elevated to include them)' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- UI
# Builds the real window off-screen and clicks buttons from here, outside the Add-*Tab functions,
# which is where the handlers run in real use. Message boxes are replaced so nothing blocks.

if (-not $SkipUi) {
    . (Join-Path $repo 'src\Ui.ps1')
    $script:Infos = New-Object System.Collections.ArrayList
    $script:ConfirmAnswer = $true
    function Show-FuInfo($Text, $Icon = 'Information') { [void]$script:Infos.Add([string]$Text) }
    function Confirm-FuAction($Text) { return $script:ConfirmAnswer }

    $script:NoUpdateCheck = $true   # no automatic call to GitHub when the test window opens
    $form = New-MainForm
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-3000, -3000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    function Find-FuButton([string]$Tab, [string]$Text) {
        $page = $script:Ui.Tabs.TabPages | Where-Object { $_.Text -eq $Tab }
        $script:Ui.Tabs.SelectedTab = $page
        [System.Windows.Forms.Application]::DoEvents()
        $stack = New-Object System.Collections.Stack
        $stack.Push($page)
        while ($stack.Count -gt 0) {
            $c = $stack.Pop()
            if ($c -is [System.Windows.Forms.Button] -and $c.Text -eq $Text) { return $c }
            foreach ($child in $c.Controls) { $stack.Push($child) }
        }
        throw "button '$Text' not found on '$Tab'"
    }
    function Wait-FuJob([int]$Seconds = 120) {
        $end = (Get-Date).AddSeconds($Seconds)
        while ($script:Job -and (Get-Date) -lt $end) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        Assert (-not $script:Job) 'job did not finish in time'
        Assert ($script:StatusLabel.Text -ne 'Task failed') ("job failed: " + ($script:Infos -join ' | '))
    }

    Test-Case 'UI: background runspace has Core functions, AppRoot and progress' {
        $rs = New-FuRunspace
        try {
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript('Set-FuProgress "probe" 42; Write-FuLog "runspace probe"; (Get-Command Get-CleanupTargets).Name')
            $out = @($ps.Invoke())
            Assert ($out -contains 'Get-CleanupTargets') 'Core function missing in runspace'
            Assert ($script:FuProgress.Text -eq 'probe' -and $script:FuProgress.Percent -eq 42) 'progress not shared'
            Assert ((Get-Content -LiteralPath (Join-Path $tmp 'Logs\freeutil.log') -Raw) -match 'runspace probe') 'runspace did not log to the app log'
        } finally { $rs.Dispose() }
    }

    Test-Case 'UI: Cancel task stops a running task at once' {
        Start-FuWork 'Sleeping' { Start-Sleep -Seconds 60 } -OnDone { throw 'should not finish' }
        Start-Sleep -Milliseconds 300
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $script:CancelButton.PerformClick()
        Wait-FuJob 10
        Assert ($sw.Elapsed.TotalSeconds -lt 5) "took $($sw.Elapsed.TotalSeconds)s"
        Assert ($script:StatusLabel.Text -eq 'Cancelled') "status: $($script:StatusLabel.Text)"
    }

    Test-Case 'UI: window builds with 12 tabs' { Assert ($script:Ui.Tabs.TabPages.Count -eq 12) "tabs = $($script:Ui.Tabs.TabPages.Count)" }

    Test-Case 'UI: Dashboard Refresh button' {
        $script:Ui.DashText.Text = ''
        (Find-FuButton 'Dashboard' 'Refresh').PerformClick()
        Assert ($script:Ui.DashText.Text -match 'Windows') 'dashboard text empty'
    }

    Test-Case 'UI: Activity Log Refresh button' {
        $script:Ui.LogText.Text = ''
        (Find-FuButton 'Activity Log' 'Refresh').PerformClick()
        Assert ($script:Ui.LogText.Text -match 'hello from tests') 'log text not shown'
    }

    Test-Case 'UI: Startup, Services, Programs, Recycle refresh buttons' {
        (Find-FuButton 'Startup' 'Refresh').PerformClick()
        Assert ($script:Ui.StartupGrid.Rows.Count -eq @($script:StartupItems).Count) 'startup grid mismatch'
        (Find-FuButton 'Services' 'Refresh').PerformClick()
        Assert ($script:Ui.ServiceGrid.Rows.Count -gt 10) 'services grid empty'
        (Find-FuButton 'Installed Programs' 'Refresh').PerformClick()
        Assert ($script:Ui.ProgramGrid.Rows.Count -gt 0) 'programs grid empty'
        (Find-FuButton 'Recover Deleted' 'Refresh').PerformClick()
        Assert ($script:Ui.RecycleGrid.Rows.Count -eq @($script:RecycleRows).Count) 'recycle grid mismatch'
    }

    Test-Case 'UI: Disk Health refresh button' {
        (Find-FuButton 'Disk Health' 'Refresh disks').PerformClick()
        Assert ($script:Ui.DiskGrid.Rows.Count -ge 1) 'disk grid empty'
    }

    Test-Case 'UI: Cleanup Scan runs in a background job' {
        (Find-FuButton 'Cleanup' 'Scan').PerformClick()
        Assert $script:Job 'no job started'
        Wait-FuJob
        Assert ($script:Ui.CleanupList.Items.Count -ge 1) 'cleanup list empty'
    }

    Test-Case 'UI: Processes Refresh runs in a background job' {
        (Find-FuButton 'Processes' 'Refresh').PerformClick()
        Wait-FuJob
        Assert ($script:Ui.ProcessGrid.Rows.Count -gt 5) 'process grid empty'
    }

    Test-Case 'UI: Duplicates job finds the test copy' {
        $d = Join-Path $tmp 'uidups'
        New-TestFile (Join-Path $d 'one.bin') 1200000 3
        New-TestFile (Join-Path $d 'two.bin') 1200000 3
        $script:Ui.DupPath.Text = $d
        (Find-FuButton 'Duplicates' 'Find duplicates').PerformClick()
        Wait-FuJob
        Assert (@($script:DupRows).Count -eq 1) "dup rows = $(@($script:DupRows).Count)"
        Assert ($script:Ui.DupGrid.Rows.Count -eq 1) 'dup grid not filled'
    }

    Test-Case 'UI: Large Files job fills the grid' {
        $script:Ui.LargePath.Text = Join-Path $tmp 'large'
        (Find-FuButton 'Large Files' 'Find 200 largest files').PerformClick()
        Wait-FuJob
        Assert ($script:Ui.LargeGrid.Rows.Count -eq 2) "large rows = $($script:Ui.LargeGrid.Rows.Count)"
    }

    Test-Case 'UI: Secure Delete button shreds the chosen file' {
        $f = Join-Path $tmp 'uishred\x.txt'
        New-TestFile $f 100
        $script:Ui.ShredPath.Text = $f
        (Find-FuButton 'Secure Delete' 'Shred file permanently').PerformClick()
        Assert (-not (Test-Path -LiteralPath $f)) 'file still there'
        Assert ($script:Ui.ShredPath.Text -eq '') 'path box not cleared'
    }

    Test-Case 'UI: Clean ticked locations runs Invoke-Cleanup in a job' {
        $d = Join-Path $tmp 'uiclean'
        New-TestFile (Join-Path $d 'junk.tmp') 100
        $script:CleanupRows = @([pscustomobject]@{ Id = 't'; Target = 'Test'; Path = $d; Files = 1; MB = 0; Bytes = 100; NeedsAdmin = $false })
        $script:Ui.CleanupList.Items.Clear()
        [void]$script:Ui.CleanupList.Items.Add('Test')
        $script:Ui.CleanupList.SetItemChecked(0, $true)
        $script:Infos.Clear()
        (Find-FuButton 'Cleanup' 'Clean ticked locations').PerformClick()
        Wait-FuJob
        Assert (-not (Test-Path -LiteralPath (Join-Path $d 'junk.tmp'))) 'file not cleaned'
        Assert (($script:Infos -join ' ') -match 'Deleted 1 files') ("result message: " + ($script:Infos -join ' | '))
        Assert ((Get-Content -LiteralPath (Join-Path $tmp 'Logs\freeutil.log') -Raw) -match 'Cleanup: deleted 1 files') 'job did not log to the app log'
        Wait-FuJob   # the re-scan that follows
    }

    Test-Case 'UI: Optimize now runs the auto-clean and reports what it freed' {
        # Stand-in, so the test does not clean this PC; the background runspace picks it up
        function Invoke-AutoClean([string]$Reason) { [pscustomobject]@{ FreedMB = 12.5; Deleted = 40; Skipped = 2; Items = 3; LeftForOpenPrograms = @('Google Chrome cache') } }
        $script:Infos.Clear()
        (Find-FuButton 'Dashboard' 'Optimize now').PerformClick()
        Wait-FuJob
        $msg = $script:Infos -join ' '
        Assert ($msg -match 'Freed 12.5 MB' -and $msg -match 'Google Chrome cache') "message: $msg"
        Remove-Item Function:\Invoke-AutoClean
    }

    Test-Case 'UI: weekly reminder asks when due, and "No" waits a week' {
        Set-FuSetting 'WeeklyReminder' $true
        Set-FuSetting 'LastCleanup' (Get-Date).AddDays(-9)
        Set-FuSetting 'LastReminder' $null
        $script:ConfirmAnswer = $false
        $started = & $script:Ui.ReminderCheck
        $script:ConfirmAnswer = $true
        Assert (-not $started -and -not $script:Job) 'cleanup started after No'
        Assert (-not (Test-FuCleanupDue)) 'would ask again straight away'
        Assert ($script:Ui.CleanupWeekly.Checked) 'reminder checkbox not shown as on'
    }

    Test-Case 'UI: update check - not set up, offline (quiet and manual), up to date' {
        # Stand-ins, so the test does not depend on GitHub; the background runspace picks them up
        function Get-FuUpdateRepo { '' }
        $script:Infos.Clear()
        (Find-FuButton 'Dashboard' 'Check for updates').PerformClick()
        Assert (($script:Infos -join ' ') -match 'not set up') "not set up: $($script:Infos -join ' ')"

        function Get-FuUpdateRepo { 'example/repo' }
        function Find-FuUpdate { throw 'No such host is known.' }
        $script:Infos.Clear()
        & $script:Ui.UpdateCheck $true
        Wait-FuJob
        Assert ($script:Infos.Count -eq 0) "quiet check spoke: $($script:Infos -join ' ')"
        (Find-FuButton 'Dashboard' 'Check for updates').PerformClick()
        Wait-FuJob
        Assert (($script:Infos -join ' ') -match 'Could not check for updates') "manual offline: $($script:Infos -join ' ')"

        function Find-FuUpdate { $null }
        $script:Infos.Clear()
        (Find-FuButton 'Dashboard' 'Check for updates').PerformClick()
        Wait-FuJob
        Assert (($script:Infos -join ' ') -match 'latest version') "up to date: $($script:Infos -join ' ')"
        Remove-Item Function:\Get-FuUpdateRepo, Function:\Find-FuUpdate
        . (Join-Path $repo 'src\Core.ps1')   # put the real functions back
    }

    Test-Case 'UI: Startup tab has Switch off / Switch on, and the window scales by DPI' {
        $null = Find-FuButton 'Startup' 'Switch off'
        $null = Find-FuButton 'Startup' 'Switch on'
        Assert ([string]$form.AutoScaleMode -eq 'Dpi') "AutoScaleMode $($form.AutoScaleMode)"
        Assert ($form.Text -eq "Makatools $(Get-FuVersion)") "title: $($form.Text)"
    }

    $form.Close()
    $form.Dispose()
}

# ---------------------------------------------------------------- done

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($ResultFile) { Stop-Transcript | Out-Null }
if ($script:Failed -gt 0) { exit 1 }
exit 0
