<#
.SYNOPSIS
    Loads and composes service-config.json and pipeline-catalog.json into a single configuration object.

.DESCRIPTION
    Reads service-config.json from the specified path (or default location one level up from scripts/),
    reads pipeline-catalog.json from the same directory, merges the pipeline catalog under a 'pipelines'
    property, validates required fields, and returns the composed PSCustomObject.

.PARAMETER ServiceConfigPath
    Path to service-config.json. Defaults to Join-Path $PSScriptRoot '..\service-config.json'.

.OUTPUTS
    PSCustomObject — the merged configuration with service config fields plus $cfg.pipelines.*

.EXAMPLE
    $cfg = & .\Load-ServiceConfig.ps1
    $cfg.service.name          # → "<YourServiceName>"
    $cfg.pipelines.canary.'<Key>'.id  # → pipeline ID from catalog
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ServiceConfigPath
)

$ErrorActionPreference = 'Stop'

# Default path resolution
if (-not $ServiceConfigPath) {
    $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json'
}

# Resolve to absolute path for consistent error messages
$ServiceConfigPath = [System.IO.Path]::GetFullPath($ServiceConfigPath)

# --- Load service-config.json ---
if (-not (Test-Path -LiteralPath $ServiceConfigPath)) {
    throw "Service config not found: $ServiceConfigPath"
}

try {
    $cfg = Get-Content -LiteralPath $ServiceConfigPath -Raw | ConvertFrom-Json
}
catch {
    throw "Failed to parse service-config.json: $_"
}

# --- Load pipeline-catalog.json from the same directory ---
$configDir   = Split-Path -Parent $ServiceConfigPath
$catalogPath = Join-Path $configDir 'pipeline-catalog.json'

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "Pipeline catalog not found: $catalogPath"
}

try {
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
}
catch {
    throw "Failed to parse pipeline-catalog.json: $_"
}

# --- Merge pipeline catalog into config under 'pipelines' property ---
$cfg | Add-Member -NotePropertyName 'pipelines' -NotePropertyValue $catalog -Force

# --- Validation helper ---
function Assert-FieldExists {
    param(
        [string]$FieldPath,
        [object]$Root,
        [switch]$NonEmptyArray
    )

    $parts   = $FieldPath -split '\.'
    $current = $Root
    foreach ($part in $parts) {
        if ($null -eq $current) {
            throw "Required config field is missing: '$FieldPath'"
        }
        # Navigate into the object property
        $current = $current.PSObject.Properties[$part].Value
    }

    if ($null -eq $current) {
        throw "Required config field is missing or null: '$FieldPath'"
    }

    if ($NonEmptyArray) {
        # PS 5.1 unwraps single-element JSON arrays into scalars — accept both
        $isNonEmptyArray  = ($current -is [System.Array]) -and $current.Count -gt 0
        $isNonEmptyScalar = ($current -is [string]) -and (-not [string]::IsNullOrWhiteSpace($current))
        if (-not ($isNonEmptyArray -or $isNonEmptyScalar)) {
            throw "Required config field must be a non-empty array: '$FieldPath'"
        }
    }
    elseif ($current -is [string] -and [string]::IsNullOrWhiteSpace($current)) {
        throw "Required config field is empty: '$FieldPath'"
    }
}

# --- Validate required fields ---
Assert-FieldExists -FieldPath 'service.name'              -Root $cfg
Assert-FieldExists -FieldPath 'service.displayName'       -Root $cfg
Assert-FieldExists -FieldPath 'serviceTreeIds.safefly'    -Root $cfg
Assert-FieldExists -FieldPath 'ado.organization'          -Root $cfg
Assert-FieldExists -FieldPath 'ado.project'               -Root $cfg
Assert-FieldExists -FieldPath 'ado.repository'            -Root $cfg
Assert-FieldExists -FieldPath 'kusto.bvt.cluster'         -Root $cfg
Assert-FieldExists -FieldPath 'kusto.canary.cluster'      -Root $cfg
Assert-FieldExists -FieldPath 'sharepoint.sitePath'            -Root $cfg
Assert-FieldExists -FieldPath 'notifications.groups.permanent' -Root $cfg -NonEmptyArray

# --- Validate notifications.routing block ---
# Routing is per-step (keys match stepGates: '1-send-reminder' .. '16-merge-back') with
# per-outcome sub-objects (success | failure | halt). Any step/outcome not listed
# defaults to owner-only. Nothing is *required* to be present — but every group
# reference must resolve to a declared group under notifications.groups.
if ($null -eq $cfg.notifications.PSObject.Properties['routing'] -or $null -eq $cfg.notifications.routing) {
    throw "Required config field is missing or null: 'notifications.routing'. Run 'setup-service group 5b' to regenerate."
}

$validOutcomes = @('success', 'failure', 'halt')
$validStepKeys = @(
    '1-send-reminder','2-cut-branch','3-wait-build','4-collect-commits',
    '5-deploy-canary','6-bvt-check','7-rollback','8-post-rollback-bvt',
    '9-post-rollback-signoff','10-roll-forward','11-post-rollforward-bvt',
    '12-post-rollforward-signoff','13-create-r2d','14-crb-review',
    '15-production-rollout','16-merge-back'
)

