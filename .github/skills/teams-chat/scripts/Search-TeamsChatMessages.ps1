<#
.SYNOPSIS
    Searches messages across Teams conversations via the Teams messaging API.
.PARAMETER Query
    Search term (case-insensitive). Required.
.PARAMETER MaxChats
    Number of conversations to search across (default 50).
.PARAMETER MaxMessages
    Maximum messages to fetch per conversation (default 50).
.PARAMETER ChatName
    Limit search to a single conversation matching this name.
#>
param(
    [Parameter(Mandatory)][string]$Query,
    [int]$MaxChats = 50,
    [int]$MaxMessages = 50,
    [string]$ChatName = ""
)

. "$PSScriptRoot\Teams-ChatHelper.ps1"

try {
    $token = Get-TeamsSkypeToken
    $conversations = Get-TeamsConversations -Token $token -PageSize $MaxChats

    if ($ChatName) {
        $conversations = @($conversations | Where-Object {
            $displayName = Resolve-ConversationDisplayName -Token $token -Conversation $_
            $displayName -like "*$ChatName*"
        })
        if ($conversations.Count -eq 0) {
            Write-Host "No conversation found matching `"$ChatName`""
            exit 1
        }
    }

    Write-Host "Searching `"$Query`" across $($conversations.Count) conversations...`n"

    $totalHits = 0
    $queryLower = $Query.ToLower()

    foreach ($conv in $conversations) {
        $topic = Resolve-ConversationDisplayName -Token $token -Conversation $conv

        try {
            $messages = Get-TeamsMessages -Token $token -ConversationId $conv.id -MaxMessages $MaxMessages

            $hits = $messages | Where-Object {
                ($_.messagetype -eq 'Text' -or $_.messagetype -eq 'RichText/Html' -or $_.messagetype -eq 'RichText') -and
                (($_.content -and $_.content.ToLower().Contains($queryLower)) -or
                 ($_.properties.subject -and $_.properties.subject.ToLower().Contains($queryLower)))
            }

            if (-not $hits -or @($hits).Count -eq 0) { continue }

            $hitCount = @($hits).Count
            $totalHits += $hitCount

            Write-Host "=== $topic ($hitCount hit$(if ($hitCount -gt 1) { 's' })) ==="
            Write-Host "    ID: $($conv.id)"

            foreach ($msg in $hits) {
                $sender = if ($msg.imdisplayname) { $msg.imdisplayname } else { "?" }
                $content = ConvertFrom-HtmlContent $msg.content
                $subject = $msg.properties.subject
                $rawTime = if ($msg.originalarrivaltime) { "$($msg.originalarrivaltime)" } elseif ($msg.composetime) { "$($msg.composetime)" } else { "" }
                $time = $rawTime.Substring(0, [Math]::Min(19, $rawTime.Length))
                $reactions = Format-Reactions $msg.properties

                # Show subject if present and it matched
                $subjectTag = if ($subject) { " [thread: $subject]" } else { "" }

                $searchText = if ($subject -and $subject.ToLower().Contains($queryLower)) { $subject } else { $content }
                $idx = $searchText.ToLower().IndexOf($queryLower)
                if ($idx -ge 0) {
                    $start = [Math]::Max(0, $idx - 50)
                    $end = [Math]::Min($searchText.Length, $idx + $Query.Length + 80)
                    $snippet = $(if ($start -gt 0) { "..." }) + $searchText.Substring($start, $end - $start) + $(if ($end -lt $searchText.Length) { "..." })
                } else {
                    $snippet = $content.Substring(0, [Math]::Min(130, $content.Length))
                }

                Write-Host "  [$time] ${sender}:${reactions}${subjectTag} $snippet"
            }
            Write-Host ""
        }
        catch {
            # Skip inaccessible conversations
        }
    }

    Write-Host "Total: $totalHits message(s) matching `"$Query`" across $($conversations.Count) conversations"

    if ($totalHits -eq 0) {
        Write-Host "Try increasing -MaxChats or -MaxMessages to search more data."
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
