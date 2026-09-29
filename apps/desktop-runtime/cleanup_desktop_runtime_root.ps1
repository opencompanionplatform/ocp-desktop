[CmdletBinding()]
param(
    [string]$RuntimeRoot = ".",

    [ValidateSet("Preview", "Archive", "Delete")]
    [string]$Mode = "Preview",

    [switch]$IncludeRecovery,

    [switch]$IncludeArtifacts,

    [switch]$IncludeLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($RuntimeRoot)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archiveRoot = Join-Path `
    $root `
    "_archive\desktop-runtime-cleanup-$timestamp"

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Runtime root not found: $root"
}

$script:candidates = New-Object `
    'System.Collections.Generic.List[object]'

function Add-Candidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [ValidateSet("File", "Directory")]
        [string]$Type = "File"
    )

    $fullPath = Join-Path $root $RelativePath

    $exists = if ($Type -eq "File") {
        Test-Path -LiteralPath $fullPath -PathType Leaf
    }
    else {
        Test-Path -LiteralPath $fullPath -PathType Container
    }

    if (-not $exists) {
        return
    }

    $script:candidates.Add(
        [pscustomobject]@{
            RelativePath = $RelativePath
            FullPath = $fullPath
            Reason = $Reason
            Type = $Type
        }
    )
}

# Superseded build helpers.
Add-Candidate `
    -RelativePath "build_poc_character_v2.ps1" `
    -Reason "Superseded by the canonical v3/generic OCP builder"

Add-Candidate `
    -RelativePath "run_cs_rt_fixed.ps1" `
    -Reason "Temporary replacement copy; run_cs_rt.ps1 is canonical"

Add-Candidate `
    -RelativePath "run_cs_rt_isolated.ps1" `
    -Reason "Temporary Phase 6.3.2 runner; run_cs_rt.ps1 is canonical"

Add-Candidate `
    -RelativePath "run_install_poc_production.ps1" `
    -Reason "Duplicate production copy; run_install_poc.ps1 is canonical"

Add-Candidate `
    -RelativePath "run_runtime_v3_release_gate.ps1.before-fix" `
    -Reason "Pre-fix backup"

Add-Candidate `
    -RelativePath "RuntimeApp_phase6_4_1_patched.tscn" `
    -Reason "Temporary patch artifact; canonical scene is under godot/scenes/runtime_v3"

Add-Candidate `
    -RelativePath "repair_runtime_app_tscn_encoding.ps1" `
    -Reason "One-time recovery utility after successful scene validation"

# One-time installers and migration scripts.
Add-Candidate `
    -RelativePath "install_cs_rt_runner_fix.ps1" `
    -Reason "One-time Phase 6.3 installer"

Add-Candidate `
    -RelativePath "install_phase6_2_1_package_refactor.ps1" `
    -Reason "One-time Phase 6.2.1 installer"

Add-Candidate `
    -RelativePath "install_phase6_3_2_cs_rt_isolation.ps1" `
    -Reason "One-time Phase 6.3.2 installer"

Add-Candidate `
    -RelativePath "install_phase6_3_3_cs_rt_adapter.ps1" `
    -Reason "One-time Phase 6.3.3 installer"

Add-Candidate `
    -RelativePath "install_phase6_4_1_rc1_ux_fixes.ps1" `
    -Reason "One-time Phase 6.4.1 installer"

Add-Candidate `
    -RelativePath "migrate_runtime_v3_production.ps1" `
    -Reason "Completed production migration utility"

Add-Candidate `
    -RelativePath "rollback_runtime_v3_default.ps1" `
    -Reason "Obsolete default-migration rollback"

Add-Candidate `
    -RelativePath "rollback_runtime_v3_production.ps1" `
    -Reason "Keep only in source control history after RC baseline"

# Phase-specific temporary validation scripts.
Add-Candidate `
    -RelativePath "test_cs_rt_isolation_static.ps1" `
    -Reason "Superseded by release gate"

Add-Candidate `
    -RelativePath "test_phase6_4_1_static.ps1" `
    -Reason "Phase-local static test already completed"

Add-Candidate `
    -RelativePath "test_runtime_v3_production_entry.ps1" `
    -Reason "Superseded by release layout and release gate"

Add-Candidate `
    -RelativePath "audit_legacy_runtime_references.ps1" `
    -Reason "One-time migration audit"

$phaseDocs = @(
    "CHECKLIST_PHASE6_3.md",
    "CHECKLIST_PHASE6_3_1.md",
    "CHECKLIST_PHASE6_3_2.md",
    "CHECKLIST_PHASE6_3_3.md",
    "CHECKLIST_PHASE6_3_DEFAULT_MIGRATION.md",
    "CHECKLIST_PHASE6_4.md",
    "CHECKLIST_PHASE6_4_1.md",
    "COMMIT_MESSAGE_PHASE6_3.txt",
    "COMMIT_MESSAGE_PHASE6_3_1.txt",
    "COMMIT_MESSAGE_PHASE6_3_2.txt",
    "COMMIT_MESSAGE_PHASE6_3_3.txt",
    "COMMIT_MESSAGE_PHASE6_4.txt",
    "COMMIT_MESSAGE_PHASE6_4_1.txt",
    "README_CS_RT_RUNNER_FIX.md",
    "README_PHASE6_3.md",
    "README_PHASE6_3_1.md",
    "README_PHASE6_3_2.md",
    "README_PHASE6_3_3.md",
    "README_PHASE6_3_DEFAULT_MIGRATION.md",
    "README_PHASE6_4.md",
    "README_PHASE6_4_1.md"
)

foreach ($doc in $phaseDocs) {
    Add-Candidate `
        -RelativePath $doc `
        -Reason "Historical phase document; consolidate into docs/runtime"
}

if ($IncludeLogs) {
    foreach ($log in @(
        "cs_rt_live.err.log",
        "cs_rt_live.out.log",
        "godot_headless.err.log",
        "godot_headless.out.log"
    )) {
        Add-Candidate `
            -RelativePath $log `
            -Reason "Generated test log"
    }
}

if ($IncludeArtifacts) {
    Add-Candidate `
        -RelativePath "artifacts" `
        -Reason "Generated release/test reports" `
        -Type "Directory"
}

