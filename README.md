# ZED-Agent — Zero Effort Deployment

ZED-Agent is a hybrid AI + PowerShell automation that drives a service team's
**monthly production release** end-to-end: branch cut, build wait, commit
collection, canary deployment, BVT validation, rollout, SafeFly + R2D filings,
notifications, and merge-back. The release owner gives short slash-style
acknowledgements (`ack`, `gate on/off`) — ZED handles the orchestration, the
file plumbing, the email/Teams notifications, and the audit trail.

It is **service-agnostic**. Every service-specific value lives in two committed
JSON files (`service-config.json` + `pipeline-catalog.json`) — no hard-coded
service names, paths, or pipeline IDs anywhere in the agent or its scripts.

## What's in this repo

```
.github/
├── agents/
│   └── ZedAgent.agent.md          # The agent prompt (entry point for Copilot Chat)
└── skills/
    └── zed-agent/
        ├── SKILL.md               # Skill overview + variable reference
        ├── service-config.json    # Empty skeleton — populated per target repo
        ├── service-config.schema.json   # JSON Schema (drives VS Code IntelliSense)
        ├── pipeline-catalog.json  # Empty skeleton — populated per target repo
        ├── queries/               # KQL queries (BVT failure detection)
        ├── scripts/               # 21 production PowerShell scripts
        │   ├── Install-Zed.ps1    # Copies the skeleton into a target repo
        │   ├── EV2/               # Edge CDP + Playwright EV2 portal scrape
        │   └── SafeFly/           # SafeFly request submission
        ├── templates/             # Email + Teams notification templates
        └── tests/                 # Pester tests
```

No service-specific data ships with this repo — both JSON files are empty.

## Installing ZED into a target service repo

### 1. Clone this repo locally

```powershell
git clone https://github.com/gwazire-microsoft/ZED-Agent.git D:\ZED-Agent
cd D:\ZED-Agent
```

### 2. Install Node dependencies (one-time, for EV2 portal scrape)

```powershell
cd .github\skills\zed-agent\scripts\EV2
npm install
cd ..\..\..\..\..
```

This installs `playwright-core` locally. (The Playwright browser itself is not
needed — ZED talks to a running Microsoft Edge instance via CDP.)

### 3. Run the installer against your target repo

```powershell
pwsh -File .github\skills\zed-agent\scripts\Install-Zed.ps1 `
    -TargetRepoPath D:\repos\Mgmt-RecoverySvcs-MyService
```

The installer:

- Copies `ZedAgent.agent.md` into `<target>/.github/agents/`
- Copies the entire `zed-agent/` skill (scripts, schema, queries, templates) into `<target>/.github/skills/`
- Writes **empty** `service-config.json` and `pipeline-catalog.json` into the target — even if some other service's values exist in the source clone
- Skips `node_modules/` and runtime artifacts

Pass `-Force` to overwrite existing ZED files in the target.

### 4. Configure for the target service

Inside the target repo, populate the two empty JSON files. You have three options
(mix them however you like):

- **Pre-fill in VS Code** — open `service-config.json` and start typing. The
  `$schema` reference gives autocomplete + inline validation. `pipeline-catalog.json`
  has a removable `_examples` block showing the expected entry shape.
- **Run the wizard** — open Copilot Chat in the target repo and say
  `@ZedAgent setup-service`. The agent reads what you've already typed,
  **skips every field that's already filled**, and only prompts for what's still empty.
- **Validate at any time** — `@ZedAgent setup-service validate` runs
  `Load-ServiceConfig.ps1 -Strict` and reports missing or invalid fields.

When `validate` passes, force-add and commit (most service repos gitignore `.github/`):

```powershell
git add -f .github/agents/ZedAgent.agent.md .github/skills/zed-agent/
git commit -m "feat(zed): onboard ZED Agent"
```

### 5. Run a release

In Copilot Chat in the target repo:

```
@ZedAgent setup        # per-release: prompts for release ID, owner, target month
@ZedAgent              # the agent walks the 16-step pipeline
```

See `.github/agents/ZedAgent.agent.md` (in this repo or after install) for the
full pipeline definition and per-step ack vocabulary.

## What's per-repo (one-time) vs per-release

| Scope | Command | Output | Committed? |
|---|---|---|---|
| Per repo (one-time) | `@ZedAgent setup-service` | `service-config.json`, `pipeline-catalog.json` | Yes — committed to the target repo |
| Per release | `@ZedAgent setup` | `.zed-agent/state.json` | No — local only, gitignored |

## Compatibility

- **Repos**: any service repo that already has a monthly release pipeline on
  Azure DevOps and uses EV2 for production rollout.
- **OS**: Windows (the agent uses Outlook COM, Teams desktop client CDP, and
  Microsoft Edge CDP — all Windows-only integrations).
- **Shell**: PowerShell 7+ (`pwsh`). Some scripts run under Windows PowerShell 5.1, but 7 is recommended.
- **Tools required on the release owner's machine**: `git`, `gh`, `az`, Outlook desktop, Microsoft Teams desktop, Microsoft Edge.

## Development

This repo is the upstream source of truth. To improve the agent:

1. Make changes here, run the Pester tests under `.github/skills/zed-agent/tests/`.
2. Push to `main`.
3. In each consuming service repo, re-run `Install-Zed.ps1 -Force` and review the diff before committing.

The two configuration files in this repo are intentionally empty — never push
service-specific data here.

## License

See `LICENSE` (add your preferred license; Microsoft-managed repos typically
default to MIT or the org's standard internal license).
