[CmdletBinding()]
param(
    [string]$ManifestPath = '',
    [string]$OutputDirectory = '',
    [ValidateSet('json', 'xml')][string]$Format = 'json',
    [switch]$AllowNetwork,
    [switch]$ReplaceGeneratedFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $releaseRoot
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repositoryRoot 'Cargo.toml'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $releaseRoot 'out\sbom'
}

$manifest = (Resolve-Path -LiteralPath $ManifestPath).Path
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
$cargoCyclonedx = Get-Command cargo-cyclonedx -ErrorAction SilentlyContinue
if ($null -eq $cargoCyclonedx) {
    throw 'cargo-cyclonedx was not found. Install it with: cargo install cargo-cyclonedx --locked'
}

$metadata = (& cargo metadata --manifest-path $manifest --format-version 1 --no-deps | ConvertFrom-Json)
$workspaceRoot = [System.IO.Path]::GetFullPath($metadata.workspace_root)
$extension = if ($Format -eq 'json') { 'json' } else { 'xml' }
$generatedName = "ocp-platform.sbom.$extension"
$workspaceMembers = @($metadata.packages | Where-Object { $metadata.workspace_members -contains $_.id })
$generatedPaths = @($workspaceMembers | ForEach-Object {
    Join-Path (Split-Path -Parent $_.manifest_path) $generatedName
})
$preExisting = @($generatedPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($preExisting.Count -gt 0 -and -not $ReplaceGeneratedFiles) {
    throw "Existing generated SBOM files were found. Re-run with -ReplaceGeneratedFiles to replace them: $($preExisting[0])"
}

New-Item -ItemType Directory -Force -Path $output | Out-Null
$previousOffline = $env:CARGO_NET_OFFLINE
if ($AllowNetwork) { $env:CARGO_NET_OFFLINE = 'false' }

try {
    & cargo cyclonedx --manifest-path $manifest --format $Format --target all --override-filename 'ocp-platform.sbom'
    if ($LASTEXITCODE -ne 0) { throw "cargo cyclonedx failed with exit code $LASTEXITCODE." }

    $generated = @($generatedPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($generated.Count -eq 0) { throw 'CycloneDX completed but produced no workspace SBOM files.' }

    $entries = foreach ($source in $generated) {
        $relative = $source.Substring($workspaceRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $output $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
        [pscustomobject]@{
            Path = $relative.Replace('\', '/')
            Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $indexPath = Join-Path $output 'sbom-index.json'
    [pscustomobject]@{
        Format = "CycloneDX $Format"
        WorkspaceRoot = $workspaceRoot
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Files = $entries
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $indexPath -Encoding utf8
    Write-Host "sbomDirectory=$output"
    Write-Host "sbomFiles=$($generated.Count)"
}
finally {
    $env:CARGO_NET_OFFLINE = $previousOffline
    foreach ($generatedPath in $generatedPaths) {
        if (Test-Path -LiteralPath $generatedPath -PathType Leaf) {
            Remove-Item -LiteralPath $generatedPath -Force
        }
    }
}
