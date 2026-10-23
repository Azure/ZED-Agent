# ZedForge Skill — Self-Improving Development Agent for ZED

ZedForge is a **meta-agent** that hardens the ZED deployment agent through an autonomous
**fix → validate → harvest** loop. It implements the pending *learnings*, seeds a real target
deployment repo with pre-filled configs, runs the ZED **true test run**, verifies the captured
pipeline parameters against a *requirements* (end-state) file, harvests new learnings, and loops
until a clean run.

Agent prompt: `.github/agents/ZedForge.agent.md`.

## What "true test run" means (the ZED change ZedForge validates)

The ZED `test-run` was redefined to be a **fast, non-destructive** validation (see
`ZedAgent.agent.md → Test Mode Overrides`):

| Step | Behavior in a true test run |
|------|-----------------------------|
| 1 | Branch-cut reminder (owner-only email) |
| 2 | Cut branch + **trigger build → instantly cancel + capture params** |
| 3 | skipped (build cancelled) |
| 4 | **real** commit analysis + Excel, owner-only mail, no human wait |
| 5 | canary pipelines → **trigger → instantly cancel + capture params** |
| 6 | BVT Kusto **query-works check** (no 24h wait, no `approve-bvt`) |
| 7-9 | skipped |
| 10 | prod pipelines → **trigger → instantly cancel + capture params** |
| 11-12 | skipped |
| 13 | **real** SafeFly R2D (owner abandons) |
| 14-16 | skipped |

Trigger steps 2/5/10 write `.zed-agent/releases/<id>/test-run-capture.json` via
`.github/skills/zed-agent/scripts/Invoke-TriggerAndCancel.ps1`. That file is the contract ZedForge
verifies.

## Files

```
.github/skills/zed-forge/
├── SKILL.md
├── requirements/
│   ├── requirements.md          # END STATE (prose): detailed per-step + golden syntax + caveats
│   ├── success-criteria.json    # END STATE (machine): per-step params + syntax rules + reference runs
│   └── reference-runs.json      # GOLDEN runs' full parameters (cached; compare current-run SYNTAX)
├── learnings/
│   └── learnings.md             # BACKLOG: real ZED freeform lessons-learned (status in forge-state.json)
├── config-seed/
│   ├── service-config.json      # pre-filled real service config (seed from bdp2)
│   ├── pipeline-catalog.json    # pre-filled catalog (static routing; fill real pipeline ids)
│   └── manifest.json            # kept files copied into the target repo each iteration
├── scripts/
│   ├── Update-ForgeState.ps1    # read/init/update forge-state.json
│   ├── Add-Learning.ps1         # append / mark-implemented backlog entries
│   ├── Get-Learnings.ps1        # read/filter backlog
│   ├── LearningsStore.ps1       # shared learnings.md markdown parser/renderer (dot-sourced)
│   ├── Seed-DeploymentRepo.ps1  # install latest ZED + overlay pre-filled configs
│   ├── Watch-ValidationRun.ps1  # poll the true test run until terminal
│   ├── Test-RunRequirements.ps1 # verify capture + state vs success-criteria (+ golden syntax rules)
│   └── Get-ReferenceRun.ps1     # fetch/read golden reference-run parameters for comparison
├── state/                       # forge-state.json (runtime, gitignored)
└── tests/
    └── Test-RunRequirements.smoke.ps1
```

## Requirements vs Learnings

- **Requirements** = the *end state* you want. Stable. Never weakened to make a run pass.
- **Learnings** = the *work items* to reach it. A living backlog: implement pending ones each
  iteration; harvest new ones from each run's failures + the target repo's `lessons-learned.md`.

## Quick start

```powershell
# From the ZED-Agent repo root, in Copilot Chat:
@ZedForge start           # runs the full loop against Q:\bdp3 until green / blocked
@ZedForge run-once        # one iteration
@ZedForge status          # loop state + last verdict + pending learnings
@ZedForge validate        # seed + run + verify against current ZED (no new edits)
```

Direct script use (outside the agent):

```powershell
$s = '.github/skills/zed-forge/scripts'
& "$s/Seed-DeploymentRepo.ps1"   -TargetRepo Q:\bdp3
& "$s/Watch-ValidationRun.ps1"   -TargetRepo Q:\bdp3 -ReleaseId TEST-2026-07-i1
& "$s/Test-RunRequirements.ps1"  -TargetRepo Q:\bdp3 -ReleaseId TEST-2026-07-i1
```

## Prerequisites
- `config-seed/pipeline-catalog.json` pipeline ids are **all real** — canary/production from the
  golden reference runs, and `officialBuild` = **282413** (Official-CloudBuild). DT-* pipeline
  variants (canary 421110/395577; prod 421108/403182) can be added from
  `requirements/reference-runs.json` if you want them in the trigger set.
- `az login --tenant microsoft.com` (ADO trigger/cancel + Kusto + reference-run fetch).
- Target repo (`Q:\bdp3`) is a clone of the service repo the seed config targets
  (`msazure/One/Mgmt-RecoverySvcs-BackupDataPlane`).
