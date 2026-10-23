<#
.SYNOPSIS
    Lists thread (root post) subjects in a Teams channel conversation.
.PARAMETER ConversationId
    The channel conversation ID (from Get-TeamsChats.ps1).
.PARAMETER Name
    Search for a channel by topic name instead of using an ID.
.PARAMETER MaxMessages
    Maximum messages to scan for threads (default 200).
#>
param(
    [string]$ConversationId = "",
    [string]$Name = "",
    [int]$MaxMessages = 200
)

. "$PSScriptRoot\Teams-ChatHelper.ps1"

try {
    if (-not $ConversationId -and -not $Name) {
        Write-Host "Usage: .\Get-TeamsChannelThreads.ps1 -ConversationId <id> | -Name <search>"
        Write-Host "  Use Get-TeamsChats.ps1 to find channel conversation IDs"
        exit 1
    }

    $token = Get-TeamsSkypeToken

    if ($Name) {
        Write-Host "Searching for channel matching: `"$Name`""
        $conversations = Get-TeamsConversations -Token $token -PageSize 50
        $match = $conversations | Where-Object {
            ($_.threadProperties.topic -and $_.threadProperties.topic -like "*$Name*") -or
            ($_.threadProperties.spaceThreadTopic -and $_.threadProperties.spaceThreadTopic -like "*$Name*")
        } | Select-Object -First 1

        if (-not $match) {
            Write-Host "No conversation found matching `"$Name`"" -ForegroundColor Red
            exit 1
        }

        $ConversationId = $match.id
        $channelName = if ($match.threadProperties.topic) { $match.threadProperties.topic } else { $match.threadProperties.spaceThreadTopic }
        Write-Host "Found: $channelName"
    }

    Write-Host "Scanning for threads...`n"

    $threads = Get-TeamsChannelThreads -Token $token -ConversationId $ConversationId -MaxMessages $MaxMessages

    if (-not $threads -or @($threads).Count -eq 0) {
        Write-Host "No threads found"
        return
    }

    Write-Host "=== $(@($threads).Count) thread(s) ===`n"

    foreach ($t in $threads) {
        $subject = if ($t.Subject) { $t.Subject } else { "(no subject)" }
        $firstTime = if ($t.FirstTime) { "$($t.FirstTime)".Substring(0, [Math]::Min(19, "$($t.FirstTime)".Length)) } else { "" }
        $replies = $t.ReplyCount

        Write-Host "  $subject"
        Write-Host "    ThreadId: $($t.RootId)"
        Write-Host "    By: $($t.FirstSender) | Started: $firstTime | Replies: $replies"
        Write-Host ""
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
