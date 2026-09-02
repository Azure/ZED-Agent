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
.PARAMETER ReferenceRunsPath  Override for the golden reference cache consumed by Get-ReferenceRun.ps1.
.PARAMETER SkipReferenceComparison  Skip the golden-run SHAPE comparison.
.OUTPUTS PSCustomObject { verdict, releaseId, targetRepo, checks[], failedRequirements[] }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRepo,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$CriteriaPath,
    [string]$CatalogPath,
    [string]$ReferenceRunsPath,
    [switch]$SkipReferenceComparison
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
if (-not $CriteriaPath) { $CriteriaPath = Join-Path $skillRoot 'requirements\success-criteria.json' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $TargetRepo '.github\skills\zed-agent\pipeline-catalog.json' }
if (-not $ReferenceRunsPath) { $ReferenceRunsPath = Join-Path $skillRoot 'requirements\reference-runs.json' }

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
$notifFile    = Join-Path $relDir 'notifications-capture.json'
$notifRecords = @()
if (Test-Path $notifFile) {
    try { $nr = Get-Content $notifFile -Raw | ConvertFrom-Json; if ($nr) { $notifRecords = @($nr) } } catch {}
}

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

function Test-CaptureRecord($rec, $stepCriteria, $labelPrefix, $syntax, [bool]$acceptArtifactGap = $false) {
    # Returns list of issue strings ([] == clean).
    # $acceptArtifactGap: derived by caller from whether the parent step's acceptedStatuses includes
    # "completed-with-expected-artifact-gap". This collapses the former acceptExpectedArtifactFailure
    # field (removed from success-criteria.json) into a single acceptance layer.
    $issues = @()
    if (-not $rec.triggered) {
        # Steps 5/10: canary/prod cannot trigger on a freshly-cut branch because their YAMLs pull a
        # build-artifact resource keyed on ArtifactsBranch that only exists after a COMPLETED build
        # (which fast test mode cancels) → ADO 400 "No version was found". This is EXPECTED, not a
        # failure; the resolved params are still validated below. Accept it when the step opts in.
        $expectedArtifact = $acceptArtifactGap -and ("$($rec.error)" -match 'No version was found')
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
        # Check per-step acceptedStatuses if defined; fall back to requiring 'completed'
        $stepCrit = $criteria.steps.PSObject.Properties["$s"]?.Value
        if ($stepCrit -and $stepCrit.PSObject.Properties['acceptedStatuses']) {
            $accepted = @($stepCrit.acceptedStatuses)
        } else {
            $accepted = @('completed')
        }
        Add-Check "step.$s.completed" ($stepMap["$s"] -in $accepted) "step $s status='$($stepMap["$s"])' (want one of: $([string]::Join(', ', $accepted)))"
    }
}
if ($criteria.overall.noStepFailed) {
    $anyFailed = @($criteria.release.nonSkippedSteps | Where-Object { $stepMap["$_"] -in @('failed', 'failed-drift') })
    Add-Check 'overall.noStepFailed' ($anyFailed.Count -eq 0) "failed steps: $([string]::Join(',', $anyFailed))"
}
if ($criteria.overall.captureFileRequired) {
    Add-Check 'overall.captureFile' ((Test-Path $captureFile) -and $capture.Count -gt 0) "test-run-capture.json present with $($capture.Count) record(s)"
}
if ($criteria.overall.notificationsCaptureRequired) {
    $notifExists  = Test-Path $notifFile
    $notifCount   = $notifRecords.Count
    $failedNotifs = @($notifRecords | Where-Object { -not $_.ok }).Count
    $notifOk = $notifExists -and $notifCount -gt 0 -and $failedNotifs -eq 0
    Add-Check 'overall.notificationsCapture' $notifOk "notifications-capture.json: $notifCount record(s), $failedNotifs failed (ok=false)"
}

