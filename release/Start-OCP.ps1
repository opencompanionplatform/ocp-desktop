[CmdletBinding()]
param(
    [ValidateLength(0, 4096)][string]$ProtocolUri = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$kernelExe = Join-Path $root 'bin\ocp-kernel.exe'
$nativeExe = Join-Path $root 'bin\ocp-native-companion-window.exe'
$updaterExe = Join-Path $root 'bin\ocp-release-check.exe'
$applySource = Join-Path $root 'Apply-OcpUpdate.ps1'
$runtimeExe = Join-Path $root 'ocp-runtime.exe'
$desktopShellRoot = Join-Path $root 'desktop-shell'
$desktopShellExe = Join-Path $desktopShellRoot 'OCP.exe'
$buildInfoPath = Join-Path $root 'BUILD-INFO.json'
$ocpDataRoot = Join-Path $env:LOCALAPPDATA 'OCP'
$logRoot = Join-Path $ocpDataRoot 'logs'
$updateRoot = Join-Path $ocpDataRoot 'updates'
$updaterRoot = Join-Path $ocpDataRoot 'updater'
$applyHelper = Join-Path $updaterRoot 'Apply-OcpUpdate.ps1'
$statusFile = Join-Path $updateRoot 'ocp-update-status.json'
$healthFile = Join-Path $updateRoot 'startup-ok.json'
$session = [guid]::NewGuid().ToString('N')
$tempRoot = [System.IO.Path]::GetTempPath()
$inheritedEnvironment = @{}
$managedEnvironmentNames = @(
    'OCP_IPC_SOCKET','OCP_IPC_TOKEN','OCP_NATIVE_HOST_HANDOFF_PATH',
    'OCP_NATIVE_HOST_EVENT_PATH','OCP_NATIVE_HOST_COMMAND_PATH',
    'OCP_NATIVE_HOST_UI_COMMAND_PATH','OCP_NATIVE_HOST_BUBBLE_PATH',
    'OCP_NATIVE_HOST_TOKEN','OCP_NATIVE_HOST_EMBED','OCP_NATIVE_HOST_SIZE',
    'OCP_NATIVE_HOST_HITBOX','OCP_NATIVE_INTERACTIVE',
    'OCP_NATIVE_PRODUCTION_ENABLED','OCP_PRESENTATION_MODE','OCP_TASKBAR_RELAUNCH_COMMAND',
    'OCP_TASKBAR_DISPLAY_NAME','OCP_TASKBAR_ICON_RESOURCE','OCP_BUNDLED_FONT_PATH','OCP_DESKTOP_SHELL_ENABLED',
    'OCP_DESKTOP_SHELL_FUNCTIONAL_ADAPTER','OCP_DESKTOP_SHELL_EXECUTABLE','OCP_DESKTOP_SHELL_ROOT',
    'OCP_STORE_LOOPBACK_ORIGINS','OCP_STORE_URL','OCP_UPDATER_EXE',
    'OCP_UPDATE_STAGING_DIR','OCP_UPDATE_APPLY_SCRIPT','OCP_UPDATE_INSTALL_ROOT',
    'OCP_UPDATE_START_SCRIPT','OCP_UPDATE_STATUS_FILE','OCP_UPDATE_HEALTH_FILE',
    'OCP_UPDATE_EXPECTED_VERSION','OCP_UPDATE_PEER_PROCESS_IDS'
)
foreach ($name in $managedEnvironmentNames) {
    $inheritedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
}

foreach ($path in @($kernelExe, $nativeExe, $updaterExe, $applySource, $runtimeExe, $desktopShellExe, $buildInfoPath, (Join-Path $root 'ocp-runtime.pck'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "OCP portable file is missing: $path"
    }
}

$validatedProtocolUri = ''
if (-not [string]::IsNullOrWhiteSpace($ProtocolUri)) {
    $candidateUri = $null
    if (-not [System.Uri]::TryCreate($ProtocolUri, [System.UriKind]::Absolute, [ref]$candidateUri) -or $candidateUri.Scheme -ne 'ocp') {
        throw 'ProtocolUri must be an absolute ocp:// URI.'
    }
    $validatedProtocolUri = $candidateUri.AbsoluteUri
}

$buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json
$storeOrigin = [string]$buildInfo.storeOrigin
if (-not [string]::IsNullOrWhiteSpace($storeOrigin)) {
    $storeUri = $null
    if (-not [System.Uri]::TryCreate($storeOrigin, [System.UriKind]::Absolute, [ref]$storeUri) -or $storeUri.Scheme -ne 'https') {
        throw "BUILD-INFO storeOrigin is invalid: $storeOrigin"
    }
    $storeOrigin = $storeUri.GetLeftPart([System.UriPartial]::Authority)
}

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
New-Item -ItemType Directory -Force -Path $updateRoot,$updaterRoot | Out-Null
Copy-Item -LiteralPath $applySource -Destination $applyHelper -Force

$handoffPath = Join-Path $tempRoot "ocp-handoff-$session.json"
$eventPath = Join-Path $tempRoot "ocp-event-$session.json"
$commandPath = Join-Path $tempRoot "ocp-command-$session.json"
$uiCommandPath = Join-Path $tempRoot "ocp-ui-command-$session.json"
$bubblePath = Join-Path $tempRoot "ocp-bubble-$session.json"
$token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')

$env:OCP_IPC_SOCKET = "ocp-runtime-$($session.Substring(0, 12))"
$env:OCP_IPC_TOKEN = $token
$env:OCP_NATIVE_HOST_HANDOFF_PATH = $handoffPath
$env:OCP_NATIVE_HOST_EVENT_PATH = $eventPath
$env:OCP_NATIVE_HOST_COMMAND_PATH = $commandPath
$env:OCP_NATIVE_HOST_UI_COMMAND_PATH = $uiCommandPath
$env:OCP_NATIVE_HOST_BUBBLE_PATH = $bubblePath
$env:OCP_NATIVE_HOST_TOKEN = $token
$env:OCP_NATIVE_HOST_EMBED = '1'
$env:OCP_NATIVE_HOST_SIZE = '384'
$env:OCP_NATIVE_HOST_HITBOX = '0.08,0.02,0.84,0.96'
$env:OCP_NATIVE_INTERACTIVE = '1'
$env:OCP_NATIVE_PRODUCTION_ENABLED = '1'
$env:OCP_PRESENTATION_MODE = 'native-companion'
$taskbarLauncher = Join-Path $root 'ocp-launcher.exe'
if (Test-Path -LiteralPath $taskbarLauncher -PathType Leaf) {
    $env:OCP_TASKBAR_RELAUNCH_COMMAND = '"' + $taskbarLauncher + '"'
}
else {
    $env:OCP_TASKBAR_RELAUNCH_COMMAND = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
}
$env:OCP_TASKBAR_DISPLAY_NAME = 'OCP'
$env:OCP_TASKBAR_ICON_RESOURCE = $runtimeExe + ',0'
$env:OCP_BUNDLED_FONT_PATH = Join-Path $root 'fonts\NotoSansThai-VF.ttf'
$env:OCP_DESKTOP_SHELL_ENABLED = '1'
$env:OCP_DESKTOP_SHELL_FUNCTIONAL_ADAPTER = '1'
$env:OCP_DESKTOP_SHELL_EXECUTABLE = $desktopShellExe
$env:OCP_DESKTOP_SHELL_ROOT = $desktopShellRoot
if (-not [string]::IsNullOrWhiteSpace($storeOrigin)) {
    $env:OCP_STORE_LOOPBACK_ORIGINS = $storeOrigin
    $env:OCP_STORE_URL = "$storeOrigin/"
}
$env:OCP_UPDATER_EXE = $updaterExe
$env:OCP_UPDATE_STAGING_DIR = $(if ([string]::IsNullOrWhiteSpace($env:OCP_UPDATE_STAGING_DIR)) { $updateRoot } else { $env:OCP_UPDATE_STAGING_DIR })
$env:OCP_UPDATE_APPLY_SCRIPT = $applyHelper
$env:OCP_UPDATE_INSTALL_ROOT = $root
$env:OCP_UPDATE_START_SCRIPT = Join-Path $root 'Start-OCP.ps1'
$env:OCP_UPDATE_STATUS_FILE = $statusFile
$env:OCP_UPDATE_HEALTH_FILE = $healthFile

function Start-OcpProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.Arguments = (($Arguments | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    }) -join ' ')
    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw "Could not start $FilePath" }
    return $process
}

