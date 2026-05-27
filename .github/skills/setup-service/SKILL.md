---
name: setup-service
description: |
  Interactive one-time onboarding wizard for the ZED Agent. Populates
  .github/skills/zed-agent/service-config.json and pipeline-catalog.json by
  reading what the release owner has already filled in and prompting only for
  empty fields. Persists incrementally (per-answer file write + audit log).

  Use this skill whenever the release owner types any of:
    - `setup-service`               (full wizard from group 1)
    - `setup-service validate`      (run loader in strict mode, no prompts)
    - `setup-service group <N>`     where N in {1, 2, 3, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 4.10, 4.11, 4.12, 4.13, 5a, 5b, 6, 7, 8, 9, 10}
                                    (jump directly to a group)

  Also use this skill from inside the `setup` command when Test-PreFlight reports
  empty service-config or pipeline-catalog fields and Behavior Rule 13 says to
  "resume the matching setup-service group <N>".
allowed-tools: shell
---

You are the ZED Agent setup-service wizard. The release owner has just typed `setup-service`, `setup-service validate`, or `setup-service group <N>`. Follow the procedure below.

> **This command is run ONCE per repo** to generate the service configuration files. After generation, the files should be committed to the repo. For subsequent releases, use `setup` instead.

### Phase 0 — Pre-flight gate (always runs first)

Before any prompts, **always invoke `test-preflight`** so the *machine* is known-good — `az`, `git`, `pwsh`, modules, MCP, Teams CDP, AzureServiceConfig reachability, skill scripts. There is no point collecting answers if `az` is broken.

`Test-PreFlight` returns three independent verdicts. Setup-service only gates on the first one:

| Verdict | What it covers | Setup-service behavior |
|---|---|---|
| **`envVerdict`** | Machine readiness — `az`, `git`, `pwsh`, modules, MCP, Teams CDP, AzureServiceConfig, skill scripts | **Hard gate.** `fail` → halt. `warn` → confirm. `pass` → continue. |
| **`configVerdict`** | `service-config.json` + `pipeline-catalog.json` completeness | **Informational.** This is *exactly* what the wizard is about to fill. Show it as the work-list, never as a blocker. |
| **`releaseVerdict`** | Per-release artefacts (`environment.json`, `secrets.json`, `releases/<id>/*`) | **Ignored here.** Those belong to `setup`, not `setup-service`. |

1. Invoke the `/test-preflight` skill. It runs `Test-PreFlight.ps1`, attempts auto-remediation, writes `.zed-agent/readiness.json → preflight` (now with `envVerdict`, `configVerdict`, `releaseVerdict`), and reports.
2. Read the freshly-written readiness file.
3. Branch on **`envVerdict`** (NOT the overall `verdict`):
   - **`pass`** → show a one-line summary like *"Environment ✅ ready. Config gaps: {n} (this is what we're about to fill in)."* and continue to the Interactive Collection Flow.
   - **`warn`** → show the env warnings, then ask via `ask_user`:
     > *"Environment passed with {n} warning(s). These usually do not block setup-service. Continue?"*
     > Choices: `Continue`, `Stop — let me fix first`
     On `Continue`, write `readiness.preflight.overridden = true` and proceed.
   - **`fail`** → show the env failure list and halt: *"Environment has unresolved failures ({names}). Fix them (or re-run `test-preflight fix`) before re-running `setup-service`."* Do NOT offer an override path for env failures — the wizard cannot do its job with a broken `az` or missing skill scripts.
4. **Never prompt about `configVerdict` or `releaseVerdict`.** A `fail` on either is the *expected* first-run state. Mentioning them as "failures requiring confirmation" confuses the release owner.
5. Skip Phase 0 only when the dispatcher receives `setup-service validate` (validation is read-only and runs even on a broken environment).

> **For `setup-service group <N>` jumps**: Phase 0 still runs. A broken `az` token will fail the very first ADO call in Group 4 anyway — surfacing it up-front saves the owner a wasted round of prompts.

---

### Configuration files

The service configuration lives in just **two files** under `.github/skills/zed-agent/`:
- `service-config.json` — service identity, ADO, Kusto, notifications, SafeFly, gates, operational tunables
- `pipeline-catalog.json` — official build + canary + production pipeline definitions with `templateParameters`

Both files **already exist** in the repo (placed there by `Install-Zed.ps1`, or shipped empty in the ZED skeleton). The release owner can fill them in any way they want before — or instead of — running the wizard:

- **Fill nothing** → `setup-service` asks every question.
- **Fill some fields by hand** in VS Code (the `$schema` reference gives IntelliSense) → `setup-service` reads what's already there and only asks about the rest.
- **Fill everything by hand** → `setup-service` finds nothing missing, runs validation, and exits.

There is only one command — `setup-service` — and only one flow. The wizard is a gap-filler, not a separate mode.

> *Tip to surface to the release owner on first invocation:*
> *"You can pre-fill any fields you already know in `.github/skills/zed-agent/service-config.json` and `pipeline-catalog.json` before running `setup-service` — VS Code's JSON Schema autocomplete will guide you. Whatever you don't fill, I'll ask about. Use `setup-service validate` to check the files without prompting."*

### Interactive Collection Flow

**Always start by reading the current state of both files.** For every field below, check whether it is already populated (non-empty string, valid GUID, non-zero number, non-empty array, etc.). If populated, **skip the question** and use the existing value. If empty/null/placeholder, prompt the release owner. After each group, show what changed (carried-over vs newly-collected) and ask for confirmation before proceeding.

**⚠️ Persist incrementally — write after EVERY answer.** As soon as the release owner answers a single question, the agent MUST immediately write that value to the corresponding JSON file (`service-config.json` or `pipeline-catalog.json`) on disk before asking the next question. Do **NOT** buffer answers in memory and dump them in one big write at the end of the wizard. This guarantees:
- If the chat session is interrupted, killed, or the release owner walks away mid-wizard, no answers are lost.
- The release owner can re-run `setup-service` and it will pick up from exactly where they left off (already-answered fields are skipped).
- The release owner can open the file in VS Code in parallel and watch it fill in live.

Implementation pattern for every prompt:
1. Read the JSON file from disk into an object.
2. Ask the release owner the question via `ask_user`.
3. On receiving the answer, set the field on the in-memory object.
4. Write the object back to disk (preserve formatting, 2-space indent, trailing newline) **before** asking the next question.
5. Append a one-line entry to `audit.jsonl` (`{"action":"setup-service-field","field":"<dotted.path>","timestamp":"..."}`) — do NOT log the value if it is a secret.

The "show what changed" confirmation at the end of a group is a *recap* of what was just persisted — it is NOT the moment of writing. Writing happens per-answer.

**⚠️ Phase-boundary lesson sweep (silent, no owner prompt).** At the end of every Group / Phase that wrote at least one row to `audit.jsonl`, the wizard MUST run this sweep **before** advancing to the next phase. The owner is NEVER prompted during this sweep — the agent just writes the missing lessons.

1. Read `audit.jsonl` since this phase started; collect every row that matches a Behavior Rule 10 deterministic trigger (a–g) — warnings, errors, owner-corrections, script edits under `.github/skills/zed-agent/scripts/*.ps1`, unexpected API/tool shapes, mandated-step skips, hallucinated assumptions.
2. For each trigger row, check whether a `type:"lesson"` row exists within ± 5 minutes of its timestamp.
3. For every trigger with no time-adjacent lesson, **the agent calls `Add-Lesson.ps1` itself**, reconstructing the `Step` / `Symptom` / `RootCause` / `Fix` from the audit row and surrounding conversation context. Append `(backfilled)` to the `Step` field when the lesson is written after the trigger turn.
4. Persist one summary audit row `{type:"lesson-sweep", phase:"<N>", triggers:<N>, lessonsBefore:<L>, lessonsAfter:<L'>, backfilled:<B>}` and advance.
5. If no audit triggers fired this phase, the sweep is a no-op.

This sweep is the forcing function for Behavior Rule 10. "Capture lessons immediately" is the in-turn ideal; the sweep is the safety net for turns the agent missed. The owner reviews the resulting `lessons-learned.md` at `teardown`, not during the wizard.

If the release owner types `setup-service validate`, skip all prompting — go straight to the **Validation** subsection at the end.

**`setup-service group <N>` shortcut** — jump directly to a specific group instead of walking from the top. Supported group identifiers:

| Identifier | Section |
|------------|---------|
| `1` | Group 1 — Service Identity |
| `2` | Group 2 — Azure DevOps |
| `3` | Group 3 — Service Tree ID |
| `4.1` | Phase 4.1 — Pipeline identity |
| `4.2` | Phase 4.2 — Routing mode + per-pipeline cluster type |
| `4.3` | Phase 4.3 — Prior-run analysis |
| `4.4` | Phase 4.4 — Pipeline YAML introspection |
| `4.5` | Phase 4.5 — SDS discovery + field-mapping |
| `4.6` | Phase 4.6 — Canary stamp set |
| `4.7` | Phase 4.7 — Production scope |
| `4.8` | Phase 4.8 — BVT Kusto |
| `4.9` | Phase 4.9 — Cluster-type detection Kusto |
| `4.10` | Phase 4.10 — Per-pipeline parameter proposal |
| `4.11` | Phase 4.11 — Canary resolver + canary dry-run |
| `4.12` | Phase 4.12 — Production resolver + production dry-run |
| `4.13` | Phase 4.13 — EV2 metadata |
| `5a` | Group 5 — Notification Groups |
| `5b` | Group 5b — Notification Routing |
| `6` | Group 6 — SafeFly / R2D |
| `7` | Group 7 — Commit Excel |
| `8` | Group 8 — SharePoint |
| `9` | Group 9 — Operational Parameters |
| `10` | Group 10 — Step Gates |

Dispatcher behavior:
1. Parse the trailing token after `setup-service group `.
2. If the identifier is not in the table above, list valid choices and abort.
3. Otherwise, **load the existing `service-config.json` and `pipeline-catalog.json` from disk** (do not overwrite), then **resume the wizard at the named group** — same prompts, same persistence (incremental write after each `ask_user`), same audit log.
4. Skip the Generation phase except for re-running schema validation on completion.
5. After the group's questions are persisted, end with a recap line: `Group <N> updated — run 'setup-service validate' to re-validate.`

> 📒 **Always log a learning when the documented signal fails.** Whenever the agent has to fall back from the primary path described in a group (a cached/snapshot Azure Service Config fetch instead of live, an owner correcting a stamp name the agent built, an empty Kusto result that forces a manual prompt, an owner-declared region that does not resolve against Azure Service Config, etc.), the agent **MUST** call `Add-Learning.ps1` once per fallback, before the next `ask_user`, with `-Source agent-discovery` and a category from `{infrastructure, pipeline, parameter, config, process}`. The learning text must name the group, the signal that failed, and what the agent used instead. Re-runs still log — the gap is only "closed" when the source data is fixed, not when the wizard finishes. Skipping this step is a bug, not an optimisation.

**Group 1 — Service Identity**
Ask for:
- `service.name` — Short canonical name (e.g., "Prot", "DPM", "MABS"). Used in file names, tags, and filters.
- `service.displayName` — Human-readable name (e.g., "Protection Service", "Data Protection Manager")
- `service.stampTag` — Lowercase per-service infix used in stamp names (e.g. `prot` for `ea-can02-prot1`, `rec` for `eus-pod01-rec2`). Drives canary stamp parsing in `Get-StampInventory.ps1` and stamp filtering in the canary stamp set (Phase 4.6), the production scope (Phase 4.7), the canary cluster-type Kusto query (Phase 4.9, canary half), and the production cluster-type Kusto query (Phase 4.9, production half). Ask the release owner: *"Look at any one of your service's stamp names in EV2 or Kusto. The middle-segment letters between the layout and the trailing number — that's your stamp tag. Common values: `prot`, `rec`, `mab`, `bdp`."* Validate against `^[a-z]+$` and re-ask on invalid input.

> **Do NOT prompt for `service.agentFeedbackEmail`.** This field is hardcoded to `gwazire@microsoft.com` (the ZED agent author). Always write that exact value to `service-config.json` during the Group 1 persistence step — never ask the release owner about it, never carry over a different value already in the file, and never expose this field in `setup-service` prompts.

**Group 2 — Azure DevOps**
Ask for:
- `ado.organization` — ADO org (e.g., "msazure")
- `ado.project` — ADO project (e.g., "One")
- `ado.repository` — Repository name (e.g., "Mgmt-RecoverySvcs-BackupDataPlane")
- `ado.branchPrefix` — Release branch prefix (e.g., "official/bdp-"). The agent appends YYMM.
- `ado.baseBranch` — Branch to cut releases from (e.g., "develop", "main")

**Group 3 — Service Tree ID**
Ask for:
- `serviceTreeIds.safefly` — Your team's Service Tree ID (36-char hyphenated GUID). The agent uses this internally wherever a Service Tree ID is required.

Tell the release owner: *"You can find your Service Tree ID at https://microsoftservicetree.com/home — search for your service name. If you don't know it now, type `skip` and you can fill it in later. If your service uses different service IDs for different environments, you can update them manually later in the file."*

> **One question, multiple fields**: Persist the answer to `serviceTreeIds.safefly`, `serviceTreeIds.ev2.Prod`, `serviceTreeIds.ev2.Fairfax`, and `serviceTreeIds.ev2.Mooncake` — all four get the same GUID. Do NOT ask the release owner separately for EV2/Fairfax/Mooncake IDs.

**Group 4 — Service Topology, Pipelines, and Kusto**

Group 4 is the **single contiguous wizard block** covering everything pipeline- and topology-related: pipeline identity, routing mode, evidence-driven parameter discovery, the cloud-agnostic SDS stamp source, canary + production stamp lists, Kusto detection queries, dry-run validation, and EV2 metadata. It collapses the previously separate Kusto/stamps and pipeline-catalog sections into one ordered flow so that:

