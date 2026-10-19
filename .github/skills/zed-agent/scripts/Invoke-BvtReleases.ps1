<#
.SYNOPSIS
    BVT releases instead of a fixed BVT wait: after a canary deployment (Steps 5, 7, 10) ZED creates
    the configured classic BVT releases (BCM: 40785 IaaSVM-CloudTest-Scheduled-Canary and 47437
    IaaSVM-LHT-CloudTest-Canary, MABIsOfficial="True") and the BVT step (6, 8, 11) continues as soon as
    all of their stages have finished — not after 24 h.

.DESCRIPTION
    Config — pipeline-catalog.json:
        "bvtReleases": {
          "steps": [6, 8, 11],                       # BVT steps that use the releases
          "timeoutHours": 12,                        # Poll → Phase 'timed-out' after this
          "releases": {
            "<key>": { "definitionId": 40785, "variables": { "MABIsOfficial": "True" } }, ...
          }
        }
    Each release is created like the portal's "Create release": every artifact's default (latest)
    version passed explicitly (an unresolved artifact would start without bits), the configured
    variables overridden (they must be "settable at release time"), all other variables at their
    definition defaults.

    State: state.bvtReleases.<step> = { status: running | completed | failed | timed-out,
      startedAt, completedAt, runs: { <key>: { definitionId, definitionName, releaseId, name, url,
      createdAt, status: running | completed | failed-to-start, outcome, stages[{ name, status }],
      summary, finishedAt, error } }, history[] }

    A release is finished when every stage is final (succeeded / partiallySucceeded / rejected /
    canceled), the release was abandoned, or a stage was rejected/canceled and nothing is still
    queued or running (later stages will never start). outcome = rejected (a stage rejected or
    canceled, or abandoned) / partiallySucceeded / succeeded. partiallySucceeded is the normal
    result of these test releases (the 'Publish VSO Drop' stage always is) — the owner judges.

    Actions:
      Start   -Step N  Create the releases not created yet for step N (idempotent). -Rerun also
                       re-creates releases that failed to start or ended rejected/canceled/abandoned
                       (the old run moves to history[]). Test mode → Phase 'skipped', nothing created.
      Poll    -Step N  Refresh every running release. Phase: running | completed | failed (a release
                       could not be created) | timed-out.
      Get     -Step N  Current state.
    Never throws for Start/Poll — errors are returned in .Error / per run.

.OUTPUTS
    PSCustomObject: Success, Action, Step, Phase, Runs[], Summary (markdown table), Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Poll', 'Get')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][int]$Step,
    [switch]$Rerun,
    [string]$StateFile,
    [string]$StateLock,
    [string]$AuditFile,
    [string]$ReleaseFile,
    [string]$PipelineCatalogPath,
    [string]$ServiceConfigPath,
    [string]$Organization,
    [string]$Project,
    [string]$AccessToken,
    [datetime]$Now
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

$out = [pscustomobject]@{ Success = $false; Action = $Action; Step = $Step; Phase = $null; Runs = @(); Summary = $null; Error = $null }
# keep ISO date strings as written (no DateTime round-trip of other state fields)
$script:Cfj = @{ AsHashtable = $true; Depth = 100 }
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:Cfj.DateKind = 'String' }
$final = @('succeeded', 'partiallySucceeded', 'rejected', 'canceled')
$active = @('inProgress', 'queued', 'scheduled')

function Get-UtcNow { if ($script:NowValue) { $script:NowValue } else { (Get-Date).ToUniversalTime() } }
function Get-NowIso { (Get-UtcNow).ToString('o') }
function Write-Audit([hashtable]$Entry) {
    try { $Entry.ts = Get-NowIso; $Entry | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $script:AuditFile -Encoding UTF8 } catch { }
}
function Get-AdoToken {
    if ($script:AccessToken) { return $script:AccessToken }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $t = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null } finally { $ErrorActionPreference = $prev }
    if (-not $t) { throw "Failed to acquire ADO token. Run 'az login --tenant microsoft.com'." }
    $script:AccessToken = $t
    return $t
}
function ConvertTo-UtcDate($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }; return $v.ToUniversalTime() }
    return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

