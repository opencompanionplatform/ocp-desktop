[CmdletBinding()]
param(
    [ValidateSet(
        "Run",
        "RunV3",
        "RunLegacy",
        "TestV3",
        "TestSingleInstance",
        "TestMonitor",
        "Build",
        "All"
    )]
    [string]$Action = "RunV3",

    [ValidateSet("overlay", "debug", "remember")]
    [string]$StartupMode = "remember",

    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe",

    [ValidateSet("arm64", "x86_64")]
    [string]$Arch = "arm64",

    [ValidateSet("debug", "release")]
    [string]$Profile = "debug"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = $PSScriptRoot
$godotProject = Join-Path $runtimeRoot "godot"
$legacyRunner = Join-Path $runtimeRoot "run_install_poc.ps1"
$runtimeScene = "res://scenes/runtime_v3/RuntimeApp.tscn"
$testSuite = "res://scripts/runtime_v3/tests/runtime_v3_test_suite.gd"
$monitorTest = "res://scripts/runtime_v3/tests/test_monitor_window_service_unit.gd"
$singleInstanceTest = Join-Path $runtimeRoot "test_runtime_v3_single_instance.ps1"

function Require-Path {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description not found: $Path"
    }
}

function Set-StartupMode {
    param([Parameter(Mandatory = $true)][string]$Mode)

    $settingsDir = Join-Path `
        $env:APPDATA `
        "Godot\app_userdata\OCP Desktop Runtime\runtime"

    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    }

    $settingsFile = Join-Path $settingsDir "settings.json"
    $startInOverlay = $Mode -eq "overlay"

    $payload = @{
        startInOverlay = $startInOverlay
    } | ConvertTo-Json -Depth 4

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $settingsFile,
        $payload,
        $encoding
    )

    Write-Host "[OCP] Startup mode set to: $Mode" -ForegroundColor Cyan
}

function Invoke-GodotAndWait {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Godot for Windows is a GUI executable. Calling it with `&` may return
    # without creating $LASTEXITCODE. Start-Process gives us a deterministic
    # Process.ExitCode for headless validation and tests.
    $process = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    $exitCode = $process.ExitCode

    if ($null -eq $exitCode) {
        throw "$Description did not return an exit code."
    }

    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }

    return $exitCode
}

function Run-V3 {
    Require-Path $GodotExe "Godot executable"
    Require-Path (Join-Path $godotProject "project.godot") "Godot project"

    if ($StartupMode -ne "remember") {
        Set-StartupMode $StartupMode
    }

    # Runtime is intentionally detached from the PowerShell session.
    Start-Process `
        -FilePath $GodotExe `
        -ArgumentList @(
            "--path",
            $godotProject,
            $runtimeScene
        ) |
        Out-Null
}

function Test-V3 {
    Require-Path $GodotExe "Godot executable"
    Require-Path (Join-Path $godotProject "project.godot") "Godot project"

    Invoke-GodotAndWait `
        -Description "Runtime V3 test suite" `
        -Arguments @(
            "--headless",
            "--path",
            $godotProject,
            "--script",
            $testSuite
        ) |
        Out-Null

    Write-Host "[PASS] Runtime V3 test process exited successfully." -ForegroundColor Green
}

function Test-Monitor {
    Require-Path $GodotExe "Godot executable"

    Invoke-GodotAndWait `
        -Description "Runtime V3 monitor descriptor test" `
        -Arguments @(
            "--headless",
            "--path",
            $godotProject,
            "--script",
            $monitorTest
        ) |
        Out-Null
}

function Test-SingleInstance {
    Require-Path $singleInstanceTest "Single Instance test script"

    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $singleInstanceTest,
            "-GodotExe",
            $GodotExe
        ) `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($process.ExitCode -ne 0) {
        throw "Single Instance test failed with exit code $($process.ExitCode)."
    }
}

function Run-Legacy {
    Require-Path $legacyRunner "Legacy runtime runner"

    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $legacyRunner,
            "-Action",
            "RunLegacyInternal",
            "-Arch",
            $Arch,
            "-Profile",
            $Profile
        ) `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($process.ExitCode -ne 0) {
        throw "Legacy runtime failed with exit code $($process.ExitCode)."
    }
}

function Build-Runtime {
    Require-Path $legacyRunner "Runtime build runner"

    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $legacyRunner,
            "-Action",
            "Build",
            "-Arch",
            $Arch,
            "-Profile",
            $Profile
        ) `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($process.ExitCode -ne 0) {
        throw "Runtime build failed with exit code $($process.ExitCode)."
    }
}

switch ($Action) {
    "Run" {
        Run-V3
    }

    "RunV3" {
        Run-V3
    }

    "RunLegacy" {
        Run-Legacy
    }

    "TestV3" {
        Test-V3
    }

    "TestSingleInstance" {
        Test-SingleInstance
    }

    "TestMonitor" {
        Test-Monitor
    }

    "Build" {
        Build-Runtime
    }

    "All" {
        Build-Runtime
        Test-V3
        Run-V3
    }
}
