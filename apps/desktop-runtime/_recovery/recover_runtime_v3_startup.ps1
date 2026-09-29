[CmdletBinding()]
param(
    [string]$RuntimeScene = ".\godot\scenes\runtime_v3\RuntimeApp.tscn",
    [string]$RuntimeScript = ".\godot\scripts\runtime_v3\runtime_app.gd",
    [string]$ProjectFile = ".\godot\project.godot"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-File {
    param([string]$Path, [string]$Description)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($Path),
        $Content,
        $encoding
    )
}

Require-File $RuntimeScene "Runtime scene"
Require-File $RuntimeScript "Runtime script"
Require-File $ProjectFile "Godot project"

$scriptBackup = "$RuntimeScript.phase6-2-backup"

if (-not (Test-Path -LiteralPath $scriptBackup -PathType Leaf)) {
    throw @"
The RuntimeApp backup was not found:

  $scriptBackup

Restore runtime_app.gd from the Phase 6.1 package before continuing.
"@
}

Write-Host "[RECOVERY] Restoring unmodified RuntimeApp script..." -ForegroundColor Cyan
Copy-Item -LiteralPath $scriptBackup -Destination $RuntimeScript -Force

# ---------------------------------------------------------------------------
# Safe scene-only startup patch.
# No GDScript functions are edited.
# ---------------------------------------------------------------------------

$scene = Get-Content -LiteralPath $RuntimeScene -Raw
$scene = $scene -replace "`r`n", "`n"

# Remove duplicate visible=false lines first, then insert exactly once.
$scene = [regex]::Replace(
    $scene,
    '(?m)(^\[node name="StartupLayer" type="CanvasLayer" parent="RuntimeUI"\]\n)(?:visible = false\n)*',
    '${1}visible = false' + "`n"
)

# Keep the startup backdrop transparent even if the layer is made visible
# manually in the editor.
$scene = [regex]::Replace(
    $scene,
    '(?ms)(\[node name="Backdrop" type="ColorRect" parent="RuntimeUI/StartupLayer"\].*?^color = )Color\([^)]+\)',
    '${1}Color(0, 0, 0, 0)'
)

Write-Utf8NoBom -Path $RuntimeScene -Content $scene

# ---------------------------------------------------------------------------
# Safe project settings patch.
# ---------------------------------------------------------------------------

$project = Get-Content -LiteralPath $ProjectFile -Raw
$project = $project -replace "`r`n", "`n"

function Set-GodotSetting {
    param(
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $sectionPattern = "(?ms)^\[" + [regex]::Escape($Section) + "\]\n(?<body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($script:project, $sectionPattern)

    if (-not $match.Success) {
        $script:project = $script:project.TrimEnd() + "`n`n[$Section]`n$Key=$Value`n"
        return
    }

    $body = $match.Groups["body"].Value
    $keyPattern = "(?m)^" + [regex]::Escape($Key) + "=.*$"

    if ([regex]::IsMatch($body, $keyPattern)) {
        $newBody = [regex]::Replace($body, $keyPattern, "$Key=$Value")
    }
    else {
        $newBody = $body.TrimEnd() + "`n$Key=$Value`n"
    }

    $replacement = "[$Section]`n$newBody"

    $script:project =
        $script:project.Substring(0, $match.Index) +
        $replacement +
        $script:project.Substring($match.Index + $match.Length)
}

Set-GodotSetting "application" "boot_splash/show_image" "false"
Set-GodotSetting "display" "window/size/transparent" "true"
Set-GodotSetting "display" "window/per_pixel_transparency/allowed" "true"
Set-GodotSetting "rendering" "viewport/transparent_background" "true"
Set-GodotSetting "rendering" "environment/defaults/default_clear_color" "Color(0, 0, 0, 0)"

Write-Utf8NoBom -Path $ProjectFile -Content $project

Write-Host ""
Write-Host "[RECOVERY] Runtime V3 script restored successfully." -ForegroundColor Green
Write-Host "[RECOVERY] Safe startup settings applied without editing GDScript functions." -ForegroundColor Green
Write-Host ""
Write-Host "Validate:" -ForegroundColor Cyan
Write-Host '  & "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe" --headless --path .\godot --editor --quit'
Write-Host ""
Write-Host "Run:" -ForegroundColor Cyan
Write-Host "  .\run_ocp_runtime.ps1 -Action RunV3 -StartupMode overlay"
