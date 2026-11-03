<#
.SYNOPSIS
    Resolves recipients for a notification event by applying the canonical Notification Routing rules.

.DESCRIPTION
    Single source of truth for "who gets which email/Teams message" across the agent.

    Model: every notification belongs to a (step, outcome) pair.
      Outcomes: success | failure | halt   (halt covers both unexpected halts and waiting-approval gates).
    Routing lives in notifications.routing.<stepKey>.<outcome> in service-config.json.

    Resolution order:
      1. Test mode (release.testMode == true) → owner-only, Teams suppressed.
      2. Map EventKey -> (stepKey, outcome). If unmapped (judgment, failure, halt,
         step-transition, or any unrecognized key) -> owner-only.
      3. Lookup notifications.routing.<stepKey>.<outcome>. Resolve emailGroups /
         ccGroups / teamsGroups against notifications.groups.
      4. ALWAYS add the release owner's personal email to the To-line.
         (No includeOwner field — owner is implicit on every notification.)
      5. Missing entry / empty buckets -> owner-only (the default everywhere).

    EventKey -> (step, outcome) map:
      step-<N>-completed         -> (<N>, success)
      step-<N>-skipped           -> (<N>, success)
      step-<N>-failed            -> (<N>, failure)
      step-<N>-waiting-approval  -> (<N>, halt)
      reminder                   -> (1,  success)
      ri-pr-raised               -> (2,  halt)     Step 2a RI PR opened, owner must merge
      fi-pr-raised               -> (2,  halt)     Step 2b FI PR opened, owner must merge
      private-stamp-input-needed -> (5,  halt)     upgrade test needs instance/ports/last build/queue name
      private-stamp-bvt-ready    -> (5,  halt)     both private stamp legs deployed, owner runs BVT
      private-stamp-failed       -> (5,  failure)  a private stamp leg failed to queue or deploy
      private-stamp-restored     -> (5,  success)  stamp redeployed without the queue override (restoreAfterSignOff)
      private-stamp-restore-failed -> (5, failure) a restore redeploy failed
      revert-bits-select         -> (7,  halt)     revert bits: owner picks the settings to keep
      revert-bits-pr-raised      -> (7,  halt)     revert bits PR opened, owner must merge
      revert-bits-bvt-ready      -> (7,  halt)     revert build ready, owner runs BVT
      revert-bits-ready          -> (7,  halt)     revert build ready during canary BVT (prepareDuringCanaryBvt)
      revert-bits-failed         -> (7,  failure)  revert bits PR abandoned / build failed / track error
      approval-needed / approval-reminder / approval-expiring -> ('approval-requests', halt)
      approval-failed            -> ('approval-requests', failure)   (Invoke-ApprovalWatch.ps1)
      commit-request             -> (4,  success)
      create-r2d                 -> (13, success)
      ev2-stage-progress         -> (15, success)
      ev2-promotion-reminder     -> (15, halt)
      release-health-go          -> ('release-health', success)
      release-health-hold / release-health-inconclusive -> ('release-health', halt)
      release-health-no-go       -> ('release-health', failure)
      release-health-early-warning -> ('release-health-tripwire', failure)
                                    (releaseHealth.mode = shadow -> owner-only for all release-health-* keys;
                                     release-health-interim is unmapped -> owner-only)
      anything else              -> unmapped -> owner-only

.PARAMETER EventKey
    Event key string. See DESCRIPTION for the mapping table.
    Unmapped or unrouted events default to owner-only (safe default).

.PARAMETER Config
    Loaded service config object (output of Load-ServiceConfig.ps1).

.PARAMETER Release
    Loaded release.json object (must contain releaseOwner.email and optional testMode).

.PARAMETER Secrets
    Loaded secrets.json object (optional — used to resolve Teams group conversation IDs
    via $Secrets.teamsChats.<chatName>).

.OUTPUTS
    Hashtable:
      EmailTo               = string[]  (To-line addresses; always includes owner)
      EmailCc               = string[]  (CC-line addresses)
      TeamsConversationIds  = string[]  (Teams conversation IDs to post to)
      TestMode              = bool      (true if testMode redirect was applied)
      Broadcast             = bool      (true if event resolved against routing block; false if owner-only short-circuit)

.EXAMPLE
    $r = & .\Resolve-NotificationRecipients.ps1 -EventKey 'reminder' -Config $cfg -Release $rel -Secrets $sec
    Send-MailMessage -To $r.EmailTo -Cc $r.EmailCc ...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$EventKey,

    [Parameter(Mandatory=$true)]
    $Config,

    [Parameter(Mandatory=$true)]
    $Release,

    [Parameter(Mandatory=$false)]
    $Secrets
)