# Read-modify-write of state.bvtReleases.<step> under the state lock. $Mutator gets the current
# step object (hashtable, or $null) and returns the new one.
function Update-StepState([scriptblock]$Mutator) {
    $script:updated = $null
    Invoke-WithStateLock -LockFile $script:StateLock -Action ({
        $st = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json @script:Cfj
        if (-not $st.ContainsKey('bvtReleases') -or $null -eq $st['bvtReleases']) { $st['bvtReleases'] = @{} }
        $cur = if ($st['bvtReleases'].ContainsKey("$Step")) { $st['bvtReleases']["$Step"] } else { $null }
        $new = & $Mutator $cur
        $st['bvtReleases']["$Step"] = $new
        $st['lastUpdated'] = Get-NowIso
        $st | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 -NoNewline
        $script:updated = $new
    })
    return $script:updated
}
function Get-StepState {
    $st = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json @script:Cfj
    if ($st.ContainsKey('bvtReleases') -and $st['bvtReleases'] -and $st['bvtReleases'].ContainsKey("$Step")) { return $st['bvtReleases']["$Step"] }
    return $null
}

function New-BvtRelease([string]$Key, $Cfg) {
    $vsrm = "https://vsrm.dev.azure.com/$($script:Organization)/$($script:Project)/_apis/release"
    $headers = @{ Authorization = "Bearer $(Get-AdoToken)"; 'Content-Type' = 'application/json' }
    $defId = [int]$Cfg.definitionId
    $run = [ordered]@{ definitionId = $defId; definitionName = $null; releaseId = $null; name = $null; url = $null; createdAt = (Get-NowIso); status = 'running'; outcome = $null; stages = @(); summary = $null; finishedAt = $null; artifacts = @(); error = $null }
    try {
        if ($Cfg.variables -and $Cfg.variables.PSObject.Properties['MABIsOfficial']) {
            Assert-OfficialValue $Cfg.variables.MABIsOfficial
        }
        $versions = Invoke-RestMethod -Uri "$vsrm/artifacts/versions?releaseDefinitionId=$defId&api-version=7.1" -Headers $headers -ErrorAction Stop
        $artifacts = @()
        foreach ($av in @($versions.artifactVersions)) {
            if (-not $av) { continue }
            if ($av.errorMessage) { throw "artifact '$($av.alias)': $($av.errorMessage)" }
            if (-not $av.defaultVersion -or -not $av.defaultVersion.id) { throw "artifact '$($av.alias)' has no version to deploy." }
            $artifacts += [ordered]@{ alias = $av.alias; instanceReference = [ordered]@{ id = [string]$av.defaultVersion.id; name = [string]$av.defaultVersion.name } }
        }
        $vars = [ordered]@{}
        if ($Cfg.PSObject.Properties['variables'] -and $Cfg.variables) {
            foreach ($p in $Cfg.variables.PSObject.Properties) { $vars[$p.Name] = [ordered]@{ value = [string]$p.Value } }
        }
        $body = [ordered]@{ definitionId = $defId; isDraft = $false; description = "ZED $($script:ServiceName) release $ReleaseId — Step $Step BVT"; artifacts = $artifacts; variables = $vars } | ConvertTo-Json -Depth 8
        # Capture the actual serialized payload, not a later editable release variable.
        $posted = $body | ConvertFrom-Json
        if ($vars.Contains('MABIsOfficial')) { Assert-OfficialValue $posted.variables.MABIsOfficial.value }
        $rel = Invoke-RestMethod -Uri "$vsrm/releases?api-version=7.1" -Method POST -Headers $headers -Body $body -ErrorAction Stop
        $run['creationVariables'] = @{}
        # Only this non-secret contract value is needed as provenance.
        if ($vars.Contains('MABIsOfficial')) { $run.creationVariables['MABIsOfficial'] = $posted.variables.MABIsOfficial.value }
        $run.releaseId = [long]$rel.id; $run.name = [string]$rel.name
        $run.definitionName = if ($rel.releaseDefinition) { [string]$rel.releaseDefinition.name } else { $null }
        $run.url = if ($rel._links -and $rel._links.web -and $rel._links.web.href) { [string]$rel._links.web.href } else { "https://dev.azure.com/$($script:Organization)/$($script:Project)/_releaseProgress?_a=release-pipeline-progress&releaseId=$($rel.id)" }
        $run.artifacts = @($artifacts | ForEach-Object { "$($_.alias)=$($_.instanceReference.name)" })
        Write-Audit @{ event = 'bvt-release-created'; step = $Step; key = $Key; definitionId = $defId; releaseId = $rel.id; name = $rel.name; variables = @($vars.Keys); artifacts = $run.artifacts }
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { '' }
        $run.status = 'failed-to-start'; $run.error = "Could not create release from definition ${defId}: $($_.Exception.Message)$detail"
        Write-Audit @{ event = 'bvt-release-create-failed'; step = $Step; key = $Key; definitionId = $defId; error = $run.error }
    }
    return $run
}

