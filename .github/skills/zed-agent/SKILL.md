# ZED Agent Skills

This directory contains PowerShell skill scripts for the **ZED Agent** — an agentic framework that automates the Azure Backup monthly production release. Service-specific configuration is loaded from `service-config.json` and `pipeline-catalog.json`.

## Skills

| Script | Purpose | ~LOC |
|--------|---------|------|
| `Update-ReleaseState.ps1` | Read/write `state.json` with `.bak` safety and audit logging | 40 |
| `Expand-Template.ps1` | Mustache-style `{{variable}}` template rendering with conditional blocks | 25 |
| `Send-TeamsMessage.ps1` | Send HTML messages to Teams chats via CDP + Skype token (replaces Power Automate webhooks) | 115 |
| `New-CommitExcel.ps1` | Generate `.xlsx` commit detail spreadsheet via ImportExcel | 50 |
| `Upload-ToSharePoint.ps1` | Upload files to SharePoint/OneDrive via Graph API | 40 |
| `Register-WatcherTask.ps1` | Register/unregister Windows Task Scheduler task for restart recovery | 30 |
| `Release-Watcher.ps1` | Background poller that bridges async gaps by re-invoking the agent | 80 |
| `Test-PreFlight.ps1` | Pre-flight readiness checks for environment and configuration | 60 |
| `Add-Learning.ps1` | Append a learning entry to `learnings.md` | 45 |
| `Get-Learnings.ps1` | Read/filter learnings (unapplied, by category, by release) | 40 |
| `Apply-Learning.ps1` | Mark a learning as applied and record which files changed | 45 |
| `Get-RegionMapping.ps1` | Parse deployment config to extract region mappings (source of truth) | 60 |
| `EV2/Get-Ev2RolloutStatus.ps1` | Query EV2 rollout status — REST API for Prod, Edge portal scraping for gov-clouds | 300 |
| `EV2/Invoke-Ev2PortalScrape.js` | Node.js scraper: intercepts EV2 portal XHR for Fairfax/Mooncake rollout data | 170 |
| `EV2/Ensure-EdgeCDP.ps1` | Ensure Edge CDP is running on port 9222, install playwright-core if missing | 70 |
| `EV2/Show-Ev2Dashboard.ps1` | Render rich terminal dashboard for all pipelines × all clouds | 230 |
| `Install-Zed.ps1` | Scaffolds the ZED skeleton into a new repo (templates, scripts, agent.md). | 200 |

## Onboarding ZED to a New Repo

ZED uses a single command and a single flow — no separate "wizard mode" vs "manual mode". The two configuration files (`service-config.json` and `pipeline-catalog.json`) ship empty in the skeleton, and the release owner populates them in whatever mix of by-hand and wizard-prompted feels easiest.

### Step 1 — Drop the skeleton into the target repo

```powershell
# From the source ZED repo (or a clone of the standalone ZED repo, when it exists):
pwsh -File .github/skills/zed-agent/scripts/Install-Zed.ps1 `
     -TargetRepoPath D:\repos\Mgmt-RecoverySvcs-MyService
```

`Install-Zed.ps1` copies `ZedAgent.agent.md` plus the entire `.github/skills/zed-agent/` directory (scripts, schema, queries, templates), and writes the two configuration files **empty** in the target — embedded skeletons inside the script ensure they're empty regardless of what the source repo had.

### Step 2 — Populate the two config files (any mix works)

In the target repo, both files now exist at:

- `.github/skills/zed-agent/service-config.json`
- `.github/skills/zed-agent/pipeline-catalog.json`

Choose any mix of:

- **Pre-fill in VS Code** — open the files and type. The `$schema` reference in `service-config.json` gives IntelliSense + autocomplete + inline validation. `pipeline-catalog.json` includes a removable `_examples` block showing the expected shape.
- **Run the wizard** — `@ZedAgent setup-service` in Copilot Chat. The agent reads whichever file(s) you've started, **skips every field that's already filled**, and only prompts for what's still empty.
- **Validate any time** — `@ZedAgent setup-service validate` runs the loader in strict mode and reports any missing or invalid fields.

When `setup-service validate` reports green, force-add and commit:

```powershell
git add -f .github/agents/ZedAgent.agent.md .github/skills/zed-agent/
git commit -m "feat(zed): onboard ZED Agent"
```

### What's per-repo (one-time) vs per-release

- **One-time per repo** — `setup-service` (or hand-edits): produces `service-config.json` + `pipeline-catalog.json`, both committed to the repo.
- **Every release** — `setup`: prompts for release-specific values (release ID, release owner, target month) and writes them to local-only `.zed-agent/state.json`.

## Region Mapping (Source of Truth)

The `Get-RegionMapping.ps1` script fetches `AzureServiceConfig.json` from the region source-of-truth repo configured in `service-config.json` (`regions.ascRepo`, `regions.ascPath`, `regions.ascBranch`) via ADO Git Items API. This is the deployment-region source of truth for the service.

```powershell
# All regions across all 5 deployment clouds + supplementary SafeFly regions (~170 regions)
.\.github\skills\zed-agent\scripts\Get-RegionMapping.ps1 -AllClouds

