# Runtime install POC runner for Windows.
#
# This script is intentionally a portable-runtime harness, not a product
# installer. It validates the local toolchain, builds the GDExtension, runs
# CS-RT conformance, and opens the Runtime Test page in Godot. `Clean` removes
# only build artifacts and logs created under this desktop-runtime directory.
# It never removes user:// package or application state.

[CmdletBinding()]
param(
    [ValidateSet("Validate", "Build", "Conformance", "Run", "RunV3", "TestV3", "AppShell", "All", "Clean")]
    [string]$Action = "All",

    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe",

    [ValidateSet("arm64", "x86_64")]
    [string]$Arch = "arm64",

    [ValidateSet("debug", "release")]
    [string]$Profile = "debug",

    [switch]$SkipConformance,
    [switch]$Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = $PSScriptRoot
$godotProject = Join-Path $runtimeRoot "godot"
$buildScript = Join-Path $runtimeRoot "build.ps1"
$conformanceScript = Join-Path $runtimeRoot "run_cs_rt.ps1"
$target = if ($Arch -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
$extension = Join-Path $godotProject "bin\windows\$Arch\ocp_desktop_runtime_ext.dll"

function Require-Path([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description not found: $Path"
    }
}

function Require-Command([string]$Name) {
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not available in PATH."
    }
}

function Invoke-Checked([scriptblock]$Command, [string]$Description) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Test-Prerequisites {
    Write-Host "[POC] Validating prerequisites..." -ForegroundColor Cyan
    Require-Path $GodotExe "Godot executable"
    Require-Path (Join-Path $godotProject "project.godot") "Godot project"
    Require-Path $buildScript "GDExtension build script"
    Require-Path $conformanceScript "CS-RT conformance script"
    Require-Command "cargo"
    Require-Command "rustup"

    $installedTargets = & rustup target list --installed
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list installed Rust targets."
    }
    if ($installedTargets -notcontains $target) {
        Write-Host "[POC] Installing Rust target $target..." -ForegroundColor Yellow
        Invoke-Checked { rustup target add $target } "Rust target installation"
    }

    Write-Host "[POC] Godot: $GodotExe"
    Write-Host "[POC] Rust target: $target"
    Write-Host "[POC] Prerequisites OK" -ForegroundColor Green
}

function Build-Runtime {
    Test-Prerequisites
    Write-Host "[POC] Building GDExtension ($Profile/$Arch)..." -ForegroundColor Cyan
    Invoke-Checked { & $buildScript -Profile $Profile -Arch $Arch } "GDExtension build"
    Require-Path $extension "Staged GDExtension"
    Write-Host "[POC] Staged: $extension" -ForegroundColor Green
}

function Run-Conformance {
    Test-Prerequisites
    Require-Path $extension "Staged GDExtension (run Build first)"
    Write-Host "[POC] Running CS-RT conformance..." -ForegroundColor Cyan
    Invoke-Checked { & $conformanceScript -GodotExe $GodotExe } "CS-RT conformance"
    Write-Host "[POC] CS-RT passed" -ForegroundColor Green
}

function Open-CompanionRuntime {
    Test-Prerequisites
    Require-Path $extension "Staged GDExtension (run Build first)"
    $runtimeScene = "res://scenes/Main.tscn"
    Write-Host "[POC] Opening companion runtime. It loads the active installed character package." -ForegroundColor Cyan
    Start-Process -FilePath $GodotExe -ArgumentList @("--path", $godotProject, $runtimeScene) | Out-Null
}

function Open-AppShell {
    Test-Prerequisites
    Require-Path $extension "Staged GDExtension (run Build first)"
    $appShellScene = "res://scenes/Studio.tscn"
    Write-Host "[POC] Opening AppShell UI (Runtime Test is available from its navigation)." -ForegroundColor Cyan
    Start-Process -FilePath $GodotExe -ArgumentList @("--path", $godotProject, $appShellScene) | Out-Null
}

function Clear-PocArtifacts {
    if (-not $Confirm) {
        throw "Clean is destructive for POC artifacts. Run again with -Confirm."
    }

    $targets = @(
        $extension,
        (Join-Path $runtimeRoot "cs_rt_live.out.log"),
        (Join-Path $runtimeRoot "cs_rt_live.err.log"),
        (Join-Path $runtimeRoot "godot_headless.out.log"),
        (Join-Path $runtimeRoot "godot_headless.err.log")
    )
    foreach ($item in $targets) {
        if (Test-Path -LiteralPath $item) {
            Remove-Item -LiteralPath $item -Force
            Write-Host "[POC] Removed: $item"
        }
    }
    Write-Host "[POC] Clean complete. No user:// packages or state were removed." -ForegroundColor Green
}


function Run-RuntimeV3 {
    Test-Prerequisites
    Require-Path $extension "Staged GDExtension (run Build first)"
    $runtimeScene = "res://scenes/runtime_v3/RuntimeApp.tscn"
    Write-Host "[POC] Opening Runtime V3." -ForegroundColor Cyan
    Start-Process -FilePath $GodotExe -ArgumentList @("--path", $godotProject, $runtimeScene) | Out-Null
}

function Test-RuntimeV3 {
    Test-Prerequisites
    Write-Host "[POC] Running Runtime V3 test suite..." -ForegroundColor Cyan
    & $GodotExe `
        --headless `
        --path $godotProject `
        --script "res://scripts/runtime_v3/tests/runtime_v3_test_suite.gd"

    if ($LASTEXITCODE -ne 0) {
        throw "Runtime V3 tests failed with exit code $LASTEXITCODE."
    }
}
switch ($Action) {
    "RunV3" {
        Run-RuntimeV3
        break
    }
    "TestV3" {
        Test-RuntimeV3
        break
    }
    "Validate" { Test-Prerequisites }
    "Build" { Build-Runtime }
    "Conformance" { Run-Conformance }
    "Run" { Open-CompanionRuntime }
    "AppShell" { Open-AppShell }
    "All" {
        Build-Runtime
        if (-not $SkipConformance) {
            Run-Conformance
        }
        Open-RuntimeTest
    }
    "Clean" { Clear-PocArtifacts }
}
