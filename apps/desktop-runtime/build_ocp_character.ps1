[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CharacterRoot,

    [ValidateRange(0, 100)]
    [int]$ChromaFuzz = 4,

    [switch]$PreviewOnly,

    [switch]$SkipImageValidation,

    [switch]$KeepTemp,

    [string]$MagickExe = "magick"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($CharacterRoot)
$configPath = Join-Path $root "character.build.json"
$sourceRoot = Join-Path $root "animations"
$runtimeRoot = Join-Path $root "runtime"
$runtimeAnimations = Join-Path $runtimeRoot "animations"
$packageRoot = Join-Path $runtimeRoot "_package"
$packageAssets = Join-Path $packageRoot "assets"
$tempRoot = Join-Path $runtimeRoot "_temp"
$runtimeCharacterPath = Join-Path $runtimeRoot "character.json"

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "============================================================" `
        -ForegroundColor DarkCyan
}

function Require-Path {
    param(
        [string]$Path,
        [ValidateSet("File", "Directory")]
        [string]$Type,
        [string]$Description
    )

    $exists = if ($Type -eq "File") {
        Test-Path -LiteralPath $Path -PathType Leaf
    }
    else {
        Test-Path -LiteralPath $Path -PathType Container
    }

    if (-not $exists) {
        throw "$Description not found: $Path"
    }
}

function Get-JsonObject {
    param([string]$Path)

    $raw = [System.IO.File]::ReadAllText(
        $Path,
        [System.Text.Encoding]::UTF8
    )

    $value = $raw | ConvertFrom-Json

    if ($null -eq $value) {
        throw "Invalid JSON: $Path"
    }

    return $value
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Convert-ToHashtable {
    param([object]$Object)

    $table = @{}

    if ($null -eq $Object) {
        return $table
    }

    foreach ($property in $Object.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }

    return $table
}

function Resolve-AnimationSource {
    param(
        [string]$AnimationName,
        [string]$AnimationsRoot
    )

    $aliases = @{
        "idle" = @("idle.png")
        "appear" = @("appear.png")
        "disappear" = @("disappear.png")
        "wave" = @("wave.png")
        "speak" = @("speak.png")
        "think" = @("think.png", "thinking.png")
        "walk_left" = @(
            "walk_left.png",
            "walk-left.png",
            "walkleft.png"
        )
        "walk_right" = @(
            "walk_right.png",
            "walk-right.png",
            "walkright.png"
        )
        "sit" = @("sit.png")
        "sleep" = @("sleep.png")
        "wake" = @("wake.png")
        "happy" = @("happy.png")
        "sad" = @("sad.png")
        "angry" = @("angry.png")
        "surprised" = @("surprised.png")
    }

    if (-not $aliases.ContainsKey($AnimationName)) {
        $aliases[$AnimationName] = @("$AnimationName.png")
    }

    foreach ($fileName in $aliases[$AnimationName]) {
        $candidate = Join-Path $AnimationsRoot $fileName

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Invoke-Magick {
    param([string[]]$Arguments)

    & $MagickExe @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "ImageMagick failed with exit code $LASTEXITCODE."
    }
}

function Get-ImageSize {
    param([string]$Path)

    $result = & $MagickExe `
        identify `
        -format "%w %h" `
        $Path

    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read image dimensions: $Path"
    }

    $parts = [string]$result -split "\s+"

    if ($parts.Count -lt 2) {
        throw "Unexpected identify result for: $Path"
    }

    return @{
        Width = [int]$parts[0]
        Height = [int]$parts[1]
    }
}

