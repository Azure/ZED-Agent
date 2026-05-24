---
name: setup
description: |
  First-run initialization for the current month's release. Reads
  .zed-agent/readiness.json (preflight + setupService must be green),
  auto-detects CCOA exclusions, creates .zed-agent/releases/<id>/,
  collects per-release secrets, validates Kusto + SafeFly + Mail MCP,
  and initializes state.json with the 16-step skeleton.

  Use this skill whenever the release owner types any of:
    - `setup`             (full first-run for the current release)
    - `setup check`       (read-only — show readiness chain status, do not write)
    - `setup skip <N,N,N>`(re-enter the per-release skip prompt without re-running everything else)

  Pre-flight is NOT re-run here — that responsibility belongs to
  `test-preflight`. Service-config gaps cause this skill to delegate
  back to `/setup-service` per Behavior Rule 13.
---

# setup — First-Run Initialization

When the release owner says `setup`:

1. **Readiness chain check (do NOT re-run pre-flight)**: Read `.zed-agent/readiness.json` and verify the upstream stages are green. Pre-flight ran during `test-preflight` / `setup-service` Phase 0 — `setup` consumes the recorded result, it does not invoke `Test-PreFlight` directly.

   ```powershell
   $readinessPath = ".zed-agent/readiness.json"
   if (-not (Test-Path $readinessPath)) {
       # No record — owner has not run test-preflight yet.
       # HALT and tell them: "Run 'test-preflight' first, then 'setup-service'."
   }
   $r = Get-Content $readinessPath -Raw | ConvertFrom-Json
   ```

   Apply these gates **in order**, halting at the first failure:

   | Gate | Pass condition | If failed |
   |---|---|---|
   | preflight present | `$r.preflight` exists | *"No pre-flight on record. Run `test-preflight` first."* HALT. |
   | preflight fresh | `(now - $r.preflight.ranAt) < 24h` | *"Pre-flight is stale (last ran {age} ago). Re-run `test-preflight` before `setup`."* HALT. |
   | preflight status | `$r.preflight.status` is `pass` or `warn` | List the failures from `$r.preflight.failures`, tell the owner: *"Run `test-preflight fix` to remediate."* HALT. |
   | setupService present | `$r.setupService` exists | *"Service configuration has not been run. Run `setup-service` first."* HALT. |
   | setupService status | `$r.setupService.status == 'pass'` | If `incomplete`, tell the owner: *"Service config is incomplete — last group: {lastGroup}. Resume with `setup-service group <N>` or `setup-service validate`."* If `fail`, list `$r.setupService.missingFields` and halt the same way. |

   Only after all four gates are green does `setup` proceed. Auto-remediation of broken environment state is now the responsibility of `test-preflight` — do NOT attempt fixes inside `setup` itself. The only auto-remediation `setup` still triggers is the `setup-service` resume cascade (Behavior Rule 13) when the readiness file says `setupService.status` is `incomplete` and the owner asks to continue.

