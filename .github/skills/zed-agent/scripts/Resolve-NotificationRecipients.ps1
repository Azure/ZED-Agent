<#
.SYNOPSIS
    Resolves recipients for a notification event by applying the canonical Notification Routing rules.

.DESCRIPTION
    Single source of truth for "who gets which email/Teams message" across the agent.

    Resolution order:
      1. Test mode (release.testMode == true) → owner-only, Teams suppressed.
      2. Safety-rail events (always owner-only regardless of config):
           failure, halt, judgment, step-transition,
           and any 'step-<N>-failed' (failures never broadcast).
         These cannot be overridden by config — they protect against accidentally
         spamming the team during a bad deploy.
      3. Lookup notifications.routing.<EventKey>. If present, use it.
      4. Default (no routing entry): owner-only.

    OWNER-CONFIGURABLE events (any of these can be added to notifications.routing
    by the release owner via `setup-service group 5b`):
      reminder, commit-request, create-r2d, ev2-stage-progress,
      step-<N>-completed, step-<N>-skipped, step-<N>-waiting-approval (for N=1..16),
      canary-status, rollback-status, rollforward-status, production-rollout,
      and any other custom event key the service needs.

.PARAMETER EventKey
    Event key string. See DESCRIPTION above for the canonical set; any string is accepted.
    Unknown event keys with no routing entry default to owner-only (safe default).

.PARAMETER Config
    Loaded service config object (output of Load-ServiceConfig.ps1).

.PARAMETER Release
    Loaded release.json object (must contain releaseOwner.email and optional testMode).

.PARAMETER Secrets
    Loaded secrets.json object (optional — used to resolve Teams group conversation IDs
    via $Secrets.teamsChats.<chatName>).

.OUTPUTS
    Hashtable:
      EmailTo               = string[]  (To-line addresses)
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

# Safety-rail events — ALWAYS owner-only regardless of notifications.routing.
# These cover failures, halts, agent-judgment updates, and the generic step-transition
# marker. Step-failure transitions (e.g., 'step-3-failed') are also force-owner-only
# via the regex below so a misconfigured routing block can never broadcast a failure.
$AlwaysOwnerOnlyEvents = @('failure', 'halt', 'judgment', 'step-transition')
$FailedStepPattern     = '^step-\d+-failed$'

# --- Extract owner email (may be missing for pure broadcast events) ---
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

# --- Safety-rail short-circuit: failures, halts, judgment, and step-transition always owner-only ---
if ($AlwaysOwnerOnlyEvents -contains $EventKey -or $EventKey -match $FailedStepPattern) {
    _Require-Owner "always-owner-only event '$EventKey'"
    return @{
        EmailTo              = @($ownerEmail)
        EmailCc              = @()
        TeamsConversationIds = @()
        TestMode             = $false
        Broadcast            = $false
    }
}

# --- Routing lookup: missing entry == owner-only default (NOT an error) ---
$routing = $null
if ($Config.notifications -and $Config.notifications.PSObject.Properties['routing']) {
    $routing = $Config.notifications.routing
}
if ($null -eq $routing -or -not $routing.PSObject.Properties[$EventKey]) {
    _Require-Owner "event '$EventKey' has no routing entry (defaulting to owner-only)"
    return @{
        EmailTo              = @($ownerEmail)
        EmailCc              = @()
        TeamsConversationIds = @()
        TestMode             = $false
        Broadcast            = $false
    }
}

$rule = $routing.$EventKey
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
    # Teams groups resolve to conversation IDs via secrets.teamsChats.<groupKey>.
    # Each chat NAME from $groups.$groupKey is looked up in $Secrets.teamsChats.
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

# Resolve emailGroups
$emailTo = @()
if ($rule.PSObject.Properties['emailGroups']) {
    foreach ($g in @($rule.emailGroups)) { $emailTo += _Resolve-EmailGroup $g }
}

# Resolve ccGroups
$emailCc = @()
if ($rule.PSObject.Properties['ccGroups']) {
    foreach ($g in @($rule.ccGroups)) { $emailCc += _Resolve-EmailGroup $g }
}

# Resolve teamsGroups
$teamsIds = @()
if ($rule.PSObject.Properties['teamsGroups']) {
    foreach ($g in @($rule.teamsGroups)) { $teamsIds += _Resolve-TeamsGroup $g }
}

# Honor includeOwner: always add owner to To-line if requested
$includeOwner = $false
if ($rule.PSObject.Properties['includeOwner']) { $includeOwner = [bool]$rule.includeOwner }
if ($includeOwner) {
    _Require-Owner "broadcast event '$EventKey' has includeOwner=true"
    if ($emailTo -notcontains $ownerEmail) { $emailTo += $ownerEmail }
}

return @{
    EmailTo              = @($emailTo | Select-Object -Unique)
    EmailCc              = @($emailCc | Select-Object -Unique)
    TeamsConversationIds = @($teamsIds | Select-Object -Unique)
    TestMode             = $false
    Broadcast            = $true
}
