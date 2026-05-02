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
Assert-FieldExists -FieldPath 'notifications.groups.releaseOwner'   -Root $cfg -NonEmptyArray

# stepGates must exist (but is not drilled into with dot-notation sub-fields)
if ($null -eq $cfg.PSObject.Properties['stepGates'] -or $null -eq $cfg.stepGates) {
    throw "Required config field is missing or null: 'stepGates'"
}

# --- Return composed object ---
return $cfg
