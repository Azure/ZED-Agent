<#
.SYNOPSIS
    Helper functions for Teams chat CDP + API automation (pure PowerShell).
.DESCRIPTION
    Connects to Teams WebView2 via Chrome DevTools Protocol, extracts the Skype auth token
    from httpOnly cookies, and provides functions to call the Teams messaging API.
#>

$script:CDP_PORT = if ($env:TEAMS_CDP_PORT) { $env:TEAMS_CDP_PORT } else { 9222 }
$script:API_BASE = "https://amer.ng.msg.teams.microsoft.com/v1/users/ME"

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory)][string]$WebSocketUrl,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None

    try {
        $ws.ConnectAsync([Uri]$WebSocketUrl, $ct).Wait()

        $cmd = @{ id = 1; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($cmd)
        $segment = New-Object System.ArraySegment[byte] -ArgumentList (,$bytes)
        $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()

        $buffer = New-Object byte[] 262144
        $result = New-Object System.Text.StringBuilder
        do {
            $seg = New-Object System.ArraySegment[byte] -ArgumentList (,$buffer)
            $recv = $ws.ReceiveAsync($seg, $ct).Result
            [void]$result.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $recv.Count))
        } while (-not $recv.EndOfMessage)

        return ($result.ToString() | ConvertFrom-Json).result
    }
    finally {
        if ($ws.State -eq 'Open') {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $ct).Wait()
        }
        $ws.Dispose()
    }
}

function Get-CdpPortOwner {
    $conns = Get-NetTCPConnection -LocalPort $script:CDP_PORT -ErrorAction SilentlyContinue |
        Where-Object State -eq 'Listen'
    if (-not $conns) { return $null }

    foreach ($ownerPid in ($conns.OwningProcess | Select-Object -Unique)) {
        $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue).ParentProcessId
        if ($parentId) {
            $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
            if ($parent) { return $parent.ProcessName }
        }
    }
    return "unknown"
}

function Get-TeamsSkypeToken {
    try {
        $targets = Invoke-RestMethod -Uri "http://localhost:$script:CDP_PORT/json" -ErrorAction Stop
    } catch {
        throw "CDP not reachable on port $script:CDP_PORT. Ensure Teams is running and WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is set to '--remote-debugging-port=$script:CDP_PORT' (user env var), then restart Teams."
    }

    $target = $targets | Where-Object { $_.type -eq 'page' -and ($_.url -match 'teams\.microsoft\.com' -or $_.url -match 'teams\.cloud\.microsoft' -or $_.url -match 'microsoft365\.com') } | Select-Object -First 1

    if (-not $target) {
        $owner = Get-CdpPortOwner
        if ($owner -and $owner -ne 'ms-teams') {
            throw "CDP port $script:CDP_PORT is owned by '$owner' instead of Teams. Close $owner, restart Teams, then reopen $owner. (The WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS env var affects all WebView2 apps; whichever starts first claims the port.)"
        }
        throw "Teams page not found via CDP on port $script:CDP_PORT"
    }

    $result = Invoke-CdpCommand -WebSocketUrl $target.webSocketDebuggerUrl -Method 'Network.getAllCookies'
    $cookie = $result.cookies | Where-Object { $_.name -eq 'skypetoken_asm' } | Select-Object -First 1

    # If no token, Teams may have navigated away from the Teams domain. Navigate back and retry.
    if (-not $cookie) {
        Invoke-CdpCommand -WebSocketUrl $target.webSocketDebuggerUrl -Method 'Page.navigate' -Params @{ url = 'https://teams.microsoft.com/v2/' } | Out-Null
        Start-Sleep 12

        $targets = Invoke-RestMethod -Uri "http://localhost:$script:CDP_PORT/json" -ErrorAction Stop
        $target = $targets | Where-Object { $_.type -eq 'page' -and ($_.url -match 'teams\.microsoft\.com' -or $_.url -match 'teams\.cloud\.microsoft') } | Select-Object -First 1
        if (-not $target) { throw "Teams page not found after navigation retry" }

        $result = Invoke-CdpCommand -WebSocketUrl $target.webSocketDebuggerUrl -Method 'Network.getAllCookies'
        $cookie = $result.cookies | Where-Object { $_.name -eq 'skypetoken_asm' } | Select-Object -First 1
        if (-not $cookie) { throw "Skype token cookie not found. Ensure Teams is logged in." }
    }

    return $cookie.value
}