function Assert-OfficialValue($Value) {
    if ($Value -isnot [string] -or $Value -cne 'True') {
        throw 'BVT_VARIABLE_INVALID: MABIsOfficial must be the case-sensitive string "True" (not a Boolean or "true").'
    }
}

# An explicitly verified retry is separate from creation provenance. Bind it to the latest
# deployment/phase and re-read its task log even on Get (cached completion is not a bypass).
function Assert-VerifiedAttempts($Run) {
    $proof = $Run['verifiedAttempts']
    if (-not $proof -or [long]$proof['releaseId'] -ne [long]$Run['releaseId']) { throw 'Missing attempt provenance.' }
    Assert-OfficialValue $proof['MABIsOfficial']
    $base = "https://vsrm.dev.azure.com/$($script:Organization)/$($script:Project)/_apis/release/releases/$($Run['releaseId'])"
    $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
    $rel = Invoke-RestMethod -Uri "${base}?api-version=7.1" -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    Assert-OfficialValue $rel.variables.MABIsOfficial.value
    $checked = 0
    foreach ($env in @($rel.environments)) {
        $mapped = @($env.deployPhasesSnapshot | ForEach-Object { $_.workflowTasks } | Where-Object {
            $_.inputs.parserProperties -cmatch '(?:^|;)worker:MABIsOfficialRun=\$\(MABIsOfficial\)(?:;|$)'
        })
        if (-not $mapped.Count) { continue }
        if ($mapped.Count -ne 1) { throw 'Ambiguous official-variable task mapping.' }
        $rows = @($proof['environments'] | Where-Object { [long]$_['environmentId'] -eq [long]$env.id })
        if ($rows.Count -ne 1) { throw "Missing/duplicate attempt proof for environment $($env.id)." }
        $row = $rows[0]
        $latest = @($env.deploySteps | Sort-Object attempt -Descending)[0]
        if (-not $latest -or [int]$latest.attempt -ne [int]$row['attempt'] -or [long]$latest.id -ne [long]$row['deploymentId']) {
            throw "Unverified newer/different attempt for environment $($env.id)."
        }
        $phases = @($latest.releaseDeployPhases | Where-Object { [long]$_.id -eq [long]$row['phaseId'] })
        if ($phases.Count -ne 1) { throw 'Attempt phase identity mismatch.' }
        $tasks = @($phases[0].deploymentJobs | ForEach-Object { $_.tasks } | Where-Object { [int]$_.id -eq [int]$row['taskId'] })
        if ($tasks.Count -ne 1 -or $tasks[0].name -cne $row['taskName']) { throw 'Attempt task identity mismatch.' }
        # Construct the URL ourselves; never send auth to an evidence-provided URL.
        $url = "$base/environments/$($env.id)/deployPhases/$($row['phaseId'])/tasks/$($row['taskId'])/logs"
        $text = [string](Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 20 -ErrorAction Stop).Content
        $lines = @($text -split "`n")
        $line = [int]$row['line']
        if ($line -lt 1 -or $line -gt $lines.Count) { throw 'Attempt log evidence line missing.' }
        $values = @([regex]::Matches($lines[$line - 1], '(?:^|[;"\s])worker:MABIsOfficialRun=([^;"\s]+)'))
        if ($values.Count -ne 1) { throw 'Missing/ambiguous consumed official value.' }
        Assert-OfficialValue $values[0].Groups[1].Value
        $checked++
    }
    if ($checked -eq 0 -or $checked -ne @($proof['environments']).Count) { throw 'Incomplete attempt coverage.' }
}

