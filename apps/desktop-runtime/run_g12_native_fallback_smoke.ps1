[CmdletBinding()]
param(
	[string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe"
)

$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "godot"
$scene = "res://scenes/tests/G12NativeFallbackSmoke.tscn"
$logFile = Join-Path $PSScriptRoot "g12_native_fallback_godot.log"
$stdoutFile = Join-Path $PSScriptRoot "g12_native_fallback_godot.out.log"

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
	throw "Godot executable not found: $GodotExe"
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $GodotExe
$psi.WorkingDirectory = $project
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.Arguments = "--headless --path `"$project`" --log-file `"$logFile`" $scene"
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $psi

$env:OCP_PRESENTATION_MODE = "native-companion"
$env:OCP_GODOT_LOG_FILE = $logFile
try {
	Write-Host "[OCP G12.2] Starting native companion safe-fallback smoke..."
	if (-not $process.Start()) { throw "Could not start Godot: $GodotExe" }
	$stdoutTask = $process.StandardOutput.ReadToEndAsync()
	$stderrTask = $process.StandardError.ReadToEndAsync()
	if (-not $process.WaitForExit(30 * 1000)) { throw "G12.2 fallback smoke timed out" }
	[IO.File]::WriteAllText($stdoutFile, $stdoutTask.Result)
	$stderr = $stderrTask.Result
	$passedMarker = $stdoutTask.Result -match '\[G12\.2\] native companion fallback smoke passed'
	if (-not $passedMarker) {
		throw "G12.2 fallback smoke failed; marker missing (exit=$($process.ExitCode), stderr=$stderr)"
	}
	if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Warning $stderr.Trim() }
	Write-Host "[OCP G12.2] native companion safe-fallback smoke passed"
}
finally {
	Remove-Item Env:OCP_PRESENTATION_MODE,Env:OCP_GODOT_LOG_FILE -ErrorAction SilentlyContinue
}