$ErrorActionPreference = 'Stop'

# Step name lookup (matches keys in service-config.stepGates and routing).
$StepNames = @{
    1  = '1-send-reminder';            2  = '2-cut-branch';                3  = '3-wait-build'
    4  = '4-collect-commits';          5  = '5-deploy-canary';             6  = '6-bvt-check'
    7  = '7-rollback';                 8  = '8-post-rollback-bvt';         9  = '9-post-rollback-signoff'
    10 = '10-roll-forward';            11 = '11-post-rollforward-bvt';     12 = '12-post-rollforward-signoff'
    13 = '13-create-r2d';              14 = '14-crb-review';               15 = '15-production-rollout'
    16 = '16-merge-back'
}

# Legacy / semantic EventKey -> (step number, outcome) overrides.
$LegacyMap = @{
    'reminder'               = @{ Step = 1;  Outcome = 'success' }
    'ri-pr-raised'           = @{ Step = 2;  Outcome = 'halt'    }
    'fi-pr-raised'           = @{ Step = 2;  Outcome = 'halt'    }
    'private-stamp-input-needed' = @{ Step = 5; Outcome = 'halt'    }
    'private-stamp-bvt-ready'    = @{ Step = 5; Outcome = 'halt'    }
    'private-stamp-failed'       = @{ Step = 5; Outcome = 'failure' }
    'private-stamp-restored'     = @{ Step = 5; Outcome = 'success' }
    'private-stamp-restore-failed' = @{ Step = 5; Outcome = 'failure' }
    'revert-bits-select'         = @{ Step = 7; Outcome = 'halt'    }
    'revert-bits-pr-raised'      = @{ Step = 7; Outcome = 'halt'    }
    'revert-bits-bvt-ready'      = @{ Step = 7; Outcome = 'halt'    }
    'revert-bits-ready'          = @{ Step = 7; Outcome = 'halt'    }
    'revert-bits-failed'         = @{ Step = 7; Outcome = 'failure' }
    'commit-request'         = @{ Step = 4;  Outcome = 'success' }
    'create-r2d'             = @{ Step = 13; Outcome = 'success' }
    'ev2-stage-progress'     = @{ Step = 15; Outcome = 'success' }
    'ev2-promotion-reminder' = @{ Step = 15; Outcome = 'halt'    }
}

function _Map-EventKey {
    param([string]$key)
    # Release health (scripts/Health): verdicts -> 'release-health', early warnings -> 'release-health-tripwire'.
    switch ($key) {
        'release-health-go'            { return @{ StepKey = 'release-health'; Outcome = 'success' } }
        'release-health-hold'          { return @{ StepKey = 'release-health'; Outcome = 'halt' } }
        'release-health-inconclusive'  { return @{ StepKey = 'release-health'; Outcome = 'halt' } }
        'release-health-no-go'         { return @{ StepKey = 'release-health'; Outcome = 'failure' } }
        'release-health-early-warning' { return @{ StepKey = 'release-health-tripwire'; Outcome = 'failure' } }
    }
    # Approval requests (Invoke-ApprovalWatch.ps1) have their own routing row, independent of the
    # step that triggered the run: notifications.routing['approval-requests'].
    if ($key -match '^approval-(needed|reminder|expiring)$') { return @{ StepKey = 'approval-requests'; Outcome = 'halt' } }
    if ($key -eq 'approval-failed') { return @{ StepKey = 'approval-requests'; Outcome = 'failure' } }
    if ($key -match '^step-(\d+)-(completed|skipped|failed|waiting-approval)$') {
        $n = [int]$Matches[1]
        if (-not $StepNames.ContainsKey($n)) { return $null }
        $outcome = switch ($Matches[2]) {
            'completed'        { 'success' }
            'skipped'          { 'success' }
            'failed'           { 'failure' }
            'waiting-approval' { 'halt'    }
        }
        return @{ StepKey = $StepNames[$n]; Outcome = $outcome }
    }
    if ($LegacyMap.ContainsKey($key)) {
        $m = $LegacyMap[$key]
        return @{ StepKey = $StepNames[$m.Step]; Outcome = $m.Outcome }
    }
    return $null
}

# --- Extract owner email (required for every notification — owner is always on To-line) ---
$ownerEmail = $null
if ($Release.PSObject.Properties['releaseOwner'] -and $Release.releaseOwner) {
    if ($Release.releaseOwner.PSObject.Properties['email']) {
        $ownerEmail = [string]$Release.releaseOwner.email
    }
}

function _Require-Owner {
    param([string]$ctx)
    if ([string]::IsNullOrWhiteSpace($script:ownerEmail)) {
        throw "Resolve-NotificationRecipients: release.releaseOwner.email is missing or empty ($ctx). Cannot resolve recipients."
    }
}

