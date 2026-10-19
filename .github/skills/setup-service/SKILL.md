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
- `ado.releaseMode` — Ask: *"Do you cut a release branch every month, or deploy the base branch (`ado.baseBranch`) itself?"* `Cut a release branch` (default → `cut-branch`) / `Deploy the base branch` (→ `deploy-base`, e.g. BCM deploys master). On `deploy-base`, explain: the deployment branch is confirmed per release at `setup` (default `ado.baseBranch`); the previous release is read from the production pipelines' run history; and every canary/production run is pinned to the exact release build — which requires Group 4's `artifactFeed` and a `buildResource` on every canary/production pipeline (propose them from each pipeline YAML's `resources.builds`: the CloudVault resource whose branch is built from `ArtifactsBranch`).
- `revertBits` — Ask: *"After the canary BVT sign-off, do you build 'revert bits' — the previous release commit plus selected settings from this release — to roll back with if a regression shows up?"* `No` (default → `{ "enabled": false }`) / `Yes`. On `Yes`, ask one at a time (show defaults): `branchTemplate` (look at existing branches like `releases/rollback*` / `releases/*revert*` and propose a matching pattern with `{{YYMM}}`; BCM: `releases/bcm{{YYMM}}revert`), `files` (propose the repo's `*ServiceDatacenterSettings*.json` / SDS settings files from `git ls-files`), `preserveAlways` (settings that must always follow the new release when they change, e.g. `BCMAppConfig->BCMTeeWorkflowVersion`), and `useForRollback` (default `true`: Step 7 rolls canary back with the revert build), and `prepareDuringCanaryBvt` (*"Prepare the revert build while the canary BVT runs, so the rollback starts right after you approve the canary BVT and its BVT is the post-rollback BVT (no separate revert BVT sign-off)?"* — default `true` when `useForRollback`). Persist `enabled: true` and the default `topicBranchTemplate` (`users/{ownerAlias}/...`). Behavior: `step-behaviors.md → Step 7 — Revert bits`.
- `ado.integration` — Ask: *"Before the branch cut, does your team merge master into develop (RI) and then develop back into master (FI) through PRs?"* Choices: `No` (default — write `{ "enabled": false }`) / `Yes`. On `Yes`, ask one at a time (show defaults; Enter accepts):
  - `developBranch` (default `develop`) and `mainBranch` (default = `ado.baseBranch`). If they differ from `ado.baseBranch`, explain that the release branch is cut from `mainBranch` after FI, and set `ado.baseBranch = mainBranch`.
  - `preservePaths` (default `[".config"]`) — *"paths where the PR target's version always wins (RI keeps develop's, FI keeps master's)"*.
  - `requireGoAheadAfterRI` (default `true`) — halt for `approve-ri` after the RI PR merges.
  - Persist `enabled: true`, `conflictStrategy: "newest-commit-per-file"`, and the default `riBranchTemplate` / `fiBranchTemplate` / `prPollIntervalSeconds` unless the owner overrides them. Behavior: `reference/step-behaviors.md → Step 2 → Integration sub-phases`.

**Group 3 — Service Tree ID**
Ask for:
- `serviceTreeIds.safefly` — Your team's Service Tree ID (36-char hyphenated GUID). The agent uses this internally wherever a Service Tree ID is required.

Tell the release owner: *"You can find your Service Tree ID at https://microsoftservicetree.com/home — search for your service name. If you don't know it now, type `skip` and you can fill it in later. If your service uses different service IDs for different environments, you can update them manually later in the file."*

> **One question, multiple fields**: Persist the answer to `serviceTreeIds.safefly`, `serviceTreeIds.ev2.Prod`, `serviceTreeIds.ev2.Fairfax`, and `serviceTreeIds.ev2.Mooncake` — all four get the same GUID. Do NOT ask the release owner separately for EV2/Fairfax/Mooncake IDs.

**Group 4 — Service Topology, Pipelines, and Kusto**

Group 4 is the **single contiguous wizard block** covering everything pipeline- and topology-related: pipeline identity, routing mode, evidence-driven parameter discovery, the cloud-agnostic SDS stamp source, canary + production stamp lists, Kusto detection queries, dry-run validation, and EV2 metadata. It collapses the previously separate Kusto/stamps and pipeline-catalog sections into one ordered flow so that:

- **SDS** (Service Datacenter Settings, the cloud-agnostic stamp source) is discovered **before** the wizard asks "how many stamps per region?" — eliminating a ordering bug that assumed one stamp per region.
- **Prior-run `sourceBranch`** is captured **before** YAML introspection, so `Get-PipelineYamlIntrospection.ps1` reads the branch the team actually develops on, not the pipeline definition's stale default.
- Owner-facing prompts use plain words — `stamp list`, `current scope`, `AzureServiceConfig`, `datacenter` — rather than the older internal jargon (`snapshot`, `ASC`, `DC`).

Stamp-universe **source-of-truth precedence** (top wins, applies wherever a stamp list is needed):

1. **Kusto live query** (Phase 4.9 cluster-type query, or any equivalent `EventLogAllClusters`-shaped query) — strongest evidence: a stamp emitting telemetry **right now** is a stamp that exists. Limited to clouds the agent's identity can reach (effectively **Public** only — sovereign clouds live in AME-tenant Kusto and are out of reach).
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

   For each canary pipeline, also ask: *"Does `<name>` also deploy on its own (a schedule or ad-hoc runs) that could overwrite the release bits during canary BVT?"* — `No` (default, persist nothing) / `Yes`. On `Yes`: GET the definition and show what it has — UI schedule triggers (`triggers[triggerType=schedule]`, e.g. *develop Sun–Thu 23:00 IST*), definition variables, and whether the YAML (`process.yamlFilename` on the scheduled branch) has a `schedules:` cron. Then ask, one at a time: (a) *"Pause its UI schedule trigger while canary BVT runs?"* (default Yes when it has one) → `pauseScheduleTriggers: true` — if the YAML also has a cron, say that deleting the UI schedule makes ADO run the YAML cron instead and recommend (c); (b) *"Is there an on/off variable that gates its deployment (e.g. `enableSchedule`)?"* — confirm it exists under Pipeline settings → Variables (not only in YAML), else persist no variable; (c) *"Cancel runs ZED did not queue (manual / scheduled) until canary BVT is signed off?"* (default Yes) → `cancelForeignRuns: true`. Persist `canary.<key>.scheduleGuard = { "pauseScheduleTriggers": <bool>, "variable": "<name>", "disabledValue": "false", "enabledValue": "true", "cancelForeignRuns": <bool> }` (omit unused fields; at least one of pauseScheduleTriggers / variable). Check the release owner's permissions on the pipeline (`_apis/permissions/33344d9c-fc72-4d6f-aba5-fa317101a7e9/2048` Edit build pipeline, `/512` Stop builds) and warn when missing. Behavior: `step-behaviors.md → Canary schedule guard`.

   For each canary pipeline that deploys through EV2 Managed SDP, also ask: *"Does its run keep going after the bits are deployed (e.g. EV2 `Canary-ManagedValidation` bake time of ~24 h)? ZED can treat the deployment as done as soon as that EV2 step starts, so the BVT window runs in parallel."* — `No` (default) / the EV2 step name. On a name: find a recent succeeded run, read the `Ev2 portal link - …` line from its `Ev2 Managed SDP Region Agnostic` task log (ask for the task name if it differs) and run `scripts/EV2/Get-Ev2DeploymentProgress.ps1 -RunId <run> -StepName <name> -PortalLinkTask <task>` — it must return `Phase: deployed` with a `ValidationStartedAt`. Persist `canary.<key>.deploymentDoneWhen = { "ev2StepStarted": "<name>", "portalLinkTask": "<task>" }`. Behavior: `step-behaviors.md → EV2 deployment done`.

   Then ask once: *"Do you run BVT/E2E **release pipelines** against canary after a deployment (instead of waiting a fixed 24 h)? Paste their release definition links."* — `No` (default — Steps 6/8/11 keep the 24 h wait) / one or more `…/_release?definitionId=<id>` links. For each: GET `vsrm …/_apis/release/definitions/<id>`, show its stages and the variables marked settable at release time, and ask which to override (e.g. `MABIsOfficial=true`); confirm `…/_apis/release/artifacts/versions?releaseDefinitionId=<id>` resolves a default version for every artifact. Ask which BVT steps use them (default all: 6 after canary, 8 after rollback, 11 after roll-forward). Persist `bvtReleases = { "steps": [...], "timeoutHours": 12, "releases": { "<key>": { "definitionId": <id>, "variables": { ... } } } }` at the catalog top level. Behavior: `step-behaviors.md → BVT releases`.

3. **Production pipeline count** — same pattern. Persist to `production.<key>.{name,id}`.

4. **Private stamp upgrade test** (optional side track — `step-behaviors.md → Private stamp upgrade test`):
   > *"Do you run an upgrade test on a private stamp during canary (deploy the last build and this release's build side by side, then BVT)?"* — `No` (default → persist `privateStampUpgrade: { "enabled": false }`) / `Yes`.

   On `Yes`, ask one at a time and persist to `privateStampUpgrade`:
   - pipeline `name` and `id` (e.g. BCM: `Mgmt-RecoverySvcs-IaaSCoord-BCM-SF-EaCan-PrivateStamp-BCM-Svc-Deployment`, `396863`).
   - Read the pipeline YAML parameters (`Read-PipelineYaml.ps1`) and the last 20 runs, then **propose** — owner confirms or edits: `parameterNames` (instance / port / artifactBranch / serviceOverrides), fixed `templateParameters` (every other parameter, using the value most prior runs used), `portSpan` (2 if the port parameter says HTTP = port + 1), and `serviceOverrideSettingsTemplate` with the `{queueName}` token (BCM: `@{"BCMAppConfig->WorkflowQueueName"="{queueName}";}`).
   - Persist `enabled: true`, `sourceBranch: "{currentBranch}"`.
   - **Build pinning** (`privateStampUpgrade.artifact`, recommended): read the YAML `resources.builds` and pick the build resource that carries the service bits (BCM: `svc_build`, `type: CloudVaultArtifacts-v3`, `branch: Mgmt_RecoverySvcs_IaaSCoord_${{ replace(...ArtifactBranch...) }}`). Persist `resourceAlias`, `type`, `sourceId` (its `source`), `connectionName` + `connectionId` (resolve the name via `GET …/_apis/serviceendpoint/endpoints?endpointNames=<name>`), `feedBranchPrefix` (the literal part of its `branch` expression; the YAML must replace `/ - .` with `_`), and `buildDefinitionId` = `officialBuild.id`. Check it: look up the newest build of `officialBuild` on the base branch and confirm `POST vsrm …/_apis/Release/artifacts/versions` for that feed lists a version ending in `_<buildId>`. With this set, the owner gives the last build as a **build link** and both deployments are pinned to exact builds.
   - **BVT release** (`privateStampUpgrade.bvtRelease`, optional): *"After both deployments succeed, should ZED run a BVT release pipeline against a vault redirected to the private stamp? Paste the release definition URL or id, or 'no'."* On an id: GET `https://vsrm.dev.azure.com/<org>/<project>/_apis/release/definitions/<id>` and show its stages and release-time-settable variables (`allowOverride: true`); propose `environmentName` = the last stage by rank and `vaultIdVariable` = the settable variable whose name contains `VaultId` (BCM: 64863 `IaaSVM-BVT-Private-Stamp`, stage `IaaSVM BVT Private Stamp`, variable `PrivateStampVaultId`). Owner confirms. Persist `{ definitionId, name, environmentName, vaultIdVariable }`. The vault id itself is asked every release.
   - **Never** persist an instance, port, last-build branch, queue name or vault id — those are asked from the owner every release by the `private-stamp` command.

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

#### Phase 4.3 — Prior-run analysis (owner supplies ONE release, ZED does the rest)

The agent learns the real-world parameter surface from runs a **human** actually authored for a real release. That evidence feeds (a) Phase 4.4's YAML branch resolution and (b) Phase 4.10's `templateParameters` merge.

Do **not** walk the pipelines one at a time asking "which run belongs to this pipeline". The owner does not think in pipeline ids — they think in releases. Ask once, for a release, and let ZED map runs to pipelines itself.

**Step A — ask for one real release, as URLs.**

> *"Paste the ADO run URLs from your last real production release — all of them, in any order, one per line or comma-separated. I'll work out which pipeline each one belongs to. (Cancelled runs are fine; releases are often cancelled once the rollout is verified.)"*

**Step B — self-map and learn.** One call handles resolution, mapping, model-building, and persistence:

```powershell
$learned = & .github/skills/zed-agent/scripts/New-ParameterModel.ps1 `
    -Organization $cfg.ado.organization `
    -Project $cfg.ado.project `
    -CatalogPath  $catalogPath `
    -RunUrls      @(<URLs the owner pasted>) `
    -ReleaseGroup "<owner's name for this release>" `
    -RepoRoot     $repoRoot
```

The script resolves each run's owning pipeline through the Build API (`definition.id`), matches it against the catalog, and persists the result under `<scope>.<key>._learnedFrom`. It never asks the owner to do that mapping.

Report back exactly what it returns:

- `mapped[]` — *"Mapped run `{runId}` → `{scope}.{key}`."*
- `unmapped[]` — a run whose pipeline is **not in the catalog**. Surface it; it usually means Phase 4.1 missed a pipeline: *"Run `{runId}` belongs to pipeline definition `{definitionId}`, which isn't in the catalog. Should I add it?"* Never silently drop it.
- `uncovered[]` — catalog pipelines with no run yet. Carry these into Step D.

**Step C — ask for a second, older release (this is the confidence bar).**

A single release cannot distinguish "this value is always X" from "this value happened to be X that week". Every parameter learned from one release is marked `lowConfidence = true` and stays that way until a second **independent** release agrees.

> *"To tell constants apart from per-release values, I need a second, older release. Paste those run URLs too — or say `skip` and I'll mark everything I learned as low-confidence and ask you to confirm each value in Phase 4.10."*

On answer, re-run the same script with `-Merge` and a different `-ReleaseGroup`:

```powershell
$learned2 = & .github/skills/zed-agent/scripts/New-ParameterModel.ps1 `
    -Organization $cfg.ado.organization -Project $cfg.ado.project `
    -CatalogPath  $catalogPath -RepoRoot $repoRoot `
    -RunUrls @(<second release's URLs>) -ReleaseGroup "<older release name>" -Merge
```

Two runs of the *same* release count as **one** observation — independence is counted per `releaseGroup`, not per run. `-Merge` is what raises `independentReleaseCount` to 2 and clears `lowConfidence` on values that agree.

**Step D — coverage check, then a proposal list for what's left.**

Only for pipelines still in `uncovered[]`, offer candidates. Never auto-pick one:

```powershell
$candidates = & .github/skills/zed-agent/scripts/Read-PriorRun.ps1 `
    -Organization $cfg.ado.organization -Project $cfg.ado.project `
    -PipelineId $entry.id -Top 10 -ResultFilter 'any' -RepoRoot $repoRoot
```

`-ResultFilter 'any'` is deliberate: filtering to `succeeded` hides exactly the runs worth learning from, because release runs are routinely cancelled once the rollout is verified. Present them as a table — run id, finished date, source branch, result — ranked most-recent-first, and ask:

> *"I have no release run for `{key}` yet. Here are its last 10 runs. Which one (if any) came from a real release?"*

If the owner recognises none, leave the pipeline uncovered and say so plainly: *"`{key}` has no learned parameter model — Phase 4.10 will fall back to YAML-declared defaults and I'll ask you to confirm every value."*

**Runs ZED authored itself are never offered and never learned from.** `Read-PriorRun.ps1` excludes them using the ledger from `Get-SelfAuthoredRuns.ps1`. This cannot be done by identity: ZED queues runs with the release owner's delegated token, so `requestedFor` and `reason` are identical for a human-queued run and a ZED-queued run. Only the run ids ZED recorded at trigger time can tell them apart. Learning from ZED's own trigger-and-cancel runs would make ZED's mistakes permanent.

**Branch capture.** After Step B, inspect `sourceBranch` across the mapped runs:

- **All agree** and the runs target the wizard's `selfRepo` → persist as `yamlRepos.<selfRepo>.baseBranch`. Recap: *"Captured `sourceBranch = <branch>` from `<N>` release runs — Phase 4.4 will read YAML from this branch."*
- **They disagree** → surface the split and ask the owner to pick one; persist the choice.
  > *"Your release runs queued from different source branches: `{branch_a}` (×2), `{branch_b}` (×1). Which branch should I introspect the YAML from?"*
- **Cross-repo** → record `_learnedFrom.crossRepo = true` and leave `yamlRepos` alone; Phase 4.4 confirms per-repo.

A release branch is often a short-lived feature/release branch. If the captured branch differs from `cfg.ado.baseBranch`, say so — a parameter that exists only on that branch will not be declared on the base branch, and posting it would be rejected by ADO.

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
- **`sdsHint.{fileName, repoPath}`** — extracted from inline PowerShell `-SdsFiles <name>` plus the nearest quoted literal containing a `dep_specs/<path>` subtree (any variable name, `/` or `\` separators — not just `$hsp_source`). `repoPath` is the directory only. Consumed by Phase 4.5.
- **`selfRepo.{name, baseBranch, alias}`** — the source-tree repo declared under `resources.repositories[]` (type git, not under `OneBranch.Pipelines/`). Consumed by Phase 4.5 for the SDS path.

Persist verbatim to `pipeline-catalog.json → pipelines.<key>.yamlIntrospection`. The merged `parameters:` block (per-parameter `name`, `type`, `default`, `values`, plus `_resolvedFrom` provenance) is persisted under `pipelines.<key>.yamlIntrospection.parameters` and consumed by Phase 4.10's merge.

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

   For each sample whose value is null or `<unresolved>`, ask the owner to dictate the correct dotted path. Persist non-default overrides to `service-config.json → sdsFieldMapping.<key>` (keys: `cloudArrayPath`, `cloudNameField`, `stampsArrayField`, `stampIdField`, `stampNamePath`, `clusterNamePath`, `dcShortNamePath`, `regionPath`, `deploymentNamePath`, `dsmsRegionPath`). When all sample values look right, skip the block entirely — missing keys fall back to Phobos 2022 defaults at runtime.

4. **Smoke-test once.** After persisting, run the full inventory against every cloud the SDS exposes:

   ```powershell
   & .\.github\skills\zed-agent\scripts\Get-StampInventoryFromSds.ps1 -SdsPath <path>
   ```

   Recap: *"SDS pinned at `<path>`. Found `<N>` stamps across `<clouds>`. Hash: `<sha256[:12]>`. From this point on, `Get-StampInventory.ps1 -Scope production` will read this SDS — sovereign clouds source from it directly, Public cloud cross-checks against it."*

5. **Set drift tolerance once.** Ask: *"How many unmatched stamps between Kusto and SDS should the inventory gate tolerate before halting Step 10 / Step 15? `0` means any drift requires re-approval. Recommended: `0`."* Persist to `inventory.driftToleranceCount`. Default to `0` if the owner hits enter.

6. **Decide whether the production gate is mandatory.** Ask: *"Should Step 10 (Roll-Forward) and Step 15 (Production Rollout) refuse to fire until the owner explicitly approves each inventory snapshot? Recommended: `yes`."* Persist `true`/`false` to `inventory.production.approvalRequired`. When `false`, the gate auto-passes — use only for test services.

---

#### Phase 4.6 — Canary stamp set

The canary fleet is small, stable, and **owner-declared**. Some services have all canary stamps in one purpose-built cloud (e.g. the `Canary` cloud); others have canary stamps inside the **Public** cloud (e.g. `ecy`, `ccy` regions). Each stamp carries its own `{ cloud, region, layout }` so multi-cloud setups are represented natively.

**The owner is the only source of truth for which regions are canary.** The agent does **not** scan AzureServiceConfig looking for "canary datacenters" — AzureServiceConfig has no reliable, service-agnostic tag for that. AzureServiceConfig is used only as a **lookup table** to (a) map each owner-provided region short name to its `{ cloud, layout }`, (b) catch typos before they reach a release, and (c) surface whether a region has a passive recovery stamp.

`clusterType` is never prompted in Phase 4.6 — it is filled lazily by `Get-StampInventory.ps1` running the Phase 4.9 canary-half Kusto query when `canaryRouting.mode == "cluster-type"`.

> **AzureServiceConfig vocabulary — for the recap only**
>
> Each `Clouds[].DataCenters[]` entry carries a `DatacenterType` comma-list. Two values matter for the recap:
> - **`PASSIVE`** — this datacenter IS a recovery-only copy. Never targeted as a canary stamp.
> - **`HAS_PASSIVE`** — this datacenter has an additional passive (recovery) copy behind the primary. Purely informational; surface it so the owner knows which regions have a recovery copy.
>
> Many services only use `ACTIVE` / `PASSIVE` / `HAS_PASSIVE` and never tag canary datacenters at all. That is fine — the agent does not need that tag because the owner already told us which regions are canary.

Prerequisite: `service.stampTag` must already be set (Group 1). If it is empty, jump back to Group 1.

1. **Fetch AzureServiceConfig** by calling:

   ```powershell
   $asc = & .\.github\skills\zed-agent\scripts\Get-AzureServiceConfig.ps1
   ```

   Live-first; cache and committed snapshot are fallbacks. If the call falls back, tell the release owner — they may want to fix `az login` before continuing so validation is grounded in truth. If the call throws or `$asc.data.Clouds.Count -eq 0`, halt and surface the error.

2. **Ask the owner for the canary region short names.** Read any existing `inventory.canary.regionPrefixHints` from disk first; if non-empty, offer the saved list as a one-tap default. Otherwise (and on re-runs where the owner says "change"), ask:

   > *"Which regions are canary regions for your service? List the region short names exactly as they appear in your stamp names. Comma-separated, lowercase. The agent will look each one up in AzureServiceConfig to confirm it exists and find its cloud + layout. Example: `ea-can, ecy, ccy`."*

   If Phase 4.9 has already been completed and `kusto.canary.stampPrefixFilter` is set, derive a suggested default from it (e.g. the `startswith '<token>'` tokens) and offer:
   `1. Use <suggested list>   2. Provide my own   3. None of my regions are canary (skip Phase 4.6)`.

   Persist the trimmed lowercase list to `inventory.canary.regionPrefixHints`.

3. **Resolve each owner-provided short name against AzureServiceConfig.** For every short name `p` in the list, scan `$asc.data.Clouds[*].DataCenters[*]` and find every datacenter where `"$($dc.ShortName)-$($cloud.Layout)" -like "$p*"` (case-insensitive). This matches both exact short names (`ecy`) and shape-anchored prefixes (`ea-can` resolves to `(Canary, ea, can02)` because the full token `ea-can02` starts with `ea-can`).

   - **Zero matches** for a token → halt and re-prompt step 2 with: *"`<p>` doesn't match any datacenter in AzureServiceConfig. Check spelling, or remove it from the list."*
   - **Multiple matches across clouds** for a token → render the choices and ask the owner to pick which one is canary.
   - **One match per cloud** → record the `{ cloud, region: shortName, layout }` triple for that token. Multiple tokens may legitimately resolve to different `(cloud, layout)` triples — that's the multi-cloud case.

4. **For each resolved `(cloud, region, layout)` triple, determine the stamp list.** **Do not** ask the owner for an index list up front. Instead, walk the source-of-truth precedence chain:

   1. **SDS first (Phase 4.5):** Run `Get-StampInventoryFromSds.ps1 -SdsPath <pinned path> -Cloud <cloud> -Region <region>`. If the result is non-empty, use the returned stamp names verbatim and recap the count to the owner.
   2. **YAML defaults second (Phase 4.4):** If SDS returned nothing for this `(cloud, region)`, look in `pipelines.<canaryKey>.yamlIntrospection.flatDefaults.stamps` (or `perCloudDefaults.<cloud>.stamps`) for entries matching this region. If found, use them and recap.
   3. **AzureServiceConfig grammar fallback (last resort):** If neither (1) nor (2) has stamp names for this region, prompt the owner explicitly:
      > ⚠️ *"SDS and YAML defaults are both unavailable for `<cloud> / <region>` — using grammar approximation `<region>-<layout>-<stampTag><index>`. How many `{region}-{layout}-{stampTag}{index}` stamps does your service run here? (Comma-separated indexes — e.g. `1, 1d, 2`. Please correct if the grammar approximation is wrong.)"*

      For each index, build `stampName = "<region>-<layout>-<stampTag><index>"`. **Always** log a fallback via `Add-Learning.ps1 -Source agent-discovery -Category infrastructure` describing the missing SDS / YAML source.

   For every stamp, push `{ stampName, cloud, region, layout, clusterType: null }` to `inventory.canary.stamps`. **Never prompt for `clusterType`.**

5. **Validate immediately** by calling:

   ```powershell
   $inv = & .\.github\skills\zed-agent\scripts\Get-StampInventory.ps1 -Scope canary
   ```

   - If `$inv.drift` is non-empty, render the drift table (`stampName`, `reason`) and re-prompt for each drifted stamp. Common reasons: region not in the named cloud, stampTag mismatch, grammar mismatch.
   - If `$inv.stamps.Count -eq 0`, halt and re-run Phase 4.6 from step 2.

6. **Recap + confirm.** Render the full stamp list as a table. The `clusterType` column **must not** assert that `canaryRouting.mode` is anything — that decision lives in Phase 4.2. If Phase 4.2 set the mode to `cluster-type` and Phase 4.9 canary half is configured, the lazy resolver fills the column at validation time; otherwise it reads `(unresolved — set by Phase 4.2)`. Never infer `static` from a null `clusterType`.

   | Cloud | Region | Layout | HAS_PASSIVE | Stamps | clusterType | source |
   |-------|--------|--------|-------------|--------|-------------|--------|
   | Public | ecy | pod01 | yes | ecy-pod01-prot1 | (unresolved — set by Phase 4.2) | SDS |
   | Public | ccy | pod01 | yes | ccy-pod01-prot1 | (unresolved — set by Phase 4.2) | YAML defaults |
   | Canary | ea | can02 | no | ea-can02-prot1 | (unresolved — set by Phase 4.2) | AzureServiceConfig grammar (fallback ⚠) |

   Then `ask_user`:
   > *"Does this canary stamp list look right? Picking `Edit` lets you redo the region list from step 2. Picking `Yes — looks good` finalizes the list and continues to Phase 4.7."*
   > Choices: `Yes — looks good`, `Edit`

   On `Edit`, jump back to step 2. On `Yes — looks good`, persist and remind the owner that any stamp added or decommissioned needs a re-run of `setup-service group 4.6`.

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

   1. **SDS (Phase 4.5):** Run `Get-StampInventoryFromSds.ps1 -SdsPath <pinned path> -Cloud <cloud>`. Capture `regions` and `stamps[]` verbatim from SDS. Source label: `SDS`.
   2. **YAML defaults (Phase 4.4):** If SDS returned nothing for this cloud (rare for production), fall back to `pipelines.<prodKey>.yamlIntrospection.perCloudDefaults.<cloud>.{Regions,stamps}` (or `flatDefaults` for single-cloud pipelines). Source label: `YAML defaults`.
   3. **AzureServiceConfig + grammar (last resort, with explicit warning):** If both SDS and YAML defaults are unavailable, fall back to the AzureServiceConfig + grammar expansion (`<region>-<layout>-<stampTag><index>`) and surface a warning to the owner. Source label: `AzureServiceConfig grammar (fallback ⚠)`. Always log a fallback learning.

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
         "_scopeFrom": { "source": "SDS", "sdsHash": "<sha256[:12]>", "at": "<UTC ISO>" }
       },
       "Fairfax":  { … same shape … }
     }
   }
   ```

   When `_scopeFrom.source` is `AzureServiceConfig grammar (fallback)`, the gate at Step 15 surfaces this fact in the drift recap.

6. **Recap** to the release owner:
   - *"Current scope saved for {N} clouds, {total regions}, {total stamps}."*
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

> **Hard rule — always show the query**: Whenever the agent references, discusses, validates, or dry-runs a Kusto query in this phase, it MUST display the full query text in a fenced `kql` code block. Never summarize, paraphrase, or refer to a query without printing it verbatim first. This applies to: the default query (step 1), any pasted custom query (step B.4), any file-based query (step B.5), and the dry-run execution (step B.7).

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

5. **Dry-run check (recommended)** — before finishing the canary half, offer to execute the finalized query once via the Kusto MCP against `kusto.canary.cluster` / `kusto.canary.database`, substituting `{{SERVICE_FILTER}}` and `{{STAMP_PREFIX_FILTER}}` with the collected values and using `ago(7d)` for any time window. **Always print the substituted query verbatim in a fenced `kql` code block before executing** (per the Phase 4.8 hard rule — same applies here). On success, recap row count and the distinct `StampName` / `DeploymentUnit` sample (top 5) so the owner can sanity-check shape. On error, surface the Kusto error verbatim and let the owner edit `kusto.canary.queryFile` / `serviceFilter` / `stampPrefixFilter` and re-run the dry-run. Ask via `ask_user` whether to run it: `Yes — dry-run now`, `Skip — I'll trust the values`.

6. **Hard reminder** before finishing the canary half:
   > ⚠️ **Contract**: Steps 5/7/10 will run this query verbatim, substituting `{{SERVICE_FILTER}}` / `{{STAMP_PREFIX_FILTER}}` / any custom placeholders. The agent then (a) extracts the SET of cluster types via `kusto.canary.clusterTypeExtraction` and intersects with `canaryRouting.clusterTypeMap` (Phase 4.2) to pick canary pipelines, and (b) joins rows back by `StampName` to fill `inventory.canary.stamps[*].clusterType`. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run.

**Production half** (only when `productionRouting.mode == "cluster-type"`):

Mirrors the canary half but persists under `kusto.production.*`. Defaults differ:

- `kusto.production.queryFile` → `Production-DeploymentUnits.kql` (canonical, shape-identical to canary; copy into queries/ if absent).
- `kusto.production.cluster` → `https://mabprod1.kusto.windows.net/` (Azure Backup default).
- `kusto.production.database` → `MABKustoProd1` (Azure Backup default).
- `kusto.production.clusterTypeExtraction` → `{ mode: "deployment-unit-substring" }`.
- **Auto-derive `kusto.production.stampPrefixFilter` from AzureServiceConfig — do NOT prompt**:
  1. Run `Get-AzureServiceConfig.ps1` to load the snapshot.
  2. Select the `Public` cloud entry and collect the distinct lower-cased `ShortName` values from `DataCenters[]`.
  3. Persist the sorted distinct list to `kusto.production.stampPrefixFilter`. At runtime `Get-StampInventory.ps1` joins them into `StampName startswith 'eus' or StampName startswith 'wus' or …` and substitutes into `{{STAMP_PREFIX_FILTER}}`.
  4. Recap: *"Auto-filled `kusto.production.stampPrefixFilter` from AzureServiceConfig Public cloud (N short names). Edit `service-config.json` directly any time to add/remove entries — the wizard will not overwrite a non-empty value on re-run."*
  5. **Sovereign clouds note**: this query covers Public only — Fairfax / Mooncake / USNat / USSec stamps live in AME-tenant Kusto this agent cannot reach. SDS (Phase 4.5) is the stamp source for them; cluster-type for sovereign-cloud stamps remains out-of-band (mechanism TBD).
- Ask only `kusto.production.serviceFilter`.
- **Dry-run check (recommended)** — same shape as the canary half: offer to execute the finalized production query once via the Kusto MCP against `kusto.production.cluster` / `kusto.production.database`, substituting `{{SERVICE_FILTER}}` / `{{STAMP_PREFIX_FILTER}}` and using `ago(7d)`. **Always print the substituted query verbatim in a fenced `kql` code block before executing.** Recap row count + sample `StampName` / `DeploymentUnit` on success; surface the Kusto error verbatim on failure and let the owner edit the file / filters and re-run. Ask via `ask_user`: `Yes — dry-run now`, `Skip — I'll trust the values`.

> ⚠️ **Contract**: Step 10 (Roll-Forward) and Step 15 (Production Rollout) will invoke `Resolve-PipelinesByClusterType.ps1 -Scope production` **once per release** — not per cloud. The resolver runs this query verbatim, extracts cluster types, and intersects with `productionRouting.clusterTypeMap` to decide which production pipeline(s) to trigger. Each resolved pipeline then pushes to whichever clouds are listed under `ev2CloudCoverage.<key>` (Phase 4.13).

Recap to the release owner what was saved for each half (cluster, database, query file path, filters). If the release owner uses the **same** Kusto cluster/database for canary and production, keep them as separate config keys — that's fine, just enter the same values.

---

#### Phase 4.10 — Per-pipeline parameter proposal

For each pipeline (official build + canary + production), synthesize a single proposed `templateParameters` map from (a) prior-run values captured in Phase 4.3 and (b) YAML parameter declarations captured in Phase 4.4. The owner reviews and accepts per pipeline — this is the **single point of human approval** between discovery and the dry-runs in Phase 4.11 / 4.12.

#### Reserved placeholders

The agent reserves these `{{...}}` tokens and substitutes them at runtime — **never** ask the owner to provide a value for them, and **never** drop them when they appear inside `templateParameters` discovered from prior runs or YAML:

- `{{currentBranch}}` — replaced with the active release branch (e.g., `releases/svc2604`).
- `{{canaryStamps}}`, `{{canaryRegions}}` — replaced with the live `inventory.canary.stamps[].stampName` / distinct `inventory.canary.stamps[].region` from `service-config.json` (Phase 4.6). For `cluster-type` routing, the agent further filters by the pipeline's declared `clusterType` (Phase 4.2) before joining into the parameter format the pipeline expects (CSV, JSON array, etc. — auto-detected from prior-run shape in `canary.<key>.discoveryNotes.stampNameStyle`).
- `{{excludeStamps}}`, `{{pubRegions}}`, `{{ffStamps}}`, `{{ffRegions}}` (and any cloud-prefixed analogues like `{{mcRegions}}`, `{{mcStamps}}`) — at **real release time** (Step 15), replaced with CCOA / SafeFly-narrowed region scope minus the live exclusion list. Source universe is `inventory.production.<cloud>` (Phase 4.7); CCOA filter and exclusion list narrow it. At **dry-run time** (Phase 4.12), only the universe applies.
- `{{sdpType}}`, `{{validateOnly}}` — replaced based on rollout mode.

> **Why canary stamps are tokenized, not literal**: prior runs are stale by definition — a stamp added or decommissioned since the last successful run would silently rot into `templateParameters` and only surface at real-release time. Phase 4.6 is the owner-curated source of truth, validated against AzureServiceConfig. Treating canary stamp/region values as reserved tokens makes the dry-run an honest preview of what the next real run will send: shape learned from prior runs, values pulled live from Phase 4.6.

When the agent shows owner-facing diffs, render these as **highlighted tokens with a one-line tooltip** explaining the runtime substitution.

#### Auth & cost

Every ADO REST call in Phase 4.10 / 4.11 / 4.12 uses the same `az login` identity that runs `setup` / `setup-service`. The token is acquired on the fly with `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798` (the fixed Azure DevOps resource GUID). No PAT, no separate sign-in. If a call returns 401, run `Repair-AzAuth.ps1 -Tenant 'microsoft.com'` and retry once; on 403, halt with the explicit message *"Your account lacks Pipelines (write) on `{org}/{project}`. Ask your project admin to grant `Build Service (queue/cancel)` permission, then re-run `setup-service group 4.10`."*

#### Merge logic

For each pipeline key, fan out in parallel using `ForEach-Object -Parallel` and:

1. **Baseline**: union of all parameters declared in `pipelines.<key>.yamlIntrospection.parameters` (Phase 4.4).
2. **Concrete values**: the learned parameter model at `<scope>.<key>._learnedFrom.model` (Phase 4.3). For each parameter use `model.<param>.lastValue`, and treat the entry's confidence as the gate:
   - `stability = "constant"` and `lowConfidence = false` → propose the value silently.
   - `lowConfidence = true` (fewer than two independent releases observed, or `observedIn` < `independentReleaseCount`) → propose the value but mark it `needs-confirmation` in the proposal so the owner must look at it. Never treat a one-release observation as settled.
   - `stability = "volatile"` → the value changes per release. Do **not** propose a literal; flag the parameter as `mode-disagreement` in `agentGaps` and list the `observedValues` so the owner can pick or supply a token.
   - `stability = "unobserved"` → fall through to the YAML `default`.
   Use `model.<param>.shape` / `.container` (e.g. `wildcard`, `regionsList`, `empty`) to check that any owner-supplied or token-substituted value keeps the same **form** the pipeline has historically accepted.
3. **Reserved-token preservation**: if a prior-run value matches one of the reserved `{{...}}` tokens **or** the YAML's `default` is a reserved token, keep it as the token (do not substitute the literal from history).
4. **Canary stamp / region detection (token replaces literal)**: prior-run values are excellent for *teaching the agent the parameter shape* (CSV vs JSON array, naming style, count) but they are **not** trusted as the actual values to send — Phase 4.6's `inventory.canary.stamps` is the truth. For each parameter whose prior-run value looks like a canary stamp list or canary region list (values are a subset of `inventory.canary.stamps[].stampName` / distinct `inventory.canary.stamps[].region`, or look like `<region>-<layout>-<stampTag><index>` triples), **replace the literal with the matching reserved token** (`{{canaryStamps}}` or `{{canaryRegions}}`) in the proposal. Record the detected delivery shape (CSV / semicolon-list / JSON array) under `canary.<key>.discoveryNotes.stampNameStyle` so the runtime substitution knows how to join the inventory values. If detection is ambiguous (prior-run value contains stamps NOT in `inventory.canary.stamps`), flag `agentGaps: stamp-list-drift: [<stamps not in inventory>]` and surface in the proposal review.
   - **Wildcard sentinel rule**: if the parameter name contains `Stamps` or `Regions` (case-insensitive) AND the prior-run value is `*`, `all`, `ALL`, empty string, or null, treat it as a token candidate even when no stamp-list match is possible. Use the parameter name's cloud prefix to pick the token: a name containing `canary` (case-insensitive) → `{{canaryStamps}}` / `{{canaryRegions}}`; names containing `pub`/`public`/`prod` (and no sovereign prefix) → `{{pubStamps}}` / `{{pubRegions}}`; `ff`/`fairfax` → `{{ffStamps}}` / `{{ffRegions}}`; `mc`/`mooncake` → `{{mcStamps}}` / `{{mcRegions}}`; `usnat` → `{{usnatStamps}}` / `{{usnatRegions}}`; `ussec` → `{{ussecStamps}}` / `{{ussecRegions}}`. Flag `agentGaps: wildcard-collapsed-to-token: <param>=<original>` so the owner sees the collapse during proposal review and can override.
5. **Production stamp / region detection** — same shape (including the wildcard sentinel rule from step 4), against `inventory.production.<cloud>` (Phase 4.7); tokens become `{{pubRegions}}` / `{{ffStamps}}` / etc. depending on the matching cloud.
6. **Cluster-type cross-check**: if `canaryRouting.mode == "cluster-type"` (or production equivalent) and the owner declared `entry.clusterType` in Phase 4.2, scan the YAML and prior runs for stamp-list / region-list parameters whose values cluster around a single suffix (e.g., all entries end in `-sfmc`). If the inferred suffix **disagrees** with the owner-declared cluster type, flag `agentGaps: clusterType-mismatch: declared <X>, evidence suggests <Y>`. If `clusterType` was NOT declared, fall back to the inferred value as the proposal.
7. **Unknown / new params**: parameters in YAML that have no prior-run value and no `default` → mark `requiresOwnerInput: true` in the proposal.

#### Render the proposal

Show the owner a single review block per pipeline:

```
┌─ Pipeline: SVC-SFMC (3527) ──────────────────────────────────────┐
│ YAML:  Mgmt-RecoverySvcs-BackupDataPlane/pipelines/canary.yml    │
│        @ develop · sha 7a3f4b1                                   │
│ Prior: run 28471 (2026-05-19), 28392 (2026-04-22), 28203 (2026-03-24) │
│                                                                  │
│ Proposed templateParameters:                                     │
│   ServiceTreeId      = "<guid>"            ← prior runs (all 3)  │
│   SourceBranch       = "{{currentBranch}}" ← YAML default token  │
│   PubCanaryStamps    = "{{canaryStamps}}"  ← detected (canary)   │
│   SdpType            = "{{sdpType}}"       ← reserved token      │
│   ValidateOnlyRollOut= "{{validateOnly}}"  ← reserved token      │
│   ExcludeStamps      = "{{excludeStamps}}" ← reserved token      │
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

Loop on the choice until owner picks `Accept` or `Reject`. On `Edit a value` ask which key, collect new value via `ask_user`, re-render. On `Reject`, drop to the legacy paste-YAML / paste-JSON / manual flow as a fallback.

#### Persist

- `<scope>.<key>.templateParameters` = accepted map (with reserved tokens preserved as strings).
- `<scope>.<key>._learnedFrom` = `{ updatedAt, organization, project, independentReleaseCount, runs: [ { runId, runUrl, definitionId, finishedAt, sourceBranch, result, releaseGroup, templateParameters } ], model: { <param>: { declaredDefault, shape, container, stability, lastValue, observedIn, lowConfidence, observedValues } } }`, plus `yamlPath, yamlRepo, yamlBranch, yamlSha` from Phase 4.4. Written by `New-ParameterModel.ps1`; merge additional releases with `-Merge` rather than overwriting.
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
   - `{{currentBranch}}` → `refs/heads/setup-service-dry-run`
   - `{{canaryStamps}}` → joined `inventory.canary.stamps[].stampName` (Phase 4.6), filtered by `entry.clusterType` when `canaryRouting.mode == "cluster-type"`, joined using `canary.<key>.discoveryNotes.stampNameStyle`.
   - `{{canaryRegions}}` → joined `inventory.canary.regions` using the same style.
   - `{{excludeStamps}}` → `""` *(dry-run never excludes anything)*.
   - `{{pubRegions}}`, `{{ffRegions}}`, `{{ffStamps}}`, `{{mcRegions}}`, `{{mcStamps}}`, … — for **canary** dry-run, `""`; for **production** dry-run (Phase 4.12), joined from `inventory.production.<cloud>`. Cloud inferred from token prefix; unmapped tokens flag `agentGaps: token-cloud-unmapped: <token>`.
   - `{{sdpType}}` → `"Express"`
   - `{{validateOnly}}` → `"true"`
2. `POST https://dev.azure.com/{org}/{project}/_apis/pipelines/{id}/runs?api-version=7.1-preview.1` with body `{ "resources": { "repositories": { "self": { "refName": "refs/heads/setup-service-dry-run" } } }, "templateParameters": <substituted map> }`. Capture `runId` and `runUrl`.
3. Sleep 5 seconds.
4. `PATCH https://dev.azure.com/{org}/{project}/_apis/build/builds/{runId}?api-version=7.0` with body `{ "status": "cancelling" }` (retry up to 3 times).
5. Return `{ pipelineKey, runId, runUrl, queuedAt, cancelledAt, finalState, queuedParameters }`.

Aggregate `$results` and hand them to `Confirm-DryRunResults.ps1` — it owns the review block, the verdict prompt, the audit row, and the `readiness.json → dryRun.reviewed` flip. The phase cannot advance until the script returns `verdict='ok'`.

```powershell
$render = & .\.github\skills\zed-agent\scripts\Confirm-DryRunResults.ps1 -Mode render -Results $results -Scope canary
# Agent echoes $render.table verbatim, then asks $render.prompt with $render.choices via ask_user.
$answer = <user choice>
$verdict = switch ($answer) { 'All good — proceed' {'ok'} 'Report a discrepancy' {'discrepancy'} 'Re-run dry-runs' {'rerun'} }
$record = & .\.github\skills\zed-agent\scripts\Confirm-DryRunResults.ps1 -Mode record -Results $results -Scope canary -Verdict $verdict -Discrepancy $discrepancyText
```

Loop semantics:

- **`verdict='ok'`** — persist `canary.<key>._validated = { at: <UTC ISO>, lastDryRunId: <id>, by: <owner email or 'wizard'> }` for every key in `$record.validatedKeys`. Advance to Phase 4.12.
- **`verdict='discrepancy'`** — enter the discrepancy loop:
  1. Ask which pipeline.
  2. Ask what's wrong (free-text via `ask_user`).
  3. Classify the fix:
     - **(a) Catalog-only fix** — owner gives a corrected value; agent updates `canary.<key>.templateParameters` and re-runs the dry-run for that one pipeline.
     - **(b) Reserved-token semantics drift** — same as (a) but record the discrepancy in `canary.<key>.discoveryNotes.freeText`.
     - **(c) Skill / agent.md edit required** — trigger the MD edit proposal flow (show current text + proposed text, persist as `md-edit-proposal` in `audit.jsonl`, apply on owner confirmation).
  4. Re-run `Invoke-PipelineDryRun.ps1` for the affected pipeline(s), then call `Confirm-DryRunResults.ps1 -Mode render` again. Loop until owner picks `All good`.
- **`verdict='rerun'`** — re-fan-out the full set with `Invoke-PipelineDryRun.ps1` and call `Confirm-DryRunResults.ps1 -Mode render` again.

`readiness.json → dryRun.reviewed` only flips to `true` on `verdict='ok'`, and `Write-Readiness.ps1` refuses to promote `setupService.status='pass'` while it is `false` (mirrors the refusal to `audit.jsonl` as `readiness-gate-refused`).

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

Validation loop is identical to Phase 4.11 step 2 — aggregate, call `Confirm-DryRunResults.ps1 -Mode render -Scope production`, run the discrepancy loop on `verdict='discrepancy'`, re-fan-out on `verdict='rerun'`, persist `production.<key>._validated` per key returned in `$record.validatedKeys` on `verdict='ok'`. The same `readiness.json → dryRun.reviewed` gate applies before `setupService.status='pass'` is allowed.

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

Besides the 16 steps there is one extra row, **`approval-requests`** — the email + Teams message ZED sends when a canary / rollback / production / private stamp run is stuck waiting on the OneBranch Approval Service (or an ADO approval): `halt` = approval needed / reminder / expiring soon, `failure` = approval task ended without approval. Ask: *"Who should get 'pipeline waiting for approval' emails and Teams messages (with the approval link)?"* — propose `halt` and `failure` = `emailGroups: [permanent]`, `teamsGroups: [teamsExtended]` (approvers usually aren't only the release owner). Also confirm `operational.approvalReminderHours` (default 4) and `approvalExpiryWarnHours` (default 12).

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

**Group 7 — Commit Excel**
Ask for:
- `commitExcel.mode` — *"Does your team keep ONE shared commit workbook with a new sheet per release (e.g. BCM's 'BCM Release Commits Tracker.xlsx'), or should ZED create a new commit Excel file every release?"* — `New file every release` (default → `per-release`) / `One shared workbook, one sheet per release` (→ `tracker`).
- `commitExcel.sheetNameTemplate` — Sheet name template (e.g., "Prot{{YYMM}}Commits"). `{{YYMM}}` is replaced at runtime. In tracker mode, propose the pattern of the workbook's most recent sheets (e.g. `BCM{{YYMM}}` when the last sheets are `BCM2609`, `BCM2610`).
- `commitExcel.sharePointFolder` — SharePoint folder path (e.g., "/Shared Documents/Monthly Releases")
- **Tracker mode only** (`commitExcel.tracker`), behavior in `step-behaviors.md → Step 4 → Tracker mode`:
  - `url` — the workbook's SharePoint sharing link. Resolve it via Graph (`/shares/{u!base64url}/driveItem`, then `/workbook/worksheets`) and show the owner the workbook name and its last 5 sheet names to confirm.
  - `columns` — **propose from the most recent sheet's header row** (row 1), owner confirms or edits. Suggest `source` by header text: `Date`→`date`, `Author`/`Owner`→`author`, a PR/commit link column→`link`, `Description`/`Comments`→`description`; every other column is team-filled — ask which of them must be filled before Step 4 completes (`required: true`; at least one). Copy each column's current width into `width`, and the header fill / font colour / bold / wrap into `headerStyle`. If older sheets spell a header differently, offer it as an `alias`.
  - Add the build-bot author (e.g. `OneBranch GitPushVersion Account`) to `commitExcel.excludeAuthors` if recent commits show one.
  - Verify access without changing the workbook: run `Invoke-CommitTracker.ps1 -Action Poll -SheetName <latest sheet>` (read-only) and show the fill % it reports. (Write access is first exercised by Step 4's Publish; a failure there halts Step 4 with the Graph error.)

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
    status        = '<pass|incomplete|fail>'   # pass = full validation green; incomplete = owner exited mid-wizard or some required field still empty; fail = validation hit type errors / placeholder values
    lastGroup     = '<last group identifier successfully persisted, e.g., "4.13" or "5b">'
    missingFields = @('<dotted.path>', '...')   # empty array on pass
}
```

Incremental rule: also call `Write-Readiness -Stage setupService -Data @{ status = 'incomplete'; lastGroup = '<N>' }` after each group completes, so a chat interruption mid-wizard still produces a meaningful record. The `run` command's chain check will see `status = 'incomplete'` and tell the owner exactly where to resume.
