#Requires -Version 5.1
<#
  Makatools - a free, open-source Windows maintenance toolkit for Windows 10 and 11 (64-bit).
  Installed copies start from the Start menu or Desktop shortcut. Otherwise use Start-Makatools.bat, or:
      powershell -NoProfile -ExecutionPolicy Bypass -File Makatools.ps1
  -NoGui only loads the code (used by tests).

  Layout
    src\Core.ps1          logic (no UI); tested by tests\Run-Tests.ps1
    src\Ui.ps1            connects the window to the logic
    src\MainWindow.xaml   the window (WPF); Theme.xaml and Colors.*.xaml are the design system
    setup\                the installer, compiled into Makatools-Setup.exe by build\Build.ps1
#>
param([switch]$NoGui)

# On 64-bit Windows, run in 64-bit PowerShell. The 32-bit one sees a redirected registry
# (WOW6432Node) and the storage cmdlets can miss disks.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $PSCommandPath) {
    $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    if ($NoGui) { $relaunch += '-NoGui' }
    Start-Process -FilePath $ps64 -ArgumentList $relaunch
    return
}

$script:AppRoot = $PSScriptRoot

. (Join-Path $script:AppRoot 'src\Core.ps1')
. (Join-Path $script:AppRoot 'src\Ui.ps1')

if ($NoGui) { return }

# One window only: opening Makatools again brings the running one to the front
$created = $false
$script:OneWindow = New-Object System.Threading.Mutex($true, 'Local\Makatools.App', [ref]$created)
if (-not $created) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    try { [Microsoft.VisualBasic.Interaction]::AppActivate('Makatools') } catch { }
    return
}

if (-not (Test-FuSupportedOs)) {
    [void][Windows.MessageBox]::Show('Makatools needs Windows 10 or Windows 11.', 'Makatools', 'OK', 'Error')
    return
}
Show-MainForm
