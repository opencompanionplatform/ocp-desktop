[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'starter-artifacts.json'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'out\starter-input')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Starter artifact manifest not found: $ManifestPath"
}

$config = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([int]$config.schemaVersion -ne 1) {
    throw "Unsupported starter artifact manifest schemaVersion: $($config.schemaVersion)"
}
if ([string]$config.repository -ne 'opencompanionplatform/ocp-releases') {
    throw "Starter artifact repository is not approved: $($config.repository)"
}
$releaseTag = [string]$config.releaseTag
if ($releaseTag -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
    throw "Starter artifact releaseTag is invalid: $releaseTag"
}

$expected = @{
    'character'   = 'character.bible-1.0.0.ocp'
    'effect-pack' = 'effect.starter-neon-1.0.0.ocp'
}
$artifacts = @($config.artifacts)
if ($artifacts.Count -ne $expected.Count) {
    throw "Starter artifact manifest must contain exactly $($expected.Count) artifacts."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$resolved = @{}
foreach ($artifact in $artifacts) {
    $role = [string]$artifact.role
    if (-not $expected.ContainsKey($role)) {
        throw "Starter artifact role is not approved: $role"
    }
    if ($resolved.ContainsKey($role)) {
        throw "Starter artifact role is duplicated: $role"
    }

    $fileName = [string]$artifact.fileName
    if ($fileName -ne $expected[$role]) {
        throw "Starter artifact filename for $role is invalid: $fileName"
    }
    $sha256 = ([string]$artifact.sha256).ToLowerInvariant()
    if ($sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Starter artifact SHA-256 for $fileName is invalid."
    }

    $uri = [Uri]([string]$artifact.url)
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com') {
        throw "Starter artifact URL must use https://github.com: $uri"
    }
    $expectedPath = "/opencompanionplatform/ocp-releases/releases/download/$releaseTag/$fileName"
    if ($uri.AbsolutePath -ne $expectedPath -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "Starter artifact URL is not the pinned release asset path: $uri"
    }

    $destination = Join-Path $OutputDirectory $fileName
    Write-Host "[OCP Starter] Downloading $role from $uri"
    Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $destination
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $sha256) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw "Starter artifact SHA-256 mismatch for $fileName. expected=$sha256 actual=$actual"
    }
    $resolved[$role] = [IO.Path]::GetFullPath($destination)
    Write-Host "[OCP Starter] Verified $fileName sha256=$actual"
}

[pscustomobject]@{
    characterPackagePath = $resolved['character']
    effectPackagePath = $resolved['effect-pack']
    releaseTag = $releaseTag
}
