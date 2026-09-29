[CmdletBinding()]
param(
    [ValidateSet("Validate","Build","Conformance","Run","RunV3","RunLegacy","TestV3","TestPackageLayer","AppShell","All","Clean")]
    [string]$Action = "Run",
    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe",
    [ValidateSet("arm64","x86_64")][string]$Arch = "arm64",
    [ValidateSet("debug","release")][string]$Profile = "debug",
    [ValidateSet("overlay","debug","remember")][string]$StartupMode = "remember",
    [switch]$SkipConformance,
    [switch]$Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = $PSScriptRoot
$godotProject = Join-Path $runtimeRoot "godot"
$legacyRunner = Join-Path $runtimeRoot "run_install_poc_legacy.ps1"
$runtimeV3Scene = "res://scenes/runtime_v3/RuntimeApp.tscn"
$legacyRuntimeScene = "res://scenes/Main.tscn"
$appShellScene = "res://scenes/AppShell.tscn"
$runtimeV3TestSuite = "res://scripts/runtime_v3/tests/runtime_v3_test_suite.gd"
$packageLayerTest = "res://scripts/runtime_v3/tests/test_package_layer_path_unit.gd"

function Require-Path([string]$Path,[string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Description not found: $Path" }
}

function Set-StartupMode([string]$Mode) {
    if ($Mode -eq "remember") { return }
    $settingsDir = Join-Path $env:APPDATA "Godot\app_userdata\OCP Desktop Runtime\runtime"
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    $settingsFile = Join-Path $settingsDir "settings.json"
    $payload = @{ startInOverlay = ($Mode -eq "overlay") } | ConvertTo-Json -Depth 4
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsFile,$payload,$enc)
    Write-Host "[OCP] Startup mode set to: $Mode" -ForegroundColor Cyan
}

function Invoke-GodotAndWait([string[]]$Arguments,[string]$Description) {
    Require-Path $GodotExe "Godot executable"
    Require-Path (Join-Path $godotProject "project.godot") "Godot project"
    $p = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($null -eq $p.ExitCode) { throw "$Description did not return an exit code." }
    if ($p.ExitCode -ne 0) { throw "$Description failed with exit code $($p.ExitCode)." }
}

function Start-GodotScene([string]$Scene,[string]$Description) {
    Require-Path $GodotExe "Godot executable"
    Require-Path (Join-Path $godotProject "project.godot") "Godot project"
    Write-Host "[POC] Opening $Description." -ForegroundColor Cyan
    Start-Process -FilePath $GodotExe -ArgumentList @("--path",$godotProject,$Scene) | Out-Null
}

function Invoke-LegacyRunner([string]$LegacyAction) {
    Require-Path $legacyRunner "Legacy POC runner"
    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$legacyRunner,"-Action",$LegacyAction,"-GodotExe",$GodotExe,"-Arch",$Arch,"-Profile",$Profile)
    if ($SkipConformance) { $args += "-SkipConformance" }
    if ($Confirm) { $args += "-Confirm" }
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "Legacy runner action '$LegacyAction' failed with exit code $($p.ExitCode)." }
}

function Run-RuntimeV3 {
    Set-StartupMode $StartupMode
    Start-GodotScene $runtimeV3Scene "Runtime V3 (production default)"
}

function Test-RuntimeV3 {
    Invoke-GodotAndWait @("--headless","--path",$godotProject,"--script",$runtimeV3TestSuite) "Runtime V3 test suite"
    Write-Host "[PASS] Runtime V3 test process exited successfully." -ForegroundColor Green
}

function Test-PackageLayer {
    Invoke-GodotAndWait @("--headless","--path",$godotProject,"--script",$packageLayerTest) "Package Layer path test"
    Write-Host "[PASS] Package Layer test process exited successfully." -ForegroundColor Green
}

switch ($Action) {
    "Run" { Run-RuntimeV3 }
    "RunV3" { Run-RuntimeV3 }
    "RunLegacy" { Start-GodotScene $legacyRuntimeScene "legacy Runtime" }
    "TestV3" { Test-RuntimeV3 }
    "TestPackageLayer" { Test-PackageLayer }
    "AppShell" { Start-GodotScene $appShellScene "App Shell" }
    "All" {
        Invoke-LegacyRunner "Build"
        if (-not $SkipConformance) { Invoke-LegacyRunner "Conformance" }
        Test-PackageLayer
        Test-RuntimeV3
        Run-RuntimeV3
    }
    default { Invoke-LegacyRunner $Action }
}