# All clouds minus CCOA exclusions → SafeFly targetedRegions
.\.github\skills\zed-agent\scripts\Get-RegionMapping.ps1 -AllClouds -ExcludeRegions @("eastus2", "westeurope")

# Single cloud only
.\.github\skills\zed-agent\scripts\Get-RegionMapping.ps1 -CloudName Fairfax

# Force fresh fetch (bypass 24h cache)
.\.github\skills\zed-agent\scripts\Get-RegionMapping.ps1 -ForceRefresh
```

Returns objects with: `DataCenterName` (SafeFly display name), `RegionShortName` (Azure/CCOA short name), `StampPrefix` (abbreviation or "supplementary"), `StampCount`, `Ev2Geography` (geography grouping), `DatacenterType` (ACTIVE/PASSIVE classification).

**Source**: `Mgmt-RecoverySvcs-DeploymentExtn/src/DeploymentInfra/EV2DeploymentEngine/SchemaInput/AzureServiceConfig.json`
**Cache**: `$env:TEMP\zed-asc-cache.json` (24h TTL, stale-on-error)

## Configuration

- `pipeline-catalog.json` — Pipeline definitions (officialBuild + 4 canary + 4 production with full template parameters)
- `scripts/SafeFly/SAFEFLY-API-REFERENCE.md` — Complete SafeFly R2D API reference: all fields, enums, valid values (from [OpenAPI spec](https://www.safefly.azure.com/swagger/v1/swagger.json))

### Email Recipients (Reminder — Step 1)

Notification recipients are configured in `service-config.json → notifications.groups`.

**To add or remove recipients:**
Edit the notification groups in `service-config.json`.

During `setup`, the release owner is prompted: *"Any additional email recipients for the reminder?"*
Responses are stored in `release.json → additionalRecipients`. At Step 1 execution, permanent + additional are merged.

### Reminder Email Template Variables

The `templates/reminder-email.html` template requires these variables (computed by the agent at Step 1):

| Variable | Source | Description |
|----------|--------|-------------|
| `releaseId` | `release.json` | e.g., `2026-04` |
| `releaseLabel` | `service-config.json → service.releaseLabel`, default `BDP` (filled automatically by `Expand-Template` — do not pass) | e.g., `BCM` — used in the title and sign-off |
| `branchCutDate` | `release.json → dates.branchCut` | Code freeze date |
| `baseBranch` | Agent Domain Knowledge (ADO Infrastructure) | `develop` |
| `branchName` | `release.json → currentBranch` | e.g., `{CONFIG[ado.branchPrefix]}2604` |
| `releaseOwnerName` | `release.json → releaseOwner.name` | Release owner display name |
| `releaseOwnerEmail` | `release.json → releaseOwner.email` | Release owner email |
| `dateNotification` | `today()` | Date the email is sent |
| `dateBuild` | `T + 3` | Build date |
| `dateCanary` | `T + 3` | Canary deployment |
| `dateCRB` | `T + 6` | CRB review |
| `dateR2D` | `T + 7` | R2D creation |
| `dateLowGeos` | `T + 7` | Low-traffic geos |
| `dateMidGeos` | `T + 8` | Mid-traffic geos |
| `dateHighGeos` | `T + 9` | High-traffic geos |
| `dateDay1` | `T + 10` | Day 1 region |
| `dateDay2` | `T + 11` | Day 2 region + FF & MC day 1 |
| `dateDay3` | `T + 12` | Day 3 region + FF & MC day 2 |
| `dateDay4` | `T + 13` | Day 4 region + FF & MC day 3 |
| `dateDay5` | `T + 14` | FF & MC day 4 |

**T = notification date (today).** All dates formatted as `ddd, MMM d yyyy` (e.g., `Thu, Apr 2 2026`).

### Setup Prechecks

**Test email:** Email transport is Mail MCP only (no Outlook, no SMTP fallback). The agent itself invokes the `SendEmailWithAttachments` MCP tool during `setup` action 10 to verify the MCP server is registered and authenticated — `Test-PreFlight.ps1` does not probe email at all.

### Teams Notifications (CDP + Skype Token)

Teams messages are sent via Chrome DevTools Protocol (CDP) to extract a Skype token from the running Teams desktop client, then posted as `RichText/Html` messages through the Skype messaging API.

**Prerequisites:**
- Teams desktop must be running with CDP enabled (`--remote-debugging-port=9222`)
- During `setup`, the agent auto-discovers conversation IDs via `Find-TeamsChat`

Conversation IDs are stored in `secrets.json` under `teamsChats`. Notification routing rules are configured in `service-config.json → notifications.routing`.

| Routing key | Email | Teams messages |
|-------------|-------|----------------|
| `reminder` | ✉️ permanent recipients | 💬 configured Teams chats |
| `build-status` | ✉️ Release owner only | — |
| `commit-request` | ✉️ permanent recipients | 💬 configured Teams chats |
| `canary-status` | ✉️ permanent recipients | — |
| `bvt-check` | 🔲 TBD | 🔲 TBD |
| `bvt-signoff` | 🔲 TBD | 🔲 TBD |
| `rollback-status` | ✉️ permanent recipients | — |
| `post-rollback-bvt` | 🔲 TBD | 🔲 TBD |
| `post-rollback-signoff` | 🔲 TBD | 🔲 TBD |
| `rollforward-status` | ✉️ permanent recipients | — |
| `post-rollforward-bvt` | 🔲 TBD | 🔲 TBD |
| `post-rollforward-signoff` | 🔲 TBD | 🔲 TBD |
| `create-r2d` | ✉️ permanent recipients | — |
| `crb-review` | 🔲 TBD | 🔲 TBD |
| `production-rollout` | ✉️ permanent recipients | — |
| `ev2-failure-report` | ✉️ permanent recipients + release owner | 💬 configured Teams chats |
| `merge-back` | — | — |

### Pipeline Configuration

Pipeline definitions are configured in `pipeline-catalog.json`.

- **Official Build**: Defined in `pipeline-catalog.json → officialBuild`
  - `sourceBranch` = `refs/heads/{{currentBranch}}` — the actual release branch (unlike canary/prod which use `refs/heads/develop`)
  - Parameters: `CloudBuildQueue` (static), `debug` (False)
- **Canary pipelines**: Deploy current release bits to canary regions
- **Production pipelines**: Deploy with production pipeline after R2D approval

Rollback reuses the canary pipelines with previous production bits (no dedicated rollback pipeline).

**Pipeline selection** is config-driven via `pipeline-catalog.json → canaryRouting` and `productionRouting`:
- `mode: "static"` (default) — the agent triggers ALL pipelines under `canary.*` (or `production.*` for Step 10) in parallel. Use this when each pipeline is region-scoped.
- `mode: "cluster-type"` — the agent queries Kusto at runtime to determine which cluster types (e.g., SFMC vs SFRP) exist in canary regions, and only triggers the matching pipelines via `clusterTypeMap`.

#### Canary Pipeline IDs & Parameters

Each pipeline in `pipeline-catalog.json → canary` has:
- `name` — ADO pipeline name
- `id` — ADO pipeline definition ID (used in REST API)
- `sourceBranch` — always `refs/heads/develop` (pipeline YAML lives on develop)
- `templateParameters` — full parameter payload ready for ADO `POST /_apis/build/builds`

Pipeline IDs, names, regions, and parameter differences are all defined in `pipeline-catalog.json`.

**Key parameter differences (cluster-type routing example, e.g., PROT):**
- **SFMC** pipelines: `CanaryScript=True`, stamps include both ecy+ccy, SFMC macros (`__SFMCPostfix__`, `__UnitName__`), `CustomResourceTemplates` with SFMC templates
- **SFRP** pipelines: `CanaryScript=false`, stamps only ecy (ccy has no SFRP), no SFMC macros, no custom templates
- For region-scoped (`mode: "static"`) catalogs, parameter shape is whatever the service author defined per entry — the agent passes `templateParameters` through verbatim.
- All parameter details (Resources, OverrideResourceParameters, stamps) are defined per-pipeline in `pipeline-catalog.json`

**Dynamic substitution:** `ArtifactsBranch = "{{currentBranch}}"` → replaced at runtime with the release branch from `release.json → currentBranch`. In `ado.releaseMode = "deploy-base"` (e.g. BCM) `currentBranch` is the deployment branch itself (e.g. `master`) and every run ALSO carries `resources.builds.<buildResource>.version` from `Resolve-ReleaseBuild.ps1 -Action PinResources` so it deploys the exact release build (see `reference/step-behaviors.md → Step 5 Action 2`).

#### How the agent triggers the official build

```powershell
# Official build uses the RELEASE BRANCH as sourceBranch (not develop)
# Pipeline details from pipeline-catalog.json → officialBuild
$branch = $release.currentBranch  # e.g., "releases/svc2604"

