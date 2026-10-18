# Publishes a new version to GitHub, so every installed Makatools offers it as an update.
# Before running: raise the number in Get-FuVersion (src\Core.ps1) and commit your changes.
#   powershell -ExecutionPolicy Bypass -File build\Publish-Release.ps1 [-Notes "What changed"] [-DryRun]
# It refuses to publish unless the working tree is clean, the version is new, and every test passes.
# -DryRun does all the checks and the build, but uploads nothing.
param([string]$Notes = '', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$gh = 'C:\Program Files\GitHub CLI\gh.exe'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Runs git or gh and returns their exit code. Windows PowerShell 5.1 turns anything a program
# writes to stderr (git's progress, gh's "release not found") into an error that 'Stop' would
# treat as a crash, so these calls run with errors allowed and are judged by the exit code alone.
function Invoke-Tool {
    $ErrorActionPreference = 'Continue'
    $exe = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    & $exe @rest 2>&1 | ForEach-Object { "  $_" } | Write-Verbose
    return $LASTEXITCODE
}

$core = Get-Content -LiteralPath 'src\Core.ps1' -Raw
if ($core -notmatch "function Get-FuVersion \{ '([\d.]+)' \}") { throw 'Could not read the version from src\Core.ps1.' }
$version = $Matches[1]
$tag = "v$version"
if ($core -notmatch "function Get-FuUpdateRepo \{ '([^']+)' \}") { throw 'Get-FuUpdateRepo is empty, so installed copies would never see this release.' }
$repo = $Matches[1]
Write-Output "Release $tag to $repo$(if ($DryRun) { ' (dry run)' })"

if (git status --porcelain) { throw 'There are uncommitted changes. Commit them first, so the release matches the code on GitHub.' }
if (git tag --list $tag) { throw "Tag $tag already exists. Raise the version in Get-FuVersion first." }
if ((Invoke-Tool $gh release view $tag --repo $repo) -eq 0) { throw "Release $tag already exists on GitHub." }

Write-Output 'Running tests...'
& $ps -NoProfile -ExecutionPolicy Bypass -File 'tests\Run-Tests.ps1' | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { throw 'Tests failed. Nothing was published.' }
Write-Output 'Building...'
& $ps -NoProfile -ExecutionPolicy Bypass -File 'build\Build-Bundle.ps1' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Build failed. Nothing was published.' }
& $ps -NoProfile -ExecutionPolicy Bypass -File 'tests\Test-Setup.ps1' -SetupExe 'dist\Makatools-Setup.exe' | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { throw 'The built Setup.exe failed its install tests. Nothing was published.' }

if ($DryRun) { Write-Output "Dry run finished: $tag would be published with dist\Makatools-Setup.exe and dist\Makatools.zip."; return }

if (-not $Notes) { $Notes = "Makatools $version. Install or update by running Makatools-Setup.exe. Installed copies offer this update automatically." }
if ((Invoke-Tool git push origin HEAD) -ne 0) { throw 'Could not push the code to GitHub. Nothing was published.' }
if ((Invoke-Tool $gh release create $tag 'dist\Makatools-Setup.exe' 'dist\Makatools.zip' --repo $repo --title "Makatools $version" --notes $Notes --latest) -ne 0) { throw 'GitHub refused the release.' }
[void](Invoke-Tool git fetch --tags)
Write-Output "Published https://github.com/$repo/releases/tag/$tag"
