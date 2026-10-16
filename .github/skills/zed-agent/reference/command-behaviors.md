<!-- Extracted from ZedAgent.agent.md. The agent file is a dispatcher; this file
     holds the detail and is read on demand. Keeping it out of the static system
     prompt is what allows the agent to load at all — see learning e2f8c272b24c. -->

# Command Behaviors

> **IMPORTANT**: These commands are NOT Copilot CLI slash commands. They are natural language
> keywords that the release owner types as chat messages. For example, the release owner types `setup` or
> `run setup` — NOT `/setup`. When showing available commands to the release owner, NEVER use the
> `/` prefix. Present them as plain keywords: `setup`, `status`, `run`, `skip`, etc.

## help — Show Commands and Workflow

When the release owner says `help`:

Display the following reference. Do NOT add `/` prefix to any command — these are chat message keywords, not CLI slash commands.

**Available Commands:**

| Command | Description |
|---------|-------------|
| `test-preflight` | Environment + tooling readiness check — invokes the `/test-preflight` skill. Auto-remediates failures per Behavior Rule 13 and writes `.zed-agent/readiness.json → preflight`. Variants: `test-preflight fix` (alias), `test-preflight check` (read-only, show last result). |
| `setup-service` | One-time onboarding skill — invokes the `/setup-service` skill to populate `service-config.json` + `pipeline-catalog.json`. Reads whatever the release owner has already filled in and only asks about empty fields. Always runs `test-preflight` as Phase 0. Supports `setup-service validate` and `setup-service group <N>`. |
| `setup` | First-run initialization for the current release — reads the readiness chain (`preflight` < 24h + `setupService` must be `pass`), creates the release env directory, collects secrets, auto-detects CCOA. Does NOT re-run pre-flight. |
| `run` | Start a new release or resume the current one |
| `status` | Show the 16-step pipeline dashboard with progress |
| `skip` or `skip N` | Skip the current step (or step N) at runtime |
| `modify skip 4,5` | Skip specific steps mid-release (also supports `reorder` and `reset`). For up-front skipping, the per-release `setup` command has an interactive skip prompt. |
| `approve-ri` | Give the go-ahead after the RI PR merged (starts FI — only when `ado.integration` is enabled) |
| `private-stamp` | Provide the private stamp upgrade test inputs (instance, port for last build, port for current build, last build branch, TeeWorkflowQueueName, redirected vault ARM id for the BVT). Also `private-stamp retry`, `private-stamp skip <reason>`, `private-stamp status` |
| `approve-private-stamp` | Sign off the private stamp BVT (releases the Step 13 join) |
| `revert-bits base <sha>` / `revert-bits preserve <numbers\|all\|none>` | Revert bits (Step 7, after canary BVT sign-off): confirm the previous release commit / choose which changed settings to keep. Also `revert-bits status`, `revert-bits skip <reason>` |
| `approve-revert` | Sign off the BVT on the revert build — Step 7 then rolls canary back with it |
| `approve-bvt` | Approve BVT check results (unblocks step 6) |
| `approve-rollback` | Approve post-rollback results (unblocks step 9) |
| `approve-rollforward` | Approve post-roll-forward results (unblocks step 12) |
| `approve-crb` | Approve CRB review (dual-gate with SafeFly approval — unblocks step 14) |
| `ack retry` | Retry a failed step |
| `ack skip` | Skip a failed step and move on |
| `mitigated` | Re-run the currently halted (`failed-drift`) step normally. Use after editing `service-config.json` canary inventory or fixing the Kusto cluster-type extraction. Resolver re-validates; if drift persists, the step halts again. |
| `approve drift` | Re-run the currently halted (`failed-drift`) step with `-IgnoreDrift` on the resolver. Owner explicitly accepts the reported drift; agent writes an `event: "drift-approved"` audit row capturing the original drift list and the approver alias before triggering pipelines. |
| `resume` | Manually resume pipeline and restart watcher if needed |
| `stop` | Pause the release and stop the watcher |
| `test N` or `test all` | Dry-run a step or all steps (no real API calls) |
| `test-run` | Fast trigger-and-cancel validation — no deployment, no approvals, minutes. Steps 2/5/10 trigger→cancel+capture; 3,7-9,11-12,14-16 skipped |
| `teardown` | Post-release cleanup — remove secrets, unregister watcher |
| `gate on <N>` | Enable approval gate for step N |
| `gate off <N>` | Disable approval gate for step N (except step 14) |
| `gate list` | Show all 16 steps with current gate status |
| `approve-step <N>` | Approve the specified step to proceed |
| `approve` | Approve the currently waiting step |
| `help` | Show this command reference |

**Release Workflow:**

