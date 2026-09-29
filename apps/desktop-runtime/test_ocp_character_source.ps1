[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CharacterRoot,

    [string]$MagickExe = "magick"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($CharacterRoot)
$configPath = Join-Path $root "character.build.json"
$animationsRoot = Join-Path $root "animations"

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Missing character.build.json"
}

if (-not (Test-Path -LiteralPath $animationsRoot -PathType Container)) {
    throw "Missing animations directory"
}

$config = (
    [System.IO.File]::ReadAllText(
        $configPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
)

$required = @(
    "idle",
    "appear",
    "disappear",
    "wave",
    "speak",
    "think",
    "walk_left",
    "walk_right",
    "sit",
    "sleep",
    "wake",
    "happy",
    "sad",
    "angry",
    "surprised"
)

$aliases = @{
    "walk_left" = @(
        "walk_left.png",
        "walk-left.png",
        "walkleft.png"
    )
    "walk_right" = @(
        "walk_right.png",
        "walk-right.png",
        "walkright.png"
    )
    "think" = @("think.png", "thinking.png")
}

$failed = $false

foreach ($name in $required) {
    $names = if ($aliases.ContainsKey($name)) {
        $aliases[$name]
    }
    else {
        @("$name.png")
    }

    $found = $false

    foreach ($fileName in $names) {
        $path = Join-Path $animationsRoot $fileName

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $found = $true
            Write-Host "[PASS] $name -> $fileName" `
                -ForegroundColor Green
            break
        }
    }

    if (-not $found) {
        Write-Host "[FAIL] missing animation: $name" `
            -ForegroundColor Red
        $failed = $true
    }
}

if ($failed) {
    throw "OCP source validation failed."
}

Write-Host ""
Write-Host "[PASS] OCP character source" -ForegroundColor Green
