[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = $PSScriptRoot
$godotProject = Join-Path $runtimeRoot "godot"
$scene = "res://scenes/runtime_v3/RuntimeApp.tscn"

if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot executable not found: $GodotExe"
}

Get-Process Godot* -ErrorAction SilentlyContinue |
    Stop-Process -Force

Write-Host "[TEST] Starting primary Runtime V3..." -ForegroundColor Cyan
$primary = Start-Process `
    -FilePath $GodotExe `
    -ArgumentList @("--path", $godotProject, $scene) `
    -PassThru

Start-Sleep -Seconds 3

Write-Host "[TEST] Starting duplicate Runtime V3..." -ForegroundColor Cyan
$duplicate = Start-Process `
    -FilePath $GodotExe `
    -ArgumentList @("--path", $godotProject, $scene) `
    -PassThru

Start-Sleep -Seconds 3

$runtimeProcesses = @(
    Get-Process Godot* -ErrorAction SilentlyContinue
)

if ($runtimeProcesses.Count -ne 1) {
    Write-Host "[FAIL] Expected one Runtime process, found $($runtimeProcesses.Count)." -ForegroundColor Red
    $runtimeProcesses | Stop-Process -Force
    exit 1
}

Write-Host "[PASS] Single Instance Guard kept one Runtime process." -ForegroundColor Green
$runtimeProcesses | Stop-Process -Force
exit 0
