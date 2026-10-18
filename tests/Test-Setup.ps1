# Tests the installer and uninstaller against temp folders and a throwaway HKCU key, so the
# real Start menu, Desktop and Settings > Apps are not touched.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Setup.ps1 [-SetupExe dist\Makatools-Setup.exe]
# With -SetupExe, the files inside the exe are extracted and its bootstrap is tested instead.
param([string]$SetupExe)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('makatools-setuptest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$common = @(
    '-InstallDir', (Join-Path $tmp 'Programs\Makatools'),
    '-StartMenuDir', (Join-Path $tmp 'StartMenu'),
    '-DesktopDir', (Join-Path $tmp 'Desktop'),
    '-RegKey', 'HKCU:\Software\MakatoolsSetupTest\Makatools',
    '-Quiet'
)
$failed = 0
function Check($Condition, [string]$Name) {
    if ($Condition) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name" -ForegroundColor Red; $script:failed++ }
}

try {
    if ($SetupExe) {
        $x = Join-Path $tmp 'extracted'
        $p = Start-Process -FilePath (Resolve-Path -LiteralPath $SetupExe).Path -ArgumentList @("/T:$x", '/C', '/Q') -Wait -PassThru
        Check ($p.ExitCode -eq 0) "exe extracts (exit $($p.ExitCode))"
        foreach ($f in 'setup.cmd', 'Bootstrap.ps1', 'payload.zip') { Check (Test-Path -LiteralPath (Join-Path $x $f)) "exe contains $f" }
        $installer = Join-Path $x 'Bootstrap.ps1'
    } else {
        $installer = Join-Path $repo 'setup\Install.ps1'
    }

    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $installer @common
    Check ($LASTEXITCODE -eq 0) "install exits 0 ($($out -join ' '))"
    $dir = Join-Path $tmp 'Programs\Makatools'
    foreach ($f in 'Makatools.ps1', 'Uninstall.ps1', 'src\Core.ps1', 'src\Ui.ps1', 'assets\Makatools.ico', 'assets\logo.png') {
        Check (Test-Path -LiteralPath (Join-Path $dir $f)) "installed $f"
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($s in 'StartMenu', 'Desktop') {
        $lnkPath = Join-Path $tmp "$s\Makatools.lnk"
        Check (Test-Path -LiteralPath $lnkPath) "$s shortcut exists"
        if (Test-Path -LiteralPath $lnkPath) {
            $lnk = $shell.CreateShortcut($lnkPath)
            Check ($lnk.TargetPath -like '*System32\WindowsPowerShell\v1.0\powershell.exe') "$s shortcut runs 64-bit PowerShell"
            Check ($lnk.Arguments -like "*$dir\Makatools.ps1*") "$s shortcut points at installed app"
            Check ($lnk.IconLocation -like '*assets\Makatools.ico*') "$s shortcut uses the logo icon"
        }
    }
    $reg = Get-ItemProperty -Path 'HKCU:\Software\MakatoolsSetupTest\Makatools'
    Check ($reg.DisplayName -eq 'Makatools' -and $reg.UninstallString -like '*Uninstall.ps1*') 'Apps entry registered'
    Check ($reg.DisplayVersion -match '^\d+\.\d+\.\d+$') "Apps entry shows version $($reg.DisplayVersion)"

    # The installed copy must start (load Core + Ui) without errors
    $run = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Makatools.ps1') -NoGui 2>&1
    Check ($LASTEXITCODE -eq 0 -and -not $run) "installed app loads ($($run -join ' '))"

    # Reinstall over the top keeps Logs
    New-Item -ItemType Directory -Path (Join-Path $dir 'Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'Logs\freeutil.log') -Value 'keep me'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $installer @common | Out-Null
    Check (Test-Path -LiteralPath (Join-Path $dir 'Logs\freeutil.log')) 'reinstall keeps the log'

    # Uninstall refuses a folder that is not a Makatools install
    $other = Join-Path $tmp 'not-makatools'
    New-Item -ItemType Directory -Path $other | Out-Null
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Uninstall.ps1') -InstallDir $other -Quiet | Out-Null
    Check ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $other)) 'uninstall refuses a non-Makatools folder'

    $uargs = @($common | Where-Object { $_ -ne '-InstallDir' -and $_ -ne $dir })
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Uninstall.ps1') -InstallDir $dir @uargs | Out-Null
    Check ($LASTEXITCODE -eq 0) 'uninstall exits 0'
    Check (-not (Test-Path -LiteralPath $dir)) 'install folder removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $tmp 'Desktop\Makatools.lnk'))) 'Desktop shortcut removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $tmp 'StartMenu\Makatools.lnk'))) 'Start menu shortcut removed'
    Check (-not (Test-Path -LiteralPath 'HKCU:\Software\MakatoolsSetupTest\Makatools')) 'Apps entry removed'
} finally {
    Remove-Item -LiteralPath 'HKCU:\Software\MakatoolsSetupTest' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All setup checks passed'
exit 0
