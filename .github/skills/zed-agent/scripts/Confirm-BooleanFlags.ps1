<#
.SYNOPSIS
    L-07: Owner-confirmation step for boolean flags that differ between pipeline
    variants (e.g., CanaryScript=true in PROT vs false in DT).

.DESCRIPTION
    A reference run's boolean flags may reflect one-time overrides, incremental
    changes, or different deployment conditions. This function compares boolean
    flags across pipeline variants and surfaces differences that require an
    explicit owner decision rather than auto-accepting.

    Confirmation is recorded/auditable — not just prompted.

.PARAMETER PipelineBaselines
    Hashtable keyed by pipeline key, values are PSCustomObjects with
    templateParameters (from prior-run baseline).

.PARAMETER FlagNames
    Array of boolean parameter names to check across pipelines.
    Defaults to common script flags.

.OUTPUTS
    PSCustomObject with:
      - conflicts: array of flag conflicts requiring owner decision
      - confirmed: hashtable of confirmed flag values (after owner input)
      - auditRecord: serializable audit entry
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable]$PipelineBaselines,
    [string[]]$FlagNames = @('CanaryScript','MCScript','FFScript','BleuScript','UsNatScript','UsSecScript'),
    [hashtable]$OwnerDecisions = @{}
)

$ErrorActionPreference = 'Stop'

$conflicts = @()
$flagValues = @{}

# Collect flag values across all pipelines
foreach ($flagName in $FlagNames) {
    $values = @{}
    foreach ($pKey in $PipelineBaselines.Keys) {
        $baseline = $PipelineBaselines[$pKey]
        $tp = $baseline.templateParameters
        if ($tp -and $tp.PSObject.Properties[$flagName]) {
            $values[$pKey] = [string]$tp.$flagName
        } elseif ($tp -is [hashtable] -and $tp.ContainsKey($flagName)) {
            $values[$pKey] = [string]$tp[$flagName]
        }
    }

    if ($values.Count -le 1) { continue }

    # Check if values differ across pipelines
    $uniqueValues = @($values.Values | Sort-Object -Unique)
    if ($uniqueValues.Count -gt 1) {
        $details = @()
        foreach ($pKey in ($values.Keys | Sort-Object)) {
            $details += "$pKey=$($values[$pKey])"
        }
        $conflicts += [PSCustomObject]@{
            flagName  = $flagName
            values    = $values
            details   = $details -join ', '
            message   = "Flag '$flagName' differs across pipelines: $($details -join ', '). Prior-run values may reflect one-time overrides. Owner must confirm the correct value for each pipeline."
        }
    }

    $flagValues[$flagName] = $values
}

# Apply owner decisions if provided
$confirmed = @{}
if ($OwnerDecisions -and $OwnerDecisions.Count -gt 0) {
    foreach ($flagName in $OwnerDecisions.Keys) {
        $confirmed[$flagName] = $OwnerDecisions[$flagName]
    }
}

# Require confirmation for all conflicts
$requiresConfirmation = @($conflicts | Where-Object {
    -not $confirmed.ContainsKey($_.flagName)
})

$auditRecord = [PSCustomObject]@{
    ts                    = (Get-Date).ToUniversalTime().ToString('o')
    event                 = 'boolean-flag-confirmation'
    totalFlagsChecked     = $FlagNames.Count
    conflictsFound        = $conflicts.Count
    confirmedCount        = $confirmed.Count
    pendingConfirmation   = $requiresConfirmation.Count
}

[PSCustomObject]@{
    conflicts             = $conflicts
    confirmed             = $confirmed
    requiresConfirmation  = $requiresConfirmation
    auditRecord           = $auditRecord
    allFlagValues         = $flagValues
}
