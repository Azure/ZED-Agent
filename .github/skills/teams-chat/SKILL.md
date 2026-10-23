---
name: teams-chat
description: "Read Microsoft Teams chat messages and conversations via CDP and Teams messaging API. List conversations, read full message history with pagination, and search across chats. Activated when users ask to read, search, or summarize Teams chats and messages. Requires Windows with Microsoft Teams (new WebView2 version) running with CDP enabled on port 9222."
compatibility: "Requires Windows with Microsoft Teams (new WebView2 version) and Windows PowerShell 5.1"
metadata:
  author: Azure Core Team
  version: "1.0.0"
---

# Teams Chat

Reads Microsoft Teams chat messages programmatically via Chrome DevTools Protocol (CDP). Extracts the Skype auth token from Teams' httpOnly cookies, then calls the Teams messaging API directly for full paginated access to conversation history.

No Graph API permissions or cloud tokens required. Pure PowerShell talking to the locally running Teams app.

## Prerequisites

- **Windows-only** — uses Teams WebView2 CDP interface
- **Microsoft Teams** (new version, WebView2-based `MSTeams_8wekyb3d8bbwe`) must be running
- **CDP enabled** — User environment variable `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` must be set to `--remote-debugging-port=9222` and Teams restarted after setting it
- **Windows PowerShell 5.1** (`powershell`)

### One-Time Setup

If CDP is not already enabled, run:

```powershell
[Environment]::SetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "--remote-debugging-port=9222", "User")
```

Then restart Teams. Verify CDP is active: `Invoke-RestMethod http://localhost:9222/json`

## Activation Triggers

- User asks to "read my Teams chat" or "show my Teams messages"
- User asks "what did X say in Teams"
- User asks to "list my Teams conversations"
- User asks to "search Teams for X"
- User asks to "summarize a Teams chat"
- User mentions a Teams chat or conversation by name
- User asks about recent messages or discussions in Teams

## Capabilities

1. **List Chats** — List conversations grouped by type with filtering, plus unread and mentions views ([Get-TeamsChats.ps1](./scripts/Get-TeamsChats.ps1))
2. **Read Chat** — Read complete message history with pagination, reactions, image/giphy alt text, and optional thread filtering ([Get-TeamsChatMessages.ps1](./scripts/Get-TeamsChatMessages.ps1))
3. **Search** — Search message content and thread subjects across conversations with reaction and context display ([Search-TeamsChatMessages.ps1](./scripts/Search-TeamsChatMessages.ps1))
4. **List Channel Threads** — List thread subjects and reply counts in a Teams channel ([Get-TeamsChannelThreads.ps1](./scripts/Get-TeamsChannelThreads.ps1))

All scripts use [Teams-ChatHelper.ps1](./scripts/Teams-ChatHelper.ps1) which connects to CDP via `System.Net.WebSockets.ClientWebSocket`, extracts the `skypetoken_asm` httpOnly cookie via `Network.getAllCookies`, then calls `amer.ng.msg.teams.microsoft.com`.

### Output Features

- **Reactions**: Displayed inline after sender name as `[heart 3, thumbsup 1, tada 2]`. Standard Teams reactions, Unicode-prefixed keys, and custom org emojis are all handled.
- **Images/Giphys**: Rendered as `[alt text]` (e.g., `[Animation Pixar GIF (GIF Image)]`, `[this-is-fine]`).
- **HTML stripping**: Message content is converted to plain text with links, bold, and formatting stripped.

---

## Technical Details

### How It Works

