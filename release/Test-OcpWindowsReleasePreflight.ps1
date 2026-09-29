[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory = $true)][ValidateSet('arm64', 'x86_64')]
    [string]$Arch,
    [string]$BuildGodotExe = '',
    [string]$RuntimeGodotExe = '',
    [string]$StarterPackagePath = '',
    [string]$EffectStarterPackagePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $releaseRoot
$portableBuilderPath = Join-Path $releaseRoot 'build_windows_portable.ps1'
$desktopShellPackagePath = Join-Path $repoRoot 'apps\desktop-shell\package.json'
$cargoConfigPath = Join-Path $repoRoot '.cargo\config.toml'
$godotPresetPath = Join-Path $repoRoot 'apps\desktop-runtime\godot\export_presets.cfg'

$wiring = @{
    arm64 = [pscustomobject]@{
        RustTarget = 'aarch64-pc-windows-msvc'
        ElectronFlag = '--arm64'
        SignerResource = 'tools/ocp-package-signer-arm64.exe'
        Preset = 'Windows Portable PCK arm64'
    }
    x86_64 = [pscustomobject]@{
        RustTarget = 'x86_64-pc-windows-msvc'
        ElectronFlag = '--x64'
        SignerResource = 'tools/ocp-package-signer-x64.exe'
        Preset = 'Windows Portable PCK x86_64'
    }
}
$selected = $wiring[$Arch]

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Needle, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Text.Contains($Needle)) { throw $Message }
}

function Get-WindowsPeArchitecture {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $resolved = (Resolve-Path -LiteralPath $Executable).Path
    $stream = [System.IO.File]::Open($resolved, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        try {
            $stream.Position = 0x3c
            $peOffset = $reader.ReadInt32()
            if ($peOffset -le 0 -or $peOffset + 6 -gt $stream.Length) { throw "Invalid PE header in: $Executable" }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature in: $Executable" }
            switch ($reader.ReadUInt16()) {
                0xAA64 { return 'arm64' }
                0x8664 { return 'x86_64' }
                default { throw "Unsupported Windows PE architecture in: $Executable" }
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

foreach ($required in @($portableBuilderPath, $desktopShellPackagePath, $cargoConfigPath, $godotPresetPath)) {
    Assert-True (Test-Path -LiteralPath $required -PathType Leaf) "Release prerequisite file is missing: $required"
}

$portableBuilder = Get-Content -LiteralPath $portableBuilderPath -Raw
$desktopShellPackage = Get-Content -LiteralPath $desktopShellPackagePath -Raw | ConvertFrom-Json
$cargoConfig = Get-Content -LiteralPath $cargoConfigPath -Raw
$godotPresets = Get-Content -LiteralPath $godotPresetPath -Raw

Write-Host "[PREFLIGHT] OCP Windows release version=$Version arch=$Arch rust=$($selected.RustTarget) electron=$($selected.ElectronFlag)"

Assert-Contains $portableBuilder "'aarch64-pc-windows-msvc'" 'Portable builder lost the Windows ARM64 Rust target wiring.'
Assert-Contains $portableBuilder "'x86_64-pc-windows-msvc'" 'Portable builder lost the Windows x64 Rust target wiring.'
Assert-Contains $portableBuilder "'--arm64'" 'Portable builder lost the Electron ARM64 flag wiring.'
Assert-Contains $portableBuilder "'--x64'" 'Portable builder lost the Electron x64 flag wiring.'
Assert-Contains $portableBuilder 'node_modules\.bin\electron-builder.cmd' 'Portable builder must invoke the pinned local electron-builder command directly.'
Assert-True (-not $portableBuilder.Contains('npm exec electron-builder --')) 'Portable builder must not route release packaging through npm exec; CI argument forwarding is not deterministic enough for the release output contract.'
Assert-Contains $portableBuilder 'cargo build --release --target $signerTriple -p ocp-package-signer' 'Portable builder must build both packaged native signer binaries before Electron packaging.'
Assert-Contains $portableBuilder '--publish never' 'Portable builder must disable electron-builder implicit CI publishing.'

foreach ($entry in @(
    [pscustomobject]@{ Target = 'aarch64-pc-windows-msvc'; Resource = 'tools/ocp-package-signer-arm64.exe'; Preset = 'Windows Portable PCK arm64' },
    [pscustomobject]@{ Target = 'x86_64-pc-windows-msvc'; Resource = 'tools/ocp-package-signer-x64.exe'; Preset = 'Windows Portable PCK x86_64' }
)) {
    Assert-Contains $cargoConfig "[target.$($entry.Target)]" "Cargo config is missing target wiring for $($entry.Target)."
    Assert-Contains $godotPresets ("name=`"$($entry.Preset)`"") "Godot export preset is missing: $($entry.Preset)"
    $resource = @($desktopShellPackage.build.extraResources | Where-Object { [string]$_.to -eq $entry.Resource } | Select-Object -First 1)
    Assert-True ($resource.Count -eq 1) "Electron package resources are missing signer mapping: $($entry.Resource)"
    Assert-True ([string]$resource[0].from -like "*target/$($entry.Target)/release/ocp-package-signer.exe" -or [string]$resource[0].from -like "*target\$($entry.Target)\release\ocp-package-signer.exe") "Signer resource '$($entry.Resource)' points at the wrong Rust target."
}

if (-not [string]::IsNullOrWhiteSpace($BuildGodotExe)) {
    Assert-True (Test-Path -LiteralPath $BuildGodotExe -PathType Leaf) "Godot build host was not found: $BuildGodotExe"
    $buildArch = Get-WindowsPeArchitecture -Executable $BuildGodotExe
    Write-Host "[PREFLIGHT] Godot build host architecture=$buildArch"
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeGodotExe)) {
    Assert-True (Test-Path -LiteralPath $RuntimeGodotExe -PathType Leaf) "Godot target runtime was not found: $RuntimeGodotExe"
    Assert-True ($RuntimeGodotExe -notmatch '_console\.exe$') 'RuntimeGodotExe must point to the GUI runtime executable, not the console companion.'
    $runtimeArch = Get-WindowsPeArchitecture -Executable $RuntimeGodotExe
    Assert-True ($runtimeArch -eq $Arch) "Godot target runtime architecture mismatch: requested=$Arch actual=$runtimeArch path=$RuntimeGodotExe"
    Write-Host "[PREFLIGHT] Godot target runtime architecture=$runtimeArch"
}
foreach ($artifact in @(
    [pscustomobject]@{ Label = 'Bible starter'; Path = $StarterPackagePath },
    [pscustomobject]@{ Label = 'Starter FX'; Path = $EffectStarterPackagePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($artifact.Path)) {
        Assert-True (Test-Path -LiteralPath $artifact.Path -PathType Leaf) "$($artifact.Label) package was not found: $($artifact.Path)"
        $item = Get-Item -LiteralPath $artifact.Path
        Assert-True ($item.Length -gt 0) "$($artifact.Label) package is empty: $($artifact.Path)"
        Write-Host "[PREFLIGHT] $($artifact.Label) bytes=$($item.Length)"
    }
}

Write-Host "[PREFLIGHT] PASS - release wiring is coherent for $Arch; expensive compile/package work may start."
