#Requires -Version 5.1
<#
  Makatools - a free, open-source Windows maintenance toolkit for Windows 10 and 11 (64-bit).
  Launch with Start-Makatools.bat, or:
      powershell -NoProfile -ExecutionPolicy Bypass -File Makatools.ps1
  -NoGui only loads the code (used by tests).

  Layout
    src\Core.ps1   logic (no UI); unit-tested by tests\Run-Tests.ps1
    src\Ui.ps1     windows and buttons
    assets\        logo and icon
    build\         makes a single-file bundle, an .exe and the Setup installer
#>
param([switch]$NoGui)

# On 64-bit Windows, run in 64-bit PowerShell. The 32-bit one sees a redirected registry
# (WOW6432Node) and the storage cmdlets can miss disks.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $PSCommandPath) {
    $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoGui) { $relaunch += '-NoGui' }
    Start-Process -FilePath $ps64 -ArgumentList $relaunch
    return
}

if ($PSScriptRoot) { $script:AppRoot = $PSScriptRoot }
else { $script:AppRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

. (Join-Path $script:AppRoot 'src\Core.ps1')
. (Join-Path $script:AppRoot 'src\Ui.ps1')

if (-not (Test-FuSupportedOs)) {
    Show-FuInfo 'Makatools needs Windows 10 or Windows 11.' 'Error'
    return
}
if (-not $NoGui) { Show-MainForm }
