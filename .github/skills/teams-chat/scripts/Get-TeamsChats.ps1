<#
.SYNOPSIS
    Lists Teams chat conversations via the Teams messaging API.
.PARAMETER MaxResults
    Maximum number of conversations to return (default 50).
.PARAMETER Search
    Filter conversations by display name, including member names for DMs and group chats (case-insensitive substring match).
.PARAMETER Type
    Filter by thread type: chat, meeting, topic, space.
.PARAMETER View
    API view filter: mychats (default), unread, mentions.
#>
param(
    [int]$MaxResults = 50,
    [string]$Search = "",
    [string]$Type = "",
    [ValidateSet('mychats', 'unread', 'mentions')]
    [string]$View = "mychats"
)

. "$PSScriptRoot\Teams-ChatHelper.ps1"

try {
    $token = Get-TeamsSkypeToken
    $conversations = Get-TeamsConversations -Token $token -PageSize $MaxResults -View $View

    $viewLabel = switch ($View) { 'unread' { 'Unread' }; 'mentions' { 'Mentions' }; default { 'Recent' } }

    if ($Type) {
        $conversations = $conversations | Where-Object {
            $_.threadProperties.threadType -like "*$Type*"
        }
    }

    if (-not $conversations -or $conversations.Count -eq 0) {
        Write-Host $(if ($Search) { "No conversations matching `"$Search`"" } else { "No conversations found" })
        return
    }

    # Resolve display names, skipping expensive API calls for non-matching topics when searching
    $resolved = foreach ($conv in $conversations) {
        $topic = $conv.threadProperties.topic
        if (-not $topic) { $topic = $conv.threadProperties.spaceThreadTopic }

        if ($Search -and $topic) {
            # Has a topic: cheap string check, skip resolution if no match
            if ($topic -like "*$Search*") {
                [PSCustomObject]@{ Conversation = $conv; DisplayName = $topic }
            }
        } else {
            # No search, or no topic (DMs/untitled groups): resolve the display name
            $displayName = if ($topic) { $topic } else { Resolve-ConversationDisplayName -Token $token -Conversation $conv }
            if (-not $Search -or $displayName -like "*$Search*") {
                [PSCustomObject]@{ Conversation = $conv; DisplayName = $displayName }
            }
        }
    }
    $resolved = @($resolved)

    if (-not $resolved -or $resolved.Count -eq 0) {
        Write-Host $(if ($Search) { "No conversations matching `"$Search`"" } else { "No conversations found" })
        return
    }

    Write-Host "$viewLabel - Found $($resolved.Count) conversation(s):`n"

    $groups = $resolved | Group-Object { $_.Conversation.threadProperties.threadType }
    foreach ($group in $groups) {
        Write-Host "--- $($group.Name) ($($group.Count)) ---"
        foreach ($item in $group.Group) {
            $conv = $item.Conversation
            $topic = $item.DisplayName

            $lastMsg = $conv.properties.lastimreceivedtime
            $lastTime = if ($lastMsg) { ([DateTime]$lastMsg).ToLocalTime().ToString("g") } else { "" }

            Write-Host "  $topic"
            Write-Host "    ID: $($conv.id)"
            if ($lastTime) { Write-Host "    Last: $lastTime" }
            Write-Host ""
        }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match 'ECONNREFUSED|Unable to connect|No connection') {
        Write-Host "`nTeams CDP not available. Ensure:" -ForegroundColor Yellow
        Write-Host "1. WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is set to --remote-debugging-port=9222"
        Write-Host "2. Teams has been restarted after setting the variable"
    }
    exit 1
}
