# Automated CS-RT conformance runner.
# Windows PowerShell 5.1 compatible.
#
# This runner does not depend on project.godot run/main_scene.
# It starts an explicit conformance scene and captures stdout/stderr reliably.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GodotExe,

    [int]$TimeoutSeconds = 30,

    [string]$ConformanceScene = "res://scenes/tests/RuntimeBridgeConformance.tscn",

    [switch]$UseLegacyScene
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$godotProject = Join-Path $PSScriptRoot "godot"
$legacyScene = "res://scenes/Main.tscn"

if ($UseLegacyScene) {
    $ConformanceScene = $legacyScene
}

function Convert-ResPathToLocal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$ResPath
    )

    if (-not $ResPath.StartsWith("res://")) {
        throw "Expected a res:// path, got: $ResPath"
    }

    $relative = $ResPath.Substring(6).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    return Join-Path $ProjectRoot $relative
}

function Convert-ToQuotedProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '(\\*)"', '$1$1\"') + '"'
}

function New-OcpProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = [string]::Join(
        " ",
        @($Arguments | ForEach-Object {
            Convert-ToQuotedProcessArgument $_
        })
    )
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Rebuild environment with case-insensitive keys.
    $psi.Environment.Clear()

    $environment = New-Object `
        'System.Collections.Generic.Dictionary[string,string]' `
        ([System.StringComparer]::OrdinalIgnoreCase)

    Get-ChildItem Env: | ForEach-Object {
        $environment[$_.Name] = $_.Value
    }

    foreach ($entry in $environment.GetEnumerator()) {
        $psi.Environment[$entry.Key] = $entry.Value
    }

    return $psi
}

function Start-OcpChildProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-OcpProcessStartInfo `
        -FilePath $FilePath `
        -Arguments $Arguments

    if (-not $process.Start()) {
        throw "Cannot start child process: $FilePath"
    }

    # Read both pipes asynchronously to avoid deadlocks.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    return @{
        Process = $process
        StdOutTask = $stdoutTask
        StdErrTask = $stderrTask
    }
}

function Complete-OcpChildProcess {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Child,

        [Parameter(Mandatory = $true)]
        [string]$StdOutPath,

        [Parameter(Mandatory = $true)]
        [string]$StdErrPath
    )

    $process = $Child.Process

    $Child.StdOutTask.Wait()
    $Child.StdErrTask.Wait()

    [System.IO.File]::WriteAllText(
        $StdOutPath,
        $Child.StdOutTask.Result,
        [System.Text.Encoding]::UTF8
    )

    [System.IO.File]::WriteAllText(
        $StdErrPath,
        $Child.StdErrTask.Result,
        [System.Text.Encoding]::UTF8
    )

    $process.Refresh()
}

function Stop-OcpChildProcess {
    param([hashtable]$Child)

    if ($null -eq $Child) {
        return
    }

    $process = $Child.Process

    if ($null -ne $process -and -not $process.HasExited) {
        try {
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
        }
        catch {
            Write-Warning "Could not stop process $($process.Id): $($_.Exception.Message)"
        }
    }
}

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    Write-Error "Godot executable not found: $GodotExe"
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $godotProject "project.godot") -PathType Leaf)) {
    Write-Error "Godot project not found: $godotProject"
    exit 1
}

$conformanceSceneFile = Convert-ResPathToLocal `
    -ProjectRoot $godotProject `
    -ResPath $ConformanceScene

if (-not (Test-Path -LiteralPath $conformanceSceneFile -PathType Leaf)) {
    if ($ConformanceScene -ne $legacyScene) {
        Write-Warning "Dedicated conformance scene not found: $conformanceSceneFile"
        Write-Warning "Falling back to legacy scene: $legacyScene"

        $ConformanceScene = $legacyScene
        $conformanceSceneFile = Convert-ResPathToLocal `
            -ProjectRoot $godotProject `
            -ResPath $ConformanceScene
    }
}

