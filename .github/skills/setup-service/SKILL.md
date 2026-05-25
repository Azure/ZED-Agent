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
    - `setup-service group <N>`     where N in {1, 2, 3, 4a, 4b, 4c, 5a, 5b, 6, 7, 8, 9, 10, 11, 11.1a, 11.3a, 11.3b, 11.4a}
                                    (jump directly to a group)

  Also use this skill from inside the `setup` command when Test-PreFlight reports
  empty service-config or pipeline-catalog fields and Behavior Rule 13 says to
  "resume the matching setup-service group <N>".
allowed-tools: shell
---

You are the ZED Agent setup-service wizard. The release owner has just typed `setup-service`, `setup-service validate`, or `setup-service group <N>`. Follow the procedure below.

> **This command is run ONCE per repo** to generate the service configuration files. After generation, the files should be committed to the repo. For subsequent releases, use `setup` instead.

### Phase 0 — Pre-flight gate (always runs first)

Before any prompts, **always invoke `test-preflight`** so the *machine* is known-good — `az`, `git`, `pwsh`, modules, MCP, Teams CDP, ASC reachability, skill scripts. There is no point collecting answers if `az` is broken.

`Test-PreFlight` returns three independent verdicts. Setup-service only gates on the first one:

| Verdict | What it covers | Setup-service behavior |
|---|---|---|
| **`envVerdict`** | Machine readiness — `az`, `git`, `pwsh`, modules, MCP, Teams CDP, ASC, skill scripts | **Hard gate.** `fail` → halt. `warn` → confirm. `pass` → continue. |
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

> **For `setup-service group <N>` jumps**: Phase 0 still runs. A broken `az` token will fail the very first ADO call in Group 11 anyway — surfacing it up-front saves the owner a wasted round of prompts.

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
| `4a` | Phase 4a — BVT Kusto (schema-aware) |
| `4b` | Phase 4b — Canary Detection Kusto (cluster-type discovery query) |
| `4c` | Group 4c — Canary Stamp Inventory (multi-cloud per-stamp `{ stampName, cloud, region, layout }`) |
| `4d` | Group 4d — Production Stamp/Region Inventory (per-cloud ASC snapshot) |
| `4e` | Phase 4e — Production Detection Kusto (cluster-type discovery query) |
| `5a` | Group 5 — Notification Groups (DLs + Teams chats) |
| `5b` | Group 5b — Notification Routing (4 default broadcasts + owner-added per-step / status entries) |
| `6` | Group 6 — Operational defaults |
| `7` | Group 7 — SafeFly defaults |
| `8` | Group 8 — Step Gates |
| `9` | Group 9 — CommitExcel + SharePoint |
| `10` | Group 10 — Test mode |
| `11` | Pipeline Catalog (Group 11 — pipeline-catalog.json entries) |

> **Group 11 sub-identifiers**: `11.canary`, `11.prod`, `11.dryrun <pipelineKey>`, `11.discovery-only`, `11.ev2`, `11.1a` (canary cluster-type resolver invocation — Kusto config itself now lives in **Phase 4b**), `11.3a` (production cluster-type resolver invocation — Kusto config itself now lives in **Phase 4e**), `11.3b` (SDS discovery + inventory generation — runs inside 11.3, after 11.3a and before 11.4), `11.4a` (pipeline YAML introspection — runs inside 11.4, before EV2 metadata is collected) — see the Group 11 section for behavior. Treat them as valid identifiers in step 2 of the dispatcher (do not reject as unknown).

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
- `service.stampTag` — Lowercase per-service infix used in stamp names (e.g. `prot` for `ea-can02-prot1`, `rec` for `eus-pod01-rec2`). Drives canary stamp parsing in `Get-StampInventory.ps1` and stamp filtering in the canary inventory (Group 4c) and production Kusto query (Phase 4e). Ask the release owner: *"Look at any one of your service's stamp names in EV2 or Kusto. The middle-segment letters between the layout and the trailing number — that's your stamp tag. Common values: `prot`, `rec`, `mab`, `bdp`."* Validate against `^[a-z]+$` and re-ask on invalid input.

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

**Group 4 — Kusto Configuration**

Kusto powers several discovery and analysis tasks in this agent:
- **BVT failure analysis** (Steps 6, 8, 11) — attributes BVT failures to your service.
- **Canary stamp cluster-type detection** (Steps 5, 7, 10) — discovers which cluster types (e.g., `sfmc`, `sfrp`) are currently live in canary stamps so the agent picks the right canary pipeline(s).
- **Production stamp cluster-type detection** (Step 15) — same idea as canary, but across production stamps for every cloud the service runs in (Public, Mooncake, Fairfax, Bleu, USNat, USSec, …) so the agent picks the right production pipeline(s) per cloud.
- **Region + stamp inventory per cloud** — enumerates the regions and stamp short names that belong to each cloud (Public / MC / FF / Bleu / …) for region scoping at production trigger time.

Collect the connection + query settings for BVT in **Phase 4a**, canary cluster-type detection in **Phase 4b**, the multi-cloud canary stamp inventory itself in **Group 4c**, the per-cloud production stamp snapshot in **Group 4d**, and production cluster-type detection in **Phase 4e**. The Phase 4b / Phase 4e Kusto values are stored under `kusto.canary.*` and `kusto.production.*` and used by `Resolve-PipelinesByClusterType.ps1` + the lazy clusterType resolver in `Get-StampInventory.ps1` whenever `pipeline-catalog.json → canaryRouting.mode` (or `productionRouting.mode`) is `cluster-type`. When routing mode is `static` or `explicit`, the resolver invocation (Phase 11.1a / Phase 11.3a inside Group 11) just no-ops — no Kusto call is made — but the Phase 4b / Phase 4e config still loads cleanly so flipping the mode later does not require a setup re-run.

---

**Phase 4a — BVT Kusto (schema-aware)**

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
     6. **Make the query agent-runnable** — the agent must analyze the submitted KQL and intelligently fill in / negotiate the runtime parameters it needs:
        - **Timestamp window**: scan the query for any of `ago(...)`, `datetime(...)`, `between(...)`, `now()`, or a `TimeStamp >=` predicate. If none reference a pipeline-driven anchor, tell the owner the agent's BVT step needs the query to be scoped to "since canary deploy started" and offer to inject the placeholder `{{PIPELINE_TRIGGER_TIME}}` in the right spot. Confirm the exact column to filter on (default `TimeStamp`) via `ask_user`.
        - **Team / service filter (or whatever scoping the query uses)**: don't assume every custom query scopes results with a `ResponsibleTeam == "<team>"` predicate — some teams use a completely different mechanism (e.g., a tag column, a build-id join, a namespace prefix on `TestCaseName`, a pre-filtered function in their own database, or no per-team filter at all because the cluster only holds their data). Ask the owner via `ask_user` how their query already narrows results to their service's BVT runs, with choices roughly: `Uses a {{RESPONSIBLE_TEAM}}-style column filter`, `Uses a different mechanism — let me describe it`, `No scoping needed — query is already service-specific`. Then:
           - On `Uses a {{RESPONSIBLE_TEAM}}-style column filter`: ask for the column name (e.g., `ResponsibleTeam`, `ServiceName`, `Owner`) and the match value, offer to inject `{{RESPONSIBLE_TEAM}}`, and collect `kusto.bvt.queryVariables.RESPONSIBLE_TEAM`.
           - On `Uses a different mechanism`: collect a free-text description of the mechanism via `ask_user` (persist to `kusto.bvt.scopingNotes` as a comment for future maintainers), then ask which placeholders — if any — the agent needs to substitute at runtime and what values to bind. Persist each placeholder under `kusto.bvt.queryVariables.<NAME>`. If the mechanism needs nothing dynamic (a build id, a stamp list, etc. is hard-coded by the owner inside the .kql file), just record the note and move on — do NOT force a `{{RESPONSIBLE_TEAM}}` placeholder.
           - On `No scoping needed`: leave `kusto.bvt.queryVariables` untouched and record `kusto.bvt.scopingNotes = "Query is pre-scoped — no runtime filter needed"`.
           - In all branches: confirm the final shape with the owner (echo the relevant section of the .kql + the placeholder list) before persisting.
        - **Failure semantics**: confirm with the owner that "a returned row = a failure to surface to the release owner" (the agent does not interpret severity — it just routes whatever rows come back). If the query also returns passes, instruct the owner to add a `where Result == false` (or equivalent) filter.
        - **Required columns for routing**: ask which columns the owner wants displayed in the failure summary (TestCaseName, Environment, Owner, Analysis link, etc.). Persist the column list to `kusto.bvt.displayColumns` so Steps 6/8/11 can render a consistent table even with a non-MAB schema.
        - **Additional placeholders**: if the owner referenced any other `{{...}}` tokens, prompt for each one and persist under `kusto.bvt.queryVariables.<NAME>`.
     7. **Dry-run check (optional but recommended)**: offer to execute the finalized query once via the Kusto MCP against the cluster/database the owner just provided, using a recent `{{PIPELINE_TRIGGER_TIME}}` (e.g., `ago(7d)`) to confirm it returns rows in the expected shape. On error, surface the Kusto error verbatim and let the owner edit the file and re-run the dry-run.
     8. **Show this hard reminder** before finishing:
        > ⚠️ **Contract**: Steps 6, 8, and 11 will run this query verbatim against the cluster/database you just provided, substituting `{{PIPELINE_TRIGGER_TIME}}`, `{{RESPONSIBLE_TEAM}}`, and any other placeholders you declared. Every returned row will be reported as a BVT failure. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run; no agent code change needed.

5. After persistence, recap to the release owner what was saved (cluster, database, query file path, team filter value, display columns).

---

**Phase 4b — Canary Detection Kusto (schema-aware)**

