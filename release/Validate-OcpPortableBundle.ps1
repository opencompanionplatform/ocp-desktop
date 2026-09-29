[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$BundleDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [ValidateSet('arm64', 'x86_64')][string]$Arch = 'arm64',
    [switch]$RequirePublishable,
    [switch]$CheckSbom,
    [string]$SbomDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$requiredFiles = @(
    'BUILD-INFO.json',
    'THIRD-PARTY-NOTICES.txt',
    'ocp-launcher.exe',
    'Start-OCP.ps1',
    'Apply-OcpUpdate.ps1',
    'ocp-runtime.exe',
    'ocp-runtime.pck',
    'fonts\NotoSansThai-VF.ttf',
    'fonts\OFL-NotoSansThai.txt',
    'starter\character.bible-1.0.0.ocp',
    'starter\effect.starter-neon-1.0.0.ocp',
    'bin\ocp-kernel.exe',
    'bin\ocp-native-companion-window.exe',
    'bin\ocp-release-check.exe',
    "bin\windows\$Arch\ocp_desktop_runtime_ext.dll"
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $bundle $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Portable bundle is missing: $relative"
    }
}

$buildInfo = Get-Content -LiteralPath (Join-Path $bundle 'BUILD-INFO.json') -Raw | ConvertFrom-Json
if ($buildInfo.format -eq 'portable-desktop') {
    $desktopShellExe = Join-Path $bundle 'desktop-shell\OCP.exe'
    if (-not (Test-Path -LiteralPath $desktopShellExe -PathType Leaf)) {
        throw 'Portable desktop bundle is missing: desktop-shell\OCP.exe'
    }
    $starterRelative = [string]$buildInfo.embeddedStarter
    if ($starterRelative -ne 'starter/character.bible-1.0.0.ocp') {
        throw "Portable desktop bundle has invalid embeddedStarter: $starterRelative"
    }
    $starterPath = Join-Path $bundle ($starterRelative -replace '/', '\\')
    $starterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $starterPath).Hash.ToLowerInvariant()
    $expectedStarterHash = [string]$buildInfo.embeddedStarterSha256
    if ([string]::IsNullOrWhiteSpace($expectedStarterHash) -or $starterHash -ne $expectedStarterHash.ToLowerInvariant()) {
        throw "Embedded Bible starter hash mismatch: expected=$expectedStarterHash actual=$starterHash"
    }
    $effectStarterRelative = [string]$buildInfo.embeddedEffectStarter
    if ($effectStarterRelative -ne 'starter/effect.starter-neon-1.0.0.ocp') {
        throw "Portable desktop bundle has invalid embeddedEffectStarter: $effectStarterRelative"
    }
    $effectStarterPath = Join-Path $bundle ($effectStarterRelative -replace '/', '\\')
    $effectStarterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $effectStarterPath).Hash.ToLowerInvariant()
    $expectedEffectStarterHash = [string]$buildInfo.embeddedEffectStarterSha256
    if ([string]::IsNullOrWhiteSpace($expectedEffectStarterHash) -or $effectStarterHash -ne $expectedEffectStarterHash.ToLowerInvariant()) {
        throw "Embedded Starter FX hash mismatch: expected=$expectedEffectStarterHash actual=$effectStarterHash"
    }
    $storeOrigin = [string]$buildInfo.storeOrigin
    $storeUri = $null
    if ([string]::IsNullOrWhiteSpace($storeOrigin) -or -not [System.Uri]::TryCreate($storeOrigin, [System.UriKind]::Absolute, [ref]$storeUri) -or $storeUri.Scheme -ne 'https' -or $storeUri.AbsolutePath -ne '/') {
        throw "Portable desktop bundle has invalid BUILD-INFO storeOrigin: $storeOrigin"
    }

    $pckModeProperty = $buildInfo.PSObject.Properties['pckMode']
    if ($null -ne $pckModeProperty) {
        $pckMode = [string]$pckModeProperty.Value
        switch ($pckMode) {
            'editor-export' {
                if ($buildInfo.PSObject.Properties['publishable'] -and $buildInfo.publishable -ne $true) {
                    throw 'Editor-export bundle must not be marked publishable=false.'
                }
                if ($buildInfo.PSObject.Properties['pckContentVerified'] -and $buildInfo.pckContentVerified -ne $true) {
                    throw 'Editor-export bundle must not be marked pckContentVerified=false.'
                }
            }
            'source-fallback-local' {
                if ($Version -notmatch '-local\.') {
                    throw "Raw-source PCK fallback is forbidden for publishable version: $Version"
                }
                if (-not $buildInfo.PSObject.Properties['publishable'] -or $buildInfo.publishable -ne $false) {
                    throw 'Local source-fallback bundle must be marked publishable=false.'
                }
                if ($buildInfo.PSObject.Properties['pckContentVerified'] -and $buildInfo.pckContentVerified -ne $false) {
                    throw 'Local source-fallback bundle must be marked pckContentVerified=false.'
                }
                Write-Warning 'LOCAL-ONLY source PCK detected. This bundle is valid for installer/cold-start acceptance but must not be published.'
            }
            default { throw "Unsupported BUILD-INFO pckMode: $pckMode" }
        }
    }
    else {
        Write-Warning 'Legacy portable-desktop bundle has no pckMode marker; current builders must emit one.'
    }

    if ($RequirePublishable) {
        if ($Version -match '-local\.') {
            throw "Publishable validation rejects local-only version: $Version"
        }
        $pckModeProperty = $buildInfo.PSObject.Properties['pckMode']
        $publishableProperty = $buildInfo.PSObject.Properties['publishable']
        if ($null -eq $pckModeProperty -or [string]$pckModeProperty.Value -ne 'editor-export') {
            throw 'Publishable validation requires pckMode=editor-export.'
        }
        if ($null -eq $publishableProperty -or $publishableProperty.Value -ne $true) {
            throw 'Publishable validation requires publishable=true.'
        }
        $pckVerifiedProperty = $buildInfo.PSObject.Properties['pckContentVerified']
        if ($null -eq $pckVerifiedProperty -or $pckVerifiedProperty.Value -ne $true) {
            throw 'Publishable validation requires pckContentVerified=true.'
        }
    }
}
if ($buildInfo.version -ne $Version) { throw "BUILD-INFO version mismatch: $($buildInfo.version) != $Version" }
if ($buildInfo.architecture -ne $Arch) { throw "BUILD-INFO architecture mismatch: $($buildInfo.architecture) != $Arch" }
if ($buildInfo.platform -ne 'windows') { throw "Unsupported BUILD-INFO platform: $($buildInfo.platform)" }