- **SDS** (Service Datacenter Settings, the cloud-agnostic stamp source) is discovered **before** the wizard asks "how many stamps per region?" — eliminating the old `4d` ordering bug that assumed one stamp per region.
- **Prior-run `sourceBranch`** is captured **before** YAML introspection, so `Get-PipelineYamlIntrospection.ps1` reads the branch the team actually develops on, not the pipeline definition's stale default.
- Owner-facing prompts use plain words — `stamp list`, `current scope`, `AzureServiceConfig`, `datacenter` — rather than the older internal jargon (`snapshot`, `ASC`, `DC`).

Stamp-universe **source-of-truth precedence** (top wins, applies wherever a stamp list is needed):

1. **Kusto live inventory query** (Phase 4.9 `kusto.production.inventoryQueryFile` — default `Production-StampInventory.kql`, shape `EventLogAllClusters | distinct StampName`) — strongest evidence: a stamp emitting telemetry **right now** is a stamp that exists. Inventory enumeration is intentionally split from cluster-type detection (which keeps using `kusto.production.queryFile` → `Production-DeploymentUnits.kql`). Limited to clouds the agent's identity can reach (effectively **Public** only — sovereign clouds live in AME-tenant Kusto and are out of reach).
2. **SDS** (Phobos 2022 JSON, pinned in Phase 4.5) — authoritative declared truth; the only source that covers sovereign clouds (Fairfax / Mooncake / USNat / USSec / Bleu). For Public, used to cross-check Kusto and catch decommissioned-but-still-configured stamps.
3. **Pipeline YAML hard-coded defaults** — `flatDefaults` / `perCloudDefaults` from `Get-PipelineYamlIntrospection.ps1` (Phase 4.4). Useful when a pipeline pins an explicit stamp list that disagrees with SDS / Kusto.
4. **AzureServiceConfig + grammar `<region>-<layout>-<stampTag><index>`** — last-resort approximation only when (1)–(3) are unavailable. The wizard surfaces an explicit warning when it falls back here.

Runtime contract is unchanged: `Get-StampInventory.ps1` reconciles **Kusto + SDS** for Public cloud (drift between the two halts Step 10 / Step 15 beyond `inventory.driftToleranceCount`), and reads SDS directly for sovereign clouds. `Resolve-RegionScope.ps1` (Step 15) diffs live AzureServiceConfig against `inventory.production.<cloud>` and requires an explicit `Accept` before substituting tokens.

Every prompt in Group 4 follows the **incremental-persistence rule**: read JSON from disk → ask the owner → write the answer to disk → log to `audit.jsonl` → ask the next question. Buffering answers in memory and dumping at the end is a bug.

---

#### Phase 4.1 — Pipeline identity

Collect just enough to identify every pipeline. **No `templateParameters`, no `clusterType` here** — those are addressed in 4.2 and 4.10.

Ask via `ask_user`, persisting after each answer:

1. **Official Build** — pipeline `name` and `id`. Persist to `officialBuild.name` and `officialBuild.id` in `pipeline-catalog.json`.

2. **Canary pipeline count**:
   > *"How many canary pipelines does your service have? (Just the count — I'll learn each one's parameters from ADO in a later phase.)"*

   For each, collect only **key**, **name**, **id**:
   - **key** — service-defined identifier the agent uses internally (e.g., `SVC-SFMC`, `DM-EACAN`).
   - **name** — display name as it appears in ADO.
   - **id** — the integer ID from the pipeline URL (`definitionId=XXXXXX`).

   Persist to `canary.<key>.{name,id}`.

3. **Production pipeline count** — same pattern. Persist to `production.<key>.{name,id}`.

Do **not** ask for `templateParameters`, `clusterType`, `clusterTypeMap`, or any cluster-routing concept yet — those are Phase 4.2 and Phase 4.10.

---

#### Phase 4.2 — Routing mode + per-pipeline cluster type

Ask via `ask_user`:

> *"How are your service's deployment pipelines structured?*
> *  (a) **By region / stamp only** — every canary pipeline serves the same cluster type; the agent triggers all of them every release.*
> *  (b) **By cluster type** — each region hosts multiple cluster-type variants (e.g., SFMC + SFRP) served by separate pipelines; the agent queries Kusto at runtime to pick which pipeline(s) to trigger per release."*

> ⚠️ **Never auto-default this answer.** `canaryRouting.mode` and `productionRouting.mode` are load-bearing — they decide whether `Resolve-PipelinesByClusterType.ps1` and the lazy `clusterType` resolver in `Get-StampInventory.ps1` actually run. If `pipeline-catalog.json` already has a non-empty value on re-entry, show it back to the owner and explicitly ask *"keep `<existing mode>` or change?"* before persisting. If `pipeline-catalog.json` is fresh / missing the field, you **must** ask the question above and wait for an answer — do not silently write `static` because it is the conservative default.

- On `(a)`: persist `canaryRouting.mode = "static"` and `productionRouting.mode = "static"`.
- On `(b)`: persist `canaryRouting.mode = "cluster-type"` and **immediately ask production separately** (production topology can be asymmetric):
  > *"And your production pipelines — same split (by cluster type), or static (by region only)?"*

  Persist `productionRouting.mode` accordingly. If either mode is `cluster-type`, persist an empty `clusterTypeMap: {}` placeholder under that block — the map is filled in this phase as the owner declares each pipeline's cluster type.

**Per-pipeline `clusterType` collection** — for each canary pipeline declared in Phase 4.1, **only when `canaryRouting.mode == "cluster-type"`**:

> *"Which cluster type does this pipeline serve? (e.g., `sfmc`, `sfrp`, `eap`)"*

Persist to `canary.<key>.clusterType` and append `<key>` to `canaryRouting.clusterTypeMap[<clusterType>]` (use array form if the type already maps to another key). Phase 4.10's inference step then becomes a **cross-check** rather than the source of truth — if YAML / prior-run evidence in 4.10 contradicts the owner-declared cluster type, surface it as a discrepancy.

Repeat the same per-pipeline `clusterType` collection for production pipelines when `productionRouting.mode == "cluster-type"` — persist to `production.<key>.clusterType` and append to `productionRouting.clusterTypeMap[<clusterType>]`.

If both modes are `static`, skip the per-pipeline `clusterType` ask entirely.

---

#### Phase 4.3 — Prior-run analysis (per pipeline)

For each pipeline collected in Phase 4.1 (official build + canary + production), read prior successful production runs. The agent uses these runs as **evidence** for two things: (a) Phase 4.4's YAML branch resolution, and (b) Phase 4.10's `templateParameters` merge.

For each pipeline, ask via `ask_user`:

> *"For `{key}` (`{name}`), do you want to point me at specific successful runs to learn from, or should I just grab the last 3 successful production runs automatically?"*
> Choices: `I'll provide run IDs / URLs`, `Use last 3 successful runs (auto)`

**On `I'll provide run IDs / URLs`** — collect a comma-separated list of run IDs or full ADO run URLs via `ask_user`. Parse each entry (extract the integer `runId` from URLs of the form `…/_build/results?buildId=<id>`), then resolve each one through `Read-PriorRun.ps1` in single-run mode:

```powershell
$runs = & .github/skills/zed-agent/scripts/Read-PriorRun.ps1 `
    -Organization $cfg.ado.organization `
    -Project $cfg.ado.project `
    -PipelineId $entry.id `
    -RunIds @(<ids parsed from owner input>)
```

For each ID, verify it (a) belongs to this `PipelineId`, (b) has `result = succeeded`. If any fail those checks, surface the exact reason (*"Run 28471 belongs to pipeline 3528, not 3527"* / *"Run 28471 finished with `result = failed`"*) and re-prompt the owner — either correct the list or fall back to auto.

**On `Use last 3 successful runs (auto)`** — run the auto-fetch:

```powershell
$runs = & .github/skills/zed-agent/scripts/Read-PriorRun.ps1 `
    -Organization $cfg.ado.organization `
    -Project $cfg.ado.project `
    -PipelineId $entry.id `
    -ResultFilter "succeeded" `
    -Top 3
```

The script returns normalized objects: `{ runId, runUrl, finishedAt, sourceBranch, templateParameters }`. If fewer than 3 runs exist (new pipeline), return whatever's available; if zero, tell the owner *"No prior successful runs found for `{key}` — I'll rely on YAML only in Phase 4.4 / 4.10 and lean more heavily on your review."*

**Branch capture (new behavior)** — after the runs are returned, inspect `$runs[*].sourceBranch`:

- **If all observed branches agree** AND the runs target the wizard's `selfRepo` (the repo whose YAML the pipeline reads), persist that branch as `yamlRepos.<selfRepo>.baseBranch` so Phase 4.4's YAML fetch reads the correct branch. Recap: *"Captured `sourceBranch = <branch>` from `<N>` recent runs of `<key>` — Phase 4.4 will read YAML from this branch."*
- **If branches disagree** across the 3 runs (e.g., some on `develop`, some on a release branch), surface the disagreement and ask the owner to pick one:
  > *"The last 3 runs of `{key}` queued from different source branches: `{branch_a}` (×2), `{branch_b}` (×1). Which branch do you want me to introspect the YAML from for parameter discovery?"*

  Persist the owner's choice to `yamlRepos.<selfRepo>.baseBranch`.
- **If runs target a different repo** (cross-repo pipeline), record `_learnedFrom.crossRepo = true` against this pipeline key and leave `yamlRepos` alone — Phase 4.4 will handle the cross-repo branch confirmation per-repo.

Persist the normalized run objects under `<scope>.<key>._learnedFrom.runs` so Phase 4.10 can read them without re-fetching.

**Reference-run capture (per production pipeline)** — the auto-captured 3 runs teach the agent **parameter shape** (CSV vs JSON, naming style, which params even exist). They are intentionally **not trusted as the source of truth for values** — history goes stale, owners experiment, runs get queued from feature branches. To anchor real-world value patterns (e.g., *"do operators actually pass `*` for regions, or do they enumerate?"*, *"is `excludeStamps` typically empty or populated?"*, *"what's the typical `sdpType` for a clean prod push?"*), the wizard asks each production-pipeline owner to nominate ONE known-good release run after the 3-run capture:

> *"For `{key}`: I've captured the last 3 successful runs to learn the parameter schema. Now point me at one specific **reference release** — a run you'd describe as 'this is what a healthy production push of this service looks like'. I'll use its values (not the 3-run mode) whenever a parameter is ambiguous or its value diverges across the 3 runs. Run ID or full ADO run URL?"*
> Choices: `Provide reference run`, `Skip — the 3-run mode is good enough`

On `Provide reference run`, parse the input (integer `runId` or `…/_build/results?buildId=<id>` URL) and validate via `Read-PriorRun.ps1`:

```powershell
$ref = & .github/skills/zed-agent/scripts/Read-PriorRun.ps1 `
    -Organization $cfg.ado.organization `
    -Project $cfg.ado.project `
    -PipelineId $entry.id `
    -RunIds @(<owner-provided id>)
```

Reject (and re-prompt) if any of these fail:
- The run belongs to a different `PipelineId`.
- `result != succeeded`.
- `reason == 'manual'` AND `templateParameters` is empty (a dry-run — reference runs must be real releases).

Also ask one optional free-text follow-up: *"One-line note on why this run is your reference (e.g. 'May 2026 release — clean prod push, all clouds, no skips')?"* — stored as `reason` in the persisted record.

Persist alongside the 3-run capture, distinct shape:

```jsonc
"<scope>.<key>._learnedFrom": {
  "runs": [ /* 3 auto-captured — schema source */ ],
  "referenceRun": {
    "runId":             28471,
    "runUrl":            "https://dev.azure.com/…/_build/results?buildId=28471",
    "finishedAt":        "2026-05-19T17:42:11Z",
    "sourceBranch":      "refs/heads/releases/svc2604",
    "templateParameters": { /* full owner-signed-off value map */ },
    "nominatedAt":       "<UTC ISO>",
    "nominatedBy":       "<owner email>",
    "reason":            "<owner free-text or empty>"
  }
}
```

On `Skip`, write `_learnedFrom.referenceRun = null` so Phase 4.10 knows to fall back to 3-run mode-of-values for value selection.

**Scope**: the reference-run prompt is asked **only for production pipeline keys** (canary pipelines use stamp/region tokens substituted from Phase 4.6 inventory at runtime — a reference run there teaches nothing the tokens don't already encode). The official build pipeline is also skipped — it has no scope-shaped parameters.

---

#### Phase 4.4 — Pipeline YAML introspection

For each pipeline (official build + canary + production), fetch and statically analyze the YAML so 4.5 / 4.10 / 4.13 can pre-fill defaults.

```powershell
$yamlInfo = & .github/skills/zed-agent/scripts/Read-PipelineYaml.ps1 `
    -Organization $cfg.ado.organization `
    -Project $cfg.ado.project `
    -PipelineId $entry.id
```

The script:

