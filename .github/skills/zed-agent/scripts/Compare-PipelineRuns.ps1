<#
.SYNOPSIS
    L-19/L-20: Fail-closed complete diff between a source pipeline run and a
    candidate (clone/follow-up) run.

.DESCRIPTION
    Before accepting a cloned/follow-up run, compares source and candidate across
    ALL of: branch, artifact build, every template parameter, macros, exclusions,
    cloud flags, repository resources, template commits, and rollout mode.

    DEFAULT IS DENY: any field not in the explicit allow-list that differs causes
    rejection. Unknown/new fields are also treated as differences — they are never
    silently ignored.

    L-20 enforcement: if template repository commits have drifted, the run is
    NEVER described as an "exact clone" and is rejected unless the allow-list
    explicitly includes template repository fields.

.PARAMETER SourceRun
    PSCustomObject representing the source (reference) run. Must have:
      sourceBranch, templateParameters (hashtable), resources (optional PSCustomObject
      with repositories containing self and template repo info).

.PARAMETER CandidateRun
    PSCustomObject representing the candidate (clone/follow-up) run. Same schema.

.PARAMETER AllowedDifferences
    Array of field names that ARE permitted to differ (e.g. a regions-facet field).
    Everything else must be identical.

.PARAMETER TemplateRepoFields
    Array of template repository resource field names to compare.
    Default: @('templates', 'obcoretemplates', '1escoretemplates').

.OUTPUTS
    PSCustomObject with: isAccepted, differences (array), templateDrift (bool),
    summary (string).
    THROWS on rejection with an actionable message listing every unauthorized difference.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$SourceRun,
    [Parameter(Mandatory)]$CandidateRun,
    [string[]]$AllowedDifferences = @(),
    [string[]]$TemplateRepoFields = @('templates', 'obcoretemplates', '1escoretemplates')
)

$ErrorActionPreference = 'Stop'

# Build allow-list as a case-insensitive set
$allowSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($a in $AllowedDifferences) { [void]$allowSet.Add($a) }

$differences = @()
$templateDrift = $false

# ── 1. Compare sourceBranch ──
$srcBranch = $SourceRun.sourceBranch
$candBranch = $CandidateRun.sourceBranch
if ($srcBranch -ne $candBranch) {
    if (-not $allowSet.Contains('sourceBranch')) {
        $differences += [PSCustomObject]@{
            field    = 'sourceBranch'
            source   = $srcBranch
            candidate = $candBranch
            allowed  = $false
        }
    }
}

# ── 2. Compare templateParameters (the core diff) ──
$srcParams = @{}
$candParams = @{}

# Normalize to hashtable
if ($SourceRun.templateParameters -is [hashtable]) {
    $srcParams = $SourceRun.templateParameters
} elseif ($SourceRun.templateParameters) {
    foreach ($p in $SourceRun.templateParameters.PSObject.Properties) {
        $srcParams[$p.Name] = $p.Value
    }
}
if ($CandidateRun.templateParameters -is [hashtable]) {
    $candParams = $CandidateRun.templateParameters
} elseif ($CandidateRun.templateParameters) {
    foreach ($p in $CandidateRun.templateParameters.PSObject.Properties) {
        $candParams[$p.Name] = $p.Value
    }
}

# All known keys (union of both)
$allKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($k in $srcParams.Keys) { [void]$allKeys.Add($k) }
foreach ($k in $candParams.Keys) { [void]$allKeys.Add($k) }

foreach ($key in ($allKeys | Sort-Object)) {
    $srcVal = if ($srcParams.ContainsKey($key)) { "$($srcParams[$key])" } else { $null }
    $candVal = if ($candParams.ContainsKey($key)) { "$($candParams[$key])" } else { $null }

    if ($srcVal -ne $candVal) {
        $isAllowed = $allowSet.Contains($key)
        $differences += [PSCustomObject]@{
            field     = "templateParameters.$key"
            source    = $srcVal
            candidate = $candVal
            allowed   = $isAllowed
        }
    }
}

# ── 3. Compare repository resources / template commits (L-20) ──
$srcResources = @{}
$candResources = @{}

