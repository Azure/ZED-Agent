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