- Calls `GET /_apis/pipelines/{id}?api-version=7.1` to discover `configuration.type`, `configuration.repository`, and `configuration.path` directly from ADO.
- Computes a **proposed branch**: if the YAML repo equals the wizard's current repo, use `cfg.ado.baseBranch`; otherwise check `yamlRepos.{repoName}.baseBranch` for a previously-persisted value (now seeded by Phase 4.3 from prior-run `sourceBranch`); otherwise fall back to the pipeline definition's default branch (`configuration.repository.defaultBranch`, typically `refs/heads/main`).
- **Always confirm with the owner via `ask_user`** before fetching:
  > *"For pipeline `{key}` (`{name}`), I'm about to read the YAML from:*
  > *  • Repo: `{repoName}` ({same-repo|cross-repo})*
  > *  • Path: `{configuration.path}`*
  > *  • Branch: `{proposedBranch}` (source: {prior-run capture | yamlRepos cache | cfg.ado.baseBranch | ADO default})*
  >
  > *Use this, or point me somewhere else?"*
  > Choices: `Use this`, `Change branch`, `Point me at a different YAML`, `No YAML — use prior runs only`

  - **`Use this`** — proceed; persist `yamlRepos.{repoName}.baseBranch = <proposedBranch>` if the repo wasn't already in the cache.
  - **`Change branch`** — ask for the branch name only (`develop`, `main`, `releases/svc2604`, …), then re-show the confirmation. Persist the new value to `yamlRepos.{repoName}.baseBranch`.
  - **`Point me at a different YAML`** — collect a `repo:branch:path` shorthand via `ask_user` (the `repo` half may be a bare name within the same org/project, or a full `org/project/repo` for cross-org). Validate the file exists at that ref before continuing.
  - **`No YAML — use prior runs only`** — skip introspection for this pipeline and record `_learnedFrom.yamlSource = "absent"`. Phase 4.10 then works from prior-run values alone.

- **Fallback for classic / designer / non-YAML pipelines**: if `configuration.type != "yaml"`, the auto-discovered repo/path are empty. Replace the confirmation prompt with a direct collection prompt asking for the YAML path (in this repo, in another repo via `repo:branch:path` shorthand, or `none`).
- Fetches the YAML content from the confirmed branch.
- Recursively follows every `extends:` template reference (cross-repo allowed). For each new repo encountered in an `extends:` chain, run the same confirmation prompt before fetching, and persist to `yamlRepos`.

Then run the structured introspector:

```powershell
$intro = & .\.github\skills\zed-agent\scripts\Get-PipelineYamlIntrospection.ps1 -YamlPath <localYamlPath>
```

The introspector is pure analysis — no network, no auth, no side effects. It returns:

- **`cloudConvention`** — `stageHardcoded` (one pipeline = one cloud, via `value: <Cloud>` under a `cloud` variable) or `perCloudScriptFlags` (one pipeline → many clouds via `<Prefix>Script` boolean toggles) or `unknown`.
- **`cloudsDetected`** — list of cloud names the YAML actually targets. Cross-checked against `ev2CloudCoverage.<key>` in Phase 4.13 (deferred — `ev2CloudCoverage` is not collected yet).
- **`stampParamShape`** + **`flatDefaults` / `perCloudDefaults`** — declared `stamps` / `Excludestamps` / `Regions` / `ExcludeRegions` defaults, either flat or per-cloud-prefixed.
- **`ev2.{taskVersion, stageMapName, endpointProviderType, approvalServiceEnvironment, serviceRootPath, rolloutSpecPath, select, datacenterType}`** — the `vsrm-ev2.ev2-rollout.ev2-rollout-task.Ev2RARollout@N` task input block.
- **`sdsHint.{fileName, repoPath}`** — extracted from inline PowerShell `-SdsFiles <name>` plus the nearest `$hsp_source = "$(Pipeline.Workspace)/s/dep_specs/<path>"`. Consumed by Phase 4.5.
- **`selfRepo.{name, baseBranch, alias}`** — the source-tree repo declared under `resources.repositories[]` (type git, not under `OneBranch.Pipelines/`). Consumed by Phase 4.5 for the SDS path.

Persist verbatim to `pipeline-catalog.json → pipelines.<key>.yamlIntrospection`. The merged `parameters:` block (per-parameter `name`, `type`, `default`, `values`, plus `_resolvedFrom` provenance) is persisted under `pipelines.<key>.yamlIntrospection.parameters` and consumed by Phase 4.10's merge.

> **Hard warning — empty leaf parameters + non-null extends.** If `Get-PipelineYamlIntrospection.ps1` returns `parameters.Count == 0` AND the YAML contains an `extends:` reference AND `Read-PipelineYaml.ps1` did NOT return parameters from the extended template either (or returned a non-empty `promptForRepos`), halt with:
>
> > *"Pipeline `<key>`: the leaf YAML has no `parameters:` block, but it extends `<template>@<repo>` and Read-PipelineYaml could not resolve that template either. Phase 4.10 will be unable to propose `templateParameters` for this pipeline. Re-run `setup-service group 4.4` after fixing the extends resolution (most common cause: missing `yamlRepos.<repo>.baseBranch` entry — answer the `promptForRepos` follow-up, or set `LocalRepoRoot` if the repo is cloned locally)."*
>
> Do not silently continue — a stale `pipelines.<key>.yamlIntrospection.parameters = []` makes Phase 4.10 fall back to prior-run values alone, which strips reserved tokens and re-introduces stamp-list drift.

> **Path strings are passed verbatim to ADO.** Pipeline YAML paths sometimes contain commas, spaces, or other characters that look like typos (e.g., `OneBranch.DT,SF.ServiceUpgrade.yml`). Do not normalize, "fix", or strip them — `configuration.path` from the pipeline definition is the source of truth and ADO's Git Items API matches it byte-for-byte.

The cloud-coverage cross-check is deferred to Phase 4.13 — that's where `ev2CloudCoverage.<key>` is collected.

Recap: *"YAML introspection captured for `<N>` pipelines. Convention: `<convention>`. SDS hints written to `pipelines.*.yamlIntrospection`. Re-run `setup-service group 4.4` after any pipeline YAML edit to refresh."*

---

#### Phase 4.5 — SDS discovery + field-mapping

