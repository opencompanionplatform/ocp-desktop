# Build the OcpRuntimeBridge GDExtension and stage it where Godot expects it
# (godot/ocp_runtime.gdextension points at godot/bin/...). Windows-only for
# now; Linux/macOS scripts are a follow-up (tracked in SPRINT_CHECKLIST I2).
# ASCII-only (Windows PowerShell 5.1 misparses BOM-less UTF-8).

param(
    [ValidateSet("debug", "release")]
    [string]$Profile = "debug",
    [ValidateSet("x86_64", "arm64")]
    [string]$Arch = "arm64",
    [switch]$LocalBetaTrust,
    [switch]$StagingTrust,
    [string]$MarketplaceTrustRootFile = "",
    [string]$CargoTargetDir = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$target = if ($Arch -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
rustup target add $target | Out-Null

$previousCargoTargetDir = $env:CARGO_TARGET_DIR
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$effectiveCargoTargetDir = $CargoTargetDir
if ([string]::IsNullOrWhiteSpace($effectiveCargoTargetDir) -and -not [string]::IsNullOrWhiteSpace($previousCargoTargetDir)) {
    $effectiveCargoTargetDir = $previousCargoTargetDir
}
if ([string]::IsNullOrWhiteSpace($effectiveCargoTargetDir)) {
    $driveRoot = [IO.Path]::GetPathRoot($PSScriptRoot)
    $driveName = $driveRoot.TrimEnd('\\').TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($null -ne $drive -and $drive.Free -lt 1GB) {
        $effectiveCargoTargetDir = Join-Path ([IO.Path]::GetTempPath()) 'ocp-runtime-cargo-target'
        Write-Host ("[OCP Runtime] Low free space on {0}; Cargo target redirected to {1}" -f $driveRoot, $effectiveCargoTargetDir) -ForegroundColor Yellow
    }
}
if (-not [string]::IsNullOrWhiteSpace($effectiveCargoTargetDir)) {
    $effectiveCargoTargetDir = [IO.Path]::GetFullPath($effectiveCargoTargetDir)
    New-Item -ItemType Directory -Force -Path $effectiveCargoTargetDir | Out-Null
    $env:CARGO_TARGET_DIR = $effectiveCargoTargetDir
}

# MSVC link.exe writes large temporary files through TEMP/TMP even when Cargo's
# target directory is on another drive. Keep this scoped to the build process so
# low free space on the user's Windows TEMP drive cannot surface as LNK1108.
try {
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $tempRoot = [IO.Path]::GetPathRoot($tempPath)
    $tempDriveName = $tempRoot.TrimEnd('\\').TrimEnd(':')
    $tempDrive = Get-PSDrive -Name $tempDriveName -ErrorAction SilentlyContinue
    $repoRoot = [IO.Path]::GetPathRoot($PSScriptRoot)
    $repoDriveName = $repoRoot.TrimEnd('\\').TrimEnd(':')
    $repoDrive = Get-PSDrive -Name $repoDriveName -ErrorAction SilentlyContinue
    if ($null -ne $tempDrive -and $null -ne $repoDrive -and $tempDrive.Free -lt 8GB -and $repoDrive.Free -gt 8GB) {
        $linkerTemp = Join-Path $repoRoot 'ocp-build-temp\desktop-runtime-link'
        New-Item -ItemType Directory -Force -Path $linkerTemp | Out-Null
        $env:TEMP = $linkerTemp
        $env:TMP = $linkerTemp
        Write-Host ("[OCP Runtime] Low free space on linker TEMP drive {0}; TEMP/TMP redirected to {1} for this build." -f $tempRoot, $linkerTemp) -ForegroundColor Yellow
    }
} catch {
    Write-Host ("[OCP Runtime] Linker TEMP free-space probe skipped: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
}

$previousMarketplaceRoot = $env:OCP_MARKETPLACE_TRUST_ROOT_JSON
$previousStagingRoot = $env:OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON
if ($LocalBetaTrust -and $StagingTrust) {
    throw '-LocalBetaTrust and -StagingTrust are mutually exclusive.'
}
if ($LocalBetaTrust) {
    Remove-Item Env:OCP_MARKETPLACE_TRUST_ROOT_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON -ErrorAction SilentlyContinue
} elseif ($StagingTrust) {
    Remove-Item Env:OCP_MARKETPLACE_TRUST_ROOT_JSON -ErrorAction SilentlyContinue
    $stagingRootJson = ''
    if (-not [string]::IsNullOrWhiteSpace($MarketplaceTrustRootFile)) {
        $resolvedRoot = (Resolve-Path -LiteralPath $MarketplaceTrustRootFile -ErrorAction Stop).Path
        $stagingRootJson = [IO.File]::ReadAllText($resolvedRoot)
    } elseif (-not [string]::IsNullOrWhiteSpace($previousStagingRoot)) {
        $stagingRootJson = $previousStagingRoot
    } else {
        $defaultRoot = Join-Path $PSScriptRoot '..\..\config\marketplace-trust\staging\marketplace-root.json'
        if (Test-Path -LiteralPath $defaultRoot -PathType Leaf) {
            $stagingRootJson = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $defaultRoot).Path)
        }
    }
    if ([string]::IsNullOrWhiteSpace($stagingRootJson)) {
        throw 'Staging trust build requires config/marketplace-trust/staging/marketplace-root.json, -MarketplaceTrustRootFile, or OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON.'
    }
    if ($stagingRootJson.Length -gt 4096) { throw 'Marketplace staging trust root JSON is too large.' }
    try { $root = $stagingRootJson | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Marketplace staging trust root JSON is invalid.' }
    if ($root.trustDomain -ne 'marketplace-staging' -or $root.custody -ne 'online-staging' -or [string]::IsNullOrWhiteSpace([string]$root.keyId) -or [string]::IsNullOrWhiteSpace([string]$root.publicKeyHex)) {
        throw 'Marketplace staging trust root JSON does not describe marketplace-staging online-staging trust.'
    }
    $env:OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON = $stagingRootJson
} else {
    $marketplaceRootJson = ''
    if (-not [string]::IsNullOrWhiteSpace($MarketplaceTrustRootFile)) {
        $resolvedRoot = (Resolve-Path -LiteralPath $MarketplaceTrustRootFile -ErrorAction Stop).Path
        $marketplaceRootJson = [IO.File]::ReadAllText($resolvedRoot)
    } elseif (-not [string]::IsNullOrWhiteSpace($previousMarketplaceRoot)) {
        $marketplaceRootJson = $previousMarketplaceRoot
    } else {
        $defaultRoot = Join-Path $PSScriptRoot '..\..\config\marketplace-trust\production\marketplace-root.json'
        if (Test-Path -LiteralPath $defaultRoot -PathType Leaf) {
            $marketplaceRootJson = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $defaultRoot).Path)
        }
    }
    if ([string]::IsNullOrWhiteSpace($marketplaceRootJson)) {
        throw 'Marketplace release build requires the approved production root file (default config/marketplace-trust/production/marketplace-root.json), -MarketplaceTrustRootFile, or OCP_MARKETPLACE_TRUST_ROOT_JSON. Local Beta must use -LocalBetaTrust explicitly.'
    }
    if ($marketplaceRootJson.Length -gt 4096) { throw 'Marketplace trust root JSON is too large.' }
    try { $root = $marketplaceRootJson | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Marketplace trust root JSON is invalid.' }
    if ($root.trustDomain -ne 'marketplace-release' -or $root.custody -ne 'offline-root' -or [string]::IsNullOrWhiteSpace([string]$root.keyId) -or [string]::IsNullOrWhiteSpace([string]$root.publicKeyHex)) {
        throw 'Marketplace trust root JSON does not describe the approved marketplace-release offline root.'
    }
    $env:OCP_MARKETPLACE_TRUST_ROOT_JSON = $marketplaceRootJson
}

try {
    Push-Location rust
    try {
        $cargoArgs = @('build', '--target', $target)
        if ($Profile -eq 'release') { $cargoArgs += '--release' }
        if ($LocalBetaTrust) { $cargoArgs += @('--features', 'local-beta-trust') }
        if ($StagingTrust) { $cargoArgs += @('--features', 'staging-marketplace-trust') }
        & cargo @cargoArgs
        if ($LASTEXITCODE -ne 0) { throw 'Runtime bridge build failed; previous DLL will not be staged.' }
    } finally {
        Pop-Location
    }
} finally {
    if ([string]::IsNullOrWhiteSpace($previousMarketplaceRoot)) {
        Remove-Item Env:OCP_MARKETPLACE_TRUST_ROOT_JSON -ErrorAction SilentlyContinue
    } else {
        $env:OCP_MARKETPLACE_TRUST_ROOT_JSON = $previousMarketplaceRoot
    }
    if ([string]::IsNullOrWhiteSpace($previousStagingRoot)) {
        Remove-Item Env:OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON -ErrorAction SilentlyContinue
    } else {
        $env:OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON = $previousStagingRoot
    }
    if ([string]::IsNullOrWhiteSpace($previousCargoTargetDir)) {
        Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    } else {
        $env:CARGO_TARGET_DIR = $previousCargoTargetDir
    }
    if ([string]::IsNullOrWhiteSpace($previousTemp)) {
        Remove-Item Env:TEMP -ErrorAction SilentlyContinue
    } else {
        $env:TEMP = $previousTemp
    }
    if ([string]::IsNullOrWhiteSpace($previousTmp)) {
        Remove-Item Env:TMP -ErrorAction SilentlyContinue
    } else {
        $env:TMP = $previousTmp
    }
}

$src = if ([string]::IsNullOrWhiteSpace($effectiveCargoTargetDir)) {
    "rust/target/$target/$Profile/ocp_runtime.dll"
} else {
    Join-Path $effectiveCargoTargetDir "$target/$Profile/ocp_runtime.dll"
}
$destDir = "godot/bin/windows/$Arch"
$dest = "$destDir/ocp_desktop_runtime_ext.dll"
New-Item -ItemType Directory -Force $destDir | Out-Null

# Windows keeps a loaded GDExtension DLL locked until the owning Godot process
# exits. Rapid smoke-test/restart loops can therefore race the final module
# unload. Retry briefly before failing, and print the locking process so the
# caller gets an actionable error instead of a bare Copy-Item IOException.
$copySucceeded = $false
$lastCopyError = $null
for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
        Copy-Item $src $dest -Force
        $copySucceeded = $true
        break
    }
    catch [System.IO.IOException] {
        $lastCopyError = $_
        Start-Sleep -Milliseconds 150
    }
}

if (-not $copySucceeded) {
    Write-Host "Runtime bridge destination is still locked: $dest" -ForegroundColor Red
    try {
        $lockRows = & tasklist.exe /m ocp_desktop_runtime_ext.dll /fo csv /nh 2>$null
        if ($lockRows -and -not ($lockRows -match '^INFO:')) {
            Write-Host 'Processes currently loading ocp_desktop_runtime_ext.dll:' -ForegroundColor Yellow
            $lockRows | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
    }
    catch { }
    if ($null -ne $lastCopyError) { throw $lastCopyError }
    throw "Failed to stage runtime bridge: $dest"
}

Write-Host "Staged: $dest"
Write-Host "If Godot fails to load the extension with an 'entry symbol not found'"
Write-Host "error, check the real exported symbol name and fix entry_symbol in"
Write-Host "godot/ocp_runtime.gdextension (see the comment in that file)."
