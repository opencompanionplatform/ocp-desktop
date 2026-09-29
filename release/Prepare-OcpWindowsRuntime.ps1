[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceExecutable,
    [Parameter(Mandatory = $true)][string]$DestinationExecutable,
    [string]$ManifestPath = '',
    [ValidateSet('Development', 'Release')][string]$Branding = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $releaseRoot
$rceditExe = Join-Path $repoRoot 'apps\desktop-shell\node_modules\electron-winstaller\vendor\rcedit.exe'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $releaseRoot 'windows\ocp-runtime-pmv2.manifest'
}

$SourceExecutable = [System.IO.Path]::GetFullPath($SourceExecutable)
$DestinationExecutable = [System.IO.Path]::GetFullPath($DestinationExecutable)
$ManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

foreach ($path in @($SourceExecutable, $ManifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "OCP runtime preparation input is missing: $path"
    }
}
if ([string]::Equals($SourceExecutable, $DestinationExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'SourceExecutable and DestinationExecutable must be different; the signed source runtime is immutable'
}

$nativeArchitecture = if (-not [string]::IsNullOrWhiteSpace([string]$env:PROCESSOR_ARCHITEW6432)) {
    [string]$env:PROCESSOR_ARCHITEW6432
} else {
    [string]$env:PROCESSOR_ARCHITECTURE
}
$hostToolArch = if ($nativeArchitecture.Trim().ToUpperInvariant() -eq 'ARM64') {
    'arm64'
} else {
    'x64'
}
$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$mt = Get-ChildItem -LiteralPath $kitsRoot -Filter mt.exe -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Directory.Name -eq $hostToolArch -and
        $_.Directory.Parent.Name -match '^\d+\.\d+'
    } |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if ([string]::IsNullOrWhiteSpace($mt)) {
    throw "Windows SDK mt.exe ($hostToolArch) was not found under $kitsRoot"
}
$signTool = Get-ChildItem -LiteralPath $kitsRoot -Filter signtool.exe -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Directory.Name -eq $hostToolArch -and
        $_.Directory.Parent.Name -match '^\d+\.\d+'
    } |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if ([string]::IsNullOrWhiteSpace($signTool)) {
    throw "Windows SDK signtool.exe ($hostToolArch) was not found under $kitsRoot"
}

$destinationDirectory = Split-Path -Parent $DestinationExecutable
New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
$source = Get-Item -LiteralPath $SourceExecutable
$manifest = Get-Item -LiteralPath $ManifestPath
$self = Get-Item -LiteralPath $MyInvocation.MyCommand.Path
$needsRefresh = -not (Test-Path -LiteralPath $DestinationExecutable -PathType Leaf)
if (-not $needsRefresh) {
    $destination = Get-Item -LiteralPath $DestinationExecutable
    $needsRefresh = $destination.LastWriteTimeUtc -lt $source.LastWriteTimeUtc `
        -or $destination.LastWriteTimeUtc -lt $manifest.LastWriteTimeUtc `
        -or $destination.LastWriteTimeUtc -lt $self.LastWriteTimeUtc
}

