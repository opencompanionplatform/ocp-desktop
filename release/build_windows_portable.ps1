[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [ValidateSet('arm64', 'x86_64')][string]$Arch = 'arm64',
    [Parameter(Mandatory = $true)][string]$BuildGodotExe,
    [Parameter(Mandatory = $true)][string]$RuntimeGodotExe,
    [ValidateRange(10, 300)][int]$GodotExportTimeoutSeconds = 120,
    [string]$OutputDirectory = '',
    [string]$StoreOrigin = 'https://ocp-store-staging.pages.dev',
    [string]$StarterPackagePath = '',
    [string]$EffectStarterPackagePath = '',
    [switch]$StagingTrust
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $releaseRoot
$runtimeRoot = Join-Path $repoRoot 'apps\desktop-runtime'
$desktopShellRoot = Join-Path $repoRoot 'apps\desktop-shell'
$animationStudioRoot = Join-Path $repoRoot 'apps\animation-studio\app'
$godotProject = Join-Path $runtimeRoot 'godot'
$targetTriple = if ($Arch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$artifactName = "ocp-windows-$Arch-$Version.zip"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $releaseRoot 'out'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$desktopShellPackageOutput = Join-Path $OutputDirectory ".desktop-shell-$Arch-$Version"
$godotExportProject = Join-Path $OutputDirectory ".godot-export-$Arch-$Version"
$godotPckHostProject = Join-Path $OutputDirectory ".godot-pck-host-$Arch-$Version"
$localPckPacker = Join-Path $releaseRoot 'tools\Pack-OcpLocalRuntimePck.gd'
$pckVerifier = Join-Path $releaseRoot 'Test-OcpRuntimePck.ps1'
$bundle = Join-Path $OutputDirectory "ocp-windows-$Arch-$Version"
$zipPath = Join-Path $OutputDirectory $artifactName
$manifestPath = Join-Path $OutputDirectory 'update-manifest.unsigned.json'
$godotExportLog = Join-Path $OutputDirectory "godot-export-$Arch-$Version.log"
$coreFontSource = Join-Path $godotProject 'assets\fonts\NotoSansThai-VF.ttf'
$coreFontLicenseSource = Join-Path $godotProject 'assets\fonts\OFL-NotoSansThai.txt'
if (-not (Test-Path -LiteralPath $coreFontSource -PathType Leaf)) { throw "Bundled Noto Sans Thai font not found: $coreFontSource" }
if (-not (Test-Path -LiteralPath $coreFontLicenseSource -PathType Leaf)) { throw "Bundled Noto Sans Thai license not found: $coreFontLicenseSource" }
$starterPackageFilename = 'character.bible-1.0.0.ocp'
if ([string]::IsNullOrWhiteSpace($StarterPackagePath)) {
    $fromEnvironment = [Environment]::GetEnvironmentVariable('OCP_EMBEDDED_STARTER_PACKAGE')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
        $StarterPackagePath = $fromEnvironment
    }
    else {
        $StarterPackagePath = Join-Path $releaseRoot ('starter-local\\' + $starterPackageFilename)
    }
}
$StarterPackagePath = [System.IO.Path]::GetFullPath($StarterPackagePath)
if (-not (Test-Path -LiteralPath $StarterPackagePath -PathType Leaf)) {
    throw "Embedded Bible starter package not found: $StarterPackagePath. Supply -StarterPackagePath or OCP_EMBEDDED_STARTER_PACKAGE."
}

$effectStarterPackageFilename = 'effect.starter-neon-1.0.0.ocp'
if ([string]::IsNullOrWhiteSpace($EffectStarterPackagePath)) {
    $effectFromEnvironment = [Environment]::GetEnvironmentVariable('OCP_EMBEDDED_STARTER_EFFECT_PACK')
    if (-not [string]::IsNullOrWhiteSpace($effectFromEnvironment)) {
        $EffectStarterPackagePath = $effectFromEnvironment
    }
    else {
        $EffectStarterPackagePath = Join-Path $releaseRoot ('starter-local\\' + $effectStarterPackageFilename)
    }
}
$EffectStarterPackagePath = [System.IO.Path]::GetFullPath($EffectStarterPackagePath)
if (-not (Test-Path -LiteralPath $EffectStarterPackagePath -PathType Leaf)) {
    throw "Embedded Starter FX package not found: $EffectStarterPackagePath. Supply -EffectStarterPackagePath or OCP_EMBEDDED_STARTER_EFFECT_PACK."
}

foreach ($path in @($BuildGodotExe, $RuntimeGodotExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Godot executable not found: $path"
    }
}

# Release/export builds must not share the repo with a live source Runtime. A
# running Godot/Kernel/Desktop Shell can hold generated DLL/PCK resources and
# make the headless editor appear to hang until the export timeout. Fail fast
# with an actionable message instead of silently producing a local fallback.
try {
    $repoNeedle = $repoRoot.ToLowerInvariant()
    $liveRepoProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $commandLine = [string]$_.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
        $lower = $commandLine.ToLowerInvariant()
        $lower.Contains($repoNeedle) -and $_.Name -in @(
            'ocp-godot-pmv2.exe',
            'ocp-kernel.exe',
            'ocp-native-companion-window-spike.exe',
            'OCP-Desktop-Dev.exe',
            'electron.exe'
        )
    })
    if ($liveRepoProcesses.Count -gt 0) {
        $summary = ($liveRepoProcesses | ForEach-Object { "$($_.Name) PID=$($_.ProcessId)" }) -join ', '
        throw "OCP source Runtime is still running from this repo: $summary. Exit OCP before building a portable/release artifact."
    }
}
catch {
    if ($_.Exception.Message -like 'OCP source Runtime is still running*') { throw }
    Write-Warning "Could not verify source Runtime process state before build: $($_.Exception.Message)"
}