$groupsObj = $cfg.notifications.groups
foreach ($routingProp in $cfg.notifications.routing.PSObject.Properties) {
    $stepKey = $routingProp.Name
    if ($stepKey -eq '_comment') { continue }
    if ($validStepKeys -notcontains $stepKey) {
        throw "notifications.routing.$stepKey is not a valid step key. Expected one of: $($validStepKeys -join ', ')."
    }
    $stepBlock = $routingProp.Value
    foreach ($outcomeProp in $stepBlock.PSObject.Properties) {
        $outcome = $outcomeProp.Name
        if ($validOutcomes -notcontains $outcome) {
            throw "notifications.routing.$stepKey.$outcome is not a valid outcome. Expected one of: $($validOutcomes -join ', ')."
        }
        $rule = $outcomeProp.Value
        foreach ($prop in @('emailGroups','ccGroups','teamsGroups')) {
            if ($rule.PSObject.Properties[$prop]) {
                foreach ($g in @($rule.$prop)) {
                    if ([string]::IsNullOrWhiteSpace($g)) { continue }
                    if (-not $groupsObj.PSObject.Properties[$g]) {
                        throw "notifications.routing.$stepKey.$outcome.$prop references group '$g' which is not declared under notifications.groups. Run 'setup-service group 5b'."
                    }
                }
            }
        }
    }
}

# stepGates must exist (but is not drilled into with dot-notation sub-fields)
if ($null -eq $cfg.PSObject.Properties['stepGates'] -or $null -eq $cfg.stepGates) {
    throw "Required config field is missing or null: 'stepGates'"
}

# --- Optional ado.integration (Step 2a RI / 2b FI) ---
$integration = $cfg.ado.PSObject.Properties['integration']
if ($integration -and $integration.Value -and $integration.Value.PSObject.Properties['enabled'] -and $integration.Value.enabled -eq $true) {
    $int = $integration.Value
    foreach ($f in @('developBranch', 'mainBranch')) {
        if (-not $int.PSObject.Properties[$f] -or [string]::IsNullOrWhiteSpace([string]$int.$f)) {
            throw "Required config field is missing or empty: 'ado.integration.$f' (required when ado.integration.enabled = true). Run 'setup-service group 2'."
        }
    }
    if ($int.developBranch -eq $int.mainBranch) {
        throw "ado.integration.developBranch and ado.integration.mainBranch must differ (both are '$($int.mainBranch)')."
    }
    if ($int.mainBranch -ne $cfg.ado.baseBranch) {
        throw "ado.integration.mainBranch ('$($int.mainBranch)') must equal ado.baseBranch ('$($cfg.ado.baseBranch)') — the release branch is cut from the FI result."
    }
    if ($int.PSObject.Properties['conflictStrategy'] -and $int.conflictStrategy -and $int.conflictStrategy -ne 'newest-commit-per-file') {
        throw "ado.integration.conflictStrategy '$($int.conflictStrategy)' is not supported. Expected 'newest-commit-per-file'."
    }
}

# --- Optional commitExcel.mode == "tracker" (one sheet per release in a shared workbook) ---
$ceProp = $cfg.PSObject.Properties['commitExcel']
if ($ceProp -and $ceProp.Value -and $ceProp.Value.PSObject.Properties['mode'] -and $ceProp.Value.mode) {
    $ce = $ceProp.Value
    if (@('per-release', 'tracker') -notcontains [string]$ce.mode) {
        throw "commitExcel.mode '$($ce.mode)' is not supported. Expected 'per-release' or 'tracker'."
    }
    if ($ce.mode -eq 'tracker') {
        if (-not $ce.PSObject.Properties['tracker'] -or -not $ce.tracker) { throw "commitExcel.tracker is required when commitExcel.mode = 'tracker'. Run 'setup-service group 7'." }
        if ([string]::IsNullOrWhiteSpace([string]$ce.tracker.url)) { throw "Required config field is empty: 'commitExcel.tracker.url'." }
        $cols = @($ce.tracker.columns)
        if ($cols.Count -eq 0) { throw "Required config field is empty: 'commitExcel.tracker.columns'." }
        if (@($cols | Where-Object { $_.source -in @('link', 'linkText') }).Count -ne 1) {
            throw "commitExcel.tracker.columns needs exactly one column with source 'link' (or 'linkText')."
        }
        if (@($cols | Where-Object { $_.PSObject.Properties['required'] -and $_.required -eq $true }).Count -eq 0) {
            throw "commitExcel.tracker.columns has no 'required: true' column — Step 4 would complete immediately."
        }
        if ([string]$ce.sheetNameTemplate -notmatch '\{\{(YYMM|releaseId)\}\}') {
            throw "commitExcel.sheetNameTemplate '$($ce.sheetNameTemplate)' must contain {{YYMM}} (or {{releaseId}}) so each release gets its own sheet."
        }
    }
}

# --- Return composed object ---
return $cfg