# --- Test-mode override: collapse everything to owner-only, suppress Teams ---
$testMode = $false
if ($Release.PSObject.Properties['testMode']) {
    $testMode = [bool]$Release.testMode
}
if ($testMode) {
    _Require-Owner "test-mode override needs owner"
    return @{
        EmailTo              = @($ownerEmail)
        EmailCc              = @()
        TeamsConversationIds = @()
        TestMode             = $true
        Broadcast            = $false
    }
}

_Require-Owner "owner is always included on every notification"

# --- Release health in shadow mode: every health notification goes to the owner only ---
if ($EventKey -like 'release-health-*') {
    $rhMode = 'shadow'
    if ($Config.PSObject.Properties['releaseHealth'] -and $Config.releaseHealth -and $Config.releaseHealth.PSObject.Properties['mode'] -and $Config.releaseHealth.mode) {
        $rhMode = [string]$Config.releaseHealth.mode
    }
    if ($rhMode -eq 'shadow') {
        return @{
            EmailTo              = @($ownerEmail)
            EmailCc              = @()
            TeamsConversationIds = @()
            TestMode             = $false
            Broadcast            = $false
        }
    }
}

# --- Map EventKey to (stepKey, outcome). Unmapped -> owner-only fallback. ---
$mapped = _Map-EventKey $EventKey
if ($null -eq $mapped) {
    return @{
        EmailTo              = @($ownerEmail)
        EmailCc              = @()
        TeamsConversationIds = @()
        TestMode             = $false
        Broadcast            = $false
    }
}

# --- Routing lookup: missing step or missing outcome == owner-only default ---
$routing = $null
if ($Config.notifications -and $Config.notifications.PSObject.Properties['routing']) {
    $routing = $Config.notifications.routing
}
$rule = $null
if ($null -ne $routing -and $routing.PSObject.Properties[$mapped.StepKey]) {
    $stepBlock = $routing.($mapped.StepKey)
    if ($stepBlock -and $stepBlock.PSObject.Properties[$mapped.Outcome]) {
        $rule = $stepBlock.($mapped.Outcome)
    }
}
if ($null -eq $rule) {
    return @{
        EmailTo              = @($ownerEmail)
        EmailCc              = @()
        TeamsConversationIds = @()
        TestMode             = $false
        Broadcast            = $false
    }
}

$groups = $Config.notifications.groups

function _Resolve-EmailGroup($groupKey) {
    if (-not $groups.PSObject.Properties[$groupKey]) {
        throw "Resolve-NotificationRecipients: routing references group '$groupKey' which is not defined under notifications.groups."
    }
    $arr = $groups.$groupKey
    if ($null -eq $arr) { return @() }
    return @($arr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function _Resolve-TeamsGroup($groupKey) {
    if (-not $groups.PSObject.Properties[$groupKey]) {
        throw "Resolve-NotificationRecipients: routing references group '$groupKey' which is not defined under notifications.groups."
    }
    $chatNames = @($groups.$groupKey)
    if ($null -eq $Secrets -or $null -eq $Secrets.teamsChats) { return @() }
    $ids = @()
    foreach ($name in $chatNames) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($Secrets.teamsChats.PSObject.Properties[$name]) {
            $val = $Secrets.teamsChats.$name
            if ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) { $ids += $val }
            elseif ($val.PSObject.Properties['conversationId']) { $ids += [string]$val.conversationId }
        }
    }
    return $ids
}

# Resolve groups from the rule
$emailTo = @()
if ($rule.PSObject.Properties['emailGroups']) {
    foreach ($g in @($rule.emailGroups)) { $emailTo += _Resolve-EmailGroup $g }
}
$emailCc = @()
if ($rule.PSObject.Properties['ccGroups']) {
    foreach ($g in @($rule.ccGroups)) { $emailCc += _Resolve-EmailGroup $g }
}
$teamsIds = @()
if ($rule.PSObject.Properties['teamsGroups']) {
    foreach ($g in @($rule.teamsGroups)) { $teamsIds += _Resolve-TeamsGroup $g }
}

# Owner is always on the To-line.
if ($emailTo -notcontains $ownerEmail) { $emailTo += $ownerEmail }

return @{
    EmailTo              = @($emailTo | Select-Object -Unique)
    EmailCc              = @($emailCc | Select-Object -Unique)
    TeamsConversationIds = @($teamsIds | Select-Object -Unique)
    TestMode             = $false
    Broadcast            = ($emailTo.Count -gt 1 -or $emailCc.Count -gt 0 -or $teamsIds.Count -gt 0)
}
