[CmdletBinding()]
param(
    [string]$GodotRoot = ".\godot",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$godotRootPath = [System.IO.Path]::GetFullPath($GodotRoot)
$canonicalRoot = Join-Path $godotRootPath "scripts"
$duplicateRoot = Join-Path $canonicalRoot "scripts"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$recoveryRoot = Join-Path (Split-Path -Parent $godotRootPath) "_recovery"
$backupRoot = Join-Path $recoveryRoot "godot-scripts-scripts-$timestamp"

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseUri = New-Object System.Uri(($BasePath.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($fileUri).ToString()
    ).Replace('/', '\')
}

if (-not (Test-Path -LiteralPath $canonicalRoot -PathType Container)) {
    throw "Canonical scripts folder not found: $canonicalRoot"
}

if (-not (Test-Path -LiteralPath $duplicateRoot -PathType Container)) {
    Write-Host "No duplicate folder found: $duplicateRoot" -ForegroundColor Green
    Write-Host "Nothing to clean."
    exit 0
}

Write-Section "Inspecting duplicate Godot scripts"

Write-Host "Canonical : $canonicalRoot"
Write-Host "Duplicate : $duplicateRoot"
Write-Host "Backup    : $backupRoot"

$duplicateFiles = @(
    Get-ChildItem -LiteralPath $duplicateRoot -Recurse -File |
        Where-Object {
            $_.FullName -notlike "*\.godot\*"
        }
)

if ($duplicateFiles.Count -eq 0) {
    Write-Warning "Duplicate folder is empty."
}
else {
    Write-Host ""
    Write-Host "Files found: $($duplicateFiles.Count)"
}

$mismatched = @()
$missingCanonical = @()
$identical = @()

foreach ($duplicateFile in $duplicateFiles) {
    $relative = Get-RelativePath `
        -BasePath $duplicateRoot `
        -FullPath $duplicateFile.FullName

    $canonicalFile = Join-Path $canonicalRoot $relative

    if (-not (Test-Path -LiteralPath $canonicalFile -PathType Leaf)) {
        $missingCanonical += [pscustomobject]@{
            Relative = $relative
            Duplicate = $duplicateFile.FullName
            Canonical = $canonicalFile
        }
        continue
    }

    $duplicateHash = (Get-FileHash -LiteralPath $duplicateFile.FullName -Algorithm SHA256).Hash
    $canonicalHash = (Get-FileHash -LiteralPath $canonicalFile -Algorithm SHA256).Hash

    if ($duplicateHash -eq $canonicalHash) {
        $identical += $relative
    }
    else {
        $mismatched += [pscustomobject]@{
            Relative = $relative
            Duplicate = $duplicateFile.FullName
            Canonical = $canonicalFile
        }
    }
}

Write-Host ""
Write-Host "Identical files       : $($identical.Count)" -ForegroundColor Green
Write-Host "Different files       : $($mismatched.Count)" -ForegroundColor Yellow
Write-Host "No canonical file     : $($missingCanonical.Count)" -ForegroundColor Yellow

if ($mismatched.Count -gt 0) {
    Write-Host ""
    Write-Warning "Some duplicate files differ from their canonical versions:"
    $mismatched | Format-Table Relative, Canonical, Duplicate -AutoSize
}

if ($missingCanonical.Count -gt 0) {
    Write-Host ""
    Write-Warning "Some duplicate files do not exist in the canonical scripts folder:"
    $missingCanonical | Format-Table Relative, Canonical, Duplicate -AutoSize
}

if (($mismatched.Count -gt 0 -or $missingCanonical.Count -gt 0) -and -not $Force) {
    Write-Host ""
    Write-Host "Cleanup stopped for safety." -ForegroundColor Red
    Write-Host "The duplicate folder was NOT changed."
    Write-Host ""
    Write-Host "Review the files above. To back up and remove the duplicate folder anyway:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\cleanup_duplicate_godot_scripts.ps1 -Force"
    exit 2
}

Write-Section "Backing up duplicate folder"

New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
Move-Item -LiteralPath $duplicateRoot -Destination $backupRoot

Write-Host "Moved duplicate folder to:" -ForegroundColor Green
Write-Host "  $backupRoot"

Write-Section "Clearing Godot script caches"

$cachePaths = @(
    (Join-Path $godotRootPath ".godot\global_script_class_cache.cfg"),
    (Join-Path $godotRootPath ".godot\uid_cache.bin"),
    (Join-Path $godotRootPath ".godot\editor\script_editor_cache.cfg"),
    (Join-Path $godotRootPath ".godot\editor\editor_script_doc_cache.res")
)

foreach ($cachePath in $cachePaths) {
    if (Test-Path -LiteralPath $cachePath) {
        Remove-Item -LiteralPath $cachePath -Force
        Write-Host "Removed: $cachePath"
    }
}

$filesystemCaches = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $godotRootPath ".godot\editor") `
        -Filter "filesystem_cache*" `
        -File `
        -ErrorAction SilentlyContinue
)

foreach ($cache in $filesystemCaches) {
    Remove-Item -LiteralPath $cache.FullName -Force
    Write-Host "Removed: $($cache.FullName)"
}

Write-Section "Cleanup complete"

Write-Host "Canonical scripts remain at:" -ForegroundColor Green
Write-Host "  $canonicalRoot"
Write-Host ""
Write-Host "Duplicate backup is outside the Godot project:" -ForegroundColor Green
Write-Host "  $backupRoot"
Write-Host ""
Write-Host "Validate the project:" -ForegroundColor Cyan
Write-Host '  & "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe" `'
Write-Host '    --headless `'
Write-Host '    --path .\godot `'
Write-Host '    --editor `'
Write-Host '    --quit'
Write-Host ""
Write-Host "Expected: no UID duplicate warnings and no PackageBuilder class conflict."