function Resolve-GodotCliExecutable {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $resolved = (Resolve-Path -LiteralPath $Executable).Path
    if ($resolved -match '_console\.exe$') {
        return $resolved
    }

    $directory = Split-Path -Parent $resolved
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
    $consoleCandidate = Join-Path $directory ($baseName + '_console.exe')
    if (Test-Path -LiteralPath $consoleCandidate -PathType Leaf) {
        Write-Host "[OCP Release] Godot CLI resolved to console executable: $consoleCandidate"
        return $consoleCandidate
    }

    Write-Warning "Godot console companion was not found next to '$resolved'. CLI export will use the supplied executable, which may detach on Windows."
    return $resolved
}

function Get-WindowsPeArchitecture {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $stream = [System.IO.File]::Open((Resolve-Path -LiteralPath $Executable).Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        try {
            $stream.Position = 0x3c
            $peOffset = $reader.ReadInt32()
            if ($peOffset -le 0 -or $peOffset + 6 -gt $stream.Length) {
                throw "Invalid PE header in: $Executable"
            }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) {
                throw "Invalid PE signature in: $Executable"
            }
            switch ($reader.ReadUInt16()) {
                0xAA64 { return 'arm64' }
                0x8664 { return 'x86_64' }
                default { throw "Unsupported Godot PE architecture in: $Executable" }
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

$buildGodotCli = Resolve-GodotCliExecutable -Executable $BuildGodotExe
$buildHostArch = Get-WindowsPeArchitecture -Executable $buildGodotCli
$buildHostTriple = if ($buildHostArch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$runtimeGodotResolved = (Resolve-Path -LiteralPath $RuntimeGodotExe).Path
if ($runtimeGodotResolved -match '_console\.exe$') {
    throw 'RuntimeGodotExe must be the target GUI runtime executable, not the Godot console companion.'
}
$runtimeGodotArch = Get-WindowsPeArchitecture -Executable $runtimeGodotResolved
if ($runtimeGodotArch -ne $Arch) {
    throw "Runtime Godot architecture mismatch: expected $Arch, found $runtimeGodotArch ($runtimeGodotResolved)"
}
Write-Host "[OCP Release] Godot build host architecture=$buildHostArch target architecture=$Arch runtime architecture=$runtimeGodotArch"

if (-not (Test-Path -LiteralPath (Join-Path $desktopShellRoot 'package.json') -PathType Leaf)) {
    throw "Desktop Shell project not found: $desktopShellRoot"
}
foreach ($frontendRoot in @($animationStudioRoot, $desktopShellRoot)) {
    foreach ($requiredFile in @('package.json', 'package-lock.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $frontendRoot $requiredFile) -PathType Leaf)) {
            throw "Locked frontend dependency file not found: $(Join-Path $frontendRoot $requiredFile)"
        }
    }
}
$storeUri = $null
if (-not [System.Uri]::TryCreate($StoreOrigin, [System.UriKind]::Absolute, [ref]$storeUri) -or $storeUri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($storeUri.UserInfo) -or $storeUri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($storeUri.Query) -or -not [string]::IsNullOrEmpty($storeUri.Fragment)) {
    throw 'StoreOrigin must be an HTTPS origin root without credentials, path, query, or fragment.'
}
$StoreOrigin = $storeUri.GetLeftPart([System.UriPartial]::Authority)

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShellPackageOutput -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $godotExportProject -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $godotPckHostProject -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zipPath,$manifestPath,$godotExportLog -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $bundle "bin\windows\$Arch") | Out-Null
$coreFontBundleDir = Join-Path $bundle 'fonts'
New-Item -ItemType Directory -Force -Path $coreFontBundleDir | Out-Null
Copy-Item -LiteralPath $coreFontSource -Destination (Join-Path $coreFontBundleDir 'NotoSansThai-VF.ttf') -Force
Copy-Item -LiteralPath $coreFontLicenseSource -Destination (Join-Path $coreFontBundleDir 'OFL-NotoSansThai.txt') -Force
$starterBundleDir = Join-Path $bundle 'starter'
New-Item -ItemType Directory -Force -Path $starterBundleDir | Out-Null
$starterBundlePath = Join-Path $starterBundleDir $starterPackageFilename
Copy-Item -LiteralPath $StarterPackagePath -Destination $starterBundlePath -Force
$starterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $starterBundlePath).Hash.ToLowerInvariant()
Write-Host "[OCP Release] Embedded Bible starter bundled: $starterBundlePath sha256=$starterHash"
$effectStarterBundlePath = Join-Path $starterBundleDir $effectStarterPackageFilename
Copy-Item -LiteralPath $EffectStarterPackagePath -Destination $effectStarterBundlePath -Force
$effectStarterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $effectStarterBundlePath).Hash.ToLowerInvariant()
Write-Host "[OCP Release] Embedded Starter FX bundled: $effectStarterBundlePath sha256=$effectStarterHash"

function Invoke-Checked {
    param([Parameter(Mandatory = $true)][scriptblock]$Command, [Parameter(Mandatory = $true)][string]$Label)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}

function New-IsolatedGodotExportProject {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    foreach ($directory in @('assets','bin','scenes','scripts','shaders','themes')) {
        $sourceDirectory = Join-Path $Source $directory
        if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
            Copy-Item -LiteralPath $sourceDirectory -Destination (Join-Path $Destination $directory) -Recurse -Force
        }
    }
    foreach ($file in @('project.godot','export_presets.cfg','ocp_runtime.gdextension','ocp_runtime.gdextension.uid')) {
        $sourceFile = Join-Path $Source $file
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "Godot export project is missing required file: $file"
        }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $Destination $file) -Force
    }

    Write-Host "[OCP Release] Isolated Godot export project ready: $Destination"
}

