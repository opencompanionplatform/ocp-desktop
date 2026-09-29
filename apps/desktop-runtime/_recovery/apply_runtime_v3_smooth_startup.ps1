[CmdletBinding()]
param(
    [string]$RuntimeScene = ".\godot\scenes\runtime_v3\RuntimeApp.tscn",
    [string]$RuntimeScript = ".\godot\scripts\runtime_v3\runtime_app.gd",
    [string]$ProjectFile = ".\godot\project.godot"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Backup-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }

    $backup = "$Path.phase6-2-backup"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-Host "Backup: $backup" -ForegroundColor DarkGray
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        (Resolve-Path -LiteralPath $Path).Path,
        $Content,
        $encoding
    )
}

Backup-File -Path $RuntimeScene
Backup-File -Path $RuntimeScript
Backup-File -Path $ProjectFile

# ---------------------------------------------------------------------------
# 1. Hide the in-scene StartupLayer before the first rendered frame.
#    It was an opaque full-window layer and became visible while the main
#    window changed from the initial project size to virtual-desktop overlay.
# ---------------------------------------------------------------------------

$scene = Get-Content -LiteralPath $RuntimeScene -Raw
$scene = $scene -replace "`r`n", "`n"

$startupPattern = '(?ms)(\[node name="StartupLayer" type="CanvasLayer" parent="RuntimeUI"\]\n(?:.*?\n)*?)(?=\[node |\z)'

if ($scene -match '\[node name="StartupLayer" type="CanvasLayer" parent="RuntimeUI"\]') {
    $scene = [regex]::Replace(
        $scene,
        '(\[node name="StartupLayer" type="CanvasLayer" parent="RuntimeUI"\]\n)',
        "`$1visible = false`n",
        1
    )

    # Make the old backdrop transparent as a second safety layer.
    $scene = $scene -replace `
        '(\[node name="Backdrop" type="ColorRect" parent="RuntimeUI/StartupLayer"\][\s\S]*?color = )Color\([^)]+\)', `
        '${1}Color(0, 0, 0, 0)'
}

Write-Utf8NoBom -Path $RuntimeScene -Content $scene

# ---------------------------------------------------------------------------
# 2. Prevent RuntimeApp from showing StartupLayer again.
#    Keep the node for compatibility, but it remains invisible.
# ---------------------------------------------------------------------------

$script = Get-Content -LiteralPath $RuntimeScript -Raw
$script = $script -replace "`r`n", "`n"

$script = $script -replace `
    '(?ms)func _on_startup_character_ready\(_payload: Dictionary\) -> void:\n(?:\t.*\n)+?(?=\nfunc )', `
@'
func _on_startup_character_ready(_payload: Dictionary) -> void:
	if is_instance_valid(%StartupLayer):
		%StartupLayer.visible = false


'@

$script = $script -replace `
    '(?ms)func _on_startup_character_failed\(payload: Dictionary\) -> void:\n(?:\t.*\n)+?(?=\nfunc )', `
@'
func _on_startup_character_failed(payload: Dictionary) -> void:
	push_warning("Runtime V3 character load failed: " + str(payload.get("error", "Unknown error")))
	if is_instance_valid(%StartupLayer):
		%StartupLayer.visible = false


'@

# Force it off as early as possible in _ready.
if ($script -notmatch 'StartupLayer\.visible = false\s+# Phase 6\.2') {
    $script = $script -replace `
        'func _ready\(\) -> void:\n', `
@'
func _ready() -> void:
	if is_instance_valid(%StartupLayer):
		%StartupLayer.visible = false # Phase 6.2 smooth startup

'@
}

Write-Utf8NoBom -Path $RuntimeScript -Content $script

# ---------------------------------------------------------------------------
# 3. Keep Godot's own splash disabled and make the initial project background
#    transparent. The Runtime will apply Debug or Overlay mode immediately.
# ---------------------------------------------------------------------------

$project = Get-Content -LiteralPath $ProjectFile -Raw
$project = $project -replace "`r`n", "`n"

function Set-ProjectSetting {
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
    $script:project = $script:project.Substring(0, $match.Index) +
        $replacement +
        $script:project.Substring($match.Index + $match.Length)
}

Set-ProjectSetting -Section "application" -Key "boot_splash/show_image" -Value "false"
Set-ProjectSetting -Section "display" -Key "window/size/transparent" -Value "true"
Set-ProjectSetting -Section "display" -Key "window/per_pixel_transparency/allowed" -Value "true"
Set-ProjectSetting -Section "rendering" -Key "viewport/transparent_background" -Value "true"
Set-ProjectSetting -Section "rendering" -Key "environment/defaults/default_clear_color" -Value "Color(0, 0, 0, 0)"

Write-Utf8NoBom -Path $ProjectFile -Content $project

Write-Host ""
Write-Host "Runtime V3 smooth startup patch applied." -ForegroundColor Green
Write-Host "The full-screen black StartupLayer is now disabled."
Write-Host ""
Write-Host "Restart:" -ForegroundColor Cyan
Write-Host "  Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force"
Write-Host "  .\run_ocp_runtime.ps1 -Action RunV3 -StartupMode overlay"