The agent uses this Kusto query for **canary pipeline selection** — to discover which cluster types (e.g., `sfmc`, `sfrp`) are currently in canary deployment. The same query also resolves `clusterType` for individual stamps in `inventory.canary.stamps[]` (Group 4c never prompts for `clusterType` — `Get-StampInventory.ps1` lazily runs this query on first canary read and joins by `StampName`). When `canaryRouting.mode != "cluster-type"` (set in Phase 11.0 later), the resolver invocation (Phase 11.1a) and the lazy join both no-op — but collecting the config here is cheap and lets owners flip the mode later without re-running setup.

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
     {{SERVICE_FILTER}}        (replaced with kusto.canary.serviceFilter at runtime,
                                e.g., ServiceName == 'prot')
     {{STAMP_PREFIX_FILTER}}   (replaced with kusto.canary.stampPrefixFilter at runtime,
                                e.g., StampName startswith 'ea-can' or
                                      StampName startswith 'ecy' or
                                      StampName startswith 'ccy')
   Downstream usage:
     1) Pipeline selection (Steps 5/7/10): the agent collects the SET of cluster
        types observed across all rows (by inspecting DeploymentUnit substrings —
        e.g., '-sfmc' → 'sfmc', '-sf' without '-sfmc' → 'sfrp'). This set is
        intersected with canaryRouting.clusterTypeMap to pick which pipelines to fire.
     2) Per-stamp clusterType (Group 4c stamps): rows are joined back by StampName
        and the inferred clusterType is written to inventory.canary.stamps[*].clusterType
        on first read by Get-StampInventory.ps1. Group 4c never prompts the owner
        for clusterType — Kusto is the single source of truth.
   Response parsing:
     ALWAYS use $resp.Tables[0].Rows.
   ```
3. **Ask the schema-fit question** via `ask_user`:
   > *"The default query above is valid for services in **Azure Backup**. Does your service fall under Azure Backup?"*
   > Choices: `Yes — Use default query`, `No — Use a different query`
4. **Branch on the answer**:

   **(A) `Yes — Use default query`** (default path):
   - Persist `kusto.canary.queryFile = "Canary-DeploymentUnits.kql"`. If the file doesn't exist in `.github/skills/zed-agent/queries/`, copy the canonical version above into it now. **Do NOT prompt for the filename.**
   - **Do NOT prompt for `kusto.canary.cluster` or `kusto.canary.database`** — write the Azure Backup defaults directly:
     - `kusto.canary.cluster` → `https://mabprod1.kusto.windows.net/`
     - `kusto.canary.database` → `MABKustoProd1`
   - Persist `kusto.canary.clusterTypeExtraction = { mode: "deployment-unit-substring" }`.
   - Ask only the **2 filter fields** (one at a time, persist after each):
     - `kusto.canary.serviceFilter` — KQL `where` predicate that selects rows belonging to your service (e.g., `ServiceName == 'prot'`). Substituted into `{{SERVICE_FILTER}}` at runtime.
     - `kusto.canary.stampPrefixFilter` — KQL `where` predicate that narrows `StampName` to your service's canary stamps. Substituted into `{{STAMP_PREFIX_FILTER}}` at runtime.

       **Canary stamp filter shape (service-agnostic guidance):** This value is a KQL `where`-clause fragment over the `StampName` column. The general shape is `StampName startswith '<prefix1>' or StampName startswith '<prefix2>' …`. Replace `<prefix...>` with the short-name prefixes your service uses for canary stamps. Leave empty if your custom `.kql` file does not use the `{{STAMP_PREFIX_FILTER}}` placeholder.

       **Conditional default offer:** If `service.name` matches a known MAB-family service (case-insensitive regex `^(WBCM|DM|Prot)$`), offer the MAB-historical predicate `StampName startswith 'ea-can' or StampName startswith 'ecy' or StampName startswith 'ccy'` as a suggested default via `ask_user` — but make clear this is a snapshot and the owner is free to edit. For all other services, present `ask_user` with **no pre-filled value** and the shape guidance above; do not bake one service's stamp prefixes into another service's setup.

   **(B) `No — Use a different query`**:
   - Walk the owner through the same guided setup as Phase 4a step 4(B) (custom query path), but persisting under `kusto.canary.*`:
     1. Ask `kusto.canary.cluster` and `kusto.canary.database`.
     2. Ask `Paste KQL now` vs `Point me at a .kql file in this repo`; capture the file into `.github/skills/zed-agent/queries/<service-name>-canary.kql` (paste path) or validate the existing file path. Persist to `kusto.canary.queryFile`.
     3. Reconcile timestamp window, service-scoping (`Uses a {{SERVICE_FILTER}}-style column filter` / `Uses a different mechanism` / `No scoping needed`), and stamp-prefix scoping (`{{STAMP_PREFIX_FILTER}}` or not). Persist `kusto.canary.serviceFilter`, `kusto.canary.stampPrefixFilter`, `kusto.canary.scopingNotes`, and any custom placeholders under `kusto.canary.queryVariables.<NAME>`.
     4. Confirm cluster-type extraction via `ask_user`: `Set/array column named DeploymentUnit (parse substrings like -sfmc, -sf)`, `Dedicated column (e.g., ClusterType)` (ask for column name), or `Other` (free text). Persist to `kusto.canary.clusterTypeExtraction`.
     5. Confirm result columns include at least `StampName` plus the cluster-type column; persist to `kusto.canary.resultColumns`.

5. **Hard reminder** before finishing:
   > ⚠️ **Contract**: Steps 5/7/10 will run this query verbatim, substituting `{{SERVICE_FILTER}}` / `{{STAMP_PREFIX_FILTER}}` / any custom placeholders. The agent then (a) extracts the SET of cluster types via `kusto.canary.clusterTypeExtraction` and intersects with `canaryRouting.clusterTypeMap` (Group 11) to pick canary pipelines, and (b) joins rows back by `StampName` to fill `inventory.canary.stamps[*].clusterType`. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run.

6. Recap to the release owner what was saved (cluster, database, query file path, service filter value).

---

**Group 4c — Canary Stamp Inventory**

The canary fleet is small, stable, and **owner-declared**. Some services have all canary stamps in one purpose-built cloud (e.g. the `Canary` cloud); others have canary stamps inside the **Public** cloud (e.g. `ecy`, `ccy` regions for Prot). Each stamp carries its own `{ cloud, region, layout }` so multi-cloud setups are represented natively.

**The owner is the only source of truth for which regions are canary.** The agent does **not** scan Azure Service Config looking for "canary datacenters" — Azure Service Config has no reliable, service-agnostic tag for that. Azure Service Config is used only as a **lookup table** to (a) map each owner-provided region short name to its `{ cloud, layout }`, (b) catch typos before they reach a release, and (c) surface whether a region has a passive recovery stamp.

`clusterType` is never prompted in Group 4c — it is filled lazily by `Get-StampInventory.ps1` running the Phase 4b Kusto query when Phase 11.0 sets `canaryRouting.mode` to `cluster-type`.

> **Azure Service Config vocabulary — for the recap only**
>
> Each `Clouds[].DataCenters[]` entry carries a `DatacenterType` comma-list. Two values matter for the recap:
> - **`PASSIVE`** — this datacenter IS a recovery-only copy. Never targeted as a canary stamp.
> - **`HAS_PASSIVE`** — this datacenter has an additional passive (recovery) copy behind the primary. Purely informational; surface it so the owner knows which regions have a recovery copy.
>
> Many services (e.g. Prot) only use `ACTIVE` / `PASSIVE` / `HAS_PASSIVE` and never tag canary datacenters at all. That is fine — the agent does not need that tag because the owner already told us which regions are canary.

Prerequisite: `service.stampTag` must already be set (Group 1). If it is empty, jump back to Group 1.

1. **Fetch Azure Service Config** by calling:
   ```powershell
   $asc = & .\.github\skills\zed-agent\scripts\Get-AzureServiceConfig.ps1
   ```
   Live-first; cache and committed snapshot are fallbacks. If the call surfaces a warning that it fell back to cache or snapshot, tell the release owner — they may want to fix `az login` before continuing so validation is grounded in truth. If the call throws or `$asc.data.Clouds.Count -eq 0`, halt and surface the error.

2. **Ask the owner for the canary region short names.** Read any existing `inventory.canary.regionPrefixHints` from disk first; if it is non-empty, offer the saved list as a one-tap default. Otherwise (and on re-runs where the owner says "change"), ask:

   > *"Which regions are canary regions for your service? List the region short names exactly as they appear in your stamp names. Comma-separated, lowercase. The agent will look each one up in Azure Service Config to confirm it exists and find its cloud + layout. Example for Prot: `ea-can, ecy, ccy`."*

   If Phase 4b already collected `kusto.canary.stampPrefixFilter`, derive a suggested default from it (e.g. the `startswith '<token>'` tokens) and offer:
   `1. Use <suggested list>   2. Provide my own   3. None of my regions are canary (skip Group 4c)`.

   Persist the trimmed lowercase list to `inventory.canary.regionPrefixHints`.

3. **Resolve each owner-provided short name against Azure Service Config.** For every short name `p` in the list, scan `$asc.data.Clouds[*].DataCenters[*]` and find every datacenter where `"$($dc.ShortName)-$($cloud.Layout)" -like "$p*"` (case-insensitive). This matches both exact short names (`ecy`) and shape-anchored prefixes (`ea-can` resolves to `(Canary, ea, can02)` because the full token `ea-can02` starts with `ea-can`).

   - **Zero matches** for a token → halt and re-prompt step 2 with: *"`<p>` doesn't match any datacenter in Azure Service Config. Check spelling, or remove it from the list."*
   - **Multiple matches across clouds** for a token (rare) → render the choices and ask the owner to pick which one is canary.
   - **One match per cloud** → record the `{ cloud, region: shortName, layout }` triple for that token. Multiple tokens may legitimately resolve to different `(cloud, layout)` triples — that's the multi-cloud case.

4. **For each resolved `(cloud, region, layout)` triple**, ask only for the stamp index list:

   > *"How many `{region}-{layout}-{stampTag}{index}` stamps does your service run in `<cloud> / <region>`? (Comma-separated indexes — e.g. `1, 1d, 2`. The agent builds the full stamp names.)"*

   For each index, build `stampName = "<region>-<layout>-<stampTag><index>"` and push `{ stampName, cloud, region, layout, clusterType: null }` to `inventory.canary.stamps`. **Never prompt for clusterType.**

