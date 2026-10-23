# ZedForge Requirements — the END STATE (detailed)

This file defines **what "done" looks like** for the ZED deployment agent, step by step and
sub-step by sub-step. It is the north star ZedForge drives ZED toward. It is *not* a task list
(that is `learnings/learnings.md`) — it is the **desired end state**: a ZED **true test run** that
completes cleanly with every triggered pipeline carrying **correctly-formatted** parameters that
match the **golden reference runs**.

The machine-checkable form is `requirements/success-criteria.json`, evaluated by
`scripts/Test-RunRequirements.ps1`. The golden reference parameters are cached in
`requirements/reference-runs.json` (refresh via `scripts/Get-ReferenceRun.ps1`). Keep all three in
sync.

---

## 0. Scope — ZED is service-agnostic; bdp3/MAB is only the current test target

ZED deploys **any** service. Every service-specific value (ADO org/project/repo, pipelines, Kusto,
SafeFly, regions, stamps) lives in the target repo's committed `service-config.json` +
`pipeline-catalog.json`. **bdp3 / Azure Backup (MAB/prot) is only the CURRENT validation target** —
ZedForge must keep ZED's logic and every ZED-side fix **generic**: no hard-coded service names,
pipeline ids, stamps, or regions in ZED scripts or `ZedAgent.agent.md`.

- The **generic contract** — step statuses, the trigger-and-cancel capture contract, the golden
  parameter **syntax** rules, no-unresolved-tokens, the SafeFly field shape — applies to **any** service.
- The **specific values** — the reference build ids, the `PROT-SFMC/SFRP` pipeline keys, the
  `isc-01`/`ne5s-01` forbidden stamps, the region lists — are **bdp3/MAB-specific**. They live in
  ZedForge's seed configs + `reference-runs.json`, **not** in ZED itself; a different service supplies
  its own via its two config files.

When implementing a learning, always prefer a **generic** fix (schema field, config-driven behavior)
over a service-specific hard-code in ZED.

## 1. Definition of a successful validation run

A validation run = one execution of the ZED **true test run** (`testMode: true`) in the target
repo. It succeeds when ALL of the following hold.

### Release-level
- `release.json → testMode == true`.
- Steps **3, 7, 8, 9, 11, 12, 14, 15, 16** are `skipped`.
- Steps **1, 2, 4, 5, 6, 10, 13** all reach `completed`.
- **No step is `failed`/`failed-drift`.**
- `.zed-agent/releases/<id>/test-run-capture.json` exists and is non-empty.
- The run is fully autonomous — **no human approval gate** blocked it.

---

## 2. Per-step / per-sub-step end state

### Step 1 — Send Branch Cut Reminder
- **1.1** Reminder rendered and sent to the release owner **only** (email); Teams suppressed (test mode).
- **1.2** Status → `completed`. Notification failure is non-blocking (log + continue).

### Step 2 — Cut Release Branch & Trigger-and-Cancel Build
- **2.1** Create the release branch `currentBranch` from `origin/<ado.baseBranch>` (develop). In a
  true test run this is the ephemeral branch `zedforge/test-<yyyyMMdd-HHmm>`.
- **2.2** Resolve `officialBuild.templateParameters` from the catalog (reserved tokens resolved).
- **2.3** Trigger the build for real via `Invoke-TriggerAndCancel.ps1 -Step 2`, then **cancel within
  ~5s**. A capture record is appended: `{ step:2, pipelineKey:"officialBuild", triggered:true,
  runId, postedParameters, cancelledAt, finalState }`.
- **2.4** Step 4 **Phase A** (commit collection) runs inline here (see Step 4).
- **2.5** `triggered == true`; `sourceBranch` resolved to the real release branch (no `{{token}}`);
  `postedParameters` contain `CloudBuildQueue` and match the officialBuild catalog entry
  (`CloudBuildQueue`, `debug`). Note: the official CloudBuild (def 282413) has **no `ArtifactsBranch`**
  parameter — the branch is the `sourceBranch`.
- **2.6** Step 2 → `completed`; Step 3 → `skipped` (`reason: "test-run: build cancelled at trigger"`).
- **2.7** No build watcher is armed.

