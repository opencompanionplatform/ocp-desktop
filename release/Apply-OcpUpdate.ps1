[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$InstallRoot,
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ArtifactPath,
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$StagingDirectory,
    [Parameter(Mandatory = $true)][string]$StartScript,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$CurrentVersion,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$TargetVersion,
    [Parameter(Mandatory = $true)][string]$StatusFile,
    [Parameter(Mandatory = $true)][string]$HealthFile,
    [string]$ProcessIds = '',
    [string]$RecoveryRoot = '',
    [ValidateRange(5, 300)][int]$ProcessTimeoutSeconds = 30,
    [ValidateRange(5, 300)][int]$HealthTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

# Child launchers change their working directory to the installation root. Keep
# updater coordination files absolute so health/status observation cannot drift
# when callers supplied relative paths (for example isolated RC acceptance).
$StatusFile = Get-FullPath $StatusFile
$HealthFile = Get-FullPath $HealthFile

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )
    $rootFull = (Get-FullPath $Root).TrimEnd('\') + '\'
    $candidateFull = Get-FullPath $Candidate
    return $candidateFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-ApplyStatus {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Version = $TargetVersion,
        [string]$PreviousVersion = $CurrentVersion
    )
    $parent = Split-Path -Parent $StatusFile
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $payload = [ordered]@{
        state = $State
        message = $Message
        version = $Version
        previousVersion = $PreviousVersion
        updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $temporary = "$StatusFile.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText(
        $temporary,
        ($payload | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $StatusFile -Force
}

function Get-VersionParts {
    param([Parameter(Mandatory = $true)][string]$Version)
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$') {
        throw "Invalid semantic version: $Version"
    }
    return @([int64]$Matches[1], [int64]$Matches[2], [int64]$Matches[3], [string]$Matches[4])
}

function Test-VersionIsNewer {
    param(
        [Parameter(Mandatory = $true)][string]$Current,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $currentParts = Get-VersionParts $Current
    $targetParts = Get-VersionParts $Target
    foreach ($index in 0..2) {
        if ($targetParts[$index] -ne $currentParts[$index]) {
            return $targetParts[$index] -gt $currentParts[$index]
        }
    }
    $currentPre = $currentParts[3]
    $targetPre = $targetParts[3]
    if ([string]::IsNullOrEmpty($currentPre) -and -not [string]::IsNullOrEmpty($targetPre)) { return $false }
    if (-not [string]::IsNullOrEmpty($currentPre) -and [string]::IsNullOrEmpty($targetPre)) { return $true }
    return ([string]::CompareOrdinal($targetPre, $currentPre) -gt 0)
}

function Get-BuildInfo {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root 'BUILD-INFO.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'BUILD-INFO.json is missing' }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw 'BUILD-INFO.json is invalid' }
}

function Assert-PortableBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            if ([System.IO.Path]::IsPathRooted($relative) -or
                $relative.Split('\') -contains '..' -or
                -not (Test-PathWithin $Destination (Join-Path $Destination $relative))) {
                throw "Unsafe ZIP entry: $($entry.FullName)"
            }
        }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
    }
    finally { $zip.Dispose() }

    $info = Get-BuildInfo $Destination
    if ($info.version -ne $TargetVersion) { throw "Target version mismatch: $($info.version) != $TargetVersion" }
    if ($info.platform -ne 'windows') { throw 'Target bundle is not a Windows bundle' }
    if ($info.architecture -notin @('arm64', 'x86_64')) { throw "Unsupported target architecture: $($info.architecture)" }
    if ([string]$info.format -ne 'portable-desktop') { throw "Target bundle format must be portable-desktop; found '$($info.format)'" }
    $storeOrigin = [string]$info.storeOrigin
    $storeUri = $null
    if ([string]::IsNullOrWhiteSpace($storeOrigin) -or -not [System.Uri]::TryCreate($storeOrigin, [System.UriKind]::Absolute, [ref]$storeUri) -or $storeUri.Scheme -ne 'https' -or $storeUri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($storeUri.Query) -or -not [string]::IsNullOrEmpty($storeUri.Fragment)) {
        throw "Target bundle has invalid storeOrigin: $storeOrigin"
    }
    $required = @(
        'BUILD-INFO.json', 'THIRD-PARTY-NOTICES.txt', 'ocp-launcher.exe', 'Start-OCP.ps1',
        'Apply-OcpUpdate.ps1', 'ocp-runtime.exe', 'ocp-runtime.pck',
        'desktop-shell\OCP.exe', 'desktop-shell\resources\app.asar',
        'bin\ocp-kernel.exe', 'bin\ocp-native-companion-window.exe',
        'bin\ocp-release-check.exe',
        "bin\windows\$($info.architecture)\ocp_desktop_runtime_ext.dll"
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $relative) -PathType Leaf)) {
            throw "Target bundle is missing: $relative"
        }
    }
    foreach ($name in @('logs', 'updates', 'updater', 'user-data', 'userdata', '.cache')) {
        if (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Container) {
            throw "Target bundle contains transient/runtime data directory: $name"
        }
    }
    return $info
}