```
Step 1:  run                  ← Sends reminder
Step 2:  (automatic)          ← Cuts branch, queues build
         └ ado.integration:   ← 2a RI PR (master→develop) → merged → approve-ri → 2b FI PR (develop→master) → merged → cut
Step 3:  (automatic)          ← Watcher polls until build completes
Step 4:  (automatic)          ← Collects commits, generates Excel, uploads to SharePoint
Step 5:  (automatic)          ← Deploys canary (CANARY pipelines → EACan/ECY/CCY)
         └ privateStampUpgrade: ← private-stamp (inputs + vault) → last build (port 1) ∥ current build (port 2) → BVT release (PrivateStampVaultId) → approve-private-stamp  [parallel; Step 13 waits for it]
Step 6:  (automatic)          ← BVT check runs, frontliners notified if failures
Step 7:  (automatic)          ← Rollback (CANARY pipelines with previous bits)
         └ revertBits:        ← revert-bits preserve … → PR (owner merges) → revert build → owner BVT → approve-revert → rollback uses the revert build
Step 8:  (automatic)          ← Post-rollback BVT check runs
Step 9:  approve-rollback     ← Release owner reviews post-rollback results, approves
Step 10: (automatic)          ← Roll-forward (PROD pipelines → canary regions)
Step 11: (automatic)          ← Post-roll-forward BVT check runs
Step 12: approve-rollforward  ← Release owner reviews post-roll-forward results, approves
Step 13: (automatic)          ← SafeFly R2D request created via API, email sent
Step 14: approve-crb          ← Watcher polls SafeFly approval + release owner approves CRB
Step 15: (automatic)          ← Trigger all PROD pipelines, EV2 managed rollout
Step 16: (automatic)          ← Merge-back PR created, release complete
         teardown             ← Release owner cleans up (secrets, watcher, scheduler)
```

**~9 release owner commands** — everything else is autonomous via the watcher.

**How it works:** Type any command above as a chat message. The agent reads `state.json`, executes the appropriate logic, and updates state. Long-running operations (builds, deployments) are handled by a background watcher that polls and re-invokes the agent when conditions are met.

## setup-service — One-Time Service Onboarding

> **The full wizard procedure now lives in the `setup-service` skill at `.github/skills/setup-service/SKILL.md`.** When the release owner types `setup-service`, `setup-service validate`, or `setup-service group <N>`, **invoke the `/setup-service` skill** — do not attempt to run the wizard inline. The skill contains the complete 11-group flow (groups 1, 2, 3, 4a, 4b, 5a, 5b, 6, 7, 8, 9, 10, 11), the schema-aware Kusto branches for BVT and canary detection, the notification-routing customizer, the pipeline catalog collector, the Generation finalization pass, and the `setup-service validate` routine.

> **Internal invocation from `setup`:** When Behavior Rule 13's auto-remediation cascade encounters empty `service-config.json` or `pipeline-catalog.json` fields during `Test-PreFlight`, invoke the `/setup-service` skill with the matching group identifier (e.g., `/setup-service` then "group 5b") rather than asking the owner to start a new command. The skill is the single source of truth for the wizard logic — never reproduce its prompts here.

> **What stays in this agent file:** behavior rules that *reference* `setup-service` (Rules 11, 13), the `help` command listing, cross-references from step bodies (e.g., Step 5 cluster-type routing mentions setup-service-time collection), and the Notification Routing domain-knowledge section. These remain because they are read by the agent in contexts unrelated to the wizard itself.

> **Side effects to be aware of**: Group 11 (pipeline catalog) is evidence-driven — for every pipeline the owner declares, the wizard queues a real ADO pipeline run with the discovered parameters and cancels it within 5 seconds (same queue+cancel mechanic Step 15 test-mode uses). No deployment happens because cancellation occurs before any agent picks the work up, but cancelled runs ARE visible in ADO pipeline history. The wizard requires owner consent before entering Phase 11.2; sub-identifier `setup-service group 11.discovery-only` skips dry-runs entirely. Helper scripts: `scripts/Read-PriorRun.ps1`, `scripts/Read-PipelineYaml.ps1`, `scripts/Invoke-PipelineDryRun.ps1`. Auth uses the existing `az login` identity (ADO resource GUID `499b84ac-1321-427f-aa17-267ca6975798`) — no new credentials.

## setup — First-Run Initialization

> **Skill-owned.** Full procedure lives in [.github/skills/setup/SKILL.md](.github/skills/setup/SKILL.md).
> Do not reproduce the steps inline. Invoke `/setup` when the release owner types `setup`, `setup check`, or `setup skip <N,N,N>`.
> Auto-remediation of broken environment state is owned by `test-preflight`; service-config gaps cascade into `/setup-service` per Behavior Rule 13.