function Invoke-BoundedGodotEditorExport {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Preset,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $repoRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    # Godot editor export is intentionally isolated from the interactive user's
    # editor profile. A corrupt/stale editor cache or theme/settings file under
    # %APPDATA% can stall even an empty headless project before filesystem scan.
    # PCK export itself does not need the user's editor profile, so give every
    # release export a fresh per-run APPDATA/LOCALAPPDATA sandbox.
    $profileRoot = Join-Path (Split-Path -Parent $LogPath) ('.' + [System.IO.Path]::GetFileNameWithoutExtension($LogPath) + '-profile')
    Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
    $profileRoaming = Join-Path $profileRoot 'Roaming'
    $profileLocal = Join-Path $profileRoot 'Local'
    New-Item -ItemType Directory -Force -Path $profileRoaming, $profileLocal | Out-Null
    $info.EnvironmentVariables['APPDATA'] = $profileRoaming
    $info.EnvironmentVariables['LOCALAPPDATA'] = $profileLocal

    $args = @('--headless','--recovery-mode','--path',$ProjectPath,'--export-pack',$Preset,$OutputPath)
    $info.Arguments = (($args | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')

    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -eq $process) {
        throw 'Could not start Godot export process.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        Write-Warning "Godot editor export exceeded ${TimeoutSeconds}s; terminating PID $($process.Id) and evaluating local-only fallback policy."
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        & $taskkill /PID $process.Id /T /F | Out-Null
        try { [void]$process.WaitForExit(5000) } catch { }
    }

    $stdout = try { [string]$stdoutTask.Result } catch { '' }
    $stderr = try { [string]$stderrTask.Result } catch { '' }
    $logText = @(
        "Executable: $Executable",
        "Project: $ProjectPath",
        "Preset: $Preset",
        "Output: $OutputPath",
        "EditorProfile: $profileRoot",
        "TimedOut: $timedOut",
        "ExitCode: $(if ($timedOut) { '<timeout>' } else { $process.ExitCode })",
        '',
        '--- STDOUT ---',
        $stdout,
        '',
        '--- STDERR ---',
        $stderr
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($LogPath, $logText, [System.Text.UTF8Encoding]::new($false))

    if ($timedOut) {
        return [pscustomobject]@{ Completed = $false; ExitCode = $null; TimedOut = $true; LogPath = $LogPath }
    }
    return [pscustomobject]@{ Completed = ($process.ExitCode -eq 0); ExitCode = $process.ExitCode; TimedOut = $false; LogPath = $LogPath }
}

function New-GodotPckHostProject {
    param([Parameter(Mandatory = $true)][string]$Destination)
    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $content = '[application]' + "`r`n" + 'config/name="OCP Local PCK Host"' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $Destination 'project.godot'), $content, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-LocalSourcePckFallback {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    if ($Version -notmatch '-local\.') {
        throw "Godot editor export failed and raw-source PCK fallback is forbidden for publishable version '$Version'. Use a working Godot editor/export host."
    }
    if (-not (Test-Path -LiteralPath $localPckPacker -PathType Leaf)) {
        throw "Local PCK fallback helper is missing: $localPckPacker"
    }

    Write-Warning 'Using LOCAL-ONLY raw GDScript PCK fallback. This artifact is not publishable.'
    New-GodotPckHostProject -Destination $godotPckHostProject
    & $buildGodotCli --headless --path $godotPckHostProject --script $localPckPacker -- $godotProject $OutputPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Local PCK fallback failed with exit code $LASTEXITCODE."
    }
}

$releasePreflight = Join-Path $releaseRoot 'Test-OcpWindowsReleasePreflight.ps1'
if (-not (Test-Path -LiteralPath $releasePreflight -PathType Leaf)) {
    throw "Release preflight helper is missing: $releasePreflight"
}
& $releasePreflight `
    -Version $Version `
    -Arch $Arch `
    -BuildGodotExe $buildGodotCli `
    -RuntimeGodotExe $runtimeGodotResolved `
    -StarterPackagePath $StarterPackagePath `
    -EffectStarterPackagePath $EffectStarterPackagePath

Push-Location $animationStudioRoot
try {
    Invoke-Checked { npm ci } 'install Animation Studio dependencies'
}
finally {
    Pop-Location
}

Push-Location $desktopShellRoot
try {
    Invoke-Checked { npm ci } 'install Desktop Shell dependencies'
}
finally {
    Pop-Location
}

Push-Location $repoRoot
try {
    Invoke-Checked { rustup target add $targetTriple } 'install Rust target'
    if ($buildHostTriple -ne $targetTriple) {
        Invoke-Checked { rustup target add $buildHostTriple } 'install editor-host Rust target'
    }
    $signerTriples = @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')
    foreach ($signerTriple in $signerTriples) {
        Invoke-Checked { rustup target add $signerTriple } "install signer Rust target $signerTriple"
        Invoke-Checked { cargo build --release --target $signerTriple -p ocp-package-signer } "build package signer $signerTriple"
        $signerOutput = Join-Path $repoRoot "target\$signerTriple\release\ocp-package-signer.exe"
        if (-not (Test-Path -LiteralPath $signerOutput -PathType Leaf)) {
            throw "Package signer build reported success but output is missing: $signerOutput"
        }
    }
    $runtimeTrustArgs = @{}
    if ($StagingTrust) { $runtimeTrustArgs['StagingTrust'] = $true }
    Invoke-Checked { & (Join-Path $runtimeRoot 'build.ps1') -Profile release -Arch $Arch @runtimeTrustArgs } 'build runtime GDExtension'
    if ($buildHostArch -ne $Arch) {
        Invoke-Checked { & (Join-Path $runtimeRoot 'build.ps1') -Profile release -Arch $buildHostArch @runtimeTrustArgs } 'build editor-host GDExtension'
    }
    Invoke-Checked { cargo build --release --target $targetTriple -p ocp-kernel } 'build kernel'
    Invoke-Checked { cargo build --release --target $targetTriple -p ocp-launcher } 'build native launcher'
    Invoke-Checked { cargo build --release --target $targetTriple -p ocp-release-core --bin ocp-release-check } 'build Rust updater'
    Invoke-Checked { cargo build --release --target $targetTriple --manifest-path (Join-Path $repoRoot 'spike\native-companion-window\Cargo.toml') } 'build native host'

    $electronArchFlag = if ($Arch -eq 'arm64') { '--arm64' } else { '--x64' }
    Push-Location $desktopShellRoot
    try {
        Invoke-Checked { npm run build } 'build Electron Desktop Shell'
        $electronBuilderCmd = Join-Path $desktopShellRoot 'node_modules\.bin\electron-builder.cmd'
        if (-not (Test-Path -LiteralPath $electronBuilderCmd -PathType Leaf)) {
            throw "Pinned electron-builder command was not installed: $electronBuilderCmd"
        }
        Write-Host "[OCP Release] Electron package arch=$Arch flag=$electronArchFlag output=$desktopShellPackageOutput"
        Invoke-Checked {
            & $electronBuilderCmd --win --dir $electronArchFlag --publish never `
                "--config.directories.output=$desktopShellPackageOutput" `
                "--config.extraMetadata.version=$Version"
        } 'package Electron Desktop Shell'
    }
    finally {
        Pop-Location
    }
    $desktopShellPackage = Get-ChildItem -LiteralPath $desktopShellPackageOutput -Directory | Where-Object {
        $_.Name -like 'win*-unpacked'
    } | Select-Object -First 1
    if ($null -eq $desktopShellPackage -or -not (Test-Path -LiteralPath (Join-Path $desktopShellPackage.FullName 'OCP.exe') -PathType Leaf)) {
        throw "Electron Desktop Shell package was not produced under: $desktopShellPackageOutput"
    }

    $pckPath = Join-Path $bundle 'ocp-runtime.pck'
    $exportPreset = "Windows Portable PCK $Arch"
    $pckMode = 'editor-export'
    New-IsolatedGodotExportProject -Source $godotProject -Destination $godotExportProject
    $exportResult = Invoke-BoundedGodotEditorExport `
        -Executable $buildGodotCli `
        -ProjectPath $godotExportProject `
        -Preset $exportPreset `
        -OutputPath $pckPath `
        -TimeoutSeconds $GodotExportTimeoutSeconds `
        -LogPath $godotExportLog

    if (-not $exportResult.Completed -or -not (Test-Path -LiteralPath $pckPath -PathType Leaf)) {
        $reason = if ($exportResult.TimedOut) { 'timeout' } else { "exit=$($exportResult.ExitCode)" }
        Write-Warning "Godot editor PCK export did not complete ($reason). Diagnostic log: $($exportResult.LogPath)"
        if (Test-Path -LiteralPath $exportResult.LogPath -PathType Leaf) {
            Write-Host '[OCP Release] Godot export diagnostic tail:'
            Get-Content -LiteralPath $exportResult.LogPath -Tail 40 | ForEach-Object { Write-Host "  $_" }
        }
        Invoke-LocalSourcePckFallback -OutputPath $pckPath
        $pckMode = 'source-fallback-local'
    }

    if (-not (Test-Path -LiteralPath $pckPath -PathType Leaf)) {
        throw "Godot PCK was not produced: $pckPath"
    }
    if (-not (Test-Path -LiteralPath $pckVerifier -PathType Leaf)) {
        throw "PCK verification helper is missing: $pckVerifier"
    }
    $pckVerification = if ($pckMode -eq 'editor-export') {
        & $pckVerifier -GodotExe $buildGodotCli -PckPath $pckPath -RequirePublishable
    }
    else {
        & $pckVerifier -GodotExe $buildGodotCli -PckPath $pckPath
    }
    $pckContentVerified = $null -ne $pckVerification -and $pckVerification.Publishable -eq $true
    if ($pckMode -eq 'editor-export' -and -not $pckContentVerified) {
        throw 'Godot editor export did not pass compiled-PCK content verification.'
    }
    Write-Host "[OCP Release] PCK ready mode=$pckMode verified=$pckContentVerified bytes=$((Get-Item -LiteralPath $pckPath).Length)"

    & (Join-Path $releaseRoot 'Prepare-OcpWindowsRuntime.ps1') `
        -SourceExecutable $runtimeGodotResolved `
        -DestinationExecutable (Join-Path $bundle 'ocp-runtime.exe') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "target\$targetTriple\release\ocp-kernel.exe") -Destination (Join-Path $bundle 'bin\ocp-kernel.exe') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "target\$targetTriple\release\ocp-launcher.exe") -Destination (Join-Path $bundle 'ocp-launcher.exe') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "target\$targetTriple\release\ocp-release-check.exe") -Destination (Join-Path $bundle 'bin\ocp-release-check.exe') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "spike\native-companion-window\target\$targetTriple\release\ocp-native-companion-window-spike.exe") -Destination (Join-Path $bundle 'bin\ocp-native-companion-window.exe') -Force
    Copy-Item -LiteralPath (Join-Path $godotProject "bin\windows\$Arch\ocp_desktop_runtime_ext.dll") -Destination (Join-Path $bundle "bin\windows\$Arch\ocp_desktop_runtime_ext.dll") -Force
    $desktopShellBundle = Join-Path $bundle 'desktop-shell'
    New-Item -ItemType Directory -Force -Path $desktopShellBundle | Out-Null
    Copy-Item -Path (Join-Path $desktopShellPackage.FullName '*') -Destination $desktopShellBundle -Recurse -Force
    if (-not (Test-Path -LiteralPath (Join-Path $desktopShellBundle 'OCP.exe') -PathType Leaf)) {
        throw 'Packaged Desktop Shell is missing OCP.exe after bundle copy.'
    }
    Remove-Item -LiteralPath $desktopShellPackageOutput -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $releaseRoot 'Start-OCP.ps1') -Destination (Join-Path $bundle 'Start-OCP.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $releaseRoot 'Apply-OcpUpdate.ps1') -Destination (Join-Path $bundle 'Apply-OcpUpdate.ps1') -Force

    $commit = (git rev-parse HEAD).Trim()
    $buildInfo = [ordered]@{
        product = 'Open Companion Platform'
        version = $Version
        platform = 'windows'
        architecture = $Arch
        commit = $commit
        format = 'portable-desktop'
        storeOrigin = $StoreOrigin
        desktopShell = 'desktop-shell/OCP.exe'
        embeddedStarter = 'starter/character.bible-1.0.0.ocp'
        embeddedStarterSha256 = $starterHash
        embeddedEffectStarter = 'starter/effect.starter-neon-1.0.0.ocp'
        embeddedEffectStarterSha256 = $effectStarterHash
        pckMode = $pckMode
        pckContentVerified = $pckContentVerified
        publishable = ($pckMode -eq 'editor-export' -and $pckContentVerified)
    } | ConvertTo-Json
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $bundle 'BUILD-INFO.json'), $buildInfo, $utf8)
    [System.IO.File]::WriteAllText(
        (Join-Path $bundle 'THIRD-PARTY-NOTICES.txt'),
        "This portable POC bundles Godot Engine 4.7.1 (MIT License).`r`nhttps://godotengine.org/license/`r`n`r`nNoto Sans Thai is bundled under the SIL Open Font License 1.1.`r`nSee fonts\OFL-NotoSansThai.txt.`r`n",
        $utf8
    )

    if (-not (Test-Path -LiteralPath $pckPath -PathType Leaf)) {
        throw "Godot PCK was not produced: $pckPath"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $bundle,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        # ZipArchive may preserve Windows separators when CreateFromDirectory is
        # called on Windows. Compare normalized archive names so validation is
        # portable and does not reject a ZIP that contains the required file.
        $normalizedEntries = @($zipArchive.Entries | ForEach-Object {
            [pscustomobject]@{ Entry = $_; Name = ($_.FullName -replace '\\', '/') }
        })
        if ($null -eq ($normalizedEntries | Where-Object Name -eq 'ocp-runtime.pck' | Select-Object -First 1)) {
            throw "Portable ZIP is missing ocp-runtime.pck"
        }
        if ($null -eq ($normalizedEntries | Where-Object Name -eq 'desktop-shell/OCP.exe' | Select-Object -First 1)) {
            throw "Portable ZIP is missing desktop-shell/OCP.exe"
        }
    }
    finally {
        $zipArchive.Dispose()
    }
    $artifact = Get-Item -LiteralPath $zipPath
    $sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $tag = "v$Version"
    $manifest = [ordered]@{
        schema = 'ocp-update/1'
        channel = 'stable'
        version = $Version
        publishedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        releaseNotesUrl = "https://github.com/opencompanionplatform/ocp-releases/releases/tag/$tag"
        artifacts = @([ordered]@{
            platform = 'windows'
            arch = $Arch
            url = "https://github.com/opencompanionplatform/ocp-releases/releases/download/$tag/$artifactName"
            size = $artifact.Length
            sha256 = $sha256
        })
    } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($manifestPath, $manifest, $utf8)

    Write-Host "artifactPath=$zipPath"
    Write-Host "manifestPath=$manifestPath"
    Write-Host "artifactName=$artifactName"
    Write-Host "sha256=$sha256"
}
finally {
    Remove-Item -LiteralPath $godotExportProject -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $godotPckHostProject -Recurse -Force -ErrorAction SilentlyContinue
    Pop-Location
}