2. **CCOA region exclusion (auto-detect)**: Automatically check the CCOA (Critical Changes Only Advisory) schedule to determine which Azure regions are blocked for the current month.
   a. Use the Engineering Hub MCP tool (`es_search`) to query the CCOA schedule:
      - Search with keywords: `CCOASchedule "Critical Change Only Advisory Schedule" "Planned CCOA" 2026 regions`
      - Question: `"Show me the planned CCOA schedule table with dates, categories, and Azure regions"`
      - The `es_search` tool has direct access to EngHub content — no browser or authentication needed
   b. Parse the returned CCOA schedule table. Each entry has: Event Name, Category, Start Time, End Time, Azure Location, Environment, Applied SDP Policy
   c. Find entries whose date range **overlaps with the current release month** (not just exact month match — a CCOA starting in late prior month or ending in early next month still applies)
   d. Extract all **blocked/restricted Azure regions** from matching entries. Note these location groups:
      - `Global` = all regions
      - `Mooncake` = China North, China East, China North 2, China East 2, China North 3, China East 3
      - `US Public` = Central US, East US, East US 2, East US 3, North Central US, South Central US, West Central US, West US, West US 2, West US 3
      - Individual regions listed directly (e.g., "Israel Central, Qatar Central, UAE North")
   e. Filter by category relevance: `Standard` and `WMT Targeted` CCOAs block deployments via SDP tooling. `Banner` CCOAs are awareness-only — note them but do NOT auto-exclude regions (inform the release owner instead).
   f. Map region display names to Azure short names (e.g., "East US 2" → `eastus2`, "Central US" → `centralus`)
   g. If **no CCOA is active** for the release window → set `excludedRegions` to an empty array `[]`
   h. Display the results to the release owner:
      - If Standard/WMT regions found: *"🔒 CCOA active for {month}: regions {list} are blocked. These will be excluded from production rollout."*
      - If Banner-only: *"⚠️ Banner CCOA for {month} in regions {list}. Deployments are NOT blocked but extra scrutiny is advised."*
      - If no CCOA: *"✅ No CCOA restrictions for {month}. All regions eligible for rollout."*
   i. Ask the release owner to confirm the detected regions are correct, or if they want to add/remove any regions from the exclusion list

3. **Create environment directory**: Create `.zed-agent/` in the current directory

4. **Update .gitignore**: Ensure `.zed-agent/` is in `.gitignore` (if in a git repo)

5. **Prompt for secrets**: Ask the release owner for:
   - **Repo path** — e.g., `D:\{CONFIG[ado.repository]}`. MUST ask and wait. This is needed for `git log` commit collection.
   - **Teams group chat names** that should receive notifications (from CONFIG[notifications.groups.teams]). The agent will auto-discover conversation IDs via CDP.
   
    **Auto-discover Teams conversation IDs** — requires Teams Web open in Edge with CDP on port 9222.
    
    For **group chats** (team channels, named group chats):
    ```powershell
    . .github\skills\zed-agent\scripts\Send-TeamsMessage.ps1
    # Discover each chat listed in CONFIG[notifications.groups.teams]
    $chat = Find-TeamsChat -ChatName "<group chat name from config>"
    # Returns: @{ conversationId = "19:abc..."; displayName = "<chat name>" }
    ```
    
    For **1:1 personal messages** (alias-based, zero-ambiguity):
    ```powershell
    . .github\skills\zed-agent\scripts\Send-TeamsMessage.ps1
    $chat = Resolve-OneOnOneChat -Alias "surrai"
    # Returns: @{ conversationId = "19:{sortedId1}_{sortedId2}@unq.gbl.spaces"; displayName = "Surbhi Rai"; email = "..." }
    # Uses Graph API: alias → Azure AD Object ID → deterministic conversation ID
    ```
    ⚠️ **NEVER use `Find-TeamsChat` for personal 1:1 messages** — fuzzy name matching can send to the wrong person or a group chat. Always use `Resolve-OneOnOneChat` for individuals.
    
    If CDP is not reachable, ask the release owner to provide conversation IDs manually (from Teams web → chat URL → extract the `19:...` thread ID).

    
    **Auto-detect SharePoint site ID** — run `az rest --url "https://graph.microsoft.com/v1.0/sites/microsoft.sharepoint.com:CONFIG[sharepoint.sitePath]" --query id -o tsv` and store in `environment.json`. Do NOT ask the release owner for this.
   
   **Auto-detect tenant ID** — run `az account show --query tenantId -o tsv` and store in `environment.json`. Do NOT ask the release owner for this.
   
   Write discovered conversation IDs to `.zed-agent/secrets.json`:
   ```json
   {
     "teamsChats": {
       "<chat-name-from-config>": "<conversation-id>"
     }
   }
   ```

6. **Create environment.json**: Auto-detect paths and store release owner inputs:
   ```json
   {
     "repoRoot": "<release owner input — repo path>",
     "copilotBinaryPath": "copilot",
     "pwshPath": "pwsh",
     "azCliPath": "az",
     "tenantId": "<auto-detected via az account show>",
     "sharePointSiteId": "<auto-detected via Graph API>",
     "logLevel": "info"
   }
   ```

