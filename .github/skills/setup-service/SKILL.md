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
    - `setup-service group <N>`     where N in {1, 2, 3, 4a, 4b, 5a, 5b, 6, 7, 8, 9, 10, 11}
                                    (jump directly to a group)

  Also use this skill from inside the `setup` command when Test-PreFlight reports
  empty service-config or pipeline-catalog fields and Behavior Rule 13 says to
  "resume the matching setup-service group <N>".
allowed-tools: shell
---

You are the ZED Agent setup-service wizard. The release owner has just typed `setup-service`, `setup-service validate`, or `setup-service group <N>`. Follow the procedure below.

> **This command is run ONCE per repo** to generate the service configuration files. After generation, the files should be committed to the repo. For subsequent releases, use `setup` instead.

### Phase 0 — Pre-flight gate (always runs first)

Before any prompts, **always invoke `test-preflight`** so the environment (auth, tooling, ADO/Kusto connectivity, MCP wiring, Teams CDP, required modules) is known-good. The wizard depends on every one of these — there is no point collecting answers if `az` is broken or `pipeline-catalog.json` is unreachable.

1. Invoke the `/test-preflight` skill (the canonical entry point for pre-flight). It runs `Test-PreFlight.ps1`, attempts auto-remediation, writes `.zed-agent/readiness.json → preflight`, and reports the verdict.
2. Read the freshly-written `.zed-agent/readiness.json → preflight` to learn the verdict.
3. Branch on the verdict:
   - **`pass`** → continue to the Interactive Collection Flow below.
   - **`warn`** → show the warning list, then ask via `ask_user`:
     > *"Pre-flight passed with {n} warning(s). These usually do not block setup-service but may degrade some checks. Continue?"*
     > Choices: `Continue`, `Stop — let me fix first`
     On `Continue`, write `readiness.preflight.overridden = true` (via `Write-Readiness.ps1`) and proceed. On `Stop`, halt.
   - **`fail`** → show the failure list and halt: *"Pre-flight has unresolved failures. Fix them (or re-run `test-preflight fix`) before re-running `setup-service`."* Do NOT offer an override path for hard failures — the wizard cannot do its job with a broken environment.
4. Skip Phase 0 only when the dispatcher receives `setup-service validate` (validation is read-only and runs even on a broken environment).

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
| `4b` | Phase 4b — Canary Detection Kusto (schema-aware) — **executes AFTER Group 11** because it depends on `canaryRouting.mode` set there |
| `5a` | Group 5 — Notification Groups (DLs + Teams chats) |
| `5b` | Group 5b — Notification Routing (4 default broadcasts + owner-added per-step / status entries) |
| `6` | Group 6 — Operational defaults |
| `7` | Group 7 — SafeFly defaults |
| `8` | Group 8 — Step Gates |
| `9` | Group 9 — CommitExcel + SharePoint |
| `10` | Group 10 — Test mode |
| `11` | Pipeline Catalog (Group 11 — pipeline-catalog.json entries) |

> **Group 11 sub-identifiers**: `11.canary`, `11.prod`, `11.dryrun <pipelineKey>`, `11.discovery-only`, `11.ev2` — see the Group 11 section for behavior. Treat them as valid identifiers in step 2 of the dispatcher (do not reject as unknown).

Dispatcher behavior:
1. Parse the trailing token after `setup-service group `.
2. If the identifier is not in the table above, list valid choices and abort.
3. Otherwise, **load the existing `service-config.json` and `pipeline-catalog.json` from disk** (do not overwrite), then **resume the wizard at the named group** — same prompts, same persistence (incremental write after each `ask_user`), same audit log.
4. Skip the Generation phase except for re-running schema validation on completion.
5. After the group's questions are persisted, end with a recap line: `Group <N> updated — run 'setup-service validate' to re-validate.`

**Group 1 — Service Identity**
Ask for:
- `service.name` — Short canonical name (e.g., "Prot", "DPM", "MABS"). Used in file names, tags, and filters.
- `service.displayName` — Human-readable name (e.g., "Protection Service", "Data Protection Manager")

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

