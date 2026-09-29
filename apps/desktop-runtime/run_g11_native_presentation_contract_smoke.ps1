[CmdletBinding()]
param(
	[string]$GodotExe = "C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe",
	[int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root 'godot'
$scene = 'res://scenes/tests/G11NativePresentationContractSmoke.tscn'
$stdoutPath = Join-Path $root 'g11_native_presentation_contract.out.log'
$stderrPath = Join-Path $root 'g11_native_presentation_contract.err.log'

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
	throw "Godot executable not found: $GodotExe"
}
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $GodotExe
$psi.WorkingDirectory = $project
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.Arguments = "--headless --path `"$project`" --log-file `"$stdoutPath`" `"$scene`""
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $psi

Write-Host '[OCP G11] Starting native presentation contract smoke...'
if (-not $process.Start()) { throw 'Could not start Godot G11 smoke' }
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
	$process.Kill()
	$process.WaitForExit()
	throw "G11 smoke timed out after $TimeoutSeconds seconds"
}
$stdout = $stdoutTask.Result
$stderr = $stderrTask.Result
[IO.File]::WriteAllText($stdoutPath, $stdout)
[IO.File]::WriteAllText($stderrPath, $stderr)

Write-Host '----- G11 stdout -----'
Write-Host $stdout
if (-not [string]::IsNullOrWhiteSpace($stderr)) {
	Write-Host '----- G11 stderr -----'
	Write-Host $stderr
}

if ($process.ExitCode -ne 0 -or $stdout -notmatch '\[G11\] native presentation contract smoke passed') {
	throw "G11 native presentation contract smoke failed with exit code $($process.ExitCode)"
}
Write-Host '[OCP G11] native presentation contract smoke passed'