function Test-RunEvidence([string]$Key, $Run) {
    if ($Run['status'] -eq 'failed-to-start') { return $Run }
    $entry = if ($cfg -and $cfg.releases) { $cfg.releases.$Key } else { $null }
    $requiresOfficial = $entry -and $entry.variables -and $entry.variables.PSObject.Properties['MABIsOfficial']
    if ($requiresOfficial -or ($Run['creationVariables'] -and $Run['creationVariables'].Contains('MABIsOfficial'))) {
        try {
            if ($Run['verifiedAttempts']) { Assert-VerifiedAttempts $Run }
            else { Assert-OfficialValue $Run['creationVariables']['MABIsOfficial'] }
        } catch {
            $Run['status'] = 'invalid-evidence'
            $Run['error'] = 'BVT_VARIABLE_EVIDENCE_INVALID: missing or invalid creation-time MABIsOfficial="True". Editing a live release does not repair consumed job variables; owner-approved replacement or attempt-level verification is required.'
            Write-Audit @{ event = 'bvt-evidence-invalid'; step = $Step; key = $Key; releaseId = $Run['releaseId']; error = $Run['error'] }
        }
    }
    return $Run
}

function Update-Run([string]$Key, $Run) {
    $Run = Test-RunEvidence $Key $Run
    if ($Run['status'] -ne 'running' -or -not $Run['releaseId']) { return $Run }
    $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
    $rel = Invoke-RestMethod -Uri "https://vsrm.dev.azure.com/$($script:Organization)/$($script:Project)/_apis/release/releases/$($Run['releaseId'])?api-version=7.1" -Headers $headers -ErrorAction Stop
    if ($Run['creationVariables'] -and $Run['creationVariables'].Contains('MABIsOfficial')) {
        try { Assert-OfficialValue $rel.variables.MABIsOfficial.value }
        catch {
            $Run['status'] = 'invalid-evidence'; $Run['error'] = $_.Exception.Message
            Write-Audit @{ event = 'bvt-evidence-invalid'; step = $Step; key = $Key; releaseId = $Run['releaseId']; error = $Run['error'] }
            return $Run
        }
    }
    $envs = @($rel.environments | Sort-Object rank)
    $Run['stages'] = @($envs | ForEach-Object { [ordered]@{ name = [string]$_.name; status = [string]$_.status } })
    $Run['summary'] = ($envs | ForEach-Object { "$($_.name)=$($_.status)" }) -join '; '
    if (-not $Run['definitionName'] -and $rel.releaseDefinition) { $Run['definitionName'] = [string]$rel.releaseDefinition.name }
    $statuses = @($envs | ForEach-Object { [string]$_.status })
    $stopped = @($statuses | Where-Object { $_ -in @('rejected', 'canceled') }).Count -gt 0 -and @($statuses | Where-Object { $_ -in $active }).Count -eq 0
    $allFinal = $statuses.Count -gt 0 -and @($statuses | Where-Object { $_ -notin $final }).Count -eq 0
    if ($allFinal -or $stopped -or $rel.status -eq 'abandoned') {
        $Run['status'] = 'completed'; $Run['finishedAt'] = Get-NowIso
        $Run['outcome'] = if ($rel.status -eq 'abandoned' -or @($statuses | Where-Object { $_ -in @('rejected', 'canceled') }).Count) { 'rejected' }
                          elseif (@($statuses | Where-Object { $_ -eq 'partiallySucceeded' }).Count) { 'partiallySucceeded' } else { 'succeeded' }
        Write-Audit @{ event = 'bvt-release-completed'; step = $Step; key = $Key; releaseId = $Run['releaseId']; outcome = $Run['outcome']; stages = $Run['summary'] }
    }
    return $Run
}