5. **Validate immediately** by calling:
   ```powershell
   $inv = & .\.github\skills\zed-agent\scripts\Get-StampInventory.ps1 -Scope canary
   ```
   - If `$inv.drift` is non-empty, render the drift table (`stampName`, `reason`) and re-prompt for each drifted stamp. Common reasons: region not in the named cloud, stampTag mismatch, grammar mismatch.
   - If `$inv.stamps.Count -eq 0`, halt and re-run Group 4c from step 2.

6. **Recap + confirm.** Render the full inventory as a table. The `clusterType` column **must not** assert that `canaryRouting.mode` is anything — that decision lives in Phase 11.0. If Phase 11.0 has already set the mode to `cluster-type` and Phase 4b's Kusto is configured, the lazy resolver fills the column at validation time; otherwise it reads `(unresolved — set by Phase 11.0)`. Never infer `static` from a null `clusterType`.

   | Cloud | Region | Layout | HAS_PASSIVE | Stamps | clusterType |
   |-------|--------|--------|-------------|--------|-------------|
   | Public | ecy | pod01 | yes | ecy-pod01-prot1 | (unresolved — set by Phase 11.0) |
   | Public | ccy | pod01 | yes | ccy-pod01-prot1 | (unresolved — set by Phase 11.0) |
   | Canary | ea | can02 | no | ea-can02-prot1 | (unresolved — set by Phase 11.0) |

   Then `ask_user`:
   > *"Does this canary inventory look right? Picking `Edit` lets you redo the region list from step 2. Picking `Yes — looks good` finalizes the inventory and continues to Group 4d."*
   > Choices: `Yes — looks good`, `Edit`

   On `Edit`, jump back to step 2. On `Yes — looks good`, persist and remind the owner that any stamp added or decommissioned needs a re-run of `setup-service group 4c`.

---

**Group 4d — Production Stamp/Region Inventory (per-cloud ASC snapshot)**

The production fleet is too large to enumerate stamp-by-stamp the way Group 4c does for canary, but at *setup time* the agent CAN compute the full per-cloud inventory directly from ASC and persist a snapshot. This snapshot has two jobs:

1. **Phase 11.3 dry-runs** substitute `{{pubRegions}}`, `{{ffRegions}}`, `{{ffStamps}}` (and any cloud-prefixed equivalents) from this snapshot, so the production dry-run POST body looks like a real maximum-scope release — not an empty-string placeholder.
2. **Step 15 (real release)** re-fetches ASC live and **diffs against this snapshot**. Added regions/stamps are flagged as `+drift`, removed as `-drift`, and the owner sees the diff before the production POST is queued. On `Accept`, the diff is auto-merged back into `inventory.production.<cloud>` so the next release starts from the new baseline.

Prerequisite: `service.stampTag` (Group 1) and a successful Group 4c run (so the agent knows the stamp grammar). If `service.stampTag` is empty, jump back to Group 1.

1. **Fetch ASC** (re-uses the call from Group 4c if already loaded this session):
   ```powershell
   $asc = & .\.github\skills\zed-agent\scripts\Get-AzureServiceConfig.ps1
   ```
   On cache/snapshot fallback, warn the owner — a stale ASC at setup time means stale dry-run scope and noisy Step 15 drift.

2. **Pick active production clouds** via `ask_user` (multi-select) from the list of ASC clouds whose `Name` does NOT contain `Canary` or `BVTD3`. Typical choices: `Public`, `Fairfax`, `Mooncake`, `USNat`, `USSec`, `Bleu`. Persist to `inventory.production.cloudsActive` (array of cloud names, exact ASC casing). This is the master list — Phase 11.4's `ev2CloudCoverage.<key>` must be a subset of this when set later.

3. **Per chosen cloud, auto-build the snapshot** (no per-stamp prompting):
   - `layout` = `$asc.Clouds[<cloud>].Layout`
   - `regions` = `$asc.Clouds[<cloud>].DataCenters[].ShortName`
   - `stamps` = expanded from `<region>-<layout>-<service.stampTag><index>` grammar using the index list ASC declares per region (or, if ASC carries explicit stamp names, use those verbatim). Each entry: `{ stampName, region, index }`.

4. **Show the snapshot per cloud** for owner confirmation:
   ```
   Production inventory — Fairfax
     Layout:   pod01
     Regions:  usva, ussc, usaz, usga (4)
     Stamps:   usva-pod01-prot1, usva-pod01-prot2, ussc-pod01-prot1, … (47 total)
   Choices: Looks right, Edit regions, Edit stamps in a region, Skip this cloud
   ```
   - **`Edit regions`** — owner can deselect regions the service does NOT actually deploy to (rare but possible — e.g., a cloud has more DCs than the service is provisioned in). Persist the narrowed list.
   - **`Edit stamps in a region`** — owner can deselect stamps that aren't owned by this service inside a shared region. Persist the narrowed list.
   - **`Skip this cloud`** — record `inventory.production.<cloud> = { skipped: true, reason: "<owner free-text>" }` and exclude from production-side dry-run / drift checks.

5. **Persist** with provenance:
   ```json
   "inventory": {
     "production": {
       "cloudsActive": ["Public", "Fairfax", "Mooncake"],
       "Public": {
         "layout": "prod",
         "regions": ["eus", "wus", "eas", …],
         "stamps": [{ "stampName": "eus-prod-prot1", "region": "eus", "index": "1" }, …],
         "_snapshotFrom": { "ascSource": "live", "ascSha": "<sha>", "at": "<UTC ISO>" }
       },
       "Fairfax":  { … same shape … }
     }
   }
   ```

6. **Recap** to the release owner:
   - *"Snapshot saved for {N} clouds, {total regions}, {total stamps}."*
   - *"This is what Phase 11.3 will POST to your production pipelines for `{{pubRegions}}` / `{{ffRegions}}` / `{{ffStamps}}`-style parameters — no CCOA filtering, no exclusion list (those don't exist at setup time). Dry-run is a **maximum-scope** preview."*
   - *"At Step 15 of every real release, the agent re-fetches ASC live and diffs against this snapshot. If a region or stamp was added/removed since you ran Group 4d, you'll see a drift table and approve the new scope before the production POST goes out. On approval, this snapshot is updated automatically. Re-run `setup-service group 4d` any time to force-refresh the baseline."*

> **Drift contract for runtime**: `Resolve-RegionScope.ps1` (called at Step 15) MUST:
> 1. Call `Get-AzureServiceConfig.ps1` live.
> 2. For each cloud in `inventory.production.cloudsActive`, compute `live.regions \ snapshot.regions` (added) and `snapshot.regions \ live.regions` (removed), same for stamps.
> 3. If either set is non-empty, render the diff to the owner and require explicit `Accept` before substituting tokens.
> 4. On `Accept`, merge the live values into `inventory.production.<cloud>` and bump `_snapshotFrom.at`.
> 5. On `Reject`, halt Step 15 with a clear message — don't fall back to either side silently.

---

**Phase 4e — Production Detection Kusto (schema-aware)**

Mirrors Phase 4b exactly, but persists under `kusto.production.*` and is used by Step 10 / Step 15 to pick production pipelines when `productionRouting.mode == "cluster-type"`. Cluster-type is a pipeline-level attribute, so the resolver runs once per release (not per cloud) and the same query serves every cloud the pipeline pushes to. When `productionRouting.mode != "cluster-type"`, the resolver invocation (Phase 11.3a) and any lazy join no-op — but collecting the config here lets owners flip the mode later without re-running setup.

1. **Show the default production-detection query** by reading `.github/skills/zed-agent/queries/Production-DeploymentUnits.kql` from disk (or print the canonical canary-shaped query verbatim if the file is absent). The default is shape-identical to Phase 4b — it reports which cluster types are currently live across the production fleet, regardless of cloud.

2. **Show the required column / placeholder contract** (same shape as Phase 4b):
   ```
   Required columns in result rows:
     StampName, DeploymentUnit (a set/array of deployment unit names)
   Required placeholders in the query:
     {{SERVICE_FILTER}}        (replaced with kusto.production.serviceFilter)
     {{STAMP_PREFIX_FILTER}}   (replaced with kusto.production.stampPrefixFilter)
   Downstream usage:
     Resolve-PipelinesByClusterType.ps1 -Scope production extracts the SET of
     live cluster types via kusto.production.clusterTypeExtraction, intersects
     with productionRouting.clusterTypeMap, and returns the pipeline keys whose
     declared cluster type is currently live. Cloud fan-out happens AFTER
     resolution — each resolved pipeline pushes to whichever clouds are listed
     under ev2CloudCoverage.<key>.
   Response parsing:
     ALWAYS use $resp.Tables[0].Rows.
   ```

3. **Ask the schema-fit question** via `ask_user`:
   > *"The default production query above is valid for services in **Azure Backup** (same `EventLogAllClusters` schema as canary). Does your service fall under Azure Backup?"*
   > Choices: `Yes — Use default query`, `No — Use a different query`