> **Phase 4.5 pins the Service Datacenter Settings (SDS) JSON file** that each production pipeline reads at queue time — the same file EV2 uses to expand `{stamp}` macros. SDS is the cloud-agnostic source of truth for the stamp fleet (Phobos 2022 schema, https://aka.ms/phobosweb/schema/2022/sds). Two reasons we pin it here, **before** asking the owner about stamp counts:
>
> 1. **Sovereign clouds** (Fairfax / Mooncake / USNat / USSec / Bleu / BVTD3 / EXP) live in AME-tenant Kusto this agent cannot reach. SDS is the **only** stamp source for them.
> 2. **Public cloud reconciliation.** Kusto remains the primary stamp source for Public, but `Get-StampInventory.ps1` cross-checks against SDS and halts Step 10 / Step 15 if the two disagree beyond `inventory.driftToleranceCount`.

The phase has three parts: **locate**, **confirm**, **detect-mapping**. All three persist incrementally to `service-config.json → sds.<pipelineKey>` and `service-config.json → sdsFieldMapping`.

1. **Locate the SDS file each production pipeline references.** For every key under `production.*` (from Phase 4.1), read `pipelines.<key>.yamlIntrospection` (Phase 4.4):
   - `$intro.sdsHint.fileName` (e.g., `ServiceDatacenterSettingsConfig.json`, `ServiceDatacenterSettingsConfigActPass.json`)
   - `$intro.sdsHint.repoPath` (e.g., `src/ServiceFabric/Deployment`)
   - `$intro.selfRepo.name` and `$intro.selfRepo.baseBranch`

   If the owner has a local clone (commonly under `Q:\<repo>` or `~/src/<repo>`), search for the file there first via:

   ```powershell
   Get-ChildItem -Path <candidateCloneRoot> -Recurse -Filter $intro.sdsHint.fileName -ErrorAction SilentlyContinue
   ```

   Otherwise fall back to the ADO Git items API (same pattern as `Read-PipelineYaml.ps1`).

2. **Confirm with the owner.** Before persisting, ask once per pipeline key:
   > *"I located `<full path>` referenced by pipeline `<pipelineKey>` via `-SdsFiles <fileName>` in the YAML. Is this the SDS that contains all stamps for this service, or is it somewhere else?"*

   Accept `yes` (persist) or a corrected absolute path (re-validate then persist). Capture `confirmedAt` (UTC ISO timestamp) and `confirmedBy` (owner email). Persist:

   ```json
   "sds": {
     "<pipelineKey>": {
       "repo":           "<selfRepo.name>",
       "branch":         "<selfRepo.baseBranch>",
       "path":           "<repo-relative path ending in fileName>",
       "fileName":       "<fileName>",
       "localClonePath": "<absolute path to local clone, when known>",
       "confirmedAt":    "<UTC ISO>",
       "confirmedBy":    "<owner email>"
     }
   }
   ```

   When several pipeline keys all point at the same SDS file (common — `ServiceUpgrade.PROD` and `ClusterUpgrade.PROD` often share one SDS), persist one entry per pipeline key with identical values; the gate compares hashes per `pipelineKey`, not per file.

3. **Detect the field-mapping shape and confirm overrides.** Phobos 2022 is the default; if the owner's SDS deviates (rare but real for older services), use the script's `-Detect` mode to surface what each default path resolved to and what the first stamp's values look like:

   ```powershell
   $d = & .\.github\skills\zed-agent\scripts\Get-StampInventoryFromSds.ps1 -SdsPath <path> -Detect
   $d.mapping  # dotted paths the script will walk
   $d.samples  # what each path actually returned on the first stamp / cloud
   ```

   For each sample whose value is null or `<unresolved>`, **try probe-and-resolve before asking the owner**:

   - **Pick a probe value** the agent already knows is correct for *some* stamp in this SDS — preferred order: (a) a stamp name returned by Phase 4.7 Kusto inventory for this service, (b) a canary stamp the owner declared in Phase 4.6, (c) a stamp name from a prior `audit.jsonl` learning. Repeat per missing field with the matching probe (e.g. probe `"ea-bvtd3"` for `deploymentNamePath`, `"ea-bvtd3-prot-01-sf"` for any deployment-unit path, `"eastasia"` for `regionPath`).
   - **Walk the SDS** and collect every dotted path whose value contains the probe. Implement as a depth-first JSON walk emitting `(path, value)` tuples; do not rely on regex against the raw file (key names contain `->` and quotes which trip naive matchers).
   - **Score candidates** and pick a winner:
     1. Exact match (`value == probe`) beats substring match (`value -like "*probe*"`, e.g. URL or DNS containing the stamp name).
     2. Path appearing in **every** SDS row with a **distinct** exact value per row (1:1 with row identity) beats a path that's constant across rows or missing on some.
     3. Path whose final segment contains the field's intent word (`StampName`, `DeploymentName`, `Region`, etc., case-insensitive) beats one that doesn't.
     4. Shorter path beats deeper path on ties.
   - **Persist the winner** to `sdsFieldMapping.<key>` and record provenance in `audit.jsonl` as `{type:"sds-field-resolve", field, probe, winnerPath, candidatesConsidered:<n>, confidence:"high|medium"}`. Confidence is `high` only when rule 1 + rule 2 both hold for the winner.
   - **Ask the owner only when** probe-and-resolve returns zero hits, or returns a tie that none of rules 1–4 breaks, or when confidence is `medium` and the field is one of `stampNamePath` / `clusterNamePath` (the two paths that drive Phase 4.7 stamp identity). Show the top 3 candidates plus their sample values; let the owner pick by index or dictate a path.

   Persist non-default overrides to `service-config.json → sdsFieldMapping.<key>` (keys: `cloudArrayPath`, `cloudNameField`, `stampsArrayField`, `stampIdField`, `stampNamePath`, `clusterNamePath`, `dcShortNamePath`, `regionPath`, `deploymentNamePath`, `dsmsRegionPath`). When all sample values look right under Phobos 2022 defaults, skip the block entirely — missing keys fall back to Phobos 2022 defaults at runtime.

   > **Why probe-and-resolve, not a hard-coded list of known prefixes:** different services bury the stamp name under different `Properties.*Config->StampName` prefixes (`ProtConfig`, `RecConfig`, `BcdrConfig`, `ProvConfig`, …) and some don't use the `*Config->` shape at all. Encoding any one prefix as a default biases the agent toward one service. The probe is service-agnostic because it asks the SDS "where does this known-good value live?" rather than "do you match my hard-coded path?".

4. **Smoke-test once.** After persisting, run the full inventory against every cloud the SDS exposes:

   ```powershell
   & .\.github\skills\zed-agent\scripts\Get-StampInventoryFromSds.ps1 -SdsPath <path>
   ```

   Recap: *"SDS pinned at `<path>`. Found `<N>` stamps across `<clouds>`. Hash: `<sha256[:12]>`. From this point on, `Get-StampInventory.ps1 -Scope production` will read this SDS — sovereign clouds source from it directly, Public cloud cross-checks against it."*

5. **Set drift tolerance once.** Ask: *"How many unmatched stamps between Kusto and SDS should the inventory gate tolerate before halting Step 10 / Step 15? `0` means any drift requires re-approval. Recommended: `0`."* Persist to `inventory.driftToleranceCount`. Default to `0` if the owner hits enter.

6. **Decide whether the production gate is mandatory.** Ask: *"Should Step 10 (Roll-Forward) and Step 15 (Production Rollout) refuse to fire until the owner explicitly approves each inventory snapshot? Recommended: `yes`."* Persist `true`/`false` to `inventory.production.approvalRequired`. When `false`, the gate auto-passes — use only for test services.

---

#### Phase 4.6 — Canary stamp set

The canary fleet is small and stable. **Kusto is first source of truth**: `Canary-DeploymentUnits.kql` (Phase 4.9) returns `StampName` + `DeploymentUnit set`, and `Get-StampInventory.ps1 -Scope canary` derives `clusterType` per stamp via `kusto.canary.clusterTypeExtraction`. AzureServiceConfig validates region resolution; the owner **confirms or edits** the Kusto-derived list — they no longer supply it from scratch.

**SDS remains critical and always reconciled.** If Kusto fails or returns zero rows, the wizard falls back to SDS as degraded mode (`source = SDS-fallback`) so setup can continue; the owner can edit before persist. Even when Kusto succeeds, run SDS cross-check and surface drift (`kustoOnly`, `sdsOnly`) before final confirmation.

> **AzureServiceConfig vocabulary — for the recap only**
>
> Each `Clouds[].DataCenters[]` entry carries a `DatacenterType` comma-list. Two values matter for the recap:
> - **`PASSIVE`** — this datacenter IS a recovery-only copy. Never targeted as a canary stamp.
> - **`HAS_PASSIVE`** — this datacenter has an additional passive (recovery) copy behind the primary. Purely informational; surface it so the owner knows which regions have a recovery copy.

Prerequisite: `service.stampTag` (Group 1) **and Phase 4.9 canary half** must be populated. If `kusto.canary.cluster` is empty, jump back to Phase 4.9.

1. **Run Kusto live first.** Call:

   ```powershell
   $inv = & .\.github\skills\zed-agent\scripts\Get-StampInventory.ps1 -Scope canary -ViaKusto -NoCache
   ```

   The script executes `kusto.canary.queryFile` against `kusto.canary.cluster` / `.database`, returns one row per stamp with `{ stampName, clusterType, region, layout, cloud }` (clusterType extracted from `DeploymentUnit` per `kusto.canary.clusterTypeExtraction.mode`).

   If Kusto fails or returns zero rows, surface the error and immediately run SDS fallback:

   ```powershell
   $inv = & .\.github\skills\zed-agent\scripts\Get-StampInventoryFromSds.ps1 -SdsPath <pinned path>
   ```

   Mark provenance as `_inventoryFrom: { source: "SDS-fallback", reason: "kusto-failed-or-empty", at: <UTC> }` and add a warning recap: *"Kusto failed, inventory sourced from SDS fallback. Re-run `setup-service group 4.9` and then `setup-service group 4.6` to restore live Kusto baseline."*

2. **Cross-check Kusto vs SDS (always).** If Kusto succeeded, load SDS in parallel and diff by stamp name:

   - `kustoOnly = Kusto - SDS`
   - `sdsOnly = SDS - Kusto`

   Render both sets before confirmation. Owner choices per set: `accept Kusto`, `accept SDS`, `manual edit`. Persist a `_reconcile` block with counts + owner decision.

3. **Resolve each selected stamp list's regions against AzureServiceConfig.** For every distinct `region` in `$inv.stamps[].region`, look up `{ cloud, layout }` from `$asc.data.Clouds[].DataCenters[]`. Surface any unknown region as `drift.unknownRegion` — owner picks per row: *keep anyway* (mark `_unresolved: true`) or *drop*.

4. **Show the owner the derived list for confirmation (Kusto or SDS-fallback):**

   ```
   Canary inventory — source: <Kusto live | SDS-fallback>
     ecy-pod01-prot1  | region=ecy   | cloud=Public  | clusterType=sfrp  | source=Kusto
     ccy-pod01-prot1  | region=ccy   | cloud=Public  | clusterType=sfrp  | source=Kusto
     ea-can02-prot1   | region=ea    | cloud=Canary  | clusterType=sfmc  | source=Kusto
     …
   Choices: Looks right, Edit (drop / rename / re-classify a row), Re-run Kusto
   ```

   - **`Looks right`** — persist `inventory.canary.stamps[]` from the selected source with `clusterType` populated where available; record `_inventoryFrom` and `_reconcile` (when both Kusto and SDS were available).
   - **`Edit`** — the owner may drop a row (e.g., a decommissioned stamp Kusto is still emitting telemetry for), correct a `clusterType` Kusto mis-classified, or annotate a region. Edits are recorded with `_ownerOverride: { field, was, now, reason }` so the next setup pass can re-warn if Kusto disagrees again.
   - **`Re-run Kusto`** — useful if the owner just fixed an issue (token, query); jumps back to step 1.

5. **Validate immediately** by calling `Get-StampInventory.ps1 -Scope canary` (this time without `-ViaKusto`; it now reads the persisted catalog and re-validates against AzureServiceConfig). If `$inv.drift` is non-empty, render the drift table and re-prompt. If `$inv.stamps.Count -eq 0`, halt and re-run Phase 4.6 from step 1.

6. **Recap + remind:** *"Canary inventory pinned. {N} stamps across {M} regions; cluster types observed: {distinct list}. Source: {Kusto live | SDS-fallback}. If fallback was used, re-run `setup-service group 4.9` and then `setup-service group 4.6` to refresh from live telemetry."*

---

#### Phase 4.7 — Production scope

The production fleet is too large to enumerate stamp-by-stamp the way Phase 4.6 does for canary, but at *setup time* the agent CAN compute the full per-cloud stamp list from the SDS pinned in Phase 4.5 (or YAML defaults from Phase 4.4 as a fallback) and persist it. This **current scope** has two jobs:

1. **Phase 4.12 dry-runs** substitute `{{pubRegions}}`, `{{ffRegions}}`, `{{ffStamps}}` (and any cloud-prefixed equivalents) from this scope, so the production dry-run POST body looks like a real maximum-scope release — not an empty-string placeholder.
2. **Step 15 (real release)** re-fetches AzureServiceConfig live and **diffs against this scope**. Added regions/stamps are flagged as `+drift`, removed as `-drift`, and the owner sees the diff before the production POST is queued. On `Accept`, the diff is auto-merged back into `inventory.production.<cloud>` so the next release starts from the new baseline.

Prerequisite: `service.stampTag` (Group 1), Phase 4.5 (SDS pinned), and Phase 4.6 (canary stamp set) must have completed. If `service.stampTag` is empty, jump back to Group 1.

1. **Fetch AzureServiceConfig** (re-uses the call from Phase 4.6 if already loaded this session):

   ```powershell
   $asc = & .\.github\skills\zed-agent\scripts\Get-AzureServiceConfig.ps1
   ```

   On cache/snapshot fallback, warn the owner — a stale AzureServiceConfig at setup time means stale dry-run scope and noisy Step 15 drift.

2. **Pick active production clouds** via `ask_user` (multi-select) from the list of AzureServiceConfig clouds whose `Name` does NOT contain `Canary` or `BVTD3`. Typical choices: `Public`, `Fairfax`, `Mooncake`, `USNat`, `USSec`, `Bleu`. Persist to `inventory.production.cloudsActive` (array of cloud names, exact AzureServiceConfig casing). This is the master list — Phase 4.13's `ev2CloudCoverage.<key>` must be a subset of this when collected.

3. **Per chosen cloud, build the stamp list using the source-of-truth precedence chain:**

   > Kusto is the **finalizing signal** for the Public cloud — a stamp emitting telemetry right now is a stamp that exists. The chain still falls back to SDS / YAML / grammar for sovereign clouds (out of reach from the agent's identity) and for the case where Phase 4.9's production half has not been collected yet.

   **3a. Kusto live — cluster-type query preferred (Public cloud, mandatory when configured).**

   Gate: this branch runs **whenever** `cloud == "Public"` AND `kusto.production.cluster` / `.database` are populated (Phase 4.9). Two queries are usable, in order of preference:

   1. **`kusto.production.queryFile`** (default `Production-DeploymentUnits.kql`) — returns `StampName, set<DeploymentUnit>`. `Get-StampInventory.ps1` derives `clusterType` per stamp via `kusto.production.clusterTypeExtraction`. **Preferred** because each stamp carries an authoritative `clusterType` from the same pass that enumerated it — no separate query is needed at run time.
   2. **`kusto.production.inventoryQueryFile`** (default `Production-StampInventory.kql`) — returns `StampName` only. Used when `queryFile` isn't configured yet; stamps come back with `clusterType: null` and Phase 4.10's cluster-type checks will refuse to proceed in `cluster-type` mode until the cluster-type query is configured.

   `kusto.production.serviceFilter` (substituted into `{{SERVICE_FILTER}}`) and `kusto.production.stampPrefixFilter` (substituted into `{{STAMP_PREFIX_FILTER}}`) are required for both. Both are auto-derived in Phase 4.9 production half.

   ```powershell
   $kustoRows = & .\.github\skills\zed-agent\scripts\Get-StampInventory.ps1 `
       -Scope production -Cloud Public -NoCache
   ```

   Stamp names are captured **verbatim from Kusto** — the wizard does **not** synthesize names via grammar on this branch. Regions are derived per stamp by `Resolve-StampParts` (the short-name prefix). `clusterType` is populated per stamp when the `queryFile` form was used. Source label: `Kusto live (<queryFile>@<UTC ISO>)`.

   On Kusto error for Public (auth, query syntax, empty result set), surface the verbatim error, then run SDS fallback for Public and mark `_scopeFrom.source = "SDS-fallback"` with `_scopeFrom.reason = "kusto-failed-or-empty"`. Setup may proceed, but recap must include: *"Public scope is degraded (SDS fallback). Re-run `setup-service group 4.9` and then `setup-service group 4.7` to restore Kusto baseline."*

   **Public SDS cross-check (always):** when Kusto succeeds, also run SDS for Public and compute drift before owner confirmation:

   - `kustoOnly = Public(Kusto) - Public(SDS)`
   - `sdsOnly = Public(SDS) - Public(Kusto)`

   Render drift table and require owner decision: `accept Kusto`, `accept SDS`, `manual merge`. Persist the decision under `inventory.production.Public._reconcile` with counts + timestamp.

   When Phase 4.9 production half has NOT been run yet, the wizard MUST surface the recap (not silence it): *"Built Public scope from SDS. Run `setup-service group 4.9` to enable live Kusto reconciliation, then re-run `setup-service group 4.7` to refresh the baseline from telemetry."*

   **3b. SDS (Phase 4.5):** Run `Get-StampInventoryFromSds.ps1 -SdsPath <pinned path> -Cloud <cloud>`. Capture `regions` and `stamps[].stampName` **verbatim from SDS** — do NOT reconstruct names via grammar; SDS already stores the canonical, unpadded stamp names. Source label: `SDS`.

   **3c. YAML defaults (Phase 4.4):** If SDS returned nothing for this cloud (rare for production), fall back to `pipelines.<prodKey>.yamlIntrospection.perCloudDefaults.<cloud>.{Regions,stamps}` (or `flatDefaults` for single-cloud pipelines). Source label: `YAML defaults`.

   **3d. AzureServiceConfig + grammar (last resort, with explicit warning):** If 3a–3c are all unavailable for this cloud, fall back to the AzureServiceConfig + grammar expansion (`<region>-<layout>-<stampTag><index>`) and surface a warning to the owner. Grammar synthesis is reserved for this branch only. Source label: `AzureServiceConfig grammar (fallback ⚠)`. Always log a fallback learning.

   No "1 stamp per region (assumed)" preview — the wizard always reports the **actual** count derived from the chain above.

4. **Show the per-cloud current scope** for owner confirmation:

   ```
   Production scope — Fairfax  (source: SDS)
     Layout:   pod01
     Regions:  usva, ussc, usaz, usga (4)
     Stamps:   usva-pod01-prot1, usva-pod01-prot2, ussc-pod01-prot1, … (47 total)
   Choices: Looks right, Edit regions, Edit stamps in a region, Skip this cloud
   ```

   - **`Edit regions`** — owner can deselect regions the service does NOT actually deploy to. Persist the narrowed list.
   - **`Edit stamps in a region`** — owner can deselect stamps that aren't owned by this service inside a shared region. Persist the narrowed list.
   - **`Skip this cloud`** — record `inventory.production.<cloud> = { skipped: true, reason: "<owner free-text>" }` and exclude from production-side dry-run / drift checks.

5. **Persist with provenance:**

   ```json
   "inventory": {
     "production": {
       "cloudsActive": ["Public", "Fairfax", "Mooncake"],
       "Public": {
         "layout": "prod",
         "regions": ["eus", "wus", "eas", …],
         "stamps": [{ "stampName": "eus-prod-prot1", "region": "eus", "index": "1" }, …],
         "_scopeFrom": { "source": "Kusto live", "queryFile": "Production-DeploymentUnits.kql", "rowCount": 312, "at": "<UTC ISO>" }
       },
       "Fairfax":  { "_scopeFrom": { "source": "SDS", "sdsHash": "<sha256[:12]>", "at": "<UTC ISO>" }, … }
     }
   }
   ```

   `_scopeFrom.source` is one of: `Kusto live` | `SDS` | `YAML defaults` | `AzureServiceConfig grammar (fallback)`. The fallback label is surfaced again at Step 15 in the drift recap.

6. **Recap** to the release owner:
   - *"Current scope saved for {N} clouds, {total regions}, {total stamps}. Public finalized from Kusto ({rowCount} live rows); sovereign clouds from SDS."* (Adapt the second sentence to actual `_scopeFrom.source` values per cloud.)
   - *"This is what Phase 4.12 will POST to your production pipelines for `{{pubRegions}}` / `{{ffRegions}}` / `{{ffStamps}}`-style parameters — no CCOA filtering, no exclusion list (those don't exist at setup time). Dry-run is a **maximum-scope** preview."*
   - *"At Step 15 of every real release, the agent re-fetches AzureServiceConfig live and diffs against this current scope. If a region or stamp was added/removed, you'll see a drift table and approve the new scope before the production POST goes out. On approval, this scope is updated automatically. Re-run `setup-service group 4.7` any time to force-refresh the baseline."*

> **Drift contract for runtime** (unchanged): `Resolve-RegionScope.ps1` (Step 15) MUST:
> 1. Call `Get-AzureServiceConfig.ps1` live.
> 2. For each cloud in `inventory.production.cloudsActive`, compute `live.regions \ scope.regions` (added) and `scope.regions \ live.regions` (removed); same for stamps.
> 3. If either set is non-empty, render the diff to the owner and require explicit `Accept` before substituting tokens.
> 4. On `Accept`, merge the live values into `inventory.production.<cloud>` and bump `_scopeFrom.at`.
> 5. On `Reject`, halt Step 15 with a clear message — don't fall back to either side silently.

---

#### Phase 4.8 — BVT Kusto

The agent runs a built-in BVT failure-analysis query to decide whether canary BVTs passed. The default query expects a specific schema. Walk the release owner through it before asking for cluster details:

1. **Show the default query** by reading `.github/skills/zed-agent/queries/<default file>.kql` from disk and printing it verbatim in a fenced code block. If no default file exists in the repo yet, show the canonical version from the BVT Failure Analysis section of this spec.
2. **Show the required column contract** the agent depends on for downstream logic:
   ```
   Required columns in result rows:
     WorkLoadType, Environment, TestCaseName, IssueCategory,
     FrontLiners, Analysis, CanBeCaughtInInnerLoop
   Required placeholders in the .kql file:
     {{PIPELINE_TRIGGER_TIME}}   (appears in main query AND join subquery)
     {{RESPONSIBLE_TEAM}}        (replaced with kusto.bvt.queryVariables.RESPONSIBLE_TEAM at runtime)
   Tables referenced by default query:
     BvtDailyTestRunData (primary), BVTRawData (join — provides FrontLiners)
   ```
3. **Ask the service-fit question** via `ask_user`:
   > *"The default query above is valid for services in **Azure Backup** (it queries `BvtDailyTestRunData` / `BVTRawData`). Does your service fall under Azure Backup?*
   >
   > *If your service is NOT an Azure Backup service, you'll likely need a different mechanism for BVT failure checking — I'll walk you through the options."*
   > Choices: `Yes — Azure Backup service`, `No — not an Azure Backup service`
4. **Branch on the answer**:

   **(A) `Yes — Azure Backup service`** (default path — MAB / DPM / Prot / BDP / similar):
   - Persist the default `.kql` file path to `kusto.bvt.queryFile` (e.g., `MAB-BVT-FailureAnalysis.kql`). If the file doesn't exist in `.github/skills/zed-agent/queries/`, copy the canonical version into it now.
   - **Do NOT prompt for `kusto.bvt.cluster` or `kusto.bvt.database`** — the default query targets a fixed Azure Backup cluster/database. Write these values directly:
     - `kusto.bvt.cluster` → `https://mabprod1.kusto.windows.net/`
     - `kusto.bvt.database` → `AzureBackup`
   - Ask only **one** field:
     - `kusto.bvt.queryVariables.RESPONSIBLE_TEAM` — value used by the agent to filter rows attributable to your team (e.g., `Prot`, `MABS`)
   - Note to release owner: *"Cluster `https://mabprod1.kusto.windows.net/` and database `AzureBackup` are fixed for the default Azure Backup BVT query. If results look wrong later, you can edit `.github/skills/zed-agent/queries/{queryFile}` directly — the agent re-reads it on every run."*

   **(B) `No — not an Azure Backup service`**:
   - First, show the release owner the available BVT failure-detection mechanisms supported by this agent today:
     > *"The agent currently supports the following mechanisms for BVT failure detection:*
     > *  (1) **Custom Kusto query** — you provide a KQL query the agent runs on your team's Kusto cluster after canary BVTs complete; the result rows are treated as failures.*
     >
     > *More mechanisms may be added later."*
     > Choices: `1) Custom Kusto query`
   - On `Custom Kusto query`, walk the owner through a guided setup so the resulting query is solid and re-runnable by the agent. Persist each answer immediately:
     1. Ask `kusto.bvt.cluster` — Kusto cluster URL where the BVT data lives.
     2. Ask `kusto.bvt.database` — database name on that cluster.
     3. Ask the owner how they want to provide the KQL, via `ask_user`:
        > *"How do you want to provide your team's BVT query?"*
        > Choices: `Paste KQL now`, `Point me at a .kql file in this repo`
     4. **If `Paste KQL now`**: collect the KQL via `ask_user` (multi-line), write it to `.github/skills/zed-agent/queries/<service-name>-bvt.kql`, and persist that path to `kusto.bvt.queryFile`.
     5. **If `Point me at a .kql file in this repo`**: ask for the relative path, validate the file exists, and persist it to `kusto.bvt.queryFile`.
     6. **Make the query agent-runnable** — same negotiation flow as before: detect / inject `{{PIPELINE_TRIGGER_TIME}}`, negotiate scoping (`{{RESPONSIBLE_TEAM}}` style filter / different mechanism / no scoping), confirm failure semantics ("a returned row = a failure"), collect `kusto.bvt.displayColumns`, and prompt for any additional `{{...}}` placeholders. Persist each placeholder under `kusto.bvt.queryVariables.<NAME>` and any free-text scoping notes under `kusto.bvt.scopingNotes`.
     7. **Dry-run check (optional but recommended)**: offer to execute the finalized query once via the Kusto MCP against the cluster/database the owner just provided, using a recent `{{PIPELINE_TRIGGER_TIME}}` (e.g., `ago(7d)`) to confirm it returns rows in the expected shape. On error, surface the Kusto error verbatim and let the owner edit the file and re-run the dry-run.
     8. **Show this hard reminder** before finishing:
        > ⚠️ **Contract**: Steps 6, 8, and 11 will run this query verbatim against the cluster/database you just provided, substituting `{{PIPELINE_TRIGGER_TIME}}`, `{{RESPONSIBLE_TEAM}}`, and any other placeholders you declared. Every returned row will be reported as a BVT failure. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run; no agent code change needed.

5. After persistence, recap to the release owner what was saved (cluster, database, query file path, team filter value, display columns).

---

#### Phase 4.9 — Cluster-type detection Kusto (canary + production)

This phase configures the Kusto query the agent uses to discover **which cluster types are currently live** — for canary pipeline selection (Steps 5/7/10) and production pipeline selection (Step 10/15). The canary and production halves typically share cluster + database; the queries differ only in their `stampPrefixFilter`.

**Conditional execution.** Read `canaryRouting.mode` and `productionRouting.mode` from `pipeline-catalog.json` (set in Phase 4.2):

- If **both** are `static`, skip Phase 4.9 entirely. Recap: *"Phase 4.9 skipped — both canary and production routing are `static`; cluster-type Kusto is not needed. You can configure it later by switching either mode to `cluster-type` and re-running `setup-service group 4.9`."*
- If `canaryRouting.mode == "cluster-type"`, collect the canary half (below).
- If `productionRouting.mode == "cluster-type"`, collect the production half (below).

Both halves are persisted under `kusto.canary.*` / `kusto.production.*` and used by `Resolve-PipelinesByClusterType.ps1` + the lazy `clusterType` resolver in `Get-StampInventory.ps1`.

**Canary half** (only when `canaryRouting.mode == "cluster-type"`):

1. **Show the default canary-detection query** — print verbatim in a fenced code block:
   ```kql
   EventLogAllClusters
   | where TIMESTAMP > ago(1d)
   | where {{SERVICE_FILTER}} and DeploymentName !contains 'r-pod01'
   | where {{STAMP_PREFIX_FILTER}}
   | summarize make_set(DeploymentUnit) by StampName
   | order by StampName asc
   ```
2. **Show the required column contract**:
   ```
   Required columns in result rows:
     StampName, DeploymentUnit (a set/array of deployment unit names)
   Required placeholders in the query:
     {{SERVICE_FILTER}}        (replaced with kusto.canary.serviceFilter at runtime)
     {{STAMP_PREFIX_FILTER}}   (replaced with kusto.canary.stampPrefixFilter at runtime)
   Downstream usage:
     1) Pipeline selection (Steps 5/7/10): the agent extracts the SET of cluster
        types observed across all rows (by inspecting DeploymentUnit substrings —
        e.g., '-sfmc' → 'sfmc', '-sf' without '-sfmc' → 'sfrp'). This set is
        intersected with canaryRouting.clusterTypeMap to pick which pipelines to fire.
     2) Per-stamp clusterType: rows are joined back by StampName and the inferred
        clusterType is written to inventory.canary.stamps[*].clusterType on first
        read by Get-StampInventory.ps1. Phase 4.6 never prompts the owner for
        clusterType — Kusto is the single source of truth.
   Response parsing:
     ALWAYS use $resp.Tables[0].Rows.
   ```
3. **Ask the schema-fit question** via `ask_user`:
   > *"The default query above is valid for services in **Azure Backup**. Does your service fall under Azure Backup?"*
   > Choices: `Yes — Use default query`, `No — Use a different query`
4. **Branch**:

   **(A) `Yes — Use default query`** (default path):
   - Persist `kusto.canary.queryFile = "Canary-DeploymentUnits.kql"`. If the file doesn't exist in `.github/skills/zed-agent/queries/`, copy the canonical version above into it now. **Do NOT prompt for the filename.**
   - **Do NOT prompt for `kusto.canary.cluster` or `kusto.canary.database`** — write the Azure Backup defaults directly:
     - `kusto.canary.cluster` → `https://mabprod1.kusto.windows.net/`
     - `kusto.canary.database` → `MABKustoProd1`
   - Persist `kusto.canary.clusterTypeExtraction = { mode: "deployment-unit-substring" }`.
   - Ask only the **2 filter fields** (one at a time, persist after each):
     - `kusto.canary.serviceFilter` — KQL `where` predicate that selects rows belonging to your service (e.g., `ServiceName == 'prot'`). Substituted into `{{SERVICE_FILTER}}` at runtime.
     - `kusto.canary.stampPrefixFilter` — KQL `where` predicate that narrows `StampName` to your service's canary stamps. Substituted into `{{STAMP_PREFIX_FILTER}}` at runtime.

       **Canary stamp filter shape (service-agnostic guidance):** The value is a KQL `where`-clause fragment over the `StampName` column. The general shape is `StampName startswith '<prefix1>' or StampName startswith '<prefix2>' …`. Replace `<prefix...>` with the short-name prefixes your service uses for canary stamps. Leave empty if your custom `.kql` file does not use the `{{STAMP_PREFIX_FILTER}}` placeholder.

       **Conditional default offer:** If `service.name` matches a known MAB-family service (case-insensitive regex `^(WBCM|DM|Prot)$`), offer the MAB-historical predicate `StampName startswith 'ea-can' or StampName startswith 'ecy' or StampName startswith 'ccy'` as a suggested default via `ask_user` — but make clear this is a current snapshot of the value (not an authoritative shape) and the owner is free to edit. For all other services, present `ask_user` with **no pre-filled value** and the shape guidance above.

   **(B) `No — Use a different query`** — walk the owner through the custom-query flow (cluster, database, paste-vs-file, scoping reconciliation, `clusterTypeExtraction` mode selection, `resultColumns`). Persist under `kusto.canary.*`.

5. **Hard reminder** before finishing the canary half:
   > ⚠️ **Contract**: Steps 5/7/10 will run this query verbatim, substituting `{{SERVICE_FILTER}}` / `{{STAMP_PREFIX_FILTER}}` / any custom placeholders. The agent then (a) extracts the SET of cluster types via `kusto.canary.clusterTypeExtraction` and intersects with `canaryRouting.clusterTypeMap` (Phase 4.2) to pick canary pipelines, and (b) joins rows back by `StampName` to fill `inventory.canary.stamps[*].clusterType`. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run.

**Production half** (always collected when the production scope is non-empty — Phase 4.7 step 3a depends on it for Public-cloud inventory finalization; also required when `productionRouting.mode == "cluster-type"` for the resolver):

Mirrors the canary half but persists under `kusto.production.*`. **Two queries are collected, not one** — they have different shapes and different consumers:

| Field | Default file | Consumed by | Shape |
|---|---|---|---|
| `kusto.production.inventoryQueryFile` | `Production-StampInventory.kql` | Phase 4.7 step 3a, `Get-StampInventory.ps1 -Scope production` (inventory path) | `EventLogAllClusters \| where {{SERVICE_FILTER}} and DeploymentName !contains 'r-pod01' \| where {{STAMP_PREFIX_FILTER}} \| distinct StampName` |
| `kusto.production.queryFile`          | `Production-DeploymentUnits.kql` | `Resolve-PipelinesByClusterType.ps1 -Scope production` (Step 10, cluster-type resolver) | `… \| summarize make_set(DeploymentUnit) by StampName` |

If the file doesn't exist in `.github/skills/zed-agent/queries/`, copy the canonical version above into it now. **Do NOT prompt for the filenames.**

Other defaults (shared by both queries):

- `kusto.production.cluster` → `https://mabprod1.kusto.windows.net/` (Azure Backup default).
- `kusto.production.database` → `MABKustoProd1` (Azure Backup default).
- `kusto.production.clusterTypeExtraction` → `{ mode: "deployment-unit-substring" }` (only used by the cluster-type query).
- **Auto-derive `kusto.production.stampPrefixFilter` from AzureServiceConfig — do NOT prompt**:
  1. Run `Get-AzureServiceConfig.ps1` to load the snapshot.
  2. Select the `Public` cloud entry and collect the distinct lower-cased `ShortName` values from `DataCenters[]`.
  3. Persist the sorted distinct list to `kusto.production.stampPrefixFilter`. At runtime `Get-StampInventory.ps1` joins them into `StampName startswith 'eus' or StampName startswith 'wus' or …` and substitutes into `{{STAMP_PREFIX_FILTER}}`.
  4. Recap: *"Auto-filled `kusto.production.stampPrefixFilter` from AzureServiceConfig Public cloud (N short names). Edit `service-config.json` directly any time to add/remove entries — the wizard will not overwrite a non-empty value on re-run."*
  5. **Sovereign clouds note**: this query covers Public only — Fairfax / Mooncake / USNat / USSec stamps live in AME-tenant Kusto this agent cannot reach. SDS (Phase 4.5) is the stamp source for them; cluster-type for sovereign-cloud stamps remains out-of-band (mechanism TBD).
- Ask only `kusto.production.serviceFilter`.

> ⚠️ **Contract**: Step 10 (Roll-Forward) and Step 15 (Production Rollout) will invoke `Resolve-PipelinesByClusterType.ps1 -Scope production` **once per release** — not per cloud. The resolver runs this query verbatim, extracts cluster types, and intersects with `productionRouting.clusterTypeMap` to decide which production pipeline(s) to trigger. Each resolved pipeline then pushes to whichever clouds are listed under `ev2CloudCoverage.<key>` (Phase 4.13).

Recap to the release owner what was saved for each half (cluster, database, query file path, filters). If the release owner uses the **same** Kusto cluster/database for canary and production, keep them as separate config keys — that's fine, just enter the same values.

---

#### Phase 4.10 — Per-pipeline parameter proposal

For each pipeline (official build + canary + production), synthesize a single proposed `templateParameters` map from (a) prior-run values captured in Phase 4.3 and (b) YAML parameter declarations captured in Phase 4.4. The owner reviews and accepts per pipeline — this is the **single point of human approval** between discovery and the dry-runs in Phase 4.11 / 4.12.

#### Reserved placeholders

The agent reserves these `{{...}}` tokens and substitutes them at runtime — **never** ask the owner to provide a value for them, and **never** drop them when they appear inside `templateParameters` discovered from prior runs or YAML:

- `{{currentBranch}}` — replaced with the active release branch as a **SHORT** name (e.g., `releases/svc2604`, NOT `refs/heads/releases/svc2604`). templateParameters whose YAML type is `string` and whose name contains `Branch` / `BranchName` are consumed by the YAML as plain short branch identifiers, not git refs. Only `resources.repositories.self.refName` in the run-queue body uses the full `refs/heads/<short>` form. Any token-as-full-ref will make ADO try to resolve the value as a pipeline-version identifier and return `400 No version was found for the pipeline`.
- `{{canaryStamps}}`, `{{canaryRegions}}` — replaced with the live `inventory.canary.stamps[].stampName` / distinct `inventory.canary.stamps[].region` from `service-config.json` (Phase 4.6). For `cluster-type` routing, the agent further filters by the pipeline's declared `clusterType` (Phase 4.2) before joining into the parameter format the pipeline expects (CSV, JSON array, etc. — auto-detected from prior-run shape in `canary.<key>.discoveryNotes.stampNameStyle`).
- `{{excludeStamps}}`, `{{pubRegions}}`, `{{ffStamps}}`, `{{ffRegions}}` (and any cloud-prefixed analogues like `{{mcRegions}}`, `{{mcStamps}}`) — at **real release time** (Step 15), replaced with CCOA / SafeFly-narrowed region scope minus the live exclusion list. Source universe is `inventory.production.<cloud>` (Phase 4.7); CCOA filter and exclusion list narrow it. At **dry-run time** (Phase 4.12), only the universe applies.
- `{{sdpType}}`, `{{validateOnly}}` — replaced based on rollout mode.

> **Why canary stamps are tokenized, not literal**: prior runs are stale by definition — a stamp added or decommissioned since the last successful run would silently rot into `templateParameters` and only surface at real-release time. Phase 4.6 is the owner-curated source of truth, validated against AzureServiceConfig. Treating canary stamp/region values as reserved tokens makes the dry-run an honest preview of what the next real run will send: shape learned from prior runs, values pulled live from Phase 4.6.

When the agent shows owner-facing diffs, render these as **highlighted tokens with a one-line tooltip** explaining the runtime substitution.

#### Catalog completeness check (end of Phase 4.10)

After the owner accepts the proposed `templateParameters` for a pipeline, the agent MUST run **two** intersections — against the YAML (catalog drift) and against the inventory (cluster-type contamination) — **before** moving to the next pipeline:

**A. YAML intersection (catalog drift):** Intersect the accepted map's keys with `pipelines.<key>.yamlIntrospection.parameters[].name` (Phase 4.4) and surface drift in both directions:

- **Undeclared params** — keys in `templateParameters` that the YAML on `ado.baseBranch` does NOT declare. ADO will reject the entire queue request on any one of these (full rejection, not a warning), so they MUST be reconciled now — either dropped from the catalog or added to the YAML. Persist any kept-anyway entries to `<scope>.<key>._learnedFrom.dryRun.droppedParams[]` so Phase 4.12 can drop them at queue time and Step 15 can refuse to fire until the YAML is amended.
- **Required-but-missing params** — YAML-declared params with no default and no entry in the accepted map. Already checked by the existing required-param logic; mentioned here only for symmetry.

**B. Cluster-type precondition (inventory contamination):** When `canaryRouting.mode == "cluster-type"` (canary scope) or `productionRouting.mode == "cluster-type"` (production scope), the agent MUST verify:

1. `<scope>.<key>.clusterType` is non-empty for every pipeline whose params are being proposed.
2. That `clusterType` appears in the live set returned by inventory: `distinct(inventory.<scope>.stamps[].clusterType)` (Phase 4.6 for canary, Phase 4.7 for production). A pipeline whose declared `clusterType` doesn't match any stamp's `clusterType` will, by definition, be triggered with stamps it has no business touching.
3. Every stamp the proposed `templateParameters` would substitute into `{{canaryStamps}}` / `{{canaryRegions}}` / `{{pubRegions}}` / etc. — derived via `Resolve-TemplateParams.ps1` — must share that pipeline's `clusterType`. The resolver throws `CLUSTER_TYPE_CONTAMINATION:` listing the offending stamps; the agent refuses to persist the proposal and surfaces the list to the owner with the explicit instruction to either fix `<scope>.<key>.clusterType`, fix the offending stamps' `clusterType` in inventory, or fix the routing mode.

Do NOT defer either check to Phase 4.12 — catching contamination at proposal time avoids both a wasted dry-run cycle and the much worse failure mode of an SFRP stamp routed to an SFMC pipeline.

#### Auth & cost

Every ADO REST call in Phase 4.10 / 4.11 / 4.12 uses the same `az login` identity that runs `setup` / `setup-service`. The token is acquired on the fly with `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798` (the fixed Azure DevOps resource GUID). No PAT, no separate sign-in. If a call returns 401, run `Repair-AzAuth.ps1 -Tenant 'microsoft.com'` and retry once; on 403, halt with the explicit message *"Your account lacks Pipelines (write) on `{org}/{project}`. Ask your project admin to grant `Build Service (queue/cancel)` permission, then re-run `setup-service group 4.10`."*

#### Merge logic

For each pipeline key, fan out in parallel using `ForEach-Object -Parallel` and:

1. **Baseline**: union of all parameters declared in `pipelines.<key>.yamlIntrospection.parameters` (Phase 4.4).
2. **Concrete values — schema source (last 3 runs)**: prior-run values from `<scope>.<key>._learnedFrom.runs[].templateParameters` (Phase 4.3), mode-of-values across the runs (most common wins). This pass establishes the **shape** of each parameter (CSV vs JSON array, naming style, whether the param exists at all). If the runs disagree on a value, flag the parameter as `mode-disagreement` in `agentGaps` — do NOT pick a winner yet, defer to step 2b.
2b. **Concrete values — value-of-truth (reference run)**: if `<scope>.<key>._learnedFrom.referenceRun` is set (Phase 4.3 reference-run capture, production scope only), for every parameter that is either flagged `mode-disagreement` from step 2 OR has a different value in the reference run than the 3-run mode, **prefer the reference-run value**. Tag the parameter's source as `reference-run` so the proposal block can render the lineage. Reserved tokens (step 3 below) still win over both — the reference run only resolves literal-value ambiguity, it never overrides a token.
3. **Reserved-token preservation**: if a prior-run value matches one of the reserved `{{...}}` tokens **or** the YAML's `default` is a reserved token, keep it as the token (do not substitute the literal from history, and ignore the reference run for this parameter).
4. **Canary stamp / region detection (token replaces literal)**: prior-run values are excellent for *teaching the agent the parameter shape* (CSV vs JSON array, naming style, count) but they are **not** trusted as the actual values to send — Phase 4.6's `inventory.canary.stamps` is the truth. For each parameter whose prior-run value looks like a canary stamp list or canary region list (values are a subset of `inventory.canary.stamps[].stampName` / distinct `inventory.canary.stamps[].region`, or look like `<region>-<layout>-<stampTag><index>` triples), **replace the literal with the matching reserved token** (`{{canaryStamps}}` or `{{canaryRegions}}`) in the proposal. Record the detected delivery shape (CSV / semicolon-list / JSON array) under `canary.<key>.discoveryNotes.stampNameStyle` so the runtime substitution knows how to join the inventory values. If detection is ambiguous (prior-run value contains stamps NOT in `inventory.canary.stamps`), flag `agentGaps: stamp-list-drift: [<stamps not in inventory>]` and surface in the proposal review.
5. **Production stamp / region detection** — same shape, against `inventory.production.<cloud>` (Phase 4.7); tokens become `{{pubRegions}}` / `{{ffStamps}}` / etc. depending on the matching cloud.
6. **Cluster-type cross-check**: if `canaryRouting.mode == "cluster-type"` (or production equivalent) and the owner declared `entry.clusterType` in Phase 4.2, scan the YAML and prior runs for stamp-list / region-list parameters whose values cluster around a single suffix (e.g., all entries end in `-sfmc`). If the inferred suffix **disagrees** with the owner-declared cluster type, flag `agentGaps: clusterType-mismatch: declared <X>, evidence suggests <Y>`. If `clusterType` was NOT declared, fall back to the inferred value as the proposal.
7. **Unknown / new params**: parameters in YAML that have no prior-run value and no `default` → mark `requiresOwnerInput: true` in the proposal.

#### Render the proposal

Show the owner a single review block per pipeline:

```
┌─ Pipeline: SVC-SFMC (3527) ──────────────────────────────────────┐
│ YAML:  Mgmt-RecoverySvcs-BackupDataPlane/pipelines/canary.yml    │
│        @ develop · sha 7a3f4b1                                   │
│ Prior: run 28471 (2026-05-19), 28392 (2026-04-22), 28203 (2026-03-24) │
│ Reference run: #28471 (2026-05-19) — nominated by alice@…         │
│   "May 2026 release — clean prod push, all clouds, no skips"     │
│                                                                  │
│ Proposed templateParameters:                                     │
│   ServiceTreeId      = "<guid>"            ← prior runs (all 3)  │
│   SourceBranch       = "{{currentBranch}}" ← YAML default token  │
│   PubCanaryStamps    = "{{canaryStamps}}"  ← detected (canary)   │
│   PubRegions         = "*"                 ← reference run #28471 │
│   ExcludeStamps      = ""                  ← reference run #28471 │
│   SdpType            = "{{sdpType}}"       ← reserved token      │
│   ValidateOnlyRollOut= "{{validateOnly}}"  ← reserved token      │
│                                                                  │
│ clusterType: "sfmc" (declared in Phase 4.2 · ✓ matches evidence)│
│                                                                  │
│ Gaps the agent could not resolve:                                │
│   • RolloutNotes — declared in YAML, no prior value, no default  │
└──────────────────────────────────────────────────────────────────┘
Choices: Accept, Edit a value, Reject, Show diff vs YAML defaults
```

Rules for rendering the `clusterType` line:
- If routing mode is `static` for this scope → omit the line.
- If owner **declared** in Phase 4.2 and the cross-check agrees → show `clusterType: "<declared>" (declared in Phase 4.2 · ✓ matches evidence)`.
- If owner **declared** but the cross-check disagrees → show with `⚠ evidence suggests "<inferred>"` and also list the discrepancy in **Gaps** — must be resolved before `Accept` is allowed.
- If owner did **not** declare it → show `clusterType: "<inferred>" (inferred from <evidence source> — please confirm)` and treat as a gap.

Rules for rendering the per-parameter source-of-value annotation (right-hand side of each line):
- `← prior runs (all 3)` — all 3 auto-captured runs agreed on this literal value.
- `← reference run #<id>` — either the 3 runs disagreed and the reference broke the tie, or the reference value differs from the 3-run mode. Always render the run id so the lineage is auditable.
- `← YAML default token` / `← reserved token` — token preservation path (merge step 3). Wins over both run sources.
- `← detected (canary)` / `← detected (<cloud>)` — stamp/region literal collapsed to a token by merge step 4/5.
- The `Reference run:` header line is omitted entirely when `_learnedFrom.referenceRun` is null (owner skipped in Phase 4.3).

Loop on the choice until owner picks `Accept` or `Reject`. On `Edit a value` ask which key, collect new value via `ask_user`, re-render. On `Reject`, drop to the legacy paste-YAML / paste-JSON / manual flow as a fallback.

#### Persist

- `<scope>.<key>.templateParameters` = accepted map (with reserved tokens preserved as strings).
- `<scope>.<key>._learnedFrom` = `{ runIds: [...], referenceRunId: <int|null>, yamlPath, yamlRepo, yamlBranch, yamlSha, learnedAt: <UTC ISO> }`
- `<scope>.<key>._learnedFrom.referenceRun` (production pipelines that nominated one) = `{ runId, runUrl, finishedAt, sourceBranch, templateParameters, nominatedAt, nominatedBy, reason }` — the full payload captured in Phase 4.3; preserved so Phase 4.10 can re-merge on rerun without re-prompting the owner.
- `<scope>.<key>._learnedFrom.valueSources` (optional, debug) = per-parameter `{ <paramName>: "prior-runs-mode" | "reference-run" | "reserved-token" | "yaml-default" | "detected-canary" | "detected-<cloud>" }` so the proposal block's right-hand annotations remain auditable on rerun.
- `<scope>.<key>.discoveryNotes` = `{ exclusionFormat: <auto-detected>, stampNameStyle: <auto-detected>, freeText: "" }`
- `<scope>.<key>.agentGaps` = list of unresolved-gap descriptions (empty array on full success).
- If routing mode is `cluster-type` and a `clusterType` was inferred (or owner overrode Phase 4.2's declared value), persist `<scope>.<key>.clusterType` and update `<scope>Routing.clusterTypeMap[<clusterType>]`.

Underscore-prefixed fields (`_learnedFrom`) are stripped by the schema-driven empty-skeleton generator but accepted by the validator — they're metadata, not config.

---

#### Phase 4.11 — Canary resolver + canary dry-run

> **Phase 4.11 step 1 is a resolver invocation only.** The Kusto cluster / database / query file / filters used to discover which canary cluster types are currently live were collected in **Phase 4.9 canary half**. Step 1 invokes `Resolve-PipelinesByClusterType.ps1 -Scope canary` between Phase 4.10 (parameter proposal) and Phase 4.11 step 2 (dry-run fan-out) so the dry-runs only fire for currently-live pipelines.

**Step 1 — Canary cluster-type resolver invocation:**

Read `pipeline-catalog.json → canaryRouting.mode` (set during Phase 4.2). Branch:

- **`mode == "static"`** — no resolution needed. The resolver returns every `canary.*` key. Recap: *"Phase 4.11 step 1: canary routing is `static`, all canary pipelines participate in the dry-run fan-out."* Exit to step 2.
- **`mode == "explicit"`** (or `_pendingExplicitList` schema-fallback equivalent) — no resolution needed; per-key triggering is narrowed by the static `canaryStamps` / `canaryRegions` list at real-release time. Show the brittleness reminder:
  > ⚠️ **Brittleness reminder**: the agent will trigger canary pipelines based on the static `canaryStamps` / `canaryRegions` list. Keep that list fresh when the org rebalances. To switch to dynamic Kusto-driven routing later, re-run `setup-service group 4.2` and change `canaryRouting.mode` to `cluster-type`. The Phase 4.9 canary-half config is already in `service-config.json` and will be used automatically.

  Exit to step 2.
- **`mode == "cluster-type"`** — proceed. Verify Phase 4.9 canary half exists (`kusto.canary.cluster`, `.database`, `.queryFile` all set); if not, halt with *"Phase 4.9 canary half has not been collected yet. Re-run `setup-service group 4.9` first, then re-run `setup-service group 4.11`."* Then invoke the resolver:

  ```powershell
  $res = & .\.github\skills\zed-agent\scripts\Resolve-PipelinesByClusterType.ps1 -Scope canary
  $canaryKeys = @($res.resolved | ForEach-Object { $_.pipelineKey })
  ```

  On error, surface the Kusto error verbatim and let the owner edit `kusto.canary.queryFile` (the agent re-reads it on every run) or re-run Phase 4.9. Recap the resolved set, the cluster types observed, and the skipped keys.

**Step 2 — Canary dry-run fan-out:**

Show the **dry-run consent banner** once, before queueing anything:

> *"I've finished analyzing prior runs and YAML for every canary pipeline, and you've accepted the proposed parameters in Phase 4.10. Next, I'll queue a real ADO run per pipeline with those parameters and cancel each within 5 seconds — well before any agent picks it up. You'll see a cancelled run in ADO history; nothing actually deploys. This validates that the parameters I learned are correct and that I have the right ADO permissions. OK to proceed?"*

On `No`, halt and tell the owner they can re-run with `setup-service group 4.10` to keep the accepted proposals on disk and skip the queue-and-cancel validation (less safe — parameter mistakes won't surface until the first real release).

On `Yes`, fan out a dry-run for the resolved set in parallel:

```powershell
$results = $canaryKeys | ForEach-Object -Parallel {
    & .github/skills/zed-agent/scripts/Invoke-PipelineDryRun.ps1 `
        -Organization $using:org `
        -Project $using:project `
        -PipelineKey $_ `
        -CatalogPath $using:catalogPath `
        -CancelAfterSeconds 5
} -ThrottleLimit 8
```

`Invoke-PipelineDryRun.ps1` performs, per pipeline:

1. Resolve the entry from `pipeline-catalog.json`. Substitute reserved tokens with the **same values a real release would send today** — exceptions: the branch (dummy ref) and the rollout-mode tokens (force `validateOnly = true`):
   - `{{currentBranch}}` → SHORT branch name from `ado.baseBranch` (e.g., `develop` — not `refs/heads/develop`). templateParameters take short form.
   - `{{canaryStamps}}` → joined `inventory.canary.stamps[].stampName` (Phase 4.6), filtered by `entry.clusterType` when `canaryRouting.mode == "cluster-type"`, joined using `canary.<key>.discoveryNotes.stampNameStyle`.
   - `{{canaryRegions}}` → joined `inventory.canary.regions` using the same style.
   - `{{excludeStamps}}` → `""` *(dry-run never excludes anything)*.
   - `{{pubRegions}}`, `{{ffRegions}}`, `{{ffStamps}}`, `{{mcRegions}}`, `{{mcStamps}}`, … — for **canary** dry-run, `""`; for **production** dry-run (Phase 4.12), joined from `inventory.production.<cloud>`. Cloud inferred from token prefix; unmapped tokens flag `agentGaps: token-cloud-unmapped: <token>`.
   - `{{sdpType}}` → `"Express"`
   - `{{validateOnly}}` → `"true"`
2. `POST https://dev.azure.com/{org}/{project}/_apis/pipelines/{id}/runs?api-version=7.1-preview.1` with body `{ "resources": { "repositories": { "self": { "refName": "refs/heads/<ado.baseBranch>" } } }, "templateParameters": <substituted map> }`. Note: `refName` is the only place that uses the FULL `refs/heads/<short>` form; everything in `templateParameters` uses short names. Capture `runId` and `runUrl`.
3. Sleep 5 seconds.
4. `PATCH https://dev.azure.com/{org}/{project}/_apis/build/builds/{runId}?api-version=7.0` with body `{ "status": "cancelling" }` (retry up to 3 times).
5. Return `{ pipelineKey, runId, runUrl, queuedAt, cancelledAt, finalState, queuedParameters }`.

Aggregate results and render an owner review block:

```
Canary dry-run results — 3 pipelines, all queued and cancelled.

✓ SVC-SFMC    run #28591 cancelled @ +4.8s  → <url>
✓ SVC-SFRP    run #28592 cancelled @ +5.1s  → <url>
✗ SVC-EAP     run #28593 queue FAILED — HTTP 400: "PubCanaryStamps invalid format"

Open run pages and verify the queued-run parameters match your expectations.
When done, tell me which (if any) had discrepancies.

Choices: All good → continue to production, Report a discrepancy, Re-run dry-runs
```

On `Report a discrepancy`, enter the **discrepancy loop**:

1. Ask which pipeline.
2. Ask what's wrong (free-text via `ask_user`).
3. Classify the fix:
   - **(a) Catalog-only fix** — owner gives a corrected value; agent updates `canary.<key>.templateParameters` and re-runs the dry-run for that one pipeline.
   - **(b) Reserved-token semantics drift** — same as (a) but record the discrepancy in `canary.<key>.discoveryNotes.freeText`.
   - **(c) Skill / agent.md edit required** — trigger the MD edit proposal flow (show current text + proposed text, persist as `md-edit-proposal` in `audit.jsonl`, apply on owner confirmation).
4. Re-run the dry-run for that pipeline and loop until the owner says `All good`.

Persist `_validated` per pipeline once its dry-run is clean: `canary.<key>._validated = { at: <UTC ISO>, lastDryRunId: <id>, by: <owner email or 'wizard'> }`.

---

#### Phase 4.12 — Production resolver + production dry-run

Mirrors Phase 4.11 for production pipelines.

**Step 1 — Production cluster-type resolver invocation:**

Read `pipeline-catalog.json → productionRouting.mode` (set during Phase 4.2). Branch:

- **`mode == "static"`** — no resolution needed. The resolver returns every `production.*` key. Recap: *"Phase 4.12 step 1: production routing is `static`, all production pipelines participate in the fan-out; each pipeline pushes to whichever clouds are listed under `ev2CloudCoverage.<key>` (Phase 4.13)."* Exit to step 2.
- **`mode == "cluster-type"`** — proceed. Verify Phase 4.9 production half exists (`kusto.production.cluster`, `.database`, `.queryFile` all set); if not, halt with *"Phase 4.9 production half has not been collected yet. Re-run `setup-service group 4.9` first, then re-run `setup-service group 4.12`."* Then invoke:

  ```powershell
  $res = & .\.github\skills\zed-agent\scripts\Resolve-PipelinesByClusterType.ps1 -Scope production
  $prodKeys = @($res.resolved | ForEach-Object { $_.pipelineKey })
  ```

  Surface Kusto errors verbatim. Recap the resolved set, observed cluster types, and skipped keys.

**Step 2 — Production dry-run fan-out:**

Reinforce the consent banner: *"Each resolved production pipeline will receive a queued-then-cancelled run — same 5-second window. EV2 will NOT fire because cancellation happens before the agent picks up the work. A production pipeline that targets multiple clouds is still dry-run only once — cloud-fan-out happens at real-release time in Step 15, not here."*

Fan out using `Invoke-PipelineDryRun.ps1 -PipelineKey "production:<key>"`. Substituted region/stamp values come from `inventory.production.<cloud>` (Phase 4.7) — a **maximum-scope** preview, no CCOA filter and no exclusion list. If `inventory.production` is empty (owner skipped Phase 4.7), surface a warning that the dry-run will only validate parameter *shape*, not values, and recommend running `setup-service group 4.7` first.

**Step 15 drift handshake** — the baseline persisted in `inventory.production.<cloud>` is the **same** baseline `Resolve-RegionScope.ps1` diffs against at real-release time. A clean dry-run today means the next real release only prompts for drift if AzureServiceConfig actually changed since this scope, not because dry-run and real-release have different scope-computation paths. (Drift contract: see end of Phase 4.7.)

Validation loop is identical to Phase 4.11 step 2 — aggregate, render the review block, run the discrepancy loop, persist `production.<key>._validated` on success.

If `productionRouting.mode == "cluster-type"`, the per-pipeline `clusterType` inference (Phase 4.10) runs against production runs / YAML and populates `productionRouting.clusterTypeMap`.

Any `production.*` entry whose declared `clusterType` is NOT in the live set is surfaced in `$res.skipped` with `reason: "no live cluster type matched at query time"` — record `production.<key>._validated = { skipped: true, reason: "no live cluster type", resolvedAt: <UTC ISO> }` and tell the owner the pipeline remains in the catalog and will be dry-run automatically next time its cluster type appears in Kusto.

---

#### Phase 4.13 — EV2 metadata

For each pipeline key (canary + production), collect:

- **EV2 Service Groups** — `ev2ServiceGroups.<key>` = EV2 ServiceGroup name (e.g., `Microsoft.Azure.Backup.<Service>.<Component>.ACTIVE`).
- **EV2 Cloud Coverage** — `ev2CloudCoverage.<key>` = array of clouds (`Prod`, `Fairfax`, `Mooncake`, `USNat`, `USSec`).

> **Do NOT prompt for `ev2ServiceTreeIds.<cloud>` here.** Group 3 already collected one Service Tree ID and persisted the same GUID to `serviceTreeIds.ev2.Prod`, `.Fairfax`, and `.Mooncake`. Phase 4.13 reuses those values verbatim — only ask the owner for an EV2 Service Tree ID if a cloud appears in `ev2CloudCoverage.<key>` that has no entry under `serviceTreeIds.ev2.*` (e.g., the owner enables `USNat` / `USSec` here and Group 3 never set those). In that case ask once per missing cloud and persist to `serviceTreeIds.ev2.<cloud>`.

**Cross-check cloud coverage** against `pipelines.<key>.yamlIntrospection.cloudsDetected` (Phase 4.4). On mismatch, ask the owner one of two things:

- YAML targets clouds NOT in `ev2CloudCoverage` → *"The pipeline `<key>` YAML targets `<extra>` but `ev2CloudCoverage.<key>` does not list them. Add to coverage, or remove from YAML?"*
- YAML omits clouds listed in `ev2CloudCoverage` → *"`ev2CloudCoverage.<key>` lists `<missing>` but the pipeline YAML does not target them. Trim coverage, or amend YAML?"*

Record the owner's resolution as an `audit.jsonl` event `yaml-coverage-discrepancy`. Do not auto-write either side — the owner edits the YAML or `ev2CloudCoverage.<key>` explicitly.

Tell the owner: *"This metadata isn't validatable by dry-run — it only matters at the EV2 monitoring stage of Step 15. If something's wrong here, it'll surface as a missing dashboard row, not a queue failure."*

---

**Group 5a — Notifications (Groups)**
Ask for:
- `notifications.groups.permanent` — Email addresses that receive important release notifications (array)
- `notifications.groups.cc` — CC recipients (array)
- `notifications.groups.teams` — Teams chat names for notifications (array)
- `notifications.groups.teamsExtended` — Extended Teams chats for commit requests (array, can be subset of teams)

**Group 5b — Notifications (Routing)**

Routing is **per step, per outcome**. Each of the 16 pipeline steps has three outcomes:

- **success** — step finished OK (also covers `skipped` and intermediate progress like EV2 stage ticks).
- **failure** — step ended in failure.
- **halt** — pipeline paused (unexpected halt OR waiting for an approval gate).

The **current** release owner's personal email is **always** added to every notification by `Resolve-NotificationRecipients.ps1` on top of whatever's in the cell. **Empty arrays mean current-owner-only.** Add any group from Group 5a to widen further.

Ensure the per-step routing block exists in `service-config.json` first — if `notifications.routing` is missing, write all 16 steps × 3 outcomes with empty `{ "emailGroups": [], "ccGroups": [], "teamsGroups": [] }` cells plus the four seeded non-default success cells from the Generation section. Then read it back and **render the full 16-step table** to the release owner. Use `—` (em dash) for empty/current-owner-only cells. Each outcome cell shows `emailGroups` / `ccGroups` / `teamsGroups` separated by ` / `.

Example of what the agent renders (with the owner's actual values, not these placeholders):

| Step | success (email / cc / teams) | failure (email / cc / teams) | halt (email / cc / teams) |
| ---- | ---------------------------- | ---------------------------- | ------------------------- |
| `1-send-reminder` | `permanent` / — / `teams` | — / — / — | — / — / — |
| `2-cut-branch` | — / — / — | — / — / — | — / — / — |
| `3-wait-build` | — / — / — | — / — / — | — / — / — |
| `4-collect-commits` | — / — / `teamsExtended` | — / — / — | — / — / — |
| `5-deploy-canary` | — / — / — | — / — / — | — / — / — |
| `6-bvt-check` | — / — / — | — / — / — | — / — / — |
| `7-rollback` | — / — / — | — / — / — | — / — / — |
| `8-post-rollback-bvt` | — / — / — | — / — / — | — / — / — |
| `9-post-rollback-signoff` | — / — / — | — / — / — | — / — / — |
| `10-roll-forward` | — / — / — | — / — / — | — / — / — |
| `11-post-rollforward-bvt` | — / — / — | — / — / — | — / — / — |
| `12-post-rollforward-signoff` | — / — / — | — / — / — | — / — / — |
| `13-create-r2d` | — / `cc` / — | — / — / — | — / — / — |
| `14-crb-review` | — / — / — | — / — / — | — / — / — |
| `15-production-rollout` | `permanent`, `cc` / — / — | — / — / — | — / — / — |
| `16-merge-back` | — / — / — | — / — / — | — / — / — |

After the table, add this one-line footnote:

> *— means current-owner-only. The current release owner's personal email is on the To-line of every notification regardless of what's in the table. Add any group from Group 5a to widen further.*

Then ask:

> *"Edit routing?"*
> Choices: `Keep as-is`, `Edit a cell`, `Done`

Loop on the choice until the owner picks `Keep as-is` or `Done`:

- **`Edit a cell`** — ask for the step (e.g., `6-bvt-check`), then the outcome (`success` / `failure` / `halt`), then which fields to change (`emailGroups`, `ccGroups`, `teamsGroups`). For each field, collect a comma-separated list of group keys from `notifications.groups` (Group 5a) and validate every entry against that list; re-ask on invalid input. To clear a cell back to current-owner-only, pass an empty list. Persist immediately and re-render the table.

After the loop exits, run schema validation on the persisted routing block. If validation fails (e.g., owner referenced a group key not in Group 5a), surface the exact error and re-prompt for the offending cell only.

> An owner can re-run just routing later with the shortcut `setup-service group 5b`. Re-running starts from the current table.

**Group 6 — SafeFly / R2D**
Ask for:
- `safefly.titleTemplate` — R2D title template. Suggest: `[MAB][{serviceName}] {serviceDisplayName} monthly release for {month}-{yy}`
- `safefly.tags` — SafeFly tags array (e.g., ["Prot_Regular_Rollout"])
- `safefly.additionalNotifiers` — Extra emails notified on SafeFly changes (array)
- `safefly.monitoringLink` — Monitoring link (e.g., Geneva MDM dashboard URL)
- `safefly.serviceGroupName` — **Optional override.** SafeFly `DeploymentDetails.DeploymentToolInputs.ServiceGroupName`. Default behavior is to derive this from `pipeline-catalog.json → ev2ServiceGroups` (the values collected in Phase 4.13): if all production pipelines share one value, it's used automatically; if they diverge, the SafeFly script throws and the owner must set this override to pick which one SafeFly attaches the R2D to. Do not prompt unless the owner explicitly opts in or `New-SafeFlyRequest.ps1` reports the ambiguity error.

**Group 7 — Commit Excel**
Ask for:
- `commitExcel.sheetNameTemplate` — Sheet name template (e.g., "Prot{{YYMM}}Commits"). `{{YYMM}}` is replaced at runtime.
- `commitExcel.sharePointFolder` — SharePoint folder path (e.g., "/Shared Documents/Monthly Releases")

**Group 8 — SharePoint**
Ask for:
- `sharepoint.sitePath` — SharePoint site path for Graph API auto-detection (e.g., "/teams/AzureBackupDataPlane", "/teams/MyTeamSite")

Tell the release owner: *"This is the path portion of your team's SharePoint site URL. For example, if your SharePoint is at `microsoft.sharepoint.com/teams/MyTeam`, enter `/teams/MyTeam`."*

**Group 9 — Operational Parameters**
Show defaults and ask if the release owner wants to change any:
- `operational.buildTimeoutMinutes` — default: 360 (6 hours)
- `operational.bvtWaitHours` — default: 24
- `operational.canaryBakeTimeHours` — default: 24
- `operational.watcherPollIntervalSeconds` — default: 3600 (1 hour)
- `operational.watcherTaskPrefix` — default: "ZED-ReleaseWatcher"

Tell the release owner: *"These defaults work well for most services. Only change if your service has specific timing requirements."*

**Group 10 — Step Gates**
Show all 16 steps with their default gate settings:

```
Step 1  send-reminder:            OFF
Step 2  cut-branch:               OFF
Step 3  wait-build:               OFF
Step 4  collect-commits:          OFF
Step 5  deploy-canary:            OFF
Step 6  bvt-check:                ON   ← release owner reviews BVT results
Step 7  rollback:                 OFF
Step 8  post-rollback-bvt:        OFF
Step 9  post-rollback-signoff:    ON   ← release owner approves post-rollback
Step 10 roll-forward:             OFF
Step 11 post-rollforward-bvt:     OFF
Step 12 post-rollforward-signoff: ON   ← release owner approves post-rollforward
Step 13 create-r2d:               OFF
Step 14 crb-review:               ON   ← ALWAYS ON (non-overridable)
Step 15 production-rollout:       OFF
Step 16 merge-back:               OFF
```

Explain what a gate is, then ask whether to change defaults. Use this exact phrasing:

> *"A **gate** is a pause point. When a step's gate is **ON**, the pipeline stops there and waits for you to type `approve-step <N>` (or `approve`) before moving to the next step. When **OFF**, that step auto-advances with no human input.*
>
> *Example: Step 6 (BVT Check) gate is ON by default — after canary BVTs run, the agent shows you the results and waits. You eyeball them, then type `approve-bvt` to continue to rollback. If you turned this gate OFF, the agent would auto-proceed to Step 7 the moment BVTs pass.*
>
> *The recommended defaults gate the 4 human-judgment steps (6 BVT review, 9 post-rollback sign-off, 12 post-roll-forward sign-off, 14 CRB review) and let the other 12 steps auto-flow. Step 14 is always ON and cannot be turned off — CRB approval is mandatory.*
>
> *Would you like to change any gates? You can also adjust them later any time with `gate on <N>` / `gate off <N>`."*

### Generation

By this point, all field values collected from the release owner have **already been written to disk incrementally** (see the Interactive Collection Flow). The Generation phase is therefore a **finalization pass**, not a bulk write. It exists to:
- Inject any default sub-objects (like the `routing` block below) that were not asked field-by-field.
- Run schema validation on the now-complete files.
- Print the final summary to the release owner.

If at this point a required field is still missing on disk (e.g., the release owner answered "skip" earlier), surface it during validation rather than silently writing a placeholder.

1. **Finalize `service-config.json`** — Re-read `.github/skills/zed-agent/service-config.json` from disk, ensure the per-step `notifications.routing` block is present with **all 16 steps** and **all three outcomes** (`success`, `failure`, `halt`) populated as empty `{ "emailGroups": [], "ccGroups": [], "teamsGroups": [] }` objects (so owners see the full grid in the file). Seed only these four cells with the non-default values; everything else stays empty (= current-owner-only). Do NOT overwrite if the release owner has customized any cell. Default seed values for those four cells:

   - `1-send-reminder.success`       → `{ "emailGroups": ["permanent"],          "teamsGroups": ["teams"] }`
   - `4-collect-commits.success`     → `{                                       "teamsGroups": ["teamsExtended"] }`
   - `13-create-r2d.success`         → `{ "ccGroups": ["cc"] }`
   - `15-production-rollout.success` → `{ "emailGroups": ["permanent", "cc"] }`

   The current release owner's personal email is always added to the To-line of every notification by `Resolve-NotificationRecipients.ps1`. Empty cells in the grid resolve to current-owner-only. Owners widen any cell — including `failure` and `halt` for any step — via `setup-service group 5b`. The legacy generic keys (`judgment`, `failure`, `halt`, `step-transition`) are unmapped (no associated step) and stay current-owner-only.

2. **Finalize `pipeline-catalog.json`** — Re-read the file from disk. Pipeline entries collected during Group 4 (Phase 4.10) were already persisted incrementally per pipeline. Confirm all pipeline entries the release owner provided are present and well-formed; do not overwrite existing entries.

3. **Validate** — Run `Load-ServiceConfig.ps1` to verify the generated files parse and validate correctly:
```powershell
$cfg = & .\.github\skills\zed-agent\scripts\Load-ServiceConfig.ps1
Write-Host "✅ Config loaded: $($cfg.service.displayName)"
Write-Host "   Canary pipelines: $($cfg.pipelines.canary.PSObject.Properties.Count)"
Write-Host "   Production pipelines: $($cfg.pipelines.production.PSObject.Properties.Count)"
```

4. **Remind the release owner** to commit the files:
```
✅ Service configuration generated!

Files created:
  .github/skills/zed-agent/service-config.json
  .github/skills/zed-agent/pipeline-catalog.json

Next steps:
  1. Review the generated files
  2. Force-add and commit: git add -f .github/skills/zed-agent/service-config.json .github/skills/zed-agent/pipeline-catalog.json
  3. Push to your branch
  4. Run `setup` for per-release initialization
```

### Validation — `setup-service validate`

Whether the release owner has been editing by hand, running through the wizard, or both, validation is the same routine. It is also run automatically at the end of every wizard pass, and can be invoked on its own with `setup-service validate`:

1. **Read** `.github/skills/zed-agent/service-config.json` and `pipeline-catalog.json`. If either file is missing, tell the release owner and stop.
2. **Run loader** with strict mode:
```powershell
$cfg = & .\.github\skills\zed-agent\scripts\Load-ServiceConfig.ps1 -Strict
```
3. **Schema check** — for each required key listed in `service-config.schema.json`, verify the value is present and non-empty.
4. **Sanity checks** — verify pipeline IDs are numeric, service tree IDs are GUIDs, email addresses contain `@`, GUIDs are 36-char hyphenated.
5. **Report**: list any missing fields, type errors, or unresolved `<TODO>` placeholders. If everything passes, print:
```
✅ Configuration valid: <serviceDisplayName>
   - <N> canary pipelines, <N> production pipelines
   - <N> notification routing rules
   - Step gates: <N> on, <N> off
Run `setup` to initialize for the next release.
```

If validation fails, list the missing/invalid fields and offer the release owner either to (a) fix them in their IDE and re-run `setup-service validate`, or (b) re-run `setup-service` to be prompted for just those fields, or (c) jump directly to the failing group with `setup-service group <N>` (e.g., `setup-service group 4.10` resumes at the per-pipeline parameter proposal; `setup-service group 5b` resumes at notification routing).

### Readiness persistence

**At the end of every wizard pass and every `setup-service group <N>` jump and every `setup-service validate`**, persist the outcome to `.zed-agent/readiness.json → setupService`:

```powershell
& .\.github\skills\zed-agent\scripts\Write-Readiness.ps1 -Stage 'setupService' -Data @{
    status        = '<pass|incomplete|fail>'   # pass = full validation green AND dry-run executed; incomplete = owner exited mid-wizard or some required field still empty; fail = validation hit type errors / placeholder values
    lastGroup     = '<last group identifier successfully persisted, e.g., "4.13" or "5b">'
    missingFields = @('<dotted.path>', '...')   # empty array on pass
    dryRun        = @{
        executed        = $false                # flipped to $true ONLY after Phase 4.12 step 2 returns from Invoke-PipelineDryRun.ps1 for every consented production pipeline
        pipelinesQueued = 0                     # count of pipelines that received a real queue+cancel (queue-failed counts as queued for gate purposes)
        consented       = 0                     # count of pipelines under setupService.dryRun.consent at Phase 4.11/4.12 entry
        lastRunAt       = '<UTC ISO or null>'
    }
}
```

**Hard gate — `status = 'pass'` is REFUSED unless all three of these hold:**

1. Validation block returned no missing/invalid fields.
2. `dryRun.executed == $true`.
3. `dryRun.pipelinesQueued >= dryRun.consented`.

If the gate fails, the agent persists `status = 'incomplete'` with `lastGroup = '4.12'` (or the actual blocking phase), surfaces *"Cannot mark setupService complete: dry-run was consented for N pipelines but only M were queued. Re-run `setup-service group 4.12` to finish."* and exits. The owner does NOT get a yes/no — the gate is mechanical. This closes the loop on the Phase 4.12 process bug where consent was conflated with execution.

Incremental rule: also call `Write-Readiness -Stage setupService -Data @{ status = 'incomplete'; lastGroup = '<N>' }` after each group completes, so a chat interruption mid-wizard still produces a meaningful record. The `run` command's chain check will see `status = 'incomplete'` and tell the owner exactly where to resume.