### Step 3 — Wait for Build
- **3.1** `skipped` — the build was cancelled at trigger, so there is nothing to wait for.

### Step 4 — Collect & Analyze Commits (REAL)
- **4.1** `git fetch` + `git log --cherry-pick <prev>..<curr>` collects commits.
- **4.2** Each commit is classified: production-impacting vs not, and one of the 11 SafeFly nature
  tags (`[NewFeature]`, `[BugFix]`, …).
- **4.3** `commits.xlsx` is generated and uploaded to SharePoint; `release.json → commitExcelUrl`
  (or `state.step4ExcelUrl`) is set.
- **4.4** Mail goes to the **owner only**; the Teams commit-request post is **suppressed**.
- **4.5** Manual columns auto-filled; **no human wait** for the Impact column; Step 4 → `completed`.

### Step 5 — Deploy Canary → Trigger-and-Cancel
- **5.1** Resolve the canary trigger set. In `static` routing this is **every** `canary.*` entry.
- **5.2** For **each** resolved pipeline, resolve `templateParameters` then trigger-and-cancel via
  `Invoke-TriggerAndCancel.ps1 -Step 5 -PipelineKey "canary:<key>"`. One capture record per pipeline.
- **5.3** Each record: `triggered == true`; contains required keys
  `ArtifactsBranch, CanaryScript, Canarystamps, CanaryRegions, ValidateOnlyRollOut, rolloutType`;
  **no unresolved tokens**; matches its catalog entry; **passes the golden canary syntax** (§3).
- **5.4** The EV2 approval-link scan is skipped in test mode. Step 5 → `completed`.

### Step 6 — BVT Query-Works Check
- **6.1** **No** 24h bake `wait-timer`. Query Kusto with `ago(48h)` against `kusto.bvt.cluster/database`.
- **6.2** Purpose is to confirm the BVT query **executes** — a `bvt-query-check` record is written:
  `{ step:6, queryRan:true, rowCount, cluster, database }`.
- **6.3** **Auto-pass — no `approve-bvt`.** Query executes → Step 6 `completed`; query errors
  (auth / unreachable cluster / malformed KQL) → Step 6 `failed`.

### Steps 7-9 — Rollback cycle
- **7-9** all `skipped`.

### Step 10 — Roll-Forward (PROD pipelines) → Trigger-and-Cancel
- **10.1** Inventory gate must return `pass` or `skip`.
- **10.2** Resolve the production trigger set. In `static` routing this is **every** `production.*` entry.
- **10.3** For **each**, resolve `templateParameters` then trigger-and-cancel via
  `Invoke-TriggerAndCancel.ps1 -Step 10 -PipelineKey "production:<key>"`. One record per pipeline.
- **10.4** Each record: `triggered == true`; contains required keys
  `ArtifactsBranch, Publicstamps, PublicExcludestamps, PubRegions, SdpType, ValidateOnlyRollOut, rolloutType`;
  **no unresolved tokens**; matches its catalog entry; **passes the golden prod syntax** (§3).
- **10.5** `PublicExcludestamps` must **not** contain `isc-01` or `ne5s-01` (§4 caveat). Step 10 → `completed`.

### Steps 11-12 — Post-roll-forward
- **11-12** `skipped`.

### Step 13 — Create SafeFly R2D (REAL)
- **13.1** A real R2D is filed via `New-SafeFlyRequest.ps1`; `release.json → safeFlyId` /
  `safeFlyRequestNumber` is set.
- **13.2** The R2D fields' **shape** matches the golden reference R2D (§3.3): `deploymentNature`,
  `sdpType`, `targetedRegions` (display names), `blastRadius`, `rollback`, `impactType`,
  `sev2Alerting`, `payloadGoingToFairfax/Mooncake`, `preProdTesting`, `deploymentDetail.deploymentTool == "EV2"`.
- **13.3** Step 13 → `completed`. (Owner abandons the R2D afterwards.)

### Steps 14-16 — SafeFly/CRB wait, EV2 prod rollout, merge-back
- **14, 15, 16** all `skipped`.

---

## 3. Golden parameter reference (from the successful runs)

