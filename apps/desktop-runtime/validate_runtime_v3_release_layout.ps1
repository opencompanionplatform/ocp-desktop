[CmdletBinding()]
param(
    [string]$RuntimeRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($RuntimeRoot)

$requiredFiles = @(
    "run_install_poc.ps1",
    "run_install_poc_legacy.ps1",
    "run_cs_rt.ps1",
    "godot\project.godot",
    "godot\scenes\runtime_v3\RuntimeApp.tscn",
    "godot\scenes\tests\RuntimeBridgeConformance.tscn",
    "godot\scripts\runtime_v3\tests\runtime_bridge_conformance.gd",
    "godot\scripts\runtime_v3\tests\runtime_bridge_conformance_adapter.gd",
    "godot\scenes\tests\G8RenderHostSmoke.tscn",
    "godot\scripts\runtime_v3\tests\g8_render_host_smoke.gd",
    "godot\scenes\tests\G9NativeHostHandoffSmoke.tscn",
    "godot\scripts\runtime_v3\tests\g9_native_host_handoff_smoke.gd",
    "godot\scenes\tests\G10NativeGodotEmbedSmoke.tscn",
    "godot\scripts\runtime_v3\tests\g10_native_godot_embed_smoke.gd",
    "godot\scripts\runtime\packages\ocp_zip_path_util.gd"
)

$failed = $false

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $root $relativePath

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-Host "[PASS] $relativePath" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] missing: $relativePath" -ForegroundColor Red
        $failed = $true
    }
}

$projectPath = Join-Path $root "godot\project.godot"
$project = Get-Content -LiteralPath $projectPath -Raw

if ($project -match 'run/main_scene="res://scenes/runtime_v3/RuntimeApp\.tscn"') {
    Write-Host "[PASS] Runtime V3 is the project main scene" -ForegroundColor Green
}
else {
    Write-Host "[FAIL] Runtime V3 is not the project main scene" -ForegroundColor Red
    $failed = $true
}

$runnerPath = Join-Path $root "run_install_poc.ps1"
$runner = Get-Content -LiteralPath $runnerPath -Raw

foreach ($action in @("Run", "RunV3", "RunLegacy", "TestV3", "TestPackageLayer")) {
    if ($runner -match ('"' + [regex]::Escape($action) + '"')) {
        Write-Host "[PASS] runner action: $action" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] runner action missing: $action" -ForegroundColor Red
        $failed = $true
    }
}

if ($failed) {
    throw "Runtime V3 release layout validation failed."
}

Write-Host ""
Write-Host "[PASS] Runtime V3 release layout" -ForegroundColor Green