Collect the connection + query settings in **Phase 4a (BVT)** here. The canary/production stamp-discovery Kusto config (**Phase 4b**) is collected **after Group 11** because it depends on `canaryRouting.mode` (set during pipeline catalog collection). If `canaryRouting.mode = "static"` or `"explicit"`, Phase 4b is skipped entirely — no Kusto query is needed.

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

> **Note**: Phase 4b runs **after Group 11** because its prompts depend on `canaryRouting.mode` from `pipeline-catalog.json`. Skip ahead to **Group 5a** next.

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
- `{{excludeStamps}}`, `{{pubRegions}}`, `{{ffStamps}}`, `{{ffRegions}}` — replaced with CCOA / SafeFly region scope at production trigger time
- `{{sdpType}}`, `{{validateOnly}}` — replaced based on rollout mode

When the agent shows owner-facing diffs, render these as **highlighted tokens with a one-line tooltip** explaining the runtime substitution.

#### Auth & cost

Every ADO REST call in Group 11 uses the same `az login` identity that runs `setup` / `setup-service`. The token is acquired on the fly with `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798` (the fixed Azure DevOps resource GUID — same pattern used by `Get-RegionMapping.ps1` and `Get-Ev2RolloutStatus.ps1`). No PAT, no separate sign-in. If a call returns 401, run `Repair-AzAuth.ps1 -Tenant 'microsoft.com'` and retry once; on 403, halt the wizard with the explicit message *"Your account lacks Pipelines (write) on `{org}/{project}`. Ask your project admin to grant `Build Service (queue/cancel)` permission, then re-run `setup-service group 11`."*

Dry-runs in Phase 11.2 / 11.3 do create real ADO runs that the owner will see in pipeline history. The agent cancels each within **5 seconds** of queueing (well before any agent picks the work up), so no actual deployment happens, but the run row remains visible. Tell the owner this up front (see Phase 11.0 intro).

---

#### Phase 11.0 — Cluster specificity, pipeline count, and routing mode

Ask via `ask_user`, **in this order**, persisting after each answer:

1. **Cluster specificity** (asked once, applies to canary and production):

   > *"How are your service's deployment pipelines structured?*
   > *  (a) **By region / stamp only** — every canary pipeline serves the same cluster type; the agent triggers all of them every release.*
   > *  (b) **By cluster type** — each region hosts multiple cluster-type variants (e.g., SFMC + SFRP) served by separate pipelines; the agent queries Kusto at runtime to pick which pipeline(s) to trigger per release."*

   - On `(a)`: persist `canaryRouting.mode = "static"` and `productionRouting.mode = "static"`.
   - On `(b)`: persist `canaryRouting.mode = "cluster-type"` and **immediately ask production separately** (production topology can be asymmetric):
     > *"And your production pipelines — same split (by cluster type), or static (by region only)?"*
     Persist `productionRouting.mode` accordingly. If either mode is `cluster-type`, persist an empty `clusterTypeMap: {}` placeholder under that block — the map is filled in Phase 11.1 once pipeline keys are known.

2. **Official Build** — pipeline name + ID. Then run **Phase 11.1 discovery** against the official build pipeline (single instance, not a fan-out). The same prior-run + YAML logic applies — see below.

3. **Canary pipeline count**:
   > *"How many canary pipelines does your service have? (Just the count — I'll learn each one's parameters from ADO in a moment.)"*

   For each, collect only **key, name, id** up front:
   - **key** — service-defined identifier the agent uses internally (e.g., `SVC-SFMC`, `DM-EACAN`)
   - **name** — display name as it appears in ADO
   - **id** — the integer ID from the pipeline URL (`definitionId=XXXXXX`)

   Do **not** ask for `templateParameters` here — Phase 11.1 derives them.

4. **Production pipeline count + key/name/id** — same pattern.