function Wait-ForOcpProcesses {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)
    $ids = @($ProcessIds -split ',' | ForEach-Object {
        $value = $_.Trim()
        if ($value -match '^\d+$' -and [int]$value -ne $PID) { [int]$value }
    })
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $running = @($ids | ForEach-Object {
            try { Get-Process -Id $_ -ErrorAction Stop } catch { $null }
        } | Where-Object { $null -ne $_ -and -not $_.HasExited })
        if ($running.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "OCP processes did not exit before timeout: $($running.Id -join ',')"
}

function Stop-LauncherTree {
    param([System.Diagnostics.Process]$Launcher)

    # First ask Windows to terminate the launcher process tree while the parent
    # relationship still exists. A launcher can exit before its Runtime/native
    # children, however, so process-tree termination alone is not sufficient for
    # rollback: those surviving children can keep DLLs under InstallRoot locked.
    if ($null -ne $Launcher) {
        try {
            $Launcher.Refresh()
            if (-not $Launcher.HasExited) {
                & taskkill.exe /PID $Launcher.Id /T /F | Out-Null
            }
        }
        catch { }
    }

    $installRootValue = [string](Get-Variable -Name install -ValueOnly -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($installRootValue)) { return }
    $prefix = (Get-FullPath $installRootValue).TrimEnd('\\') + '\\'
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $survivors = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $path = [string]$_.ExecutablePath
            -not [string]::IsNullOrWhiteSpace($path) -and
                (Get-FullPath $path).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($survivors.Count -eq 0) { return }
        foreach ($process in $survivors) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
}

function Start-OcpLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )
    Remove-Item -LiteralPath $HealthFile -Force -ErrorAction SilentlyContinue
    $env:OCP_UPDATE_HEALTH_FILE = $HealthFile
    $env:OCP_UPDATE_EXPECTED_VERSION = $ExpectedVersion
    $workingDirectory = Split-Path -Parent $LauncherPath
    if ([System.IO.Path]::GetExtension($LauncherPath) -ieq '.exe') {
        return Start-Process -FilePath $LauncherPath -WorkingDirectory $workingDirectory -WindowStyle Hidden -PassThru
    }
    return Start-Process -FilePath 'powershell.exe' -WorkingDirectory $workingDirectory `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LauncherPath) `
        -WindowStyle Hidden -PassThru
}

