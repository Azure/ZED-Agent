<#
.SYNOPSIS
    Creates a SafeFly R2D (Ready to Deploy) request via the SafeFly V2 GraphQL API.

.DESCRIPTION
    Fetches the live SafeFly V2 form, maps ZED's release parameters to question answers,
    computes the effective-required question set (EV2 orchestrator partition only),
    validates all required answers and option values, assembles SaveRequestRequestBaseInput,
    and — when NOT in DryRun mode — submits via the submitRequest GraphQL mutation.

    SAFETY: -DryRun is the ONLY mode used during automated test runs. No mutation
    (submitRequest / saveRequest / cloneRequest) is ever called when -DryRun is set.
    Filing a real R2D for Azure Backup is a production action — this gate must never
    be bypassed.

.PARAMETER BuildId
    ADO Build ID from the CloudBuild pipeline run (Step 2).

.PARAMETER BuildNumber
    Value for the 'ev2.build' answer. With service-config safefly.r2dBuildSource =
    "productionRun" this is the production pipeline run's buildNumber (e.g. Release-2610-1,
    Step 13 triggers production first); otherwise the release build number.

.PARAMETER ReleaseId
    Release identifier, e.g. "2026-04".

.PARAMETER ReleaseOwnerAlias
    Alias of the release owner (owner field on the request).

.PARAMETER TeamAssessedRisk
    Risk level. Default: "Low".

.PARAMETER DeploymentNature
    Array of deployment nature strings. Default: @("New feature", "General bug fixes").
    (V2 note: DeploymentNature has no direct equivalent field in App deployment — drops.)

.PARAMETER SDPType
    SDP type. V2 mapping: "Standard SDP" → "Standard SDP (Normal Rollout)";
    "Conservative SDP" stays as-is. Default: "Conservative SDP".

.PARAMETER TargetedRegions
    Azure regions for the deployment (display names). Not used for core.regions when
    service-config safefly.regionGroups is set (see -ExcludedRegions); required otherwise.

.PARAMETER ExcludedRegions
    CCOA-excluded region short names (release.json excludedRegions, e.g. "eastasia").
    Removed from the safefly.regionGroups region set (case/space-insensitive match).

.PARAMETER ReleaseMonth
    Release month 'yyyy-MM' (release.json releaseMonth). Drives the {month}/{yy} title and
    description tokens — the R2D names the payload month, not the filing date (13.14103
    "BCM September Payload" was filed 2026-10-05). Default: current UTC month.

.PARAMETER ChangeSummary
    One line per notable change in the payload (HTML-encoded, joined with <br>) for the
    {changeSummary} description token. Required for a real filing when the template uses it.

