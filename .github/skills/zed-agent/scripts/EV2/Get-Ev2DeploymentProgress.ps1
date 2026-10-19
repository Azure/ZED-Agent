<#
.SYNOPSIS
    Tells whether a pipeline run's EV2 rollout has finished DEPLOYING, without waiting for the
    run itself — the run stays in progress for the whole post-deployment managed validation
    (BCM canary: 'Canary-ManagedValidation', ~24 h).

.DESCRIPTION
    1. Finds the EV2 portal link in the run: the log of the timeline task named -PortalLinkTask
       (default 'Ev2 Managed SDP Region Agnostic'), which prints
         ##[warning]Ev2 portal link - https://ra.ev2portal.azure.net/#/rollouts/<Cloud>/<ServiceTreeId>/<ServiceGroup>/<RolloutId>
       (fallback: the 'Rollout Progress' task log). The newest link wins (stage retries start a
       new rollout). -PortalUrl skips this.
    2. GET <ev2>/api/rollouts/<id>?servicegroupname=<sg>&embed-detail=true (Prod only — the gov
       cloud APIs are not reachable from CorpNet: Phase 'unsupported-cloud').
    3. -StepName (default 'Canary-ManagedValidation') identifies the post-deployment validation
       action in ResourceGroups[].Resources[].Actions[]; its status is reported separately. Its
       region stages are the StageInfos named '<prefix>.<region>' where <prefix> = StepName
       without '-ManagedValidation' (e.g. 'Canary.centraluseuap').

    Phase:
      no-rollout         run has no portal link yet (e.g. still waiting on the Approval Service)
      deploying          no region stages yet, or regions not all deployed
      deployed           every region stage succeeded; validation need not have started
      failed             a region stage, the validation step or the rollout failed/was cancelled
      unsupported-cloud  rollout is in a cloud whose EV2 API is not reachable (use the ADO run)
      error              lookup failed (see Error) — callers fall back to the ADO run status

    Never throws.

.OUTPUTS
    PSCustomObject: Success, Phase, Deployed, DeployedAt, RunId, PortalUrl, Cloud, ServiceTreeId,
    ServiceGroup, RolloutId, RolloutStatus, ValidationStep, ValidationStatus, ValidationStartedAt,
    ValidationEndedAt, Regions[{ name, status, endTime }], Reason, Error
#>
[CmdletBinding()]
param(
    [long]$RunId,
    [string]$PortalUrl,
    [string]$StepName = 'Canary-ManagedValidation',
    [string]$PortalLinkTask = 'Ev2 Managed SDP Region Agnostic',
    [string]$Organization,
    [string]$Project,
    [string]$AdoToken,
    [string]$Ev2Token,
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = 'Stop'

$ev2Endpoints = @{ Prod = 'https://azureservicedeploy.msft.net' }
$linkRx = 'https://[a-z0-9.-]*ev2portal\.azure\.net/#/rollouts/(\w+)/([^/\s"]+)/([^/\s"]+)/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

$out = [pscustomobject]@{
    Success = $false; Phase = 'error'; Deployed = $false; DeployedAt = $null; RunId = $RunId
    PortalUrl = $null; Cloud = $null; ServiceTreeId = $null; ServiceGroup = $null; RolloutId = $null; RolloutStatus = $null
    ValidationStep = $StepName; ValidationStatus = $null; ValidationStartedAt = $null; ValidationEndedAt = $null
    Regions = @(); Reason = $null; Error = $null
}

function ConvertTo-UtcIso($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    $d = if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) } else { $v.ToUniversalTime() }
    } else {
        [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    }
    if ($d.Year -lt 2000) { return $null }   # EV2 uses 0001-01-01 for "not set"
    return $d.ToString('o')
}

function Get-Token([string]$Resource) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $t = az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null } finally { $ErrorActionPreference = $prev }
    if (-not $t) { throw "Failed to acquire a token for '$Resource'. Run 'az login --tenant microsoft.com'." }
    return $t
}

function Find-PortalLink {
    if (-not $AdoToken) { $script:AdoToken = Get-Token '499b84ac-1321-427f-aa17-267ca6975798' } else { $script:AdoToken = $AdoToken }
    $h = @{ Authorization = "Bearer $($script:AdoToken)" }
    $base = "https://dev.azure.com/$Organization/$Project/_apis/build/builds/$RunId"
    $tl = Invoke-RestMethod -Uri "$base/timeline?api-version=7.1" -Headers $h -ErrorAction Stop
    $recs = @($tl.records | Where-Object { $_ -and $_.log -and $_.log.id })
    $cands = @($recs | Where-Object { $_.name -eq $PortalLinkTask })
    if ($cands.Count -eq 0) { $cands = @($recs | Where-Object { $_.name -match '(?i)^rollout progress$' }) }
    $best = $null; $bestAt = [datetime]::MinValue
    foreach ($r in $cands) {
        $txt = [string](Invoke-WebRequest -Uri "$base/logs/$($r.log.id)?api-version=7.1" -Headers $h -UseBasicParsing -ErrorAction Stop).Content
        $m = @([regex]::Matches($txt, $linkRx))
        if ($m.Count -eq 0) { continue }
        $at = if ($r.startTime) { [datetime]$r.startTime } else { [datetime]::MinValue }
        if (-not $best -or $at -ge $bestAt) { $best = $m[-1].Value; $bestAt = $at }
    }
    return $best
}

