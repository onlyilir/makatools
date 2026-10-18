# Runs inside Makatools-Setup.exe: unpacks payload.zip (the app and its installer) to a temp
# folder, then runs the normal installer from there. Parameters pass through to Install.ps1.
param(
    [string]$InstallDir,
    [string]$StartMenuDir,
    [string]$DesktopDir,
    [string]$RegKey,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'Makatools-Setup.log'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('makatools-setup-' + [guid]::NewGuid().ToString('N'))
$code = 1
try {
    Add-Content -LiteralPath $log -Value ('{0}  Setup.exe unpacking to {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $work) -Encoding UTF8
    Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'payload.zip') -DestinationPath $work
    & (Join-Path $work 'setup\Install.ps1') @PSBoundParameters
    $code = $LASTEXITCODE
} catch {
    # The window is hidden, so a failure here would otherwise vanish without a trace
    Add-Content -LiteralPath $log -Value ('{0}  Setup.exe FAILED: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        [void][System.Windows.Forms.MessageBox]::Show($owner, "Makatools Setup could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $log", 'Makatools Setup', 'OK', 'Error')
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
