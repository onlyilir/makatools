# Builds everything in dist\:
#   Makatools-Setup.exe   the installer: compiled here with the .NET Framework compiler that ships with
#                         Windows, with the app's files inside it and full file details
#   Makatools-<version>-portable.zip   the app without installing; run Start-Makatools.bat
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File build\Build.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null

$core = Get-Content -LiteralPath (Join-Path $root 'src\Core.ps1') -Raw
if ($core -notmatch "function Get-FuVersion \{ '(\d+\.\d+\.\d+)' \}") { throw 'Could not read the version from src\Core.ps1.' }
$version = $Matches[1]
Write-Output "Building Makatools $version"

# The files that make up the app
$appFiles = @('Makatools.ps1', 'Start-Makatools.bat', 'README.md', 'LICENSE') +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File | ForEach-Object { "src\$($_.Name)" }) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'assets') -File | ForEach-Object { "assets\$($_.Name)" })

$stage = Join-Path ([IO.Path]::GetTempPath()) ('makatools-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    # ------------------------------------------------------------ portable zip
    $folder = Join-Path $stage 'Makatools'
    foreach ($f in $appFiles) {
        $dst = Join-Path $folder $f
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $dst
    }
    $zip = Join-Path $dist "Makatools-$version-portable.zip"
    Compress-Archive -Path $folder -DestinationPath $zip
    Write-Output "Zip written: $zip"

    # ------------------------------------------------------------ Setup.exe
    # Each app file becomes a gzip resource "payload/<path>.gz"
    $resArgs = @()
    $i = 0
    foreach ($f in $appFiles) {
        $gz = Join-Path $stage ("p{0}.gz" -f $i++)
        $in = [IO.File]::OpenRead((Join-Path $root $f))
        $out = [IO.File]::Create($gz)
        $z = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionLevel]::Optimal)
        $in.CopyTo($z)
        $z.Dispose(); $out.Dispose(); $in.Dispose()
        $resArgs += ('/resource:' + $gz + ',payload/' + ($f -replace '\\', '/') + '.gz')
    }
    # The installer's own look: the app's design system
    foreach ($x in 'src\Theme.xaml', 'src\Colors.Light.xaml', 'src\Colors.Dark.xaml', 'setup\SetupWindow.xaml', 'assets\logo.png') {
        $resArgs += ('/resource:' + (Join-Path $root $x) + ',' + (Split-Path -Leaf $x))
    }

    # Version and file details are written into a copy of the source
    $src = (Get-Content -LiteralPath (Join-Path $root 'setup\Setup.cs') -Raw).
        Replace('AssemblyVersion("0.0.0.0")', "AssemblyVersion(`"$version.0`")").
        Replace('AssemblyFileVersion("0.0.0.0")', "AssemblyFileVersion(`"$version.0`")").
        Replace('Version = "0.0.0"', "Version = `"$version`"")
    $srcFile = Join-Path $stage 'Setup.cs'
    [IO.File]::WriteAllText($srcFile, $src)

    $fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
    $refs = @('WPF\PresentationFramework.dll', 'WPF\PresentationCore.dll', 'WPF\WindowsBase.dll', 'System.Xaml.dll',
              'Microsoft.CSharp.dll', 'System.Core.dll', 'System.dll') | ForEach-Object { '/reference:' + (Join-Path $fw $_) }
    $exe = Join-Path $dist 'Makatools-Setup.exe'
    $cscArgs = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001', '/warn:4', "/out:$exe",
                 ('/win32icon:' + (Join-Path $root 'assets\Makatools.ico')),
                 ('/win32manifest:' + (Join-Path $root 'setup\app.manifest'))) + $resArgs + $refs + @($srcFile)
    & (Join-Path $fw 'csc.exe') @cscArgs
    if ($LASTEXITCODE -ne 0) { throw 'The installer did not compile.' }
    Write-Output ('Setup written: {0} ({1:N0} KB)' -f $exe, ((Get-Item -LiteralPath $exe).Length / 1KB))
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
