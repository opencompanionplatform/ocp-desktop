<#
.SYNOPSIS
    Build an OCP POC character package from AI-generated sprite sheets.

.DESCRIPTION
    - Reads PNG sprite sheets from:
        poc-assets\<CharacterId>\animations
    - Splits each 4x2 sheet into individual frames
    - Removes non-uniform green backgrounds by flood-filling from frame edges
    - Reassembles transparent sprite sheets into:
        poc-assets\<CharacterId>\runtime\animations
    - Generates character.json as UTF-8 without BOM
    - Packages runtime contents as:
        poc-assets\<CharacterId>\<CharacterId>.ocp

.EXAMPLE
    cd D:\ocp-platform\apps\desktop-runtime

    powershell -ExecutionPolicy Bypass `
      -File .\build_poc_character.ps1 `
      -CharacterId meowsom `
      -CharacterName "Meowsom" `
      -FrameWidth 512 `
      -FrameHeight 512

.EXAMPLE
    # Increase background tolerance carefully when green remains (try 7 or 8):
    .\build_poc_character.ps1 `
      -CharacterId meowsom `
      -CharacterName "Meowsom" `
      -ChromaFuzz 8

.NOTES
    Requires ImageMagick 7 command: magick
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9_-]+$')]
    [string]$CharacterId,

    [string]$CharacterName = $CharacterId,

    [string]$Version = "0.1.0",

    [ValidateRange(1, 8192)]
    [int]$FrameWidth = 512,

    [ValidateRange(1, 8192)]
    [int]$FrameHeight = 512,

    [ValidateRange(1, 32)]
    [int]$Columns = 4,

    [ValidateRange(1, 32)]
    [int]$Rows = 2,

    [ValidateRange(1, 40)]
    [int]$ChromaFuzz = 6,

    [ValidateRange(0.0, 5.0)]
    [double]$AlphaBlur = 0.6,

    [string]$Author = "Warin",

    [string]$License = "Private POC",

    [switch]$KeepTemporaryFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# PowerShell 5.1 compatible script root.
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

function Write-Step {
    param([string]$Message)
    Write-Host "[OCP] $Message" -ForegroundColor Cyan
}

function Invoke-Magick {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    & magick @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "ImageMagick failed: $Description (exit code $LASTEXITCODE)"
    }
}

function Get-ImageSize {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = & magick identify -quiet -format "%wx%h" $Path

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
        throw "Unable to read image size: $Path"
    }

    return $result.Trim()
}

