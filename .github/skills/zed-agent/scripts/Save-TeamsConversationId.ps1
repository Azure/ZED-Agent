<#
.SYNOPSIS
    L-01: Persists Teams conversation IDs in secrets.json at setup time so no
    runtime discovery is needed.

.DESCRIPTION
    Four approaches to auto-discover Teams conversation IDs all failed in the field:
      1. Teams CDP helper — needs Teams Desktop WebView2 CDP, not Edge
      2. Graph API via az CLI — missing Chat.Read scope
      3. Teams Web MSAL cache — tokens encrypted at rest
      4. CDP navigation — session expired

    This function takes the simpler, more robust approach: persist conversation IDs
    in configuration at setup time. The release owner provides the conversation ID
    once, and it's stored in secrets.json (never committed — respects gitignore).

    Optionally supports MSAL device-code flow for delegated Chat.ReadBasic as an
    assist — but this is NOT a hard dependency and no real auth/network call is
    performed during testing.

.PARAMETER ConversationId
    The Teams conversation ID to persist.

.PARAMETER ConversationLabel
    Human-readable label for the conversation (e.g., 'release-channel', 'approvals').

.PARAMETER SecretsJsonPath
    Path to secrets.json.

.PARAMETER UseDeviceCodeFlow
    When set, attempts MSAL device-code flow for Chat.ReadBasic to discover
    conversation IDs. NOT a hard dependency — falls back to manual entry.

.OUTPUTS
    PSCustomObject with success status and the persisted conversation entry.

.NOTES
    secrets.json must NEVER be committed. This file is in .gitignore.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConversationId,
    [Parameter(Mandatory)][string]$ConversationLabel,
    [Parameter(Mandatory)][string]$SecretsJsonPath,
    [switch]$UseDeviceCodeFlow
)

$ErrorActionPreference = 'Stop'

# Validate conversation ID format (Teams conversation IDs are typically 19:xxx@thread.v2 or similar)
if ([string]::IsNullOrWhiteSpace($ConversationId)) {
    throw "TEAMS_EMPTY_CONVERSATION_ID: conversation ID cannot be empty. Provide the Teams conversation ID from the chat URL or Teams admin."
}

# Load or create secrets.json
$secrets = @{}
if (Test-Path $SecretsJsonPath) {
    $secrets = Get-Content $SecretsJsonPath -Raw | ConvertFrom-Json
    # Convert to hashtable for easier manipulation
    $secretsHt = @{}
    foreach ($p in $secrets.PSObject.Properties) { $secretsHt[$p.Name] = $p.Value }
    $secrets = $secretsHt
}

# Ensure teamsConversations section exists
if (-not $secrets.ContainsKey('teamsConversations')) {
    $secrets['teamsConversations'] = @{}
}
$convSection = $secrets['teamsConversations']
if ($convSection -is [PSCustomObject]) {
    $ht = @{}
    foreach ($p in $convSection.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    $convSection = $ht
    $secrets['teamsConversations'] = $convSection
}

# Persist the conversation ID
$convSection[$ConversationLabel] = [PSCustomObject]@{
    conversationId = $ConversationId
    setAt          = (Get-Date).ToUniversalTime().ToString('o')
    source         = if ($UseDeviceCodeFlow) { 'device-code-flow' } else { 'manual-entry' }
}
$secrets['teamsConversations'] = $convSection

# Write back
[PSCustomObject]$secrets | ConvertTo-Json -Depth 10 | Set-Content $SecretsJsonPath -Encoding UTF8

[PSCustomObject]@{
    success          = $true
    label            = $ConversationLabel
    conversationId   = $ConversationId
    secretsPath      = $SecretsJsonPath
    source           = if ($UseDeviceCodeFlow) { 'device-code-flow' } else { 'manual-entry' }
}
