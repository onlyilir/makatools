# Builds everything in dist\:
#   Makatools.ps1        one-file version of the app (no src folder needed), with assets\ beside it
#   Makatools.zip        the app plus "Install Makatools.bat", for sharing as a zip
#   Makatools-Setup.exe  one-file installer, made with IExpress (built into Windows, no download)
#   Makatools.exe        only with -WithAppExe: the app compiled by the ps2exe module (needs internet
#                        the first time; antivirus such as Norton often flags ps2exe output)
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File build\Build-Bundle.ps1
param([switch]$WithAppExe)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null

# ---------------------------------------------------------------- one-file bundle

$core = Get-Content -LiteralPath (Join-Path $root 'src\Core.ps1') -Raw
if ($core -notmatch "function Get-FuVersion \{ '([\d.]+)' \}") { throw 'Could not read the version from src\Core.ps1.' }
$version = $Matches[1]
Write-Output "Building Makatools $version"
$ui   = Get-Content -LiteralPath (Join-Path $root 'src\Ui.ps1') -Raw
$head = @'
param([switch]$NoGui)
# On 64-bit Windows, run in 64-bit PowerShell (see Makatools.ps1)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $PSCommandPath) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoGui) { $relaunch += '-NoGui' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $relaunch
    return
}
if ($PSScriptRoot) { $script:AppRoot = $PSScriptRoot }
else { $script:AppRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
'@
$tail = @'
if (-not (Test-FuSupportedOs)) { Show-FuInfo 'Makatools needs Windows 10 or Windows 11.' 'Error'; return }
if (-not $NoGui) { Show-MainForm }
'@
$bundle = Join-Path $dist 'Makatools.ps1'
Set-Content -LiteralPath $bundle -Value ($head + "`r`n" + $core + "`r`n" + $ui + "`r`n" + $tail) -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $root 'assets') -Destination (Join-Path $dist 'assets') -Recurse
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($bundle, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Output $_.Message }; throw 'Bundle has syntax errors.' }
Write-Output "Bundle written: $bundle"

# ---------------------------------------------------------------- zip for sharing

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('makatools-build-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $stage 'Makatools'
New-Item -ItemType Directory -Path (Join-Path $app 'setup') -Force | Out-Null
foreach ($item in 'Makatools.ps1', 'Start-Makatools.bat', 'Install Makatools.bat', 'README.md', 'src', 'assets') {
    Copy-Item -LiteralPath (Join-Path $root $item) -Destination (Join-Path $app $item) -Recurse
}
foreach ($f in 'Install.ps1', 'Uninstall.ps1') { Copy-Item -LiteralPath (Join-Path $root "setup\$f") -Destination (Join-Path $app "setup\$f") }
$zip = Join-Path $dist 'Makatools.zip'
Compress-Archive -Path $app -DestinationPath $zip
Write-Output "Zip written: $zip"

# ---------------------------------------------------------------- Setup.exe (IExpress)

$pkg = Join-Path $stage 'pkg'
New-Item -ItemType Directory -Path $pkg | Out-Null
Compress-Archive -Path (Join-Path $app '*') -DestinationPath (Join-Path $pkg 'payload.zip')
Copy-Item -LiteralPath (Join-Path $root 'setup\Bootstrap.ps1') -Destination (Join-Path $pkg 'Bootstrap.ps1')
Set-Content -LiteralPath (Join-Path $pkg 'setup.cmd') -Encoding ASCII -Value @'
@echo off
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Bootstrap.ps1"
'@
# IExpress is happier with a target path that has no spaces; the result is copied to dist afterwards
$exeTmp = Join-Path $stage 'Makatools-Setup.exe'
$sed = Join-Path $stage 'setup.sed'
Set-Content -LiteralPath $sed -Encoding ASCII -Value @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$exeTmp
FriendlyName=Makatools Setup
AppLaunched=cmd.exe /c setup.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
FILE0="setup.cmd"
FILE1="Bootstrap.ps1"
FILE2="payload.zip"
[SourceFiles]
SourceFiles0=$pkg\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
"@
$p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\iexpress.exe') -ArgumentList @('/N', '/Q', '/M', $sed) -Wait -PassThru -WindowStyle Hidden
if (-not (Test-Path -LiteralPath $exeTmp)) { throw "IExpress did not produce the setup exe (exit code $($p.ExitCode))." }
Copy-Item -LiteralPath $exeTmp -Destination (Join-Path $dist 'Makatools-Setup.exe')
Write-Output "Setup written: $(Join-Path $dist 'Makatools-Setup.exe')"
Remove-Item -LiteralPath $stage -Recurse -Force

# ---------------------------------------------------------------- optional app exe (ps2exe)

if ($WithAppExe) {
    if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
        try {
            Install-Module -Name ps2exe -Scope CurrentUser -Force -ErrorAction Stop
            Import-Module ps2exe -ErrorAction Stop
        } catch {
            Write-Output "Skipping Makatools.exe: could not install ps2exe ($($_.Exception.Message))."
            return
        }
    }
    Invoke-ps2exe -inputFile $bundle -outputFile (Join-Path $dist 'Makatools.exe') -iconFile (Join-Path $root 'assets\Makatools.ico') `
        -title 'Makatools' -product 'Makatools' -version ($version + '.0') -noConsole -x64
    Write-Output "Exe written: $(Join-Path $dist 'Makatools.exe')"
}