4. **Branch on the answer** — shape mirrors Phase 4b:

   **(A) `Yes — Use default query`** (default path):
   - Persist `kusto.production.queryFile = "Production-DeploymentUnits.kql"`. If the file doesn't exist in `.github/skills/zed-agent/queries/`, copy the canonical version into it now.
   - **Do NOT prompt for cluster/database** — use the same Azure Backup defaults as canary:
     - `kusto.production.cluster` → `https://mabprod1.kusto.windows.net/`
     - `kusto.production.database` → `MABKustoProd1`
   - Persist `kusto.production.clusterTypeExtraction = { mode: "deployment-unit-substring" }`.
   - **Auto-derive `kusto.production.stampPrefixFilter` from ASC — do NOT prompt**:
     1. Run `.\.github\skills\zed-agent\scripts\Get-AzureServiceConfig.ps1` to load the ASC snapshot.
     2. Select the `Public` cloud entry (`$asc.data.Clouds | Where-Object { $_.Name -eq 'Public' }`) and collect the distinct lower-cased `ShortName` values from `DataCenters[]` (e.g., `eus`, `wus`, `weu`, `sea`, …).
     3. Persist the sorted distinct list to `kusto.production.stampPrefixFilter` verbatim. At runtime `Get-StampInventory.ps1` joins them into `StampName startswith 'eus' or StampName startswith 'wus' or …` and substitutes into `{{STAMP_PREFIX_FILTER}}`.
     4. Recap: *"Auto-filled `kusto.production.stampPrefixFilter` from ASC Public cloud (N short names). Edit `service-config.json` directly any time to add/remove entries — the wizard will not overwrite a non-empty value on re-run."* If `kusto.production.stampPrefixFilter` is already non-empty on re-run, leave it alone.
     5. **Sovereign clouds note**: this query covers Public only — Fairfax / Mooncake / USNat / USSec stamps require AME-tenant Kusto access this agent does not have. Their handling is out-of-band (mechanism TBD).
   - Ask only `kusto.production.serviceFilter` — same shape as `kusto.canary.serviceFilter`. Owner can reuse the canary value or specify a broader one for production.

   **(B) `No — Use a different query`** — walk the owner through the same custom-query flow as Phase 4b step 4(B), but persisting under `kusto.production.*` and asking for `kusto.production.clusterTypeExtraction` the same way (modes: `deployment-unit-substring` | `column` | `custom`).

5. **Hard reminder** before finishing:
   > ⚠️ **Contract**: Step 10 (Roll-Forward) and Step 15 (Production Rollout) will invoke `Resolve-PipelinesByClusterType.ps1 -Scope production` **once per release** — not per cloud. The resolver runs this query verbatim, extracts cluster types via `kusto.production.clusterTypeExtraction`, and intersects with `productionRouting.clusterTypeMap` to decide which production pipeline(s) to trigger. Each resolved pipeline then pushes to whichever clouds are listed under `ev2CloudCoverage.<key>`. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run.

6. Recap to the release owner what was saved (cluster, database, query file path, service filter).

> If the release owner uses the **same** Kusto cluster/database for canary and production, keep them as separate config keys — that's fine, just enter the same values.

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

**Group 11 — Pipeline Catalog**

This generates `pipeline-catalog.json`. **Critical insight:** every service's pipelines have *different* `templateParameters` keys — there is **no fixed schema**. The agent treats `templateParameters` as a **free-form, pass-through key-value object** that is forwarded verbatim to the ADO pipeline trigger API at runtime. Do **not** assume a fixed set of keys; do **not** reject unknown keys.

This group is **evidence-driven, not memory-driven**: for every pipeline, the agent learns the real-world parameter shape from (1) the **last few successful production runs** of that pipeline in ADO and (2) the **YAML on disk in the pipeline's source repo**, then **validates** its understanding by queuing a real ADO run and cancelling it within seconds before any agent picks it up. The owner never has to recite parameter names from memory — they only confirm or correct what the agent already discovered.