function Invoke-TeamsApi {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path
    )

    $url = if ($Path.StartsWith('http')) { $Path } else { "$script:API_BASE$Path" }
    $headers = @{ 'Authentication' = "skypetoken=$Token" }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $url -Headers $headers -ErrorAction Stop
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 429 -and $attempt -lt 3) {
                Start-Sleep (5 * $attempt)
            } else {
                throw
            }
        }
    }
}

function Get-TeamsConversations {
    param(
        [Parameter(Mandatory)][string]$Token,
        [int]$PageSize = 50,
        [ValidateSet('mychats', 'unread', 'mentions', 'superchat')]
        [string]$View = 'mychats'
    )
    return (Invoke-TeamsApi -Token $Token -Path "/conversations?view=$View&pageSize=$PageSize").conversations
}

function Get-TeamsMessages {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ConversationId,
        [int]$PageSize = 50,
        [int]$MaxMessages = 200,
        [string]$ThreadId = ""
    )

    $allMessages = @()
    $url = "$script:API_BASE/conversations/$([Uri]::EscapeDataString($ConversationId))/messages?pageSize=$PageSize"

    while ($url -and $allMessages.Count -lt $MaxMessages) {
        $data = Invoke-TeamsApi -Token $Token -Path $url
        $messages = $data.messages
        if (-not $messages -or $messages.Count -eq 0) { break }

        if ($ThreadId) {
            $messages = @($messages | Where-Object { $_.rootMessageId -eq $ThreadId })
        }

        $allMessages += $messages

        $url = $data._metadata.backwardLink
    }

    return $allMessages
}

function Get-TeamsChannelThreads {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ConversationId,
        [int]$MaxMessages = 200
    )

    $msgs = Get-TeamsMessages -Token $Token -ConversationId $ConversationId -MaxMessages $MaxMessages
    $chatMsgs = @($msgs | Where-Object { $_.messagetype -eq 'Text' -or $_.messagetype -eq 'RichText/Html' -or $_.messagetype -eq 'RichText' })

    # Group by rootMessageId to find threads
    $threads = @{}
    foreach ($m in $chatMsgs) {
        $rootId = $m.rootMessageId
        if (-not $rootId) { continue }
        if (-not $threads.ContainsKey($rootId)) {
            $threads[$rootId] = @{
                RootId = $rootId
                Subject = ''
                FirstSender = ''
                FirstTime = ''
                ReplyCount = 0
                LastReplyTime = ''
            }
        }
        # The root post is the one whose id equals rootMessageId
        if ($m.id -eq $rootId -or $m.sequenceId -eq $rootId) {
            $threads[$rootId].Subject = $m.properties.subject
            $threads[$rootId].FirstSender = $m.imdisplayname
            $threads[$rootId].FirstTime = if ($m.originalarrivaltime) { $m.originalarrivaltime } else { $m.composetime }
            if (-not $threads[$rootId].Subject) {
                $threads[$rootId].Subject = (ConvertFrom-HtmlContent $m.content).Substring(0, [Math]::Min(80, (ConvertFrom-HtmlContent $m.content).Length))
            }
        } else {
            $threads[$rootId].ReplyCount++
            $time = if ($m.originalarrivaltime) { $m.originalarrivaltime } else { $m.composetime }
            if (-not $threads[$rootId].LastReplyTime -or $time -gt $threads[$rootId].LastReplyTime) {
                $threads[$rootId].LastReplyTime = $time
            }
        }
    }

    return $threads.Values | Sort-Object { $_.LastReplyTime } -Descending
}