## status — Display Release Pipeline Status

When the release owner says `status`:

1. Load state (all config files)
2. If no active release → report "No active release"
3. If active release exists:
   - Show release ID, release owner name, current step
   - Show branch cut date ONLY — do NOT show canary target or production target dates
   - Show a table of all 16 steps with status icons, step name, and duration
   - If `state.integration` exists, show it under Step 2 as sub-rows `2a RI`, `2b FI`, `2c Cut` with each status and PR link (e.g. `2a RI ✅ merged !123`, `2b FI ⏳ pr-open !124`)
   - If `state.privateStampUpgrade` exists, show a side-track row `🧪 Private stamp upgrade` with its status, instance, ports, both run links/results, and the owner action it is waiting for (if any)
   - If `state.scheduleGuards` exists, show one line per guarded canary pipeline, e.g. `⏸ BCM-EACAN enableSchedule=false (paused after run 185400001, resumes on approve-bvt)` / `▶ … restored`
   - If `state.revertBits` exists, show it under Step 7: `🔁 Revert bits <revertBranch>: <phase>` with the kept settings count, PR link, build number/link and the owner action it waits for
   - Show progress (N/16 done)
   - Show watcher status (running/stopped, PID, what it's polling)
   - Show next expected action

Status icons:
- `pending` → ⬚
- `in-progress` → ⏳
- `completed` → ✅
- `failed` → ❌
- `skipped` → ⊘
- `waiting-approval` → ✧

## run — Start or Continue Release

When the release owner says `run`:

**0. Readiness chain check (do NOT re-run pre-flight):**

`run` reads `.zed-agent/readiness.json` and gates on the recorded outcome of every upstream stage. It does NOT invoke `Test-PreFlight` itself — `test-preflight` is now a first-class command that owns that responsibility.

Render a 3-row chain table:

```
| Stage          | Status | Detail                                                     |
|----------------|--------|------------------------------------------------------------|
| test-preflight |  ✅   | pass — ran 3h ago                                          |
| setup-service  |  ✅   | pass — last group: 11                                      |
| setup          |  ❌   | incomplete — missing: environment.json:repoRoot            |
```

Apply the gates in order. Each broken link gets an impact line:

| Broken link | Impact — what WILL break |
|---|---|
| `preflight` missing | Nothing has been verified — `az`, ADO, Kusto, Teams, MCP could all be broken. Every step that calls an external system can fail. |
| `preflight` stale (>24h) | Most likely an expired `az` token. ADO/Kusto/Graph calls in Steps 2, 3, 4, 5, 6, 8, 11, 13, 15 will return 401. |
| `preflight.status == fail` | The specific failures listed in `$r.preflight.failures` are still broken — list each one and the step it would affect. |
| `setupService` missing | Service config never collected — `service-config.json` and `pipeline-catalog.json` are likely empty. Step 2 cannot cut the branch, Steps 5/7/10/15 have no pipelines to trigger, Step 13 has no SafeFly title template. |
| `setupService.status == incomplete` | The wizard exited mid-flow at group `{lastGroup}`. List `$r.setupService.missingFields`. Affected steps depend on which fields are missing (e.g., missing Kusto config breaks Steps 6/8/11; missing notification routing breaks every email/Teams notification). |
| `setupService.status == fail` | Schema validation failed — list `missingFields`. Same impact as `incomplete`. |
| `setup` missing | No release directory — nothing in `.zed-agent/` for this month. Watcher cannot register, no `state.json`, no `secrets.json`. Pipeline cannot start. |
| `setup.status == incomplete` | Setup exited before producing required artifacts. List `$r.setup.missingArtifacts`. Notifications, SharePoint upload, CCOA exclusions, and Teams messages will silently misbehave. |

**If every gate is green** → proceed silently to step 1 below.

**If any gate is red:**

1. Render the chain table above with each red row's impact line directly underneath it.
2. Tell the release owner the exact command to fix it:
   - `preflight` issues → *"Run `test-preflight fix` — it will auto-remediate auth, modules, and MCP. Then re-run `run`."*
   - `setupService` issues → *"Run `setup-service group {lastGroup}` to resume, or `setup-service validate` after fixing fields by hand. Then re-run `run`."*
   - `setup` issues → *"Run `setup` to finish initializing this month's release. Then re-run `run`."*
3. Ask via `ask_user`:
   > *"Do you want to fix this now (recommended) or proceed anyway?"*
   > Choices: `Fix it now — stop run`, `Proceed anyway — I accept the risk`
4. On `Fix it now` → HALT silently. The owner re-runs `run` after fixing.
5. On `Proceed anyway` → show the **strong warning** before continuing:

   ```
   ⚠️  YOU ARE RUNNING WITH KNOWN-BROKEN READINESS

   The following stages are NOT green:
     - {stage}: {detail}
     - ...

   The following pipeline steps WILL fail or behave incorrectly:
     - {step-list derived from the impact table above}

   Audit will record this as a `run-with-broken-readiness` event with the
   exact list of broken gates and overridden checks.

   Do you still want to proceed?
   ```
   Choices: `Yes — proceed despite the risk`, `No — let me fix it first`

6. On `No` → HALT. On `Yes` → append to `audit.jsonl`:
   ```json
   {"action":"run-with-broken-readiness","brokenGates":["preflight.stale","setup.incomplete"],"impactedSteps":[2,5,6,8,15],"timestamp":"<UTC ISO>"}
   ```
   … then continue with step 1 below.

The chain check **never** mutates `readiness.json` except to set the relevant `overridden` flag to `true` on whichever stage(s) the owner waived.

**Then proceed with the normal run flow:**

1. Verify a release directory exists for the current month (format: `YYYY-MM`). If **no release exists** → tell the release owner: *"No release initialized for this month. Run `setup` first."* and **HALT**.
2. Load state from `state.json`, resume from current step
3. Execute steps in order following the Step Execution Loop above
4. For async steps: write `watcherDirective` to state, start watcher process, exit

## modify — Skip, Reorder, or Override Steps

When the release owner says `modify`:

**Input patterns**:
- `modify skip 4,5` — Skip steps 4 and 5
- `modify reorder 8 before 7` — Execute step 8 before step 7
- `modify reset 3` — Reset step 3 to `pending` for re-execution

> **Tip**: To skip steps **before** the release starts, the per-release `setup` command offers an interactive skip prompt (sub-step 11.f). Same persistence — both write `status: "skipped"` to `state.json`. Use `setup` for planned skips, `modify skip` for mid-release adjustments.

**Behavior**:
1. Parse the modification request
2. Check the dependency matrix for warnings
3. Show a confirmation view:
   ```
   Proposed changes to release {id} pipeline:

    ⚠ SKIP Step 4 (Collect Commit Details)
      → Warning: Step 11 (Create R2D) references commit data from Step 4.
                 R2D description may be incomplete.

   Confirm? (yes/no)
   ```
4. If confirmed, apply changes to `state.json`
5. Log modification in `audit.jsonl` with actor `release-owner`

## skip — Quick Skip Current Step

When the release owner says `skip` or `skip N`:

1. If no step number → skip the current step (first non-completed step)
2. If step number → skip that specific step
3. Set step status to `skipped`
4. Advance `currentStep` to next pending step
5. Log in audit with reason

## approve-ri — Go-Ahead After Reverse Integration

When the release owner says `approve-ri` or `approve ri` (only meaningful when `CONFIG[ado.integration.enabled]`):

1. Verify Step 2 is `waiting-approval` **and** `state.integration.phase == "ri-go-ahead"`. Otherwise reply with the current integration phase (e.g. *"RI PR !123 is still open — I'll ask for the go-ahead once it merges."*) and change nothing.
2. Record `state.integration.ri.goAheadAt` (UTC now) and `goAheadBy` (owner alias); set `phase = "fi"`
3. Set Step 2 → `in-progress` (**not** `completed`) in the same `Update-ReleaseState` write
4. Log `{ "event": "ri-go-ahead" }` in audit
5. Resume execution loop → Step 2 sub-phase 2b (FI) per `step-behaviors.md → Step 2 — Integration sub-phases`

`approve` and `approve-step 2` are accepted as aliases while `phase == "ri-go-ahead"`.

## private-stamp — Private Stamp Upgrade Test Inputs and Control

Only meaningful when `CONFIG[pipelines.privateStampUpgrade.enabled]`. Spec: `step-behaviors.md → Private stamp upgrade test`. Every variant calls `scripts/Invoke-PrivateStampUpgrade.ps1 -ReleaseId <id> -By <owner alias>`; if the result has a `NotifyEvent`, send that email. Never POST the private stamp pipeline directly.

**`private-stamp`** (inputs). **Ask every release — never pre-fill from a previous release.**
- One-line form (also used from email replies / headless): `private-stamp instance=<X> lastPort=<n> currentPort=<n> lastBuild=<build link or id> queue=<name> vault=<redirected vault ARM id>` — parse, do not prompt.
- Interactive form (bare `private-stamp`): use `ask_user` **one question at a time**:
  1. *"Which private stamp instance should I deploy to (e.g. A, B, C)?"*
  2. *"Port for the LAST build deployment (WebRolePort; HTTP uses port + 1)?"*
  3. *"Port for the CURRENT build deployment ({release.currentBranch})?"*
  4. *"Link to the LAST deployment's official build (…/_build/results?buildId=…) — I'll deploy exactly that build, even if its branch has newer ones."* (without `privateStampUpgrade.artifact`: *"Which branch is the last deployment build? Its latest build is deployed."*)
  5. *"TeeWorkflowQueueName for both deployments? (passed as ServiceOverrideSettings = @{\"BCMAppConfig->WorkflowQueueName\"=\"<name>\";})"*
  6. *(only when `privateStampUpgrade.bvtRelease` is configured)* *"ARM id of the vault redirected to one of these ports? The BVT runs against it (PrivateStampVaultId). Format: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.RecoveryServices/vaults/<name>"*
- Then run `-Action SetInputs -Instance -LastPort -CurrentPort -LastBuild <link|id> -QueueName -VaultId` (without `artifact`: `-LastArtifactBranch <branch>` instead of `-LastBuild`). On a validation error, show the message and re-ask only the offending field(s). On success, reply with the resolved plan (instance, `port1 ← <last build number> (<branch>, build <id>)`, `port2 ← this release's build (pinned to release.buildId when queued)` — **deployed in parallel**, queue name, vault for the BVT) and the new status: `deploying` (both run links) if Step 3 has completed, otherwise *"Inputs saved — I'll deploy both builds as soon as the release build finishes."* Accepted while the track is `awaiting-input`, `inputs-ready` or `failed` (new inputs restart both legs), and also before Step 5 (inputs are kept until the build is ready).

**`private-stamp retry`** — `-Action Retry`: re-runs only what failed with the same inputs — the failed leg(s) (the succeeded leg is not redeployed; the BVT starts once both have succeeded) or, when only the BVT failed, a new BVT release.

**`private-stamp skip <reason>`** — `-Action Skip -Reason <reason>` (ask for a reason if missing). Releases the Step 13 join; if Step 13 is `waiting`, resume the execution loop. The reason is recorded in audit and quoted in the R2D notes.

**`private-stamp status`** — `-Action Get`; show status, inputs, both deployment runs, the BVT release (link, stage results) and the next owner action.

## approve-private-stamp — Sign Off Private Stamp BVT

When the release owner says `approve-private-stamp` or `approve private-stamp`:

1. Run `Invoke-PrivateStampUpgrade.ps1 -Action SignOff -By <owner alias>`. Accepted when the track is `awaiting-bvt` (BVT finished succeeded/partiallySucceeded), or `failed` with only the BVT failed (owner override — confirm first: *"The BVT ended {bvtOutcome}. Sign off anyway?"*). Otherwise report the current status and what it is waiting for; change nothing.
2. Confirm: *"✅ Private stamp upgrade test signed off ({instance}: {lastBuild} on {port1}, {currentBranch} on {port2}; BVT {bvtOutcome})."*
3. If Step 13 is `waiting`, resume the execution loop (Step 13 re-runs its prerequisite checks).

## revert-bits — Revert Bits Selection and Control (Step 7 pre-phase)

Only meaningful when `CONFIG[revertBits.enabled]`. Spec: `step-behaviors.md → Step 7 — Revert bits (7a–7d)`. All git work goes through `scripts/Invoke-RevertBits.ps1`.

- **`revert-bits base <sha|branch>`** — accepted while `state.revertBits.phase == "needs-previous-commit"` (or `awaiting-selection`, to correct it). Resolve to a full sha (`git rev-parse`), store `state.revertBits.previousCommit`, re-run 7a (`-Action Plan -PreviousCommit <sha>`) and send the selection email. Warn if the commit is not an ancestor of the current release commit.
- **`revert-bits preserve <list>`** — accepted while `phase == "awaiting-selection"`. `<list>` = setting numbers from the plan (`2,4,7`), `all`, or `none`; `CONFIG[revertBits.preserveAlways]` settings (BCM: `BCMAppConfig->BCMTeeWorkflowVersion`) are always included and need not be listed. Echo the resolved list (number, scope, setting, kept value) before running 7b; on an invalid number show the error and the valid range and change nothing.
- **`revert-bits status`** — show `state.revertBits` (phase, commits, kept settings, PR, build) and the plan table.
- **`revert-bits skip <reason>`** — any phase before `signed-off`: `phase = "skipped"`, `skippedReason`, Step 7 → `in-progress` and continue with Step 7 Action 1 using `release.previousBranch`. Ask for a reason if missing. An already-open PR or branch is left as is (mention it).

## approve-revert — Sign Off the Revert Build

When the release owner says `approve-revert` (or `approve revert`):

1. Verify Step 7 is `waiting-approval` and `state.revertBits.phase == "awaiting-bvt"`; otherwise report the current revert-bits phase and what it waits for, change nothing.
2. `phase = "signed-off"`, record `signedOffAt` / `signedOffBy`, Step 7 → `in-progress` (single `Update-ReleaseState` write); audit `{ "event": "revert-bits-signed-off", "build": "<buildNumber>" }`.
3. Resume execution loop → Step 7 Action 1 (canary rollback with the revert build per Action 2).

`approve` / `approve-step 7` are accepted as aliases while `phase == "awaiting-bvt"` — they never mark Step 7 `completed`.

## approve-bvt — Approve BVT Results

When the release owner says `approve-bvt`:

1. Verify step 6 (bvt-check) is in `waiting-approval`
2. Record approval: `state.json → approvals.bvt`
3. Set step 6 → `completed`, advance to step 7
4. **Canary schedule guard**: run `Invoke-ScheduleGuard.ps1 -Action Restore -ReleaseId <id> -Reason approve-bvt` and send an email per `NotifyEvents` entry (e.g. BCM-EACAN `enableSchedule` → `true`). See `step-behaviors.md → Canary schedule guard`.
5. Resume execution loop
6. Log in audit

## approve-rollback — Approve Post-Rollback Results

When the release owner says `approve-rollback` or `approve rollback`:

1. Verify step 9 (post-rollback-signoff) is in `waiting-approval`
2. Record approval: `state.json → approvals.rollback`
3. Set step 9 → `completed`, advance to step 10
4. Resume execution loop
5. Log in audit

## approve-rollforward — Approve Post-Roll-Forward Results

When the release owner says `approve-rollforward` or `approve rollforward`:

1. Verify step 12 (post-rollforward-signoff) is in `waiting-approval`
2. Record approval: `state.json → approvals.rollforward`
3. Set step 12 → `completed`, advance to step 13
4. Resume execution loop
5. Log in audit

## approve-crb — Approve CRB Review

When the release owner says `approve-crb` or `approve crb`:

1. Verify step 14 (crb-review) is in `waiting-approval`
2. Set `state.json → step14.crbApproved = true`, record timestamp
3. **Check dual-gate**: Read `state.json → step14.safeFlyApproved`
   - If **both** `safeFlyApproved` and `crbApproved` are `true`:
     - Set step 14 → `completed`, advance to step 15
     - Send transition email to release owner via `Resolve-NotificationRecipients -EventKey 'step-14-completed'`: *"✅ Both CRB and SafeFly approved — proceeding to production rollout"* (no Teams unless owner has configured `step-14-completed` routing)
     - Resume execution loop
   - If SafeFly is **not yet approved**:
     - Send email to release owner via `Resolve-NotificationRecipients -EventKey 'judgment'`: *"✅ CRB approved. Waiting for SafeFly R2D #{number} approval — currently: {safeFlyApprovalState}"* (no Teams per Rule 1)
     - Keep step 14 in `waiting-approval` — watcher continues polling SafeFly
4. Log in audit

## ack — Acknowledge Failure

When the release owner says `ack retry` or `ack skip`:

- **`ack retry`**: Reset the failed step to `pending`, re-enter execution loop
- **`ack skip`**: Set the failed step to `skipped`, advance to next step

**Step 2 integration exception** (`state.integration.phase` is `ri` or `fi`): `ack retry` re-runs only the current sub-phase and `ack skip` skips only that sub-phase (RI → FI, FI → cut) — Step 2 goes back to `in-progress` and the branch cut still runs. See `step-behaviors.md → Step 2 — Integration sub-phases → Failure / owner commands`.

Log acknowledgment and action in audit.

## resume — Manual Resume

When the release owner says `resume`:

1. Read state, detect where the pipeline left off
2. Check if watcher is running (parse `watcher.lock` as JSON per the "Reading `watcher.lock`" sub-section in Step Execution Loop → liveness-check the PID)
3. If watcher not running → restart it
4. Re-enter step execution loop from current step
5. Report current status and next action

## stop — Stop Watcher and Pause Release

When the release owner says `stop`:

1. Parse `watcher.lock` as JSON (per the "Reading `watcher.lock`" sub-section in Step Execution Loop) → extract `$lock.pid`
2. Kill watcher process: `Stop-Process -Id $lock.pid`
3. Set release status → `stopped`
4. Send email to release owner via `Resolve-NotificationRecipients -EventKey 'judgment'`: "Release paused by release owner" (no Teams per Rule 1)
5. Log in audit

## test — Dry-Run Step or Full Flow

When the release owner says `test N` or `test all`:

1. Set a dry-run flag in context
2. Execute the step(s) with all external calls mocked:
   - Skills return `{ dryRun: true, wouldHaveDone: "..." }` instead of making real API calls
   - MCP tools are not invoked — agent describes what it would have done
3. Report what **would have** happened at each step
4. **No state changes** are persisted — state.json is not modified

## test-run — Real Run with Steps Skipped

When the release owner says `test-run`:

> **Design principle**: `test-run` is a **fast, non-destructive validation** of the release
> pipeline. Every pipeline that a real release would trigger (build, canary, prod) is triggered
> **for real and cancelled within seconds** — proving the trigger works and capturing the exact
> parameters ZED posted, without deploying anything. Steps whose only purpose is to wait
> (build wait, 24h bakes, SafeFly/CRB approval, EV2 monitoring) are skipped. There are **no human
> approval gates** — the run completes autonomously in minutes so a development agent (ZedForge)
> can loop fix→validate→harvest. The trigger-and-cancel steps write a machine-readable
> `test-run-capture.json` that the development agent verifies against its requirements file.

> **Non-interactive invocation**: When ZED is invoked headlessly (e.g. by ZedForge with
> `--no-ask-user --autopilot`, and the prompt says "non-interactive"), **skip the confirmation
> prompt in step 1** and proceed directly to Setup using the `currentBranch` / `previousBranch` /
> `releaseId` / `releaseOwner` supplied in the prompt. The confirmation is only for interactive owners.

1. **Confirm**: Display this message and wait for release owner confirmation:
   ```
   🧪 TEST RUN — Fast Trigger-and-Cancel Validation (no deployment)

   This runs the pipeline end-to-end WITHOUT deploying anything. For each pipeline
   a real release would trigger, ZED triggers it for real, captures the exact posted
   parameters + runId, then cancels it within ~5s (before any agent picks it up):

   ✅ Step 1  Branch cut reminder — owner-only email
   ✅ Step 2  Cut release branch + queue build → INSTANTLY CANCEL + capture params
   ⊘ Step 3  Wait for build — SKIPPED (build was cancelled)
   ✅ Step 4  Collect & analyze commits — REAL run, owner-only mail, no human wait
   ✅ Step 5  Canary pipelines → trigger then INSTANTLY CANCEL + capture params
   ✅ Step 6  BVT check — run the Kusto query as a "does-it-work" check (no 24h wait, no approval)
   ⊘ Steps 7-9   Rollback cycle — SKIPPED
   ✅ Step 10 Roll-forward PROD pipelines → trigger then INSTANTLY CANCEL + capture params
   ⊘ Steps 11-12 Post-roll-forward — SKIPPED
   ✅ Step 13 SafeFly R2D — REAL filing (you abandon it afterwards)
   ⊘ Steps 14-15 SafeFly/CRB wait + EV2 prod rollout — SKIPPED
   ⊘ Step 16 Merge-back PR — SKIPPED

   No human approvals. Notifications go to you only (email, [TEST] prefix, no Teams).
   Cancelled runs ARE visible in ADO build history. Remember to abandon the SafeFly R2D.
   Expected duration: minutes.

   Proceed? (yes/no)
   ```

2. **Setup** (same flow as `setup` command but with test overrides):
   a. Release ID: `TEST-{YYYY-MM}` (e.g., `TEST-2026-04`)
   b. Ask for `currentBranch` (release branch to test) and `previousBranch`
   c. Run full `setup` prerequisites check
   d. Create `release.json` with test mode config:
      ```json
      {
        "releaseId": "TEST-2026-04",
        "testMode": true,
        "testConfig": {
          "skippedSteps": [3, 7, 8, 9, 11, 12, 14],
          "triggerAndCancelSteps": [2, 5, 10],
          "cancelAfterSeconds": 5,
          "skipBvtBakeTimer": true,
          "bvtMode": "query-works-check",
          "autoApprove": true,
          "notificationTarget": "owner-email-only"
        },
        "currentBranch": "...",
        "previousBranch": "...",
        "releaseOwner": { "alias": "...", "email": "..." }
      }
      ```
   e. Create `state.json` — mark steps 3, 7, 8, 9, 11, 12, 14 as `skipped` with reason `"test-run"`:
      ```json
      {
        "steps": {
          "3":  { "status": "skipped", "reason": "test-run: build cancelled at trigger" },
          "7":  { "status": "skipped", "reason": "test-run" },
          "8":  { "status": "skipped", "reason": "test-run" },
          "9":  { "status": "skipped", "reason": "test-run" },
          "11": { "status": "skipped", "reason": "test-run" },
          "12": { "status": "skipped", "reason": "test-run" },
          "14": { "status": "skipped", "reason": "test-run" }
        }
      }
      ```
   f. Run preflight checks. **No watcher is needed** — the true test run has no async waits
      (build wait, bakes, approvals and EV2 monitoring are all skipped), so it runs
      synchronously to completion in one invocation. Do NOT register the watcher task.

3. **Execute**: Enter the normal Step Execution Loop. Steps **1→2→4→5→6→10→13→15→16** run;
   steps 3,7,8,9,11,12,14 are bypassed automatically ("if `skipped` → advance to next
   pending step"). Steps 2/5/10 use the trigger-and-cancel override (see Test Mode Overrides).
   Step 15 uses its test-mode override (notification sent, then marked skipped). Step 16 runs fully.
   The whole run is synchronous — no step arms a `watcherDirective` in test mode.

4. **After Step 16 completes** (the last step): Send test summary email (see Test
   Mode Overrides below) including the `test-run-capture.json` summary, remind owner to abandon
   the SafeFly R2D, and auto-teardown.

## teardown — Post-Release Cleanup

When the release owner says `teardown`:

1. **Unregister ALL ZED watcher scheduled tasks and kill watcher processes**:
   ```powershell
   . .github\skills\zed-agent\scripts\Register-WatcherTask.ps1
   $result = Register-WatcherTask -Action cleanup
   # Reports: tasksRemoved (list of task names), processesKilled (list of PIDs)
   ```
   This removes the current release task AND sweeps any orphaned/stale tasks from crashed runs or old test-runs.
2. **Canary schedule guard**: run `Invoke-ScheduleGuard.ps1 -Action Restore -ReleaseId <id> -Reason teardown` so no canary pipeline is left with its schedule paused by ZED (e.g. a release abandoned between Step 5 and Step 6). Report any `restore-failed` with the manual fix.
3. Delete `.zed-agent/secrets.json`
4. Send final email to release owner via `Resolve-NotificationRecipients -EventKey 'judgment'`: "Release {id} teardown complete" (no Teams per Rule 1)
5. Log in audit
6. Report teardown completion summary — include count of tasks removed and processes killed

## rebuild — Re-queue Build + Selective Canary Retrigger

When the release owner says `rebuild` (e.g. after late cherry-picks into the release branch):
1. Queue a new officialBuild on `release.json → currentBranch` (Step 2's queueing logic; the branch
   already exists, so skip branch creation). Update `release.json → buildId` / `buildNumber` and log.
2. Arm Step 3's build watcher for the new build. On completion, **ask the owner which canary pipelines
   to retrigger** — only the pipelines whose service had missing commits need it; the others keep
   their existing canary results.
3. Retrigger only the chosen canary pipelines (Step 5 logic) with the new build artifacts.
   **Canary schedule guard**: for each chosen pipeline that has `scheduleGuard`, run
   `Invoke-ScheduleGuard.ps1 -Action Restore -PipelineKey <key> -Reason rebuild` **before** queueing it
   (halt the rebuild for that pipeline if the result is `restore-failed` — its run would be silently skipped),
   and right after queueing run `-Action Rearm -PipelineKey <key> -RunId <newRunId>` so the schedule is paused
   again once THAT run succeeds (no-op once Step 6 is signed off). Send an email per `NotifyEvents` entry.
Rationale: a mid-release rebuild invalidates canary results for the affected service only; blindly
re-running everything wastes ~1h/pipeline. Service-agnostic — pipeline keys come from the catalog.

## new-stamp — Onboard / Reclassify a Stamp

When the release owner says `new-stamp` (onboarding a new stamp, or reclassifying one between pipeline
types, e.g. SFRP↔SFMC), collect per stamp: **prefix**, **region** (Azure short name), **pipeline
type**, **cloud**. Then compute the parameter deltas for the affected `pipeline-catalog.json` entries:
- **Add** the stamp's region to the target pipeline-type's `PubRegions` — look the region up in
  `service-config.json → stampPrefixToRegion` (the prefix is not always the literal region code, e.g.
  `uae`→`uaecentral` via short code `uac`); do not guess.
- **Remove** the stamp from the target type's `PublicExcludestamps`; **keep** it excluded in the
  other type(s) it does not belong to.
- Confirm boolean flags (e.g. `CanaryScript`) and `ev2CloudCoverage` differ per pipeline type.
Both EV2 gates must align: a stamp deploys only if its region is in `PubRegions` **and** it is not in
`PublicExcludestamps`. Service-agnostic — every value comes from the two config files.

## Teams conversation IDs — collected at setup, not auto-discovered

Teams group-chat conversation IDs are **collected during `setup` and stored in
`.zed-agent/secrets.json → teamsChats`** (keyed by chat name), NOT auto-discovered at runtime.
Reliable runtime auto-discovery is unavailable (`Find-TeamsChat` needs Teams-Desktop CDP; Graph needs
a delegated `Chat.ReadBasic` token). If a conversation ID is missing at send time, prompt the owner
for it once and persist it to `secrets.json` rather than attempting discovery.

---