function Get-VisibleGreenRatio {
    param([string]$Path)

    # ImageMagick's -fx channel value is context-sensitive. Build an explicit
    # RGB green mask and multiply it by the source alpha so transparent green
    # pixels are not reported as visible chroma.
    $validationRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("ocp-green-validation-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $validationRoot | Out-Null

    try {
        $greenMaskPath = Join-Path $validationRoot "green-mask.png"
        $alphaPath = Join-Path $validationRoot "alpha.png"
        $visibleGreenPath = Join-Path $validationRoot "visible-green.png"
        $greenExpression = (
            "((g>0.18)&&(g>r*1.12)&&(g>b*1.12))?1:0"
        )

        Invoke-Magick @(
            $Path,
            "-alpha", "off",
            "-fx", $greenExpression,
            $greenMaskPath
        )
        Invoke-Magick @($Path, "-alpha", "extract", $alphaPath)
        Invoke-Magick @(
            $alphaPath,
            $greenMaskPath,
            "-compose", "Multiply",
            "-composite",
            $visibleGreenPath
        )

        $result = & $MagickExe `
            $visibleGreenPath `
            "-format" "%[fx:mean]" `
            "info:"

        if ($LASTEXITCODE -ne 0) {
            throw "Cannot inspect residual chroma: $Path"
        }

        return [double]::Parse(
            ([string]$result).Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    finally {
        if (Test-Path -LiteralPath $validationRoot) {
            Remove-Item -LiteralPath $validationRoot -Recurse -Force
        }
    }
}

function Get-VisibleAlphaRatio {
    param([string]$Path)

    $result = & $MagickExe `
        $Path `
        "-format" "%[fx:mean.a]" `
        "info:"

    if ($LASTEXITCODE -ne 0) {
        throw "Cannot inspect foreground alpha: $Path"
    }

    return [double]::Parse(
        ([string]$result).Trim(),
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Remove-ChromaPerFrame {
    param(
        [string]$SourcePath,
        [string]$OutputPath,
        [int]$SheetWidth,
        [int]$SheetHeight,
        [int]$Columns,
        [int]$Rows,
        [int]$FrameWidth,
        [int]$FrameHeight,
        [int]$FrameCount,
        [int]$FuzzPercent,
        [string]$WorkRoot
    )

    $animationName = [System.IO.Path]::GetFileNameWithoutExtension(
        $OutputPath
    )
    $animationWork = Join-Path $WorkRoot $animationName

    if (Test-Path -LiteralPath $animationWork) {
        Remove-Item -LiteralPath $animationWork -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $animationWork |
        Out-Null

    $transparentFrames = New-Object `
        'System.Collections.Generic.List[string]'

    for ($frameIndex = 0; $frameIndex -lt $FrameCount; $frameIndex++) {
        $column = $frameIndex % $Columns
        $row = [math]::Floor($frameIndex / $Columns)
        $x = $column * $FrameWidth
        $y = $row * $FrameHeight

        $croppedPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}-source.png" -f $frameIndex)

        $transparentPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}.png" -f $frameIndex)
        $gutterRemovedPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}-gutter-removed.png" -f $frameIndex)
        $greenMaskPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}-green-mask.png" -f $frameIndex)
        $existingAlphaPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}-alpha.png" -f $frameIndex)
        $combinedMaskPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}-combined-mask.png" -f $frameIndex)

        Invoke-Magick @(
            $SourcePath,
            "-crop",
            "${FrameWidth}x${FrameHeight}+${x}+${y}",
            "+repage",
            $croppedPath
        )

        # Generated sheets may contain white gutters around an inset green
        # stage. Corner-only flood fill removes the gutter but cannot reach
        # that disconnected green region. First remove only the edge-connected
        # gutter, then clear green-dominant pixels globally. This preserves
        # white costume/detail pixels that are not connected to the corners.
        $greenRatio = [Math]::Max(
            1.10,
            1.34 - ($FuzzPercent * 0.01)
        )
        $greenMinimum = [Math]::Max(
            0.12,
            0.26 - ($FuzzPercent * 0.008)
        )
        $greenMaskExpression = (
            "((g > {0}) && (g > r*{1}) && (g > b*{1})) ? 0 : 1" -f `
                $greenMinimum.ToString(
                    [System.Globalization.CultureInfo]::InvariantCulture
                ), `
                $greenRatio.ToString(
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
        )

        Invoke-Magick @(
            $croppedPath,
            "-alpha", "on",
            "-fuzz", "$FuzzPercent%",
            "-fill", "none",
            "-draw", "alpha 0,0 floodfill",
            "-draw", "alpha $($FrameWidth - 1),0 floodfill",
            "-draw", "alpha 0,$($FrameHeight - 1) floodfill",
            "-draw", "alpha $($FrameWidth - 1),$($FrameHeight - 1) floodfill",
            "-define", "png:color-type=6",
            $gutterRemovedPath
        )

        # Generate the chroma mask from RGB independently of alpha, preserve
        # the flood-filled gutter alpha, then install the multiplied mask as
        # final opacity. This handles inset green stages correctly.
        Invoke-Magick @(
            $gutterRemovedPath,
            "-alpha", "off",
            "-fx", $greenMaskExpression,
            $greenMaskPath
        )
        Invoke-Magick @(
            $gutterRemovedPath,
            "-alpha", "extract",
            $existingAlphaPath
        )
        Invoke-Magick @(
            $existingAlphaPath,
            $greenMaskPath,
            "-compose", "Multiply",
            "-composite",
            $combinedMaskPath
        )
        Invoke-Magick @(
            $gutterRemovedPath,
            $combinedMaskPath,
            "-alpha", "off",
            "-compose", "CopyOpacity",
            "-composite",
            # Remove green-screen spill from opaque and anti-aliased edge
            # pixels. Preserve cyan/magenta costume accents by changing only
            # pixels whose green channel exceeds both red and blue.
            "-channel", "G",
            "-fx", "min(g,max(r,b)*1.02)",
            "+channel",
            "-define", "png:color-type=6",
            $transparentPath
        )

        $transparentFrames.Add($transparentPath)
    }

    # Create transparent blank cells for unused grid slots.
    $totalCells = $Columns * $Rows

    for ($frameIndex = $FrameCount; $frameIndex -lt $totalCells; $frameIndex++) {
        $blankPath = Join-Path `
            $animationWork `
            ("frame-{0:D2}.png" -f $frameIndex)

        Invoke-Magick @(
            "-size", "${FrameWidth}x${FrameHeight}",
            "xc:none",
            $blankPath
        )

        $transparentFrames.Add($blankPath)
    }

    # Reassemble in exact grid order.
    $rowImages = New-Object 'System.Collections.Generic.List[string]'

    for ($row = 0; $row -lt $Rows; $row++) {
        $rowPath = Join-Path `
            $animationWork `
            ("row-{0:D2}.png" -f $row)

        $args = New-Object 'System.Collections.Generic.List[string]'

        for ($column = 0; $column -lt $Columns; $column++) {
            $index = ($row * $Columns) + $column
            $args.Add($transparentFrames[$index])
        }

        $args.Add("+append")
        $args.Add($rowPath)
        Invoke-Magick $args.ToArray()
        $rowImages.Add($rowPath)
    }

    $finalArgs = New-Object 'System.Collections.Generic.List[string]'

    foreach ($rowImage in $rowImages) {
        $finalArgs.Add($rowImage)
    }

    $finalArgs.Add("-append")
    $finalArgs.Add($OutputPath)
    Invoke-Magick $finalArgs.ToArray()
}

function New-CharacterJson {
    param(
        [object]$Config,
        [hashtable]$AnimationFiles,
        [hashtable]$AnimationCounts,
        [string]$OutputPath
    )

    $sheet = Get-PropertyValue $Config "sheet"
    $bodyProfile = Get-PropertyValue $Config "bodyProfile"
    $presentationProfile = Get-PropertyValue $Config "presentationProfile"
    $capabilities = Get-PropertyValue $Config "capabilities"
    $animationFallbacks = Get-PropertyValue `
        $Config `
        "animationFallbacks" `
        ([ordered]@{})
    $visualProfiles = Get-PropertyValue `
        $Config `
        "visualProfiles" `
        ([ordered]@{})
    $authorship = @(Get-PropertyValue $Config "authorship" @())
    $logicalSize = Get-PropertyValue $bodyProfile "logicalSize" @(128, 128)
    $collisionHalfExtents = Get-PropertyValue `
        $bodyProfile `
        "collisionHalfExtents" `
        @(64, 64)
    $feetAnchor = Get-PropertyValue $bodyProfile "feetAnchor" @(0.5, 1.0)

    $animations = [ordered]@{}
    $sprites = @()

    foreach ($name in $AnimationFiles.Keys | Sort-Object) {
        $sprites += [ordered]@{
            id = $name
            path = "assets/$($AnimationFiles[$name])"
            frameSize = @(
                [int](Get-PropertyValue $sheet "frameWidth" 512),
                [int](Get-PropertyValue $sheet "frameHeight" 512)
            )
        }

        $frameCount = [int]$AnimationCounts[$name]
        $frames = @()
        for ($index = 0; $index -lt $frameCount; $index++) {
            $frames += $index
        }

        $animations[$name] = [ordered]@{
            sprite = $name
            frames = $frames
            # `sit` and `land` are enter/recovery transitions for the current
            # character/2 contract. Looping them repeatedly replays the pose
            # change while canonical state is stable. A non-looping
            # AnimatedSprite2D holds the final frame until the next state.
            loop = ($name -notin @(
                "appear",
                "disappear",
                "wake",
                "sit",
                "land"
            ))
            fps = 8.0
        }
    }

    # `climb-ready` is a stationary semantic state, while `climb_up` must keep
    # looping during real movement. Reuse the first climb frame as a dedicated
    # non-looping logical animation so every character/2 package gets a stable
    # left/right-ready pose without requiring another PNG. Runtime mirrors this
    # clip from Kernel facing authority.
    if ($animations.Contains("climb_up") -and -not $animations.Contains("climb_ready")) {
        $animations["climb_ready"] = [ordered]@{
            sprite = "climb_up"
            frames = @(0)
            loop = $false
            fps = 1.0
        }
    }

    $character = [ordered]@{
        schema = "character/2"
        id = [string](Get-PropertyValue $Config "id")
        version = [string](Get-PropertyValue $Config "version")
        name = [string](Get-PropertyValue $Config "name")
        renderer = "sprite-sheet-2d"
        runtimeCompatibility = [ordered]@{
            minimumRuntimeVersion = [string](Get-PropertyValue $Config "minimumRuntimeVersion" "0.1.0")
        }
        capabilities = $capabilities
        bodyProfile = [ordered]@{
            logicalSize = @($logicalSize)
            collisionHalfExtents = @($collisionHalfExtents)
            feetAnchor = @($feetAnchor)
        }
        presentationProfile = [ordered]@{
            baseScale = [double](Get-PropertyValue $presentationProfile "baseScale" 1.0)
            minimumUserScale = [double](Get-PropertyValue $presentationProfile "minimumUserScale" 0.5)
            maximumUserScale = [double](Get-PropertyValue $presentationProfile "maximumUserScale" 2.0)
        }
        sprites = $sprites
        animations = $animations
        animationFallbacks = $animationFallbacks
        visualProfiles = $visualProfiles
        authorship = $authorship
    }

    $json = $character | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $OutputPath,
        $json,
        $utf8NoBom
    )
}

function New-Manifest {
    param(
        [object]$Config,
        [string]$AssetsRoot,
        [string]$OutputPath
    )

    $assetEntries = New-Object 'System.Collections.Generic.List[object]'

    Get-ChildItem `
        -LiteralPath $AssetsRoot `
        -File |
        Sort-Object Name |
        ForEach-Object {
            $hash = Get-FileHash `
                -LiteralPath $_.FullName `
                -Algorithm SHA256

            $assetEntries.Add(
                [ordered]@{
                    path = "assets/$($_.Name)"
                    sha256 = $hash.Hash.ToLowerInvariant()
                }
            )
        }

    $manifest = [ordered]@{
        manifestVersion = "0.1"
        id = [string](Get-PropertyValue $Config "id")
        type = "character"
        version = [string](Get-PropertyValue $Config "version")
        publisher = Get-PropertyValue $Config "publisher"
        license = [string](Get-PropertyValue $Config "license")
        entry = "assets/character.json"
        assets = $assetEntries
    }

    $json = $manifest | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $OutputPath,
        $json,
        $utf8NoBom
    )
}

function New-OcpArchive {
    param(
        [string]$PackageDirectory,
        [string]$OutputPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $stream = [System.IO.File]::Open(
        $OutputPath,
        [System.IO.FileMode]::CreateNew
    )

    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )

        try {
            Get-ChildItem `
                -LiteralPath $PackageDirectory `
                -Recurse `
                -File |
                Sort-Object FullName |
                ForEach-Object {
                    $relative = $_.FullName.Substring(
                        $PackageDirectory.Length
                    ).TrimStart("\", "/")

                    $entryName = $relative.Replace("\", "/")
                    $entry = $archive.CreateEntry(
                        $entryName,
                        [System.IO.Compression.CompressionLevel]::Optimal
                    )

                    $entryStream = $entry.Open()

                    try {
                        $fileStream = [System.IO.File]::OpenRead($_.FullName)

                        try {
                            $fileStream.CopyTo($entryStream)
                        }
                        finally {
                            $fileStream.Dispose()
                        }
                    }
                    finally {
                        $entryStream.Dispose()
                    }
                }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Test-OcpArchive {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $stream = [System.IO.File]::OpenRead($Path)

    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )

        try {
            $names = @(
                $archive.Entries |
                ForEach-Object {
                    $_.FullName.Replace("\", "/")
                }
            )

            foreach ($required in @(
                "manifest.json",
                "assets/character.json",
                "assets/idle.png"
            )) {
                if ($required -notin $names) {
                    throw "OCP verification failed. Missing: $required"
                }
            }

            foreach ($name in $names) {
                if (
                    $name.StartsWith("/") -or
                    $name.Contains("../") -or
                    $name.Contains(":\")
                ) {
                    throw "Unsafe ZIP entry: $name"
                }
            }

            Write-Host `
                ("OCP verification passed: {0} entries" -f $names.Count) `
                -ForegroundColor Green
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

Write-Section "Generic OCP Character Builder"

Require-Path $root "Directory" "Character root"
Require-Path $configPath "File" "character.build.json"
Require-Path $sourceRoot "Directory" "Animation source directory"

$magickCommand = Get-Command `
    $MagickExe `
    -ErrorAction SilentlyContinue

if ($null -eq $magickCommand) {
    throw (
        "ImageMagick was not found. Install it and ensure 'magick' " +
        "is available in PATH."
    )
}

$config = Get-JsonObject $configPath

$characterId = [string](Get-PropertyValue $config "id")
$characterName = [string](Get-PropertyValue $config "name")
$version = [string](Get-PropertyValue $config "version")
$sheet = Get-PropertyValue $config "sheet"
$animationConfig = Convert-ToHashtable(
    Get-PropertyValue $config "animations"
)

if ([string]::IsNullOrWhiteSpace($characterId)) {
    throw "character.build.json is missing id."
}

if ([string]::IsNullOrWhiteSpace($characterName)) {
    throw "character.build.json is missing name."
}

if ([string]::IsNullOrWhiteSpace($version)) {
    throw "character.build.json is missing version."
}

$sheetWidth = [int](Get-PropertyValue $sheet "width" 2048)
$sheetHeight = [int](Get-PropertyValue $sheet "height" 1024)
$columns = [int](Get-PropertyValue $sheet "columns" 4)
$rows = [int](Get-PropertyValue $sheet "rows" 2)
$frameWidth = [int](Get-PropertyValue $sheet "frameWidth" 512)
$frameHeight = [int](Get-PropertyValue $sheet "frameHeight" 512)

if ($columns * $frameWidth -ne $sheetWidth) {
    throw "columns * frameWidth does not equal sheet width."
}

if ($rows * $frameHeight -ne $sheetHeight) {
    throw "rows * frameHeight does not equal sheet height."
}

$requiredAnimations = @($animationConfig.Keys | Sort-Object)

if ("idle" -notin $requiredAnimations) {
    throw "Missing required animation frame count: idle"
}

$resolvedSources = @{}
$animationCounts = @{}

foreach ($animationName in $requiredAnimations) {
    if (-not $animationConfig.ContainsKey($animationName)) {
        throw "Missing animation frame count: $animationName"
    }

    $frameCount = [int]$animationConfig[$animationName]
    $maximumFrames = $columns * $rows

    if ($frameCount -lt 1 -or $frameCount -gt $maximumFrames) {
        throw (
            "Invalid frame count for ${animationName}: ${frameCount}. " +
            "Expected 1-${maximumFrames}."
        )
    }

    $sourcePath = Resolve-AnimationSource `
        -AnimationName $animationName `
        -AnimationsRoot $sourceRoot

    if ($null -eq $sourcePath) {
        throw "Animation source missing: $animationName"
    }

    $resolvedSources[$animationName] = $sourcePath
    $animationCounts[$animationName] = $frameCount
}

Write-Host "Character     : $characterName"
Write-Host "ID            : $characterId"
Write-Host "Version       : $version"
Write-Host "Source        : $sourceRoot"
Write-Host "Runtime       : $runtimeRoot"
Write-Host "Sheet         : ${sheetWidth}x${sheetHeight}"
Write-Host "Grid          : ${columns}x${rows}"
Write-Host "Frame         : ${frameWidth}x${frameHeight}"
Write-Host "Chroma fuzz   : $ChromaFuzz%"
Write-Host "Preview only  : $PreviewOnly"

if (Test-Path -LiteralPath $runtimeAnimations) {
    Remove-Item -LiteralPath $runtimeAnimations -Recurse -Force
}

if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $runtimeAnimations |
    Out-Null
New-Item -ItemType Directory -Force -Path $packageAssets |
    Out-Null
New-Item -ItemType Directory -Force -Path $tempRoot |
    Out-Null

$outputFiles = @{}

foreach ($animationName in $requiredAnimations) {
    $sourcePath = $resolvedSources[$animationName]
    $outputFileName = "$animationName.png"
    $outputPath = Join-Path $runtimeAnimations $outputFileName

    Write-Host ""
    Write-Host "Processing $animationName" -ForegroundColor Cyan
    Write-Host "  Source: $([System.IO.Path]::GetFileName($sourcePath))"
    Write-Host "  Frames: $($animationCounts[$animationName])"

    if (-not $SkipImageValidation) {
        $size = Get-ImageSize $sourcePath

        if (
            $size.Width -ne $sheetWidth -or
            $size.Height -ne $sheetHeight
        ) {
            throw (
                "Unexpected size for $sourcePath. " +
                "Expected ${sheetWidth}x${sheetHeight}, " +
                "got $($size.Width)x$($size.Height)."
            )
        }
    }

    Remove-ChromaPerFrame `
        -SourcePath $sourcePath `
        -OutputPath $outputPath `
        -SheetWidth $sheetWidth `
        -SheetHeight $sheetHeight `
        -Columns $columns `
        -Rows $rows `
        -FrameWidth $frameWidth `
        -FrameHeight $frameHeight `
        -FrameCount $animationCounts[$animationName] `
        -FuzzPercent $ChromaFuzz `
        -WorkRoot $tempRoot

    $residualGreen = Get-VisibleGreenRatio $outputPath

    if ($residualGreen -gt 0.02) {
        throw (
            "Background removal failed for $animationName. " +
            "Visible green ratio is {0:P2}." -f $residualGreen
        )
    }

    $visibleAlpha = Get-VisibleAlphaRatio $outputPath

    if ($visibleAlpha -lt 0.001) {
        throw (
            "Background removal erased all foreground for " +
            "$animationName."
        )
    }

    $outputFiles[$animationName] = $outputFileName
}

New-CharacterJson `
    -Config $config `
    -AnimationFiles $outputFiles `
    -AnimationCounts $animationCounts `
    -OutputPath $runtimeCharacterPath

Copy-Item `
    -LiteralPath $runtimeCharacterPath `
    -Destination (Join-Path $packageAssets "character.json") `
    -Force

foreach ($animationName in $requiredAnimations) {
    $fileName = $outputFiles[$animationName]

    Copy-Item `
        -LiteralPath (Join-Path $runtimeAnimations $fileName) `
        -Destination (Join-Path $packageAssets $fileName) `
        -Force
}

$manifestPath = Join-Path $packageRoot "manifest.json"

New-Manifest `
    -Config $config `
    -AssetsRoot $packageAssets `
    -OutputPath $manifestPath

if (-not $KeepTemp) {
    Remove-Item `
        -LiteralPath $tempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

if ($PreviewOnly) {
    Write-Section "PREVIEW COMPLETE"
    Write-Host "Review:"
    Write-Host "  $runtimeAnimations"
    Write-Host ""
    Write-Host "Generated character config:"
    Write-Host "  $runtimeCharacterPath"
    Write-Host ""
    Write-Host "No .ocp package was created."
    exit 0
}

$packageFileName = [string](
    Get-PropertyValue $config "outputFile" ""
)

if ([string]::IsNullOrWhiteSpace($packageFileName)) {
    $shortId = $characterId

    if ($shortId.Contains(".")) {
        $shortId = $shortId.Substring(
            $shortId.LastIndexOf(".") + 1
        )
    }

    $packageFileName = "$shortId.ocp"
}

if (-not $packageFileName.EndsWith(
    ".ocp",
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    $packageFileName += ".ocp"
}

$packagePath = Join-Path $root $packageFileName

New-OcpArchive `
    -PackageDirectory $packageRoot `
    -OutputPath $packagePath

Test-OcpArchive $packagePath

$packageInfo = Get-Item -LiteralPath $packagePath

Write-Section "OCP BUILD COMPLETE"
Write-Host "Package:"
Write-Host "  $packagePath"
Write-Host "Size:"
Write-Host "  $([math]::Round($packageInfo.Length / 1MB, 2)) MB"
Write-Host "Character JSON:"
Write-Host "  $runtimeCharacterPath"
Write-Host "Runtime animations:"
Write-Host "  $runtimeAnimations"
Write-Host "Manifest:"
Write-Host "  $manifestPath"
