[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CharacterRoot,

    [Parameter(Mandatory = $true)]
    [string]$CharacterId,

    [Parameter(Mandatory = $true)]
    [string]$CharacterName,

    [string]$Version = "1.0.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($CharacterRoot)
$animations = Join-Path $root "animations"
$configPath = Join-Path $root "character.build.json"

if (Test-Path -LiteralPath $configPath) {
    throw "character.build.json already exists: $configPath"
}

New-Item -ItemType Directory -Force -Path $animations |
    Out-Null

$shortId = $CharacterId

if ($shortId.Contains(".")) {
    $shortId = $shortId.Substring(
        $shortId.LastIndexOf(".") + 1
    )
}

$config = [ordered]@{
    id = $CharacterId
    name = $CharacterName
    version = $Version
    outputFile = "$shortId.ocp"
    publisher = [ordered]@{
        id = "ocp.local"
        keyId = "local-poc"
    }
    license = "Private POC"
    sheet = [ordered]@{
        width = 2048
        height = 1024
        columns = 4
        rows = 2
        frameWidth = 512
        frameHeight = 512
    }
    presentation = [ordered]@{
        scale = 1.0
        bubbleAnchor = [ordered]@{
            x = 0
            y = -220
        }
        hitbox = [ordered]@{
            x = -128
            y = -220
            width = 256
            height = 300
        }
    }
    animations = [ordered]@{
        idle = 8
        appear = 8
        disappear = 8
        wave = 8
        speak = 6
        think = 8
        walk_left = 8
        walk_right = 8
        sit = 4
        sleep = 8
        wake = 8
        happy = 6
        sad = 6
        angry = 6
        surprised = 6
    }
}

$json = $config | ConvertTo-Json -Depth 12
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $configPath,
    $json,
    $utf8NoBom
)

Write-Host "OCP character workspace created." -ForegroundColor Green
Write-Host "Root: $root"
Write-Host "Config: $configPath"
Write-Host "Animations: $animations"