function Resolve-ConversationDisplayName {
    param(
        [Parameter(Mandatory)][string]$Token,
        $Conversation
    )

    $topic = $Conversation.threadProperties.topic
    if ($topic) { return $topic }
    $topic = $Conversation.threadProperties.spaceThreadTopic
    if ($topic) { return $topic }

    # For 1:1 chats, get the other person's name from the most recent message
    if ($Conversation.id -match '@unq\.gbl\.spaces') {
        try {
            $msgs = Get-TeamsMessages -Token $Token -ConversationId $Conversation.id -PageSize 5 -MaxMessages 5
            $otherMsg = $msgs | Where-Object {
                ($_.messagetype -eq 'Text' -or $_.messagetype -eq 'RichText/Html') -and
                $_.imdisplayname -and $_.from -notmatch '1e5c567b-6d3a-4179-9cbd-5291dc7204ff'
            } | Select-Object -First 1
            if ($otherMsg) { return $otherMsg.imdisplayname }

            # Fallback: use any sender name that isn't us
            $anyMsg = $msgs | Where-Object { $_.imdisplayname } | Select-Object -First 1
            if ($anyMsg) { return $anyMsg.imdisplayname }
        } catch {}
        return "1:1 chat"
    }

    # For untitled group chats, get participant names from recent messages
    if ($Conversation.threadProperties.threadType -eq 'chat' -and -not $topic) {
        try {
            $msgs = Get-TeamsMessages -Token $Token -ConversationId $Conversation.id -PageSize 10 -MaxMessages 10
            $names = @($msgs | Where-Object { $_.imdisplayname } | Select-Object -ExpandProperty imdisplayname -Unique | Select-Object -First 3)
            if ($names.Count -gt 0) { return ($names -join ', ') }
        } catch {}
    }

    if ($Conversation.id -match 'meeting_') { return "Meeting chat" }
    return $Conversation.id.Substring(0, [Math]::Min(50, $Conversation.id.Length))
}

function ConvertFrom-HtmlContent {
    param([string]$Html)
    # Preserve image alt text (giphys, custom emoji, inline images)
    $result = $Html -replace '<img\s[^>]*alt="([^"]+)"[^>]*/?\s*>', '[$1]'
    # Strip remaining HTML tags
    $result = $result -replace '<[^>]+>', ''
    # Decode HTML entities
    $result = $result -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"'
    return $result.Trim()
}

function Format-Reactions {
    param($Properties)

    $emotionMap = @{
        'like'          = 'like'; 'heart'        = 'heart'
        'laugh'         = 'laugh'; 'surprised'   = 'surprised'
        'sad'           = 'sad'; 'angry'         = 'angry'
        'yes'           = 'thumbsup'; 'no'       = 'thumbsdown'
        'clap'          = 'clap'; 'fire'         = 'fire'
        'cry'           = 'cry'; 'checkmark'     = 'check'
        'partypopper'   = 'tada'; 'heavyplussign' = 'plus'
        'salute'        = 'salute'; 'follow'     = 'follow'
        'muscle'        = 'muscle'; 'eyesincloud' = 'thinking'
        'whiteheavycheckmark' = 'check'; 'heavycheckmark' = 'check'
        'eyes'          = 'eyes'; 'crossedswords' = 'swords'
        'hundredpointssymbol' = '100'; 'giggle' = 'giggle'
    }

    if (-not $Properties -or -not $Properties.emotions) { return "" }

    $emotions = $Properties.emotions
    if ($emotions -is [string]) {
        if (-not $emotions -or $emotions -eq '[]') { return "" }
        try { $emotions = $emotions | ConvertFrom-Json } catch { return "" }
    }

    if (-not $emotions -or $emotions.Count -eq 0) { return "" }

    $parts = @()
    foreach ($e in $emotions) {
        $key = ($e.key -replace '-tone\d+$', '').ToLower()
        # Clean up Unicode-prefixed keys like "2795_heavyplussign" or "1f389_partypopper"
        $key = $key -replace '^\w{4,5}_', ''
        # Clean up custom/org emoji keys like "greencheck1;0-canaryeus-d3-4cfa..." -> "greencheck1"
        $key = $key -replace ';0-.*$', ''
        $emoji = if ($emotionMap.ContainsKey($key)) { $emotionMap[$key] } else { $key }
        $count = if ($e.users) { $e.users.Count } else { 1 }
        $parts += "$emoji $count"
    }

    return " [$($parts -join ', ')]"
}