if ($needsRefresh) {
    Copy-Item -LiteralPath $SourceExecutable -Destination $DestinationExecutable -Force

    # Official Godot Windows executables are Authenticode-signed upstream. Any
    # PE resource edit invalidates that signature while leaving the security
    # directory in place. Strip only the destination copy before embedding OCP's
    # PMv2 manifest. Release builds keep the resulting Godot derivative unsigned
    # and preserve its upstream product identity; it is intentionally outside
    # OCP/SignPath Authenticode ownership.
    $upstreamSignature = Get-AuthenticodeSignature -LiteralPath $DestinationExecutable
    if ($null -ne $upstreamSignature.SignerCertificate) {
        $stripOutput = (& $signTool remove /s $DestinationExecutable 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Removing the upstream runtime Authenticode signature failed with exit code $LASTEXITCODE`n$stripOutput"
        }
        Write-Host "[OCP Runtime] stripped upstream Authenticode signature before PMv2 manifest embed"
    }

    if ($Branding -eq 'Development') {
        if (-not (Test-Path -LiteralPath $rceditExe -PathType Leaf)) {
            throw "OCP runtime branding tool is missing: $rceditExe"
        }
        $fileDescription = 'OCP Desktop Runtime (Development)'
        $originalFilename = Split-Path -Leaf $DestinationExecutable
        & $rceditExe $DestinationExecutable `
            --set-version-string FileDescription $fileDescription `
            --set-version-string ProductName 'OCP Desktop Runtime' `
            --set-version-string CompanyName 'Open Companion Platform' `
            --set-version-string InternalName 'OCPDesktopRuntime' `
            --set-version-string OriginalFilename $originalFilename
        if ($LASTEXITCODE -ne 0) {
            throw "Branding the OCP Desktop Runtime failed with exit code $LASTEXITCODE"
        }
        Write-Host "[OCP Runtime] development copy branded as $fileDescription"
    }
    else {
        $sourceVersionInfo = $source.VersionInfo
        if ($sourceVersionInfo.FileDescription -ne 'Godot Engine' -or
            $sourceVersionInfo.ProductName -ne 'Godot Engine') {
            throw "Release Runtime source must retain upstream Godot identity. FileDescription='$($sourceVersionInfo.FileDescription)' ProductName='$($sourceVersionInfo.ProductName)'"
        }
        Write-Host '[OCP Runtime] release copy retains upstream Godot product identity; only PMv2 manifest is patched'
    }

    $mtOutput = ''
    $mtExitCode = 1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $mtOutput = (& $mt -manifest $ManifestPath "-outputresource:$DestinationExecutable`;#1" 2>&1 | Out-String)
        $mtExitCode = $LASTEXITCODE
        if ($mtExitCode -eq 0) { break }
        if ($attempt -lt 3) {
            Write-Warning "PMv2 manifest embed attempt $attempt failed with exit code $mtExitCode; retrying after transient PE handle release."
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    if ($mtExitCode -ne 0) {
        throw "Embedding the OCP PMv2 manifest failed with exit code $mtExitCode after 3 attempts`n$mtOutput"
    }
}

$verificationPath = Join-Path $destinationDirectory ((Split-Path -Leaf $DestinationExecutable) + '.manifest.verify.xml')
try {
    $mtOutput = (& $mt "-inputresource:$DestinationExecutable`;#1" "-out:$verificationPath" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Reading the prepared OCP runtime manifest failed with exit code $LASTEXITCODE`n$mtOutput"
    }
    $verification = Get-Content -LiteralPath $verificationPath -Raw
    if (-not $verification.Contains('PerMonitorV2')) {
        throw 'Prepared OCP runtime does not declare PerMonitorV2 DPI awareness'
    }
}
finally {
    Remove-Item -LiteralPath $verificationPath -Force -ErrorAction SilentlyContinue
}

$versionInfo = (Get-Item -LiteralPath $DestinationExecutable).VersionInfo
if ($Branding -eq 'Development') {
    if ($versionInfo.FileDescription -ne 'OCP Desktop Runtime (Development)' -or $versionInfo.ProductName -ne 'OCP Desktop Runtime') {
        throw "Prepared OCP development runtime branding verification failed. FileDescription='$($versionInfo.FileDescription)' ProductName='$($versionInfo.ProductName)'"
    }
}
else {
    if ($versionInfo.FileDescription -ne 'Godot Engine' -or $versionInfo.ProductName -ne 'Godot Engine' -or $versionInfo.CompanyName -ne 'Godot Engine') {
        throw "Prepared release Runtime must retain upstream Godot identity. FileDescription='$($versionInfo.FileDescription)' ProductName='$($versionInfo.ProductName)' CompanyName='$($versionInfo.CompanyName)'"
    }
    $preparedSignature = Get-AuthenticodeSignature -LiteralPath $DestinationExecutable
    if ($null -ne $preparedSignature.SignerCertificate -or $preparedSignature.Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) {
        throw "Prepared release Runtime must remain unsigned after the PMv2 resource patch; found status=$($preparedSignature.Status)."
    }
    Write-Host '[OCP Runtime] upstream derivative boundary verified: Godot identity retained, OCP Authenticode excluded'
}

Write-Host "[OCP Runtime] PMv2 executable ready: $DestinationExecutable" -ForegroundColor DarkCyan
Write-Output $DestinationExecutable
