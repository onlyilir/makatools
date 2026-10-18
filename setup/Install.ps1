# Makatools Setup. Installs for the current Windows account, no administrator rights needed:
#   - copies the app to %LOCALAPPDATA%\Programs\Makatools
#   - adds Start menu and Desktop shortcuts with the Makatools icon
#   - registers it in Settings > Apps, so it can be uninstalled from there
# Run it with "Install Makatools.bat". The parameters exist so tests can install into a temp folder.
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\Makatools'),
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
    [string]$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Makatools',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$source = Split-Path -Parent $PSScriptRoot
# The version is read from the app itself so it is only written in one place
$version = '?'
if ((Get-Content -LiteralPath (Join-Path $source 'src\Core.ps1') -Raw -ErrorAction SilentlyContinue) -match "function Get-FuVersion \{ '([\d.]+)' \}") { $version = $Matches[1] }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Setup runs from a hidden window, and Windows would open its dialogs behind other windows.
# A top-most owner keeps them in front.
function Show-SetupMessage($Text, $Buttons = 'OK', $Icon = 'Information') {
    # Write-Host, not Write-Output: anything written to output would become part of the return value
    if ($Quiet) { Write-Host $Text; return 'Yes' }
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    try { return [string][System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Makatools Setup', $Buttons, $Icon) }
    finally { $owner.Dispose() }
}

# What setup did, for when something goes wrong on another PC: %TEMP%\Makatools-Setup.log
function Write-SetupLog([string]$Message) {
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'Makatools-Setup.log') -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}

try {
    Write-SetupLog "Install $version started from $source (64-bit: $([Environment]::Is64BitProcess))"
    if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Makatools needs Windows 10 or Windows 11.' }
    $ask = "Install Makatools $version?`r`n`r`nFolder: $InstallDir`r`nShortcuts: Start menu and Desktop`r`n`r`nNo administrator rights are needed."
    $answer = Show-SetupMessage $ask 'YesNo' 'Question'
    Write-SetupLog "Install question answered: $answer"
    if ($answer -ne 'Yes') { return }

    # Copy the app. An older version is replaced; its Logs and Backups folders are kept.
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    foreach ($item in 'Makatools.ps1', 'Start-Makatools.bat', 'README.md', 'src', 'assets') {
        $from = Join-Path $source $item
        if (-not (Test-Path -LiteralPath $from)) { throw "The setup files are incomplete ($item is missing). Extract the whole zip, then run Install Makatools.bat again." }
        $to = Join-Path $InstallDir $item
        if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination (Join-Path $InstallDir 'Uninstall.ps1') -Force
    # Files from a downloaded zip carry a "came from the internet" mark; clear it on the installed copy
    Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Unblock-File

    # Shortcuts start 64-bit PowerShell with the window hidden, so only the Makatools window shows
    $icon = Join-Path $InstallDir 'assets\Makatools.ico'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in $StartMenuDir, $DesktopDir) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lnk = $shell.CreateShortcut((Join-Path $dir 'Makatools.lnk'))
        $lnk.TargetPath = $ps
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallDir 'Makatools.ps1')
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation = "$icon,0"
        $lnk.Description = 'Makatools - free Windows maintenance toolkit'
        $lnk.Save()
    }

    # Entry in Settings > Apps (and Control Panel > Programs)
    $kb = [int]((Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
    New-Item -Path $RegKey -Force | Out-Null
    $strings = @{
        DisplayName     = 'Makatools'
        DisplayVersion  = $version
        Publisher       = 'Makatools (free, open source)'
        DisplayIcon     = $icon
        InstallLocation = $InstallDir
        UninstallString = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $ps, (Join-Path $InstallDir 'Uninstall.ps1')
    }
    foreach ($k in $strings.Keys) { New-ItemProperty -Path $RegKey -Name $k -Value $strings[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $RegKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $RegKey -Name 'EstimatedSize' -Value $kb -PropertyType DWord -Force | Out-Null

    Write-SetupLog "Installed to $InstallDir"
    if ($Quiet) { Write-Host "Installed to $InstallDir"; return }
    if ((Show-SetupMessage "Makatools is installed.`r`n`r`nYou can open it from the Desktop or the Start menu. Open it now?" 'YesNo') -eq 'Yes') {
        Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f (Join-Path $InstallDir 'Makatools.ps1'))) -WorkingDirectory $InstallDir
    }
} catch {
    Write-SetupLog "FAILED: $($_.Exception.Message)"
    Show-SetupMessage "Setup did not finish.`r`n`r`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
    exit 1
}