function Send-OcpProtocolUri {
    param([Parameter(Mandatory = $true)][string]$Uri)
    [void](Start-OcpProcess -FilePath $desktopShellExe -Arguments @($Uri))
}

function Get-OcpDesktopShellProcesses {
    return @(Get-Process -Name 'OCP' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $desktopShellExe } catch { $false }
    })
}

function Request-OcpDesktopShellShutdown {
    $ownedShells = @(Get-OcpDesktopShellProcesses)
    if ($ownedShells.Count -eq 0) { return }

    Write-Host '[OCP] Requesting Desktop Shell shutdown...' -ForegroundColor DarkCyan
    [void](Start-OcpProcess -FilePath $desktopShellExe -Arguments @('--ocp-exit=runtime-owner-shutdown'))

    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 200
        $remaining = @(Get-OcpDesktopShellProcesses)
        if ($remaining.Count -eq 0) {
            Write-Host '[OCP] Desktop Shell exited cleanly.' -ForegroundColor Green
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-OcpDesktopShellProcesses)
    if ($remaining.Count -gt 0) {
        Write-Warning "[OCP] Desktop Shell did not exit within 6 seconds; stopping $($remaining.Count) remaining OCP process(es)."
        foreach ($process in $remaining) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($validatedProtocolUri)) {
    $existingRuntime = Get-Process -Name 'ocp-runtime' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $runtimeExe } catch { $false }
    } | Select-Object -First 1
    if ($null -ne $existingRuntime) {
        Send-OcpProtocolUri -Uri $validatedProtocolUri
        return
    }
}