if (-not (Test-Path -LiteralPath $conformanceSceneFile -PathType Leaf)) {
    Write-Error "Conformance scene not found: $conformanceSceneFile"
    exit 1
}

$env:OCP_IPC_SOCKET = "ocp-cs-rt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:OCP_IPC_TOKEN = (
    [guid]::NewGuid().ToString('N') +
    [guid]::NewGuid().ToString('N')
)
$env:CS_RT_TIMEOUT_S = [string]$TimeoutSeconds

$csOut = Join-Path $PSScriptRoot "cs_rt_live.out.log"
$csErr = Join-Path $PSScriptRoot "cs_rt_live.err.log"
$godotOut = Join-Path $PSScriptRoot "godot_headless.out.log"
$godotErr = Join-Path $PSScriptRoot "godot_headless.err.log"

Remove-Item `
    $csOut,$csErr,$godotOut,$godotErr `
    -Force `
    -ErrorAction SilentlyContinue

Write-Host "[run_cs_rt] socket: $($env:OCP_IPC_SOCKET)"
Write-Host "[run_cs_rt] scene: $ConformanceScene"

Push-Location ..

& cargo build -p ocp-kernel --bin cs_rt_live

$cargoExitCode = $LASTEXITCODE
Pop-Location

if ($cargoExitCode -ne 0) {
    Write-Error "cargo build failed (exit $cargoExitCode)"
    exit 1
}

$testExe = Resolve-Path "..\..\target\debug\cs_rt_live.exe"

$testChild = $null
$godotChild = $null
$exitCode = 1

try {
    Write-Host "[run_cs_rt] starting cs_rt_live ($testExe)..."
    $testChild = Start-OcpChildProcess `
        -FilePath $testExe `
        -Arguments @()

    # Give the listener a short moment to bind before Godot connects.
    Start-Sleep -Milliseconds 250

    Write-Host "[run_cs_rt] starting Godot headless..."
    $godotChild = Start-OcpChildProcess `
        -FilePath $GodotExe `
        -Arguments @(
            "--headless",
            "--path",
            $godotProject,
            $ConformanceScene
        )

    $testProc = $testChild.Process
    $exited = $testProc.WaitForExit(
        ($TimeoutSeconds + 15) * 1000
    )

    if (-not $exited) {
        Write-Warning "cs_rt_live timed out"
        $exitCode = 1
    }
    else {
        $testProc.Refresh()
        $exitCode = $testProc.ExitCode
    }
}
finally {
    Stop-OcpChildProcess $testChild
    Stop-OcpChildProcess $godotChild

    if ($null -ne $testChild) {
        Complete-OcpChildProcess `
            -Child $testChild `
            -StdOutPath $csOut `
            -StdErrPath $csErr
    }

    if ($null -ne $godotChild) {
        Complete-OcpChildProcess `
            -Child $godotChild `
            -StdOutPath $godotOut `
            -StdErrPath $godotErr
    }
}

if ($null -eq $exitCode) {
    $testLog = Get-Content `
        -LiteralPath $csOut `
        -Raw `
        -ErrorAction SilentlyContinue

    if (
        $testLog -match '\[cs-rt\] PASS' `
        -and $testLog -notmatch '\[cs-rt\] FAIL'
    ) {
        $exitCode = 0
    }
    else {
        $exitCode = 1
    }
}

Write-Host "----- cs_rt_live output -----"
Get-Content $csOut -ErrorAction SilentlyContinue
Get-Content $csErr -ErrorAction SilentlyContinue

Write-Host "----- Godot headless output -----"
Get-Content $godotOut -ErrorAction SilentlyContinue
Get-Content $godotErr -ErrorAction SilentlyContinue
Write-Host "-----------------------------"

if ($exitCode -eq 0) {
    Write-Host "[run_cs_rt] PASS" -ForegroundColor Green
}
else {
    Write-Host "[run_cs_rt] FAIL (exit $exitCode)" -ForegroundColor Red
}

exit $exitCode