if ($IncludeRecovery) {
    Add-Candidate `
        -RelativePath "_recovery" `
        -Reason "Historical backups; include only after external backup" `
        -Type "Directory"
}

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor DarkCyan
Write-Host " Desktop Runtime Cleanup" `
    -ForegroundColor Cyan
Write-Host "============================================================" `
    -ForegroundColor DarkCyan
Write-Host "Root : $root"
Write-Host "Mode : $Mode"
Write-Host ""

if ($script:candidates.Count -eq 0) {
    Write-Host "No cleanup candidates found." `
        -ForegroundColor Green
    exit 0
}

$script:candidates |
    Select-Object RelativePath,Type,Reason |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Protected canonical files:" `
    -ForegroundColor Cyan
Write-Host "  run_install_poc.ps1"
Write-Host "  run_install_poc_legacy.ps1"
Write-Host "  run_cs_rt.ps1"
Write-Host "  run_ocp_runtime.ps1"
Write-Host "  run_runtime_v3_release_gate.ps1"
Write-Host "  validate_runtime_v3_release_layout.ps1"
Write-Host "  test_runtime_v3_single_instance.ps1"
Write-Host "  build_poc_character_v3.ps1"
Write-Host "  build.ps1 / build.sh / run_cs_rt.sh"
Write-Host "  godot / rust / poc-assets / examples / samples"
Write-Host "  README.md / CHECKLIST.md / WINDOWS_RC_CHECKLIST.md"
Write-Host "  MACOS_FOUNDATION_PLAN.md"
Write-Host "  CROSS_PLATFORM_ARCHITECTURE_WINDOWS_MACOS.md"

if ($Mode -eq "Preview") {
    Write-Host ""
    Write-Host "Preview only. Nothing was changed." `
        -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Recommended first cleanup:"
    Write-Host (
        "  .\cleanup_desktop_runtime_root.ps1 " +
        "-Mode Archive -IncludeLogs"
    )
    exit 0
}

if ($Mode -eq "Archive") {
    New-Item `
        -ItemType Directory `
        -Force `
        -Path $archiveRoot |
        Out-Null
}

foreach ($candidate in $script:candidates) {
    if ($Mode -eq "Archive") {
        $destination = Join-Path `
            $archiveRoot `
            $candidate.RelativePath

        New-Item `
            -ItemType Directory `
            -Force `
            -Path (Split-Path -Parent $destination) |
            Out-Null

        Move-Item `
            -LiteralPath $candidate.FullPath `
            -Destination $destination `
            -Force

        Write-Host "Archived: $($candidate.RelativePath)" `
            -ForegroundColor Green
    }
    elseif ($Mode -eq "Delete") {
        if ($candidate.Type -eq "Directory") {
            Remove-Item `
                -LiteralPath $candidate.FullPath `
                -Recurse `
                -Force
        }
        else {
            Remove-Item `
                -LiteralPath $candidate.FullPath `
                -Force
        }

        Write-Host "Deleted: $($candidate.RelativePath)" `
            -ForegroundColor Yellow
    }
}

Write-Host ""

if ($Mode -eq "Archive") {
    Write-Host "Cleanup archive created:" `
        -ForegroundColor Cyan
    Write-Host "  $archiveRoot"
}
else {
    Write-Host "Selected cleanup candidates were deleted." `
        -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Validate after cleanup:" `
    -ForegroundColor Cyan
Write-Host "  .\validate_runtime_v3_release_layout.ps1 -RuntimeRoot ."
Write-Host "  .\run_runtime_v3_release_gate.ps1 -RuntimeRoot ."
