[CmdletBinding()]
param(
    [string]$Target = ".\run_install_poc.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Target)) {
    throw "Target script not found: $Target"
}

$path = (Resolve-Path -LiteralPath $Target).Path
$content = Get-Content -LiteralPath $path -Raw

if ($content -match '"RunV3"') {
    Write-Host "run_install_poc.ps1 already contains Runtime V3 actions." -ForegroundColor Yellow
    exit 0
}

$backup = "$path.phase5-backup"
Copy-Item -LiteralPath $path -Destination $backup -Force

$content = $content -replace `
    '\[ValidateSet\("Validate", "Build", "Conformance", "Run", "AppShell", "All", "Clean"\)\]', `
    '[ValidateSet("Validate", "Build", "Conformance", "Run", "RunV3", "TestV3", "AppShell", "All", "Clean")]'

$insertBefore = 'switch ($Action)'
if ($content -notmatch [regex]::Escape($insertBefore)) {
    throw "Unable to find switch (`$Action) in target script."
}

$functions = @'

function Run-RuntimeV3 {
    Test-Prerequisites
    Require-Path $extension "Staged GDExtension (run Build first)"
    $runtimeScene = "res://scenes/runtime_v3/RuntimeApp.tscn"
    Write-Host "[POC] Opening Runtime V3." -ForegroundColor Cyan
    Start-Process -FilePath $GodotExe -ArgumentList @("--path", $godotProject, $runtimeScene) | Out-Null
}

function Test-RuntimeV3 {
    Test-Prerequisites
    Write-Host "[POC] Running Runtime V3 test suite..." -ForegroundColor Cyan
    & $GodotExe `
        --headless `
        --path $godotProject `
        --script "res://scripts/runtime_v3/tests/runtime_v3_test_suite.gd"

    if ($LASTEXITCODE -ne 0) {
        throw "Runtime V3 tests failed with exit code $LASTEXITCODE."
    }
}

'@

$content = $content.Replace($insertBefore, $functions + $insertBefore)

# Add switch cases immediately after switch line.
$content = $content -replace `
    'switch \(\$Action\) \{', `
    @'
switch ($Action) {
    "RunV3" {
        Run-RuntimeV3
        break
    }
    "TestV3" {
        Test-RuntimeV3
        break
    }
'@

Set-Content -LiteralPath $path -Value $content -Encoding utf8 -NoNewline

Write-Host "Runtime V3 actions added." -ForegroundColor Green
Write-Host "Backup: $backup"
Write-Host "New actions: RunV3, TestV3"