function Get-AlphaMean {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = & magick $Path -alpha extract -format "%[fx:mean]" info:

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
        throw "Unable to inspect alpha channel: $Path"
    }

    return [double]::Parse(
        $result.Trim(),
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Add-Sprite {
    param(
        [string]$Id,
        [string]$FileName
    )

    $script:Sprites += [ordered]@{
        id        = $Id
        path      = "animations/$FileName"
        frameSize = @($FrameWidth, $FrameHeight)
    }
}

function Add-Animation {
    param(
        [string]$Name,
        [string]$SpriteId,
        [int[]]$Frames,
        [double]$Fps,
        [bool]$Loop
    )

    $script:Animations[$Name] = [ordered]@{
        sprite = $SpriteId
        frames = $Frames
        fps    = $Fps
        loop   = $Loop
    }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$AssetRoot = Join-Path $PSScriptRoot "poc-assets\$CharacterId"
$SourceDir = Join-Path $AssetRoot "animations"
$RuntimeDir = Join-Path $AssetRoot "runtime"
$OutputAnimationDir = Join-Path $RuntimeDir "animations"
$ManifestPath = Join-Path $RuntimeDir "character.json"
$OcpOutput = Join-Path $AssetRoot "$CharacterId.ocp"
$TempZip = Join-Path $AssetRoot "$CharacterId.zip"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocp-chroma-$CharacterId"

$FrameCount = $Columns * $Rows
$ExpectedWidth = $FrameWidth * $Columns
$ExpectedHeight = $FrameHeight * $Rows
$ExpectedSize = "${ExpectedWidth}x${ExpectedHeight}"

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host " Building OCP character: $CharacterName ($CharacterId)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host "Source       : $SourceDir"
Write-Host "Runtime      : $RuntimeDir"
Write-Host "Package      : $OcpOutput"
Write-Host "Sprite sheet : $ExpectedSize ($Columns x $Rows)"
Write-Host "Chroma fuzz  : $ChromaFuzz% (safe AI-background mode)"
Write-Host ""

# ---------------------------------------------------------------------------
# Prerequisite validation
# ---------------------------------------------------------------------------

if (-not (Get-Command magick -ErrorAction SilentlyContinue)) {
    throw @"
ImageMagick command 'magick' was not found in PATH.

Install:
    winget install ImageMagick.ImageMagick

Then close and reopen PowerShell.
"@
}

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    throw "Source directory not found: $SourceDir"
}

$SourcePngFiles = @(Get-ChildItem -LiteralPath $SourceDir -Filter "*.png" -File)

if ($SourcePngFiles.Count -eq 0) {
    throw "No PNG sprite sheets found in: $SourceDir"
}

# ---------------------------------------------------------------------------
# Known OCP sprite files
# ---------------------------------------------------------------------------

$SpriteIdToFileMap = [ordered]@{
    idle       = "idle.png"
    appear     = "appear.png"
    disappear  = "disappear.png"
    wave       = "wave.png"
    speak      = "speak.png"
    think      = "think.png"
    walk_left  = "walk_left.png"
    walk_right = "walk_right.png"
    sit        = "sit.png"
    sleep      = "sleep.png"
    wake       = "wake.png"
    happy      = "happy.png"
    sad        = "sad.png"
    angry      = "angry.png"
    surprised  = "surprised.png"
}

# ---------------------------------------------------------------------------
# Clean and prepare
# ---------------------------------------------------------------------------

Write-Step "Preparing runtime and temporary directories"

Remove-Item -LiteralPath $RuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $OcpOutput -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force -Path $OutputAnimationDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

# ---------------------------------------------------------------------------
# Green-background removal
# ---------------------------------------------------------------------------

Write-Step "Removing AI-generated green backgrounds frame by frame"
Write-Host "  Safe mode uses corner flood-fill only." -ForegroundColor DarkGray
Write-Host "  Note: green light painted onto fur cannot be perfectly recovered by chroma key." -ForegroundColor DarkYellow

foreach ($SpriteId in $SpriteIdToFileMap.Keys) {
    $FileName = $SpriteIdToFileMap[$SpriteId]
    $SourceFile = Join-Path $SourceDir $FileName
    $OutputFile = Join-Path $OutputAnimationDir $FileName

    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        Write-Warning "Skipping missing sprite sheet: $FileName"
        continue
    }

    $ActualSize = Get-ImageSize -Path $SourceFile

    if ($ActualSize -ne $ExpectedSize) {
        throw "Invalid sprite sheet size for '$FileName': $ActualSize. Expected: $ExpectedSize"
    }

    Write-Host "  Processing $FileName" -ForegroundColor Yellow

    $WorkDir = Join-Path $TempRoot $SpriteId
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    $SourcePattern = Join-Path $WorkDir "source_%02d.png"

    Invoke-Magick `
        -Description "split $FileName into frames" `
        -Arguments @(
            $SourceFile,
            "-crop", "${FrameWidth}x${FrameHeight}",
            "+repage",
            $SourcePattern
        )

    $MaxX = $FrameWidth - 1
    $MaxY = $FrameHeight - 1
    $MidX = [int][Math]::Floor($FrameWidth / 2)
    $MidY = [int][Math]::Floor($FrameHeight / 2)

    $CleanFrames = @()

    for ($Index = 0; $Index -lt $FrameCount; $Index++) {
        $SourceFrame = Join-Path $WorkDir ("source_{0:D2}.png" -f $Index)
        $CleanFrame = Join-Path $WorkDir ("clean_{0:D2}.png" -f $Index)

        if (-not (Test-Path -LiteralPath $SourceFrame -PathType Leaf)) {
            throw "Expected frame was not generated: $SourceFrame"
        }

        # Add a transparent border before flood-fill so edge-connected
        # background is easier to remove without deleting isolated green areas.
        #
        # Multiple seeds are used because AI backgrounds often contain
        # gradients and each corner can have a different green shade.
        # Use only corner seeds. Mid-edge seeds can begin on the character
        # when an AI-generated subject touches or approaches a frame edge.
        # A low fuzz value is intentionally safer than aggressively deleting
        # pixels from green-lit fur.
        $DrawCommands = @(
            "alpha 0,0 floodfill",
            "alpha $MaxX,0 floodfill",
            "alpha 0,$MaxY floodfill",
            "alpha $MaxX,$MaxY floodfill"
        )

        $MagickArgs = @(
            $SourceFrame,
            "-alpha", "on",
            "-fuzz", "$ChromaFuzz%",
            "-fill", "none"
        )

        foreach ($DrawCommand in $DrawCommands) {
            $MagickArgs += @("-draw", $DrawCommand)
        }

        if ($AlphaBlur -gt 0) {
            $MagickArgs += @(
                "-channel", "A",
                "-blur", "0x$AlphaBlur",
                "+channel"
            )
        }

        $MagickArgs += $CleanFrame

        Invoke-Magick `
            -Description "remove background from $FileName frame $Index" `
            -Arguments $MagickArgs

        $FrameAlphaMean = Get-AlphaMean -Path $CleanFrame

        if ($FrameAlphaMean -le 0.0001) {
            # Fully transparent frames are valid for appear/disappear.
            # Do not abort the entire package build.
            if ($SpriteId -in @("appear", "disappear")) {
                Write-Host "    Frame $Index is intentionally/fully transparent" -ForegroundColor DarkGray
            }
            else {
                Write-Warning "Frame $Index of '$FileName' is fully transparent. Check the source or reduce -ChromaFuzz."
            }
        }

        $CleanFrames += $CleanFrame
    }

    # Reassemble rows, then append rows vertically.
    $RowFiles = @()

    for ($Row = 0; $Row -lt $Rows; $Row++) {
        $RowFrameFiles = @()

        for ($Column = 0; $Column -lt $Columns; $Column++) {
            $FrameIndex = ($Row * $Columns) + $Column
            $RowFrameFiles += $CleanFrames[$FrameIndex]
        }

        $RowFile = Join-Path $WorkDir ("row_{0:D2}.png" -f $Row)

        Invoke-Magick `
            -Description "assemble row $Row of $FileName" `
            -Arguments @($RowFrameFiles + @("+append", $RowFile))

        $RowFiles += $RowFile
    }

    Invoke-Magick `
        -Description "reassemble transparent sprite sheet $FileName" `
        -Arguments @($RowFiles + @("-append", $OutputFile))

    $OutputSize = Get-ImageSize -Path $OutputFile

    if ($OutputSize -ne $ExpectedSize) {
        throw "Generated sprite sheet '$FileName' has size $OutputSize. Expected: $ExpectedSize"
    }

    $AlphaMean = Get-AlphaMean -Path $OutputFile

    if ($AlphaMean -le 0.0001) {
        throw "Processed sprite sheet '$FileName' is fully transparent."
    }

    if ($AlphaMean -ge 0.9999) {
        Write-Warning "'$FileName' appears fully opaque. Green background may remain."
    }

    Write-Host ("    OK - alpha mean: {0:N4}" -f $AlphaMean) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Generate character.json
# ---------------------------------------------------------------------------

Write-Step "Generating character.json"

$Sprites = @()
$Animations = [ordered]@{}

foreach ($SpriteId in $SpriteIdToFileMap.Keys) {
    $FileName = $SpriteIdToFileMap[$SpriteId]
    $ProcessedFile = Join-Path $OutputAnimationDir $FileName

    if (Test-Path -LiteralPath $ProcessedFile -PathType Leaf) {
        Add-Sprite -Id $SpriteId -FileName $FileName
    }
}

# Core animations
Add-Animation "idle"         "idle"       @(0,1,2,3,4,5,6,7) 6  $true
Add-Animation "idle_neutral" "idle"       @(0,1,2,3,4,5,6,7) 6  $true

Add-Animation "appear"       "appear"     @(0,1,2,3,4,5,6,7) 10 $false
Add-Animation "disappear"    "disappear"  @(0,1,2,3,4,5,6,7) 10 $false
Add-Animation "wave"         "wave"       @(0,1,2,3,4,5,6,7) 8  $false

Add-Animation "speak_enter"  "speak"      @(0)                 12 $false
Add-Animation "speak_loop"   "speak"      @(1,2,3,4,3,2,1)   12 $true
Add-Animation "speak_exit"   "speak"      @(0)                 12 $false
Add-Animation "speak"        "speak"      @(0,1,2,3,4,3,2,1) 12 $true

Add-Animation "think"        "think"      @(0,1,2,3,4,5,6,7) 7  $false
Add-Animation "thinking"     "think"      @(0,1,2,3,4,5,6,7) 7  $false

Add-Animation "walk_left"    "walk_left"  @(0,1,2,3,4,5,6,7) 10 $true
Add-Animation "walk_right"   "walk_right" @(0,1,2,3,4,5,6,7) 10 $true

Add-Animation "sit"          "sit"        @(0,1,2,3)           8  $false
Add-Animation "sleep"        "sleep"      @(0,1,2)             8  $false
Add-Animation "sleep_idle"   "sleep"      @(3,4,5,6,7)         4  $true
Add-Animation "wake"         "wake"       @(0,1,2,3,4,5,6,7) 8  $false

Add-Animation "happy"        "happy"      @(0,1,2,3,4,5)       8  $false
Add-Animation "sad"          "sad"        @(0,1,2,3,4,5)       7  $false
Add-Animation "angry"        "angry"      @(0,1,2,3,4,5)       7  $false
Add-Animation "surprised"    "surprised"  @(0,1,2,3,4,5)       10 $false

# Keep only animations whose processed sprite file exists.
$FinalAnimations = [ordered]@{}

foreach ($AnimationName in $Animations.Keys) {
    $Animation = $Animations[$AnimationName]
    $SpriteId = [string]$Animation.sprite

    if (-not $SpriteIdToFileMap.Contains($SpriteId)) {
        Write-Warning "Animation '$AnimationName' references unknown sprite '$SpriteId'."
        continue
    }

    $FileName = $SpriteIdToFileMap[$SpriteId]
    $ProcessedFile = Join-Path $OutputAnimationDir $FileName

    if (Test-Path -LiteralPath $ProcessedFile -PathType Leaf) {
        $FinalAnimations[$AnimationName] = $Animation
    }
    else {
        Write-Warning "Animation '$AnimationName' skipped because '$FileName' is missing."
    }
}

if (-not $FinalAnimations.Contains("idle")) {
    throw "Required animation 'idle' could not be generated. Ensure idle.png exists."
}

$Manifest = [ordered]@{
    schema           = "character/1"
    id               = $CharacterId
    name             = $CharacterName
    version          = $Version
    renderer         = "sprite-sheet-2d"
    sprites          = $Sprites
    animations       = $FinalAnimations
    defaultAnimation = "idle"
    runtime          = [ordered]@{
        bubbleAnchor = @(0, -176)
        scale        = 0.60
        hitbox       = @(44, 40, 220, 248)
    }
    authorship       = @(
        [ordered]@{
            component = "sprites"
            author    = $Author
            license   = $License
        }
    )
}

$ManifestJson = $Manifest | ConvertTo-Json -Depth 10
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $ManifestPath,
    $ManifestJson,
    $Utf8NoBom
)