function Get-Phase($S) {
    if (-not $S) { return $null }
    $runs = @($S['runs'].Values)
    if (@($runs | Where-Object { $_['status'] -in @('failed-to-start', 'invalid-evidence') }).Count) { return 'failed' }
    if ($runs.Count -and @($runs | Where-Object { $_['status'] -ne 'completed' }).Count -eq 0) { return 'completed' }
    return [string]$S['status']
}

function Format-Summary($S) {
    if (-not $S) { return $null }
    $lines = @('| Release | Outcome | Stages |', '|---|---|---|')
    foreach ($k in @($S['runs'].Keys | Sort-Object)) {
        $r = $S['runs'][$k]
        $label = if ($r['definitionName']) { "$($r['definitionName']) $($r['name'])" } else { "$k $($r['name'])" }
        $o = if ($r['status'] -in @('failed-to-start', 'invalid-evidence')) { "$($r['status']): $($r['error'])" } elseif ($r['outcome']) { $r['outcome'] } else { 'running' }
        $lines += "| [$label]($($r['url'])) | $o | $($r['summary']) |"
    }
    return ($lines -join "`n")
}

try {
    if ($PSBoundParameters.ContainsKey('Now')) { $script:NowValue = $Now.ToUniversalTime() }
    if (-not $StateFile -or -not $StateLock -or -not $AuditFile -or -not $ReleaseFile) {
        $paths = & (Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1') -ReleaseId $ReleaseId
        if (-not $StateFile) { $StateFile = $paths.StateFile }
        if (-not $StateLock) { $StateLock = $paths.LockFile }
        if (-not $AuditFile) { $AuditFile = $paths.AuditFile }
        if (-not $ReleaseFile) { $ReleaseFile = $paths.ReleaseFile }
    }
    $script:StateFile = $StateFile; $script:StateLock = $StateLock; $script:AuditFile = $AuditFile; $script:AccessToken = $AccessToken
    if (-not (Test-Path -LiteralPath $StateFile)) { throw "State file not found: $StateFile" }
    $release = if (Test-Path -LiteralPath $ReleaseFile) { Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

    if (-not $PipelineCatalogPath) { $PipelineCatalogPath = Join-Path $PSScriptRoot '..\pipeline-catalog.json' }
    $catalog = Get-Content -LiteralPath $PipelineCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg = if ($catalog.PSObject.Properties['bvtReleases']) { $catalog.bvtReleases } else { $null }
    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    $svc = if (Test-Path -LiteralPath $ServiceConfigPath) { Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    if (-not $Organization -and $svc) { $Organization = $svc.ado.organization }
    if (-not $Project -and $svc) { $Project = $svc.ado.project }
    $script:Organization = $Organization; $script:Project = $Project
    $script:ServiceName = if ($svc -and $svc.service.displayName) { $svc.service.displayName } elseif ($svc) { $svc.service.name } else { '' }

    switch ($Action) {
        'Get' { } # The common output path below validates cached evidence too.
        'Start' {
            if (-not $cfg -or -not $cfg.releases -or @($cfg.steps) -notcontains $Step) { throw "pipeline-catalog.json has no bvtReleases for Step $Step." }
            if ($release -and $release.testMode) { $out.Phase = 'skipped'; $out.Success = $true; break }
            $keys = @($cfg.releases.PSObject.Properties.Name)
            $cur = Get-StepState
            $todo = @($keys | Where-Object {
                $r = if ($cur -and $cur['runs'] -and $cur['runs'].ContainsKey($_)) { $cur['runs'][$_] } else { $null }
                -not $r -or ($Rerun -and ($r['status'] -in @('failed-to-start', 'invalid-evidence') -or $r['outcome'] -eq 'rejected'))
            })
            $created = @{}
            foreach ($k in $todo) { $created[$k] = New-BvtRelease $k $cfg.releases.$k }
            $null = Update-StepState {
                param($c)
                $s = if ($c) { $c } else { @{ status = 'running'; startedAt = (Get-NowIso); runs = @{}; history = @() } }
                if (-not $s.ContainsKey('runs') -or $null -eq $s['runs']) { $s['runs'] = @{} }
                if (-not $s.ContainsKey('history') -or $null -eq $s['history']) { $s['history'] = @() }
                foreach ($k in $created.Keys) {
                    if ($s['runs'].ContainsKey($k)) { $s['history'] = @($s['history']) + @($s['runs'][$k]) }
                    $s['runs'][$k] = $created[$k]
                }
                if ($created.Count) { $s['status'] = 'running'; $s['completedAt'] = $null; if ($Rerun) { $s['startedAt'] = Get-NowIso } }
                $s['status'] = $(if ((Get-Phase $s) -eq 'failed') { 'failed' } elseif ((Get-Phase $s) -eq 'completed') { 'completed' } else { 'running' })
                return $s
            }
        }
        'Poll' {
            $cur = Get-StepState
            if (-not $cur) { throw "No BVT releases started for Step $Step (run -Action Start first)." }
            $refreshed = @{}
            foreach ($k in @($cur['runs'].Keys)) {
                try { $refreshed[$k] = Update-Run $k $cur['runs'][$k] }
                catch { $out.Error = "release $($cur['runs'][$k]['releaseId']): $($_.Exception.Message)" }
            }
            $timeoutH = if ($cfg -and $cfg.PSObject.Properties['timeoutHours'] -and $cfg.timeoutHours) { [double]$cfg.timeoutHours } else { 12 }
            $null = Update-StepState {
                param($c)
                $s = if ($c) { $c } else { $cur }
                foreach ($k in $refreshed.Keys) { $s['runs'][$k] = $refreshed[$k] }
                $ph = Get-Phase $s
                if ($ph -eq 'completed' -and $s['status'] -ne 'completed') { $s['status'] = 'completed'; $s['completedAt'] = Get-NowIso }
                elseif ($ph -eq 'failed') { $s['status'] = 'failed' }
                elseif ($s['status'] -eq 'running' -and $s['startedAt'] -and ((Get-UtcNow) - (ConvertTo-UtcDate $s['startedAt'])).TotalHours -ge $timeoutH) {
                    $s['status'] = 'timed-out'
                    Write-Audit @{ event = 'bvt-releases-timed-out'; step = $Step; hours = $timeoutH }
                }
                return $s
            }
        }
    }

    if ($out.Phase -ne 'skipped') {
        $s = Get-StepState
        if (-not $out.Phase) { $out.Phase = if ($s) { [string]$s['status'] } else { 'not-started' } }
        if ($s) {
            foreach ($k in @($s['runs'].Keys)) { $s['runs'][$k] = Test-RunEvidence $k $s['runs'][$k] }
            if ((Get-Phase $s) -eq 'failed') { $out.Phase = 'failed' }
            $out.Runs = @($s['runs'].Keys | Sort-Object | ForEach-Object { $r = $s['runs'][$_]; [pscustomobject]@{ key = $_; releaseId = $r['releaseId']; name = $r['name']; definitionName = $r['definitionName']; url = $r['url']; status = $r['status']; outcome = $r['outcome']; summary = $r['summary']; error = $r['error'] } })
            $out.Summary = Format-Summary $s
        }
    }
    $out.Success = -not $out.Error -and $out.Phase -ne 'failed'
} catch {
    $out.Error = $_.Exception.Message
    if ($Action -eq 'Get') { throw }
}
return $out
