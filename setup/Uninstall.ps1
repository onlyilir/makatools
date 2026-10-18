# Removes Makatools: shortcuts, the Settings > Apps entry, and the install folder.
# Setup copies this file into the install folder; Settings > Apps > Makatools > Uninstall runs it.
param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
    [string]$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Makatools',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-SetupMessage($Text, $Buttons = 'OK', $Icon = 'Information') {
    # Write-Host, not Write-Output: anything written to output would become part of the return value
    if ($Quiet) { Write-Host $Text; return 'Yes' }
    # Runs from a hidden window; a top-most owner keeps the dialog in front of other windows
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    try { return [string][System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Uninstall Makatools', $Buttons, $Icon) }
    finally { $owner.Dispose() }
}

try {
    # Only ever delete a folder that really is a Makatools install
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Makatools.ps1'))) { throw "No Makatools install was found in $InstallDir." }
    $ask = "Remove Makatools from this PC?`r`n`r`nThis deletes $InstallDir, including its activity log and the .reg backups of startup entries it disabled."
    if ((Show-SetupMessage $ask 'YesNo' 'Question') -ne 'Yes') { return }

    foreach ($dir in $StartMenuDir, $DesktopDir) {
        Remove-Item -LiteralPath (Join-Path $dir 'Makatools.lnk') -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $RegKey) { Remove-Item -LiteralPath $RegKey -Recurse -Force }
    Set-Location -LiteralPath $env:TEMP   # a folder cannot be deleted while it is the current one
    Remove-Item -LiteralPath $InstallDir -Recurse -Force

    Show-SetupMessage 'Makatools was removed.' | Out-Null
} catch {
    Show-SetupMessage "Uninstall did not finish.`r`n`r`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
    exit 1
}