$body = @{
    definition = @{ id = $catalog.officialBuild.id }  # from pipeline-catalog.json
    sourceBranch = "refs/heads/$branch"  # refs/heads/releases/svc2604
    templateParameters = @{ CloudBuildQueue = "CloudBuild-BVT"; debug = "False" }
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "https://dev.azure.com/$org/$project/_apis/build/builds?api-version=7.1" `
    -Method Post -Headers $headers -Body $body -ContentType "application/json"
```

#### How the agent triggers a canary/production pipeline

```powershell
# Canary/production pipelines use refs/heads/develop as sourceBranch (YAML lives there)
# but ArtifactsBranch points to the release branch (where built bits are)
# Pipeline details from pipeline-catalog.json
$catalog = Get-Content "pipeline-catalog.json" -Raw | ConvertFrom-Json
$pipeline = $catalog.canary.'<canary-pipeline-key>'  # e.g., $catalog.canary.'SVC-SFMC' or $catalog.canary.'DM-EACAN'
$branch = $release.currentBranch  # e.g., "releases/svc2604"

$params = $pipeline.templateParameters.PSObject.Copy()
$params.ArtifactsBranch = $branch

$body = @{
    definition = @{ id = $pipeline.id }
    sourceBranch = $pipeline.sourceBranch  # refs/heads/develop
    templateParameters = $params
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "https://dev.azure.com/$org/$project/_apis/build/builds?api-version=7.1" `
    -Method Post -Headers $headers -Body $body -ContentType "application/json"
```

#### How the agent cancels a pipeline run

```powershell
# PATCH the build status to "cancelling"
$body = '{"status":"cancelling"}'
Invoke-RestMethod -Uri "https://dev.azure.com/$org/$project/_apis/build/builds/$buildId?api-version=7.1" `
    -Method Patch -Headers $headers -Body $body -ContentType "application/json"
```

Used during: rollback (cancel stuck canary runs), abort scenarios, or re-trigger after parameter fix.

### EV2 Rollout Diagnostics (Step 15 — Phase 2)

After production pipelines complete (or fail), the agent queries EV2 for per-region rollout status, identifies failed datacenters, and suggests remediation actions.

**Multi-cloud routing**:
- **Prod/Public** → Direct EV2 REST API (fast, no browser needed)
- **Fairfax/Mooncake** → Edge portal scraping via CDP (REST API unreachable from CorpNet)

**Scripts**:
| Script | Purpose |
|--------|---------|
| `scripts/EV2/Get-Ev2RolloutStatus.ps1` | Main entry point — routes by cloud |
| `scripts/EV2/Invoke-Ev2PortalScrape.js` | Node.js portal scraper (network interception) |
| `scripts/EV2/Ensure-EdgeCDP.ps1` | Ensures Edge CDP on port 9222 + playwright-core |
| `scripts/EV2/Show-Ev2Dashboard.ps1` | Aggregated terminal dashboard for all rollouts |

```powershell
# Prod cloud — uses REST API directly
$status = .\.github\skills\zed-agent\scripts\EV2\Get-Ev2RolloutStatus.ps1 `
    -BuildId 12345678 `
    -ServiceGroup "Microsoft.Azure.Backup.Example.ACTIVE"

# Gov-cloud — automatically uses Edge portal scraping
$status = .\.github\skills\zed-agent\scripts\EV2\Get-Ev2RolloutStatus.ps1 `
    -RolloutId "ae012682-77a9-40fb-8e4f-5062ea2b63c5" `
    -ServiceGroup "Microsoft.Azure.Backup.Example.ACTIVE" `
    -RolloutInfra Fairfax

# Check results (same format for all clouds)
$status.failedNodes    # DCs that failed with error details
$status.suggestedActions  # Actionable remediation suggestions
$status.portalUrl      # Direct link to EV2 portal for this rollout
```

**Gov-cloud scraping approach**:
The portal at `ra.ev2portal.azure.net` proxies gov-cloud API calls through its own backend. The scraper intercepts the portal's XHR response (raw JSON, same structure as REST API) rather than parsing rendered HTML. This makes it immune to UI redesigns. Falls back to DOM text extraction if interception fails.

**Prerequisites** (auto-handled, no manual steps):
- Microsoft Edge running with user's Microsoft auth session (always true on work laptops)
- Node.js on PATH (for the scraper script)
- `Ensure-EdgeCDP.ps1` auto-launches Edge CDP and installs `playwright-core` if needed

**ServiceGroup mapping**: EV2 service group mappings are configured in `pipeline-catalog.json → ev2ServiceGroups`.

> **⚠️ Shared ServiceGroup note:** Some pipelines may share the same ServiceGroup. Always query by **BuildId or RolloutId** (unique per pipeline run) — never by ServiceGroup alone — to avoid mixing rollout data. Any future "list rollouts" feature must filter by BuildId or rollout naming convention.

**Auth**:
- Prod: `az account get-access-token --resource "https://azureservicedeploy.msft.net"`
- Fairfax/Mooncake: Edge browser session (MSAL token via portal)

**API**: `GET https://azureservicedeploy.msft.net/api/rollouts/{rolloutId}?servicegroupname={sg}&api-version=2016-07-01&embed-detail=true`
**Portal**: `https://ra.ev2portal.azure.net/#/rollouts/{Infra}/{ServiceTreeId}/{SG}/{RolloutId}`

**Watcher handler**: `poll-ev2-rollout` in `Release-Watcher.ps1` — iterates over pipeline targets, calls `Get-Ev2RolloutStatus.ps1` for each, stores diagnostics in `state.json → ev2Diagnostics`.

**Failure template**: `templates/ev2-failure-report-message.html` — Teams notification with failed DCs, errors, suggested fixes, and portal link.

### Kusto Configuration

| Setting | Value |
|---------|-------|
| Cluster | `CONFIG[kusto.canary.cluster]` (from service-config.json) |
| Database | `CONFIG[kusto.canary.database]` (from service-config.json) |
| Auth | `az account get-access-token --resource "https://kusto.kusto.windows.net"` |

**Detection logic** (only when `pipeline-catalog.json → canaryRouting.mode == "cluster-type"` or `productionRouting.mode == "cluster-type"`): the agent runs the canary deployment-units Kusto query, parses the DeploymentUnit suffix (e.g., `-sfmc`, `-sf`), and routes via the catalog's `clusterTypeMap`. For `mode == "static"` (default), no Kusto detection is performed and ALL canary/production pipelines are triggered.

Used in Steps 5 (canary), 7 (rollback), 10 (roll-forward), and 15 (production rollout).

## Templates

Located in `templates/`:
- **Adaptive Cards** (`.json`): — *removed; HTML messages used instead via CDP + Skype API*
- **HTML Messages** (`.html`): All Teams notifications now use HTML templates sent via `Send-TeamsMessage.ps1`
- **HTML Email** (`.html`): r2d-email, crb-email, reminder-email, step-failure-email, missed-schedule-email

## Usage

Skills are invoked by the ZED Agent via shell tool. Dot-source for function access:

```powershell
. ".github/skills/zed-agent/scripts/Update-ReleaseState.ps1"
Update-ReleaseState -ReleaseId "2026-04" -Action read
```

## Workflow

Release owner flow: `setup` → `run` → (approve) → `teardown`

- **`setup`** — Does ALL initialization:
  1. Checks prerequisites (tools, modules)
  2. Creates `.zed-agent/` directory, updates `.gitignore`
  3. Collects secrets (repo path, Teams chat IDs), auto-detects tenant/SharePoint
  4. Writes `environment.json` and `secrets.json`
  5. Asks for release parameters (branch names, cut date)
  6. Creates `releases/{id}/release.json`, `state.json`, `audit.jsonl`
  7. Registers watcher Task Scheduler task
  8. Runs pre-flight validation (`Test-PreFlight -ReleaseId {id}`)
  9. **Reviews unapplied learnings** — runs `Get-Learnings.ps1 -Unapplied`, presents to release owner for review. Release owner approves/rejects each. Approved learnings are applied via `Apply-Learning.ps1`.
  10. Reports full readiness summary

- **`run`** — Execute-only. Picks up from `state.json` and runs steps. Fails if no release exists (must run `setup` first).

## Release Flow Summary (16 steps)

1. Send reminder
2. Cut branch & queue official build
3. Wait for build (watcher polls every 10 min)
4. Collect commits → Excel → SharePoint (watcher polls Excel completion every 30 min)
5. Deploy canary (canary pipelines → EACan, ECY, CCY)
6. BVT check (24h wait, then Kusto failure analysis)
7. Rollback (canary pipelines with `previousBranch` bits → EACan, ECY, CCY)
8. Post-rollback BVT (24h wait, then Kusto failure analysis)
9. Post-rollback sign-off (`approve-rollback`)
10. Roll-forward (PROD pipelines → canary regions) — validates prod pipeline path
11. Post-roll-forward BVT (24h wait, then Kusto failure analysis)
12. Post-roll-forward sign-off (`approve-rollforward`)
13. Create SafeFly R2D (automated via `New-SafeFlyRequest.ps1`)
14. Wait for SafeFly approval + CRB review (watcher polls SafeFly every 60 min + `approve-crb`)
15. Production rollout — trigger production pipelines, EV2 manages staged rollout via SDP nodes
16. Merge-back PR

**Failure notification:** Steps 1–5, 7, 10, 15 → email to release owner only.
**Missed schedule:** If Step 15 watcher misses a scheduled deployment by >30 min → email to release owner.

## Runtime Files

**Durable state** at `.zed-release/` (committed to the release branch — survives across cloud sessions):
- `releases/{id}/release.json` — Release configuration (owner, branches, dates)
- `releases/{id}/state.json` — Current release state (steps, directives, atomicity fields)
- `releases/{id}/audit.jsonl` — Append-only machine audit log
- `releases/{id}/audit.md` — Human-readable audit log (auto-generated)

**Scratch data** at `.zed-agent/` (gitignored — local only):
- `environment.json` — Local environment paths
- `secrets.json` — Teams chat IDs (deleted by `teardown`)
- `releases/{id}/state.json.lock` — Cross-process file lock
- `readiness.json` — Preflight check results
- `watcher.lock` — Watcher singleton lock

Path resolution: `Resolve-StatePaths.ps1` checks `.zed-release/` first (cloud/durable),
falls back to `.zed-agent/` (local). Use `-PreferDurable` to create the durable structure.

## Learning System

ZED captures insights from each release cycle and applies them to future releases.

### How it works

```
Release N: Release owner corrects agent or failure reveals an insight
    → Add-Learning.ps1 appends to learnings.md
    ↓
Release N+1: setup step 9 → "3 unapplied learnings found"
    → Release owner reviews each: approve or skip
    ↓
Approved: Agent identifies which files to change, shows diff preview
    → Release owner confirms → files updated → Apply-Learning.ps1 marks applied
```

### Files

| File | Location | Purpose |
|------|----------|---------|
| `learnings.md` | `.github/zed-agent/` | Append-only learning store (persists across releases) |
| `Add-Learning.ps1` | `.github/skills/zed-agent/` | Append a new learning entry |
| `Get-Learnings.ps1` | `.github/skills/zed-agent/` | Read/filter learnings |
| `Apply-Learning.ps1` | `.github/skills/zed-agent/` | Mark learning as applied with file references |

### Entry format

```json
{"id":"L001","date":"2026-04-05","releaseId":"2026-04","category":"pipeline","learning":"SFRP pipelines should set CanaryScript=false — ea-can has no SFRP clusters","source":"owner-correction","applied":false}
```

### Categories

| Category | Examples |
|----------|----------|
| `pipeline` | Wrong parameters, missing pipeline, trigger order |
| `process` | Steps should be parallel, gate logic change |
| `infrastructure` | Region/cluster topology changes |
| `notification` | Wrong recipients, missing Teams channel |
| `parameter` | Config value corrections |
| `config` | Schema changes, new fields needed |

### When to capture a learning

The agent captures a learning when:
- **Release owner corrects the agent** — "No, that parameter should be X not Y"
- **Pipeline failure reveals a root cause** — wrong stamp, missing macro
- **Agent discovers something new** — Kusto query shows infrastructure changed
- **Process change** — "From now on, step 4 and 5 run in parallel"

**Do NOT capture** routine operations, status checks, or confirmations.