5. **Dry-run consent banner** — show once, before entering Phase 11.2:
   > *"For each pipeline I'm about to discover, I'll queue a real ADO run with the parameters I learned, then cancel it within 5 seconds — well before any agent picks it up. You'll see a cancelled run in ADO history; nothing actually deploys. This validates that the parameters I learned are correct and that I have the right ADO permissions. OK to proceed?"*

   On `No`, halt and tell the owner they can re-run with `setup-service group 11.discovery-only` to skip the queue-and-cancel validation (less safe — parameter mistakes won't surface until the first real release).

---

#### Phase 11.1 — Per-pipeline discovery (evidence-driven)

For each canary pipeline collected in Phase 11.0 (and the official build, and later each production pipeline), **fan out in parallel** using `ForEach-Object -Parallel`:

1. **Read the last 3 successful production runs** of the pipeline:
   ```powershell
   $runs = & .github/skills/zed-agent/scripts/Read-PriorRun.ps1 `
       -Organization $cfg.ado.organization `
       -Project $cfg.ado.project `
       -PipelineId $entry.id `
       -ResultFilter "succeeded" `
       -Top 3
   ```
   The script returns normalized objects: `{ runId, runUrl, finishedAt, sourceBranch, templateParameters }`. If fewer than 3 runs exist (new pipeline), return whatever's available; if zero, tell the owner *"No prior successful runs found for `{key}` — I'll rely on YAML only and lean more heavily on your review."*

2. **Fetch the pipeline YAML** from its source repo's base branch:
   ```powershell
   $yamlInfo = & .github/skills/zed-agent/scripts/Read-PipelineYaml.ps1 `
       -Organization $cfg.ado.organization `
       -Project $cfg.ado.project `
       -PipelineId $entry.id
   ```
   The script:
   - Calls `GET /_apis/pipelines/{id}?api-version=7.1` to discover `configuration.repository` and `configuration.path`.
   - If the YAML lives in a **different repo** than the wizard is running in, prompt the owner via `ask_user`:
     > *"Pipeline `{key}` (`{name}`) reads its YAML from `{repoName}` (not the current repo). What's the base branch I should pull from? (`develop`, `main`, etc.)"*

     Persist the answer to `yamlRepos.{repoName}.baseBranch` — **once per repo**. If the same repo comes up again later, reuse the persisted value without re-prompting.
   - Fetches the YAML content from that base branch.
   - Recursively follows every `extends:` template reference (cross-repo allowed). For each new repo encountered in an `extends:` chain, prompt for its base branch the same way and persist to `yamlRepos`.
   - Returns the merged `parameters:` block as a normalized list with `name`, `type`, `default`, `values` (for enum-typed params), plus `_resolvedFrom` provenance: `{ repo, branch, path, sha }` per parameter.

3. **Agent deep analysis** — synthesize a single proposed `templateParameters` map from (1) + (2):
   - **Baseline**: union of all parameters declared in the YAML.
   - **Concrete values**: prior-run values **per parameter**, mode-of-values across the 3 runs (most common wins). If the 3 runs disagree, flag the parameter as `mode-disagreement` in `agentGaps`.
   - **Reserved-token preservation**: if a prior-run value matches one of the reserved `{{...}}` tokens **or** the YAML's `default` is a reserved token, keep it as the token (do not substitute the literal from history).
   - **Cluster-type tag**: if the routing mode is `cluster-type`, scan the YAML and prior runs for stamp-list / region-list parameters whose values cluster around a single suffix (e.g., all entries end in `-sfmc`). If a clear cluster type emerges, propose it as `entry.clusterType`. Otherwise leave blank and ask the owner.
   - **Unknown / new params**: parameters in YAML that have no prior-run value and no `default` → mark `requiresOwnerInput: true` in the proposal.

4. **Render the proposal** to the owner in a single review block:

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
   │ Inferred clusterType: "sfmc" (from PubCanaryStamps suffix)       │
   │                                                                  │
   │ Gaps the agent could not resolve:                                │
   │   • RolloutNotes — declared in YAML, no prior value, no default  │
   └──────────────────────────────────────────────────────────────────┘
   Choices: Accept, Edit a value, Reject, Show diff vs YAML defaults
   ```

   Loop on the choice until owner picks `Accept` or `Reject`. On `Edit a value` ask which key, collect new value via `ask_user`, re-render. On `Reject`, drop to the legacy paste-YAML / paste-JSON / manual flow as a fallback.

5. **Persist** the accepted proposal:
   - `canary.<key>.templateParameters` = accepted map (with reserved tokens preserved as strings).
   - `canary.<key>._learnedFrom` = `{ runIds: [...], yamlPath, yamlRepo, yamlBranch, yamlSha, learnedAt: <UTC ISO> }`
   - `canary.<key>.discoveryNotes` = `{ exclusionFormat: <auto-detected — comma|semicolon|json-array>, stampNameStyle: <auto-detected>, freeText: "" }`
   - `canary.<key>.agentGaps` = list of unresolved-gap descriptions (empty array on full success).
   - If routing mode is `cluster-type` and a `clusterType` was inferred, persist `canary.<key>.clusterType` and also update `canaryRouting.clusterTypeMap[<clusterType>]` to include this pipeline key (use array form if the suffix already maps to another key).

   Underscore-prefixed fields (`_learnedFrom`) are stripped by the schema-driven empty-skeleton generator but accepted by the validator — they're metadata, not config.

---

#### Phase 11.2 — Dry-run validation (parallel)

Once every canary pipeline has an accepted proposal on disk, fan out a dry-run for **all canary pipelines in parallel** using `ForEach-Object -Parallel`:

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

1. Resolve the entry from `pipeline-catalog.json`. Substitute reserved tokens with the **wizard-time stub values** (e.g., `{{currentBranch}}` → `refs/heads/setup-service-dry-run`, `{{validateOnly}}` → `"true"`). The substitution table is part of the script so it's auditable.
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

#### Phase 11.3 — Production pipelines (same shape)

Repeat Phase 11.1 + Phase 11.2 for production pipelines:

- Discovery reads the last 3 successful **production** runs (not canary). Production parameters typically include `BranchPrefix`, `SdpType`, `Pub*Stamps`, etc. — treat these as service-specific, **not** required.
- Dry-runs queue and cancel real production pipeline runs. Reinforce the consent banner: *"Production pipelines will receive a queued-then-cancelled run each — same 5-second window. EV2 will NOT fire because cancellation happens before the agent picks up the work."*
- Validation loop is identical.
- Persist `production.<key>._learnedFrom`, `_validated`, etc.

If `productionRouting.mode == "cluster-type"`, the per-pipeline `clusterType` inference (Phase 11.1 step 3 bullet) runs again on production runs / YAML and populates `productionRouting.clusterTypeMap` the same way.

---

#### Phase 11.4 — EV2 metadata (unchanged)

For each pipeline key (canary + production), collect:

- **EV2 Service Groups** — `ev2ServiceGroups.<key>` = EV2 ServiceGroup name (e.g., `Microsoft.Azure.Backup.<Service>.<Component>.ACTIVE`)
- **EV2 Cloud Coverage** — `ev2CloudCoverage.<key>` = array of clouds (`Prod`, `Fairfax`, `Mooncake`, `USNat`, `USSec`)
- **EV2 Service Tree IDs** — `ev2ServiceTreeIds.<cloud>` = GUID (asked once per cloud, reused across pipelines)

Tell the owner: *"This metadata isn't validatable by dry-run — it only matters at the EV2 monitoring stage of Step 15. If something's wrong here, it'll surface as a missing dashboard row, not a queue failure."*

---

#### Group 11 sub-identifiers (dispatcher shortcuts)

The dispatcher recognizes these sub-identifiers in addition to plain `11`:

| Identifier | Resumes at |
|------------|-----------|
| `11` | Phase 11.0 (full Group 11 from the top) |
| `11.canary` | Phase 11.1 for canary pipelines only (skip official build + production) |
| `11.prod` | Phase 11.3 (production discovery + dry-runs) |
| `11.dryrun <pipelineKey>` | Re-run Phase 11.2 for a single pipeline (useful when YAML changed and the owner wants to re-validate) |
| `11.discovery-only` | Run 11.0 + 11.1 + 11.3 discovery without any dry-run queue (skip 11.2 entirely; record `_validated.skipped = true`) |
| `11.ev2` | Phase 11.4 only |

Each sub-identifier follows the same incremental-persistence rule and emits matching `audit.jsonl` events: `pipeline-discovery`, `pipeline-dryrun`, `pipeline-discrepancy-fix`, `md-edit-proposal`.

---

**Phase 4b — Canary Detection Kusto (schema-aware)**

The agent uses this cluster for **pipeline selection only** — to discover which cluster types (e.g., `sfmc`, `sfrp`) are currently in canary deployment. It does NOT classify individual stamp short names — once cluster-type-to-pipeline resolution is done, each selected pipeline's `templateParameters` (including stamp lists) are passed to ADO verbatim.

> **Phase 4b runs after Group 11** because the questions below only make sense once `canaryRouting.mode` is known. Group 11 already collected it — Phase 4b just reads it and short-circuits when no Kusto is needed.

0. **Read `pipeline-catalog.json → canaryRouting.mode`** (set during Group 11). Branch:

   **If `mode == "static"`** — Phase 4b is not needed. Clear `service-config.json → kusto.canary.*` (cluster, database, queryFile, serviceFilter, stampPrefixFilter, clusterTypeExtraction) and record `kusto.canary.scopingNotes = "canaryRouting.mode is 'static' — no canary-detection Kusto query is used"`. Recap to the owner: *"Phase 4b skipped — canary routing is `static`. Steps 5/7/10 will trigger every entry under `canary.*` / `production.*` in parallel."* Exit Phase 4b.

   **If `mode == "explicit"`** (or the `_pendingExplicitList` schema-fallback equivalent) — Phase 4b is not needed. Clear `kusto.canary.*` as above and record `kusto.canary.scopingNotes = "canaryRouting.mode is 'explicit' — pipeline selection uses the static canaryStamps/canaryRegions list, no Kusto query"`. Show the brittleness reminder one more time:
   > ⚠️ **Brittleness reminder**: the agent will trigger canary pipelines based on the static `canaryStamps` / `canaryRegions` list you declared in Group 11. Keep that list fresh when the org rebalances. To switch to dynamic Kusto-driven routing later, re-run `setup-service group 11` and change `canaryRouting.mode` to `cluster-type`, then re-run `setup-service group 4b` to collect the Kusto details.

   Exit Phase 4b.

   **If `mode == "cluster-type"`** — proceed with steps 1-5 below to collect the Kusto details.

   **If `mode` is missing or unrecognized** — surface this as a configuration error: tell the owner to run `setup-service group 11` first to set `canaryRouting.mode`, then re-run `setup-service group 4b`. Do not prompt for any Kusto values yet.

1. **Show the default canary-detection query** — print verbatim in a fenced code block:
   ```kql
   EventLogAllClusters
   | where TIMESTAMP > ago(1d)
   | where {{SERVICE_FILTER}} and DeploymentName !contains 'r-pod01'
   | where {{STAMP_PREFIX_FILTER}}
   | summarize make_set(DeploymentUnit) by StampName
   | order by StampName asc
   ```
2. **Show the required column contract** the agent depends on:
   ```
   Required columns in result rows:
     StampName, DeploymentUnit (a set/array of deployment unit names)
   Required placeholders in the query:
     {{SERVICE_FILTER}}        (replaced with kusto.canary.serviceFilter at runtime,
                                e.g., ServiceName == 'prot')
     {{STAMP_PREFIX_FILTER}}   (replaced with kusto.canary.stampPrefixFilter at runtime,
                                e.g., StampName startswith '<your-prefix-1>' or
                                      StampName startswith '<your-prefix-2>')
   Tables referenced by default query:
     EventLogAllClusters
   Downstream usage (Steps 5, 7, 10):
     The agent collects the SET of cluster types observed across all rows
     (by inspecting DeploymentUnit substrings — e.g., '-sfmc' → 'sfmc',
     '-sf' without '-sfmc' → 'sfrp'). This set is intersected with
     canaryRouting.clusterTypeMap to pick which pipelines to trigger.
     The agent does NOT translate or filter stamp short names —
     each selected pipeline's templateParameters are passed to ADO
     verbatim from pipeline-catalog.json.
   Response parsing:
     ALWAYS use $resp.Tables[0].Rows. NEVER use $resp.tables | Where TableName -eq 'PrimaryResult'
     (see Kusto MCP Response Parsing in BVT Failure Analysis section).
   ```
3. **Ask the schema-fit question** via `ask_user`:
   > *"The default query above is valid for services in **Azure Backup**. Does your service fall under Azure Backup?"*
   > Choices: `Yes — Use default query`, `No — Use a different query`
4. **Branch on the answer**:

   **(A) `Yes — Use default query`** (default path):
   - Persist the default canary-detection query path to `kusto.canary.queryFile` (e.g., `Canary-DeploymentUnits.kql`). If the file doesn't exist in `.github/skills/zed-agent/queries/`, copy the canonical version above into it now. **Do NOT prompt for the filename** — use the default.
   - **Do NOT prompt for `kusto.canary.cluster` or `kusto.canary.database`** — the default query targets a fixed Azure Backup cluster/database. Write these values directly:
     - `kusto.canary.cluster` → `https://mabprod1.kusto.windows.net/`
     - `kusto.canary.database` → `MABKustoProd1`
   - Ask only the **2 filter fields** (one at a time, persist after each):
     - `kusto.canary.serviceFilter` — KQL `where` predicate that selects rows belonging to your service (e.g., `ServiceName == 'prot'`). Substituted into `{{SERVICE_FILTER}}` at runtime.
     - `kusto.canary.stampPrefixFilter` — KQL `where` predicate that narrows `StampName` to your service's canary stamps. Substituted into `{{STAMP_PREFIX_FILTER}}` at runtime.

       **Canary stamp filter shape (service-agnostic guidance):** This value is a KQL `where`-clause fragment over the `StampName` column. The general shape is `StampName startswith '<prefix1>' or StampName startswith '<prefix2>' …`. Replace `<prefix...>` with the short-name prefixes your service uses for canary stamps. Leave empty if your custom `.kql` file does not use the `{{STAMP_PREFIX_FILTER}}` placeholder.

       **Conditional default offer:** If `service.name` matches a known MAB-family service (case-insensitive regex `^(WBCM|DM|Prot)$`), offer the MAB-historical predicate `StampName startswith 'ea-can' or StampName startswith 'ecy' or StampName startswith 'ccy'` as a suggested default via `ask_user` — but make clear this is a snapshot and the owner is free to edit. For all other services, present `ask_user` with **no pre-filled value** and the shape guidance above; do not bake one service's stamp prefixes into another service's setup.
   - Note to release owner: *"If results look wrong later, you can edit `.github/skills/zed-agent/queries/{queryFile}` directly — the agent re-reads it on every run."*

   **(B) `No — Use a different query`**:
   - First, show the release owner the available canary-detection mechanisms supported by this agent today:
     > *"The agent currently supports the following mechanisms for canary cluster-type detection:*
     > *  (1) **Custom Kusto query** — you provide a KQL query the agent runs against your team's Kusto cluster; the agent inspects the returned rows to determine which cluster types are currently live in canary, then maps those to the right pipeline(s) via `canaryRouting.clusterTypeMap` (Group 11).*
     >
     > *More mechanisms may be added later."*
     > Choices: `1) Custom Kusto query`
   - On `Custom Kusto query`, walk the owner through a guided setup so the resulting query is solid and re-runnable by the agent. Persist each answer immediately:
     1. Ask `kusto.canary.cluster` — Kusto cluster URL where the canary deployment data lives.
     2. Ask `kusto.canary.database` — database name on that cluster.
     3. Ask the owner how they want to provide the KQL, via `ask_user`:
        > *"How do you want to provide your team's canary-detection query?"*
        > Choices: `Paste KQL now`, `Point me at a .kql file in this repo`
     4. **If `Paste KQL now`**: collect the KQL via `ask_user` (multi-line), write it to `.github/skills/zed-agent/queries/<service-name>-canary.kql`, and persist that path to `kusto.canary.queryFile`.
     5. **If `Point me at a .kql file in this repo`**: ask for the relative path, validate the file exists, and persist it to `kusto.canary.queryFile`.
     6. **Make the query agent-runnable** — the agent must analyze the submitted KQL and intelligently fill in / negotiate the runtime parameters it needs:
        - **Timestamp window**: scan the query for any of `ago(...)`, `datetime(...)`, `between(...)`, `now()`, or a `TIMESTAMP >=` / `TimeStamp >=` predicate. The canary-detection step needs a recent window (typically the last 1-2 days, not anchored to pipeline trigger time — canary detection is a *snapshot of what's live now*). If no time window is present, offer to inject `| where TIMESTAMP > ago(1d)` and confirm the exact column name to filter on via `ask_user`.
        - **Service scoping (or whatever mechanism the query uses)**: don't assume every custom query scopes to the service with a `ServiceName == "<svc>"` predicate — some teams use a different column, a build-id join, a namespace prefix on `DeploymentName`, a pre-filtered function in their own database, or no per-service filter at all because the cluster only holds their data. Ask the owner via `ask_user` how their query already narrows results to their service's canary stamps, with choices roughly: `Uses a {{SERVICE_FILTER}}-style column filter`, `Uses a different mechanism — let me describe it`, `No scoping needed — query is already service-specific`. Then:
           - On `Uses a {{SERVICE_FILTER}}-style column filter`: ask for the predicate (e.g., `ServiceName == 'prot'`), offer to inject `{{SERVICE_FILTER}}`, and collect `kusto.canary.serviceFilter`.
           - On `Uses a different mechanism`: collect a free-text description via `ask_user` (persist to `kusto.canary.scopingNotes` as a comment for future maintainers), then ask which placeholders — if any — the agent needs to substitute at runtime and what values to bind. Persist each placeholder under `kusto.canary.queryVariables.<NAME>`. If the mechanism needs nothing dynamic, just record the note and move on — do NOT force a `{{SERVICE_FILTER}}` placeholder.
           - On `No scoping needed`: leave `kusto.canary.serviceFilter` empty and record `kusto.canary.scopingNotes = "Query is pre-scoped — no runtime service filter needed"`.
        - **Stamp-prefix scoping (optional)**: ask whether the query needs runtime narrowing to canary stamp short-name prefixes via `ask_user`, with choices: `Uses a {{STAMP_PREFIX_FILTER}}-style predicate`, `No — stamps are hard-coded or not filtered`. On the first choice, collect `kusto.canary.stampPrefixFilter` using the same shape guidance and conditional MAB-family default offer described in branch (A) above; otherwise leave it empty.
        - **Cluster-type extraction contract**: confirm with the owner how the agent should read cluster types from the result rows. Ask via `ask_user`:
          > *"How does your query expose the cluster type of each canary stamp?"*
          > Choices: `Set/array column named DeploymentUnit (parse substrings like -sfmc, -sf)`, `Dedicated column (e.g., ClusterType) — I'll tell you the name`, `Other — let me describe it`
          - On `Set/array column named DeploymentUnit`: persist `kusto.canary.clusterTypeExtraction = { mode: "deployment-unit-substring" }`.
          - On `Dedicated column`: ask for the column name, persist `kusto.canary.clusterTypeExtraction = { mode: "column", column: "<name>" }`.
          - On `Other`: collect a free-text description, persist to `kusto.canary.clusterTypeExtraction = { mode: "custom", notes: "<description>" }`, and warn the owner that Steps 5/7/10 may need code changes to honor this mode (file a follow-up).
        - **Required columns**: ask the owner to confirm the query returns at minimum a row-per-stamp shape with a `StampName` column (or equivalent) plus whatever column the cluster-type extraction step reads. Persist the column list to `kusto.canary.resultColumns`.
        - **Additional placeholders**: if the owner referenced any other `{{...}}` tokens, prompt for each one and persist under `kusto.canary.queryVariables.<NAME>`.
     7. **Dry-run check (optional but recommended)**: offer to execute the finalized query once via the Kusto MCP against the cluster/database the owner just provided. Surface the returned rows in a small table and confirm with the owner that the cluster-type extraction step would produce the expected SET of cluster types. On error, surface the Kusto error verbatim and let the owner edit the file and re-run the dry-run.
     8. **Show this hard reminder** before finishing:
        > ⚠️ **Contract**: Steps 5, 7, and 10 will run this query verbatim against the cluster/database you just provided, substituting any placeholders you declared. The agent will then extract the SET of cluster types using `kusto.canary.clusterTypeExtraction` and intersect it with `canaryRouting.clusterTypeMap` (Group 11) to decide which canary pipeline(s) to trigger. Make sure the suffix/key vocabulary lines up between this query's output and `clusterTypeMap`. Edit `.github/skills/zed-agent/queries/{queryFile}` any time — the agent re-reads it on every run; no agent code change needed.

5. After persistence, recap to the release owner what was saved (cluster, database, query file path, service filter value).

> If the release owner uses the **same** Kusto cluster/database for both BVT and canary detection, the agent can still keep them as separate config keys — that's fine, just enter the same values.

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
