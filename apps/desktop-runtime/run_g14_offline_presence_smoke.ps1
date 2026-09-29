[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "godot"
$testScript = "res://scripts/runtime_v3/tests/offline_presence_contract_smoke.gd"
$testLog = Join-Path ([System.IO.Path]::GetTempPath()) (
    "ocp-g14-offline-presence-" + [guid]::NewGuid().ToString('N') + ".log"
)

if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot executable not found: $GodotExe"
}

# Godot's process launch on this Windows image is sensitive to duplicate
# casing of PATH. Preserve its value while retaining a single canonical key.
$pathValue = $null
foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
    if ([string]::Equals([string]$entry.Key, 'PATH', [System.StringComparison]::OrdinalIgnoreCase)) {
        $pathValue = [string]$entry.Value
        break
    }
}
if ($null -ne $pathValue) {
    [System.Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [System.Environment]::SetEnvironmentVariable('Path', $null, 'Process')
    [System.Environment]::SetEnvironmentVariable('PATH', $pathValue, 'Process')
}

Write-Host "[OCP G14.1] Starting offline companion presence contract smoke..." -ForegroundColor Cyan
$process = Start-Process -FilePath $GodotExe -ArgumentList @(
    "--headless",
    "--path", $project,
    "--log-file", $testLog,
    "--script", $testScript
) -Wait -PassThru -NoNewWindow

if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) {
    throw "G14.1 offline presence smoke failed with exit code $($process.ExitCode)"
}

Write-Host "[OCP G14.1] offline companion presence contract smoke passed" -ForegroundColor Green
Remove-Item -LiteralPath $testLog -Force -ErrorAction SilentlyContinue