# If Runtime is gone but a packaged Shell survived a prior crash, retire only
# this install's OCP.exe before creating the new Runtime-owned bridge session.
# Otherwise the stale Shell could become the single-instance primary and keep
# the fresh bridge arguments away from the UI process.
Get-Process -Name 'OCP' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $desktopShellExe } catch { $false }
} | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

$kernel = $null
$native = $null
$runtime = $null
try {
    $kernel = Start-OcpProcess -FilePath $kernelExe
    $native = Start-OcpProcess -FilePath $nativeExe
    $env:OCP_UPDATE_PEER_PROCESS_IDS = "$($kernel.Id),$($native.Id)"
    $runtimeLog = Join-Path $logRoot "runtime-$session.log"
    $runtime = Start-OcpProcess -FilePath $runtimeExe -Arguments @('--log-file', $runtimeLog)

    if (-not [string]::IsNullOrWhiteSpace($validatedProtocolUri)) {
        $shellReady = $false
        for ($attempt = 0; $attempt -lt 80; $attempt++) {
            $runtime.Refresh()
            if ($runtime.HasExited) {
                throw "OCP Runtime exited before Desktop Shell protocol handoff. See $runtimeLog"
            }
            $ownedShell = Get-Process -Name 'OCP' -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -eq $desktopShellExe } catch { $false }
            } | Select-Object -First 1
            if ($null -ne $ownedShell) {
                $shellReady = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $shellReady) {
            throw 'OCP Desktop Shell did not become ready for protocol handoff within 20 seconds.'
        }
        Send-OcpProtocolUri -Uri $validatedProtocolUri
    }

    while (-not $native.HasExited) {
        if ($runtime.HasExited) {
            throw "OCP Runtime exited with code $($runtime.ExitCode). See $runtimeLog"
        }
        Start-Sleep -Milliseconds 250
        $native.Refresh()
        $runtime.Refresh()
    }

    $native.Refresh()
    if ($native.ExitCode -ne 0) {
        throw "OCP native host exited with code $($native.ExitCode)."
    }

    # Native Exit/Ctrl+Alt+Q uses the detach -> godot-exit-ready -> host-closed
    # handshake. Give Godot a bounded grace period to tear down its adopted HWND,
    # GDExtension, preview workers, and services before the final cleanup fallback.
    $runtime.Refresh()
    if (-not $runtime.HasExited) {
        Write-Host '[OCP] Waiting for Runtime graceful shutdown...' -ForegroundColor DarkCyan
        if (-not $runtime.WaitForExit(8000)) {
            Write-Warning '[OCP] Runtime did not finish graceful shutdown within 8 seconds; cleanup will stop it.'
        }
        else {
            $runtime.Refresh()
            if ($runtime.ExitCode -ne 0) {
                throw "OCP Runtime exited with code $($runtime.ExitCode). See $runtimeLog"
            }
            Write-Host '[OCP] Runtime exited cleanly (code 0).' -ForegroundColor Green
        }
    }

    # Explicit user shutdown is authoritative. Ask Electron's primary instance
    # to quit after Runtime/native teardown, while transient Runtime owner loss
    # remains recoverable during ordinary restart/rebind flows.
    Request-OcpDesktopShellShutdown
}
finally {
    foreach ($process in @($runtime, $native, $kernel)) {
        if ($null -ne $process) {
            try { $process.Refresh() } catch { }
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Remove-Item -LiteralPath $handoffPath,$eventPath,$commandPath,$uiCommandPath,$bubblePath -Force -ErrorAction SilentlyContinue
    foreach ($name in $managedEnvironmentNames) {
        [System.Environment]::SetEnvironmentVariable($name, $inheritedEnvironment[$name], 'Process')
    }
}