ZedForge keeps the runs below as the **reference** and compares a current run's parameter
**SYNTAX/FORMAT** against them — never the literal values (§4). Full parameter sets are cached in
`requirements/reference-runs.json`.

### 3.1 Reference runs
**PROD (Release-2604):**
| buildId | defId | pipeline |
|---------|-------|----------|
| 159822784 | 421108 | DTPROT-SF-Service-Upgrade-PROD-SDP-SFMC |
| 159830918 | 421104 | PROT-SF-Service-Upgrade-PROD-SDP-SFMC |
| 159830900 | 403182 | DTPROT-SF-Service-Upgrade-PROD-SDP |
| 159830909 | 403190 | PROT-SF-Service-Upgrade-PROD-SDP |

**CANARY (Release-2607):**
| buildId | defId | pipeline |
|---------|-------|----------|
| 171595767 | 421103 | PROT-SF-Service-Upgrade-Canary-SDP-SFMC |
| 171595703 | 403183 | PROT-SF-Service-Upgrade-Canary-SDP |
| 171595764 | 421110 | DT-SF-Service-Upgrade-Canary-SFMC |
| 171595704 | 395577 | DT-SF-Service-Upgrade-Canary |

**SafeFly R2D:** `74f085e4-9824-4f16-9dab-715c55ed9f98` (orgName `r2d`).

### 3.2 Golden syntax (how fields are filled) — enforced by `parameterSyntax` in success-criteria.json

| Parameter family | Golden syntax | Reference examples |
|------------------|---------------|--------------------|
| Stamp lists (`*stamps`, `*Excludestamps`) | PowerShell string-array `@("x-01","y-02")`, or `*` (all), or `@()` (none). Quoted short names, comma-separated, **no spaces, no `*` inside the array**. | `PublicExcludestamps=@("isc-01","ne5s-01")`; `Canarystamps=@("ea-01")`; `FFstamps=@("uga-01")`; `Publicstamps=*` |
| Region lists (`PubRegions`, `CanaryRegions`, `FFRegions`, …) | `regions(a,b,c)` — comma-separated short names inside `regions(...)`, no spaces. `regions()` = empty; `regions(*)` only for non-active clouds. | `CanaryRegions=regions(eastasia)`; `FFRegions=regions(usgovarizona)` |
| `PubRegions` specifically | **Explicit non-empty** `regions(...)` list — **never `regions(*)` or `*`**. | `PubRegions=regions(eastus2euap,centraluseuap,eastasia,…)` (≈26-43 regions) |
| `PubExcludeRegions` | single space `" "` when none | `PubExcludeRegions=" "` |
| `*Script` flags | `True`/`False` (case-insensitive) | `FFScript=True`, `CanaryScript=false` |
| `SdpType` | `Standard` or `Conservative` | `SdpType=Standard` |
| `ValidateOnlyRollOut` | `true`/`false`; **`false` for a real trigger** | `ValidateOnlyRollOut=False` |
| `rolloutType` | `normal` | `rolloutType=normal` |
| `ArtifactsBranch` | a real release branch (in a real release `releases/prot<YYMM>`; in a **true test run** the ephemeral `zedforge/test-…`). Never `*`, never empty, never a `{{token}}`. | `ArtifactsBranch=releases/prot2604` |
| `OverrideMacros` / `OverrideResourceParameters` / `CustomResourceTemplates` | PowerShell hashtable `@{"__Key__"="value";…}` | `@{"__ServiceGroup__"="DataTransformerDeployment";…}` |

### 3.3 Golden SafeFly R2D shape (from `New-SafeFlyRequest.ps1` + reference R2D)
- `deploymentDetail.deploymentTool = "EV2"`, `ServiceGroupName = "Backup (MAB)"`, `buildId`, `buildNumber`, `buildUrl`.
- `deploymentType.deploymentTypeName = "Regular"`.
- `deploymentNature` = array of the SafeFly nature values derived from the commit analysis.
- `sdpType` = "Standard SDP" / "Conservative SDP".
- `targetedRegions` = SafeFly **display names** (e.g. "East Asia", "Southeast Asia").
- `impactType = ["None"]`, `blastRadius = "Single Cluster"`.
- `rollback = "DRI determines rollback or rollforward in real time…"`, `rollbackRollforwardTesting = true`.
- `sev2Alerting = "Yes"`; `payloadGoingToFairfax = "yes"`, `payloadGoingToMooncake = "yes"`.
- `preProdTesting = [{ preProdTestingType:"End to End Testing", preProdTestingDetail:"<BVT Dashboard link>" }]`.
- `customerFacingChangeTitle` / `customerFacingChangeDescription` populated.