The flow has five phases. **Persist each answer immediately** to `pipeline-catalog.json` (every other group's incremental-write rule applies here too):

- **Phase 11.0** — Cluster specificity + pipeline count (asked once, sets the shape of the rest)
- **Phase 11.1** — Per-pipeline discovery (prior runs + YAML, for canary pipelines)
- **Phase 11.2** — Per-pipeline dry-run validation (canary pipelines, fanned out in parallel)
- **Phase 11.3** — Repeat 11.1 + 11.2 for production pipelines
- **Phase 11.4** — EV2 metadata (service groups, cloud coverage, service tree IDs — unchanged from the prior wizard shape)

The official build pipeline (Phase 11.0a) follows the same discovery + dry-run pattern but is asked once at the top.

#### Reserved placeholders

The agent reserves these `{{...}}` tokens and substitutes them at runtime — **never** ask the owner to provide a value for them, and **never** drop them when they appear inside `templateParameters` discovered from prior runs or YAML:

- `{{currentBranch}}` — replaced with the active release branch (e.g., `releases/svc2604`)
- `{{canaryStamps}}`, `{{canaryRegions}}` — replaced with the live `inventory.canary.stamps[].stampName` / distinct `inventory.canary.stamps[].region` from `service-config.json` (Group 4c). For `cluster-type` routing, the agent further filters `inventory.canary.stamps` to entries whose `clusterType` (resolved lazily via the Phase 4b Kusto query) matches the pipeline's declared `clusterType` before joining into the parameter format the pipeline expects (CSV, JSON array, etc. — auto-detected from prior-run shape in `canary.<key>.discoveryNotes.stampNameStyle`).
- `{{excludeStamps}}`, `{{pubRegions}}`, `{{ffStamps}}`, `{{ffRegions}}` (and any cloud-prefixed analogues like `{{mcRegions}}`, `{{mcStamps}}`) — at **real release time** (Step 15), replaced with CCOA / SafeFly-narrowed region scope minus the live exclusion list. Source universe is `inventory.production.<cloud>` (Group 4d); CCOA filter and exclusion list narrow it. At **dry-run time** (Phase 11.3), only the universe applies — see the Phase 11.2 substitution table for the exact mapping.
- `{{sdpType}}`, `{{validateOnly}}` — replaced based on rollout mode

> **Why canary stamps are tokenized, not literal**: prior runs are stale by definition — a stamp added or decommissioned since the last successful run would silently rot into `templateParameters` and only surface at real-release time. Group 4c is the owner-curated source of truth, validated against ASC. Treating canary stamp/region values as reserved tokens makes the dry-run an honest preview of what the next real run will send: shape learned from prior runs, values pulled live from Group 4c.

When the agent shows owner-facing diffs, render these as **highlighted tokens with a one-line tooltip** explaining the runtime substitution.

#### Auth & cost

Every ADO REST call in Group 11 uses the same `az login` identity that runs `setup` / `setup-service`. The token is acquired on the fly with `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798` (the fixed Azure DevOps resource GUID — same pattern used by `Get-RegionMapping.ps1` and `Get-Ev2RolloutStatus.ps1`). No PAT, no separate sign-in. If a call returns 401, run `Repair-AzAuth.ps1 -Tenant 'microsoft.com'` and retry once; on 403, halt the wizard with the explicit message *"Your account lacks Pipelines (write) on `{org}/{project}`. Ask your project admin to grant `Build Service (queue/cancel)` permission, then re-run `setup-service group 11`."*

Dry-runs in Phase 11.2 / 11.3 do create real ADO runs that the owner will see in pipeline history. The agent cancels each within **5 seconds** of queueing (well before any agent picks the work up), so no actual deployment happens, but the run row remains visible. Tell the owner this up front (see Phase 11.0 intro).

---

#### Phase 11.0 — Cluster specificity, pipeline count, and routing mode

Ask via `ask_user`, **in this order**, persisting after each answer:

1. **Official Build** — pipeline name + ID. Then run **Phase 11.1 discovery** against the official build pipeline (single instance, not a fan-out). The same prior-run + YAML logic applies — see below.

2. **Cluster specificity** (asked once, applies to canary and production):

   > *"How are your service's deployment pipelines structured?*
   > *  (a) **By region / stamp only** — every canary pipeline serves the same cluster type; the agent triggers all of them every release.*
   > *  (b) **By cluster type** — each region hosts multiple cluster-type variants (e.g., SFMC + SFRP) served by separate pipelines; the agent queries Kusto at runtime to pick which pipeline(s) to trigger per release."*

   > ⚠️ **Never auto-default this answer.** `canaryRouting.mode` and `productionRouting.mode` are load-bearing — they decide whether `Resolve-PipelinesByClusterType.ps1` and the lazy `clusterType` resolver in `Get-StampInventory.ps1` actually run. If `pipeline-catalog.json` already has a non-empty value on re-entry, show it back to the owner and explicitly ask *"keep `<existing mode>` or change?"* before persisting. If `pipeline-catalog.json` is fresh / missing the field, you **must** ask the question above and wait for an answer — do not silently write `static` because it is the conservative default.

   - On `(a)`: persist `canaryRouting.mode = "static"` and `productionRouting.mode = "static"`.
   - On `(b)`: persist `canaryRouting.mode = "cluster-type"` and **immediately ask production separately** (production topology can be asymmetric):
     > *"And your production pipelines — same split (by cluster type), or static (by region only)?"*
     Persist `productionRouting.mode` accordingly. If either mode is `cluster-type`, persist an empty `clusterTypeMap: {}` placeholder under that block — the map is filled in Phase 11.1 once pipeline keys are known.

3. **Canary pipeline count**:
   > *"How many canary pipelines does your service have? (Just the count — I'll learn each one's parameters from ADO in a moment.)"*

   For each, collect only **key, name, id**, and (conditionally) **clusterType** up front:
   - **key** — service-defined identifier the agent uses internally (e.g., `SVC-SFMC`, `DM-EACAN`)
   - **name** — display name as it appears in ADO
   - **id** — the integer ID from the pipeline URL (`definitionId=XXXXXX`)
   - **clusterType** — **ask only if `canaryRouting.mode == "cluster-type"`**:
     > *"Which cluster type does this pipeline serve? (e.g., `sfmc`, `sfrp`, `eap`)"*

     Persist to `canary.<key>.clusterType` and also append `<key>` to `canaryRouting.clusterTypeMap[<clusterType>]` (use array form if the type already maps to another key). Phase 11.1's inference step then becomes a **cross-check** rather than the source of truth — if YAML/prior-run evidence contradicts the owner-declared cluster type, surface it as a discrepancy. If `canaryRouting.mode == "static"`, skip this question entirely.

   Do **not** ask for `templateParameters` here — Phase 11.1 derives them.

4. **Production pipeline count + key/name/id** — same pattern. Ask `clusterType` per pipeline only when `productionRouting.mode == "cluster-type"`; persist to `production.<key>.clusterType` and append to `productionRouting.clusterTypeMap[<clusterType>]`.

---

#### Phase 11.1 — Per-pipeline discovery (evidence-driven)

For each canary pipeline collected in Phase 11.0 (and the official build, and later each production pipeline), **fan out in parallel** using `ForEach-Object -Parallel`:

1. **Read prior successful runs** of the pipeline. First, ask the owner via `ask_user` whether they want to hand-pick the reference runs (which gives them control over *which* historical truth the agent learns from — useful when recent runs were one-off hotfixes with non-representative parameters):

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

   **On `Use last 3 successful runs (auto)`** — run the original auto-fetch:
   ```powershell
   $runs = & .github/skills/zed-agent/scripts/Read-PriorRun.ps1 `
       -Organization $cfg.ado.organization `
       -Project $cfg.ado.project `
       -PipelineId $entry.id `
       -ResultFilter "succeeded" `
       -Top 3
   ```

   The script returns normalized objects: `{ runId, runUrl, finishedAt, sourceBranch, templateParameters }`. If fewer than 3 runs exist (new pipeline), return whatever's available; if zero, tell the owner *"No prior successful runs found for `{key}` — I'll rely on YAML only and lean more heavily on your review."*

2. **Fetch the pipeline YAML** from its source repo's base branch. ADO knows the *repo* and *path* (every YAML-based pipeline definition stores them under `configuration.repository` and `configuration.path`), but it does NOT reliably know the **branch** to read from — the pipeline definition only pins a default branch for triggers, which is often `main` even when the team actually develops on `develop` or a release branch. So the agent always **shows the owner exactly what it discovered and the branch it intends to use, and asks for confirmation before reading a single byte of YAML** — owner can either accept or redirect to a different location.

   ```powershell
   $yamlInfo = & .github/skills/zed-agent/scripts/Read-PipelineYaml.ps1 `
       -Organization $cfg.ado.organization `
       -Project $cfg.ado.project `
       -PipelineId $entry.id
   ```
   The script:
   - Calls `GET /_apis/pipelines/{id}?api-version=7.1` to discover `configuration.type`, `configuration.repository`, and `configuration.path` directly from ADO.
   - Computes a **proposed branch**: if the YAML repo equals the wizard's current repo, use `cfg.ado.baseBranch`; otherwise check `yamlRepos.{repoName}.baseBranch` for a previously-persisted value; otherwise fall back to the pipeline definition's default branch (`configuration.repository.defaultBranch`, typically `refs/heads/main`).
   - **Always confirm with the owner via `ask_user`** before fetching:
     > *"For pipeline `{key}` (`{name}`), I'm about to read the YAML from:*
     > *  • Repo: `{repoName}` ({same-repo|cross-repo})*
     > *  • Path: `{configuration.path}`*
     > *  • Branch: `{proposedBranch}` (source: {cfg.ado.baseBranch | yamlRepos cache | ADO default})*
     >
     > *Use this, or point me somewhere else?"*
     > Choices: `Use this`, `Change branch`, `Point me at a different YAML`, `No YAML — use prior runs only`

     - **`Use this`** — proceed; persist `yamlRepos.{repoName}.baseBranch = <proposedBranch>` if the repo wasn't already in the cache.
     - **`Change branch`** — ask for the branch name only (`develop`, `main`, `releases/svc2604`, …), then re-show the confirmation. Persist the new value to `yamlRepos.{repoName}.baseBranch`.
     - **`Point me at a different YAML`** — collect a `repo:branch:path` shorthand via `ask_user` (the `repo` half may be a bare name within the same org/project, or a full `org/project/repo` for cross-org). Validate the file exists at that ref before continuing.
     - **`No YAML — use prior runs only`** — skip step 2 entirely and record `_learnedFrom.yamlSource = "absent"`. Phase 11.1 step 3 then works from prior-run values alone.

   - **Fallback for classic / designer / non-YAML pipelines**: if `configuration.type != "yaml"` (e.g., a UI-built classic pipeline, or a pipeline whose definition predates YAML), the auto-discovered repo/path are empty. In that case the confirmation prompt above is replaced with a direct collection prompt:
     > *"Pipeline `{key}` (`{name}`) doesn't expose a YAML source in its ADO definition (looks like a classic/designer pipeline). Where is its parameter definition?*
     > *  • Path to a YAML file in this repo (e.g., `pipelines/canary.yml`)*
     > *  • Path to a YAML file in another repo (give `repo:branch:path` shorthand)*
     > *  • `none` — no YAML source; rely on prior-run evidence only"*

     On `none`, skip step 2 entirely and record `_learnedFrom.yamlSource = "absent"`.
   - Fetches the YAML content from the confirmed branch.
   - Recursively follows every `extends:` template reference (cross-repo allowed). For each new repo encountered in an `extends:` chain, run the same confirmation prompt (proposed branch from `yamlRepos` cache or ADO default) before fetching, and persist to `yamlRepos`.
   - Returns the merged `parameters:` block as a normalized list with `name`, `type`, `default`, `values` (for enum-typed params), plus `_resolvedFrom` provenance: `{ repo, branch, path, sha }` per parameter.

3. **Agent deep analysis** — synthesize a single proposed `templateParameters` map from (1) + (2):
   - **Baseline**: union of all parameters declared in the YAML.
   - **Concrete values**: prior-run values **per parameter**, mode-of-values across the 3 runs (most common wins). If the 3 runs disagree, flag the parameter as `mode-disagreement` in `agentGaps`.
   - **Reserved-token preservation**: if a prior-run value matches one of the reserved `{{...}}` tokens **or** the YAML's `default` is a reserved token, keep it as the token (do not substitute the literal from history).
   - **Canary stamp / region detection (token replaces literal)**: prior-run values are excellent for *teaching the agent the parameter shape* (CSV vs JSON array, naming style, count) but they are **not** trusted as the actual values to send — Group 4c's `inventory.canary.stamps` is the truth. For each parameter whose prior-run value looks like a canary stamp list or canary region list (i.e., the values are a subset of `inventory.canary.stamps[].stampName` / distinct `inventory.canary.stamps[].region`, or look like `<region>-<layout>-<stampTag><index>` triples), **replace the literal with the matching reserved token** (`{{canaryStamps}}` or `{{canaryRegions}}`) in the proposal. Record the detected delivery shape (CSV / semicolon-list / JSON array) under `canary.<key>.discoveryNotes.stampNameStyle` so the runtime substitution knows how to join the inventory values. If detection is ambiguous (e.g., the prior-run value contains stamps that are NOT in `inventory.canary.stamps`), flag as `agentGaps: stamp-list-drift: [<stamps not in inventory>]` and surface in the proposal review so the owner either updates Group 4c or confirms the literal.
   - **Cluster-type cross-check**: if `canaryRouting.mode == "cluster-type"` and the owner already declared `entry.clusterType` in Phase 11.0, scan the YAML and prior runs for stamp-list / region-list parameters whose values cluster around a single suffix (e.g., all entries end in `-sfmc`). If the inferred suffix **disagrees** with the owner-declared cluster type, flag it in `agentGaps` as `clusterType-mismatch: declared <X>, evidence suggests <Y>` so the owner can resolve in the proposal review. If `clusterType` was NOT declared (older runs of the wizard, or owner skipped), fall back to using the inferred value as the proposal — same behavior as before.
   - **Unknown / new params**: parameters in YAML that have no prior-run value and no `default` → mark `requiresOwnerInput: true` in the proposal.

4. **Render the proposal** to the owner in a single review block. This block is the **single point of human approval** between discovery and dry-run: the owner sees the exact `templateParameters` map the agent will POST to the ADO pipeline-runs API — first in Phase 11.2's queue-and-cancel dry-run, and then in every real release going forward. For each parameter, the block shows where the value came from (prior run / YAML default / reserved token) and lists every gap the agent could not resolve on its own. Nothing proceeds to Phase 11.2 (dry-run queue) without explicit owner sign-off here.

   ```
   ┌─ Pipeline: SVC-SFMC (3527) ──────────────────────────────────────┐
   │ YAML:  Mgmt-RecoverySvcs-BackupDataPlane/pipelines/canary.yml    │
   │        @ develop · sha 7a3f4b1                                   │
   │ Prior: run 28471 (2026-05-19), 28392 (2026-04-22), 28203 (2026-03-24) │
   │                                                                  │
   │ Proposed templateParameters:                                     │
   │   ServiceTreeId      = "<guid>"            ← prior runs (all 3)  │
   │   SourceBranch       = "{{currentBranch}}" ← YAML default token   │
   │   PubCanaryStamps    = "ea-can-01,..."     ← prior run (latest)  │
   │   SdpType            = "{{sdpType}}"       ← reserved token       │
   │   ValidateOnlyRollOut= "{{validateOnly}}"  ← reserved token       │
   │   ExcludeStamps      = "{{excludeStamps}}" ← reserved token       │
   │                                                                  │
   │ clusterType: "sfmc" (declared in Phase 11.0 · ✓ matches evidence)│
   │                                                                  │
   │ Gaps the agent could not resolve:                                │
   │   • RolloutNotes — declared in YAML, no prior value, no default  │
   └──────────────────────────────────────────────────────────────────┘
   Choices: Accept, Edit a value, Reject, Show diff vs YAML defaults
   ```

   Rules for rendering the `clusterType` line:
   - If `canaryRouting.mode == "static"` → omit the line entirely.
   - If owner **declared** it in Phase 11.0 and the cross-check agrees → show `clusterType: "<declared>" (declared in Phase 11.0 · ✓ matches evidence)`.
   - If owner **declared** it but the cross-check disagrees → show `clusterType: "<declared>" (declared in Phase 11.0 · ⚠ evidence suggests "<inferred>")` and also list the discrepancy in the **Gaps** section so it must be resolved before `Accept` is allowed.
   - If owner did **not** declare it (older catalog, owner skipped) → show `clusterType: "<inferred>" (inferred from <evidence source> — please confirm)` and treat as a gap.

   Loop on the choice until owner picks `Accept` or `Reject`. On `Edit a value` ask which key, collect new value via `ask_user`, re-render. On `Reject`, drop to the legacy paste-YAML / paste-JSON / manual flow as a fallback.

5. **Persist** the accepted proposal:
   - `canary.<key>.templateParameters` = accepted map (with reserved tokens preserved as strings).
   - `canary.<key>._learnedFrom` = `{ runIds: [...], yamlPath, yamlRepo, yamlBranch, yamlSha, learnedAt: <UTC ISO> }`
   - `canary.<key>.discoveryNotes` = `{ exclusionFormat: <auto-detected — comma|semicolon|json-array>, stampNameStyle: <auto-detected>, freeText: "" }`
   - `canary.<key>.agentGaps` = list of unresolved-gap descriptions (empty array on full success).
   - If routing mode is `cluster-type` and a `clusterType` was inferred, persist `canary.<key>.clusterType` and also update `canaryRouting.clusterTypeMap[<clusterType>]` to include this pipeline key (use array form if the suffix already maps to another key).

   Underscore-prefixed fields (`_learnedFrom`) are stripped by the schema-driven empty-skeleton generator but accepted by the validator — they're metadata, not config.

---

#### Phase 11.1a — Canary cluster-type resolver invocation (config now lives in Phase 4b)

> **Phase 11.1a is a resolver invocation only.** The Kusto cluster / database / query file / filters used to discover which cluster types are currently live in canary are collected up-front in **Phase 4b — Canary Detection Kusto** (Group 4). This phase exists solely to invoke `Resolve-PipelinesByClusterType.ps1 -Scope canary` between Phase 11.1 (per-pipeline discovery) and Phase 11.2 (dry-run validation) so the dry-run fan-out only fires for currently-live pipelines.

1. **Read `pipeline-catalog.json → canaryRouting.mode`** (set during Phase 11.0). Branch:

   **If `mode == "static"`** — no resolution needed. The resolver returns every `canary.*` key, so every canary pipeline is dry-run-queued by Phase 11.2. Recap: *"Phase 11.1a: canary routing is `static`, all canary pipelines participate in the dry-run fan-out."* Exit.

   **If `mode == "explicit"`** (or `_pendingExplicitList` schema-fallback equivalent) — no resolution needed. The resolver returns every `canary.*` key; per-key triggering is then narrowed by the static `canaryStamps` / `canaryRegions` list at real-release time. Show the brittleness reminder one more time:
   > ⚠️ **Brittleness reminder**: the agent will trigger canary pipelines based on the static `canaryStamps` / `canaryRegions` list you declared in Group 11. Keep that list fresh when the org rebalances. To switch to dynamic Kusto-driven routing later, re-run `setup-service group 11` and change `canaryRouting.mode` to `cluster-type`. The Phase 4b Kusto config is already in `service-config.json` and will be used automatically.

   Exit.

   **If `mode == "cluster-type"`** — proceed.

2. **Verify Phase 4b config exists**. If `kusto.canary.cluster`, `kusto.canary.database`, and `kusto.canary.queryFile` are not all set, halt with: *"Phase 4b — Canary Detection Kusto has not been collected yet. Re-run `setup-service group 4b` first, then re-run `setup-service group 11.1a`."* Do NOT prompt for Kusto values here.

3. **Invoke the resolver**:
   ```powershell
   $resolved = & .\.github\skills\zed-agent\scripts\Resolve-PipelinesByClusterType.ps1 -Scope canary
   ```
   On error, surface the Kusto error verbatim and let the owner edit `kusto.canary.queryFile` (the agent re-reads it on every run) or re-run Phase 4b to fix the config.

4. **Recap** to the release owner: the set of resolved canary pipeline keys, the set of cluster types observed, and the keys filtered out because no cluster-type match was found. These keys form the dry-run universe for Phase 11.2.

> **Why Phase 11.1a still exists**: routing mode is set inside Group 11 (Phase 11.0) AFTER Phase 4b, so the *decision* of whether to invoke the resolver lives here next to the routing-mode declaration. The Kusto details themselves are collected in Phase 4b so the cluster-type detection query is set up at the same time as BVT — owners think about "Kusto config" once, in Group 4, not scattered across Group 4 and Group 11.

---

#### Phase 11.2 — Dry-run validation (parallel)

Once every canary pipeline has an accepted proposal on disk — i.e., the owner has seen the prior-run + YAML evidence in the Phase 11.1 review block and clicked `Accept` — show the **dry-run consent banner** once, before queueing anything:

> *"I've finished analyzing prior runs and YAML for every canary pipeline, and you've accepted the proposed parameters. Next, I'll queue a real ADO run per pipeline with those parameters and cancel each within 5 seconds — well before any agent picks it up. You'll see a cancelled run in ADO history; nothing actually deploys. This validates that the parameters I learned are correct and that I have the right ADO permissions. OK to proceed?"*

On `No`, halt and tell the owner they can re-run with `setup-service group 11.discovery-only` to keep the accepted proposals on disk and skip the queue-and-cancel validation (less safe — parameter mistakes won't surface until the first real release).

On `Yes`, **first resolve the trigger set** so dry-runs only fire for pipelines that would actually be triggered at runtime. This makes the dry-run fan-out cheaper and surfaces "declared in catalog but not currently live" gaps to the owner before they hit a real release:

```powershell
$res = & .github/skills/zed-agent/scripts/Resolve-PipelinesByClusterType.ps1 -Scope canary
$canaryKeys = @($res.resolved | ForEach-Object { $_.pipelineKey })
```

- `canaryRouting.mode == "static"` → resolver returns every key under `canary.*`; behavior identical to the previous wizard pass.
- `canaryRouting.mode == "cluster-type"` → resolver runs the Phase 11.1a Kusto query, intersects the live cluster-type set with `canaryRouting.clusterTypeMap`, and returns only the keys whose cluster type is currently live. Any `canary.*` entry whose declared `clusterType` is NOT in the live set is surfaced in `$res.skipped` with `reason: "no live cluster type matched at query time"` — record each as `canary.<key>._validated = { skipped: true, reason: "no live cluster type", resolvedAt: <UTC ISO> }` and tell the owner: *"Skipping {N} pipeline(s) in dry-run because no live cluster type: {list}. These remain in `pipeline-catalog.json` and will be dry-run automatically next time their cluster type appears in Kusto."*

If the resolver throws (Kusto failure, empty live set, missing `clusterTypeMap` entry), halt Phase 11.2 and surface the error verbatim — do NOT fall back to dry-running everything; that defeats the purpose of `cluster-type` mode.

Fan out a dry-run for the resolved set in parallel using `ForEach-Object -Parallel`:

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

1. Resolve the entry from `pipeline-catalog.json`. Substitute reserved tokens with the **same values a real release would send today** — the only exceptions are the branch (use a dummy ref so nothing builds) and the rollout-mode tokens (force `validateOnly = true`). The substitution table is part of the script so it's auditable:
   - `{{currentBranch}}` → `refs/heads/setup-service-dry-run` *(dummy — keeps the run off any real branch)*
   - `{{canaryStamps}}` → joined `inventory.canary.stamps[].stampName` from `service-config.json` (Group 4c), filtered by `entry.clusterType` when `canaryRouting.mode == "cluster-type"`, joined using `canary.<key>.discoveryNotes.stampNameStyle` (CSV / semicolon / JSON array)
   - `{{canaryRegions}}` → joined `inventory.canary.regions` using the same style
   - `{{excludeStamps}}` → `""` *(dry-run never excludes anything; the exclusion source — canary BVT failures + active SafeFly flags — doesn't exist at setup time)*
   - `{{pubRegions}}`, `{{ffRegions}}`, `{{ffStamps}}`, `{{mcRegions}}`, `{{mcStamps}}`, `{{nationalRegions}}`, etc. — for **canary** dry-run, `""`; for **production** dry-run, joined from `inventory.production.<cloud>` (Group 4d). Cloud is inferred from the token prefix: `pub*` → `Public`, `ff*` → `Fairfax`, `mc*` → `Mooncake`, `nat*` → `USNat`, `sec*` → `USSec`, `bleu*` → `Bleu`. If the token prefix doesn't match a cloud in `inventory.production.cloudsActive`, fall back to `""` and flag `agentGaps: token-cloud-unmapped: <token>` so the owner can declare the mapping. The join shape (CSV / semicolon / JSON array) is taken from `production.<key>.discoveryNotes.stampNameStyle`.
   - `{{sdpType}}` → `"Express"`
   - `{{validateOnly}}` → `"true"` *(forces ADO into validation mode — extra belt-and-suspenders on top of the 5-second cancel)*

   The point: the dry-run POST body looks *identical* to a real release POST body for every parameter the owner controls — same stamps, same regions, same JSON shape. Only the branch and rollout-mode are stubbed. That way if the parameter format is wrong, the dry-run catches it; if it's right, the owner sees in ADO history exactly what a real release would queue.
2. `POST https://dev.azure.com/{org}/{project}/_apis/pipelines/{id}/runs?api-version=7.1-preview.1` with body `{ "resources": { "repositories": { "self": { "refName": "refs/heads/setup-service-dry-run" } } }, "templateParameters": <substituted map> }`. Capture `runId` and `runUrl`.
3. Sleep 5 seconds.
4. `PATCH https://dev.azure.com/{org}/{project}/_apis/build/builds/{runId}?api-version=7.0` with body `{ "status": "cancelling" }` — same cancel mechanic Step 15 test-mode uses (retry up to 3 times).
5. Return `{ pipelineKey, runId, runUrl, queuedAt, cancelledAt, finalState, queuedParameters }`.

When all dry-runs return, **aggregate** the results and render an owner review block:

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
2. Ask what's wrong (free-text via `ask_user`, e.g., *"PubCanaryStamps was `ea-can-01,ea-can-02` but should be `ea-01,ea-02` — we dropped the `-can` prefix last quarter"*).
3. The agent classifies the fix into one of:
   - **(a) Catalog-only fix** — owner gives a corrected value; agent updates `canary.<key>.templateParameters` directly and re-runs the dry-run for that one pipeline.
   - **(b) Reserved-token semantics drift** — the agent's stub-value substitution is wrong (e.g., `{{validateOnly}}` should be `"True"`, not `"true"`, for this service). Same as (a) but the agent records the discrepancy in `canary.<key>.discoveryNotes.freeText`.
   - **(c) Skill / agent.md edit required** — the discrepancy reflects an out-of-date assumption baked into `setup-service/SKILL.md` or `ZedAgent.agent.md`. Trigger the **MD edit proposal flow**:

     > *"Currently `{file}` lines `{start}-{end}` say:*
     >
     > ```
     > {old text excerpt}
     > ```
     >
     > *Your service needs:*
     >
     > ```
     > {proposed new text}
     > ```
     >
     > *If I apply this edit, the agent will `{new outcome}` from now on (affects: `{list of impacted code paths or future setup-service runs}`)."*
     >
     > Choices: `Apply the edit`, `Reject — keep current behavior`, `Show me the diff and I'll apply by hand`

     Persist the proposal (whether accepted or rejected) as a `md-edit-proposal` entry in `audit.jsonl`. On `Apply the edit`, run the edit via `replace_string_in_file`-equivalent, validate the resulting file still parses (re-load SKILL.md / agent.md), and continue.

4. After each fix, re-run the dry-run for that pipeline and loop until the owner says `All good`.

Persist a `_validated` stamp on each canary pipeline once its dry-run is clean: `canary.<key>._validated = { at: <UTC ISO>, lastDryRunId: <id>, by: <owner email or 'wizard'> }`.

---

#### Phase 11.3 — Production pipelines (same shape as canary)

Repeat Phase 11.1 + Phase 11.2 for production pipelines:

- **Discovery (11.1)** reads the last 3 successful **production** runs (not canary). Production parameters typically include `BranchPrefix`, `SdpType`, `Pub*Stamps`, etc. — treat these as service-specific, **not** required.
- **Resolve before dry-run — once, not per cloud.** A pipeline's `clusterType` is a pipeline-level attribute, not a cloud-level one. A single production pipeline may push to multiple clouds (see `ev2CloudCoverage.<key>`), but its declared cluster type is the same everywhere it pushes — the resolver runs once and the dry-run fan-out happens at the **pipeline** level, exactly like canary:

  ```powershell
  $res = & .github/skills/zed-agent/scripts/Resolve-PipelinesByClusterType.ps1 -Scope production
  $prodKeys = @($res.resolved | ForEach-Object { $_.pipelineKey })
  $prodResults = $prodKeys | ForEach-Object -Parallel {
      & .github/skills/zed-agent/scripts/Invoke-PipelineDryRun.ps1 `
          -Organization $using:org `
          -Project $using:project `
          -PipelineKey "production:$_" `
          -CatalogPath $using:catalogPath `
          -CancelAfterSeconds 5
  } -ThrottleLimit 8
  ```

  - `productionRouting.mode == "static"` → resolver returns every key under `production.*`; behavior identical to canary static mode.
  - `productionRouting.mode == "cluster-type"` → resolver runs the Phase 11.3a Kusto query once, intersects the live cluster-type set with `productionRouting.clusterTypeMap`, and returns the resolved pipeline keys. Any `production.*` entry whose declared `clusterType` is NOT in the live set is surfaced in `$res.skipped` with `reason: "no live cluster type matched at query time"` — record each as `production.<key>._validated = { skipped: true, reason: "no live cluster type", resolvedAt: <UTC ISO> }` and tell the owner: *"Skipping {N} production pipeline(s) in dry-run because no live cluster type: {list}. They remain in `pipeline-catalog.json` and will be dry-run automatically next time their cluster type appears in Kusto."*
  - If the resolver throws (Kusto failure, empty live set, missing `clusterTypeMap` entry), halt Phase 11.3 and surface the error verbatim — do NOT fall back to dry-running everything; that defeats the purpose of `cluster-type` mode.

- **Dry-runs** queue and cancel real production pipeline runs (one per resolved pipeline). The substituted region/stamp values come from `inventory.production.<cloud>` (Group 4c) — a **maximum-scope** preview, no CCOA filter and no exclusion list applied. If `inventory.production` is empty (owner skipped Group 4c), the dry-run still queues but with empty-string region/stamp values; surface a warning that the dry-run will only validate parameter *shape*, not values, and recommend running `setup-service group 4c` first.
- **Step 15 drift handshake** — the dry-run baseline persisted in `inventory.production.<cloud>` is the **same** baseline `Resolve-RegionScope.ps1` diffs against at real-release time. So a clean dry-run today means the next real release will only prompt for drift if ASC actually changed since this snapshot, not because dry-run and real-release have different scope-computation paths. (Contract details: see the runtime drift contract at the end of Group 4c.)
- Reinforce the consent banner: *"Each resolved production pipeline will receive a queued-then-cancelled run — same 5-second window. EV2 will NOT fire because cancellation happens before the agent picks up the work. A production pipeline that targets multiple clouds is still dry-run only once — cloud-fan-out happens at real-release time in Step 15, not here."*
- Validation loop is identical to Phase 11.2.
- Persist `production.<key>._learnedFrom`, `_validated`, etc.

If `productionRouting.mode == "cluster-type"`, the per-pipeline `clusterType` inference (Phase 11.1 step 3 bullet) runs again on production runs / YAML and populates `productionRouting.clusterTypeMap` the same way.

---

#### Phase 11.3a — Production cluster-type resolver invocation (config now lives in Phase 4e)

> **Phase 11.3a is a resolver invocation only.** The Kusto cluster / database / query file / filters used to discover which cluster types are currently live in production are collected up-front in **Phase 4e — Production Detection Kusto** (Group 4). This phase exists solely to invoke `Resolve-PipelinesByClusterType.ps1 -Scope production` between Phase 11.3 (production discovery) and Phase 11.3b / Phase 11.4 so the production dry-run / EV2 fan-out only operates on currently-live pipelines.

1. **Read `pipeline-catalog.json → productionRouting.mode`** (set during Phase 11.0). Branch:

   **If `mode == "static"`** — no resolution needed. The resolver returns every `production.*` key. Recap: *"Phase 11.3a: production routing is `static`, all production pipelines participate in the fan-out; each pipeline pushes to whichever clouds are listed under `ev2CloudCoverage.<key>`."* Exit.

   **If `mode == "cluster-type"`** — proceed.

2. **Verify Phase 4e config exists**. If `kusto.production.cluster`, `kusto.production.database`, and `kusto.production.queryFile` are not all set, halt with: *"Phase 4e — Production Detection Kusto has not been collected yet. Re-run `setup-service group 4e` first, then re-run `setup-service group 11.3a`."* Do NOT prompt for Kusto values here.

3. **Invoke the resolver**:
   ```powershell
   $resolved = & .\.github\skills\zed-agent\scripts\Resolve-PipelinesByClusterType.ps1 -Scope production
   ```
   On error, surface the Kusto error verbatim and let the owner edit `kusto.production.queryFile` (the agent re-reads it on every run) or re-run Phase 4e to fix the config.

4. **Recap** to the release owner: the set of resolved production pipeline keys, the set of cluster types observed, and the keys filtered out because no cluster-type match was found. These keys form the EV2 / dry-run universe for Phase 11.3b and Phase 11.4.

---

#### Phase 11.3b — SDS discovery + inventory generation (cloud-agnostic source of truth)

> **Phase 11.3b runs inside Group 11**, after Phase 11.3a and before Phase 11.4. It pins the Service Datacenter Settings (SDS) JSON file that each production pipeline reads at queue time — the same file EV2 uses to expand `{stamp}` macros. SDS is the cloud-agnostic source of truth for the stamp fleet (Phobos 2022 schema, https://aka.ms/phobosweb/schema/2022/sds). Two reasons we pin it here:
> 1. **Sovereign clouds** (Fairfax / Mooncake / USNat / USSec / Bleu / BVTD3 / EXP) live in AME-tenant Kusto this agent cannot reach. The SDS is the **only** stamp source for them.
> 2. **Public cloud reconciliation**. Kusto remains the primary stamp source for Public, but `Get-StampInventory.ps1` now cross-checks against SDS and halts Step 10 / Step 15 if the two disagree beyond `inventory.driftToleranceCount`.

The phase has three parts: **locate**, **confirm**, **detect-mapping**. All three persist incrementally to `service-config.json → sds.<pipelineKey>` and `service-config.json → sdsFieldMapping`.

1. **Locate the SDS file each production pipeline references.** For every key under `pipelines.production.*`, run the YAML introspector against the pipeline's primary YAML (see Phase 11.4a for the introspector itself; if 11.4a has not run yet, run it inline here — the two phases share the same script):
   ```powershell
   $intro = & .\.github\skills\zed-agent\scripts\Get-PipelineYamlIntrospection.ps1 -YamlPath <localYamlPath>
   ```
   Read `$intro.sdsHint.fileName` (e.g., `ServiceDatacenterSettingsConfig.json`, `ServiceDatacenterSettingsConfigActPass.json`) and `$intro.sdsHint.repoPath` (e.g., `src/ServiceFabric/Deployment`). Combine with `$intro.selfRepo.name` and `$intro.selfRepo.baseBranch` to form the candidate location.

   If the owner has a local clone (commonly under `Q:\<repo>` or `~/src/<repo>`), search for the file there first via:
   ```powershell
   Get-ChildItem -Path <candidateCloneRoot> -Recurse -Filter $intro.sdsHint.fileName -ErrorAction SilentlyContinue
   ```
   Otherwise fall back to ADO Git items API (same pattern as `Read-PipelineYaml.ps1`).

2. **Confirm with the owner.** Before persisting, ask once per pipeline key:
   > *"I located `<full path>` referenced by pipeline `<pipelineKey>` via `-SdsFiles <fileName>` in the YAML. Is this the SDS that contains all stamps for this service, or is it somewhere else?"*

   Accept `yes` (persist) or a corrected absolute path (re-validate then persist). The owner's confirmation is captured as `confirmedAt` (UTC ISO timestamp) and `confirmedBy` (their email). Persist:
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
   When several pipeline keys all point at the same SDS file (common — ServiceUpgrade.PROD and ClusterUpgrade.PROD often share one SDS), persist one entry per pipeline key with identical values; the gate compares hashes per `pipelineKey`, not per file.

3. **Detect the field-mapping shape and confirm overrides.** Phobos 2022 is the default; if the owner's SDS deviates (rare, but real for older services), use the script's `-Detect` mode to surface what each default path resolved to and what the first stamp's values look like:
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
   Recap to the owner: *"SDS pinned at `<path>`. Found `<N>` stamps across `<clouds>`. Hash: `<sha256[:12]>`. From this point on, `Get-StampInventory.ps1 -Scope production` will read this SDS — sovereign clouds source from it directly, Public cloud cross-checks against it."*

5. **Set drift tolerance once.** Ask: *"How many unmatched stamps between Kusto and SDS should the inventory gate tolerate before halting Step 10 / Step 15? `0` means any drift requires re-approval. Recommended: `0`."* Persist to `inventory.driftToleranceCount`. Default to `0` if the owner hits enter.

6. **Decide whether the production gate is mandatory.** Ask: *"Should Step 10 (Roll-Forward) and Step 15 (Production Rollout) refuse to fire until the owner explicitly approves each inventory snapshot? Recommended: `yes`."* Persist `true`/`false` to `inventory.production.approvalRequired`. When `false`, the gate auto-passes — use only for test services.

#### Phase 11.4 — EV2 metadata

For each pipeline key (canary + production), collect:

- **EV2 Service Groups** — `ev2ServiceGroups.<key>` = EV2 ServiceGroup name (e.g., `Microsoft.Azure.Backup.<Service>.<Component>.ACTIVE`)
- **EV2 Cloud Coverage** — `ev2CloudCoverage.<key>` = array of clouds (`Prod`, `Fairfax`, `Mooncake`, `USNat`, `USSec`)

> **Do NOT prompt for `ev2ServiceTreeIds.<cloud>` here.** Group 3 already collected one Service Tree ID and persisted the same GUID to `serviceTreeIds.ev2.Prod`, `.Fairfax`, and `.Mooncake`. Phase 11.4 reuses those values verbatim — only ask the owner for an EV2 Service Tree ID if a cloud appears in `ev2CloudCoverage.<key>` that has no entry under `serviceTreeIds.ev2.*` (e.g., the owner enables `USNat` / `USSec` here and Group 3 never set those). In that case ask once per missing cloud and persist to `serviceTreeIds.ev2.<cloud>`.

Tell the owner: *"This metadata isn't validatable by dry-run — it only matters at the EV2 monitoring stage of Step 15. If something's wrong here, it'll surface as a missing dashboard row, not a queue failure."*

#### Phase 11.4a — Pipeline YAML introspection (cloud convention + EV2 task discovery)

> **Phase 11.4a runs inside Group 11**, at the start of Phase 11.4. It reads each pipeline's primary YAML statically and writes structured findings to `pipeline-catalog.json → pipelines.<key>.yamlIntrospection`. The downstream EV2 metadata collection in Phase 11.4 uses these findings to pre-fill defaults so the owner only confirms rather than retypes.

The script is pure analysis — no network, no auth, no side effects. It returns:

- **`cloudConvention`** — `stageHardcoded` (one pipeline = one cloud, via `value: <Cloud>` under a `cloud` variable — e.g., DataMover) or `perCloudScriptFlags` (one pipeline → many clouds via `<Prefix>Script` boolean toggles — e.g., Prot) or `unknown`.
- **`cloudsDetected`** — list of cloud names the YAML actually targets. Cross-checked against `ev2CloudCoverage.<key>` in Phase 11.4: mismatch → prompt the owner to reconcile.
- **`stampParamShape`** + **`flatDefaults` / `perCloudDefaults`** — the declared `stamps` / `Excludestamps` / `Regions` / `ExcludeRegions` defaults, either flat (DataMover) or per-cloud-prefixed (Prot).
- **`ev2.{taskVersion, stageMapName, endpointProviderType, approvalServiceEnvironment, serviceRootPath, rolloutSpecPath, select, datacenterType}`** — the `vsrm-ev2.ev2-rollout.ev2-rollout-task.Ev2RARollout@N` task input block.
- **`sdsHint.{fileName, repoPath}`** — extracted from inline PowerShell `-SdsFiles <name>` argument plus the nearest `$hsp_source = "$(Pipeline.Workspace)/s/dep_specs/<path>"`. Consumed by Phase 11.3b.
- **`selfRepo.{name, baseBranch, alias}`** — the source-tree repo declared under `resources.repositories[]` (type git, name not under `OneBranch.Pipelines/`). Consumed by Phase 11.3b for the SDS path.

Procedure:

1. For each pipeline key (canary + production), locate its primary YAML. Prefer the local clone path declared in Phase 11.3b's `sds.<key>.localClonePath` joined with the pipeline's YAML path from ADO. Fall back to fetching via `Read-PipelineYaml.ps1` and writing to a temp file when no local clone is available.

2. Run the introspector:
   ```powershell
   $intro = & .\.github\skills\zed-agent\scripts\Get-PipelineYamlIntrospection.ps1 -YamlPath <localYamlPath>
   ```

3. **Persist verbatim** to `pipeline-catalog.json → pipelines.<key>.yamlIntrospection = $intro`. Do not edit or normalize — if the YAML changes, the next Phase 11.4a re-run picks up the new values.

4. **Cross-check cloud coverage.** Compare `$intro.cloudsDetected` against `ev2CloudCoverage.<key>` (collected in Phase 11.4 step 1). On mismatch, ask the owner one of two things, depending on which side is longer:
   - YAML targets clouds NOT in `ev2CloudCoverage` → *"The pipeline `<key>` YAML targets `<extra>` but `ev2CloudCoverage.<key>` does not list them. Add to coverage, or remove from YAML?"*
   - YAML omits clouds listed in `ev2CloudCoverage` → *"`ev2CloudCoverage.<key>` lists `<missing>` but the pipeline YAML does not target them. Trim coverage, or amend YAML?"*
   Record the owner's resolution as an `audit.jsonl` event `yaml-coverage-discrepancy` with the chosen direction. Do not auto-write either side — the owner edits the YAML or `ev2CloudCoverage.<key>` explicitly.

5. **Recap.** *"YAML introspection captured for `<N>` pipelines. Convention: `<convention>`. SDS hints written to `pipeline-catalog.json → pipelines.*.yamlIntrospection`. Re-run `setup-service group 11.4a` after any pipeline YAML edit to refresh."*

#### Phase 11.4 (continued) — EV2 metadata fields

---

#### Group 11 sub-identifiers (dispatcher shortcuts)

The dispatcher recognizes these sub-identifiers in addition to plain `11`:

| Identifier | Resumes at |
|------------|-----------|
| `11` | Phase 11.0 (full Group 11 from the top) |
| `11.canary` | Phase 11.1 for canary pipelines only (skip official build + production) |
| `11.1a` | Phase 11.1a only — canary cluster-type detection Kusto config; **executes between 11.1 and 11.2** (auto-skipped when `canaryRouting.mode == "static"`) |
| `11.prod` | Phase 11.3 (production discovery + dry-runs, including embedded Phase 11.3a) |
| `11.3a` | Phase 11.3a only — production cluster-type detection Kusto config; **executes inside 11.3, between production discovery and production dry-run** (auto-skipped when `productionRouting.mode == "static"`) |
| `11.3b` | Phase 11.3b only — SDS discovery + inventory generation; **executes inside 11.3, after 11.3a and before 11.4**. Idempotent — re-run any time after the pipeline YAML or SDS file moves. |
| `11.dryrun <pipelineKey>` | Re-run Phase 11.2 for a single pipeline (useful when YAML changed and the owner wants to re-validate) |
| `11.discovery-only` | Run 11.0 + 11.1 + 11.3 discovery without any dry-run queue (skip 11.2 entirely; record `_validated.skipped = true`) |
| `11.ev2` | Phase 11.4 only |
| `11.4a` | Phase 11.4a only — pipeline YAML introspection. Refreshes `pipeline-catalog.json → pipelines.*.yamlIntrospection`. Re-run after any pipeline YAML edit. |

Each sub-identifier follows the same incremental-persistence rule and emits matching `audit.jsonl` events: `pipeline-discovery`, `pipeline-dryrun`, `pipeline-discrepancy-fix`, `md-edit-proposal`.

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

2. **Finalize `pipeline-catalog.json`** — Re-read the file from disk. Pipeline entries collected during Group 11 were already persisted incrementally per pipeline. Confirm all pipeline entries the release owner provided are present and well-formed; do not overwrite existing entries.

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

If validation fails, list the missing/invalid fields and offer the release owner either to (a) fix them in their IDE and re-run `setup-service validate`, or (b) re-run `setup-service` to be prompted for just those fields, or (c) jump directly to the failing group with `setup-service group <N>` (e.g., `setup-service group 11` resumes at pipeline-catalog; `setup-service group 5b` resumes at notification routing).

### Readiness persistence

**At the end of every wizard pass and every `setup-service group <N>` jump and every `setup-service validate`**, persist the outcome to `.zed-agent/readiness.json → setupService`:

```powershell
& .\.github\skills\zed-agent\scripts\Write-Readiness.ps1 -Stage 'setupService' -Data @{
    status        = '<pass|incomplete|fail>'   # pass = full validation green; incomplete = owner exited mid-wizard or some required field still empty; fail = validation hit type errors / placeholder values
    lastGroup     = '<last group identifier successfully persisted, e.g., "11" or "5b">'
    missingFields = @('<dotted.path>', '...')   # empty array on pass
}
```

Incremental rule: also call `Write-Readiness -Stage setupService -Data @{ status = 'incomplete'; lastGroup = '<N>' }` after each group completes, so a chat interruption mid-wizard still produces a meaningful record. The `run` command's chain check will see `status = 'incomplete'` and tell the owner exactly where to resume.