# ── Per-step checks ──
foreach ($stepProp in $criteria.steps.PSObject.Properties) {
    $n = $stepProp.Name; $sc = $stepProp.Value

    if ($sc.PSObject.Properties['status']) {
        Add-Check "step.$n.status" ($stepMap["$n"] -eq $sc.status) "step $n status='$($stepMap["$n"])' (want $($sc.status))"
    }
    if ($sc.PSObject.Properties['acceptedStatuses']) {
        $accepted = @($sc.acceptedStatuses)
        Add-Check "step.$n.status" ($stepMap["$n"] -in $accepted) "step $n status='$($stepMap["$n"])' (want one of: $([string]::Join(', ', $accepted)))"
    }

    # Trigger-and-cancel steps
    if ($sc.PSObject.Properties['capture']) {
        $cap = $sc.capture
        $recs = @($capture | Where-Object { "$($_.step)" -eq $n })
        # Derive artifact-gap acceptance from this step's acceptedStatuses (WP-5b collapse).
        # acceptExpectedArtifactFailure is no longer used in success-criteria.json.
        $acceptArtGap = $sc.PSObject.Properties['acceptedStatuses'] -and
                        (@($sc.acceptedStatuses) -contains 'completed-with-expected-artifact-gap')
        if ($cap.scope -eq 'single') {
            $rec = $recs | Where-Object { $_.pipelineKey -eq $cap.expectPipelineKey } | Select-Object -First 1
            if (-not $rec) { Add-Check "step.$n.capture" $false "no capture record for pipelineKey '$($cap.expectPipelineKey)'" }
            else {
                $issues = Test-CaptureRecord $rec $cap "step $n [$($rec.pipelineKey)]" ($criteria.parameterSyntax) $acceptArtGap
                Add-Check "step.$n.capture" ($issues.Count -eq 0) ($(if ($issues.Count) { [string]::Join('; ', $issues) } else { 'ok' }))
            }
        }
        else {
            # production-set: one-or-more pipelines
            $min = if ($cap.minPipelines) { [int]$cap.minPipelines } else { 1 }
            if ($recs.Count -lt $min) { Add-Check "step.$n.capture.count" $false "captured $($recs.Count) pipeline(s), need >= $min" }
            else {
                $allIssues = @()
                foreach ($rec in $recs) { $allIssues += Test-CaptureRecord $rec $cap "step $n [$($rec.pipelineKey)]" ($criteria.parameterSyntax) $acceptArtGap }
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

    # Steps with emailNotificationRequired — check notifications-capture.json
    if ($sc.PSObject.Properties['emailNotificationRequired'] -and $sc.emailNotificationRequired) {
        $notifRec = $notifRecords | Where-Object { "$($_.step)" -eq "$n" -and $_.ok } | Select-Object -First 1
        Add-Check "step.$n.emailNotification" ($null -ne $notifRec) "step $n email ok=$($notifRec.ok) subject='$($notifRec.subject)'"
    }

    # Step 16 — merge-back PR must have been created
    if ($sc.PSObject.Properties['mergeBackPrRequired'] -and $sc.mergeBackPrRequired) {
        $stepState = $null
        if ($state -and $state.PSObject.Properties['steps']) {
            # state.steps is a PSCustomObject keyed by step number string (e.g. "16"), NOT an array.
            # Use direct property access to look up the step entry.
            $stepState = $state.steps."$n"
        }
        $prId = $null
        if ($stepState) {
            if ($stepState.PSObject.Properties['pullRequestId'])    { $prId = $stepState.pullRequestId }
            elseif ($stepState.PSObject.Properties['mergeBackPrId']) { $prId = $stepState.mergeBackPrId }
            elseif ($stepState.PSObject.Properties['metadata'] -and $stepState.metadata.PSObject.Properties['pullRequestId']) {
                $prId = $stepState.metadata.pullRequestId
            }
        }
        # Also fall back to top-level release.json field
        if (-not $prId -and $release.PSObject.Properties['mergeBackPrId']) { $prId = $release.mergeBackPrId }
        Add-Check "step.$n.mergeBackPr" ([bool]$prId) "step $n pullRequestId='$prId'"
    }
}

# ── Reference-run SHAPE comparison (golden run vs what ZED posted) ──
# Values are ALLOWED to differ (CCOA exclusions, dev-status, region set, ephemeral test
# branch — see requirements.md caveats). The FORM must not. A scalar where the golden run
# used regions(...), or a bare list where it used a container literal, means ZED would post
# syntax the pipeline cannot parse.
if (-not $SkipReferenceComparison) {
    $refScript = Join-Path $PSScriptRoot 'Get-ReferenceRun.ps1'
    $libPath   = Join-Path $TargetRepo '.github\skills\zed-agent\scripts\lib\YamlParamModel.ps1'
    if (-not (Test-Path $libPath)) { $libPath = Join-Path $skillRoot '..\zed-agent\scripts\lib\YamlParamModel.ps1' }

    if (-not (Test-Path $refScript)) {
        Add-Check 'reference.available' $false "Get-ReferenceRun.ps1 not found at $refScript"
    }
    elseif (-not (Test-Path $libPath)) {
        Add-Check 'reference.available' $false "YamlParamModel.ps1 not found (needed for shape derivation)"
    }
    else {
        . $libPath
        $refRuns = @()
        try {
            $all = & $refScript -Scope 'all' -ReferencePath $ReferenceRunsPath
            foreach ($s in 'prod', 'canary') { if ($all.PSObject.Properties[$s]) { $refRuns += @($all.$s) } }
        } catch {
            Add-Check 'reference.available' $false "Get-ReferenceRun.ps1 failed: $($_.Exception.Message)"
        }

        if ($refRuns.Count -gt 0) {
            Add-Check 'reference.available' $true "$($refRuns.Count) golden reference run(s) loaded"
            $compared = 0
            foreach ($rec in @($capture | Where-Object { $_.PSObject.Properties['postedParameters'] -and $_.postedParameters })) {
                $ref = $refRuns | Where-Object { "$($_.definitionId)" -eq "$($rec.pipelineId)" } | Select-Object -First 1
                if (-not $ref) { continue }
                $compared++
                $diffs = @()
                foreach ($p in $ref.templateParameters.PSObject.Properties) {
                    $postedHas = $rec.postedParameters.PSObject.Properties[$p.Name]
                    if (-not $postedHas) { continue }   # YAML evolved — declaration check already covers this
                    $refShape = [string](Get-ParameterValueShape $p.Value).shape
                    $gotShape = [string](Get-ParameterValueShape $rec.postedParameters."$($p.Name)").shape
                    if ($refShape -eq $gotShape) { continue }
                    # regionsWildcard vs regionsList are both regions(...) — scope differs, form does not.
                    if (@($refShape, $gotShape) -contains 'regionsWildcard' -and @($refShape, $gotShape) -contains 'regionsList') { continue }
                    # An empty container is a legitimate narrowing of any list/map.
                    if ($gotShape -eq 'empty' -or $refShape -eq 'empty') { continue }
                    $diffs += "$($p.Name): golden='$refShape' posted='$gotShape'"
                }
                Add-Check "reference.shape.$($rec.pipelineKey)" ($diffs.Count -eq 0) `
                    $(if ($diffs.Count) { "vs golden build $($ref.buildId): " + [string]::Join('; ', $diffs) } else { "matches golden build $($ref.buildId) shape-for-shape" })
            }
            if ($compared -eq 0) { Add-Check 'reference.compared' $true 'no capture record matched a golden reference definitionId (nothing to compare)' }
        }
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
