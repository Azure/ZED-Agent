function Send-TeamsMessage {
    <#
    .SYNOPSIS
        Send an HTML message to a Teams conversation via CDP + Skype token.
    .DESCRIPTION
        Uses Teams-ChatHelper.ps1 (CDP → Skype token) to send messages directly
        to Teams chats. No Power Automate or Graph API needed.
        Supports HTML templates with {{variable}} placeholders via Expand-Template.
    .PARAMETER ConversationId
        The Teams conversation ID (from Get-TeamsConversations or secrets.json).
    .PARAMETER TemplatePath
        Path to an HTML template file. Mutually exclusive with -Body.
    .PARAMETER Body
        Raw HTML string to send. Mutually exclusive with -TemplatePath.
    .PARAMETER Variables
        Hashtable of template variables for Expand-Template (used with -TemplatePath).
    .PARAMETER Subject
        Optional message subject (shown as bold header in Teams thread).
    #>
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [string]$TemplatePath,
        [string]$Body,
        [hashtable]$Variables = @{},
        [string]$Subject
    )

    if (-not $TemplatePath -and -not $Body) {
        return @{ success = $false; error = "Either -TemplatePath or -Body must be provided" }
    }

    # Load the Teams-ChatHelper from the bundled teams-chat sibling skill
    $helperPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "teams-chat\scripts\Teams-ChatHelper.ps1"
    if (-not (Test-Path $helperPath)) {
        return @{ success = $false
                  error = "teams-chat skill is missing at $helperPath. Re-run Install-Zed.ps1 to restore it (it's bundled with ZED)." }
    }
    . $helperPath

    # Build message body from template or raw HTML
    if ($TemplatePath) {
        . "$PSScriptRoot\Expand-Template.ps1"
        $messageBody = Expand-Template -TemplatePath $TemplatePath -Variables $Variables
    } else {
        $messageBody = $Body
    }

    # Get Skype token via CDP
    try {
        $token = Get-TeamsSkypeToken
    } catch {
        return @{ success = $false; error = "CDP/token error: $($_.Exception.Message)" }
    }

    # Build the message payload
    $payload = @{
        messagetype = 'RichText/Html'
        contenttype = 'text'
        content     = $messageBody
    }
    if ($Subject) {
        $payload.properties = @{ subject = $Subject }
    }
    $jsonPayload = $payload | ConvertTo-Json -Depth 10 -Compress

    # Send with retry (3 attempts, backoff on 429)
    $url = "$script:API_BASE/conversations/$([Uri]::EscapeDataString($ConversationId))/messages"
    $headers = @{
        'Authentication' = "skypetoken=$token"
        'Content-Type'   = 'application/json'
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonPayload -ErrorAction Stop
            return @{
                success   = $true
                method    = 'CDP+SkypeToken'
                messageId = $response.OriginalArrivalTime
            }
        } catch {
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 0 }
            if ($statusCode -eq 429 -and $attempt -lt 3) {
                Start-Sleep (5 * $attempt)
            } elseif ($attempt -ge 3) {
                return @{ success = $false; error = $_.Exception.Message; method = 'CDP+SkypeToken' }
            } else {
                # Non-retryable error
                return @{ success = $false; error = $_.Exception.Message; method = 'CDP+SkypeToken' }
            }
        }
    }
}

function Resolve-OneOnOneChat {
    <#
    .SYNOPSIS
        Deterministically resolve a user alias to their 1:1 Teams conversation ID.
    .DESCRIPTION
        Uses Microsoft Graph API to resolve alias → Azure AD Object ID, then constructs
        the 1:1 conversation ID from the sorted pair of Azure AD GUIDs.
        This is ZERO-AMBIGUITY — no fuzzy name matching. The conversation ID format for
        1:1 chats is: 19:{lowerGuid}_{higherGuid}@unq.gbl.spaces
    .PARAMETER Alias
        The user's corporate alias (e.g., "surrai"). Resolved to {alias}@microsoft.com.
    .PARAMETER Email
        Full email address. Use instead of -Alias when the domain differs from microsoft.com.
    .OUTPUTS
        Hashtable with conversationId, displayName, email, objectId, or $null on failure.
    #>
    param(
        [string]$Alias,
        [string]$Email
    )

    if (-not $Alias -and -not $Email) {
        Write-Error "Either -Alias or -Email must be provided"
        return $null
    }

    $targetEmail = if ($Email) { $Email } else { "$Alias@microsoft.com" }

    # Step 1: Resolve user via Microsoft Graph API
    try {
        $graphToken = az account get-access-token --resource "https://graph.microsoft.com" --query accessToken -o tsv 2>$null
        if (-not $graphToken) { throw "Failed to get Graph API token from az CLI" }

        $headers = @{ Authorization = "Bearer $graphToken" }
        $encodedEmail = [Uri]::EscapeDataString($targetEmail)
        $user = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$encodedEmail`?`$select=id,displayName,mail,userPrincipalName" -Headers $headers -ErrorAction Stop
    } catch {
        Write-Warning "Graph API lookup failed for '$targetEmail': $($_.Exception.Message)"
        return $null
    }

    $targetId = $user.id
    if (-not $targetId) {
        Write-Warning "No Azure AD object ID returned for '$targetEmail'"
        return $null
    }

    # Step 2: Get our own Azure AD ID from Graph (cached after first call)
    if (-not $script:MyAzureAdId) {
        try {
            $me = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me?`$select=id" -Headers $headers -ErrorAction Stop
            $script:MyAzureAdId = $me.id
        } catch {
            Write-Warning "Failed to get own Azure AD ID: $($_.Exception.Message)"
            return $null
        }
    }

    # Step 3: Construct deterministic 1:1 conversation ID (sorted GUIDs)
    $ids = @($script:MyAzureAdId, $targetId) | Sort-Object
    $conversationId = "19:$($ids[0])_$($ids[1])@unq.gbl.spaces"

    return @{
        conversationId = $conversationId
        displayName    = $user.displayName
        email          = $user.mail
        objectId       = $targetId
        type           = 'chat'
    }
}

function Find-TeamsChat {
    <#
    .SYNOPSIS
        Find a Teams GROUP conversation by display name. Returns the conversation ID.
    .DESCRIPTION
        Uses Get-TeamsConversations + Resolve-ConversationDisplayName to search
        for a group chat by name. Used during setup to auto-discover group chat IDs.
        WARNING: Do NOT use this for 1:1 chats — use Resolve-OneOnOneChat instead.
        Fuzzy name matching can misroute to wrong person or group.
    #>
    param(
        [Parameter(Mandatory)][string]$ChatName,
        [int]$PageSize = 100
    )

    $helperPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "teams-chat\scripts\Teams-ChatHelper.ps1"
    . $helperPath

    $token = Get-TeamsSkypeToken
    $conversations = Get-TeamsConversations -Token $token -PageSize $PageSize

    foreach ($conv in $conversations) {
        $displayName = Resolve-ConversationDisplayName -Token $token -Conversation $conv
        if ($displayName -like "*$ChatName*") {
            return @{
                conversationId = $conv.id
                displayName    = $displayName
                type           = $conv.threadProperties.threadType
            }
        }
    }

    return $null
}
