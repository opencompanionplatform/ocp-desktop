[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "godot"
$testScript = "res://scripts/runtime_v3/tests/character_manager_contract_smoke.gd"
$testLog = Join-Path ([System.IO.Path]::GetTempPath()) (
    "ocp-g12-6-character-manager-" + [guid]::NewGuid().ToString('N') + ".log"
)

if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot executable not found: $GodotExe"
}

# Some PowerShell hosts expose both Path and PATH. Start-Process treats the
# environment dictionary case-insensitively and otherwise fails before Godot
# starts.
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

Write-Host "[OCP G12.6] Starting Character Manager contract smoke..." -ForegroundColor Cyan
$process = Start-Process -FilePath $GodotExe -ArgumentList @(
    "--headless",
    "--path", $project,
    "--log-file", $testLog,
    "--script", $testScript
) -Wait -PassThru -NoNewWindow

if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) {
    throw "G12.6 Character Manager smoke failed with exit code $($process.ExitCode)"
}

Write-Host "[OCP G12.6] Character Manager contract smoke passed" -ForegroundColor Green
Remove-Item -LiteralPath $testLog -Force -ErrorAction SilentlyContinue
