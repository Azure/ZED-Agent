# ZED-Agent — Zero Effort Deployment

ZED drives your service's **monthly production release** end-to-end: branch cut, build
wait, commit collection, canary deployment, BVT validation, production rollout, SafeFly
+ R2D filings, Teams/email notifications, and merge-back. You give short
acknowledgements (`ack`, `gate on/off`) — ZED does the orchestration, the file plumbing,
the notifications, and the audit trail.

ZED is **service-agnostic**. Every service-specific value lives in two committed JSON
files in *your* repo (`service-config.json` + `pipeline-catalog.json`). This repo ships
only the schemas, the scripts, and an installer that writes empty skeletons. There are no
hard-coded service names, paths, or pipeline IDs anywhere in the agent.

**Onboarding takes about 60–90 minutes**, most of it spent in the `setup-service` wizard
answering questions about your pipelines. Do it once per repo.

---

## Before you start

You need all of these on your machine. ZED runs on **Windows only** — it drives Outlook,
the Teams desktop client, and Microsoft Edge through local automation interfaces.

| Requirement | Check with | Notes |
|---|---|---|
| **PowerShell 7+** | `pwsh --version` | Some scripts run under 5.1, but 7 is required overall |
| **Git** | `git --version` | |
| **Azure CLI**, logged in | `az account show` | `az login --tenant microsoft.com` |
| **GitHub CLI**, logged in | `gh auth status` | |
| **Node.js + npm** | `node --version` | For the EV2 portal scrape |
| **ImportExcel** module | `Get-Module -ListAvailable ImportExcel` | `Install-Module ImportExcel -Scope CurrentUser` |
| **Outlook desktop** | — | Release emails are sent through it |
| **Teams desktop** | — | Notifications go through the local client |
| **Microsoft Edge** | — | Used to read EV2 rollout status for gov clouds |

You also need, for your service:

- An Azure DevOps **monthly release pipeline** and **EV2** for production rollout.
- **Permission to queue** those pipelines.
- Your **SafeFly** franchise/change-type/form IDs and your **EV2 service group** name.
  ZED will not guess these — see [Step 3](#step-3--configure-zed-for-your-service).

---

## Step 1 — Clone ZED and install its dependencies

```powershell
git clone https://github.com/gwazire_microsoft/ZED-Agent.git D:\ZED-Agent
cd D:\ZED-Agent

# One-time: installs playwright-core for the EV2 portal scrape.
# (No browser download — ZED attaches to your running Edge via CDP.)
cd .github\skills\zed-agent\scripts\EV2
npm install
cd D:\ZED-Agent
```

## Step 2 — Install ZED into your service repo

```powershell
pwsh -File .github\skills\zed-agent\scripts\Install-Zed.ps1 `
    -TargetRepoPath D:\repos\Mgmt-RecoverySvcs-MyService
```

Add `-WhatIf` first if you want to preview the file list without writing anything.

This copies into your repo:

- `.github/agents/ZedAgent.agent.md` — the agent entry point
- `.github/skills/zed-agent/` — scripts, schemas, queries, templates
- `.github/skills/setup-service/`, `setup/`, `test-preflight/`, `teams-chat/` — the
  supporting skills
- **Empty** `service-config.json` and `pipeline-catalog.json`, generated from the schemas

It skips `node_modules/`, `logs/`, and `.zed-agent/` runtime artifacts. The `zed-forge`
skill stays here in the source repo — it is a ZED development tool, not part of a release.

> **Re-installing:** `-Force` overwrites existing ZED files. It also **rewrites your two
> config files back to empty skeletons** — back them up first. See
> [Updating ZED](#updating-zed-later).

## Step 3 — Configure ZED for your service

Open **Copilot Chat in your service repo** (not in ZED-Agent) and run the wizard:

```
setup-service
```

It reads whatever you have already filled in, **skips every field that is already set**,
and prompts only for what is missing. It saves after every answer, so you can stop and
resume at any point:

```
setup-service group 4.3      # jump straight to one group
setup-service validate       # check what is still missing, no prompts
```

Groups run 1 → 10 (with 4.1–4.13 covering pipelines in detail). Expect the pipeline
groups to take the longest — that is where ZED learns your parameter shapes from prior
runs.

You can also type directly into `.github/skills/zed-agent/service-config.json` in VS
Code; the `$schema` reference gives you autocomplete and inline validation. Mix the two
approaches however you like.

**Two things ZED deliberately will not guess** — the wizard will ask, and `validate`
fails until they are set:

- `safefly.serviceGroupName` — your EV2 service group (e.g. `Backup (MAB)`). Filing an
  R2D against the wrong service group is worse than failing, so ZED refuses to infer it.
- `safefly.graphQlEndpoint` plus `franchiseId`, `changeTypeId`, `formId` — SafeFly's V1
  write API is permanently gone (HTTP 410), so ZED requires the V2 GraphQL configuration.

Repeat until clean:

```
setup-service validate
```

## Step 4 — Check your machine is ready

```
test-preflight
```

This reports three categories:

| Category | Meaning |
|---|---|
| **env** | Azure CLI, Git, PowerShell 7, ImportExcel, EV2 token, Teams CDP, skill scripts. **Must be green** — nothing works otherwise. |
| **config** | Your two JSON files. Red on a fresh clone; `setup-service` is the fix. |
| **release** | Per-release artifacts. Expected red until you run `setup`. Not a blocker yet. |

`test-preflight check` is the read-only variant. The default will offer to auto-remediate
what it can.

## Step 5 — Commit ZED into your repo

Most service repos gitignore `.github/`, so force-add:

```powershell
git add -f .github/agents/ZedAgent.agent.md .github/skills/
git commit -m "feat(zed): onboard ZED Agent"
```

Commit the two config files too — they are your service's source of truth, and ZED reads
them on every run.

## Step 6 — Run your first release

In Copilot Chat in your service repo:

```
setup        # per-release: release ID, owner, target month
```

Then hand over to the agent and let it walk the 16 steps, acknowledging as it goes. Useful
variants:

```
setup check           # read-only readiness status
setup skip 3,7        # re-enter the skip prompt for specific steps
```

The full step definitions and the per-step ack vocabulary live in
`.github/agents/ZedAgent.agent.md`.

---

## Command reference

Run these from Copilot Chat **in your service repo**, in this order the first time:

| Command | When | What it does |
|---|---|---|
| `test-preflight` | Any time | Checks machine + config readiness |
| `setup-service` | Once per repo | Fills `service-config.json` + `pipeline-catalog.json` |
| `setup-service validate` | Any time | Strict check, no prompts |
| `setup` | Once per release | Creates `.zed-agent/releases/<id>/` and `state.json` |

### Release-owner commands (during a release)

| Command | What it does |
|---|---|
| `help` / `status` | Command list / current step, gates, watcher state |
| `run` / `resume` | Start or continue the release (`resume` after a manual fix) |
| `ack [retry]` | Acknowledge a failure (optionally retry the failed step) |
| `skip` / `modify skip\|reset\|reorder N` | Skip the current step / change the step plan |
| `approve-bvt` · `approve-rollback` · `approve-rollforward` · `approve-crb` | Sign off the BVT / rollback / roll-forward / CRB gates |
| `approve-ri` | Go-ahead after the Reverse Integration PR (only with `ado.integration`) |
| `private-stamp` · `approve-private-stamp` · `private-stamp restore` | Private stamp upgrade inputs, sign-off, and redeploy without the queue override (only with `privateStampUpgrade`) |
| `revert-bits` · `approve-revert` | Revert bits selection and sign-off (only with `revertBits`) |
| `approvals` | Pending pipeline approvals (only with `operational.approvalWatchEnabled`) |
| `health status` · `health accept` · `health override` · `health backtest` … | Release health per deployment wave — GO / HOLD / NO-GO with RCA (only with `releaseHealth.enabled`) |
| `rebuild` · `new-stamp` | Re-queue the build / onboard or reclassify a stamp |
| `test` · `test-run` | Dry run, or a real run with steps skipped (pipelines cancelled at trigger) |
| `stop` · `teardown` | Pause the release and stop the watcher / post-release cleanup |

Full definitions: `.github/skills/zed-agent/reference/command-behaviors.md`.

---

## What ZED does — the 16 steps

A **watcher** (Windows scheduled task, `Release-Watcher.ps1`) polls pipelines, PRs, timers and
SafeFly between steps and re-invokes the agent when something changes, so the release keeps moving
without the owner watching it. All state is in `.zed-agent/releases/<id>/state.json` and every
action is written to `audit.jsonl`. Detailed behaviour: `.github/skills/zed-agent/reference/step-behaviors.md`.

| # | Step | What ZED does |
|---|---|---|
| 1 | Branch cut reminder | Emails + Teams the "*&lt;label&gt;* Release Branch Cut Reminder" N days before the cut |
| 2 | Cut release branch & queue build | Cuts `release/…` from the main branch and queues the official build. *Optional:* 2a/2b RI/FI integration PRs, 2c deploy-base build |
| 3 | Wait for build | Polls the official build until it succeeds |
| 4 | Commit details | Collects the commits since the last release into the commit Excel (new file per release, or one sheet in a shared tracker workbook), nudges authors to fill it in |
| 5 | Deploy canary | Triggers the canary pipelines with the release build; posts approval links |
| 6 | BVT check | Waits the BVT window (or runs BVT releases), runs the Kusto failure analysis, emails the results; owner `approve-bvt` |
| 7 | Rollback | Rolls canary back to the previous build (or to the revert bits build) |
| 8 | Post-rollback BVT | BVT on the rolled-back canary |
| 9 | Post-rollback sign-off | Owner `approve-rollback` |
| 10 | Roll-forward | Re-deploys the release build to canary via the production pipelines |
| 11 | Post-roll-forward BVT | BVT on the rolled-forward canary |
| 12 | Post-roll-forward sign-off | Owner `approve-rollforward` |
| 13 | SafeFly R2D | Derives deployment nature / SDP type / regions (CCOA exclusions) and files the SafeFly R2D |
| 14 | SafeFly approval + CRB | Polls the R2D approval, sends the CRB email; owner `approve-crb` |
| 15 | Production rollout | Triggers the EV2 managed production rollout, with stamp-inventory, payload and geography gates and rollout diagnostics |
| 16 | Merge-back PR | Opens the PR from the release branch back to the main branch |

Failures halt the step, email the owner (routing per `notifications.routing`) and wait for `ack`.

---

## Configuration and customization options

Everything a service does differently is a config value. **Every option below is off by default,
and off means the original ZED behaviour** — a service that does not set it (e.g. BDP) is
unaffected. `setup-service` asks about each one; the schemas
(`service-config.schema.json`, `pipeline-catalog.schema.json`) document every field.

### `service-config.json`

| Option | Off (default) | When enabled | BCM |
|---|---|---|---|
| `service.releaseLabel` | Messages say "BDP Release …" | Label used in reminder / commit request / nudge / CRB / step-failure messages | `"BCM"` |
| `releaseNaming` `{ prefix, sequenceSeparator }` | Release id = `YYYY-MM`, one release per month | Several releases per month (`BCM2610`, `BCM2610_2`, …); `setup` asks the name first and it is the release id everywhere (`{{releaseName}}`, `{{releaseNameLower}}` in templates) | prefix `BCM`, `_` |
| `defaultSkippedSteps` `{ "<step>": "<reason>" }` | All 16 steps run | Listed steps are written `skipped` in every release (`modify reset N` runs one anyway) | 11, 12 (Step 10 → Step 13) |
| `ado.integration` | Branch cut straight from the main branch | **Step 2a RI** (master → develop PR on a new branch, `preservePaths` kept from develop, conflicts resolved by newest commit per file) → owner `approve-ri` → **2b FI** (develop → master PR) → cut the release branch | enabled, `.config` preserved |
| `ado.releaseMode: "deploy-base"` | Canary/production deploy the official build | Step 2c queues a deploy-base build from the release branch and pipelines are pinned to it (`PinResources`) | `deploy-base` |
| `commitExcel.mode: "tracker"` (+ `commitExcel.tracker`) | New commit Excel file every release | Adds a sheet per release to one shared SharePoint workbook (columns / header style from config), polls fill % before Step 4 completes | tracker workbook |
| `revertBits` (`enabled`) | Step 7 rolls back to the previous build | Builds a revert-bits branch/PR (config files preserved), deploys it for the rollback; owner `approve-revert` | enabled |
| `revertBits.prepareDuringCanaryBvt` | Revert bits prepared at Step 7 | Prepared during the Step 6 BVT; Step 7 deploys at once after `approve-bvt`, Step 8 is the revert-bits BVT | `true` |
| `operational.approvalWatchEnabled` (+ `approvalPollIntervalSeconds`, `approvalReminderHours`, `approvalExpiryWarnHours`) | Approval links posted to Teams in Steps 5/7/10 | Approval watch: emails + Teams every waiting Approval Service / ADO approval, with reminders and an expiry warning (`approvals` command) | `true` |
| `operational.scheduleGuardPollIntervalSeconds` | — | Poll interval for `scheduleGuard` pipelines | set |
| `inventory.stampNaming` | Stamp reconciliation by exact name | SDS StampId ↔ Kusto stamp name mapping (partition suffixes, `{region}-{NN}` ids), cloud-scoped | set |
| `safefly.extendedRequest` | Original R2D builder (`New-SafeFlyRequest.Legacy.ps1`), V1 approval polling | Extended R2D: sectioned description (`descriptionSections`, `prUrlTemplate`, `payloadUrlTemplate`, …), `{titleThemes}`, `regionGroups`, `rollbackStrategy`, team-risk answers, tag GUIDs, content warnings; SafeFly V2 approval polling | `true` |
| `safefly.r2dBuildSource: "productionRun"` | R2D `ev2.build` = official build number | Step 13 triggers the production pipeline first (parked on its approval gates, requires `approvalGate.verified`) and files the R2D with that run's build number; Step 15 reuses the run | `productionRun` |
| `safefly.adoBuildLink` | No ADO build link | Adds the ADO build link answer to the R2D | set |
| `releaseHealth` `{ enabled, mode, skillPath }` + `notifications.groups.healthOnCall` | No post-deployment analysis | After every deployment wave (canary + each EV2 stage) a background check compares the new build with the previous build on the same stamps and with control stamps (outcomes, latency, error logs, CPU/memory, upgrade health), the agent adds RCA, and a **GO / HOLD / NO-GO** mail goes out (early warnings to the on-call group). Service-specific tables/queries/thresholds live in a service-owned skill (`.github/skills/<service>-release-health/`) scaffolded from `templates/service-health-skill/` by `setup-service group 11`. Modes `shadow` (owner only) / `advisory` / `acknowledge`. Spec: `reference/release-health.md` | enabled, `advisory`, `bcm-release-health` |

### `pipeline-catalog.json`

| Option | Off (default) | When enabled | BCM |
|---|---|---|---|
| `privateStampUpgrade` (`enabled`) | No private stamp test | Parallel to canary: asks the owner for the private stamp instance, two ports and the `WorkflowQueueName`, deploys the last and the current build (`ServiceOverrideSettings`), halts for the owner's private stamp BVT (`approve-private-stamp`, a join before Step 13) | pipeline 396863 |
| `privateStampUpgrade.restoreAfterSignOff` (+ `restoreServiceOverrideSettings`) | Sign-off ends the test; the stamp keeps the test's `WorkflowQueueName` override | After `approve-private-stamp`, redeploys both builds on the same ports **without** the queue override (pipeline default `ServiceOverrideSettings`), so the stamp returns to its original state and the ports don't share a TEE queue; does not delay Step 13 | `true` |
| `bvtReleases` `{ steps, releases, timeoutHours }` | 24 h BVT timer | Creates the configured classic BVT releases (with variables, e.g. `MABIsOfficial="True"`) at the listed steps and tracks them instead of waiting; the step fails if they have not finished within `timeoutHours` (default 12) | 40785 + 47437 at steps 6, 8; 15 h |
| `<canary\|production>.<key>.deploymentDoneWhen` `{ ev2StepStarted, portalLinkTask }` | Deployment done = pipeline run completed | Deployment done = the EV2 rollout reached `ev2StepStarted` (read from the EV2 portal link in `portalLinkTask`); the BVT starts without the ~24 h ManagedValidation wait, and later deployments wait for EV2 serialization | BCM-CANARY: `Canary-ManagedValidation` |
| `<canary>.<key>.scheduleGuard` | Pipeline's own schedule keeps running | Once ZED's Step 5 run succeeds, pauses the pipeline's own scheduled deployments (schedule variable off / UI schedule triggers removed / foreign runs cancelled) until Step 6 is signed off, then restores only what it changed | BCM-EACAN |
| `<canary\|production>.<key>.approvalGate` | — | Evidence that the pipeline deploys nothing before a human approval; required for `r2dBuildSource: productionRun` | BCM-PROD verified |
| `<key>.buildResource` + `artifactFeed` | — | Required with `ado.releaseMode: "deploy-base"`: the YAML build resource alias and feed used to pin every run to the release build | set |

### Fixes that apply to every service

These are bug fixes, not opt-in features:

- ADO tokens are requested for the Azure DevOps AAD application id (`Get-AzToken`, `Get-PipelineApprovalLinks`).
- `Update-ReleaseState` accepts dictionary state and adds missing properties instead of failing.
- The Step 15 geography-coverage gate no longer flips the step back to in-progress, and `regions(*)` (which always failed the gate) is treated as all regions.

## Per-repo vs per-release

| Scope | Command | Output | Commit it? |
|---|---|---|---|
| Per repo (one-time) | `setup-service` | `service-config.json`, `pipeline-catalog.json` | **Yes** |
| Per release | `setup` | `.zed-agent/state.json` | No — local only, gitignored |

## Updating ZED later

New fixes land on `main` here. To pull them into your service repo:

```powershell
# 1. Back up your configs — -Force overwrites them with empty skeletons
copy D:\repos\MyService\.github\skills\zed-agent\service-config.json    $env:TEMP\
copy D:\repos\MyService\.github\skills\zed-agent\pipeline-catalog.json  $env:TEMP\

# 2. Update and reinstall
cd D:\ZED-Agent; git pull
pwsh -File .github\skills\zed-agent\scripts\Install-Zed.ps1 `
    -TargetRepoPath D:\repos\MyService -Force

# 3. Restore your configs, then review the diff before committing
copy $env:TEMP\service-config.json    D:\repos\MyService\.github\skills\zed-agent\
copy $env:TEMP\pipeline-catalog.json  D:\repos\MyService\.github\skills\zed-agent\
```

Then re-run `setup-service validate` to confirm nothing regressed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `setup-service validate` keeps failing | Run `setup-service group <N>` for the group it names, rather than restarting the whole wizard |
| ADO calls return 404 on `dev.azure.com` | Known `msazure/One` quirk — ZED automatically retries against `visualstudio.com` |
| YAML fetch 404s despite the repo existing | ADO repo-id/name mismatch. Pass `-LocalRepoRoot <path-to-clone>` to `Read-PipelineYaml.ps1` to read from disk instead |
| SafeFly filing rejected with HTTP 410 | V1 API is retired — set the `safefly.graphQlEndpoint` V2 fields |
| EV2 status blank for Fairfax/Mooncake | Edge CDP is not up; `test-preflight` reports and can fix this |
| Teams messages not sending | Teams desktop must be running before ZED starts |

---

## What's in this repo

```
.github/
├── agents/
│   ├── ZedAgent.agent.md       # Release agent — entry point in your repo
│   └── ZedForge.agent.md       # Meta-agent that improves ZED (stays here)
└── skills/
    ├── zed-agent/              # Core skill
    │   ├── SKILL.md
    │   ├── service-config.schema.json    # Drives VS Code IntelliSense
    │   ├── pipeline-catalog.schema.json
    │   ├── scripts/            # ~74 PowerShell scripts
    │   │   ├── Install-Zed.ps1
    │   │   ├── lib/            # Shared modules (parameter model, loaders)
    │   │   ├── EV2/            # Edge CDP + Playwright EV2 portal scrape
    │   │   └── SafeFly/        # SafeFly V2 request submission
    │   ├── queries/            # KQL: BVT failures, deployment units, stamp inventory
    │   ├── reference/          # Step behaviour specs
    │   ├── templates/          # Email + Teams templates
    │   ├── fixtures/           # Test fixtures
    │   └── tests/              # Pester tests
    ├── setup-service/          # One-time onboarding wizard  ─┐
    ├── setup/                  # Per-release initialization   ├─ installed into your repo
    ├── test-preflight/         # Readiness checks             │
    ├── teams-chat/             # Teams messaging             ─┘
    └── zed-forge/              # ZED's own dev loop (source-repo only)
```

No `service-config.json` or `pipeline-catalog.json` lives here — the installer generates
empty skeletons from the schemas, and real values belong in your repo.

## Compatibility

- **Repos**: any service repo with a monthly Azure DevOps release pipeline that uses EV2
  for production rollout.
- **OS**: Windows only (Outlook COM, Teams CDP, Edge CDP).
- **Shell**: PowerShell 7+ (`pwsh`).

## Contributing to ZED

This repo is the upstream source of truth.

1. Make your change here and run the tests:
   ```powershell
   Invoke-Pester -Path .github\skills\zed-agent\tests
   ```
2. Push to `main`.
3. In each consuming repo, re-run `Install-Zed.ps1 -Force` and review the diff before
   committing.

Keep it service-agnostic: no service names, pipeline IDs, region lists, or paths in
scripts or skills. Everything service-specific belongs in the two JSON files. The two
config files in this repo stay empty — never push service data here.

### ZedForge — self-improving development agent

`ZedForge` (`.github/agents/ZedForge.agent.md` + `.github/skills/zed-forge/`) hardens ZED
through an autonomous **fix → validate → harvest** loop:

1. Implements pending **learnings** (`zed-forge/learnings/learnings.md`) as edits to ZED.
2. Seeds a target deployment repo with the latest ZED + pre-filled `config-seed/` configs.
3. Runs a **true test run** — every pipeline triggered then cancelled within seconds,
   capturing posted parameters to `test-run-capture.json`.
4. Verifies captured parameters and step outcomes against
   `requirements/success-criteria.json`.
5. Harvests new learnings from failures and loops until clean.

Two intake files, two meanings: **requirements** = the end state (never weakened);
**learnings** = the backlog to implement. Start it from Copilot Chat in this repo with
`@ZedForge start`.

## License

No `LICENSE` file has been added yet — add your preferred license (Microsoft-managed
repos typically default to MIT or the org's standard internal license).