try {
    if (-not $PortalUrl) {
        if (-not $RunId) { throw 'Pass -RunId or -PortalUrl.' }
        if (-not $Organization -or -not $Project) {
            $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $Organization) { $Organization = $svc.ado.organization }
            if (-not $Project) { $Project = $svc.ado.project }
        }
        $PortalUrl = Find-PortalLink
        if (-not $PortalUrl) {
            $out.Phase = 'no-rollout'; $out.Reason = "no EV2 portal link in '$PortalLinkTask' yet"; $out.Success = $true
            return $out
        }
    }
    $m = [regex]::Match($PortalUrl, $linkRx)
    if (-not $m.Success) { throw "Not an EV2 rollout link: $PortalUrl" }
    $out.PortalUrl = $m.Value; $out.Cloud = $m.Groups[1].Value; $out.ServiceTreeId = $m.Groups[2].Value
    $out.ServiceGroup = [uri]::UnescapeDataString($m.Groups[3].Value); $out.RolloutId = $m.Groups[4].Value

    $ep = $ev2Endpoints[$out.Cloud]
    if (-not $ep) { $out.Phase = 'unsupported-cloud'; $out.Reason = "EV2 API for cloud '$($out.Cloud)' is not reachable — use the pipeline run status"; $out.Success = $true; return $out }
    if (-not $Ev2Token) { $Ev2Token = Get-Token $ep }
    $uri = "$ep/api/rollouts/$($out.RolloutId)?servicegroupname=$([uri]::EscapeDataString($out.ServiceGroup))&api-version=2024-02-01&embed-detail=true"
    $ro = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Ev2Token" } -ErrorAction Stop

    $out.RolloutStatus = [string]$ro.Status
    $prefix = $StepName -replace '(?i)-ManagedValidation$', ''
    $regions = @(@($ro.StageInfos) | Where-Object { $_ -and $_.StageName -like "$prefix.*" -and $_.StageName -notmatch '__STAGE_PRECHECK__' } | ForEach-Object {
        [pscustomobject]@{ name = ($_.StageName -replace "^$([regex]::Escape($prefix))\.", ''); status = [string]$_.StageStatus; endTime = (ConvertTo-UtcIso $_.EndTime) }
    })
    $out.Regions = $regions
    $actions = @(@($ro.ResourceGroups) | ForEach-Object { @($_.Resources) } | ForEach-Object { @($_.Actions) } | Where-Object { $_ -and $_.StepName -eq $StepName })
    $v = $actions | Sort-Object { $s = ConvertTo-UtcIso $_.ActionOperationInfo.StartTime; if ($s) { $s } else { '' } } | Select-Object -Last 1
    if ($v) {
        $out.ValidationStatus = [string]$v.Status
        $out.ValidationStartedAt = ConvertTo-UtcIso $v.ActionOperationInfo.StartTime
        $out.ValidationEndedAt = ConvertTo-UtcIso $v.ActionOperationInfo.EndTime
    }

    $bad = '(?i)fail|cancel|abort|timedout|rollback'
    $badRegion = @($regions | Where-Object { $_.status -match $bad })
    if ($badRegion.Count) {
        $out.Phase = 'failed'; $out.Reason = "region stage(s) $(($badRegion | ForEach-Object { "$($_.name)=$($_.status)" }) -join ', ')"
    } elseif ($out.ValidationStatus -match $bad) {
        $out.Phase = 'failed'; $out.Reason = "$StepName $($out.ValidationStatus)"
    } elseif ($out.RolloutStatus -match $bad) {
        $out.Phase = 'failed'; $out.Reason = "rollout $($out.RolloutStatus)"
    } elseif ($regions.Count -gt 0 -and @($regions | Where-Object { $_.status -notmatch '(?i)^(succeeded|completed)$' }).Count -eq 0) {
        $out.Phase = 'deployed'; $out.Deployed = $true
        $out.DeployedAt = @($regions | Where-Object endTime | Sort-Object endTime | Select-Object -Last 1).endTime
        $out.Reason = if ($out.RolloutStatus -match '(?i)^(succeeded|completed)$') { 'rollout succeeded' } else { "all $($regions.Count) region(s) deployed; $StepName $(if ($out.ValidationStatus) { $out.ValidationStatus } else { 'not reported' }) (not required for deployment completion)" }
    } else {
        $out.Phase = 'deploying'
        $pending = @($regions | Where-Object { $_.status -notmatch '(?i)^(succeeded|completed)$' })
        $out.Reason = if ($regions.Count -eq 0) { "no '$prefix.*' region stages yet" } else { "waiting for $(($pending | ForEach-Object { "$($_.name)=$($_.status)" }) -join ', ')" }
    }
    $out.Success = $true
} catch {
    $out.Phase = 'error'; $out.Error = $_.Exception.Message
}
return $out