$sourceLike = @(Get-ChildItem -LiteralPath $bundle -Recurse -File | Where-Object {
    $_.Extension -in @('.gd', '.rs', '.toml', '.tscn') -or
    $_.FullName -match '\\(scripts|src)\\'
})
if ($sourceLike.Count -gt 0) {
    throw "Portable bundle contains source-like files: $($sourceLike[0].FullName)"
}

$forbiddenTopLevelDirectories = @('logs', 'updates', 'updater', 'user-data', 'userdata', '.cache')
foreach ($name in $forbiddenTopLevelDirectories) {
    $path = Join-Path $bundle $name
    if (Test-Path -LiteralPath $path -PathType Container) {
        throw "Portable bundle contains transient/runtime data directory: $name"
    }
}
$forbiddenLooseFiles = @(Get-ChildItem -LiteralPath $bundle -File | Where-Object {
    $_.Extension -in @('.log', '.tmp') -or $_.Name -in @('startup-ok.json', 'desktop-shell-install-handoff-status.json')
})
if ($forbiddenLooseFiles.Count -gt 0) {
    throw "Portable bundle contains transient/runtime data file: $($forbiddenLooseFiles[0].Name)"
}

if ($CheckSbom) {
    if ([string]::IsNullOrWhiteSpace($SbomDirectory)) {
        throw '-SbomDirectory is required with -CheckSbom'
    }
    $indexPath = Join-Path $SbomDirectory 'sbom-index.json'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "SBOM index is missing: $indexPath"
    }
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    if ($index.Format -notmatch '^CycloneDX (json|xml)$') { throw 'SBOM format is invalid' }
    foreach ($entry in @($index.Files)) {
        $path = Join-Path $SbomDirectory ($entry.Path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "SBOM file is missing: $($entry.Path)"
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $entry.Sha256) { throw "SBOM hash mismatch: $($entry.Path)" }
    }
}

Write-Host "[P1] portable bundle validation passed: version=$Version arch=$Arch"
if ($CheckSbom) { Write-Host '[P1] SBOM index/hash validation passed' }