7. **Validate pipeline catalog**: Load `.github/skills/zed-agent/pipeline-catalog.json` and verify it contains officialBuild, at least one canary, and at least one production pipeline entry

8. **Kusto connectivity test**: Verify connection to Kusto cluster `CONFIG[kusto.canary.cluster]` / database `CONFIG[kusto.canary.database]`.
   - Get token: `az account get-access-token --resource "CONFIG[kusto.canary.cluster]"` (use the actual cluster URL as the resource — the legacy `https://kusto.kusto.windows.net` audience produces tokens real clusters reject).
   - On any token error, dot-source and run `.github/skills/zed-agent/scripts/Repair-AzAuth.ps1 -Tenant 'microsoft.com' -Resource <CONFIG[kusto.canary.cluster]>` before retrying.
   - Run test query against the cluster to verify access.
   - **Parse the response per the Kusto MCP Response Parsing rule** (`$resp.Tables[0].Rows` — capital `T`, index `0`; never `$resp.tables | Where TableName -eq 'PrimaryResult'`; see the BVT Failure Analysis → Query Execution section). If the parse returns zero rows when reality says there should be data, the access pattern is wrong, not the cluster.
   - Run the canary deployment units query to show current canary infrastructure:
     ```kql
     EventLogAllClusters
     | where TIMESTAMP > ago(1d)
     | where CONFIG[kusto.canary.serviceFilter] and DeploymentName !contains "r-pod01"
     | where CONFIG[kusto.canary.stampPrefixFilter]
     | summarize make_set(DeploymentUnit) by StampName
     ```
   - **If `pipeline-catalog.json → canaryRouting.mode == "cluster-type"` OR `productionRouting.mode == "cluster-type"`**:
     - Parse Kusto results to determine which **cluster types** are currently in canary (by inspecting `DeploymentUnit` substrings — `-sfmc`, `-sf`, etc., per each routing block's `clusterTypeMap`). Display the cluster-type → pipeline-key resolution that would happen at runtime. **Iterating `clusterTypeMap`**: each value may be either a single string key (`"sfmc": "SVC-SFMC"`) or an array of keys (`"sfmc": ["PROT-SFMC", "DT-SFMC"]`) — coerce scalar values to single-element arrays before iterating.
     - Verify every pipeline key referenced in `clusterTypeMap` has a `clusterType` declared under `canaryRouting.pipelines[<key>]` / `productionRouting.pipelines[<key>]`. If any is missing, warn the owner to re-run `setup-service` (Group 11) to declare it.
   - **If both routing modes are `"static"` (default)**: skip cluster-type parsing — Steps 5, 7, and 10 will trigger all `canary.*` / `production.*` entries unconditionally. Display: *"Routing mode is 'static' — all canary/production pipelines will be triggered every release; no Kusto-driven routing required."*

9. **SafeFly API connectivity test**: Run the SafeFly pre-flight skill:
   ```powershell
   $check = .\.github\skills\zed-agent\scripts\SafeFly\Test-SafeFlyConnection.ps1
   ```
   - Display: ✅ if `$check.connected`, ❌ if not
   - Show approved lease count: *"Found {N} approved lease(s)"*
   - This validates the release owner's identity has permission to create SafeFly requests

10. **Mail MCP verification + test send** (the agent's only email transport — there is no fallback):
    a. **Check that the `mail` MCP server is registered**: read `~/.copilot/mcp-config.json` (path: `${env:USERPROFILE}\.copilot\mcp-config.json` on Windows, `$HOME/.copilot/mcp-config.json` elsewhere). Parse the JSON and confirm `mcpServers.mail` exists and points to the `agency mcp mail` server. If absent or malformed, halt setup and tell the release owner:
       > ❌ **Mail MCP server is not registered.** Edit `${env:USERPROFILE}\.copilot\mcp-config.json` and add the following entry under `mcpServers` (alongside any existing entries):
       > ```json
       > "mail": {
       >   "command": "agency",
       >   "args": ["mcp", "mail"]
       > }
       > ```
       > Prerequisites: the `agency` CLI must be on `PATH` (this is the internal Microsoft tool that hosts MCP servers including `mail`, `ado`, `kusto`, etc.). Verify with `agency --version`. After editing the file, **restart the Copilot CLI session** and re-run `setup`. Do NOT proceed.
       After confirming the entry exists, also verify the `SendEmailWithAttachments` tool is exposed in the current session's tool list — if the JSON is correct but the tool still isn't listed, the Copilot CLI session was started before the config edit; tell the release owner to restart the session.
    b. **Live send test**: Invoke `SendEmailWithAttachments` to send to `release.json → releaseOwner.email`. Subject: `[Setup] CONFIG[service.name] Release Agent — Email Test`. Body: `ZED agent email test — if you received this, Mail MCP is working. ✅`. `contentType: "Text"`. No attachments.
    c. **Interpret result**:
       - Tool returns success → display ✅ *"Mail MCP verified. Test mail sent to {email} — check inbox for `[Setup] CONFIG[service.name] Release Agent — Email Test`."*
       - Tool returns an auth error → halt setup. Tell the release owner: *"❌ Mail MCP authenticated but Graph rejected the send. Verify your Microsoft 365 account is licensed for Exchange Online and that any Conditional Access policies permit Graph `Mail.Send`. The `agency` CLI uses your signed-in identity — running `agency login` (or restarting it) may refresh the token. Re-run `setup` after fixing."*
       - Tool returns any other error → halt setup, surface the full error message verbatim, instruct the release owner to fix the Mail MCP installation and re-run `setup`.

11. **Release initialization**: Set up the release for the current month.
    a. Auto-detect release ID from current date (format: `YYYY-MM`, e.g., `2026-04`)
    b. You MUST ask the release owner for each of these values and STOP AND WAIT for their response before proceeding. Do NOT auto-fill, assume, or use defaults without the release owner explicitly confirming. If the release owner does not respond, do NOT continue — keep waiting.
       - **Previous release branch name** — e.g., `{CONFIG[ado.branchPrefix]}2411`. Needed for `git log` commit range comparison.
       - **Current release branch name** — e.g., `{CONFIG[ado.branchPrefix]}2502_sbc`. The branch that will be cut for this release.
       - **Target branch cut date** — suggest 3rd of the month, but the release owner MUST confirm or provide a different date
       
       Do NOT ask for or show canary target or production target dates anywhere. These are internal scheduling details managed by the rollout stages.
    c. Create release directory: `.zed-agent/releases/{id}/`
    d. Write `release.json`:
       ```json
       {
         "releaseId": "{id}",
         "releaseOwner": { "alias": "<from az account user.name>", "email": "<alias>@microsoft.com", "name": "<from: az ad signed-in-user show --query displayName -o tsv>" },
         "dates": { "created": "<now>", "branchCut": "<release owner input>" },
         "currentBranch": "<release owner input — e.g., {CONFIG[ado.branchPrefix]}2502_sbc>",
         "previousBranch": "<release owner input — e.g., {CONFIG[ado.branchPrefix]}2411>",
         "excludedRegions": ["<from CCOA detection in step 2 — e.g., eastus2, centralus>"],
         "buildId": null, "buildNumber": null, "r2dWorkItemId": null, "mergeBackPrId": null, "commitExcelUrl": null
       }
       ```
    e. Write `state.json` with 16 steps all `pending`, status `not-started`
    f. **Optional step skipping (per-release)**: Ask the release owner whether any steps should be skipped for THIS release only. Use `ask_user` with two choices: `Run all 16 steps (recommended)` and `Skip some steps`.
       - If they pick **Run all 16 steps** → continue to sub-step g. No state changes.
       - If they pick **Skip some steps**:
         1. Display the full 16-step table (same format as `status`):
            ```
            Step 1  send-reminder              ⬚ pending
            Step 2  cut-branch                 ⬚ pending
            Step 3  wait-build                 ⬚ pending
            Step 4  collect-commits            ⬚ pending
            Step 5  deploy-canary              ⬚ pending
            Step 6  bvt-check                  ⬚ pending
            Step 7  rollback                   ⬚ pending
            Step 8  post-rollback-bvt          ⬚ pending
            Step 9  post-rollback-signoff      ⬚ pending
            Step 10 roll-forward               ⬚ pending
            Step 11 post-rollforward-bvt       ⬚ pending
            Step 12 post-rollforward-signoff   ⬚ pending
            Step 13 create-r2d                 ⬚ pending
            Step 14 crb-review                 ⬚ pending
            Step 15 production-rollout         ⬚ pending
            Step 16 merge-back                 ⬚ pending
            ```
         2. Ask via `ask_user`: *"Which step numbers should be skipped for this release? Comma-separated (e.g., `7,8,9,10,11,12,16` to skip the rollback/roll-forward cycle and merge-back). Type `none` to run everything."*
         3. Validate the input:
            - Each number must be in 1–16. Reject and re-ask on invalid.
            - Refuse if the user tries to skip ALL steps (pipeline must run at least one step).
         4. Run the **same dependency-warning logic** as `modify skip` against the Step Dependency Matrix. For each requested skip, list any downstream steps that depend on it. Examples:
            - Skip 2 → warns Steps 3, 4, 5, 10, 13, 15, 16 (no branch, no build, no commits, no canary, no R2D, no rollout, no merge-back)
            - Skip 5 → warns Steps 6, 7 (nothing to BVT-check or roll back)
            - Skip 13 → warns Steps 14, 15 (no SafeFly R2D to approve or roll out)
            - Skip 6/9/12/14 → also warn that the human-review gate for that step is bypassed entirely
         5. Show the warnings inline and confirm via `ask_user`: *"Skip steps {list}? Downstream steps may fail without their inputs. Proceed?"* (choices: `Yes, skip these steps`, `No, let me re-pick`)
         6. On confirm, for each chosen step number `N`, update `state.json` via `Update-ReleaseState`:
            ```json
            "steps": {
              "N": { "status": "skipped", "reason": "setup-skip", "skippedAt": "<UTC ISO 8601>", "skippedBy": "<owner alias>" }
            }
            ```
         7. Append one row per skipped step to `audit.jsonl`: `{"action":"setup-skip-step","step":N,"actor":"<owner alias>","timestamp":"<UTC ISO>"}`
         8. Echo back: *"✅ Will skip Steps {list}. The other {16 - count} steps will run normally."*
       - **Note this is per-release only** — next month's `setup` starts fresh with all 16 steps `pending`. To skip steps mid-release later, use `skip N` or `modify skip N,N,N`.
    g. Initialize empty `audit.jsonl`
    h. Register Task Scheduler task via `Register-WatcherTask.ps1`

12. **Report status**: Display a summary table of all checks (tool, version, status), release parameters, CCOA exclusions, canary cluster mapping, and next steps. Tell the release owner to type `run` to start the release.

## Sub-commands

- `setup check` — Read-only. Render the readiness chain table (preflight / setupService / setup) but do NOT proceed past step 1. Useful for diagnosing why `run` is refusing to start.
- `setup skip <N,N,N>` — Re-enter step 11.f's per-release skip prompt against an existing release directory. Requires `release.json` and `state.json` to already exist. Re-runs the dependency-warning logic, updates `state.json`, and appends the audit rows. Does NOT touch any other state.

## Behavior Rule 13 interaction

If readiness gates show `setupService.status == 'incomplete'`, do NOT halt and tell the owner to type a separate command. Invoke `/setup-service group <lastGroup>` directly (the cascade described in Behavior Rule 13). Resume here at step 2 after the wizard returns `pass`.

All other environment / auth / tooling repair belongs to `/test-preflight`. `setup` only points the owner there — it never invokes `Test-PreFlight.ps1` itself.
