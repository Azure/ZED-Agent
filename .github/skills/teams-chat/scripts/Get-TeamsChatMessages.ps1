<#
.SYNOPSIS
    Reads full message history from a Teams chat conversation via the Teams messaging API.
.PARAMETER ConversationId
    The conversation ID (from Get-TeamsChats.ps1).
.PARAMETER Name
    Search for a conversation by display name, including member names for DMs and group chats.
.PARAMETER ThreadId
    Filter to a specific thread (reply chain) by root message ID. Use Get-TeamsChannelThreads.ps1 to find thread IDs.
.PARAMETER MaxMessages
    Maximum number of messages to fetch with pagination (default 100).
#>
param(
    [string]$ConversationId = "",
    [string]$Name = "",
    [string]$ThreadId = "",
    [int]$MaxMessages = 100
)

. "$PSScriptRoot\Teams-ChatHelper.ps1"

try {
    if (-not $ConversationId -and -not $Name) {
        Write-Host "Usage: .\Get-TeamsChatMessages.ps1 -ConversationId <id> | -Name <search>"
        Write-Host "  Use Get-TeamsChats.ps1 to find conversation IDs"
        exit 1
    }

    $token = Get-TeamsSkypeToken

    if ($Name) {
        Write-Host "Searching for chat matching: `"$Name`""
        $conversations = Get-TeamsConversations -Token $token -PageSize 200
        $match = $conversations | Where-Object {
            $displayName = Resolve-ConversationDisplayName -Token $token -Conversation $_
            $displayName -like "*$Name*"
        } | Select-Object -First 1

        if (-not $match) {
            Write-Host "No conversation found matching `"$Name`"" -ForegroundColor Red
            exit 1
        }

        $ConversationId = $match.id
        $topic = Resolve-ConversationDisplayName -Token $token -Conversation $match
        Write-Host "Found: $topic"
    }

    if ($ThreadId) {
        Write-Host "Fetching thread $ThreadId (up to $MaxMessages messages)...`n"
    } else {
        Write-Host "Fetching up to $MaxMessages messages...`n"
    }

    $messages = Get-TeamsMessages -Token $token -ConversationId $ConversationId -MaxMessages $MaxMessages -ThreadId $ThreadId

    $chatMessages = $messages | Where-Object {
        $_.messagetype -eq 'Text' -or $_.messagetype -eq 'RichText/Html' -or $_.messagetype -eq 'RichText'
    } | Sort-Object { [DateTime]($(if ($_.originalarrivaltime) { $_.originalarrivaltime } elseif ($_.composetime) { $_.composetime } else { '2000-01-01' })) }

    Write-Host "=== $($chatMessages.Count) messages ===`n"

    foreach ($msg in $chatMessages) {
        $sender = if ($msg.imdisplayname) { $msg.imdisplayname } else { ($msg.from -split ':')[-1] }
        $content = ConvertFrom-HtmlContent $msg.content
        $rawTime = "$(if ($msg.originalarrivaltime) { $msg.originalarrivaltime } elseif ($msg.composetime) { $msg.composetime } else { '' })"
        $time = $rawTime.Substring(0, [Math]::Min(19, $rawTime.Length))
        $reactions = Format-Reactions $msg.properties

        if ($content) {
            Write-Host "[$time] ${sender}:${reactions}"
            Write-Host "  $content`n"
        }
    }

    if ($messages.Count -ge $MaxMessages) {
        Write-Host "(Showing first $MaxMessages messages. Use -MaxMessages to increase.)"
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
