# Tests Makatools-Setup.exe against temp folders and a throwaway registry key, so the real Start menu,
# Desktop and Settings > Apps are not touched. Build first (build\Build.ps1).
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Setup.ps1 [-SetupExe dist\Makatools-Setup.exe]
param([string]$SetupExe)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $SetupExe) { $SetupExe = Join-Path $repo 'dist\Makatools-Setup.exe' }
$SetupExe = (Resolve-Path -LiteralPath $SetupExe).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('makatools-setuptest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$env:MK_TEST_LINK_DIR = Join-Path $tmp 'links'
$env:MK_TEST_REG_KEY = 'Software\MakatoolsSetupTest\Makatools'
$regPath = 'HKCU:\Software\MakatoolsSetupTest\Makatools'
$dir = Join-Path $tmp 'Programs\Makatools'
$failed = 0
function Check($Condition, [string]$Name) {
    if ($Condition) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name" -ForegroundColor Red; $script:failed++ }
}
function Invoke-Setup([string[]]$Arguments, [string]$Exe = $SetupExe) {
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru
    return $p.ExitCode
}

$version = ([regex]::Match((Get-Content -LiteralPath (Join-Path $repo 'src\Core.ps1') -Raw), "Get-FuVersion \{ '([\d.]+)' \}")).Groups[1].Value

try {
    # ------------------------------------------------------------ the file itself
    $vi = (Get-Item -LiteralPath $SetupExe).VersionInfo
    Check ($vi.ProductName -eq 'Makatools' -and $vi.FileDescription -eq 'Makatools Setup' -and $vi.CompanyName -eq 'onlyilir') 'exe has file details'
    Check ($vi.FileVersion -eq "$version.0") "exe file version is $($vi.FileVersion)"
    $bytes = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($SetupExe))
    Check ($bytes -match 'level="asInvoker"') 'exe never asks for administrator rights'
    Check ($bytes -notmatch 'IExpress|wextract|WEXTRACT') 'exe is not an IExpress self-extractor'

    # ------------------------------------------------------------ install, with leftovers from 2.1 in place
    New-Item -ItemType Directory -Path (Join-Path $dir 'src'), (Join-Path $dir 'Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'Uninstall.ps1') -Value 'old'
    Set-Content -LiteralPath (Join-Path $dir 'src\OldFile.ps1') -Value 'old'
    Set-Content -LiteralPath (Join-Path $dir 'Logs\freeutil.log') -Value 'keep me'
    Set-Content -LiteralPath (Join-Path $dir 'Makatools-settings.json') -Value '{"Appearance":"Dark"}'
    $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory | Where-Object { $_.Name -like 'IXP*' }).Count

    Check ((Invoke-Setup @('--quiet', '--target', "`"$dir`"")) -eq 0) 'install exits 0'
    foreach ($f in 'Makatools.ps1', 'Makatools-Setup.exe', 'src\Core.ps1', 'src\Ui.ps1', 'src\MainWindow.xaml', 'src\Theme.xaml', 'src\Colors.Light.xaml', 'src\Colors.Dark.xaml', 'assets\Makatools.ico', 'assets\logo.png') {
        Check (Test-Path -LiteralPath (Join-Path $dir $f)) "installed $f"
    }
    Check ((Get-FileHash -LiteralPath (Join-Path $dir 'src\Ui.ps1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $repo 'src\Ui.ps1')).Hash) 'installed files match the source exactly'
    Check (-not (Test-Path -LiteralPath (Join-Path $dir 'Uninstall.ps1'))) 'old 2.1 uninstaller removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $dir 'src\OldFile.ps1'))) 'old program files removed'
    Check ((Get-Content -LiteralPath (Join-Path $dir 'Logs\freeutil.log') -Raw) -match 'keep me') 'update keeps the log'
    Check (Test-Path -LiteralPath (Join-Path $dir 'Makatools-settings.json')) 'update keeps the settings'
    Check (@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory | Where-Object { $_.Name -like 'IXP*' }).Count -eq $before) 'nothing unpacked to TEMP'

    $shell = New-Object -ComObject WScript.Shell
    foreach ($s in 'start-menu', 'desktop') {
        $lnkPath = Join-Path $env:MK_TEST_LINK_DIR "$s\Makatools.lnk"
        Check (Test-Path -LiteralPath $lnkPath) "$s shortcut exists"
        if (Test-Path -LiteralPath $lnkPath) {
            $lnk = $shell.CreateShortcut($lnkPath)
            Check ($lnk.TargetPath -like '*System32\WindowsPowerShell\v1.0\powershell.exe') "$s shortcut runs 64-bit PowerShell"
            Check ($lnk.Arguments -like "*$dir\Makatools.ps1*") "$s shortcut points at the installed app"
            Check ($lnk.IconLocation -like '*assets\Makatools.ico*') "$s shortcut uses the app icon"
        }
    }
    $reg = Get-ItemProperty -Path $regPath
    Check ($reg.DisplayName -eq 'Makatools') 'Apps entry registered'
    Check ($reg.DisplayVersion -eq $version) "Apps entry shows version $($reg.DisplayVersion)"
    Check ($reg.UninstallString -like '*Makatools-Setup.exe*--uninstall*') 'Apps entry uninstalls with the kept exe'

    # The installed copy must load (Core + Ui) without errors
    $ErrorActionPreference = 'Continue'
    $run = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Makatools.ps1') -NoGui 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check ($code -eq 0 -and -not $run) "installed app loads ($($run -join ' '))"

    # ------------------------------------------------------------ uninstall
    $other = Join-Path $tmp 'not-makatools'
    New-Item -ItemType Directory -Path $other | Out-Null
    Set-Content -LiteralPath (Join-Path $other 'precious.txt') -Value 'x'
    Check ((Invoke-Setup @('--uninstall', '--quiet', '--target', "`"$other`"")) -ne 0) 'uninstall refuses a folder that is not Makatools'
    Check (Test-Path -LiteralPath (Join-Path $other 'precious.txt')) 'that folder is untouched'

    Check ((Invoke-Setup @('--uninstall', '--quiet', '--target', "`"$dir`"") (Join-Path $dir 'Makatools-Setup.exe')) -eq 0) 'uninstall (from the kept exe) exits 0'
    $end = (Get-Date).AddSeconds(20)
    while ((Test-Path -LiteralPath $dir) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 300 }
    Check (-not (Test-Path -LiteralPath $dir)) 'install folder removed, including the running exe'
    Check (-not (Test-Path -LiteralPath (Join-Path $env:MK_TEST_LINK_DIR 'desktop\Makatools.lnk'))) 'Desktop shortcut removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $env:MK_TEST_LINK_DIR 'start-menu\Makatools.lnk'))) 'Start menu shortcut removed'
    Check (-not (Test-Path -LiteralPath $regPath)) 'Apps entry removed'
} finally {
    Remove-Item -LiteralPath 'HKCU:\Software\MakatoolsSetupTest' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All setup checks passed'
exit 0