function Wait-ForHealth {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Launcher,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Launcher.Refresh()
        if (Test-Path -LiteralPath $HealthFile -PathType Leaf) {
            try {
                $health = Get-Content -LiteralPath $HealthFile -Raw | ConvertFrom-Json
                if ($health.state -eq 'ready' -and $health.version -eq $ExpectedVersion) { return }
            }
            catch { }
        }
        if ($Launcher.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        else { Start-Sleep -Milliseconds 250 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Target runtime did not become healthy within $TimeoutSeconds seconds"
}

$install = Get-FullPath $InstallRoot
$artifact = Get-FullPath $ArtifactPath
$staging = Get-FullPath $StagingDirectory
$start = Get-FullPath $StartScript
$startLeaf = Split-Path -Leaf $start
if ($startLeaf -notin @('ocp-launcher.exe', 'Start-OCP.ps1')) { throw "Unsupported OCP start entry point: $startLeaf" }
if (-not (Test-PathWithin $staging $artifact)) { throw 'Artifact must be inside the update staging directory' }
if (-not (Test-PathWithin $install $start)) { throw 'Start entry point must belong to the current installation' }
if (-not (Test-VersionIsNewer $CurrentVersion $TargetVersion)) { throw "Downgrade or duplicate version refused: $CurrentVersion -> $TargetVersion" }
if ([string]::IsNullOrWhiteSpace($RecoveryRoot)) { $RecoveryRoot = Join-Path $env:LOCALAPPDATA 'OCP\recovery' }
$recovery = Get-FullPath $RecoveryRoot
$transactionId = [guid]::NewGuid().ToString('N')
$transactionRoot = Join-Path $recovery "transactions\$transactionId"
$incoming = Join-Path $transactionRoot 'incoming'
$pendingOld = Join-Path $transactionRoot 'previous-install'
$previous = Join-Path $recovery 'previous'
$launcher = $null
$swapped = $false

try {
    Write-ApplyStatus 'apply_requested' "Applying update $TargetVersion after explicit user approval"
    New-Item -ItemType Directory -Force -Path $incoming | Out-Null
    Write-ApplyStatus 'stopping' 'Waiting for the running OCP processes to exit'
    Wait-ForOcpProcesses -TimeoutSeconds $ProcessTimeoutSeconds
    Write-ApplyStatus 'validating' 'Validating signed staged bundle contents'
    [void](Assert-PortableBundle -Archive $artifact -Destination $incoming)

    New-Item -ItemType Directory -Force -Path $recovery | Out-Null
    Write-ApplyStatus 'swapping' 'Switching the per-user installation transactionally'
    Move-Item -LiteralPath $install -Destination $pendingOld
    try {
        Move-Item -LiteralPath $incoming -Destination $install
        $swapped = $true
    }
    catch {
        if (Test-Path -LiteralPath $pendingOld) { Move-Item -LiteralPath $pendingOld -Destination $install -Force }
        throw
    }

    Write-ApplyStatus 'restarting' "Starting OCP $TargetVersion and waiting for its health marker"
    $launcher = Start-OcpLauncher -LauncherPath (Join-Path $install $startLeaf) -ExpectedVersion $TargetVersion
    Wait-ForHealth -Launcher $launcher -ExpectedVersion $TargetVersion -TimeoutSeconds $HealthTimeoutSeconds

    if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
    Move-Item -LiteralPath $pendingOld -Destination $previous
    Write-ApplyStatus 'applied' "Update $TargetVersion applied and passed startup health"
    Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    $failure = $_.Exception.Message
    if ($null -ne $launcher) { Stop-LauncherTree $launcher }
    if ($swapped) {
        try {
            if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
            if (Test-Path -LiteralPath $pendingOld) { Move-Item -LiteralPath $pendingOld -Destination $install -Force }
            $rollbackLauncher = Start-OcpLauncher -LauncherPath (Join-Path $install $startLeaf) -ExpectedVersion $CurrentVersion
            try { Wait-ForHealth -Launcher $rollbackLauncher -ExpectedVersion $CurrentVersion -TimeoutSeconds $HealthTimeoutSeconds }
            catch { Stop-LauncherTree $rollbackLauncher }
            Write-ApplyStatus 'rolled_back' "Update $TargetVersion failed and the previous version was restored: $failure" $CurrentVersion $TargetVersion
        }
        catch {
            $rollbackFailure = $_.Exception.Message
            Write-ApplyStatus 'rollback_failed' "Update $TargetVersion failed: $failure. Automatic rollback also failed: $rollbackFailure" $TargetVersion $CurrentVersion
            throw "Update $TargetVersion failed: $failure. Automatic rollback also failed: $rollbackFailure"
        }
    }
    else {
        Write-ApplyStatus 'failed' "Update $TargetVersion was rejected; installation was not modified: $failure"
    }
    Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