1. PowerShell calls `http://localhost:9222/json` to discover CDP targets
2. Connects via `ClientWebSocket` to the Teams page's WebSocket debug URL
3. Sends `Network.getAllCookies` CDP command to read all cookies including httpOnly
4. Extracts the `skypetoken_asm` cookie (Skype auth token set by Teams' backend)
5. Calls the Teams messaging API via `Invoke-RestMethod` with `Authentication: skypetoken=<token>`

### Token Refresh

The Skype token is refreshed automatically by Teams' native layer. As long as Teams is running and logged in, `Network.getAllCookies` always returns a valid token. No manual refresh needed.

---

## Workflow

### Step 1: Determine Intent

- If user wants to **see their recent chats** → Step 2 (List Chats)
- If user wants to **read a specific chat** → List first to get ID, then Step 3 (Read Chat)
- If user wants to **search for messages** → Step 4 (Search)
- If user wants to **browse channel threads** → Step 5 (List Threads), then Step 3 with `-ThreadId`

### Step 2: List Chats

```powershell
# From workspace-level install:
powershell -NoProfile -File .\.github\skills\teams-chat\scripts\Get-TeamsChats.ps1
# From user-level install:
powershell -NoProfile -File ~\.copilot\skills\teams-chat\scripts\Get-TeamsChats.ps1
```

**Parameters:**
- `-MaxResults <int>` — limit results (default 50)
- `-Search <string>` — filter conversations by display name, including member names for DMs and group chats
- `-Type <string>` — filter by thread type: chat, meeting, topic, space
- `-View <string>` — API view filter: `mychats` (default), `unread`, `mentions`

Returns conversation names, IDs, types, and last message timestamps.

### Step 3: Read Chat Messages

**By conversation ID (from Get-TeamsChats):**

```powershell
# From workspace-level install:
powershell -NoProfile -File .\.github\skills\teams-chat\scripts\Get-TeamsChatMessages.ps1 -ConversationId "<ID>"
# From user-level install:
powershell -NoProfile -File ~\.copilot\skills\teams-chat\scripts\Get-TeamsChatMessages.ps1 -ConversationId "<ID>"
```

**By name search:**

```powershell
# From workspace-level install:
powershell -NoProfile -File .\.github\skills\teams-chat\scripts\Get-TeamsChatMessages.ps1 -Name "search term"
# From user-level install:
powershell -NoProfile -File ~\.copilot\skills\teams-chat\scripts\Get-TeamsChatMessages.ps1 -Name "search term"
```

**Parameters:**
- `-ConversationId <string>` — conversation ID from Get-TeamsChats.ps1
- `-Name <string>` — search for conversation by display name, including member names for DMs and group chats
- `-ThreadId <string>` — filter to a specific thread by root message ID (from Get-TeamsChannelThreads.ps1)
- `-MaxMessages <int>` — maximum messages to fetch (default 100, supports pagination)

### Step 4: Search Messages Across Chats

```powershell
# From workspace-level install:
powershell -NoProfile -File .\.github\skills\teams-chat\scripts\Search-TeamsChatMessages.ps1 -Query "search term"
# From user-level install:
powershell -NoProfile -File ~\.copilot\skills\teams-chat\scripts\Search-TeamsChatMessages.ps1 -Query "search term"
```

**Parameters:**
- `-Query <string>` — search term (required, case-insensitive, matches message content and thread subjects)
- `-MaxChats <int>` — number of conversations to search across (default 50)
- `-MaxMessages <int>` — max messages to fetch per conversation (default 50)
- `-ChatName <string>` — limit search to a single conversation matching this name

Fetches recent messages from each conversation and filters locally. Shows matching snippets with context, including conversation IDs for direct follow-up. Searches both message body content and thread subject lines.

### Step 5: List Channel Threads

```powershell
# From workspace-level install:
powershell -NoProfile -File .\.github\skills\teams-chat\scripts\Get-TeamsChannelThreads.ps1 -Name "channel name"
# From user-level install:
powershell -NoProfile -File ~\.copilot\skills\teams-chat\scripts\Get-TeamsChannelThreads.ps1 -Name "channel name"
```

**Parameters:**
- `-ConversationId <string>` — channel conversation ID
- `-Name <string>` — search for a channel by topic name
- `-MaxMessages <int>` — how many messages to scan for threads (default 200)

Returns thread subjects, root message IDs (for use with `-ThreadId` in Get-TeamsChatMessages), authors, and reply counts.

---

## Rules

1. **DO NOT** modify, send, or delete any messages. This skill is **read-only**.
2. **MUST** list chats first to get conversation IDs before reading a specific chat.
3. **MUST** check CDP availability before reporting errors — suggest setup steps if connection fails.
4. **MAY** combine with other skills (e.g., read a Teams discussion about an incident, then investigate with IcM tools).
5. For long conversations (>20 messages), summarize key points and offer to show more.
6. When the user mentions a chat by name, use `-Name` parameter to find it directly.
7. **DO NOT** expose raw conversation IDs to the user — use them internally for lookups.

## Error Handling

| Error | Cause | Fix |
|-------|-------|-----|
| Unable to connect to localhost:9222 | CDP not enabled or Teams not running | Set env var and restart Teams |
| CDP port owned by 'ONENOTE' (or other app) | Another WebView2 app grabbed port 9222 first | Close the conflicting app, restart Teams, then reopen the other app |
| Teams page not found | CDP active but no Teams page detected | Ensure Teams is fully loaded |
| Skype token cookie not found | Token expired or Teams not logged in | Restart Teams or log in |
| API 401 | Token expired | Restart Teams to refresh tokens |

## Limitations

- **Read-only**: Cannot send messages, react, or modify chats
- **Token lifetime**: Skype token refreshes automatically while Teams runs, but expires if Teams is closed
- **Search is client-side**: Fetches messages first, then filters locally. Use `-MaxChats` and `-MaxMessages` to control breadth vs speed, or `-ChatName` to target a single conversation
- **Channel enumeration**: Only channels you've recently interacted with appear in the conversation list. No "list all channels in team X" endpoint is available with the Skype token
- **CDP port conflicts**: The `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` env var affects all WebView2 apps (Teams, OneNote, Outlook). Whichever app starts first claims port 9222. If Teams isn't the first, close the conflicting app and restart Teams. The script detects this and reports which app is blocking.
