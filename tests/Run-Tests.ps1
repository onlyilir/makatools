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

Test-Case 'desktop.ini is never counted or removed; an empty Recycle Bin counts as empty' {
    $d = Join-Path $tmp 'ini'
    New-TestFile (Join-Path $d 'desktop.ini') 100
    New-TestFile (Join-Path $d 'junk.tmp') 100
    Assert ((Measure-FuFolder $d).Files -eq 1) 'desktop.ini was counted'
    $r = Invoke-Cleanup @([pscustomobject]@{ Path = $d })
    Assert ($r.Deleted -eq 1 -and $r.Skipped -eq 0) "deleted $($r.Deleted), skipped $($r.Skipped)"
    Assert (Test-Path -LiteralPath (Join-Path $d 'desktop.ini')) 'desktop.ini was removed'
    $bin = Join-Path $tmp 'fake\$Recycle.Bin\S-1-5-21'
    New-TestFile (Join-Path $bin 'desktop.ini') 129
    Assert ((Measure-FuFolder $bin).Files -eq 0) 'empty bin not empty'
    New-TestFile (Join-Path $bin '$IABC.txt') 50
    New-TestFile (Join-Path $bin '$RABC.txt') 5000
    $m = Measure-FuFolder $bin
    Assert ($m.Files -eq 1 -and $m.Bytes -eq 5000) "one deleted file counted as $($m.Files), $($m.Bytes) bytes"
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

Test-Case 'All script files are pure ASCII (PowerShell 5.1 misreads anything else)' {
    foreach ($f in Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.bat' -and $_.FullName -notmatch '\\(dist|private|\.git)\\' }) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $start = $(if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 })
        for ($i = $start; $i -lt $bytes.Length; $i++) { Assert ($bytes[$i] -lt 128) "$($f.Name) has a non-ASCII byte at $i" }
    }
}

Test-Case 'Format-FuSize reads like a person wrote it' {
    Assert ((Format-FuSize 512) -eq '512 bytes') (Format-FuSize 512)
    Assert ((Format-FuSize 2048) -eq '2 KB') (Format-FuSize 2048)
    Assert ((Format-FuSize 823MB) -eq '823 MB') (Format-FuSize 823MB)
    Assert ((Format-FuSize 2.34GB) -eq '2.3 GB') (Format-FuSize 2.34GB)
    Assert ((Format-FuSize 1.5TB) -eq '1.5 TB') (Format-FuSize 1.5TB)
}

Test-Case 'Get-SystemInfo returns everything Home needs' {
    $i = Get-SystemInfo
    Assert ($i.Computer -and $i.Windows -and $i.Processor) 'missing basics'
    Assert ($i.MemoryBytes -gt 0 -and $i.MemoryUsed -gt 0 -and $i.MemoryUsed -le $i.MemoryBytes) 'bad memory figures'
    Assert (@($i.Volumes).Count -ge 1 -and $i.SystemDrive) 'no volumes'
    Assert (@($i.Volumes | Where-Object { $_.Letter -eq $i.SystemDrive }).Count -eq 1) 'system drive not among the volumes'
}

Test-Case 'Get-FuLogEntries returns newest first and skips damaged lines' {
    $log = Join-Path $tmp 'Logs\freeutil.log'
    $keep = Get-Content -LiteralPath $log
    Set-Content -LiteralPath $log -Value @('2026-01-01 10:00:00 [INFO] first', 'garbage', '2026-01-02 11:30:05 [INFO] second')
    $rows = @(Get-FuLogEntries)
    Set-Content -LiteralPath $log -Value $keep
    Assert ($rows.Count -eq 2) "rows: $($rows.Count)"
    Assert ($rows[0].Message -eq 'second' -and $rows[0].When -eq '2026-01-02 11:30') "first row: $($rows[0].When) $($rows[0].Message)"
}

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
# Shows the real window off-screen and presses its real buttons. Nothing here cleans this PC: what
# a test cleans or shreds is in its temp folder, and anything else is replaced by a stand-in defined
# inside that test. Dialogs are replaced so nothing waits for a click, except the one test of the
# real dialog.

if (-not $SkipUi) {
    . (Join-Path $repo 'src\Ui.ps1')
    $script:Infos = New-Object System.Collections.ArrayList
    $script:ConfirmAnswer = $true
    function Show-FuInfo($Text, $Icon = 'Information', $Title = '') { [void]$script:Infos.Add(("$Title $Text").Trim()) }
    function Confirm-FuAction($Text, $Title = '', $Yes = '', [bool]$Danger = $false) { [void]$script:Infos.Add(("$Title $Text").Trim()); return $script:ConfirmAnswer }

    function Wait-Ui([int]$Ms = 60) {
        $end = (Get-Date).AddMilliseconds($Ms)
        do {
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, 'Background')
            Start-Sleep -Milliseconds 10
        } while ((Get-Date) -lt $end)
    }
    function Wait-FuJob([int]$Seconds = 120) {
        $end = (Get-Date).AddSeconds($Seconds)
        Wait-Ui 30
        while ($script:Tasks.Count -and (Get-Date) -lt $end) { Wait-Ui 40 }
        Assert (-not $script:Tasks.Count) 'task did not finish in time'
        Wait-Ui 30
    }
    function Click-Ui($Element) {
        $Element.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
    function Go-Page([string]$Name) {
        $script:Ui["Nav$Name"].IsChecked = $true
        Wait-Ui 80
    }
    # Every element of a type under a visual
    function Find-Visuals($Root, [type]$Type) {
        $stack = New-Object System.Collections.Stack
        $stack.Push($Root)
        while ($stack.Count) {
            $v = $stack.Pop()
            if ($v -is $Type) { $v }
            for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($v); $i++) { $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($v, $i)) }
        }
    }

    $script:NoUpdateCheck = $true   # no automatic call to GitHub when the test window opens
    $form = New-MainForm
    $form.WindowStartupLocation = 'Manual'
    $form.Left = -6000
    $form.Top = 100
    $form.ShowInTaskbar = $false
    $form.ShowActivated = $false
    $form.Show()
    Wait-Ui 300

    Test-Case 'UI: window loads in both themes with every control found' {
        foreach ($n in 'Sheet', 'TaskPill', 'HeroBig', 'CleanGo', 'StartupList', 'ShredGo', 'DiskList', 'ThemeDark', 'CapClose') { Assert $script:Ui[$n] "control $n missing" }
        foreach ($t in 'Dark', 'Light') {
            Set-FuTheme $t
            Assert ((Get-FuEffectiveTheme $t) -eq $t) "theme $t"
            Assert (Get-FuBrush 'SegmentOn') "colour SegmentOn missing in $t"
        }
    }

    Test-Case 'UI: the window always fits the screen' {
        $w = New-Object Windows.Window
        Set-FuWindowFit $w 1920 1040
        Assert ($w.Width -eq 1120 -and $w.Height -eq 760 -and $w.MinWidth -eq 960 -and $w.MinHeight -eq 620) "big screen: $($w.Width)x$($w.Height), min $($w.MinWidth)x$($w.MinHeight)"
        Set-FuWindowFit $w 958 580
        Assert ($w.Width -eq 958 -and $w.Height -eq 580 -and $w.MinWidth -le 958 -and $w.MinHeight -le 580) "small screen: $($w.Width)x$($w.Height), min $($w.MinWidth)x$($w.MinHeight)"
    }

    Test-Case 'UI: colour files define the same names' {
        $keys = foreach ($t in 'Light', 'Dark') { ,@([regex]::Matches((Get-Content -LiteralPath (Join-Path $repo "src\Colors.$t.xaml") -Raw), 'x:Key="(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object) }
        Assert (($keys[0] -join ',') -eq ($keys[1] -join ',')) 'Colors.Light and Colors.Dark differ'
    }

    Test-Case 'UI: every colour and style the window asks for exists' {
        $text = (Get-Content -LiteralPath (Join-Path $repo 'src\MainWindow.xaml') -Raw) + (Get-Content -LiteralPath (Join-Path $repo 'src\Theme.xaml') -Raw) + (Get-Content -LiteralPath (Join-Path $repo 'setup\SetupWindow.xaml') -Raw)
        foreach ($m in [regex]::Matches($text, '\{DynamicResource (\w+)\}')) { Assert (Get-FuBrush $m.Groups[1].Value) "missing colour $($m.Groups[1].Value)" }
    }

    Test-Case 'UI: background runspace has Core functions, AppRoot and its own progress' {
        $p = [hashtable]::Synchronized(@{ Text = ''; Percent = -1 })
        $rs = New-FuRunspace $p
        try {
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript('Set-FuProgress "probe" 42; Write-FuLog "runspace probe"; (Get-Command Get-CleanupTargets).Name')
            $out = @($ps.Invoke())
            Assert ($out -contains 'Get-CleanupTargets') 'Core function missing in runspace'
            Assert ($p.Text -eq 'probe' -and $p.Percent -eq 42) 'progress not shared'
            Assert ((Get-Content -LiteralPath (Join-Path $tmp 'Logs\freeutil.log') -Raw) -match 'runspace probe') 'runspace did not log to the app log'
        } finally { $rs.Dispose() }
    }

    Test-Case 'UI: background tasks still work after Windows modules were used on the main thread' {
        # Set-StartupEntryState on the main thread loads ScheduledTasks; Core tests above loaded Storage
        $null = Get-ScheduledTask -TaskName 'NoSuchTaskXyz' -ErrorAction SilentlyContinue
        $null = Get-Volume -ErrorAction SilentlyContinue
        $rs = New-FuRunspace ([hashtable]::Synchronized(@{ Text = ''; Percent = -1 }))
        try {
            foreach ($c in '@(Get-Volume).Count', '@(Get-ScheduledTask).Count', '@(Get-PhysicalDisk).Count') {
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript($c)
                $n = @($ps.Invoke())[0]
                Assert ($n -gt 0 -and $ps.Streams.Error.Count -eq 0) "$c gave $n, errors: $($ps.Streams.Error -join ' ')"
                $ps.Dispose()
            }
        } finally { $rs.Dispose() }
    }

    Test-Case 'UI: Home fills in by itself (read-only)' {
        Wait-FuJob
        Wait-Ui 200
        Assert ($script:Ui.HeroBig.Text -ne [string][char]0x2013) 'hero never updated'
        Assert ($script:Ui.TileStorageValue.Text -match '\d') "storage tile: $($script:Ui.TileStorageValue.Text)"
        Assert ($script:Ui.TileMemoryValue.Text -match '% used') "memory tile: $($script:Ui.TileMemoryValue.Text)"
        Assert ($script:Ui.TileStartupValue.Text -match 'app') "startup tile: $($script:Ui.TileStartupValue.Text)"
        Assert (@($script:Ui.DriveList.ItemsSource).Count -ge 1) 'no drives'
        Assert (@($script:Ui.FactList.ItemsSource).Count -eq 5) 'facts missing'
        Assert (@($script:CleanRows).Count -ge 1) 'scan found nothing'
        Write-Host ('      hero: ' + $script:Ui.HeroKicker.Text + ' / ' + $script:Ui.HeroBig.Text) -ForegroundColor DarkGray
    }

    Test-Case 'UI: sidebar shows exactly one page at a time, and every page opens' {
        foreach ($n in 'Cleanup', 'Large', 'Dup', 'Startup', 'Apps', 'Proc', 'Svc', 'Recover', 'Shred', 'Disk', 'Log', 'Settings', 'Home') {
            Go-Page $n
            $shown = @('Home', 'Cleanup', 'Large', 'Dup', 'Startup', 'Apps', 'Proc', 'Svc', 'Recover', 'Shred', 'Disk', 'Log', 'Settings' | Where-Object { $script:Ui["Page$_"].Visibility -eq 'Visible' })
            Assert ($shown.Count -eq 1 -and $shown[0] -eq $n) "$n showed: $($shown -join ',')"
        }
        Wait-FuJob
    }

    Test-Case 'UI: lists fill and search narrows them' {
        foreach ($t in @(@('Proc', 'ProcSearch', 'ProcList', 'svchost'), @('Svc', 'SvcSearch', 'SvcList', 'Windows'), @('Apps', 'AppsSearch', 'AppsList', 'Microsoft'))) {
            Go-Page $t[0]
            Wait-FuJob
            $all = @($script:Ui[$t[2]].ItemsSource).Count
            Assert ($all -gt 0) "$($t[0]) list empty"
            $script:Ui[$t[1]].Text = $t[3]
            Wait-Ui 30
            $some = @($script:Ui[$t[2]].ItemsSource).Count
            Assert ($some -le $all) "$($t[0]) search grew the list"
            $script:Ui[$t[1]].Text = 'no-such-thing-xyz'
            Wait-Ui 30
            Assert (@($script:Ui[$t[2]].ItemsSource).Count -eq 0) "$($t[0]) search did not empty the list"
            Assert ($script:Ui["$($t[0])Empty"].Visibility -eq 'Visible') "$($t[0]) empty message hidden"
            $script:Ui[$t[1]].Text = ''
            Wait-Ui 30
            Assert (@($script:Ui[$t[2]].ItemsSource).Count -eq $all) "$($t[0]) search did not restore"
        }
    }

    Test-Case 'UI: Clean is off until something is ticked; a tick really changes the total' {
        Go-Page 'Cleanup'
        Wait-FuJob
        Wait-Ui 150
        $box = @(Find-Visuals $script:Ui.ListSafe ([Windows.Controls.CheckBox]) | Where-Object { $_.IsEnabled })[0]
        Assert $box 'no tickable row'
        $row = $box.DataContext
        $was = [bool]$row.Selected
        $box.IsChecked = (-not $was)
        Click-Ui $box
        Wait-Ui 30
        Assert ([bool]$row.Selected -ne $was) 'the tick did not reach the row'
        foreach ($r in $script:CleanRows) { $r.Selected = $false }
        Update-FuCleanTotal
        Assert (-not $script:Ui.CleanGo.IsEnabled) 'Clean enabled with nothing ticked'
        Assert ($script:Ui.CleanTotal.Text -eq 'Nothing selected') "total: $($script:Ui.CleanTotal.Text)"
    }

    Test-Case 'UI: Clean removes only the ticked test folder and reports it' {
        $d = Join-Path $tmp 'uiclean'
        New-TestFile (Join-Path $d 'junk.tmp') 2000000
        $source = New-CleanupRow 't' 'Test files (for the test)' @(New-FuPart $d) $false
        $script:CleanRows = @(ConvertTo-FuCleanRow $source $false @())
        Update-FuCleanTotal
        Assert ($script:Ui.CleanTotal.Text -match '2 MB selected') "total: $($script:Ui.CleanTotal.Text)"
        Assert ($script:Ui.CleanGo.IsEnabled) 'Clean disabled'
        $script:ConfirmAnswer = $false
        Click-Ui $script:Ui.CleanGo
        Wait-Ui 50
        Assert (Test-Path -LiteralPath (Join-Path $d 'junk.tmp')) 'cleaned although the answer was Cancel'
        $script:ConfirmAnswer = $true
        Click-Ui $script:Ui.CleanGo
        Wait-Ui 100
        $toast = $null
        $end = (Get-Date).AddSeconds(30)
        while (-not $toast -and (Get-Date) -lt $end) {
            Wait-Ui 30
            if ($script:Ui.TaskText.Text -match 'Freed') { $toast = $script:Ui.TaskText.Text }
        }
        Assert $toast 'no result message'
        Assert ($toast -match 'Removed 1 file') "message: $toast"
        Assert (-not (Test-Path -LiteralPath (Join-Path $d 'junk.tmp'))) 'file not cleaned'
        Assert ((Get-Content -LiteralPath (Join-Path $tmp 'Logs\freeutil.log') -Raw) -match 'Cleanup: deleted 1 files') 'not logged'
        Wait-FuJob   # the re-scan that follows
    }

    Test-Case 'UI: privacy and open-app rows are never ticked, and cost an extra question' {
        $d = Join-Path $tmp 'uipriv'
        New-TestFile (Join-Path $d 'History') 100
        $priv = New-CleanupRow 'p' 'Test history (privacy)' @(New-FuPart $d) $false $false 'Files' @() $true
        $open = New-CleanupRow 'o' 'Test App cache' @(New-FuPart $d) $false $true 'Files' @('powershell')
        $locked = New-CleanupRow 'l' 'Windows thing' @(New-FuPart $d) $true $true
        $rows = @(ConvertTo-FuCleanRow $priv $false @('powershell')), @(ConvertTo-FuCleanRow $open $false @('powershell')), @(ConvertTo-FuCleanRow $locked $false @())
        Assert (-not $rows[0][0].Selected -and $rows[0][0].Section -eq 'Privacy') 'privacy row ticked'
        Assert (-not $rows[1][0].Selected -and $rows[1][0].TagText -eq 'Open') 'open-app row ticked'
        Assert (-not $rows[2][0].CanClean -and $rows[2][0].Section -eq 'Admin') 'locked row can be ticked'
        $rows[0][0].Selected = $true
        $script:CleanRows = @($rows[0][0])
        $script:Infos.Clear()
        $script:ConfirmAnswer = $false
        Start-FuCleanSelected
        Assert (($script:Infos -join ' ') -match 'signs you out') "no privacy warning: $($script:Infos -join ' | ')"
        $script:ConfirmAnswer = $true
        Assert (Test-Path -LiteralPath (Join-Path $d 'History')) 'privacy item cleaned after Cancel'
    }

    Test-Case 'UI: Clean Now runs one-click cleanup and shows what it freed' {
        function Invoke-AutoClean([string]$Reason) { [pscustomobject]@{ FreedMB = 2048; Deleted = 40; Skipped = 2; Items = 3; LeftForOpenPrograms = @() } }
        function Get-CleanupTargets { }   # the re-scan afterwards finds nothing
        Go-Page 'Home'
        $script:Ui.HeroClean.Visibility = 'Visible'
        $script:ConfirmAnswer = $false
        Click-Ui $script:Ui.HeroClean
        Assert (-not $script:Tasks.Count) 'started although the answer was Cancel'
        $script:ConfirmAnswer = $true
        Click-Ui $script:Ui.HeroClean
        Wait-FuJob
        Assert ($script:Ui.HeroKicker.Text -eq 'All done') "kicker: $($script:Ui.HeroKicker.Text)"
        Assert ($script:Ui.HeroBig.Text -eq '2.0 GB') "big: $($script:Ui.HeroBig.Text)"
        Assert ($script:Ui.HeroSub.Text -match '40 files removed, 2 in use') "sub: $($script:Ui.HeroSub.Text)"
    }

    Test-Case 'UI: hero says All tidy when nothing is worth cleaning, and names open apps' {
        $script:CleanRows = @()
        Update-FuHeroFromScan
        Assert ($script:Ui.HeroBig.Text -eq 'All tidy') "big: $($script:Ui.HeroBig.Text)"
        Assert ($script:Ui.HeroClean.Visibility -ne 'Visible') 'Clean Now offered with nothing to clean'
        $source = [pscustomobject]@{ Target = 'Brave cache'; Bytes = 900MB; Files = 10; Recommended = $true; NeedsAdmin = $false; Privacy = $false; Process = @('brave'); Kind = 'Files' }
        $script:CleanRows = @(ConvertTo-FuCleanRow $source $false @('brave'))
        Update-FuHeroFromScan
        Assert ($script:Ui.HeroSub.Text -match 'Close Brave to clean 900 MB more') "sub: $($script:Ui.HeroSub.Text)"
    }

    Test-Case 'UI: a task can be cancelled at once, and two changes cannot run together' {
        Start-FuWork 'Sleeping' { Start-Sleep -Seconds 60 } -Exclusive -OnDone { throw 'should not finish' }
        Wait-Ui 200
        Assert ($script:Ui.TaskPill.Visibility -eq 'Visible') 'no status pill'
        $script:Infos.Clear()
        Start-FuWork 'Second' { 1 } -Exclusive
        Assert (($script:Infos -join ' ') -match 'still running') 'second change was allowed'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Click-Ui $script:Ui.TaskCancel
        Wait-FuJob 10
        Assert ($sw.Elapsed.TotalSeconds -lt 5) "took $($sw.Elapsed.TotalSeconds)s"
        Assert ($script:Ui.TaskText.Text -eq 'Cancelled') "status: $($script:Ui.TaskText.Text)"
    }

    Test-Case 'UI: a failed task explains itself; a quiet one stays quiet' {
        $script:Infos.Clear()
        Start-FuWork 'Testing' { throw 'boom' }
        Wait-FuJob
        Assert (($script:Infos -join ' ') -match 'boom') "message: $($script:Infos -join ' | ')"
        $script:Infos.Clear()
        Start-FuWork 'Testing' { throw 'boom' } -Quiet
        Wait-FuJob
        Assert ($script:Infos.Count -eq 0) 'quiet task spoke'
    }

    Test-Case 'UI: Duplicates finds the test copy; selecting it enables the button' {
        $d = Join-Path $tmp 'uidups'
        New-TestFile (Join-Path $d 'one.bin') 1200000 3
        New-TestFile (Join-Path $d 'two.bin') 1200000 3
        Go-Page 'Dup'
        $script:Ui.DupPath.Text = $d
        Click-Ui $script:Ui.DupFind
        Wait-FuJob
        Assert (@($script:DupRows).Count -eq 1) "rows: $(@($script:DupRows).Count)"
        Assert (-not $script:Ui.DupBin.IsEnabled) 'bin button on with nothing selected'
        $script:Ui.DupList.SelectedIndex = 0
        Wait-Ui 30
        Assert ($script:Ui.DupBin.IsEnabled) 'bin button off with a row selected'
        $script:Infos.Clear()
        $script:Ui.DupPath.Text = Join-Path $tmp 'nope'
        Click-Ui $script:Ui.DupFind
        Assert (($script:Infos -join ' ') -match "doesn't exist") 'bad folder accepted'
    }

    Test-Case 'UI: Large Files fills the list' {
        Go-Page 'Large'
        $script:Ui.LargePath.Text = Join-Path $tmp 'large'
        Click-Ui $script:Ui.LargeFind
        Wait-FuJob
        Assert (@($script:LargeRows).Count -eq 2) "rows: $(@($script:LargeRows).Count)"
        Assert ($script:LargeRows[0].Title -eq 'big.bin') "first: $($script:LargeRows[0].Title)"
        $script:Ui.LargeList.SelectedIndex = 0
        Wait-Ui 30
        Assert ($script:Ui.LargeReveal.IsEnabled -and $script:Ui.LargeBin.IsEnabled) 'buttons off with a row selected'
    }

    Test-Case 'UI: Startup switch applies, puts itself back when refused, and protects antivirus' {
        try {
            $locs = New-TestStartupLocations
            function Get-StartupEntries { }
            Go-Page 'Startup'
            Update-FuStartupRows @(& (Get-Command Get-StartupEntries -CommandType Function) ) # empty first: no real entries in this test
            $real = ${function:Get-StartupEntries}
            $entries = @($locs | ForEach-Object { $_ })  # keep PowerShell from unrolling the tables
            Remove-Item Function:\Get-StartupEntries
            Update-FuStartupRows @(Get-StartupEntries -Locations $entries -NoTasks)
            Wait-Ui 150
            $row = $script:StartupRows | Where-Object { $_.Name -eq 'Fake App' }
            Assert ($row.IsOn) 'not on at the start'
            $av = $script:StartupRows | Where-Object { $_.Name -eq 'Norton Fake' }
            Assert (-not $av.CanChange -and $av.TagText -eq 'Protected') 'antivirus switch is not locked'
            $toggles = @(Find-Visuals $script:Ui.StartupList ([Windows.Controls.Primitives.ToggleButton]))
            $t = $toggles | Where-Object { $_.DataContext.Name -eq 'Fake App' }
            Assert $t 'no switch for the row'
            $t.IsChecked = $false
            Click-Ui $t
            Wait-Ui 30
            $flag = (Get-Item -LiteralPath $row.Entry.ApprovedKey).GetValue('Fake App')
            Assert ($flag[0] -eq 3) 'flag not set off'
            Assert (-not $row.IsOn) 'row not updated'
            Assert ($script:Ui.TaskText.Text -match "won't start") "toast: $($script:Ui.TaskText.Text)"
            $t.IsChecked = $true
            Click-Ui $t
            Wait-Ui 30
            Assert ((Get-Item -LiteralPath $row.Entry.ApprovedKey).GetValue('Fake App')[0] -eq 2) 'flag not set on'
            if (-not (Test-FuAdmin)) {
                # An all-users entry without admin rights: the question is refused, so the switch goes back
                $row.Entry.Scope = 'All users'
                $script:ConfirmAnswer = $false
                $t.IsChecked = $false
                Click-Ui $t
                Wait-Ui 30
                $script:ConfirmAnswer = $true
                Assert ([bool]$t.IsChecked) 'switch did not go back'
                Assert ((Get-Item -LiteralPath $row.Entry.ApprovedKey).GetValue('Fake App')[0] -eq 2) 'entry changed without rights'
            }
        } finally {
            Remove-Item -Path 'HKCU:\Software\MakatoolsTest' -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'UI: End Process refuses antivirus; Services enable the right button' {
        Go-Page 'Proc'
        Wait-FuJob
        $script:ProcRows = @([pscustomobject]@{ Name = 'NortonSvc'; Id = -1; Path = 'C:\Program Files\Norton\x.exe'; Threads = 1; MemoryText = '1 MB'; MemoryShare = 1 })
        Update-FuProcFilter
        $script:Ui.ProcList.SelectedIndex = 0
        Wait-Ui 30
        $script:Infos.Clear()
        Click-Ui $script:Ui.ProcEnd
        Assert (($script:Infos -join ' ') -match 'antivirus') "message: $($script:Infos -join ' | ')"
        Go-Page 'Svc'
        Wait-FuJob
        $script:Ui.SvcSearch.Text = ''
        $r = @($script:SvcRows | Where-Object { $_.Status -eq 'Running' })[0]
        $script:Ui.SvcList.SelectedItem = $r
        Wait-Ui 30
        Assert ($script:Ui.SvcStop.IsEnabled -and -not $script:Ui.SvcStart.IsEnabled) 'wrong buttons for a running service'
    }

    Test-Case 'UI: Recover opens, Disk Health fills, Log shows changes' {
        Go-Page 'Recover'
        Wait-FuJob
        $script:Ui.RecoverSearch.Text = 'no-such-file-xyz'
        Wait-Ui 30
        Assert (@($script:Ui.RecoverList.ItemsSource).Count -eq 0) 'search did not filter'
        Assert ($script:Ui.RecoverEmpty.Visibility -eq 'Visible') 'empty message hidden'
        $script:Ui.RecoverSearch.Text = ''
        Go-Page 'Disk'
        Wait-FuJob
        Assert (@($script:Ui.DiskList.ItemsSource).Count -ge 1) 'no disk cards'
        Assert ($script:Ui.VolumePick.Children.Count -ge 1) 'no drives to pick'
        Assert (Get-FuPickedVolume) 'no drive picked'
        Go-Page 'Log'
        Assert (@($script:Ui.LogList.ItemsSource).Count -ge 1) 'log empty'
        Assert ($script:Ui.LogList.ItemsSource[0].When -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') "when: $($script:Ui.LogList.ItemsSource[0].When)"
    }

    Test-Case 'UI: Secure Delete asks first, then shreds the chosen file' {
        $f = Join-Path $tmp 'uishred\x.txt'
        New-TestFile $f 100
        Go-Page 'Shred'
        Assert (-not $script:Ui.ShredGo.IsEnabled) 'delete button on with no file'
        Set-FuShredFile $f
        Assert ($script:Ui.ShredGo.IsEnabled -and $script:Ui.ShredName.Text -eq 'x.txt') 'file not shown'
        $script:ConfirmAnswer = $false
        Click-Ui $script:Ui.ShredGo
        Wait-Ui 50
        Assert (Test-Path -LiteralPath $f) 'shredded although the answer was Cancel'
        $script:ConfirmAnswer = $true
        Click-Ui $script:Ui.ShredGo
        Wait-FuJob
        Assert (-not (Test-Path -LiteralPath $f)) 'file still there'
        Assert (-not $script:Ui.ShredGo.IsEnabled -and $script:Ui.ShredName.Text -eq 'Drop a file here') 'page not reset'
        Assert ($script:Ui.TaskText.Text -match 'overwritten and deleted') "toast: $($script:Ui.TaskText.Text)"
    }

    Test-Case 'UI: Settings changes the theme live and remembers it' {
        Go-Page 'Settings'
        $light = (Get-FuBrush 'Page').Color
        $script:Ui.ThemeDark.IsChecked = $true
        Click-Ui $script:Ui.ThemeDark
        Wait-Ui 30
        Assert ((Get-FuSettings).Appearance -eq 'Dark') 'not saved'
        Assert ((Get-FuBrush 'Page').Color.ToString() -eq '#FF1C1C1E') "page colour: $((Get-FuBrush 'Page').Color)"
        $script:Ui.ThemeLight.IsChecked = $true
        Click-Ui $script:Ui.ThemeLight
        Wait-Ui 30
        Assert ((Get-FuBrush 'Page').Color.ToString() -eq '#FFF5F5F7') 'light theme not back'
        $script:Ui.ReminderSwitch.IsChecked = $false
        Click-Ui $script:Ui.ReminderSwitch
        Assert ((Get-FuSettings).WeeklyReminder -eq $false) 'reminder not saved'
        $script:Ui.ReminderSwitch.IsChecked = $true
        Click-Ui $script:Ui.ReminderSwitch
        Assert ($script:Ui.AboutVersion.Text -match [regex]::Escape((Get-FuVersion))) 'version not shown'
    }

    Test-Case 'UI: the real in-window dialog answers Yes, No and Escape' {
        foreach ($case in @(@('SheetYes', $true), @('SheetNo', $false))) {
            $script:SheetTest = $case[0]
            $t = New-Object Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromMilliseconds(150)
            $t.Add_Tick({ param($s) $s.Stop(); Click-Ui $script:Ui[$script:SheetTest] })
            $t.Start()
            $answer = Show-FuSheet -Title 'Test' -Text 'Body' -Yes 'Yes' -No 'No' -Kind 'danger'
            Assert ($answer -eq $case[1]) "$($case[0]) gave $answer"
            Assert ($script:Ui.Sheet.Visibility -ne 'Visible') 'dialog still showing'
        }
        Assert (-not $script:Ui.SheetYes.IsDefault) 'Enter would confirm a destructive question'
    }

    Test-Case 'UI: update check - not set up, offline (quiet and manual), up to date' {
        function Get-FuUpdateRepo { '' }
        $script:Infos.Clear()
        Click-Ui $script:Ui.SettingsUpdate
        Assert (($script:Infos -join ' ') -match 'not set up') "not set up: $($script:Infos -join ' ')"

        function Get-FuUpdateRepo { 'example/repo' }
        function Find-FuUpdate { throw 'No such host is known.' }
        $script:Infos.Clear()
        Start-FuUpdateCheck $true
        Wait-FuJob
        Assert ($script:Infos.Count -eq 0) "quiet check spoke: $($script:Infos -join ' ')"
        Click-Ui $script:Ui.SettingsUpdate
        Wait-FuJob
        Assert (($script:Infos -join ' ') -match "Couldn't check for updates") "manual offline: $($script:Infos -join ' ')"

        function Find-FuUpdate { $null }
        $script:Infos.Clear()
        Click-Ui $script:Ui.SettingsUpdate
        Wait-FuJob
        Assert (($script:Infos -join ' ') -match 'up to date') "up to date: $($script:Infos -join ' ')"
    }

    Test-Case 'UI: a new version shows the button and asks; a blocked update offers the download page' {
        $script:Sheets = New-Object System.Collections.ArrayList
        $script:SheetAnswer = $false
        function Show-FuSheet { param($Title, $Text, $Yes, $No, $Kind) [void]$script:Sheets.Add($Title); return $script:SheetAnswer }
        function Get-FuUpdateRepo { 'example/repo' }
        function Find-FuUpdate { [pscustomobject]@{ Version = '9.9.9'; Url = 'x'; Sha256 = 'x'; Notes = 'New things'; Page = 'x' } }
        Start-FuUpdateCheck $true
        Wait-FuJob
        Assert ($script:Ui.UpdateChip.Visibility -eq 'Visible') 'no update button'
        Assert ([string]$script:Ui.UpdateChip.Content -match '9\.9\.9') "button: $($script:Ui.UpdateChip.Content)"
        Assert (($script:Sheets -join ' ') -match '9\.9\.9 is ready') "asked: $($script:Sheets -join ' | ')"
        Assert (-not $script:Tasks.Count) 'downloaded although the answer was Later'

        # Update Now, but antivirus removed the download: the app stays open and offers the page
        function Save-FuUpdate($Update, $Folder) { Join-Path $Folder 'gone.exe' }
        $script:Sheets.Clear()
        $script:SheetAnswer = $true
        Confirm-FuUpdate ([pscustomobject]@{ Version = '9.9.9'; Url = 'x'; Sha256 = 'x'; Notes = '' })
        $script:SheetAnswer = $false      # "Not now" on the fallback, so no browser opens
        Wait-FuJob
        Assert (($script:Sheets -join ' ') -match "didn't start") "fallback: $($script:Sheets -join ' | ')"
        Assert ($script:Ui.Window.IsVisible) 'window closed'
        Set-FuShown $script:Ui.UpdateChip $false
    }

    $form.Close()
}

# ---------------------------------------------------------------- done

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($ResultFile) { Stop-Transcript | Out-Null }
if ($script:Failed -gt 0) { exit 1 }
exit 0
