[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GodotExe
)

$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "godot"
$scene = "res://scenes/tests/G8RenderHostSmoke.tscn"
$logFile = Join-Path $PSScriptRoot "g8_render_host_godot.log"

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot executable not found: $GodotExe"
}

Write-Host "[run_g8] starting isolated G8 render-host smoke..."
$env:OCP_GODOT_LOG_FILE = $logFile
$env:OCP_IPC_SOCKET = "ocp-g8-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:OCP_IPC_TOKEN = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
& $GodotExe --headless --path $project --log-file $logFile $scene
$exitCode = $LASTEXITCODE
Remove-Item Env:OCP_GODOT_LOG_FILE,Env:OCP_IPC_SOCKET,Env:OCP_IPC_TOKEN -ErrorAction SilentlyContinue
if ($null -ne $exitCode -and $exitCode -ne 0) {
    throw "G8 render-host smoke failed with exit code $exitCode"
}
