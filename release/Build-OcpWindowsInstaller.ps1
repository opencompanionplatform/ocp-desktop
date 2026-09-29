[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$BundleDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [ValidateSet('arm64', 'x86_64')][string]$Arch = 'arm64',
    [ValidateSet('fast', 'release')][string]$CompressionProfile = 'fast',
    [string]$InnoSetupCompiler = '',
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$definition = Join-Path $releaseRoot 'windows\ocp-portable.iss'
$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$validator = Join-Path $releaseRoot 'Validate-OcpPortableBundle.ps1'
& $validator -BundleDirectory $bundle -Version $Version -Arch $Arch
$buildInfo = Get-Content -LiteralPath (Join-Path $bundle 'BUILD-INFO.json') -Raw | ConvertFrom-Json
if ([string]$buildInfo.format -ne 'portable-desktop') {
    throw "Installer requires a current portable-desktop bundle; found format '$($buildInfo.format)'."
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $releaseRoot 'out' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

foreach ($requiredPath in @(
    (Join-Path $bundle 'ocp-launcher.exe'),
    (Join-Path $bundle 'Start-OCP.ps1'),
    (Join-Path $bundle 'Apply-OcpUpdate.ps1'),
    (Join-Path $bundle 'ocp-runtime.exe'),
    (Join-Path $bundle 'ocp-runtime.pck'),
    (Join-Path $bundle 'desktop-shell\OCP.exe'),
    (Join-Path $bundle 'bin\ocp-kernel.exe'),
    (Join-Path $bundle 'bin\ocp-native-companion-window.exe')
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Portable bundle is incomplete: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler)) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $InnoSetupCompiler = $command.Source
    }
    else {
        $commonCompilerPaths = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe'
        )
        $InnoSetupCompiler = $commonCompilerPaths |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($null -eq $InnoSetupCompiler) {
            throw 'ISCC.exe was not found. Install Inno Setup or pass -InnoSetupCompiler.'
        }
    }
}
if (-not (Test-Path -LiteralPath $InnoSetupCompiler -PathType Leaf)) {
    throw "Inno Setup compiler was not found: $InnoSetupCompiler"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$innoArch = if ($Arch -eq 'arm64') { 'arm64' } else { 'x64compatible' }
$installerCompression = if ($CompressionProfile -eq 'release') { 'lzma2' } else { 'zip' }
$installerSolidCompression = if ($CompressionProfile -eq 'release') { 'yes' } else { 'no' }
Write-Host "[P1] installer compression profile=$CompressionProfile compression=$installerCompression solid=$installerSolidCompression"
& $InnoSetupCompiler "/DBundleDir=$bundle" "/DOutputDir=$OutputDirectory" "/DProductVersion=$Version" "/DOcpArch=$Arch" "/DInnoArch=$innoArch" "/DInstallerCompression=$installerCompression" "/DInstallerSolidCompression=$installerSolidCompression" $definition
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }

$installer = Join-Path $OutputDirectory "ocp-windows-$Arch-$Version-setup.exe"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Inno Setup completed but did not produce: $installer"
}
Write-Host "installerPath=$installer"