# Extract repository resource versions
if ($SourceRun.resources -and $SourceRun.resources.repositories) {
    $repos = $SourceRun.resources.repositories
    if ($repos -is [hashtable]) {
        $srcResources = $repos
    } else {
        foreach ($p in $repos.PSObject.Properties) {
            $srcResources[$p.Name] = $p.Value
        }
    }
}
if ($CandidateRun.resources -and $CandidateRun.resources.repositories) {
    $repos = $CandidateRun.resources.repositories
    if ($repos -is [hashtable]) {
        $candResources = $repos
    } else {
        foreach ($p in $repos.PSObject.Properties) {
            $candResources[$p.Name] = $p.Value
        }
    }
}

# Compare template repository versions
$allRepoKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($k in $srcResources.Keys) { [void]$allRepoKeys.Add($k) }
foreach ($k in $candResources.Keys) { [void]$allRepoKeys.Add($k) }

foreach ($repoKey in ($allRepoKeys | Sort-Object)) {
    # Skip 'self' — that's the pipeline's own repo, compared via sourceBranch
    if ($repoKey -eq 'self') { continue }

    $srcVersion = $null
    $candVersion = $null

    if ($srcResources.ContainsKey($repoKey)) {
        $r = $srcResources[$repoKey]
        $srcVersion = if ($r -is [string]) { $r }
                      elseif ($r.version) { $r.version }
                      elseif ($r.refName) { $r.refName }
                      else { ($r | ConvertTo-Json -Compress -Depth 3) }
    }
    if ($candResources.ContainsKey($repoKey)) {
        $r = $candResources[$repoKey]
        $candVersion = if ($r -is [string]) { $r }
                       elseif ($r.version) { $r.version }
                       elseif ($r.refName) { $r.refName }
                       else { ($r | ConvertTo-Json -Compress -Depth 3) }
    }

    if ($srcVersion -ne $candVersion) {
        $fieldName = "resources.repositories.$repoKey"
        $isAllowed = $allowSet.Contains($repoKey) -or $allowSet.Contains($fieldName)
        $differences += [PSCustomObject]@{
            field     = $fieldName
            source    = $srcVersion
            candidate = $candVersion
            allowed   = $isAllowed
        }

        # L-20: template drift detection
        if ($repoKey -in $TemplateRepoFields) {
            $templateDrift = $true
        }
    }
}

# ── 4. Verdict ──
$unauthorizedDiffs = @($differences | Where-Object { -not $_.allowed })
$isAccepted = ($unauthorizedDiffs.Count -eq 0)

$result = [PSCustomObject]@{
    isAccepted     = $isAccepted
    differences    = $differences
    templateDrift  = $templateDrift
    unauthorizedCount = $unauthorizedDiffs.Count
    summary        = $null
}

if (-not $isAccepted) {
    $lines = @("PIPELINE_RUN_DIFF_REJECTED: $($unauthorizedDiffs.Count) unauthorized difference(s) found between source and candidate run.")

    if ($templateDrift) {
        $lines += "⚠️  TEMPLATE_DRIFT_DETECTED: Shared template repository commits have changed. This run is NOT an exact clone. (L-20)"
    }

    $lines += ""
    $lines += "Unauthorized differences:"
    foreach ($d in $unauthorizedDiffs) {
        $lines += "  - $($d.field): source='$($d.source)' candidate='$($d.candidate)'"
    }

    $allowedDiffs = @($differences | Where-Object { $_.allowed })
    if ($allowedDiffs.Count -gt 0) {
        $lines += ""
        $lines += "Allowed differences (expected):"
        foreach ($d in $allowedDiffs) {
            $lines += "  - $($d.field): source='$($d.source)' → candidate='$($d.candidate)'"
        }
    }

    $lines += ""
    $lines += "Remedy: Either pin the source template commits in the candidate run,"
    $lines += "        or add the drifted fields to the explicit allow-list if the"
    $lines += "        change is intentional and approved."

    $result.summary = $lines -join "`n"
    throw $result.summary
}

$result.summary = "Run comparison passed: $($differences.Count) difference(s), all allowed."
return $result