# Validate generated JSON.
try {
    $null = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
}
catch {
    throw "Generated character.json is invalid: $($_.Exception.Message)"
}

Write-Host "  Manifest: $ManifestPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Create .ocp package
# ---------------------------------------------------------------------------

Write-Step "Creating $CharacterId.ocp"

Compress-Archive `
    -Path (Join-Path $RuntimeDir "*") `
    -DestinationPath $TempZip `
    -CompressionLevel Optimal `
    -Force

Move-Item -LiteralPath $TempZip -Destination $OcpOutput -Force

if (-not (Test-Path -LiteralPath $OcpOutput -PathType Leaf)) {
    throw "OCP package was not created: $OcpOutput"
}

# Verify package layout by extracting to a temporary directory.
$VerifyDir = Join-Path $TempRoot "verify-package"
$VerifyZip = Join-Path $TempRoot "$CharacterId-verify.zip"

New-Item -ItemType Directory -Force -Path $VerifyDir | Out-Null
Copy-Item -LiteralPath $OcpOutput -Destination $VerifyZip -Force
Expand-Archive -LiteralPath $VerifyZip -DestinationPath $VerifyDir -Force

$VerifiedManifest = Join-Path $VerifyDir "character.json"
$VerifiedAnimationDir = Join-Path $VerifyDir "animations"

if (-not (Test-Path -LiteralPath $VerifiedManifest -PathType Leaf)) {
    throw "Invalid OCP layout: character.json is not at the package root."
}

if (-not (Test-Path -LiteralPath $VerifiedAnimationDir -PathType Container)) {
    throw "Invalid OCP layout: animations directory is missing from the package root."
}

$PackageSize = (Get-Item -LiteralPath $OcpOutput).Length
$PackageSizeMb = [Math]::Round($PackageSize / 1MB, 2)

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGreen
Write-Host " BUILD COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor DarkGreen
Write-Host "Package : $OcpOutput"
Write-Host "Size    : $PackageSizeMb MB"
Write-Host "Manifest: $ManifestPath"
Write-Host ""
Write-Host "Next commands:" -ForegroundColor Cyan
Write-Host "  .\run_install_poc.ps1 -Action Build -Arch arm64 -Profile debug"
Write-Host "  .\run_install_poc.ps1 -Action Run   -Arch arm64 -Profile debug"
Write-Host ""

if (-not $KeepTemporaryFiles) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "Temporary files retained at: $TempRoot" -ForegroundColor Yellow
}
