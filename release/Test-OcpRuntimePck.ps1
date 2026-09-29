[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$PckPath,
    [switch]$RequirePublishable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$verifierScript = Join-Path $releaseRoot 'tools\Verify-OcpRuntimePck.gd'

foreach ($path in @($GodotExe, $PckPath, $verifierScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required PCK verification input is missing: $path"
    }
}

function Resolve-GodotCliExecutable {
    param([Parameter(Mandatory = $true)][string]$Executable)
    $resolved = (Resolve-Path -LiteralPath $Executable).Path
    if ($resolved -match '_console\.exe$') { return $resolved }
    $directory = Split-Path -Parent $resolved
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
    $consoleCandidate = Join-Path $directory ($baseName + '_console.exe')
    if (Test-Path -LiteralPath $consoleCandidate -PathType Leaf) { return $consoleCandidate }
    return $resolved
}

$godotCli = Resolve-GodotCliExecutable -Executable $GodotExe
$pckFull = (Resolve-Path -LiteralPath $PckPath).Path
$hostDir = Join-Path ([System.IO.Path]::GetTempPath()) "ocp-pck-verify-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
try {
    $projectContent = '[application]' + "`r`n" + 'config/name="OCP PCK Verification Host"' + "`r`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $hostDir 'project.godot'),
        $projectContent,
        [System.Text.UTF8Encoding]::new($false)
    )

    # Windows GUI-subsystem Godot builds can detach from PowerShell's call
    # operator before redirected output is drained. Start-Process -Wait keeps
    # verification deterministic even when no *_console.exe companion exists.
    $stdoutPath = Join-Path $hostDir 'godot-verify.stdout.log'
    $stderrPath = Join-Path $hostDir 'godot-verify.stderr.log'
    $process = Start-Process `
        -FilePath $godotCli `
        -ArgumentList @('--headless', '--path', $hostDir, '--script', $verifierScript, '--', $pckFull) `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $exitCode = $process.ExitCode
    $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $parts = @($stdoutText, $stderrText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd() }
    $text = $parts -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host $text }

    if ($RequirePublishable) {
        if ($exitCode -ne 0 -or $text -notmatch '(?m)^OCP_PCK_VERIFY_OK\s*$') {
            throw "Publishable PCK verification failed with exit code $exitCode"
        }
        Write-Host '[PCK] publishable compiled-PCK verification passed'
    }
    elseif ($exitCode -ne 0) {
        Write-Warning "PCK verifier reported a non-publishable payload (exit=$exitCode)."
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Publishable = ($exitCode -eq 0 -and $text -match '(?m)^OCP_PCK_VERIFY_OK\s*$')
        Output = $text
    }
}
finally {
    Remove-Item -LiteralPath $hostDir -Recurse -Force -ErrorAction SilentlyContinue
}
