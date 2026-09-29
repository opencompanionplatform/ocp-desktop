[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$BundleDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [ValidateSet('arm64', 'x86_64')][string]$Arch = 'arm64',
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$GodotExe,
    [switch]$CheckSbom,
    [string]$SbomDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -match '-local\.') {
    throw "Publishable release gate rejects local-only version: $Version"
}

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$pck = Join-Path $bundle 'ocp-runtime.pck'
if (-not (Test-Path -LiteralPath $pck -PathType Leaf)) {
    throw "Publishable release is missing ocp-runtime.pck: $pck"
}

Write-Host '[RC] 1/3 Inspect compiled Godot PCK contents'
& (Join-Path $releaseRoot 'Test-OcpRuntimePck.ps1') `
    -GodotExe $GodotExe `
    -PckPath $pck `
    -RequirePublishable | Out-Null

Write-Host '[RC] 2/3 Validate publishable bundle metadata and layout'
$validatorArgs = @{
    BundleDirectory = $bundle
    Version = $Version
    Arch = $Arch
    RequirePublishable = $true
}
if ($CheckSbom) {
    if ([string]::IsNullOrWhiteSpace($SbomDirectory)) { throw '-SbomDirectory is required with -CheckSbom.' }
    $validatorArgs.CheckSbom = $true
    $validatorArgs.SbomDirectory = $SbomDirectory
}
& (Join-Path $releaseRoot 'Validate-OcpPortableBundle.ps1') @validatorArgs

Write-Host '[RC] 3/3 Verify release ZIP source boundary if present'
$zipName = "ocp-windows-$Arch-$Version.zip"
$zipPath = Join-Path (Split-Path -Parent $bundle) $zipName
if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($archive.Entries | ForEach-Object {
            [pscustomobject]@{ Entry = $_; Name = ($_.FullName -replace '\\', '/') }
        })
        $forbidden = @($entries | Where-Object {
            $_.Name -match '\.(gd|rs|toml|tscn)$' -or $_.Name -match '(^|/)(scripts|src)/'
        })
        if ($forbidden.Count -gt 0) {
            throw "Publishable ZIP contains source-like entry: $($forbidden[0].Name)"
        }
        foreach ($required in @('BUILD-INFO.json', 'ocp-runtime.pck', 'ocp-launcher.exe', 'desktop-shell/OCP.exe')) {
            if ($null -eq ($entries | Where-Object Name -eq $required | Select-Object -First 1)) {
                throw "Publishable ZIP is missing: $required"
            }
        }
    }
    finally { $archive.Dispose() }
    Write-Host "[RC] ZIP boundary passed: $zipName"
}
else {
    Write-Host '[RC] ZIP not present beside bundle; bundle-only publishable gate passed.'
}

Write-Host '[RC] PUBLISHABLE RELEASE CONTENT GATE PASSED'
Write-Host "[RC] version=$Version arch=$Arch bundle=$bundle"
Write-Host '[RC] Remaining production gate: Authenticode sign/verify with the organization certificate.'
