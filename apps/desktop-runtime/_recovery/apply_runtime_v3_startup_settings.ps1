[CmdletBinding()]
param(
    [string]$ProjectFile = ".\godot\project.godot"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ProjectFile)) {
    throw "project.godot not found: $ProjectFile"
}

$projectPath = (Resolve-Path -LiteralPath $ProjectFile).Path
$content = Get-Content -LiteralPath $projectPath -Raw

function Set-GodotSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $script:content = $script:content -replace "`r`n", "`n"
    $sectionPattern = "(?ms)^\[" + [regex]::Escape($Section) + "\]\n(?<body>.*?)(?=^\[|\z)"
    $match = [regex]::Match($script:content, $sectionPattern)

    if (-not $match.Success) {
        $script:content = $script:content.TrimEnd() + "`n`n[$Section]`n$Key=$Value`n"
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
    $script:content = $script:content.Substring(0, $match.Index) +
        $replacement +
        $script:content.Substring($match.Index + $match.Length)
}

# Remove Godot's default splash. Runtime V3 supplies its own StartupLayer.
Set-GodotSetting -Section "application" -Key "boot_splash/show_image" -Value "false"
Set-GodotSetting -Section "application" -Key "boot_splash/bg_color" -Value "Color(0.025, 0.035, 0.055, 1)"

# Use OCP branding when the icon exists in the current project.
$iconPath = Join-Path (Split-Path -Parent $projectPath) "assets\icons\ocp.ico"
if (Test-Path -LiteralPath $iconPath) {
    Set-GodotSetting -Section "application" -Key "config/icon" -Value '"res://assets/icons/ocp.ico"'
}

Set-GodotSetting -Section "application" -Key "config/name" -Value '"OCP Desktop Runtime"'

Set-Content -LiteralPath $projectPath -Value $content -Encoding utf8 -NoNewline
Write-Host "Runtime V3 startup settings applied: $projectPath" -ForegroundColor Green
Write-Host "Godot boot splash disabled; OCP StartupLayer will be shown instead."