.PARAMETER TitleThemes
    Short comma-separated themes of the payload for the {titleThemes} title token
    (13.12038 style: "BCM Monthly Release 2609: Expanded recovery capabilities, CVM/S2S
    updates, pipeline hardening, and reliability fixes"). Required for a real filing when
    the title template uses it.

.PARAMETER ChangeSections
    Payload changes for the {changeSections} description token, one object per change:
    @{ section = 'Highlights'; text = '<one sentence>'; pr = 17484944 } (or workItem = <id>,
    or url + label). Rendered as <h4>section</h4><ul><li>text <a href=url>label</a></li></ul>
    in the order of safefly.descriptionSections (empty sections omitted; an unknown section
    fails closed). pr / workItem links come from safefly.prUrlTemplate / workItemUrlTemplate.
    Required for a real filing when the template uses it.

.PARAMETER PreviousBuildId
    ADO build id of the previous release build (release.json previousBuildId) for the
    {payloadUrl} token (safefly.payloadUrlTemplate: build-health Payload view between
    {previousBuildId} and {buildId}).

.PARAMETER CommitExcelSheet
    Commit tracker sheet holding this payload's rows (release.json commitExcelSheet) for the
    {commitExcelSheet} description token. Empty + commitExcel.mode == "tracker" → the sheet ZED's
    convention gives this release: commitExcel.sheetNameTemplate expanded for -ReleaseId
    ({{releaseName}} → BCM2610_2).

.PARAMETER ValidationSummary
    How the payload was validated and is monitored, for the {validationSummary} token of
    safefly.teamRiskJustificationTemplate ('core.team_risk.justification' — what R2D
    reviewers judge; 13.14103 was rejected for missing validation/monitoring evidence).
    Required for a real filing when the template uses it.

.PARAMETER AnticipatedEndDays
    Days from now for AnticipatedEndTime. Default: end of current month.

.PARAMETER CommitExcelUrl
    SharePoint URL to the commit Excel file. Used in changeDescription.

.PARAMETER AdoBuildUrl
    ADO build link for the 'ado.build' question. When set, 'ado.build_na' is answered
    'Applicable' and 'ado.build' gets this URL; when empty, 'ado.build_na' = 'Not Applicable'.
    Step 13 passes release.json → buildUrl when service-config safefly.adoBuildLink is true.

.PARAMETER RollbackStrategy
    Option for 'core.rollback_strategy' (label or value). Default: service-config
    safefly.rollbackStrategy, else 'DRI determines rollback or rollforward in real time based on the issue'.

.PARAMETER DryRun
    REQUIRED for test runs. Assembles and prints the payload without calling
    submitRequest. The fail-closed validation still runs (required answers, options).

.OUTPUTS
    PSCustomObject with safeFlyId, safeFlyRequestNumber, safeFlyUrl, requestStatus on success.
    In DryRun mode: requestStatus = "DryRun", safeFlyId = "dry-run".
    Throws on validation failure or API error.

.EXAMPLE
    # Dry-run — assemble and validate without submitting:
    .\New-SafeFlyRequest.ps1 -BuildId 12345 -BuildNumber "Release-2604-2" `
        -ReleaseId "2026-04" -ReleaseOwnerAlias "gireeraj" `
        -TargetedRegions @("East Asia","West US 2") -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BuildId,
    [Parameter(Mandatory)] [string] $BuildNumber,
    [Parameter(Mandatory)] [string] $ReleaseId,
    [Parameter(Mandatory)] [string] $ReleaseOwnerAlias,
    [string] $TeamAssessedRisk = "Low",
    [ValidateSet("New feature", "General bug fixes", "Config change", "Critical security fixes", "CRI fixes", "Monitoring/health signals", "Policy change", "Secrets/Certificate management", "Sev 1/2 repair", "OS/Image patch", "Other")]
    [string[]] $DeploymentNature = @("New feature", "General bug fixes"),
    [ValidateSet("Standard SDP", "Conservative SDP")]
    [string]   $SDPType = "Conservative SDP",
    [string[]] $TargetedRegions = @(),
    [string[]] $ExcludedRegions = @(),
    [string]   $ReleaseMonth = "",
    [string[]] $ChangeSummary = @(),
    [string]   $TitleThemes = "",
    [object[]] $ChangeSections = @(),
    [string]   $PreviousBuildId = "",
    [string]   $CommitExcelSheet = "",
    [string]   $ValidationSummary = "",
    [int]    $AnticipatedEndDays = 0,
    [string] $CommitExcelUrl = "",
    [string] $AdoBuildUrl = "",
    [string] $RollbackStrategy = "",
    [switch] $DryRun,

    [Parameter()]
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"

# --- Load service config ---
$cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

# --- Require V2 config ---
$graphQlEndpoint = if ($cfg.safefly.PSObject.Properties['graphQlEndpoint']) { $cfg.safefly.graphQlEndpoint } else { $null }
if ([string]::IsNullOrWhiteSpace($graphQlEndpoint)) {
    throw "SafeFly V2 is not configured. Add safefly.graphQlEndpoint (and related V2 fields) to service-config.json. " +
          "SafeFly V1 write API (POST /api/RequestCreation/v1/requests) is permanently HTTP 410 and cannot be used."
}

$franchiseId  = if ($cfg.safefly.PSObject.Properties['franchiseId'])  { $cfg.safefly.franchiseId }  else { $null }
$changeTypeId = if ($cfg.safefly.PSObject.Properties['changeTypeId']) { $cfg.safefly.changeTypeId } else { $null }
$formId       = if ($cfg.safefly.PSObject.Properties['formId'])       { $cfg.safefly.formId }       else { $null }
$v2ServiceId  = if ($cfg.safefly.PSObject.Properties['serviceId'])    { $cfg.safefly.serviceId }    else { $cfg.serviceTreeIds.safefly }

foreach ($req in @('franchiseId','changeTypeId','formId')) {
    $val = if ($cfg.safefly.PSObject.Properties[$req]) { $cfg.safefly.PSObject.Properties[$req].Value } else { $null }
    if ([string]::IsNullOrWhiteSpace($val)) {
        throw "safefly.$req is not configured in service-config.json (required for SafeFly V2)."
    }
}

# --- Timestamps ---
$now      = (Get-Date).ToUniversalTime()
$startIso = $now.ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
if ($AnticipatedEndDays -gt 0) {
    $endIso = $now.AddDays($AnticipatedEndDays).ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
} else {
    $endOfMonth = (Get-Date -Year $now.Year -Month $now.Month -Day 1).AddMonths(1).AddDays(-1)
    $endIso = $endOfMonth.ToUniversalTime().ToString("yyyy-MM-ddT23:59:59") + "Z"
}

# --- Derive title/description ---
# {month}/{yy} name the release (payload) month, not the filing date.
$monthDate = $now
if (-not [string]::IsNullOrWhiteSpace($ReleaseMonth)) {
    if ($ReleaseMonth -notmatch '^\d{4}-\d{2}$') { throw "SafeFly V2: -ReleaseMonth must be 'yyyy-MM' (got '$ReleaseMonth')." }
    $monthDate = [datetime]::ParseExact("$ReleaseMonth-01", 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}
$monthName   = $monthDate.ToString("MMMM", [System.Globalization.CultureInfo]::InvariantCulture)
$shortYear   = $monthDate.ToString("yy")

# Content placeholders the owner must supply before a real filing (DryRun only warns).
$contentWarnings = [System.Collections.Generic.List[string]]::new()
function Get-SafeFlyText([string]$Value, [string]$Token) {
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    $param = $Token.Substring(0,1).ToUpper() + $Token.Substring(1)
    $contentWarnings.Add("{$Token} has no value (pass -$param)") | Out-Null
    return "[$Token required]"
}
function Get-SafeFlyCfg([string]$Name) {
    if ($cfg.safefly.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace("$($cfg.safefly.$Name)")) { return "$($cfg.safefly.$Name)" }
    return ''
}
function Test-SafeFlyTemplateToken([string]$Name) {
    # True when any SafeFly text template references {Name}.
    foreach ($t in @((Get-SafeFlyCfg 'titleTemplate'), (Get-SafeFlyCfg 'descriptionTemplate'), (Get-SafeFlyCfg 'teamRiskJustificationTemplate'))) {
        if ($t.Contains("{$Name}")) { return $true }
    }
    return $false
}
# {releaseNumber}: release name without the releaseNaming prefix (BCM2610_2 -> 2610_2); else yyMM.
$releaseNumber = $monthDate.ToString("yyMM")
$namingPrefix = if ($cfg.PSObject.Properties['releaseNaming'] -and $cfg.releaseNaming -and $cfg.releaseNaming.PSObject.Properties['prefix']) { "$($cfg.releaseNaming.prefix)" } else { '' }
if ($namingPrefix -and $ReleaseId.StartsWith($namingPrefix, [StringComparison]::OrdinalIgnoreCase) -and $ReleaseId.Length -gt $namingPrefix.Length) {
    $releaseNumber = $ReleaseId.Substring($namingPrefix.Length)
}
# {titleThemes} (plain text in the title)
$titleThemesText = "$TitleThemes".Trim()
if ([string]::IsNullOrWhiteSpace($titleThemesText) -and (Test-SafeFlyTemplateToken 'titleThemes')) { $titleThemesText = Get-SafeFlyText '' 'titleThemes' }
# {payloadUrl}: build-health Payload view previous build -> this build (13.12038 "For more details, view the Payload")
$payloadUrl = ''
$payloadTpl = Get-SafeFlyCfg 'payloadUrlTemplate'
if ($payloadTpl -and (Test-SafeFlyTemplateToken 'payloadUrl')) {
    if ([string]::IsNullOrWhiteSpace($PreviousBuildId)) { $payloadUrl = Get-SafeFlyText '' 'previousBuildId' }
    else { $payloadUrl = $payloadTpl.Replace('{buildId}', "$BuildId").Replace('{previousBuildId}', "$PreviousBuildId") }
}
$tokens = [ordered]@{
    '{serviceName}'        = "$($cfg.service.name)"
    '{serviceDisplayName}' = "$($cfg.service.displayName)"
    '{releaseName}'        = $ReleaseId
    '{releaseId}'          = $ReleaseId
    '{releaseNumber}'      = $releaseNumber
    '{titleThemes}'        = $titleThemesText
    '{month}'              = $monthName
    '{yy}'                 = $shortYear
    '{buildNumber}'        = $BuildNumber
    '{buildId}'            = $BuildId
    '{commitExcelUrl}'     = $CommitExcelUrl
}
function Expand-SafeFlyTemplate([string]$Template) {
    $s = "$Template"
    foreach ($k in $tokens.Keys) { $s = $s.Replace($k, "$($tokens[$k])") }   # literal, no regex
    return $s
}
$title = Expand-SafeFlyTemplate $cfg.safefly.titleTemplate

function ConvertTo-SafeFlyChangeSections([object[]]$Items) {
    # 13.12038 structure: <h4>Section</h4><ul><li>sentence <a href="link">id</a></li>...</ul>
    $order = if ($cfg.safefly.PSObject.Properties['descriptionSections']) { @($cfg.safefly.descriptionSections | ForEach-Object { "$_" }) } else { @() }
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $bySection = [ordered]@{}
    foreach ($it in @($Items | Where-Object { $_ })) {
        $get = { param($n) if ($it -is [System.Collections.IDictionary]) { $it[$n] } elseif ($it.PSObject.Properties[$n]) { $it.$n } else { $null } }
        $sec  = "$(& $get 'section')".Trim()
        $text = "$(& $get 'text')".Trim()
        if (-not $sec -or -not $text) { throw "SafeFly V2: every -ChangeSections item needs 'section' and 'text' (got section='$sec')." }
        $matchSec = if ($order.Count) { @($order | Where-Object { $_ -ieq $sec }) | Select-Object -First 1 } else { $sec }
        if (-not $matchSec) { throw "SafeFly V2: -ChangeSections section '$sec' is not in safefly.descriptionSections ($($order -join ', '))." }
        $url = "$(& $get 'url')"; $label = "$(& $get 'label')"
        $pr = "$(& $get 'pr')"; $wi = "$(& $get 'workItem')"
        if (-not $url -and $pr) { $url = (Get-SafeFlyCfg 'prUrlTemplate').Replace('{id}', $pr); if (-not $label) { $label = $pr } }
        if (-not $url -and $wi) { $url = (Get-SafeFlyCfg 'workItemUrlTemplate').Replace('{id}', $wi); if (-not $label) { $label = $wi } }
        if (($pr -or $wi) -and -not $url.StartsWith('https://')) { throw "SafeFly V2: -ChangeSections item '$text' has a pr/workItem but safefly.prUrlTemplate / workItemUrlTemplate is not configured." }
        $li = & $enc $text
        if ($url) { $li += " <a href=`"$(& $enc $url)`">$(& $enc ($(if ($label) { $label } else { $url })))</a>" }
        if (-not $bySection.Contains($matchSec)) { $bySection[$matchSec] = [System.Collections.Generic.List[string]]::new() }
        $bySection[$matchSec].Add("<li>$li</li>")
    }
    $keys = if ($order.Count) { @($order | Where-Object { $bySection.Contains($_) }) } else { @($bySection.Keys) }
    return (($keys | ForEach-Object { "<h4>$(& $enc $_)</h4><ul>$($bySection[$_] -join '')</ul>" }) -join '')
}

$descTpl = if ($cfg.safefly.PSObject.Properties['descriptionTemplate'] -and -not [string]::IsNullOrWhiteSpace("$($cfg.safefly.descriptionTemplate)")) { "$($cfg.safefly.descriptionTemplate)" } else { "Monthly release {releaseId} for {serviceName}" }
# Description-only tokens are HTML (sections) or HTML-encoded (URLs / sheet name) before the generic expansion.
$descWork = $descTpl
if ($descWork.Contains('{changeSections}')) {
    $sectionsHtml = ConvertTo-SafeFlyChangeSections $ChangeSections
    $descWork = $descWork.Replace('{changeSections}', (Get-SafeFlyText $sectionsHtml 'changeSections'))
}
if ($descWork.Contains('{payloadUrl}')) { $descWork = $descWork.Replace('{payloadUrl}', [System.Net.WebUtility]::HtmlEncode($payloadUrl)) }
if ($descWork.Contains('{commitExcelSheet}')) {
    # ZED convention: the tracker sheet is named after the release (sheetNameTemplate {{releaseName}}).
    if ([string]::IsNullOrWhiteSpace($CommitExcelSheet) -and $cfg.PSObject.Properties['commitExcel'] -and $cfg.commitExcel -and
        "$($cfg.commitExcel.mode)" -eq 'tracker' -and -not [string]::IsNullOrWhiteSpace("$($cfg.commitExcel.sheetNameTemplate)")) {
        . (Join-Path $PSScriptRoot '..\lib\ReleaseNameLib.ps1')
        $CommitExcelSheet = Expand-ReleaseTokens "$($cfg.commitExcel.sheetNameTemplate)" $ReleaseId $null
    }
    $descWork = $descWork.Replace('{commitExcelSheet}', [System.Net.WebUtility]::HtmlEncode((Get-SafeFlyText "$CommitExcelSheet".Trim() 'commitExcelSheet')))
}
if ($descWork.Contains('{commitExcelUrl}')) {
    $descWork = $descWork.Replace('{commitExcelUrl}', [System.Net.WebUtility]::HtmlEncode((Get-SafeFlyText "$CommitExcelUrl".Trim() 'commitExcelUrl')))
}
$description = Expand-SafeFlyTemplate $descWork
if ($descTpl.Contains('{changeSummary}')) {
    $lines = @($ChangeSummary | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.Net.WebUtility]::HtmlEncode("$_".Trim()) })
    $description = $description.Replace('{changeSummary}', (Get-SafeFlyText ($lines -join '<br>') 'changeSummary'))
}
if ($CommitExcelUrl -and -not $descTpl.Contains('{commitExcelUrl}')) {
    $enc = [System.Net.WebUtility]::HtmlEncode($CommitExcelUrl)
    $description += "<p>Commit analysis: <a href=`"$enc`">$enc</a></p>"
}

# core.team_risk.justification (optional question, but it is what R2D reviewers judge)
$teamRiskJustification = $null
if ($cfg.safefly.PSObject.Properties['teamRiskJustificationTemplate'] -and -not [string]::IsNullOrWhiteSpace("$($cfg.safefly.teamRiskJustificationTemplate)")) {
    $jTpl = "$($cfg.safefly.teamRiskJustificationTemplate)"
    $teamRiskJustification = Expand-SafeFlyTemplate $jTpl
    if ($jTpl.Contains('{validationSummary}')) {
        $teamRiskJustification = $teamRiskJustification.Replace('{validationSummary}', (Get-SafeFlyText $ValidationSummary.Trim() 'validationSummary'))
    }
}
if ($contentWarnings.Count -gt 0 -and -not $DryRun) {
    throw "SafeFly V2 CONTENT MISSING: $($contentWarnings -join '; '). R2D reviewers judge the change summary and validation/monitoring evidence (13.14103 was rejected without it) — supply them before filing."
}

# --- Resolve SafeFly service group ---
$serviceGroupName = $cfg.safefly.serviceGroupName
if ([string]::IsNullOrWhiteSpace($serviceGroupName)) {
    throw "safefly.serviceGroupName is missing from service-config.json. It is the EV2 service group (e.g. 'Backup (MAB)'). ZED must not assume a service group."
}

# --- Regions ---
# No hard-coded region filter: the valid set is SafeFly V2's live list
# (getRegionsWithActiveCCOACoverage, see Build-SafeFlyRegionMap). Targeted regions
# (ASC minus CCOA exclusions, computed by the caller) that are not in the live
# list go to core.other_regions instead of being dropped.
$filteredRegions = @($TargetedRegions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
# safefly.regionGroups: core.regions = every region in the named SafeFly region groups (the
# clouds the production pipeline deploys to — 13.14103 convention: United States, Europe,
# Asia Pacific, Americas (Excl. US), Middle East & Africa, Fairfax, Mooncake) minus CCOA
# exclusions. Replaces -TargetedRegions (ASC -AllClouds also returns USNat/USSec).
$regionGroupNames = if ($cfg.safefly.PSObject.Properties['regionGroups']) { @($cfg.safefly.regionGroups | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { "$_" }) } else { @() }
$regionSource = if ($regionGroupNames.Count -gt 0) { 'regionGroups' } else { 'targetedRegions' }
if ($regionSource -eq 'targetedRegions' -and $filteredRegions.Count -eq 0) {
    throw "SafeFly V2: no regions — pass -TargetedRegions or configure safefly.regionGroups in service-config.json."
}
$excludedRegionsApplied = [System.Collections.Generic.List[string]]::new()

# --- Rollback strategy ---
if ([string]::IsNullOrWhiteSpace($RollbackStrategy)) {
    $RollbackStrategy = if ($cfg.safefly.PSObject.Properties['rollbackStrategy'] -and -not [string]::IsNullOrWhiteSpace("$($cfg.safefly.rollbackStrategy)")) {
        "$($cfg.safefly.rollbackStrategy)"
    } else { 'DRI determines rollback or rollforward in real time based on the issue' }
}

# --- SDP mapping ---
$sdpMapping = @{
    'Standard SDP'     = 'Standard SDP (Normal Rollout)'
    'Conservative SDP' = 'Conservative SDP'
}
$sdpV2Value = if ($sdpMapping.ContainsKey($SDPType)) { $sdpMapping[$SDPType] } else { $SDPType }

# =============================================================================
# HELPERS
# =============================================================================

function Get-QuestionByName {
    param($questions, $name)
    return @($questions | Where-Object { $_.name -eq $name }) | Select-Object -First 1
}

function Get-OptionValue {
    param($question, $value)
    if (-not $question -or -not $question.options) { return $null }
    return @($question.options | Where-Object { $_.label -eq $value -or $_.value -eq $value }) | Select-Object -First 1
}

function Assert-OptionValid {
    param($question, $value)
    if (-not $question -or -not $question.options -or @($question.options).Count -eq 0) { return }
    $match = Get-OptionValue $question $value
    if (-not $match) {
        $valid = (@($question.options) | ForEach-Object { $_.label }) -join '", "'
        throw "SafeFly V2: invalid option value '$value' for question '$($question.name)' ('$($question.label)'). Valid values: `"$valid`""
    }
}

function Test-ConditionValue {
    # One V2 condition against the current answer. Multi-select answers are arrays:
    # positive operators match when ANY selected value matches; NotEqualTo/NotIn when NONE does.
    param($currentVal, [string]$compOp, $compVal)
    $vals = @($currentVal | ForEach-Object { "$_" })
    $list = @($compVal -split ',\s*')
    switch ($compOp) {
        'EqualTo'     { return [bool](@($vals | Where-Object { $_ -eq $compVal }).Count) }
        'Equals'      { return [bool](@($vals | Where-Object { $_ -eq $compVal }).Count) }
        'NotEqualTo'  { return -not [bool](@($vals | Where-Object { $_ -eq $compVal }).Count) }
        'Contains'    { return [bool](@($vals | Where-Object { $_ -like "*$compVal*" }).Count) }
        'ContainsAny' { return [bool](@($vals | Where-Object { $list -contains $_ }).Count) }
        'In'          { return [bool](@($vals | Where-Object { $list -contains $_ }).Count) }
        'NotIn'       { return -not [bool](@($vals | Where-Object { $list -contains $_ }).Count) }
        default       { return $true }  # Unknown operator: do not gate
    }
}

function Test-ConditionalRule {
    param($rule, [hashtable]$currentAnswersByName)
    # No rule: unconditionally required when isRequired=true
    if ($null -eq $rule) { return $true }

    # V2 format: rule is a PSCustomObject with { conditions[], operator, actionSet { require } }
    if ($rule -isnot [string] -and $rule.PSObject.Properties['conditions']) {
        # actionSet.require must be true for this rule to gate the question as required
        $shouldRequire = $rule.PSObject.Properties['actionSet'] -and
                         $rule.actionSet -and
                         $rule.actionSet.PSObject.Properties['require'] -and
                         [bool]$rule.actionSet.require
        if (-not $shouldRequire) { return $true }  # Rule does not add a required constraint

        $conditions = @($rule.conditions)
        if ($conditions.Count -eq 0) { return $true }

        $results = @()
        foreach ($cond in $conditions) {
            $triggerName = $cond.triggerQuestionName
            $compOp      = $cond.comparisonOperator
            $compVal     = $cond.comparisonValue

            $currentVal = $currentAnswersByName[$triggerName]
            if ($null -eq $currentVal) {
                # Trigger question not answered: condition not satisfied (transitive gating)
                $results += $false
                continue
            }
            $condResult = Test-ConditionValue $currentVal $compOp $compVal
            $results += $condResult
        }

        $op = if ($rule.PSObject.Properties['operator'] -and $rule.operator) { $rule.operator } else { 'AND' }
        return $(switch ($op) {
            'OR'  { $results -contains $true }
            'AND' { $results -notcontains $false }
            default { $results -notcontains $false }
        })
    }

    # V1 / legacy format: rule is a JSON string with { questionName, operator, value, values[] }
    $ruleObj = $rule
    if ($rule -is [string]) {
        if ([string]::IsNullOrWhiteSpace($rule)) { return $true }
        try { $ruleObj = $rule | ConvertFrom-Json -ErrorAction Stop }
        catch { return $true }
    }
    $questionName = $ruleObj.questionName
    $operator     = $ruleObj.operator
    $ruleValue    = $ruleObj.value
    $ruleValues   = if ($ruleObj.PSObject.Properties['values']) { @($ruleObj.values) } else { @() }
    if ([string]::IsNullOrWhiteSpace($questionName)) { return $true }
    $currentVal = $currentAnswersByName[$questionName]
    if ($null -eq $currentVal) { return $true }
    switch ($operator) {
        'EqualTo'       { return ($currentVal -eq $ruleValue) }
        'Equals'        { return ($currentVal -eq $ruleValue) }
        'NotEqualTo'    { return ($currentVal -ne $ruleValue) }
        'In'            { return ($ruleValues -contains $currentVal) }
        'ContainsAnyOf' { return ($ruleValues -contains $currentVal) }
        'NotIn'         { return ($ruleValues -notcontains $currentVal) }
        default         { return $true }
    }
}

function Build-SafeFlyRegionMap {
    param($ServiceConfigPath)
    # Calls the dynamic data source for core.regions: getRegionsWithActiveCCOACoverage.
    # Returns a hashtable: normalized-display-name (no spaces, lowercase) → SafeFly CamelCase identifier.
    $regionQuery = 'query { getRegionsWithActiveCCOACoverage { regions } }'
    $regionData  = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') `
        -Query $regionQuery -ServiceConfigPath $ServiceConfigPath
    $map = @{}
    foreach ($r in $regionData.getRegionsWithActiveCCOACoverage.regions) {
        $key = ($r -replace '\s+', '').ToLower()
        $map[$key] = $r
    }
    return $map
}

function Resolve-RegionToSafeFlyId {
    param([string]$displayName, [hashtable]$regionMap)
    # Normalize input: strip spaces, lowercase, then look up in the SafeFly region map.
    $key = ($displayName -replace '\s+', '').ToLower()
    return $regionMap[$key]   # Returns $null if not found
}

function Resolve-SafeFlyTagIds {
    # SaveRequestRequestBaseInput.tagIds is [Guid] — config holds tag NAMES (or GUIDs).
    # Names are looked up with tags(name:) (server does a case-insensitive contains match,
    # so keep only the exact case-insensitive name). A tag that does not exist in V2 is
    # skipped with a warning — never sent as a name (SafeFly would reject the request).
    param([string[]]$TagNames, [string]$ServiceConfigPath)
    $ids = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($TagNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ("$name" -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            if (-not $ids.Contains("$name")) { $ids.Add("$name") }
            continue
        }
        $found = $null
        try {
            $tagData = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') `
                -Query 'query GetTags($name: String) { tags(name: $name) { id name } }' `
                -Variables @{ name = "$name" } -ServiceConfigPath $ServiceConfigPath
            $found = @($tagData.tags | Where-Object { "$($_.name)" -ieq "$name" }) | Select-Object -First 1
        } catch {
            $warnings.Add("tag '$name' lookup failed ($($_.Exception.Message)) - not sent")
            continue
        }
        if ($found -and $found.id) {
            if (-not $ids.Contains("$($found.id)")) { $ids.Add("$($found.id)") }
        } else {
            $warnings.Add("tag '$name' does not exist in SafeFly V2 - not sent")
        }
    }
    foreach ($w in $warnings) { Write-Warning "  [SafeFly] $w" }
    return [pscustomobject]@{ ids = @($ids); warnings = @($warnings) }
}


function Resolve-EffectiveRequired {
    param($questions, [hashtable]$currentAnswersByName)
    # Return every isRequired question whose conditionalRule is satisfied with the current answers.
    # Transitive gating is handled automatically: if a trigger question was never answered
    # (because it was itself gated out), its value is $null, making dependent conditions false.
    $effective = @()
    foreach ($q in $questions) {
        if (-not $q.isRequired) { continue }
        if (-not (Test-ConditionalRule $q.conditionalRule $currentAnswersByName)) { continue }
        $effective += $q
    }
    return $effective
}

# =============================================================================
# STEP 1 — Fetch live form
# =============================================================================

Write-Host "  [SafeFly] Fetching V2 form for change type '$($cfg.safefly.changeTypeName)'..." -ForegroundColor Gray
$formResult = & (Join-Path $PSScriptRoot 'Get-SafeFlyForm.ps1') -ServiceConfigPath $ServiceConfigPath
$questions  = $formResult.questions
Write-Host "  [SafeFly] Form $($formResult.formId): $(@($questions).Count) question(s)" -ForegroundColor Gray
# Question ids come from the live active form; the payload's formId comes from config.
# A rotated form would pair one form's question ids with another form's id — fail closed.
if ($formResult.formId -and "$($formResult.formId)" -ne "$formId") {
    throw "SafeFly V2 FORM MISMATCH: service-config safefly.formId '$formId' is not the active form '$($formResult.formId)' for change type '$changeTypeId'. Update safefly.formId (setup-service group 6) before filing."
}

# =============================================================================
# STEP 2 — Build answers
# =============================================================================
$currentAnswersByName = @{ 'core.orchestrator_name' = 'EV2' }
$answers = [System.Collections.Generic.List[object]]::new()

function Add-Answer {
    param($q, $value)
    if ($null -eq $q) { return }
    # Generic encoder: for option-based questions, use the option's .value (not the display label).
    # SafeFly stores and validates the option value field, not the label.
    # e.g. ccoa.is_ccoa_request label="No" → value="False"; we must send "False".
    # Multi-select questions (isMultiSelect = true: core.regions, ev2.servicegroup, …) are
    # stored by SafeFly as a JSON array string, e.g. ["EastAsia","WestUS2"] — the same shape
    # the UI and REST clients write (see 13.14983). Never comma-join them.
    $isMulti = $q.PSObject.Properties['isMultiSelect'] -and $q.isMultiSelect -eq $true
    $items = foreach ($v in @($value)) {
        $resolved = "$v"
        if ($q.options -and @($q.options).Count -gt 0) {
            $opt = @($q.options | Where-Object { $_.label -eq $v -or $_.value -eq $v }) | Select-Object -First 1
            if ($opt) { $resolved = "$($opt.value)" }
        }
        $resolved
    }
    $items = @($items)
    if ($isMulti) {
        $resolvedValue = ConvertTo-Json -InputObject ([string[]]$items) -Compress
        $currentAnswersByName[$q.name] = $items
    } else {
        $resolvedValue = $items -join ','
        $currentAnswersByName[$q.name] = $resolvedValue
    }
    $answers.Add([pscustomobject]@{
        id         = [System.Guid]::NewGuid().ToString()
        questionId = $q.id
        value      = $resolvedValue
    }) | Out-Null
}

# Orchestrator
$qOrch = Get-QuestionByName $questions 'core.orchestrator_name'
Assert-OptionValid $qOrch 'EV2'
Add-Answer $qOrch 'EV2'

# SDP
$qSdp = Get-QuestionByName $questions 'core.sdp'
Assert-OptionValid $qSdp $sdpV2Value
Add-Answer $qSdp $sdpV2Value

# Rollback (service-config safefly.rollbackStrategy or -RollbackStrategy; BCM: "Manual (TSG)")
$qRollback  = Get-QuestionByName $questions 'core.rollback_strategy'
Assert-OptionValid $qRollback $RollbackStrategy
Add-Answer $qRollback $RollbackStrategy

# Team-assessed risk (optional question; -TeamAssessedRisk, default Low)
$qTeamRisk = Get-QuestionByName $questions 'core.team_assessed_risk'
if ($qTeamRisk -and -not [string]::IsNullOrWhiteSpace($TeamAssessedRisk)) {
    Assert-OptionValid $qTeamRisk $TeamAssessedRisk
    Add-Answer $qTeamRisk $TeamAssessedRisk
}

# Team-assessed risk justification (safefly.teamRiskJustificationTemplate)
$qTeamRiskJust = Get-QuestionByName $questions 'core.team_risk.justification'
if ($qTeamRiskJust -and -not [string]::IsNullOrWhiteSpace($teamRiskJustification)) {
    Add-Answer $qTeamRiskJust $teamRiskJustification
}

# Health monitoring — always Yes for a production service with health signals
$qHealthMon = Get-QuestionByName $questions 'core.health_monitoring'
if ($qHealthMon) {
    Assert-OptionValid $qHealthMon 'Yes'
    Add-Answer $qHealthMon 'Yes'
}

# EV2 service group
$qSvcGroup = Get-QuestionByName $questions 'ev2.servicegroup'
Add-Answer $qSvcGroup $serviceGroupName

# Build
$qBuild = Get-QuestionByName $questions 'ev2.build'
Add-Answer $qBuild $BuildNumber

# ADO build link: 'Applicable' + ado.build = -AdoBuildUrl when given, else 'Not Applicable'.
$qAdoBuildNa = Get-QuestionByName $questions 'ado.build_na'
$qAdoBuild   = Get-QuestionByName $questions 'ado.build'
if (-not [string]::IsNullOrWhiteSpace($AdoBuildUrl)) {
    if ($AdoBuildUrl -notmatch '^https://') { throw "SafeFly V2: -AdoBuildUrl must be an https URL (got '$AdoBuildUrl')." }
    if ($qAdoBuildNa) {
        Assert-OptionValid $qAdoBuildNa 'Applicable'
        Add-Answer $qAdoBuildNa 'Applicable'
    }
    if (-not $qAdoBuild) { throw "SafeFly V2: -AdoBuildUrl was given but the active form has no 'ado.build' question." }
    Add-Answer $qAdoBuild $AdoBuildUrl
} elseif ($qAdoBuildNa) {
    Assert-OptionValid $qAdoBuildNa 'Not Applicable'
    Add-Answer $qAdoBuildNa 'Not Applicable'
}

# Regions — core.regions is a dynamic-source CheckboxGroup (isMultiSelect=true, allowManualEntry=false).
# Its valid values come from getRegionsWithActiveCCOACoverage (CamelCase identifiers: "EastAsia",
# "WestUS2", etc.) — NOT Azure display names. The static options list is always empty for this question.
# Add-Answer encodes the multi-select answer as a JSON array (["EastAsia","WestUS2"]).
$qRegions      = Get-QuestionByName $questions 'core.regions'
$qOtherRegions = Get-QuestionByName $questions 'core.other_regions'
$matchedSafeFlyIds = [System.Collections.Generic.List[string]]::new()
$unmatchedRegions  = [System.Collections.Generic.List[string]]::new()
if ($qRegions) {
    $regionMap = Build-SafeFlyRegionMap -ServiceConfigPath $ServiceConfigPath

    if ($regionSource -eq 'regionGroups') {
        $grpData = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') `
            -Query 'query { regionGroups { name regions { regionName } } }' -ServiceConfigPath $ServiceConfigPath
        $groups  = @($grpData.regionGroups)
        $unknown = @($regionGroupNames | Where-Object { $n = $_; -not @($groups | Where-Object { "$($_.name)" -ieq $n }).Count })
        if ($unknown.Count -gt 0) {
            throw "SafeFly V2: safefly.regionGroups has unknown group(s): $($unknown -join ', '). SafeFly groups: $((@($groups.name)) -join ', ')"
        }
        $excludedKeys = @($ExcludedRegions | Where-Object { $_ } | ForEach-Object { ("$_" -replace '\s+', '').ToLower() })
        $fromGroups = [System.Collections.Generic.List[string]]::new()
        foreach ($g in @($groups | Where-Object { $gn = "$($_.name)"; @($regionGroupNames | Where-Object { $_ -ieq $gn }).Count })) {
            foreach ($r in @($g.regions)) {
                $rn = "$($r.regionName)"
                if ([string]::IsNullOrWhiteSpace($rn) -or $fromGroups.Contains($rn)) { continue }
                if ($excludedKeys -contains ($rn -replace '\s+', '').ToLower()) { $excludedRegionsApplied.Add($rn); continue }
                $fromGroups.Add($rn)
            }
        }
        $filteredRegions = @($fromGroups)
    }

    foreach ($region in $filteredRegions) {
        $sfId = Resolve-RegionToSafeFlyId -displayName $region -regionMap $regionMap
        if ($sfId) {
            if (-not $matchedSafeFlyIds.Contains($sfId)) { $matchedSafeFlyIds.Add($sfId) }
        } else {
            $unmatchedRegions.Add($region)
        }
    }

    if ($matchedSafeFlyIds.Count -gt 0) {
        Add-Answer $qRegions @($matchedSafeFlyIds)
    } else {
        Write-Warning "  [SafeFly] None of the $($filteredRegions.Count) input region(s) matched SafeFly's dynamic list. All sent to core.other_regions."
    }
    if ($unmatchedRegions.Count -gt 0) {
        Write-Warning "  [SafeFly] $($unmatchedRegions.Count) targeted region(s) not in SafeFly's live region list: $($unmatchedRegions -join ', ')"
        if ($qOtherRegions) { Add-Answer $qOtherRegions ($unmatchedRegions -join ', ') }
    }
}

# CCOA
$qIsCcoa = Get-QuestionByName $questions 'ccoa.is_ccoa_request'
if ($qIsCcoa) {
    Assert-OptionValid $qIsCcoa 'No'
    Add-Answer $qIsCcoa 'No'
}

# Timing
$qStart = Get-QuestionByName $questions 'core.anticipated_start_time'
if ($qStart) { Add-Answer $qStart $startIso }
$qEnd = Get-QuestionByName $questions 'core.anticipated_end_time'
if ($qEnd) { Add-Answer $qEnd $endIso }

# =============================================================================
# STEP 3 — Fail closed on effective required
# =============================================================================
$effectiveRequired = Resolve-EffectiveRequired $questions $currentAnswersByName
$answeredIds = @($answers | ForEach-Object { $_.questionId })
$missing = @($effectiveRequired | Where-Object { $answeredIds -notcontains $_.id })
if ($missing.Count -gt 0) {
    $missingList = ($missing | ForEach-Object { "  '$($_.name)' ($($_.label))" }) -join "`n"
    throw "SafeFly V2 FAIL-CLOSED: $($missing.Count) effective-required question(s) have no answer.`n$missingList`nAdd mappings for these questions before submitting."
}

# =============================================================================
# STEP 4 — Assemble SaveRequestRequestBaseInput (14 fields)
# =============================================================================
# NOTE: requestId is deliberately NOT client-generated. SafeFly V2 assigns it on
# saveRequest; sending our own GUID fails with "The BaseRequest with id ... was not
# found." It is populated from the draft before submitRequest (see phase 2 below).
$requestId = $null

# Answer ordering: no special ordering needed. SafeFly does NOT enforce cross-question
# ordering when the answer values are correct (empirically confirmed: ccoa-before-regions
# succeeds with valid CamelCase region identifiers). The D4 "hoist" for orch/regions/ccoa
# was a cargo-cult workaround — the real root cause was wrong value format (display names
# instead of SafeFly CamelCase identifiers). Removed to avoid confusion.
$orderedAnswers = @($answers)
$tagNames      = if ($cfg.safefly.PSObject.Properties['tags']) { @($cfg.safefly.tags) } else { @() }
$tagResolution = Resolve-SafeFlyTagIds -TagNames $tagNames -ServiceConfigPath $ServiceConfigPath
$tagsVal       = @($tagResolution.ids)

$changeRequest = [ordered]@{
    changeTitle             = $title
    changeDescription       = $description
    franchiseId             = $franchiseId
    changeTypeId            = $changeTypeId
    serviceId               = $v2ServiceId
    formId                  = $formId
    requestType             = 'CHANGE'
    answers                 = @($orderedAnswers)
    tagIds                  = $tagsVal
    shouldSuppressIcmErrors = $false
    requestExceptions       = @()
    owner                   = "$ReleaseOwnerAlias@microsoft.com"
    ownerAssignmentNotes    = "ZED automated release $ReleaseId — $ReleaseOwnerAlias"
}

$payloadJson = $changeRequest | ConvertTo-Json -Depth 15
Write-Host "  [SafeFly] V2 payload assembled: $(@($answers).Count) answer(s), $($missing.Count) missing-required (requestId assigned by SafeFly on save)" -ForegroundColor Gray
Write-Host "  [SafeFly] Effective-required set: $(@($effectiveRequired).Count) question(s) (EV2 partition)" -ForegroundColor Gray

# =============================================================================
# DRY RUN
# =============================================================================
if ($DryRun) {
    Write-Host "=== DRY RUN — SafeFly V2 Payload ===" -ForegroundColor Cyan
    Write-Host "  Total questions in form: $(@($questions).Count)" -ForegroundColor DarkGray
    Write-Host "  Effective-required (EV2): $(@($effectiveRequired).Count)" -ForegroundColor DarkGray
    Write-Host "  Answers assembled: $(@($answers).Count)" -ForegroundColor DarkGray
    Write-Output $payloadJson
    return [PSCustomObject]@{
        safeFlyId              = "dry-run"
        safeFlyRequestNumber   = 0
        safeFlyUrl             = "N/A"
        requestStatus          = "DryRun"
        requestId              = $requestId
        payload                = $payloadJson
        effectiveRequiredCount = @($effectiveRequired).Count
        totalFormQuestions     = @($questions).Count
        regionsSubmitted       = $matchedSafeFlyIds.Count
        regionsUnmatched       = @($unmatchedRegions)
        regionSource           = $regionSource
        regionsExcluded        = @($excludedRegionsApplied)
        title                  = $title
        description            = $description
        teamRiskJustification  = $teamRiskJustification
        contentWarnings        = @($contentWarnings)
        tagIds                 = @($tagsVal)
        tagWarnings            = @($tagResolution.warnings)
    }
}

# =============================================================================
# SUBMIT (non-DryRun only)
#
# Two-phase. submitRequest requires the BaseRequest to already exist — calling it
# with a client-generated requestId fails with "The BaseRequest with id ... was not
# found." So: saveRequest creates the draft, then submitRequest promotes it.
# =============================================================================
Write-Host "  [SafeFly] Phase 1/2: creating draft via saveRequest..." -ForegroundColor Gray

$saveMutation = @'
mutation SaveRequest($changeRequest: SaveRequestRequestBaseInput!) {
  saveRequest(changeRequest: $changeRequest) {
    id
    displayId
    displayStatus
    status
    requestUrl
  }
}
'@

$saveData = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') `
    -Query $saveMutation -Variables @{ changeRequest = $changeRequest } -ServiceConfigPath $ServiceConfigPath

$draft = $saveData.saveRequest
if (-not $draft -or [string]::IsNullOrWhiteSpace("$($draft.id)")) {
    throw "SafeFly V2: saveRequest returned no request id — cannot submit."
}
Write-Host "  [SafeFly] Draft created: $($draft.displayId) (id=$($draft.id))" -ForegroundColor Gray

# Re-key the payload to the server-assigned id before promoting the draft.
$changeRequest.requestId = $draft.id

Write-Host "  [SafeFly] Phase 2/2: submitting via submitRequest..." -ForegroundColor Gray

$mutation = @'
mutation SubmitRequest($changeRequest: SaveRequestRequestBaseInput!) {
  submitRequest(changeRequest: $changeRequest) {
    id
    displayId
    displayStatus
    status
    requestUrl
  }
}
'@

$variables = @{ changeRequest = $changeRequest }
$data = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') `
    -Query $mutation -Variables $variables -ServiceConfigPath $ServiceConfigPath

$resp   = $data.submitRequest
$result = [PSCustomObject]@{
    safeFlyId            = $resp.id
    safeFlyRequestNumber = $resp.displayId
    safeFlyUrl           = $resp.requestUrl
    requestStatus        = $resp.status
    displayStatus        = $resp.displayStatus
    regionsSubmitted     = $matchedSafeFlyIds.Count
    regionsUnmatched     = @($unmatchedRegions)
    tagIds               = @($tagsVal)
    tagWarnings          = @($tagResolution.warnings)
}
Write-Host "✅ SafeFly V2 R2D request #$($result.safeFlyRequestNumber) created" -ForegroundColor Green
Write-Host "   URL: $($result.safeFlyUrl)" -ForegroundColor Gray
return $result
