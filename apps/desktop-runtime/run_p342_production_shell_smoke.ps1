[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "godot"
$testScript = "res://scripts/runtime_v3/tests/production_app_shell_contract_smoke.gd"
$testLog = Join-Path ([System.IO.Path]::GetTempPath()) (
    "ocp-p342-production-shell-" + [guid]::NewGuid().ToString('N') + ".log"
)

if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot executable not found: $GodotExe"
}

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

Write-Host "[OCP P3.4.2] Starting production shell contract smoke..." -ForegroundColor Cyan
$process = Start-Process -FilePath $GodotExe -ArgumentList @(
    "--headless",
    "--path", $project,
    "--log-file", $testLog,
    "--script", $testScript
) -Wait -PassThru -NoNewWindow

if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) {
    if (Test-Path -LiteralPath $testLog) {
        Get-Content -LiteralPath $testLog
    }
    throw "P3.4.2 production shell smoke failed with exit code $($process.ExitCode)"
}

Write-Host "[OCP P3.4.2] production shell contract smoke passed" -ForegroundColor Green
Remove-Item -LiteralPath $testLog -Force -ErrorAction SilentlyContinue