---

## 4. Caveats (compare SYNTAX, not literal values)

1. **`isc-01` / `ne5s-01` were dev-only exclusions — now being onboarded to SFMC.** They appear in the
   reference `PublicExcludestamps` ONLY because those stamps were in development. They are no longer
   in development. In the current run:
   - **Remove** `isc-01` / `ne5s-01` from the **SFMC** `PublicExcludestamps` (they should deploy via SFMC).
   - **Also add their regions** to the SFMC `PubRegions` — `isc-01`→`indiasouthcentral`, `ne5s-01`→`northeastus5`.
     EV2 gates on BOTH mechanisms: a stamp only deploys if its region is in `PubRegions` **and** it is
     not in `PublicExcludestamps`. Un-excluding without adding the region deploys nothing.
   - They may legitimately **remain excluded in the SFRP** pipeline type (the type they do NOT belong
     to). ⚠️ Owner: confirm the exact per-pipeline scoping — `forbiddenExcludeStamps` currently flags
     them in ANY `*Excludestamps`; narrow it to the SFMC entries if SFRP must keep excluding them.
2. **CCOA exclusions are time-dependent.** Build 159830918 excluded `we-01..we-14` because of an active
   CCOA that month. Do **not** expect the same CCOA stamps in the current run — only the `@("…")` syntax.
3. **Region sets change every release.** The exact regions inside `regions(...)` differ per release
   (new regions onboarded, CCOA holds). Enforce the `regions(...)` **shape** and the "no `*` in
   PubRegions" rule — not the literal region list.
4. **ArtifactsBranch differs in a test run** (`zedforge/test-…`, not `releases/prot<YYMM>`). Only require
   a real, resolved, non-`*` branch — not the `releases/` prefix.
5. **Production parameters are per-pipeline-type, not global.** SFRP vs SFMC (and PROT vs DT) have
   DIFFERENT `PubRegions`, `PublicExcludestamps`, sovereign-cloud flags (`MCScript`, `FFScript`,
   `FFstamps`, `BleuScript`, `UsNatScript`, `UsSecScript`) and ServiceGroup overrides. Compare a
   current pipeline's params against the reference run **of the same pipeline type** — never copy one
   type's params to another. (Golden: SFMC prod = 421104/421108; SFRP prod = 403190/403182.)

---

## 5. Comparison methodology (Phase 6)

1. `Test-RunRequirements.ps1` enforces the **structural + syntax** contract automatically:
   per-step status, required keys, no unresolved tokens, catalog match, the `parameterSyntax` rules,
   and the forbidden `isc-01`/`ne5s-01` exclusions.
2. For a **deeper** parameter comparison, ZedForge pulls the golden run for the same scope with
   `Get-ReferenceRun.ps1 -Scope canary|prod` (or a specific `-BuildId`) and compares the current
   captured params against the reference **field-by-field for shape** — same keys present, same
   value FORM (array/regions/flag), allowing value differences per §4.
3. For **SafeFly** (Step 13), fetch the reference R2D via `referenceRuns.safefly.detailsEndpoint`
   and compare the §3.3 fields' shape against the current run's R2D.

---

## 6. Definition of "done" for the whole loop
ZedForge stops (status `done`) when: (a) a validation run's verifier verdict = `pass`, AND (b) no
`pending` learnings remain, AND (c) that clean run harvested nothing new. Otherwise it harvests the
failures as new learnings and loops.

## 7. Guardrails
- The true test run must **never deploy** — every pipeline is cancelled within seconds.
- The run must be **fully autonomous** — no human approval gate may block it.
- ZedForge must **never commit** — all edits stay unstaged for owner review.
- **Never weaken a requirement** to make a run pass; fix ZED instead.
