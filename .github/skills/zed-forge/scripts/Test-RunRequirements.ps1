<#
.SYNOPSIS
    Verify a completed ZED true test run against ZedForge's requirements
    (success-criteria.json). Produces a pass/fail report the loop consumes.

.DESCRIPTION
    Reads the target repo's release.json + state.json + test-run-capture.json and
    evaluates every rule in success-criteria.json:
      * release: testMode true, skipped/non-skipped steps have the right status.
      * overall: all non-skipped steps completed, none failed, capture file present.
      * per-step: status; and for trigger steps (2/5/10) the captured
        postedParameters must contain the required keys, contain NO unresolved
        {{tokens}}, and MATCH the pipeline-catalog entry they came from.
      * step 4: a real commit Excel was produced. step 6: the BVT Kusto query
        ran. step 13: a SafeFly R2D was filed.

    The catalog used for the match check is the one ZED ACTUALLY read (the target
    repo's copy), so this proves ZED filled parameters correctly.

.PARAMETER TargetRepo   Target deployment repo.
.PARAMETER ReleaseId    Test release id.
.PARAMETER CriteriaPath Override. Default <skill>/requirements/success-criteria.json.
.PARAMETER CatalogPath  Override. Default <target>/.github/skills/zed-agent/pipeline-catalog.json.
.OUTPUTS PSCustomObject { verdict, releaseId, targetRepo, checks[], failedRequirements[] }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRepo,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$CriteriaPath,
    [string]$CatalogPath
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
if (-not $CriteriaPath) { $CriteriaPath = Join-Path $skillRoot 'requirements\success-criteria.json' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $TargetRepo '.github\skills\zed-agent\pipeline-catalog.json' }

$relDir      = Join-Path $TargetRepo ".zed-agent/releases/$ReleaseId"
$releaseFile = Join-Path $relDir 'release.json'
$stateFile   = Join-Path $relDir 'state.json'
$captureFile = Join-Path $relDir 'test-run-capture.json'

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check($id, $ok, $detail) { $checks.Add([pscustomobject]@{ id = $id; ok = [bool]$ok; detail = $detail }) }

# ── Load artifacts ──
$criteria = Get-Content $CriteriaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$release  = if (Test-Path $releaseFile) { Get-Content $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$state    = if (Test-Path $stateFile) { Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$capture  = @()
if (Test-Path $captureFile) {
    try { $parsed = Get-Content $captureFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($parsed) { $capture = @($parsed) } } catch { $capture = @() }
}
$catalog = if (Test-Path $CatalogPath) { Get-Content $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

# ── Helpers ──
function Get-StepStatusMap($st) {
    $map = @{}
    if (-not $st -or -not $st.PSObject.Properties['steps']) { return $map }
    $steps = $st.steps
    if ($steps -is [System.Array]) {
        foreach ($s in $steps) { if ($s.PSObject.Properties['number']) { $map["$($s.number)"] = $s.status } }
    }
    else {
        foreach ($p in $steps.PSObject.Properties) { $map[$p.Name] = $p.Value.status }
    }
    return $map
}
$stepMap = Get-StepStatusMap $state

function Resolve-CatalogEntry($pipelineKey) {
    if (-not $catalog) { return $null }
    if ($pipelineKey -eq 'officialBuild') { return $catalog.officialBuild }
    if ($pipelineKey -match '^(canary|production):(.+)$') {
        $section = $Matches[1]; $key = $Matches[2]
        if ($catalog.$section -and $catalog.$section.PSObject.Properties[$key]) { return $catalog.$section.$key }
    }
    return $null
}

function Test-ParamSyntax($posted, $syntax, $labelPrefix) {
    # Validate captured parameter VALUES against golden syntax rules (format, not literal values).
    $issues = @()
    if (-not $syntax -or -not $posted) { return $issues }
    $fes = $syntax.forbiddenExcludeStamps
    foreach ($p in $posted.PSObject.Properties) {
        $key = $p.Name; $val = "$($p.Value)"
        foreach ($rule in @($syntax.rules)) {
            if ($key -match $rule.appliesToKeysMatching) {
                if ($val -notmatch $rule.pattern) { $issues += "$labelPrefix '$key'='$val' violates syntax [$($rule.id)]" }
                elseif ($rule.PSObject.Properties['notPattern'] -and $rule.notPattern -and ($val -match $rule.notPattern)) { $issues += "$labelPrefix '$key'='$val' must not match /$($rule.notPattern)/ [$($rule.id)]" }
            }
        }
        if ($fes -and ($key -match $fes.appliesToKeysMatching)) {
            foreach ($bad in @($fes.forbidden)) {
                if ($val -match [regex]::Escape($bad)) { $issues += "$labelPrefix '$key' must NOT exclude '$bad' (dev-only in reference; no longer in development)" }
            }
        }
    }
    return $issues
}

function Test-CaptureRecord($rec, $stepCriteria, $labelPrefix, $syntax) {
    # Returns list of issue strings ([] == clean).
    $issues = @()
    if (-not $rec.triggered) {
        # Steps 5/10: canary/prod cannot trigger on a freshly-cut branch because their YAMLs pull a
        # build-artifact resource keyed on ArtifactsBranch that only exists after a COMPLETED build
        # (which fast test mode cancels) → ADO 400 "No version was found". This is EXPECTED, not a
        # failure; the resolved params are still validated below. Accept it when the step opts in.
        $expectedArtifact = $stepCriteria.acceptExpectedArtifactFailure -and ("$($rec.error)" -match 'No version was found')
        if (-not $expectedArtifact) {
            $issues += "$labelPrefix triggered=false (runId=$($rec.runId); error=$($rec.error))"
        }
    }

    if ($stepCriteria.sourceBranchResolved) {
        $sb = "$($rec.sourceBranch)"
        if ([string]::IsNullOrWhiteSpace($sb) -or $sb -match '\{\{') { $issues += "$labelPrefix sourceBranch not resolved: '$sb'" }
    }

    $posted = $rec.postedParameters
    $postedKeys = @()
    if ($posted) { $postedKeys = @($posted.PSObject.Properties.Name) }

    foreach ($rk in @($stepCriteria.requiredKeys)) {
        if ($postedKeys -notcontains $rk) { $issues += "$labelPrefix missing required key '$rk'" }
    }

    if ($stepCriteria.noUnresolvedTokens) {
        foreach ($p in $postedKeys) {
            $v = "$($posted.$p)"
            if ($v -match '\{\{') { $issues += "$labelPrefix param '$p' has unresolved token: $v" }
        }
    }

    if ($stepCriteria.matchCatalog) {
        $entry = Resolve-CatalogEntry $rec.pipelineKey
        if (-not $entry) { $issues += "$labelPrefix no catalog entry for '$($rec.pipelineKey)'" }
        else {
            foreach ($cp in $entry.templateParameters.PSObject.Properties) {
                $cKey = $cp.Name; $cVal = "$($cp.Value)"
                $pVal = if ($postedKeys -contains $cKey) { "$($posted.$cKey)" } else { $null }
                if ($null -eq $pVal) { $issues += "$labelPrefix catalog key '$cKey' not posted"; continue }
                if ($cVal -match '\{\{') {
                    if ($pVal -match '\{\{') { $issues += "$labelPrefix token key '$cKey' not resolved (posted='$pVal')" }
                }
                elseif ($pVal -ne $cVal) {
                    $issues += "$labelPrefix key '$cKey' mismatch: posted='$pVal' catalog='$cVal'"
                }
            }
        }
    }
    if ($stepCriteria.syntaxCheck -and $syntax) {
        $issues += Test-ParamSyntax $rec.postedParameters $syntax $labelPrefix
    }
    return $issues
}

# ── Release-level checks ──
if ($criteria.release.testModeMustBeTrue) {
    Add-Check 'release.testMode' ($release -and $release.testMode -eq $true) "release.testMode == true"
}
foreach ($s in @($criteria.release.skippedSteps)) {
    Add-Check "step.$s.skipped" ($stepMap["$s"] -eq 'skipped') "step $s status='$($stepMap["$s"])' (want skipped)"
}

# ── Overall ──
if ($criteria.overall.allNonSkippedStepsCompleted) {
    foreach ($s in @($criteria.release.nonSkippedSteps)) {
        Add-Check "step.$s.completed" ($stepMap["$s"] -eq 'completed') "step $s status='$($stepMap["$s"])' (want completed)"
    }
}
if ($criteria.overall.noStepFailed) {
    $anyFailed = @($criteria.release.nonSkippedSteps | Where-Object { $stepMap["$_"] -in @('failed', 'failed-drift') })
    Add-Check 'overall.noStepFailed' ($anyFailed.Count -eq 0) "failed steps: $([string]::Join(',', $anyFailed))"
}
if ($criteria.overall.captureFileRequired) {
    Add-Check 'overall.captureFile' ((Test-Path $captureFile) -and $capture.Count -gt 0) "test-run-capture.json present with $($capture.Count) record(s)"
}

# ── Per-step checks ──
foreach ($stepProp in $criteria.steps.PSObject.Properties) {
    $n = $stepProp.Name; $sc = $stepProp.Value

    if ($sc.PSObject.Properties['status']) {
        Add-Check "step.$n.status" ($stepMap["$n"] -eq $sc.status) "step $n status='$($stepMap["$n"])' (want $($sc.status))"
    }

    # Trigger-and-cancel steps
    if ($sc.PSObject.Properties['capture']) {
        $cap = $sc.capture
        $recs = @($capture | Where-Object { "$($_.step)" -eq $n })
        if ($cap.scope -eq 'single') {
            $rec = $recs | Where-Object { $_.pipelineKey -eq $cap.expectPipelineKey } | Select-Object -First 1
            if (-not $rec) { Add-Check "step.$n.capture" $false "no capture record for pipelineKey '$($cap.expectPipelineKey)'" }
            else {
                $issues = Test-CaptureRecord $rec $cap "step $n [$($rec.pipelineKey)]" ($criteria.parameterSyntax)
                Add-Check "step.$n.capture" ($issues.Count -eq 0) ($(if ($issues.Count) { [string]::Join('; ', $issues) } else { 'ok' }))
            }
        }
        else {
            # production-set: one-or-more pipelines
            $min = if ($cap.minPipelines) { [int]$cap.minPipelines } else { 1 }
            if ($recs.Count -lt $min) { Add-Check "step.$n.capture.count" $false "captured $($recs.Count) pipeline(s), need >= $min" }
            else {
                $allIssues = @()
                foreach ($rec in $recs) { $allIssues += Test-CaptureRecord $rec $cap "step $n [$($rec.pipelineKey)]" ($criteria.parameterSyntax) }
                Add-Check "step.$n.capture" ($allIssues.Count -eq 0) ($(if ($allIssues.Count) { [string]::Join('; ', $allIssues) } else { "$($recs.Count) pipeline(s) ok" }))
            }
        }
    }

    # Step 4 — real commit Excel produced
    if ($sc.PSObject.Properties['commitExcelUrlRequired'] -and $sc.commitExcelUrlRequired) {
        $url = $null
        if ($release -and $release.PSObject.Properties['commitExcelUrl']) { $url = $release.commitExcelUrl }
        if (-not $url -and $state -and $state.PSObject.Properties['step4ExcelUrl']) { $url = $state.step4ExcelUrl }
        Add-Check "step.$n.commitExcel" ([bool]$url) "commitExcelUrl='$url'"
    }

    # Step 6 — BVT query ran
    if ($sc.PSObject.Properties['bvtQueryMustRun'] -and $sc.bvtQueryMustRun) {
        $bvt = $capture | Where-Object { "$($_.step)" -eq $n -and $_.PSObject.Properties['queryRan'] } | Select-Object -First 1
        Add-Check "step.$n.bvtQuery" ($bvt -and $bvt.queryRan -eq $true) "bvt-query-check queryRan=$($bvt.queryRan) rowCount=$($bvt.rowCount)"
    }

    # Step 13 — SafeFly filed
    if ($sc.PSObject.Properties['safeFlyFiledRequired'] -and $sc.safeFlyFiledRequired) {
        $filed = $release -and (($release.PSObject.Properties['safeFlyId'] -and $release.safeFlyId) -or ($release.PSObject.Properties['safeFlyRequestNumber'] -and $release.safeFlyRequestNumber))
        Add-Check "step.$n.safeFlyFiled" ([bool]$filed) "safeFlyId='$($release.safeFlyId)' safeFlyRequestNumber='$($release.safeFlyRequestNumber)'"
    }
}

# ── Verdict ──
$failed = @($checks | Where-Object { -not $_.ok })
$verdict = if ($failed.Count -eq 0) { 'pass' } else { 'fail' }

Write-Host ""
Write-Host "=== ZedForge verification: $ReleaseId -> $($verdict.ToUpper()) ===" -ForegroundColor $(if ($verdict -eq 'pass') { 'Green' } else { 'Yellow' })
foreach ($c in $checks) {
    $mark = if ($c.ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1} — {2}" -f $mark, $c.id, $c.detail)
}

return [pscustomobject]@{
    verdict            = $verdict
    releaseId          = $ReleaseId
    targetRepo         = $TargetRepo
    checks             = $checks
    failedRequirements = $failed
}
