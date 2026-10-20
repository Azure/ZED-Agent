<!-- Extracted from ZedAgent.agent.md. The agent file is a dispatcher; this file
     holds the detail and is read on demand. Keeping it out of the static system
     prompt is what allows the agent to load at all — see learning e2f8c272b24c. -->

# Release Step Detailed Behaviors

## Step 1: Send Branch Cut Reminder

**Trigger**: Start of `run` execution
**Actions**:
1. Render `templates/reminder-message.html` with release dates via `Expand-Template`
2. Resolve recipients via `Resolve-NotificationRecipients -EventKey 'reminder'` (returns Teams chat list + email recipients per `routing.reminder` block: `teamsGroups: ["teams"]`, `emailGroups: ["permanent"]`). For each Teams chat returned, post via `Send-TeamsMessage`.
3. Render `templates/reminder-email.html` via `Expand-Template`
4. Send to the email recipients returned by `Resolve-NotificationRecipients` via `SendEmailWithAttachments` MCP tool with the rendered HTML as `body`, `contentType: "HTML"`
**State**: Step 1 → `completed`
**Next**: Proceed immediately to Step 2
**Failure**: Notification failure → log warning, continue (non-blocking)

## Step 2: Cut Release Branch & Queue Build

**Trigger**: Step 1 completed
**Integration sub-phases**: When `CONFIG[ado.integration.enabled]` is `true`, Step 2 first runs **2a Reverse Integration (RI)** and **2b Forward Integration (FI)** — see "Step 2 — Integration sub-phases (2a RI / 2b FI)" below — and only then performs the Actions listed here (sub-phase **2c**). When the block is absent or `enabled` is `false`, Step 2 is exactly the Actions below.
**Deploy-base releases** (`release.json → releaseMode == "deploy-base"`, e.g. BCM): **no branch is cut**. Replace Actions 1–3 with "Step 2 — Deploy-base build (2c)" below; Actions 4–6 (store build, Step 4 inline work, arm the build watcher) are unchanged.
**⚠️ Test Mode Override**: When `testMode` is `true`, create the branch and resolve the officialBuild params as normal, but **trigger the build via `Invoke-TriggerAndCancel.ps1 -Step 2` (instant cancel + capture)** instead of arming the build watcher. Mark Step 2 `completed`, Step 3 `skipped`. See "Test Mode Overrides → Step 2".
**Actions**:
1. Create branch `{release.currentBranch}` from `origin/CONFIG[ado.baseBranch]` in ADO repo via ADO API. Always branch from origin, never local — local can be stale. (Branch name was already confirmed during `setup` — do NOT re-prompt here.)
2. Verify branch exists
3. Queue CloudBuild pipeline (ID: CONFIG[pipelines.officialBuild.id], see pipeline-catalog.json → officialBuild) on the new branch via ADO API:
   - `sourceBranch` = `refs/heads/{release.currentBranch}` — the release branch being built (NOT develop)
   - `templateParameters`: Use all key-value pairs from `CONFIG[pipelines.officialBuild.templateParameters]` (loaded from pipeline-catalog.json)
4. Store `buildId` in `release.json` and step metadata
5. **Run Step 4's inline (synchronous) work in parallel with the about-to-be-armed build watcher.** Per the Step Dependency Matrix parallelism note (Step 3 ∥ Step 4), execute Step 4 Actions sub-steps 1–9 **right here, before arming any watcher** — git fetch, `git log --cherry-pick`, classify every commit, build `commits.xlsx`, upload to SharePoint, post the commit-request Teams message.
   **IDEMPOTENCY**: On entry, check `state.step4InlineCompleted`. If already `true`, skip all inline work (SharePoint upload, Teams post already done in a prior session) and proceed directly to arming the watcher side-channel.
   On completion:
   - Set `state.step4InlineCompleted = true`
   - Set `state.step4InlineCompletedAt = <UTC ISO 8601 now>` (used by the watcher's 24 h nudge timer)
   - Set `state.step4ExcelUrl = <SharePoint sharing URL>` (same value stored in `release.json.commitExcelUrl`)
   - Set `state.steps[4].status = "in-progress"` (the Excel Impact poll will continue via the watcher side-channel; `completed` is set automatically by the watcher when Impact reaches 100%)
   - Append `{ "event": "step4-inline-done", "excelUrl": "...", "commitCount": N }` to `audit.jsonl`
   - **Test mode override**: if `release.json.testMode == true`, auto-fill the Excel manual columns (Impact = "Low", Validations = "CanaryTesting", Rollback Friendly = "Yes"), skip Teams post, set `state.steps[4].status = "completed"` immediately, and skip the watcher side-channel entirely.
   - **Failure of Step 4 inline work** is non-fatal for Step 3: log the error, set `state.steps[4].status = "failed"`, send owner email, but **still arm Step 3's build watcher** and exit. Step 13's prerequisite check will catch the Step 4 failure later.
6. Arm Step 3's build watcher and EXIT.
**State**: Step 2 → `completed`, Step 3 → `in-progress` (build watcher armed), Step 4 → `in-progress` (Excel-fill side-channel armed; or `completed` in test mode)
**Watcher**: `{ action: "poll-ado-build", target: "<build API URL>", pollIntervalSeconds: CONFIG[operational.watcherPollIntervalSeconds], successCondition: "$.status == 'completed'", onSuccess: "continue release {id}", onFailure: "release {id} build failed" }`
**Failure**: Branch creation failure → `failed`, Teams notify, halt. (Step 4 inline failure does NOT block Step 2 from completing — see Action 5 above.)

## Step 2 — Integration sub-phases (2a RI / 2b FI)

Runs only when `CONFIG[ado.integration.enabled] == true` (e.g. BCM, which keeps a `develop` + `master` pair). It brings `mainBranch` and `developBranch` level **before** the release branch is cut, so the release is cut from a `mainBranch` that contains everything in `developBranch`.

| Sub-phase | What | Wait | Resumed by |
|-----------|------|------|------------|
| **2a RI** | New branch from `developBranch`, merge `mainBranch` in, open PR → `developBranch` | PR merged, then owner go-ahead (if `requireGoAheadAfterRI`) | watcher `poll-ado-pr`, then `approve-ri` |
| **2b FI** | New branch from `mainBranch`, merge `developBranch` in, open PR → `mainBranch` | PR merged | watcher `poll-ado-pr` |
| **2c Cut** | Step 2 Actions 1–6 above (branch from `origin/CONFIG[ado.baseBranch]`, which equals `mainBranch`) | — | — |

**Merge rules** (implemented by `scripts/Invoke-BranchIntegration.ps1` — never hand-resolve):
- **Preserve paths** (`CONFIG[ado.integration.preservePaths]`, default `.config`): the **PR target's** version always wins — RI keeps `developBranch`'s, FI keeps `mainBranch`'s. Applies to conflicted files **and** to files the source changed cleanly (reverted; files the source added there are removed).
- **Everything else** (`conflictStrategy: newest-commit-per-file`): for each conflicted file, the branch whose most recent commit touching that file is newer (committer time) wins. Only the conflicting hunks are taken from the winner; clean changes from both sides are kept. Binary / modify-delete / non-text-mergeable files take the winner's whole file (or its deletion) and are listed under **reviewFiles**. Ties keep the target.
- The merge runs in a throw-away `git worktree` of the service repo clone (the ZED working directory); the owner's checkout is never touched.

**State** — top-level `state.integration`, written with `Update-ReleaseState -Action update-step -StepNumber 2 -StepStatus <status> -StateProperties @{ integration = <obj> }` (single lock, single write):
```json
"integration": {
  "phase": "ri | ri-go-ahead | fi | cut",
  "ri": { "status": "pending | pr-open | merged | up-to-date | skipped | dry-run", "branch": "", "prId": null, "prUrl": "", "headSha": "", "report": ".zed-agent/releases/<id>/integration-ri.json", "conflictCount": 0, "reviewFiles": [], "mergedAt": null, "goAheadAt": null, "goAheadBy": null },
  "fi": { "status": "pending | pr-open | merged | up-to-date | skipped | dry-run", "branch": "", "prId": null, "prUrl": "", "headSha": "", "report": ".zed-agent/releases/<id>/integration-fi.json", "conflictCount": 0, "reviewFiles": [], "mergedAt": null }
}
```
On first entry to Step 2, if `state.integration` is absent, initialize it with `phase: "ri"` and both sub-objects `status: "pending"`. Every later entry dispatches on `state.integration.phase`. Also mirror the PR ids into `release.json` as `riPrId` / `fiPrId`.

**Branch names**: expand `CONFIG[ado.integration.riBranchTemplate]` / `fiBranchTemplate` (defaults `zed/{releaseTag}-ri-master-to-develop`, `zed/{releaseTag}-fi-develop-to-master`). `{releaseId}` = `release.releaseId`; `{releaseTag}` = `release.releaseTag` when set (deploy-base always sets it, e.g. `bcm-2611` — the leaf of `master` would collide month to month; with `CONFIG[releaseNaming]` it is the lowercased release name, e.g. `bcm2610_2` → `zed/bcm2610_2-ri-master-to-develop`), else the leaf of `release.currentBranch` after the last `/` (e.g. `releases/bcm-2611` → `bcm-2611`).

### 2a — Reverse Integration (`phase == "ri"`)
1. If `ri.status == "pr-open"` and `ri.prId` is set (resume / cold start): do NOT re-merge. GET the PR; if `completed` go to step 7, if `abandoned` go to **Failure**, else re-arm the watcher (step 6) and EXIT.
2. Run:
   ```powershell
   $res = & .github/skills/zed-agent/scripts/Invoke-BranchIntegration.ps1 -Direction RI `
       -SourceBranch CONFIG[ado.integration.mainBranch] -TargetBranch CONFIG[ado.integration.developBranch] `
       -IntegrationBranch <riBranch> -PreservePaths CONFIG[ado.integration.preservePaths] -Push `
       -ReportPath ".zed-agent/releases/<id>/integration-ri.json" `
       -CommitMessage "RI: Merge <mainBranch> into <developBranch> for <releaseTag>"
   ```
3. `$res.status == "up-to-date"` → `ri.status = "up-to-date"`, no PR, no go-ahead; send owner-only `judgment` email (*"RI not needed — `<developBranch>` already contains `<mainBranch>`"*), set `phase = "fi"`, continue to 2b in the same invocation.
4. `$res.status` `merged` or `reused` → create the PR via ADO MCP (same tool family as Step 16): source `refs/heads/<riBranch>` → target `refs/heads/<developBranch>`, title `RI: <mainBranch> → <developBranch> | <releaseTag> (ZED)`, description = `$res.summaryMarkdown` (truncate to 4000 chars and append "full report: <report path>" if longer), **isDraft = false** (repos may default new PRs to draft — BCM does). For `reused`, first look for an **active** PR from `<riBranch>` into `<developBranch>` and reuse it. Never set auto-complete and never bypass branch policies — reviewers/policies are the repo's.
5. Notify: email via `Resolve-NotificationRecipients -EventKey 'ri-pr-raised'` (default: current-owner-only; widen via `routing.2-cut-branch.halt`). Subject `🔀 RI PR raised — <mainBranch> → <developBranch> | <releaseId>`. Body: PR link, conflict count, the `reviewFiles` list (⚠ these need a human look), preserved `.config` files, and *"ZED will continue automatically once this PR is merged."*
6. Write `ri.status = "pr-open"`, `prId`, `prUrl`, `headSha`, `conflictCount`, `reviewFiles` (Step 2 stays `in-progress`) and arm the watcher, then EXIT:
   `{ action: "poll-ado-pr", target: "https://dev.azure.com/CONFIG[ado.organization]/CONFIG[ado.project]/_apis/git/repositories/CONFIG[ado.repository]/pullrequests/<prId>?api-version=7.1", pollIntervalSeconds: CONFIG[ado.integration.prPollIntervalSeconds] (default 900), onSuccess: "continue release {id} — RI PR <prId> merged", onFailure: "release {id} RI PR <prId> abandoned or unreachable" }`
7. **On PR merged** (watcher `onSuccess`): confirm via GET that `status == "completed"`; set `ri.status = "merged"`, `ri.mergedAt = closedDate`, clear the directive (`action: "none"`).
   - `CONFIG[ado.integration.requireGoAheadAfterRI] != false` → `phase = "ri-go-ahead"`, Step 2 → `waiting-approval`, emit the Rule 11 email `step-2-waiting-approval` with subject `⏸ Step 2 (RI merged) waiting for go-ahead — reply approve-ri to start FI | {releaseId}`, EXIT.
   - otherwise → `phase = "fi"`, continue to 2b.

### Go-ahead (`phase == "ri-go-ahead"`)
Resumed only by `approve-ri` (also accepted: `approve`, `approve-step 2` while `phase == "ri-go-ahead"`). Record `ri.goAheadAt` / `ri.goAheadBy`, set `phase = "fi"`, Step 2 → `in-progress` (**not** `completed`), audit `{ "event": "ri-go-ahead" }`, continue to 2b.

### 2b — Forward Integration (`phase == "fi"`)
Identical to 2a with: `-Direction FI -SourceBranch <developBranch> -TargetBranch <mainBranch>`, `<fiBranch>`, report `integration-fi.json`, commit message `FI: Merge <developBranch> into <mainBranch> for <releaseTag>`, PR title `FI: <developBranch> → <mainBranch> | <releaseTag> (ZED)`, EventKey `fi-pr-raised`, watcher prompts `... FI PR <prId> ...`. Preserve paths keep `<mainBranch>`'s files. **On FI PR merged**: `fi.status = "merged"`, `phase = "cut"`, **no go-ahead** — continue straight to 2c in the same invocation.

### 2c — Cut (`phase == "cut"`)
Run Step 2 Actions 1–6. Action 1 branches from `origin/CONFIG[ado.baseBranch]` (== `mainBranch`), which now contains the FI merge — always fetch first. The `2-cut-branch` step gate applies after 2c exactly as today. **Deploy-base**: run "Step 2 — Deploy-base build (2c)" instead of Actions 1–3 — the FI merge commit (or anything newer on the deployment branch) is what gets built and deployed.

## Step 2 — Deploy-base build (2c)

`release.releaseMode == "deploy-base"` (BCM): the release deploys `release.currentBranch` (the deployment branch confirmed at setup, default `master`) itself. There is no release branch; the release IS one exact build of that branch, and every later deployment is pinned to it.

1. `$d = Resolve-ReleaseBuild.ps1 -Action DeployCommit -DeployBranch <release.currentBranch>` → the newest commit on the first-parent chain of `origin/<branch>`, skipping the build-version bump commits (`***NO_CI***`), and — because the official build runs on every push (CI) — the official build of exactly that commit if one already exists (succeeded or still running).
2. `$d.BuildId` set → use that build (no duplicate build). Otherwise `Resolve-ReleaseBuild.ps1 -Action QueueBuild -Commit $d.Commit -DeployBranch <branch>` → the official build pinned to that commit (`resources.repositories.self.version`), so a merge landing meanwhile is not picked up.
3. Store `release.json → currentCommit = $d.Commit`, `buildId`, `buildNumber`; audit `{ "event": "deploy-base-build", "commit": "...", "buildId": ..., "reused": <bool> }`. The Step 2 completion email states: deployment branch, commit (sha + subject), build number + link, and the previous release (`previousBuildNumber` / `previousCommit`) — the range Step 4 analyses.
4. Continue with Actions 4–6 (Step 4 inline work + arm the Step 3 build watcher; a reused build that already succeeded completes Step 3 on the first poll).

**Test mode**: resolve the commit as above but trigger the build via `Invoke-TriggerAndCancel.ps1 -Step 2 -SourceBranch refs/heads/<branch>` (instant cancel); `currentCommit` = `$d.Commit`.

### Failure / owner commands
- `Invoke-BranchIntegration.ps1` throws (fetch/push failure, remote branch exists without the source, unresolved conflict) → Step 2 → `failed` with the error, Rule 11 `step-2-failed` email, halt.
- PR **abandoned** (watcher `onFailure`) → Step 2 → `failed` (`"RI|FI PR <id> was abandoned"`).
- `ack retry` → re-run the **current sub-phase** from its step 2 (the script re-uses the remote branch if it still contains the source; a new PR is opened if the old one was abandoned). Step 2 → `in-progress`.
- `ack skip` while `phase` is `ri` / `fi` → mark **only that sub-phase** `skipped`, advance `phase` (ri → fi, fi → cut), Step 2 → `in-progress`; never skips the branch cut. Audit `{ "event": "integration-skipped", "phase": "..." }`.

### Test mode (`release.testMode == true`)
Run 2a and 2b back-to-back **without `-Push`**: the merge + resolution is computed and reported, then discarded — no branch, no PR, no watcher, no go-ahead. Set `ri.status` / `fi.status = "dry-run"` (or `up-to-date`), add an `integration` section to `test-run-capture.json` (`{ ri: { status, conflictCount, preservedFiles, reviewFiles }, fi: { ... } }`), include the two `summaryMarkdown` blocks in the owner-only test summary, and continue to 2c. The FI dry run is computed against today's `developBranch` (the RI merge has not landed), so it is indicative only.

## Step 3: Wait for Build Completion

**Trigger**: Watcher detects build status `completed`
**Actions**:
1. Fetch build result (succeeded/failed) via ADO API
2. If **succeeded**: send transition email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-3-completed'` with build number and duration, advance to next step
3. If **failed**: send failure email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-3-failed'` (default: current-owner-only — owner widens via `routing.3-wait-build.failure`), set step → `failed`, halt for `ack`.Release owner can issue `ack retry` to re-queue the build on the same release branch with the same `templateParameters` (Step 2's queueing logic, but Step 1's branch-creation is skipped because the branch already exists). Any other `ack` aborts the release.
**State**: Step 3 → `completed` or `failed`
**Next**: Proceed to Step 4

## Step 4: Collect & Analyze Commit Details

**Trigger**: Step 2 completed (runs in **parallel** with Step 3 — commit analysis happens while the build is running).

**Execution model (parallelism implementation):** This step is split into two phases — see the Step Dependency Matrix parallelism note for the full rationale.

- **Phase A — Inline (Actions 1–9 below)**: Runs **synchronously inside Step 2's body** right after the build is queued. Generates `commits.xlsx`, uploads to SharePoint, posts the Teams commit-request message. Sets `state.step4InlineCompleted = true` and `state.step4ExcelUrl`. Step 4's status becomes `in-progress` at the end of Phase A (not `completed`, because the team still has to fill the Impact column).
- **Phase B — Side-channel poll**: Runs **inside `Release-Watcher.ps1`'s main loop, opportunistically on every tick**, as long as `state.step4InlineCompleted == true` and `state.steps[4].status == 'in-progress'`. No dedicated `watcherDirective` is needed — the build watcher's polling loop reads the OneDrive Excel and updates `state.step4ExcelImpactPct` on every iteration. When Impact reaches 100 %, the watcher sets `state.steps[4].status = "completed"` and writes a `step4-completed-by-side-channel` audit entry.

**Step 13 fallback**: If Step 12 finishes before Step 4 reaches 100 % (uncommon — Step 6 alone bakes 24 h), Step 13 arms a dedicated `poll-onedrive-file` directive and EXITs. See Step 13.

**Actions (Phase A — executed inline during Step 2)**:
1. Read `repoRoot` from `environment.json` and branch names from `release.json`
2. Run `git -C "{repoRoot}" fetch --all` to ensure branches are up to date
3. Run `git -C "{repoRoot}" log --cherry-pick origin/{previousBranch}..origin/{currentBranch} --pretty=format:"%h%x1f%an%x1f%aD%x1f%s%x1f%b%x1e"` to collect commits (fields separated by US `0x1f`, records by RS `0x1e`). Parse the delimiter-separated output into a list of raw commits with fields: CommitID, Author, Date, Subject, Body.
   > **Range order matters.** `origin/{previousBranch}..origin/{currentBranch}` returns commits reachable from `currentBranch` but NOT from `previousBranch` — the actual release payload. The reverse (`currentBranch..previousBranch`) returns hotfixes on the prior release branch that are NOT in this release; this is the wrong set and was the original spec bug. Always use `{previousBranch}..{currentBranch}`.
   > **Deploy-base releases** (`release.releaseMode == "deploy-base"`): there are no release branches — use the commits instead: `git -C "{repoRoot}" log --cherry-pick {release.previousCommit}..{release.currentCommit} …` (previous release build's commit → this release build's commit, both on the deployment branch). Skip `***NO_CI***` build-version commits.
4. **Analyze each commit**: For every commit, run `git -C "{repoRoot}" diff-tree --no-commit-id --name-only -r {CommitID}` to get the list of changed files. Then classify the commit and write `Title` and `Comments` fields:
   - **Set Title** from the commit Subject — clean up if needed (remove ticket prefixes, trim whitespace).
   - **Classify change type** based on changed file paths:
     - Files under `src/` (excluding test directories) → **Production code change**
     - Files under `**/test/**`, `**/tests/**`, `**/*.Tests.*` → **Test change**
     - Files matching `*.yml`, `*.yaml`, `*pipeline*`, `build/`, `eng/` → **Pipeline/CI change**
     - Files under `.github/`, `copilot-docs/` → **Tooling/docs change**
     - Files matching `*.config`, `*.json`, `*.props`, `*.targets`, `NuGet.config`, `Directory.*` → **Build/config change**
     - If multiple categories apply, list the primary one first
   - **Assess production impact**: A commit is **production-impacting** if it changes files under `src/` (excluding test directories). Otherwise it is **not production-impacting**.
   - **Classify change nature** — determine the intent of the commit for SafeFly DeploymentNature reporting. Use the commit Subject, Body, and changed files to assign one of the 11 SafeFly-aligned nature tags:

     | Tag | SafeFly value | Signals (keywords, file patterns, context) |
     |-----|--------------|---------------------------------------------|
     | `[NewFeature]` | `New feature` | feat, add, implement, introduce, enable, support, new endpoint/workflow/capability |
     | `[BugFix]` | `General bug fixes` | fix, bug, patch, resolve, correct, repair, handle, workaround, regression |
     | `[ConfigChange]` | `Config change` | enabl/disabl/enabling/disabling, turn on/off, config, setting, parameter, threshold, toggle, flag, *.config, "changing the value of" |
     | `[SecurityFix]` | `Critical security fixes` | security, CVE, vulnerability, auth bypass, injection, OWASP, credential fix |
     | `[CRIFix]` | `CRI fixes` | CRI, customer-reported, customer issue, support case, hotfix for customer |
     | `[Monitoring]` | `Monitoring/health signals` | monitor, alert, health, telemetry, logging, diagnostics, metrics, Geneva |
     | `[PolicyChange]` | `Policy change` | policy, compliance, governance, RBAC, access control, audit, SFI |
     | `[SecretsCerts]` | `Secrets/Certificate management` | cert, certificate, secret, key rotation, managed identity, KeyVault |
     | `[SevRepair]` | `Sev 1/2 repair` | sev1, sev2, livesite, repair item, incident, IcM, hotfix for outage |
     | `[OSPatch]` | `OS/Image patch` | "os patch", "os update", "base image", "container image", "runtime update", "image patch" — requires explicit patch/update context, not just the word "os" |
     | `[Other]` | `Other` | refactoring, cleanup, dependency updates, doc-only, test-only, tooling — anything not above |

     **Priority rules**: Security > CRI > Sev repair > Bug (use the most specific match). If truly unclear, prefer `[BugFix]` for changes to existing code and `[NewFeature]` for new code.

   - **Compose the Comments field** as a concise single line (max 200 chars), format: `"[Production-impacting] [NatureTag] <brief description>"` or `"[Non-production] [NatureTag] <brief description>"`. The `[NatureTag]` is one of the 11 tags above. Examples:
     - `"[Production-impacting] [NewFeature] Added retry logic in BackupEngine recovery flow"`
     - `"[Production-impacting] [BugFix] Fixed null reference in service catalog validation"`
     - `"[Non-production] [ConfigChange] Added canary timeout parameter to SFMC pipeline YAML"`
     - `"[Non-production] [Other] Added unit tests for service catalog validation"`
     - `"[Production-impacting] [SecurityFix] Patched auth bypass in DPP token validation"`
     - `"[Production-impacting] [Monitoring] Added Geneva alerting for backup job failure rates"`
5. Write the enriched data to `commits.json` with fields: CommitID, Author, Date, Subject, Comments.
6. Generate `commits.xlsx` via `New-CommitExcel` (5 auto-filled columns: CommitHash, Owner, Date, Title, Comments + 3 manual columns: Impact, Validations, Rollback Friendly).
7. Upload `.xlsx` to SharePoint via `Upload-ToSharePoint`, get sharing URL.
8. Store URL in `release.json.commitExcelUrl`.
9. Post `templates/commit-request-message.html` to Teams (route key `commit-request`) using `Send-TeamsMessage -TemplatePath <path> -TemplateVariables <hashtable>`. The template **requires all six** placeholders below — populate every one or the message will render with literal `{{...}}` text and a broken link:
   - `releaseId` — from `release.json → releaseId`
   - `commitCount` — total rows in `commits.json`
   - `contributorCount` — distinct count of `Author` values in `commits.json`
   - `prevBranch` — from `release.json → previousBranch`
   - `currentBranch` — from `release.json → currentBranch`
   - `excelUrl` — the SharePoint sharing URL stored in step 8 (`release.json → commitExcelUrl`)

   Before sending, verify the rendered body contains no `{{` substring; if any remain, fix the variable map and re-render rather than sending a broken message.

**Tracker mode (`CONFIG[commitExcel.mode] == "tracker"`, e.g. BCM)** — the team keeps ONE shared workbook (`CONFIG[commitExcel.tracker.url]`) with one sheet per release. Actions 1–5 are unchanged; **replace Actions 6–9** with:
- 6T. Run `Invoke-CommitTracker.ps1 -Action Publish -ReleaseId <id> -CommitsJsonPath <commits.json> -ReleaseFile <release.json>`. It works on the sheet named `CONFIG[commitExcel.sheetNameTemplate]` (e.g. `BCM{{YYMM}}` → `BCM2611`; with `CONFIG[releaseNaming]` use `{{releaseName}}` → one sheet per release: `BCM2610`, `BCM2610_2`):
  - sheet missing → created at the end of the workbook with the configured header row, styling and column widths;
  - sheet present (e.g. the team created it) → **adopted** if its row 1 has every configured column (matching ignores spaces/case; `aliases` accepted), otherwise Publish throws and writes nothing;
  - then **appends** one row per commit not already on the sheet (matched by PR id / commit sha in the link column), sorted by date: `Date`, `Author`, `PR/Commit Link` (`=HYPERLINK(<PR url>, "Pull Request <id>: <title>")`, or `Commit <sha>: <subject>` for a direct push), `Description of Changes` (the Comments line from Action 4 — authors may rewrite it), and empty team-filled columns. `excludeAuthors` are dropped.
  - It **never modifies an existing row or cell** and never re-uploads the file (edits go through the Graph Excel API in a workbook session), so co-authors' work in any sheet is safe. Re-running is a no-op; `rebuild` / late cherry-picks only add their new rows.
- 7T. Store `release.json.commitExcelUrl = CONFIG[commitExcel.tracker.url]`, `release.json.commitExcelSheet = <sheetName>`, and `state.step4Tracker = { sheetName, driveId, itemId }` (from the Publish result); set `state.step4ExcelUrl` to the same URL (the side-channel gate and nudge use it).
- 8T. Post `templates/commit-tracker-request-message.html` (route key `commit-request`) with `serviceName` (`CONFIG[service.displayName]`), `releaseId`, `sheetName`, `commitCount` (rows on the sheet = `TotalRows`), `contributorCount`, `prevBranch`, `currentBranch`, `excelUrl` (tracker URL) and `columnsToFill` (the `required: true` headers joined with `, `). Same no-`{{` check.
- Completion (Phase B) = **every row with a link has all `required: true` columns filled** (BCM: Risk Assessment, Testing Done, IsChangeUnderConfig) — the side-channel calls `Invoke-CommitTracker.ps1 -Action Poll` instead of downloading the file; `state.step4ExcelImpactPct` holds that fill %. The 24 h nudge uses `templates/commit-nudge-message.html` with the tracker URL.
- **Test mode**: Publish returns `skipped-test-mode` and writes nothing to the shared tracker — use the per-release flow above (Actions 6–8 with test-mode auto-fill, owner-only) so the test run still produces an Excel.
- Failure (Graph 401/403/404, header mismatch, locked workbook after retries) → Step 4 `failed` with the error and the manual fallback: add sheet `<sheetName>` by hand, then `ack retry` (Publish adopts it).
**State**: Step 4 → `in-progress` after Phase A completes (during Step 2). Transitions to `completed` automatically when the watcher side-channel detects 100 % Impact fill (tracker mode: 100 % of required columns).
**⚠️ Test Mode Override**: When `testMode` is `true`, auto-fill the manual columns (Impact = "Low", Validations = "CanaryTesting", Rollback Friendly = "Yes") for all rows. Skip the side-channel poll — mark Step 4 as `completed` immediately after upload. No Teams commit-request message (test mode suppresses Teams). **When `commitCount` is 0 (no commits on the branch), skip Excel creation and upload; instead set `release.json.commitExcelUrl = 'test-run:no-commits'` as a placeholder so the verifier can confirm the field was written.**
**Watcher (Phase B side-channel — no dedicated directive)**: `Release-Watcher.ps1` polls the uploaded Excel on SharePoint every `CONFIG[operational.watcherPollIntervalSeconds]` (default 1 hour) **as a side-channel inside whatever directive is currently active** (typically `poll-ado-build` during Step 3, then `poll-ado-pipelines` during Step 5). The watcher reads the Excel via Graph API + ImportExcel and counts how many rows have the **Impact** column filled (non-empty). Completion condition: **100 % of Impact cells are filled**.
- On each poll: update `state.step4ExcelImpactPct`, log fill percentage to `audit.jsonl` as event `step4-side-channel-poll`
- When 100 % filled → set `state.steps[4].status = "completed"` and log `step4-completed-by-side-channel`
- If no progress after **24 hours** (computed from `state.step4InlineCompletedAt`), send a reminder nudge to Teams using `templates/commit-nudge-message.html` (includes fill progress, pending contributors, and SharePoint link). The watcher sets `state.step4NudgeSentAt` to avoid duplicate nudges.
**Next**: Step 13 (Create R2D) waits for **both** Step 12 and Step 4 to complete — ensuring the team has reviewed commit impact before the R2D is created. If Step 4 is still `in-progress` when Step 13 fires, Step 13 arms a dedicated `poll-onedrive-file` directive and EXITs (see Step 13). In test mode, Step 12 is `skipped` (satisfies dependency) and Step 4 auto-fills (completes immediately).
**Failure**: Git/SharePoint/upload failure → `failed`, notify, halt

## Step 5: Deploy Canary

**Trigger**: Step 3 completed (build done). Step 4 (commit analysis) runs in parallel and is NOT a prerequisite for canary.
**Private stamp side track**: When `CONFIG[pipelines.privateStampUpgrade.enabled]` is `true`, the **first** thing Step 5 does (before any canary work, every entry — it is idempotent) is `Invoke-PrivateStampUpgrade.ps1 -Action Init -ReleaseId <id>`; if it returns a `NotifyEvent`, send that email (see "Private stamp upgrade test" below). It never blocks or delays the canary actions that follow.
**Canary schedule guard**: Canary pipelines with `scheduleGuard` (BCM-EACAN → UI schedule trigger + `enableSchedule`, foreign runs cancelled) get their own scheduled/ad-hoc deployments paused as soon as **ZED's Step 5 run of that pipeline succeeds** — done by the watcher side-channel, and re-checked by the agent when Step 5 completes (`Invoke-ScheduleGuard.ps1 -Action Sync`). See "Canary schedule guard" below.
**⚠️ Test Mode Override**: When `testMode` is `true`, resolve the trigger set + REAL params as normal, then call `Invoke-TriggerAndCancel.ps1 -Step 5` **once per resolved pipeline** (instant cancel + capture) instead of triggering + polling. Skip the EV2 approval-link scan. See "Test Mode Overrides → Step 5".
**Actions**:
1. Read `pipeline-catalog.json → canaryRouting` (default `{ mode: "static" }` if absent):
   - **`mode: "static"`** — skip Kusto. Trigger EVERY entry under `canary.*` in parallel. Pass each entry's `templateParameters` to ADO verbatim.
   - **`mode: "cluster-type"`** — run the cluster-type routing sub-procedure below. **Kusto is mandatory in this mode**: if the query fails, the step MUST halt with `failed` and emit the owner-only step-transition email per Behavior Rule 11. Do NOT silently fall back to triggering everything — that is what caused the PROT 2026-05 mis-routing.

   ### Cluster-type routing sub-procedure (used by Steps 5, 7, 10)

   > **Key insight**: cluster type is a property of the **pipeline**, not of the stamp short name. `ea-01` in `PROT-SFRP` always means an SFRP stamp (because that pipeline only deploys SFRP); the same short name in `PROT-SFMC` always means an SFMC stamp. The agent never translates short names to physical Kusto `StampName`s and never filters stamp lists at runtime. Kusto's runtime role is **pipeline selection only** — it returns the set of cluster types currently in canary, which resolves to a set of pipeline keys via `clusterTypeMap`. Each selected pipeline's `templateParameters` (collected and confirmed at `setup-service` time) are passed to ADO **verbatim**. Safety of the deployment therefore depends entirely on `pipeline-catalog.json` being correct.

   a. **Pipeline selection via the resolver** — invoke `.github/skills/zed-agent/scripts/Resolve-PipelinesByClusterType.ps1 -Scope canary` (Step 10 and Step 15 pass `-Scope production`). Cluster type is a pipeline-level attribute, so the resolver runs **once per scope per release**, not once per cloud — a production pipeline that targets multiple clouds in `ev2CloudCoverage.<key>` is still resolved by a single query. As of Layer 2 (capability B), the resolver delegates Kusto execution + ASC join to `Get-StampInventory.ps1` and returns `{ resolved, skipped, liveClusterTypes, stamps, drift, inventorySources, queryRanAt }`. `stamps` is the per-stamp evidence row for every entry that survived ASC validation; `drift` lists every stamp the inventory could NOT validate (bad grammar, serviceTag mismatch, layout unknown to ASC, shortName not in the resolved cloud, canary cloudHint mismatch, etc.). On any token error, **first** invoke `.github/skills/zed-agent/scripts/Repair-AzAuth.ps1 -Tenant 'microsoft.com' -Resource <kusto.{scope}.cluster>` (3-attempt cascade: interactive login → WAM-disable + retry → device-code), then re-invoke the resolver once; if it still throws, mark the step `failed` — do not proceed.

   a.1. **Drift halt (Layer 2 + Layer 3 — Steps 5, 7, 10, 15)** — the resolver throws with message prefix `DRIFT_HALT:` followed by the drift list whenever `Get-StampInventory` reports any drift row in `cluster-type` mode. The agent MUST handle this by invoking the centralised handler:

      ```powershell
      try {
          $res = & .github/skills/zed-agent/scripts/Resolve-PipelinesByClusterType.ps1 -Scope $scope
      } catch {
          if ($_.Exception.Message -like 'DRIFT_HALT:*') {
              & .github/skills/zed-agent/scripts/Invoke-DriftHalt.ps1 `
                  -ReleaseId $releaseId -StepNumber $stepNumber -StepName $stepName `
                  -Scope $scope -ResolverError $_.Exception.Message `
                  -Branch $branch -ReleaseOwner $releaseOwnerAlias
              return  # halt the step
          }
          throw
      }
      ```

      `Invoke-DriftHalt` performs the full protocol in one call:
      1. Parses drift rows from the resolver exception message.
      2. Flips `state.json → steps[$n].status` to `failed-drift` and attaches `steps[$n].driftPayload = { haltedAt, scope, count, rows[] }` via `Update-ReleaseState` (single state lock).
      3. Writes `audit.jsonl` row `{ "event": "drift-halt", "step": <n>, "scope": "<scope>", "drift": [ { stampName, reason, source } ] }`.
      4. Resolves Teams recipients via `Resolve-NotificationRecipients -EventKey "step-<n>-failed"` and posts `.github/skills/zed-agent/templates/drift-halt-message.html` (rendered with the drift table) to every resolved conversation.

      After `Invoke-DriftHalt` returns, the agent MUST NOT trigger any pipelines for this step. It MUST send the owner-only step-transition email per Behavior Rule 11 (subject: "🛑 Drift halt — Step {n} — release halted"; body summarises the drift count and links to the Teams thread). The release then waits in `failed-drift` until the owner replies in the Teams thread.

      **Owner reply commands** (recognised by the agent on re-entry; see "Owner Commands" section):
      - `mitigated` — owner has edited `service-config.json → inventory.canary.stamps` (canary) or fixed the Kusto query / `kusto.production.clusterTypeExtraction` (production). The agent re-runs the step normally; the resolver re-validates and proceeds if drift has cleared. If the resolver throws `DRIFT_HALT:` again, `Invoke-DriftHalt` re-fires with the new drift list.
      - `approve drift` — owner explicitly approves the current drift. The agent re-runs the step with `-IgnoreDrift` on the resolver call. An additional `audit.jsonl` row `{ "event": "drift-approved", "step": <n>, "scope": "<scope>", "approver": "<alias>", "originalDrift": [...] }` MUST be written before triggering pipelines.

      Drift only halts in `cluster-type` mode. In `static` mode the resolver still attaches `stamps` / `drift` to its output (best-effort), but these are informational — Steps 5/10/15 should still surface them in the Teams summary message but do not halt and do not invoke `Invoke-DriftHalt`.

   b. **Trigger set = `resolved` from the resolver output.** Each entry has `{ pipelineKey, clusterType, source: "kusto-resolved", evidence }`. Cluster types with no `clusterTypeMap` entry, and `clusterTypeMap` entries referencing keys missing from `{scope}.*`, appear in `skipped` with a `reason` field — log them at warn level. The resolver also surfaces `{scope}.*` entries whose declared `clusterType` is NOT in the live set as `skipped` with `reason: "no live cluster type matched at query time"`; those pipelines are deliberately omitted from the trigger set (this is the whole point of `cluster-type` mode). If the resolver throws because the live set is empty, halt the step — do not silently trigger nothing or everything.

   c. **Audit log entry** — write to `audit.jsonl` before triggering. Required fields:
      ```json
      { "event": "cluster-type-routing",
        "step": 5,
        "kustoClusterTypes": ["sfmc","sfrp"],
        "triggeredPipelines": [
          { "key": "PROT-SFRP", "clusterType": "sfrp",
            "params": { "CanarystampsProd": ["ea-01","ecy-01"] } },
          { "key": "PROT-SFMC", "clusterType": "sfmc",
            "params": { "CanarystampsProd": ["ccy-01"] } }
        ],
        "skippedDueToNoMapping": [] }
      ```
      This audit row is the single source of truth for what was triggered and is reused by Step 7 (Rollback).

2. Trigger all resolved pipelines in **parallel** with their `templateParameters` (passed verbatim from `pipeline-catalog.json`).
   **Deploy-base build pinning (Steps 5, 7, 10, 15)**: when `release.releaseMode == "deploy-base"`, `ArtifactsBranch` = the deployment branch (e.g. `master`), whose newest build changes whenever anything merges — so EVERY canary/production run request MUST also carry `resources.builds`: `$pin = Resolve-ReleaseBuild.ps1 -Action PinResources -BuildId <build> -PipelineKey '<canary|production>:<key>'` and post `resources = @{ repositories = @{ self = @{ refName = <sourceBranch> } }; builds = $pin.Resources.builds }` (in test mode pass `-BuildResources $pin.Resources.builds` to `Invoke-TriggerAndCancel.ps1`). `<build>` = `release.buildId` for Steps 5, 10, 15 (and Step 7's rollback build — see Step 7). If PinResources throws (build not in the feed / not succeeded), mark the step `failed` — never trigger unpinned. Record `$pin.VersionName` with each run id in `triggeredPipelines` and in the audit row.
   **ATOMICITY**: Before triggering, write `pipelineTriggerTimestamps.step5` and `triggeredPipelines.5` to `state.json` via `Update-ReleaseState -StateProperties @{ ... }`. After trigger, update `triggeredPipelines.5` with actual run IDs.
3. **Record pipeline trigger timestamp**: Save `pipelineTriggerTimestamps.step5 = <current UTC ISO 8601>` to `state.json` via `Update-ReleaseState` (already done in Action 2's pre-trigger write)
4. Email notification via `SendEmailWithAttachments` MCP tool: "Canary deployment started" — resolve recipients via `Resolve-NotificationRecipients -EventKey 'step-5-completed'` (this is part of the Step 5 → Step 6 transition email per Behavior Rule 11; do not emit a separate "canary started" broadcast).
4a. **Per-pipeline stamp summary** (Layer 3 — narrative addition): for each triggered pipeline key, call `Get-StampsForPipeline -PipelineKey $key -Scope canary` (Step 5/7) or `-Scope production` (Step 10/15) to expand the pipeline → stamp list, and render it into the Teams summary message under a "Deploying to" column. Format: `<pipelineName>: stamp1, stamp2, …` (or `(all routed stamps)` if the call returns the full set). This makes it visually obvious which DCs each pipeline will actually hit — caught a misrouted pipeline twice in dry-runs.
5. **Approval requests**: right after triggering, run `Invoke-ApprovalWatch.ps1 -Action Sync -ReleaseId <id>` once (and send any returned `NotifyEvents` — see "Approval requests" below); from then on the watcher checks every `CONFIG[operational.approvalPollIntervalSeconds]` (600 s). Any run that stops on the OneBranch **Approval Service** (or an ADO approval check) gets an email + Teams message with the approval link, reminders, and an expiry alert. Do **not** post approval links by hand.
6. Watcher polls all triggered pipeline runs every 1 hour
**Watcher**: `{ action: "poll-ado-pipelines", targets: ["<run1>", "<run2>", ...], pollIntervalSeconds: CONFIG[operational.watcherPollIntervalSeconds], teamsChatName: "<first entry from CONFIG[notifications.groups.teamsExtended]>" }`
**Watcher approval detection**: handled for every watched run by the approval side-channel (`Invoke-ApprovalWatch.ps1`) — see "Approval requests".
**EV2 deployment done**: canary pipelines with `deploymentDoneWhen` (BCM-CANARY → `Canary-ManagedValidation`) count as done once EV2 reports every canary regional deployment stage succeeded — do not wait for `*-ManagedValidation` to start or finish. The run itself keeps going for ~24 h. See "EV2 deployment done (deploymentDoneWhen)".
**Completion**: All triggered pipelines succeed (or are `deployed` per EV2) → record `state.ev2DeployedRuns.5` (see "EV2 deployment done") and send transition email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-5-completed'`: "Canary deployment completed" — for a `deployed` run say "deployed to all canary regions at {deployedAt}; EV2 {validationStep} status {validationStatus} (EV2 link {portalUrl}); validation need not start or finish before BVT; the pipeline run finishes after it".
**Failure**: Any pipeline fails → step `failed`, send failure email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-5-failed'` (default: current-owner-only — owner widens via `routing.5-deploy-canary.failure`), halt for `ack`

## Private stamp upgrade test (side track: Step 5 ∥ canary → joined at Step 13)

Runs only when `CONFIG[pipelines.privateStampUpgrade.enabled] == true` (BCM). It deploys the **last** build and **this release's** build side by side on one private stamp instance — **both deployments in parallel** — using the private stamp pipeline (`CONFIG[pipelines.privateStampUpgrade.id]`). When **both** succeed it runs the BVT release (`CONFIG[pipelines.privateStampUpgrade.bvtRelease]`, BCM: classic release definition 64863 `IaaSVM-BVT-Private-Stamp`) against the owner's redirected vault, then waits for the release owner's sign-off. It runs in parallel with Steps 5–12 and never blocks them; **Step 13 is its only join point**.

All transitions go through `scripts/Invoke-PrivateStampUpgrade.ps1` (never queue these runs or create the BVT release by hand). State: `state.privateStampUpgrade` (status, inputs, runs.last, runs.current, runs.bvt, failedLegs, bvtOutcome — see the script header).

| Status | Meaning | Advanced by |
|--------|---------|-------------|
| `awaiting-input` | Owner asked for inputs | owner `private-stamp` |
| `inputs-ready` | Inputs stored; waiting for Step 3's build | watcher Poll (queues **both** legs once Step 3 is `completed`) |
| `deploying` | Both legs running: *last* (owner's last-build branch on **port 1**) and *current* (`release.currentBranch` on **port 2**) | watcher Poll (waits until **both** finish) |
| `bvt-running` | Both legs succeeded; BVT release running with `PrivateStampVaultId` = the owner's vault | watcher Poll (waits for the `bvtRelease.environmentName` stage) |
| `awaiting-bvt` | BVT stage finished `succeeded` / `partiallySucceeded` — owner reviews the BVT results | owner `approve-private-stamp` |
| `signed-off` / `skipped` | Done — Step 13 may proceed | — |
| `failed` | `failedLegs` ⊆ {last, current, bvt}: a leg failed to queue/deploy, or the BVT stage ended `rejected`/`canceled`/never started | owner `private-stamp retry` (re-runs only what failed) / `private-stamp` (new inputs) / `private-stamp skip`; with only `bvt` failed, `approve-private-stamp` signs off anyway (recorded as `signedOffDespiteBvt`) |

**Owner inputs** — asked **every release**, never re-used from a previous release. Collected by the `private-stamp` command (see `command-behaviors.md`): private stamp **instance** (e.g. `A`), **port 1** (last build), **port 2** (current build), **last build** = a **build link** (`…/_build/results?buildId=<id>`) or build id of the previous deployment's official build — with `privateStampUpgrade.artifact` configured (BCM) the deployment is pinned to exactly that build (newer builds on its branch are never used) and its branch becomes `ArtifactBranch`; without `artifact`, a branch name whose latest build is deployed, the **TeeWorkflowQueueName**, and the **redirected vault ARM id** (`/subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.RecoveryServices/vaults/<name>` — the vault redirected to one of the two ports; required when `bvtRelease` is configured). In deploy-base releases suggest `release.previousBuildId` (the build the previous production rollout deployed) as the default *last build*. The current build is always this release's build: with `artifact` it is pinned to `release.json → buildId` (the Step 2/3 build) when the legs are queued — if that build is not yet in the artifact feed, the track waits (`waitingFor`) and fails after 6 h; without `artifact`, the latest build of `release.currentBranch`.

**Deployment payload** (both legs, queued together, same YAML ref `CONFIG[...privateStampUpgrade.sourceBranch]` → `refs/heads/<release.currentBranch>`): `CONFIG[...privateStampUpgrade.templateParameters]` verbatim plus `PrivateInstance = <instance>`, `WebRolePort = <port 1 | port 2>`, `ArtifactBranch = <the pinned build's branch | release.currentBranch>`, and — with `artifact` — `resources.builds.<artifact.resourceAlias>.version = <pinned version id>` (the build id mapped to its version via `POST vsrm …/_apis/Release/artifacts/versions` for feed `<artifact.feedBranchPrefix><branch with / - . → _>`; verified live: a run queued this way consumed exactly the pinned build), `ServiceOverrideSettings = @{"BCMAppConfig->WorkflowQueueName"="<queue>";}` (from `serviceOverrideSettingsTemplate`). The script validates: ports 1024–65534 and at least `portSpan` apart (BCM: 2 — HTTP is HTTPS + 1), queue name `[A-Za-z0-9._-]`, last build: an official build (`artifact.buildDefinitionId`) that completed successfully, is present in its feed, and is not this release's build; vault id is a Recovery Services vault ARM id.

**BVT release** (after both legs succeeded): `POST vsrm …/_apis/release/releases` for `bvtRelease.definitionId` with `isDraft: false`, every artifact's **latest version passed explicitly** (from `…/artifacts/versions` — an unresolved artifact would start the release without bits), and variables `bvtRelease.variables` (optional fixed overrides) + `<bvtRelease.vaultIdVariable>` (`PrivateStampVaultId`) = the vault id. All other release variables keep their definition defaults (BCM: `VaultLocation=eastasia`, `TestsToRun=SupportedTests`). Completion = the `bvtRelease.environmentName` stage (`IaaSVM BVT Private Stamp`) reaches a final state. `partiallySucceeded` is the normal outcome for this BVT and is **not** treated as a failure — the owner judges the results.

**Notifications** — `Invoke-PrivateStampUpgrade.ps1` returns `NotifyEvent` exactly once per transition; the agent (or the watcher prompt `private stamp upgrade <event> for release <id>`) sends ONE email via `Resolve-NotificationRecipients -EventKey <event>` (default current-owner-only; widen via `routing.5-deploy-canary.halt|failure`):
- `private-stamp-input-needed` — subject `🧪 Private stamp upgrade test — inputs needed | {releaseId}`. Body: what is needed (instance, port 1 for last build, port 2 for current build, last build branch, TeeWorkflowQueueName, redirected vault ARM id), the reply format (`private-stamp` in ZED chat — interactive — or one line `private-stamp instance=A lastPort=10060 currentPort=10062 lastBuild=<build link> queue=<name> vault=<vault ARM id>`), and that canary continues meanwhile but **Step 13 (R2D) waits** for this test.
- `private-stamp-bvt-ready` — subject `🧪 Private stamp BVT finished ({bvtOutcome}) — instance {instance}, ports {port1}/{port2} | {releaseId}`. Body: both deployment run links + results, the BVT release link (`runs.bvt.url`), per-stage results (`runs.bvt.stages`), the vault used, and *"Review the BVT results, then reply `approve-private-stamp` (or `private-stamp skip <reason>`)."* — when `bvtRelease` is not configured: *"Run BVT on the private stamp, then reply `approve-private-stamp`."*
- `private-stamp-failed` — subject `❌ Private stamp upgrade test failed ({failedLegs}) | {releaseId}`. Body: `error`, the run / BVT release links, and the options (`private-stamp retry` — re-runs only the failed part, `private-stamp` with new inputs, `private-stamp skip <reason>`, and for a BVT-only failure `approve-private-stamp` to sign off anyway).

**Polling** — `Release-Watcher.ps1` and `Invoke-ColdResume.ps1` call `-Action Poll` on every tick while the status is `inputs-ready`, `triggering*`, `deploying`, `bvt-running` or `retrying`, independent of the primary `watcherDirective` (same co-located side-channel pattern as Step 4). The watcher only invokes the agent when `NotifyEvent` is set. A cold-resume verdict with `PrivateStampSideChannel.NotifyEvent` means the session must send that email.

**Test mode** — `Init` creates the track as `skipped` (`skipReason: test-mode`): no owner input, no deployment, no BVT release, no wait. Step 13's join is satisfied.

## Canary schedule guard (Step 5 success → Step 6 sign-off)

Some canary pipelines also deploy on their own — BCM-EACAN (391732) runs `develop` Sun–Thu at 23:00 IST from a **UI schedule trigger** (Pipeline → Edit → Triggers), and teams queue ad-hoc `develop` runs — which would overwrite the release bits on the canary stamps while Step 6 BVT is evaluating them. Configure per canary pipeline in `pipeline-catalog.json` (any combination; at least one of `pauseScheduleTriggers` / `variable`):

```json
"canary": { "BCM-EACAN": { ..., "scheduleGuard": {
    "pauseScheduleTriggers": true,
    "variable": "enableSchedule", "disabledValue": "false", "enabledValue": "true",
    "cancelForeignRuns": true } } }
```

- **`pauseScheduleTriggers`** — remove every `schedule` trigger from the definition (saved verbatim in `triggersRemovedJson`) and re-add exactly those on restore. **YAML pipelines**: ADO ignores the YAML `schedules:` cron only while a UI schedule exists — once ZED deletes it, the YAML cron runs instead (BCM EA-CAN's YAML has `cron: "30 17 * * *"` on develop and master). ZED checks the YAML on the scheduled branch and puts a `warning` on the disable result when it still has a cron; `cancelForeignRuns` then cancels those runs.
- **`variable`** — a **definition variable** (Pipeline settings → Variables) that gates the pipeline's first stage (`condition: eq(variables['enableSchedule'], true)`). Because it gates **every** run, a ZED-triggered run while it is `false` is silently skipped. With `pauseScheduleTriggers` the variable is optional at runtime — skipped (noted) when it is not defined on the pipeline.
- **`cancelForeignRuns`** — while the guard is active (status `disabled` / `preexisting` / `disable-failed` / `restore-failed`, Step 6 not yet completed/skipped), cancel every queued/running run of the pipeline that ZED did not queue (any run id in `triggeredPipelines.*`, plus `disabledByRunId` / `awaitRunId`): manual develop runs, cron runs. A run queued **before** ZED's Step 5 run (e.g. a run stuck `notStarted` for weeks) is cancelled only once it actually starts. Cancelling needs only **Stop builds**, so it still protects the canary when the definition edit failed for lack of **Edit build pipeline**. A develop run needs ~20 min to reach `Test: Deploy Service`; the watcher runs the guard every `CONFIG[operational.scheduleGuardPollIntervalSeconds]` (default 300 s, also during its sleep).

Invariant: **ZED never triggers a guarded pipeline while ZED has it disabled.**

All changes go through `scripts/Invoke-ScheduleGuard.ps1` (read definition → change only the schedule triggers and/or that variable → ONE PUT with revision retry; `-Preview` returns the body without sending and lists `would-cancel` runs). State: `state.scheduleGuards.<key>` = `{ status: disabled | restored | preexisting | armed | disable-failed | restore-failed, guards, originalValue, variableChanged, triggersRemovedJson, schedules, warning, note, disabledByRunId, windowStart, disabledAt, restoredAt, restoreReason, schedulesRestored, cancelledRuns[{ runId, buildNumber, sourceBranch, reason, requestedFor, requestedForEmail, url, status: cancelled | cancel-failed, at, error }], revision, error }`.

| When | What | Who |
|------|------|-----|
| ZED's Step 5 run of `<key>` (a run id in `state.triggeredPipelines.5` for that definition) completes **succeeded** | schedule trigger(s) removed and/or `<variable>` := `disabledValue` (status `disabled`). Nothing to change (no schedule trigger, variable already `disabledValue`) → `preexisting` (ZED will not touch it again). Failed/cancelled runs never disable — so test mode (runs cancelled at trigger) never disables either. | watcher / cold-resume `-Action Sync`; agent `-Action Sync` when Step 5 completes |
| Guard active, a run ZED did not queue appears | cancelled (`schedule-guard-run-cancelled`) | watcher `-Action Sync` every `scheduleGuardPollIntervalSeconds` |
| Step 6 BVT signed off (`approve-bvt`) | saved schedule trigger(s) re-added and/or `<variable>` := `enabledValue` (status `restored`) — only what ZED changed; a schedule someone already re-added / a variable already changed back is left as is (`note`) | agent `-Action Restore -Reason approve-bvt` |
| Step 6 `completed`/`skipped` by any other path (`approve-step 6`, `ack skip`, `skip 6`, gate) | same restore (safety net) | watcher `-Action Sync` |
| Before Step 7 triggers | restore; halt Step 7 if it fails | agent `-Action Restore -Reason step-7-pre-trigger` |
| `rebuild` re-queues a guarded pipeline before Step 6 sign-off | restore before queueing, then `-Action Rearm -RunId <new run>` → status `armed`: disabled again only when **that** run succeeds (never on the older Step 5 run, whose success would otherwise skip the new run's gated stage) | agent (`rebuild`), then watcher `Sync` |
| `teardown` | restore anything still disabled | agent `-Action Restore -Reason teardown` |

**Notifications** — every `.NotifyEvents` entry (`"<event>:<pipelineKey>"`, run events `"<event>:<pipelineKey>:<runId>"`) is ONE email (`Resolve-NotificationRecipients -EventKey <event>` → unmapped → current owner only); the watcher invokes the agent with `schedule guard <event> <key> [run <runId>] for release <id>`. Read the details from `state.scheduleGuards.<key>` (and `cancelledRuns[]` for run events). `{what}` = what was paused: `schedule trigger ({schedules})` and/or `{variable}=false`.
- `schedule-guard-disabled` — `⏸ {key} daily deployments paused | {releaseId}` — "Paused after Step 5 run {disabledByRunId} succeeded: {what}. The daily develop run and ad-hoc runs cannot replace the release bits before BVT sign-off{; runs ZED did not queue are cancelled}. ZED restores it on `approve-bvt`." Include `warning` (YAML cron) and `note` when set.
- `schedule-guard-preexisting` — `ℹ {key} was already paused | {releaseId}` — nothing to change (`note`); ZED will not re-enable anything. Foreign runs are still cancelled.
- `schedule-guard-restored` — `▶ {key} daily deployments resumed | {releaseId}` — what was restored (`schedulesRestored`, `{variable}=true`); include `note` if something had been changed outside ZED.
- `schedule-guard-run-cancelled` — `🛑 {key} run {runId} cancelled — canary BVT in progress | {releaseId}` — To: owner **plus `requestedForEmail`** (the person who queued it; empty for service identities such as scheduled runs — then owner only). Body: run link, branch, reason (`manual` / `schedule`), queued by, and "Release {releaseId} bits are on the {key} stamps until canary BVT is signed off; {key} runs resume after `approve-bvt`. Ask the release owner if you need an exception."
- `schedule-guard-cancel-failed` — `⚠ Could not cancel {key} run {runId} | {releaseId}` — owner only; include the error and the run link (cancel by hand — needs Stop builds).
- `schedule-guard-failed` — `⚠ Could not pause/resume {key} | {releaseId}` — include the error (e.g. TF50309 = missing **Edit build pipeline** on the pipeline — get the permission, ZED retries every tick), the pipeline link `https://dev.azure.com/CONFIG[ado.organization]/CONFIG[ado.project]/_build?definitionId={id}` → Edit → Triggers (remove / re-add the schedule: `{schedules}`) and Variables (`{variable}`), and — for a failed disable with `cancelForeignRuns` — that ZED keeps cancelling runs it did not queue meanwhile. Retried every tick; the email is not repeated for the same error.

Failures never fail Step 5 or Step 6; a failed **restore** halts Step 7 (see Step 7 pre-trigger).

## Approval requests (all deployment runs)

Canary (Step 5), rollback (Step 7), roll-forward (Step 10), production (Step 15) and private stamp runs stop on the **OneBranch Approval Service** (job `ApprovalService`, task `Approval service`) until someone approves at `https://approval.azengsys.com/approvalRequest?id=…`. ZED finds these waits and sends the link out — owners never have to dig through ADO logs.

`scripts/Invoke-ApprovalWatch.ps1 -Action Sync` (watcher + cold resume, every `CONFIG[operational.approvalPollIntervalSeconds]`, default 600 s — also during the watcher's hourly sleep):
- **Watched runs**: every run id in `state.triggeredPipelines.<N>` (record them at trigger time in Steps 5, 7, 10, 15), `watcherDirective.targets[].buildId`, and the private stamp runs. Completed runs are remembered in `state.approvalWatch.doneRuns` and not re-read.
- **Detected**: an `Approval service` task still `pending`/`inProgress` → link from its `Waiting for Approval` log, plus the task expiry (`Approval Task will expire on …`, ~5 days); stages that share one approval request (e.g. PROD/FF/MC) are one request. ADO environment approvals (`Checkpoint.Approval` in progress) → link = the run page. Other checks (e.g. `Checkpoint.ProductionReadinessCheck`) are not approvals and are ignored. Verified on BCM canary run 186266333 (Release-2610-12): link `…approvalRequest?id=BD73B6DD5C88431EAA170B044C9B28E7`, stage `PROD: Managed SDP Deployment`, expiry 2026-10-22 04:18 UTC.
- **State**: `state.approvalRequests.<id>` (id = 8-hex) with kind, url, run, pipeline, step, stages, waitingSince, expiresAt, status (`pending` / `approved` / `ended`), notifyCount, lastNotifiedAt, and the rendered `lastMessage { event, eventKey, subject, html }`.

| Event | When | Subject |
|---|---|---|
| `approval-needed` | first time a pending approval with a link is seen | `🔐 Approval needed — <pipeline> \| <service> <releaseId>` |
| `approval-reminder` | still pending `CONFIG[operational.approvalReminderHours]` (4 h) after the last message | `⏰ Reminder #n: approval still pending — …` |
| `approval-expiring` | ≤ `CONFIG[operational.approvalExpiryWarnHours]` (12 h) before the approval task expires (once) | `⚠️ Approval expires soon — …` |
| `approval-failed` | the approval task ended without approval (rejected / expired / canceled) | `❌ Approval task ended (<result>) — …` — restart the stage |
| — | approved | audit `approval-approved` only |

**Sending** — the watcher invokes the agent with `approval <event> <id> for release <releaseId>`. The agent then: reads `state.approvalRequests.<id>.lastMessage`; resolves recipients with `Resolve-NotificationRecipients -EventKey <lastMessage.eventKey> -Config $cfg -Release $release -Secrets $secrets` (routing row `notifications.routing.approval-requests` — `halt` for needed/reminder/expiring, `failure` for failed; owner always included; test mode → owner only, no Teams); sends ONE email via `SendEmailWithAttachments` (`subject`, `html` body, `contentType: "HTML"`) to `EmailTo`/`EmailCc`; and posts the same `html` with `Send-TeamsMessage -ConversationId <id> -Body <html>` to every `TeamsConversationIds` entry. Send the stored message verbatim (template `templates/approval-service-request.html`) — do not re-compose it — then EXIT. A send failure is retried by re-running the owner command `approvals resend <id>`.

**Test mode**: runs are cancelled within seconds, so the side-channel does nothing.

## EV2 deployment done (deploymentDoneWhen)

BCM-CANARY's run (`Managed SDP Deployment` → `Ev2Agentless` / `Rollout Progress`) stays **in progress for ~24 h after the bits are deployed**: EV2 runs `Canary-ManagedValidation` (bake time + health checks) before the rollout — and the run — complete. Waiting for the run would put Step 6's 24 h BVT window *after* that, ~48 h in total. Instead, configure the pipeline in `pipeline-catalog.json`:

```json
"canary": { "BCM-CANARY": { ..., "deploymentDoneWhen": { "ev2StepStarted": "Canary-ManagedValidation", "portalLinkTask": "Ev2 Managed SDP Region Agnostic" } } }
```

`scripts/EV2/Get-Ev2DeploymentProgress.ps1 -RunId <run> -StepName <ev2StepStarted> -PortalLinkTask <portalLinkTask>`:
1. Reads the EV2 portal link from the run — task `Ev2 Managed SDP Region Agnostic` logs `##[warning]Ev2 portal link - https://ra.ev2portal.azure.net/#/rollouts/Prod/<serviceTreeId>/<serviceGroup>/<rolloutId>` (newest link wins; fallback `Rollout Progress`).
2. GETs the rollout from the EV2 API (`https://azureservicedeploy.msft.net/api/rollouts/<id>?servicegroupname=<sg>&embed-detail=true`, `az` token for that resource).
3. `Phase`: `no-rollout` (no link yet — e.g. still on the Approval Service) · `deploying` · **`deployed`** = a nonempty set of `Canary.<region>` stages all `Succeeded` / `Completed`; `DeployedAt` = the latest regional stage end time. Do **not** wait for `*-ManagedValidation` to start or finish: pending, not-started or absent validation does not block successful regional deployment. The legacy config key `ev2StepStarted` identifies the validation action and regional prefix only; it is not a start gate. Keep `ValidationStatus` / `ValidationStartedAt` / `ValidationEndedAt` separate. Pending/running/skipped/missing regional stages remain blockers even if the aggregate rollout says succeeded. `failed` still covers a failed/cancelled region, validation or rollout; later validation checks and deployment-serialization gates below are unchanged. `unsupported-cloud` (non-Prod EV2 — the run result is used) · `error` (lookup failed — the run result is used).

**Watcher** (`poll-ado-pipelines`, Steps 5 and 7 — every target whose run's definition has `deploymentDoneWhen`): while the run is still in progress, call the script each poll. `deployed` → target `status: "deployed"` (counts as done, never polled again in this directive) + `ev2 { phase, rolloutId, portalUrl, validationStep, validationStatus, validationStartedAt, deployedAt, reason }` and audit `ev2-deployed`; `failed` → target `failed` (→ `onFailure`, audit `ev2-failed`); anything else → keep polling (the run result still decides). Cold resume treats `deployed` as done too.

**On step completion** (Step 5 / Step 7): for every `deployed` target write `state.ev2DeployedRuns.<step> = [ { runId, pipelineKey, rolloutId, portalUrl, deployedAt, validationStep } ]` (via `Update-ReleaseState -StateProperties`) — the watcher directive is replaced by the BVT timer, so this is where the runs are remembered. The BVT step (Step 6 / 8) starts at step completion, i.e. in parallel with the validation — with `bvtReleases` it creates the BVT releases right away (see "BVT releases").

**When the BVT window ends** (Step 6 / Step 8, before the Kusto query): for each `state.ev2DeployedRuns.<5|7>` run, GET the ADO run:
- `completed` + `succeeded` → fine (mention "EV2 {validationStep} passed" in the BVT email).
- `completed` + not succeeded → the step is `failed`: "EV2 {validationStep} failed for {pipelineKey} run {runId} ({portalUrl}) — canary health validation did not pass", Rule 11 failure email, halt for `ack` (in addition to any BVT failures).
- still in progress → run `Get-Ev2DeploymentProgress.ps1` and state "EV2 {validationStep} still running since {validationStartedAt}" in the BVT email; the next deployment waits for it (below).

**Before triggering Steps 7, 10, 15** (and Step 13 with `safefly.r2dBuildSource == "productionRun"`): EV2 runs one rollout per service group at a time. If any run in `state.ev2DeployedRuns.*` — or any other in-progress run of this service's canary/production pipelines (a manual or previous-release run) — is still in progress, do not trigger — arm `{ action: "poll-ado-pipelines", waitForRunCompletion: true, targets: [{ url, label }], onSuccess: "continue release {id}" }` and tell the owner "waiting for EV2 {validationStep} of run {runId} to finish (started {validationStartedAt})". **`waitForRunCompletion: true` is mandatory here**: it disables the `deploymentDoneWhen` → `deployed` shortcut (which would end the wait at once and re-invoke the agent in a loop) and completes only when every run's ADO `status` is `completed`, whatever its result (`scripts/lib/RunCompletionWaitLib.ps1`). On `continue release` re-check the results: a failed run of *this* release halts the step as above; a foreign run's result is reported, not a halt.

**Test mode**: runs are cancelled at trigger, no EV2 rollout exists — nothing to do.

## Step 6: BVT Check (Kusto-Based Failure Analysis)

**Trigger**: Step 5 completed (canary deployed)
**BVT releases** (when `CONFIG[pipelines.bvtReleases.steps]` contains 6 — BCM): **no 24 h timer**. Create the BVT releases and wait for them instead — see "BVT releases (Steps 6, 8, 11)" below. Actions 0–5 run once they have all finished.
**Revert bits during the canary BVT** (when `CONFIG[revertBits.prepareDuringCanaryBvt]` — BCM): on Step 6 entry, right after starting the BVT releases (or the timer), also start the revert bits — 7a Plan + selection email now, 7b PR on `revert-bits preserve`, the build via the watcher side-channel — so the revert build is ready by `approve-bvt`. Never changes Step 6's status. See "Step 7 — Revert bits → Prepared during the canary BVT".
**Wait** (no `bvtReleases` for this step): **24 hours** after Step 5 completion. Set a timer watcher directive:
`{ action: "wait-timer", waitUntil: "<step5CompletionTime + 24h ISO 8601>", onSuccess: "continue release {id}", onFailure: "wait-timer error for release {id}" }`
**⚠️ Test Mode Override**: When `testMode` is `true`, this step becomes a **BVT-query-works check** — skip the 24h wait (no `wait-timer` directive), query Kusto with `ago(48h)`, and **auto-pass with no `approve-bvt`**: if the query executes, mark Step 6 `completed`; if it errors (auth, unreachable cluster, malformed KQL), mark it `failed`. Write a `bvt-query-check` record to `test-run-capture.json`. See "Test Mode Overrides → Step 6" for details.

**Actions** (after wait completes):
0. **EV2 validation outcome** — if `state.ev2DeployedRuns.5` exists, check those runs first (see "EV2 deployment done → When the BVT window ends").
1. Load the BVT query template from `.github/skills/zed-agent/queries/CONFIG[kusto.bvt.queryFile]`
2. Read `state.json` → `pipelineTriggerTimestamps.step5` to get the pipeline trigger time
3. Substitute placeholders in the query:
   - `{{PIPELINE_TRIGGER_TIME}}` → a COMPLETE KQL time expression, wrapper included.
     The template does NOT wrap it, so you must emit the correct form:
       * absolute timestamp from `pipelineTriggerTimestamps.step5`
         → `datetime(2026-04-15T10:30:00Z)`
       * relative fallback when no trigger timestamp exists (e.g. a test run, or the
         build was cancelled before versioning) → `ago(48h)` — emitted BARE.
     Never wrap a relative expression: `datetime(ago(48h))` is a Kusto syntax error.
   - `{{RESPONSIBLE_TEAM}}` → `CONFIG[kusto.bvt.queryVariables.RESPONSIBLE_TEAM]`
4. Execute the query via Kusto MCP:
   - Cluster: `CONFIG[kusto.bvt.cluster]`
   - Database: `CONFIG[kusto.bvt.database]`
5. Analyze results:

   **If rows returned** (CONFIG[service.name] failures found):
   - Count total failures, group by WorkLoadType, Environment, IssueCategory
   - Extract FrontLiners from results (contact aliases for each workload)
   - **For each FrontLiner**, send **personal** notifications only (NO group chat posting):
     - **Teams 1:1**: Load `templates/bvt-frontliner-teams-message.html`, fill placeholders (`{{workloadType}}`, `{{workloadFailureCount}}`, `{{environments}}`, `{{issueCategories}}`, `{{workloadFailureDetails}}`, `{{releaseOwner}}`, `{{pipelineTriggerTime}}`). Use `Resolve-OneOnOneChat -Alias "{frontlinerAlias}"` to get the 1:1 conversation ID, then `Send-TeamsMessage -ConversationId $chat.conversationId -Body $renderedHtml`.
     - **Email**: Load `templates/bvt-frontliner-email.html`, fill placeholders (`{{frontlinerName}}`, `{{workloadType}}`, `{{workloadFailureCount}}`, `{{environments}}`, `{{pipelineTriggerTime}}`, `{{queryEndTime}}`, `{{workloadFailureDetails}}`, `{{releaseOwner}}`). Send via `SendEmailWithAttachments` MCP tool to `{alias}@microsoft.com`.
     - If `Resolve-OneOnOneChat` fails for an alias (Graph API error), fall back to **email only** for that FrontLiner.
   - **CRITICAL**: NEVER use `Find-TeamsChat` for personal messages — it uses fuzzy name matching and can misroute to the wrong person or a group chat. Always use `Resolve-OneOnOneChat` which is deterministic and zero-ambiguity.
   - **CRITICAL**: Do NOT post BVT failure details to any group chat. Only FrontLiners receive notifications, and only via personal 1:1 channels.
   - Set step status → `failed` with reason: `"CONFIG[service.name] BVT failures detected: {count} failures across {workloads}"`
   - **HALT** — release owner must `ack retry` (re-run BVT check after fixes) or `ack skip` (proceed despite failures)

   **If zero rows returned** (no CONFIG[service.name] failures):
   - Send approval-needed email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-6-waiting-approval'` (defaults to owner-only; owner can broadcast if configured): "✅ BVT Check passed — no CONFIG[service.name] failures in window {triggerTime} → {now}. Results ready — please review and sign off" (use `templates/approval-needed-message.html` as body).
   - No Teams post (Rule 1: approval halts are owner-only email)
   - Set step status → `waiting-approval`
   - **HALT** — release owner must `approve-bvt` to proceed

**State**: Step 6 → `waiting-approval` (pass, awaiting sign-off) or `failed` (CONFIG[service.name] failures)
**Release owner**: `approve-bvt` — confirms BVT results are acceptable, advances to Step 7
**Note**: BVT check **always** requires release owner sign-off, even when no failures are detected. This ensures the release owner has reviewed the BVT window before proceeding.

## BVT releases (Steps 6, 8, 11)

Configured in `pipeline-catalog.json` (BCM: both canary test releases, for Steps 6 and 8 — BCM skips Steps 11–12 via `CONFIG[defaultSkippedSteps]`, so roll-forward goes straight to the R2D):

```json
"bvtReleases": {
  "steps": [6, 8],
  "timeoutHours": 12,
  "releases": {
    "IaaSVM-CloudTest":     { "definitionId": 40785, "variables": { "MABIsOfficial": "True" } },
    "IaaSVM-LHT-CloudTest": { "definitionId": 47437, "variables": { "MABIsOfficial": "True" } }
  }
}
```

The deployment just finished (Step 5 canary · Step 7 rollback · Step 10 roll-forward), so instead of waiting 24 h the BVT step runs the BVT releases against it right away and continues as soon as they are done (they take ~1.5–4 h: `Publish VSO Drop`, then `IaaSVME2ETestsECY` / `CCY` / `EaCan`). All work goes through `scripts/Invoke-BvtReleases.ps1` (never create these releases by hand). Each release is created like the portal's *Create release*: every artifact's latest version passed explicitly (BCM: `Build` = newest `git_mgmt_recoverysvcs_test_develop` test build), the configured `variables` overridden (**`MABIsOfficial="True"`** — exact case-sensitive string, settable at release time; never Boolean `true` or string `"true"`), everything else at its definition default (`AzureEnvironment=Canary`, `UseExistingVault=True`, …).

The helper records `creationVariables` from the actual serialized POST and rejects invalid official values before queuing. Missing/invalid creation evidence or a mismatching live value fails closed (including cached completion on resume). A live variable edit does not repair variables already consumed by jobs. Quarantine affected runs and ask the owner before canceling/requeuing; never silently duplicate tests or accept their results as corrected. `-Rerun` may replace quarantined runs only after owner approval and retains the old records in history.

**Owner-selected `verify-existing`** (no cancel/requeue): an existing retry can instead carry separate `verifiedAttempts` provenance (`releaseId`, exact string `MABIsOfficial`, `verifiedAt`, and `environments[]` with environment/attempt/deployment/phase/task identities and log line). Verify every applicable regional job: its release task snapshot must map `worker:MABIsOfficialRun=$(MABIsOfficial)` and its attempt-scoped task log must show the expanded exact string `worker:MABIsOfficialRun=True`. Preserve original `creationVariables` unchanged and retain quarantined run/step records in history. `Get` and `Poll` revalidate the latest attempt identities, mapping, live variable and consumed log evidence, including cached completion; a newer retry, missing/ambiguous coverage, unavailable evidence or non-exact value fails closed. Only after all proofs pass may the state helper restore the same runs to monitoring. This does not pass BVT, bypass regional completion, or approve the next step.

**On entry** of Step 6 / 8 / 11 (when the step is in `CONFIG[pipelines.bvtReleases.steps]`):
1. `$bv = Invoke-BvtReleases.ps1 -Action Start -ReleaseId <id> -Step <N>` (idempotent — re-entry never creates duplicates).
2. `$bv.Phase == 'skipped'` (test mode) → follow the step's Test Mode Override instead.
3. `$bv.Phase == 'failed'` (a release could not be created — e.g. no artifact version, variable not settable) → step `failed` with the run `error`, Rule 11 failure email, halt for `ack`.
4. Otherwise send ONE owner email (EventKey `step-<N>-started`, unmapped → owner): `🧪 Step <N> BVT releases started | {releaseId}` with `$bv.Summary` (links), and arm the watcher, then EXIT:
   `{ action: "poll-bvt-releases", step: <N>, pollIntervalSeconds: 900, onSuccess: "continue release {id}", onFailure: "release {id} Step <N> BVT releases failed or timed out" }`

**Watcher** — `poll-bvt-releases` calls `Invoke-BvtReleases.ps1 -Action Poll -Step <N>` each tick. A release is finished when all its stages are final (`succeeded` / `partiallySucceeded` / `rejected` / `canceled`), it was abandoned, or a stage was rejected/canceled with nothing still running. All finished → `onSuccess`. `failed` / `timed-out` (`timeoutHours`, default 12) → directive cleared + `onFailure`. Cold resume: `state.bvtReleases.<N>.status == completed` → continue; otherwise a live Poll is needed.

**On `continue`** (Phase `completed`): run the step's Actions (Step 6 Actions 0–5: EV2 validation outcome, Kusto BVT query from the deployment trigger time to now, FrontLiner notifications). Add the BVT releases table (`Invoke-BvtReleases.ps1 -Action Get -Step <N>` → `.Summary`: release link, outcome, per-stage status) to the BVT email.
- Any release `outcome == 'rejected'` (a stage rejected/canceled, or abandoned) → the step is `failed`: "BVT release <name> ended rejected (<stages>)" — Rule 11 failure email, halt for `ack` (together with any Kusto failures).
- `partiallySucceeded` is the normal result (some test cases fail / `Publish VSO Drop` is always partial) — not a failure; the owner reviews the results and signs off (`approve-bvt` for Step 6; Steps 8 / 11 sign-off in Steps 9 / 12).

**Owner commands while halted**: `ack retry` → `Invoke-BvtReleases.ps1 -Action Start -Step <N> -Rerun` (re-creates only the releases that failed to start or ended rejected; the earlier run is kept in `history[]`) and re-arm `poll-bvt-releases`; `ack skip` → continue with the Kusto check / sign-off as is.

**State**: `state.bvtReleases.<N> = { status: running | completed | failed | timed-out, startedAt, completedAt, runs: { <key>: { definitionId, definitionName, releaseId, name, url, createdAt, status, outcome, stages[], summary, finishedAt, artifacts[], error } }, history[] }`. Audit: `bvt-release-created`, `bvt-release-create-failed`, `bvt-release-completed`, `bvt-releases-timed-out`.

**Test mode**: `Start` returns `skipped` and creates nothing — the step's Test Mode Override applies (BVT-query-works check).

## Step 7: Rollback

**Trigger**: Step 6 approved
**Revert bits pre-phase**: When `CONFIG[revertBits.enabled]` is `true`, Step 7 first runs the revert-bits sub-phases 7a–7d (see "Step 7 — Revert bits (7a–7d)" below) and only reaches Action 1 after the owner signs off the revert build (`approve-revert`) or skips it (`revert-bits skip`). With `CONFIG[revertBits.prepareDuringCanaryBvt]` the revert bits were prepared during Step 6: `phase == "ready"` → Action 1 immediately; otherwise Step 7 waits for `ready` (see "Prepared during the canary BVT"). Without `revertBits`, Step 7 is exactly the Actions below.
**Pre-trigger (canary schedule guard)**: before Action 2, run `Invoke-ScheduleGuard.ps1 -Action Restore -ReleaseId <id> -Reason step-7-pre-trigger` (no-op unless ZED still has a guard disabled). If any result is `restore-failed`, set Step 7 → `failed` ("cannot roll back: <key> is still paused by ZED (<guards>) — its schedule is off and/or its gated run would be silently skipped") and halt — never trigger a guarded pipeline while ZED has it disabled. See "Canary schedule guard".
**EV2 one-rollout-at-a-time**: before triggering, if any run in `state.ev2DeployedRuns.*` is still in progress (EV2 post-deployment validation), wait for it instead — see "EV2 deployment done → Before triggering Steps 7, 10, 15".
**Actions**:
1. **Reuse Step 5's actually-triggered set** — do NOT re-query Kusto and do NOT recompute pipeline selection. Rollback MUST target exactly the same canary surface that was deployed to in Step 5, otherwise the rollback either (a) restores bits in regions that were never updated, or (b) misses regions that received the forward bits. Read from the Step 5 `cluster-type-routing` audit row (or equivalent `state.json → step5.triggeredPipelines`) the list of `{ key, params }` pairs that were actually triggered with their `templateParameters`. Use those verbatim. This applies to both `mode: "static"` and `mode: "cluster-type"` — Step 7 never re-runs the routing sub-procedure. If Step 5's triggered-set is missing from state/audit (e.g., manual intervention scrubbed it), halt with `failed` and ask the release owner to provide the list explicitly via `modify` before retrying.
2. Trigger each of those CANARY pipelines, but with `ArtifactsBranch` overridden to the **rollback source** (in **parallel**): `state.revertBits.revertBranch` when `CONFIG[revertBits.useForRollback] != false` and `state.revertBits.phase` is `"signed-off"` or `"ready"` (the revert-bits build); otherwise `release.json → previousBranch` (the previous release branch containing known-good production bits). **Deploy-base**: `previousBranch` does not exist — the rollback source is pinned instead: revert bits signed off / ready → `ArtifactsBranch = <revertBranch>` pinned to `state.revertBits.buildId`; otherwise `ArtifactsBranch = <deployment branch>` pinned to `release.previousBuildId` (the build the previous production rollout deployed). Never roll back with an unpinned `ArtifactsBranch` in deploy-base — it would redeploy the newest build of the branch, i.e. this release. Preserve every other parameter (including the stamp lists) exactly as Step 5 sent them. Record which source was used in `state.revertBits.rollbackSource` and in the audit row.
3. **Record pipeline trigger timestamp**: Save `pipelineTriggerTimestamps.step7 = <current UTC ISO 8601>` to `state.json` via `Update-ReleaseState`
4. Email notification via `SendEmailWithAttachments` MCP tool: "Rollback started" — resolve recipients via `Resolve-NotificationRecipients -EventKey 'step-7-completed'` (Step 6 → Step 7 transition per Behavior Rule 11).
5. **Approval requests** — record the rollback run ids in `triggeredPipelines.7` and run `Invoke-ApprovalWatch.ps1 -Action Sync` once (see "Approval requests"). Rollback pipelines have the same Approval Service gates as forward canary.
6. Watcher polls all triggered pipeline runs every 1 hour
**Watcher**: `{ action: "poll-ado-pipelines", targets: ["<run1>", "<run2>", ...], pollIntervalSeconds: CONFIG[operational.watcherPollIntervalSeconds], teamsChatName: "<first entry from CONFIG[notifications.groups.teamsExtended]>" }`
**Completion**: All triggered pipelines succeed (or are `deployed` per EV2 — record `state.ev2DeployedRuns.7`, see "EV2 deployment done")
**Note**: Rollback deploys from `previousBranch` (or the revert-bits branch — see Action 2) via CANARY pipelines to restore known-good bits in canary regions

## Step 7 — Revert bits (7a–7d)

Runs only when `CONFIG[revertBits.enabled] == true` (BCM), immediately after the canary BVT sign-off (`approve-bvt`) — or, with `CONFIG[revertBits.prepareDuringCanaryBvt]` (BCM), already during Step 6 (see "Prepared during the canary BVT" below). Produces a **revert build** kept on hand for a regression rollback: branch `CONFIG[revertBits.branchTemplate]` (BCM: `releases/{{releaseNameLower}}revert`, e.g. `releases/bcm2610revert`, `releases/bcm2610_2revert`; work branch `users/<owner>/{{releaseNameLower}}revert-config`) = the **previous release commit** + only the settings the owner chooses to keep from **this release**. This matches how the team built `releases/rollback2610` by hand (2609 release commit + 2610's `BCMTeeWorkflowVersion`). All git work goes through `scripts/Invoke-RevertBits.ps1` (never hand-edit the settings file); `releases/*` branches have blocking policies, so the kept settings reach the revert branch through a PR that the owner completes.

State: `state.revertBits = { phase, previousCommit, currentCommit, revertBranch, topicBranch, planPath, preserved[], prId, prUrl, headSha, buildId, buildNumber, buildUrl, signedOffAt, signedOffBy, skippedReason, rollbackSource }`, written with `Update-ReleaseState -Action update-step -StepNumber 7 ... -StateProperties @{ revertBits = <obj> }`. Mirror `revertBranch`, `revertPrId`, `revertBuildId` into `release.json`. Dispatch on `phase`:

| phase | What happens | Waits for |
|---|---|---|
| (absent) / `plan` | **7a** `Invoke-RevertBits.ps1 -Action Plan -ReleaseId <id>` | — |
| `needs-previous-commit` | Previous release commit could not be determined | owner `revert-bits base <sha>` |
| `awaiting-selection` | Owner chooses which changed settings to keep | owner `revert-bits preserve <numbers\|all\|none>` |
| `pr-open` | **7b** PR work branch → revert branch | watcher `poll-ado-pr` |
| `building` | **7c** official build on the revert branch | watcher `poll-ado-build` |
| `awaiting-bvt` | **7d** owner runs BVT on the revert build | owner `approve-revert` |
| `signed-off` / `skipped` | Continue with Step 7 Action 1 | — |

**7a — Plan.** Run `Invoke-RevertBits.ps1 -Action Plan -ReleaseId <id>` (plus `-PreviousCommit` once the owner gave one). Commits: *current* = `release.json.currentCommit` (deploy-base) / source commit of `release.json.buildId` (the build canary just validated); *previous* in deploy-base = `release.json.previousCommit` (owner-confirmed at setup) — else the previous ZED release's build commit, else `origin/<release.previousBranch>` if that is a dedicated release branch, else Status `needs-previous-commit` with `Candidates` (the build-version commit right after each recent release merge on the base branch — for 2610 the top candidate is `897442c3e`, exactly the commit `rollback2610` was forked from). On `needs-previous-commit`: Step 7 → `waiting-approval`, `phase = "needs-previous-commit"`, email (EventKey `revert-bits-select`) listing the candidates and asking for `revert-bits base <sha>`; EXIT. On `planned`: `phase = "awaiting-selection"`, Step 7 → `waiting-approval`, send ONE email (EventKey `revert-bits-select`, subject `🔁 Revert bits {revertBranch}: choose settings to keep | {releaseId}`) with `SummaryMarkdown` (numbered table: scope, setting, previous value, this release's value; `CONFIG[revertBits.preserveAlways]` rows marked **always**) and the reply format `revert-bits preserve 2,4` / `revert-bits preserve all` / `revert-bits preserve none` (always-kept settings are included regardless). If the plan has **no** changed settings, skip the question and go straight to 7b with `-Preserve none`. Interactive session: ask with `ask_user` instead (freeform numbers, show the table first).

**7b — Branch + PR.** On `revert-bits preserve <list>`: run `Invoke-RevertBits.ps1 -Action Prepare -ReleaseId <id> -PreviousCommit <state.revertBits.previousCommit> -CurrentCommit <state.revertBits.currentCommit> -Preserve "<list>" -OwnerAlias <owner>`. It creates `<revertBranch>` at the previous commit (branch create only), commits the kept settings on `<topicBranch>` (`users/<owner>/bcm{{YYMM}}revert-config`) — values copied byte-for-byte from this release, every other byte of the file unchanged, result re-parsed and re-diffed — and pushes it. Then:
- Status `prepared` → create the PR via ADO MCP: `<topicBranch>` → `<revertBranch>`, title `Revert bits {releaseTag}: keep {n} setting(s) from {releaseTag}`, description = `SummaryMarkdown`, **isDraft = false** (this repo defaults new PRs to draft), never auto-complete or bypass policies. Email (EventKey `revert-bits-pr-raised`) with the PR link and the kept settings. `phase = "pr-open"`, arm `{ action: "poll-ado-pr", target: "<PR API URL>", pollIntervalSeconds: CONFIG[revertBits.prPollIntervalSeconds] (900), onSuccess: "continue release {id} — revert bits PR <prId> merged", onFailure: "release {id} revert bits PR <prId> abandoned or unreachable" }`, EXIT.
- Status `no-config-changes` → no PR; go straight to 7c.

**7c — Build.** On PR merged (or no PR): queue `CONFIG[pipelines.officialBuild.id]` exactly like Step 2 Action 3 but on `refs/heads/<revertBranch>` (same `templateParameters`). Store `buildId`/`buildNumber`, `phase = "building"`, arm `{ action: "poll-ado-build", target: "<build API URL>", pollIntervalSeconds: CONFIG[operational.watcherPollIntervalSeconds], successCondition: "$.status == 'completed'", onSuccess: "continue release {id} — revert build ready", onFailure: "release {id} revert build poll failed" }`, EXIT. On completion: `result != succeeded` → Step 7 `failed` (`ack retry` re-queues the build).

**7d — BVT sign-off.** Build succeeded → `phase = "awaiting-bvt"`, Step 7 → `waiting-approval`, email (EventKey `revert-bits-bvt-ready`, subject `🧪 Revert build {buildNumber} ({revertBranch}) ready — run BVT, then reply approve-revert | {releaseId}`) with the build link, the revert branch, the kept settings, and what happens next (Step 7 rolls canary back with this build). EXIT. `approve-revert` → `phase = "signed-off"`, record `signedOffAt/By`, Step 7 → `in-progress`, continue with Step 7 Action 1 (Action 2 uses the revert branch).

### Prepared during the canary BVT (`revertBits.prepareDuringCanaryBvt`)

BCM. The revert build does not depend on the canary BVT result — only on the previous and current release commits — so it is prepared **while Step 6 runs** and Step 7 rolls back with it **right after `approve-bvt`**. Its BVT is Step 8 (the BVT releases after the rollback), its sign-off Step 9 — there is no separate `approve-revert`.

| When | What | Who |
|---|---|---|
| Step 6 entry (after the BVT releases / timer are started) | **7a** Plan exactly as above → selection email (`revert-bits-select`; say "Step 7 will roll back with this build right after you approve the canary BVT"). No changed settings → 7b with `-Preserve none` at once. Step 6 status is not touched. | agent |
| `revert-bits preserve <list>` (during Step 6) | **7b** Prepare + PR exactly as above, but arm **no** watcher directive (Step 6's is active) — just write `phase = "pr-open"` (`no-config-changes` → `phase = "queue-build"`) and send `revert-bits-pr-raised`. | agent |
| `pr-open` → PR merged | `phase = "queue-build"` (`prMergedAt`); PR abandoned → `failed` | side-channel |
| `queue-build` | reuse the official build CI started for the merge commit (`Resolve-ReleaseBuild.ps1 -Action DeployCommit -DeployBranch <revertBranch>`); none after 10 min → `-Action QueueBuild` pinned to that commit → `phase = "building"` (`buildId`, `buildNumber`, `buildUrl`, `revertCommit`) | side-channel |
| `building` → build succeeded | `phase = "ready"` (`readyAt`) → `revert-bits-ready`; failed/canceled → `failed` → `revert-bits-failed` | side-channel |
| `approve-bvt` | Step 7 starts: `ready` → Action 1 now (rollback pinned to `buildId`); earlier phase → Step 7 `waiting` ("waiting for the revert build: <selection \| PR <link> merge \| build <link>>") — on `revert-bits-ready` the agent continues Step 7 Action 1 | agent |

**Side-channel** — `scripts/Invoke-RevertBitsTrack.ps1 -Action Poll` (watcher every `CONFIG[revertBits.prPollIntervalSeconds]`, 900 s, also during its sleep; cold resume Step 3e) while `phase` is `pr-open` / `queue-build` / `building`. Each transition writes `state.revertBits` under the state lock only if the phase is unchanged. The watcher invokes the agent with `revert bits <event> for release <id>`:
- `revert-bits-ready` — mirror `revertBranch` / `revertBuildId` into `release.json`; email (EventKey `revert-bits-ready`) `🔁 Revert build {buildNumber} ({revertBranch}) ready | {releaseId}` — build link, kept settings, "Step 7 rolls canary back with it as soon as you approve the canary BVT; Step 8 runs the BVT releases on it". If Step 7 is already waiting for it → continue Step 7 Action 1.
- `revert-bits-failed` — email (EventKey `revert-bits-failed`) with `error` / `lastError` and the options (`ack retry`, `revert-bits skip <reason>`). Repeated identical errors are reported once. If Step 7 is waiting, it stays `waiting`.

**Test mode**: unchanged — 7a read-only + 7b `-DryRun` only; nothing is prepared during Step 6.

**Owner commands / failure**: see `command-behaviors.md → revert-bits`. `revert-bits skip <reason>` → `phase = "skipped"` and Step 7 rolls back with `release.previousBranch` as before. `ack retry` re-runs the current sub-phase (Prepare is idempotent: an existing revert branch that contains the previous commit and an identical work branch are reused). Any `Invoke-RevertBits.ps1` error → Step 7 `failed` with the message.

**Test mode**: Steps 7–9 are skipped in a true test run. If `revertBits.enabled`, still run 7a (`-Action Plan`, read-only) and 7b with `-DryRun` (validates the edit, pushes nothing), put the plan table and the dry-run result into `test-run-capture.json → revertBits` and the test summary — no branch, PR, build or BVT.

## Step 8: Post-Rollback BVT

**Trigger**: Step 7 completed
**Wait**: **24 hours** after Step 7 completion (same timer pattern as Step 6) — or, when `CONFIG[pipelines.bvtReleases.steps]` contains 8, the BVT releases (see "BVT releases (Steps 6, 8, 11)")
**Actions**: Same Kusto-based BVT failure analysis as Step 6, but uses `pipelineTriggerTimestamps.step7` as the query start time (and Action 0 checks `state.ev2DeployedRuns.7`).
**State**: Step 8 → `completed` (pass) or `failed` (CONFIG[service.name] failures)

## Step 9: Post-Rollback Sign-off

**Trigger**: Step 8 completed
**Actions**:
1. Send approval-needed email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-9-waiting-approval'` (defaults to owner-only) with BVT summary + `templates/approval-needed-message.html` body: "Post-rollback results ready for review"
2. No Teams post (Rule 1)
3. **HALT** — waiting for release owner `approve-rollback`
**State**: Step 9 → `waiting-approval`
**Release owner**: `approve-rollback`

## Step 10: Roll-Forward (PROD Pipelines → Canary Regions)

**Trigger**: Step 9 approved
**EV2 one-rollout-at-a-time**: before triggering, if any run in `state.ev2DeployedRuns.*` is still in progress (EV2 post-deployment validation), wait for it instead — see "EV2 deployment done → Before triggering Steps 7, 10, 15".
**Deploy-base**: every production run request carries `resources.builds` pinned to `release.buildId` — see Step 5 Action 2 "Deploy-base build pinning".
**⚠️ Test Mode Override**: When `testMode` is `true`, run the inventory gate + resolve the production trigger set + REAL params as normal, then call `Invoke-TriggerAndCancel.ps1 -Step 10` **once per resolved pipeline** (instant cancel + capture). This is where PROD-pipeline params are validated in a test run (the old Step 15 trigger-and-cancel moved here). See "Test Mode Overrides → Step 10".
**Actions**:
0. **Inventory gate** — BEFORE doing anything else, invoke `.github/skills/zed-agent/scripts/Test-InventoryGate.ps1`. The script reads `.zed-agent/readiness.json → inventory` and the live SDS hash. Handle the verdict:
   - `pass` or `skip` — proceed to action 1.
   - `missing` — halt the step `failed`. Tell the owner: *"Inventory snapshot has not been recorded for this release. Run `Get-StampInventory.ps1 -Scope production -PipelineKey <key>` then `Approve-Inventory.ps1` before retrying Step 10."*
   - `notApproved` — halt the step `failed`. Tell the owner: *"Inventory exists but has not been approved. Review the drift list and run `Approve-Inventory.ps1` to record explicit approval."*
   - `driftExceeded` — halt the step `failed-drift` (same class as the cluster-type drift halt). Tell the owner: *"Inventory status is `drift` and was not overridden. Re-approve with `-Override` to acknowledge the drift, or resolve it and re-run the inventory."*
   - `hashDrift` — halt the step `failed-drift`. Tell the owner: *"The SDS file changed since the inventory was approved (was `<hashApproved>`, now `<hashLive>`). Re-run `Get-StampInventory.ps1` and `Approve-Inventory.ps1` against the current SDS."*
   - `stale` — halt the step `failed`. Tell the owner: *"Approved inventory is older than `<MaxAgeHours>`h. Re-run `Get-StampInventory.ps1` and `Approve-Inventory.ps1` to refresh."*
   Audit-log the verdict as `event: "inventory-gate"` with `step: 10`, `verdict`, and `pipelineKey`.
   **Reading the inventory drift before approval:** `sdsReconciliation` pairs SDS and Kusto stamps on the cloud-local key `{shortName}-{index}` (SDS `acl-01` == Kusto `acl-pod01-coord1`), so `sdsOnly` / `kustoOnly` list only genuine mismatches; Kusto stamps in a different cloud than the reconciled SDS cloud are listed in `kustoOutOfScope` and are not drift; partition names folded by `inventory.stampNaming.partitionSuffixPattern` are listed in `stampNaming.foldedPartitions`. Hundreds of `serviceTag ... != service.stampTag` rows mean `kusto.production.serviceFilter` is wrong or empty — fix the config, do not approve over them.
1. **Resolve trigger set** via `Resolve-PipelinesByClusterType.ps1 -Scope production` (the resolver internally branches on `pipeline-catalog.json → productionRouting.mode` — `static` returns every `production.*` key, `cluster-type` queries Kusto and intersects with `productionRouting.clusterTypeMap`; see the **cluster-type routing sub-procedure defined in Step 5**). `productionRouting` is a SEPARATE block from `canaryRouting` because services often have asymmetric canary vs production topology. In `cluster-type` mode Kusto failure → halt with `failed` (no silent fallback). Trigger each resolved pipeline's `templateParameters` to ADO **verbatim** (no stamp-list filtering). Write a `cluster-type-routing` audit row with `step: 10` and the resolver output (resolved + skipped + liveClusterTypes).
2. This validates that the PROD pipelines work correctly before using them for public regions.
3. **Record pipeline trigger timestamp**: Save `pipelineTriggerTimestamps.step10 = <current UTC ISO 8601>` to `state.json` via `Update-ReleaseState`
4. **Capture BuildNumber**: After the PROD pipeline runs start, read the `buildNumber` from **any** of the triggered pipeline runs via ADO API (`GET /{project}/_apis/build/builds/{buildId}`) — all PROD pipelines build from the same release branch so `buildNumber` is identical across runs. The format is `<BranchName>-<RunCount>` (e.g., `Release-2604-2` means branch `Release-2604`, 2nd run). Store this in `release.json → buildNumber`. This value is used later by Step 13 for the SafeFly `DeploymentDetails.DeploymentToolInputs.BuildNumber` parameter.
5. Email notification via `SendEmailWithAttachments` MCP tool: "Roll-forward started (PROD pipelines → canary)" — resolve recipients via `Resolve-NotificationRecipients -EventKey 'step-10-completed'` (Step 9 → Step 10 transition per Behavior Rule 11).
6. **Approval requests** — record the production run ids in `triggeredPipelines.10` and run `Invoke-ApprovalWatch.ps1 -Action Sync` once (see "Approval requests"). Production pipelines gate each cloud stage (PROD / FF / MC) behind the Approval Service; stages sharing one approval request are reported as one.
7. Watcher polls all triggered pipeline runs every 1 hour
**Watcher**: `{ action: "poll-ado-pipelines", targets: ["<run1>", "<run2>", ...], pollIntervalSeconds: CONFIG[operational.watcherPollIntervalSeconds], teamsChatName: "<first entry from CONFIG[notifications.groups.teamsExtended]>" }`
**Completion**: All triggered pipelines succeed
**Note**: Uses the same release bits as Step 5 (canary) but deploys via the PROD pipeline path

## Step 11: Post-Roll-Forward BVT

**Trigger**: Step 10 completed
**Wait**: **24 hours** after Step 10 completion (same timer pattern as Step 6) — or, when `CONFIG[pipelines.bvtReleases.steps]` contains 11, the BVT releases (see "BVT releases (Steps 6, 8, 11)")
**Actions**: Same Kusto-based BVT failure analysis as Step 6, but uses `pipelineTriggerTimestamps.step10` as the query start time.
**State**: Step 11 → `completed` (pass) or `failed` (CONFIG[service.name] failures)

## Step 12: Post-Roll-Forward Sign-off

**Trigger**: Step 11 completed
**Actions**:
1. Send approval-needed email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-12-waiting-approval'` (defaults to owner-only) with BVT summary + `templates/approval-needed-message.html` body: "Post-roll-forward results ready for review"
2. No Teams post (Rule 1)
3. **HALT** — waiting for release owner `approve-rollforward`
**State**: Step 12 → `waiting-approval`
**Release owner**: `approve-rollforward`

## Step 13: Create SafeFly R2D Request

**Trigger**: Step 12 approved — or, when Steps 11–12 are `skipped` (e.g. BCM `CONFIG[defaultSkippedSteps]`: roll-forward goes straight to R2D), Step 10 completed — AND Step 4 completed (commit data) AND — when `CONFIG[pipelines.privateStampUpgrade.enabled]` — the private stamp upgrade test is `signed-off` or `skipped`

**Prerequisite check (Step 4 join point — see Step Dependency Matrix parallelism note):**

Before running any of the actions below, read `state.json` and verify `state.steps[4].status == "completed"`. If Step 4 is still `in-progress` (Phase B side-channel hasn't reached 100 % Impact fill yet — uncommon, because Step 6 alone bakes 24 h before Step 13 is reached):

1. Arm a dedicated `poll-onedrive-file` watcher directive targeting `state.step4ExcelUrl` — this is the only place in the pipeline that uses `poll-onedrive-file` as a primary directive (during normal flow it runs as the side-channel inside the build/canary watchers):
   ```json
   {
     "action": "poll-onedrive-file",
     "target": "<state.step4ExcelUrl>",
     "pollIntervalSeconds": "CONFIG[operational.watcherPollIntervalSeconds]",
     "successCondition": "$.impactPct == 100",
     "onSuccess": "continue release {id}",
     "onFailure": "release {id} step 4 excel poll failed at step 13 barrier"
   }
   ```
   **Tracker mode**: add `"tracker": <state.step4Tracker>` (`{ sheetName, driveId, itemId }`) to the directive — the watcher then measures the release's sheet via `Invoke-CommitTracker.ps1 -Action Poll` (all `required: true` columns) instead of downloading the file.
2. Set `state.steps[13].status = "waiting"` and log `step13-waiting-on-step4` to `audit.jsonl`.
3. Send the release owner a Behavior Rule 11 step-transition email with subject `⏸ Step 13 waiting on Step 4 Excel completion`.
4. EXIT (per Rule 10). The watcher re-invokes the agent when Step 4 reaches 100 %.

If `state.steps[4].status == "failed"`, halt Step 13 with `failed`, email owner with the chain of remediation attempts (per the Self-Healing rule), and wait for `ack`.

If `state.steps[4].status == "completed"`, proceed with the private stamp join below.

**Prerequisite check 2 (private stamp upgrade join — only when `CONFIG[pipelines.privateStampUpgrade.enabled]`):**

Read `state.privateStampUpgrade.status` (missing track ⇒ run `Invoke-PrivateStampUpgrade.ps1 -Action Init` first and send its `NotifyEvent`, then treat as `awaiting-input`):
- `signed-off` or `skipped` → proceed with the actions below.
- anything else → do NOT create the R2D. Set `state.steps[13].status = "waiting"`, set `watcherDirective` to `{ "action": "none" }` (the watcher keeps polling the side track), log `step13-waiting-on-private-stamp` with the current status, send ONE Behavior Rule 11 email `⏸ Step 13 waiting on private stamp upgrade test ({status})` that repeats what the owner must do for that status (inputs / BVT sign-off / retry), and EXIT. Step 13 is re-entered by `approve-private-stamp` or `private-stamp skip` (both resume the execution loop).

If both checks pass, proceed with the actions below.

**Production run first (`CONFIG[safefly.r2dBuildSource] == "productionRun"` — BCM):** the R2D's `ev2.build` answer is the production pipeline run's buildNumber (e.g. `Release-2610-1`, as in 13.14983), so Step 13 triggers the Step 15 production pipeline(s) **before** filing the R2D. Order — every item is a hard gate, any failure halts Step 13 `failed`:
1. **Idempotency**: if `state.productionPreTrigger.runs` (or `state.triggeredPipelines.15`) already holds a run for a resolved pipeline key, do NOT trigger again — reuse it (re-read its `buildNumber` from the ADO build API). Also list the pipeline's runs queued by the owner since `state.setupCompletedAt` with this release's pinned build; reuse such a run rather than queueing a second one.
2. **Approval-gate safety**: every resolved production pipeline must carry `pipeline-catalog.json → production.<key>.approvalGate.verified == true` (evidence that no stamp is deployed before a human approval — e.g. OneBranch Approval Service + ManualValidation ahead of every EV2 job). Missing → halt `failed` ("cannot trigger production ahead of the R2D: approval gate not verified for <key>"); never trigger on assumption.
3. **Step 15 Phase 1 gates** (action 0 inventory gate, EV2 one-rollout-at-a-time, action 1 resolver + parameters + payload/geography gates, deploy-base `PinResources`) exactly as Step 15 runs them.
   - **EV2 serialization blocked** (any run of the same EV2 service group — `state.ev2DeployedRuns.*`, or another in-progress run of the production/canary pipelines — is still running): do not trigger. Set Step 13 `waiting` (`waitingOn: "ev2-serialization"`), arm `{ action: "poll-ado-pipelines", waitForRunCompletion: true, targets: [{ url: "<_apis/build/builds/<runId>>", label }], pollIntervalSeconds: CONFIG[operational.watcherPollIntervalSeconds], onSuccess: "continue release {id}", onFailure: "release {id} step 13 ev2 serialization wait failed" }`, send one `⏸ Step 13 waiting on EV2 serialization` email (EventKey `step-13-waiting`, owner-only) and EXIT. `waitForRunCompletion` completes only when every run's ADO status is `completed` (any result) — never on the canary `deployed` shortcut.
4. **Trigger exactly once** per pipeline (pinned `resources.builds`), write `pipelineTriggerTimestamps.step15.<key>` BEFORE the POST, then `triggeredPipelines.15 = [runId]` and `state.productionPreTrigger = { triggeredAtStep: 13, runs: [{ pipelineKey, runId, buildNumber, url, triggeredAt }] }`. Audit `production-pre-trigger`.
5. File the R2D (actions below) with `-BuildNumber <run buildNumber>` (several pipelines → `", "`-joined). The run is now parked on its approval gates; the approval side-channel mails the Approval Service link (`approval-needed`) — it MUST NOT be approved before Step 14 completes (state this in every email of Steps 13/14).

If both checks pass (and, with `productionRun`, the production run exists), proceed with the actions below.

**Skill**: `.github/skills/zed-agent/scripts/SafeFly/New-SafeFlyRequest.ps1`
**API Reference**: `.github/skills/zed-agent/scripts/SafeFly/SAFEFLY-API-REFERENCE.md` — full schema, all enums, valid values for every field (sourced from [SafeFly OpenAPI spec](https://www.safefly.azure.com/swagger/v1/swagger.json))

This step uses the SafeFly skill to create the R2D request. Most payload parameters are defined inside the skill script — the agent provides dynamic per-release values plus a **DeploymentNature** array derived from the commit Excel. Consult the API Reference for any questions about valid field values or constraints.

**Actions**:

1. **Derive DeploymentNature from the commit Excel** — the team may have rewritten the Comments column in their own words (removed tags, added free-text), so do NOT rely on exact `[NatureTag]` pattern matching. Instead, perform intelligent analysis:

   **a. Download the latest Excel** from SharePoint (the URL in `release.json.commitExcelUrl`). Read every row — all columns: CommitHash, Owner, Date, Title, **Comments**, Impact, Validations, Rollback Friendly.
   **Tracker mode**: do NOT download the shared workbook — run `Invoke-CommitTracker.ps1 -Action Read -ReleaseId <id> -SheetName <release.json.commitExcelSheet>` and use its `Rows` (every column keyed by header, e.g. Date, Author, PR/Commit Link, **Description of Changes** (plays the role of Comments), Risk Assessment, Testing Done, IsChangeUnderConfig). Match rows to `commits.json` by the PR id in the link text. `IsChangeUnderConfig` = Yes is a strong signal for `Config change` / "behind config" in the Live-production-feature check below.

   **b. For each commit row, determine its nature** by analyzing ALL available signals holistically:
   - The **Title** (commit subject — often the strongest signal)
   - The **Comments** field (may contain agent-written tags like `[NewFeature]`, OR human-written free text like "added new backup retry mechanism" or "patching the CVE-2026-1234 vulnerability")
   - The **Impact** column (team may have written "production", "config only", "security patch", etc.)
   - The commit's original `Subject` and `Body` from `commits.json` (cross-reference if the team rewrote Comments)

   **c. Map each commit to exactly one SafeFly DeploymentNature value** from this authoritative list:

   | SafeFly DeploymentNature value | What it means — classify a commit here if... |
   |-------------------------------|-----------------------------------------------|
   | `New feature` | New capability, new endpoint, new workflow, feature flag, new API |
   | `General bug fixes` | Fixing broken behavior, error handling, null checks, regressions |
   | `Config change` | Configuration/settings/parameters/thresholds/feature flag toggled |
   | `Critical security fixes` | Security vulnerability, CVE patch, auth bypass, credential fix |
   | `CRI fixes` | Customer-reported incident fix, support case resolution |
   | `Monitoring/health signals` | Monitoring, alerting, telemetry, logging, diagnostics, Geneva |
   | `Policy change` | Policy, compliance, governance, RBAC, access control, SFI |
   | `Secrets/Certificate management` | Cert rotation, secret update, managed identity, KeyVault |
   | `Sev 1/2 repair` | Livesite repair, sev1/sev2 incident fix, IcM item |
   | `OS/Image patch` | OS update, base image update, container image, runtime patch |
   | `Other` | Refactoring, cleanup, dependency update, doc-only, test-only, tooling |

   **d. Understanding human-written comments** — people write naturally, not in tags. You must interpret intent:
   - "fixed crash when restoring large VMs" → `General bug fixes`
   - "new support for cross-region backup" → `New feature`
   - "updated timeout settings for canary" → `Config change`
   - "patched CVE-2026-XXXX in auth module" → `Critical security fixes`
   - "addressing customer Contoso backup failure" → `CRI fixes`
   - "added alerts for job queue depth" → `Monitoring/health signals`
   - "rotated storage account keys" → `Secrets/Certificate management`
   - "cleanup and refactoring of old V1 paths" → `Other`

   **e. Build the DeploymentNature array**: Collect all **unique** SafeFly nature values across all commits (deduplicated). If no commits map to any specific nature, default to `@("General bug fixes")`.

   Example: 12 commits → 5 `New feature`, 4 `General bug fixes`, 2 `Config change`, 1 `Other` → `@("New feature", "General bug fixes", "Config change")`
   Note: `Other` is only included if ALL commits are `Other`. When mixed with specific natures, omit `Other`.

   > **SafeFly V2 note:** The derived DeploymentNature array feeds the **commit Excel Comments column** and the **local audit trail** only. The SafeFly V2 App-deployment form does not have a DeploymentNature field — that payload is dropped by `New-SafeFlyRequest.ps1`. `SDPType` (Standard/Conservative) is what reaches SafeFly and is derived in Step 2 below.

2. **Determine SDPType** — analyze the commit Excel holistically and select either `Standard SDP` or `Conservative SDP`. This agent handles monthly releases only; no other SDP types apply.

   **Default to `Standard SDP`** unless ANY of the following escalation triggers are true:

   | Escalation Trigger | Why it escalates | How to detect |
   |-------------------|-----------------|---------------|
   | **Live production feature** | A new feature enabled/active in production (not behind a disabled config flag) | DeploymentNature includes `New feature` AND the commit's Comments/Title do NOT mention "behind config", "feature flag disabled", "dark launch", "gated", or similar |
   | **Breaking change** | Changes APIs, removes functionality, or alters existing behavior | Comments/Title contain "breaking change", "breaking-change", explicit API/endpoint/contract removal phrases ("removed the api", "removed the endpoint", "remove the parameter", "schema change"), "deprecated", "migration required", "incompatible". **Do NOT escalate on bare "removal" without context** — e.g., "macro removal", "dependency removal", "stale code removal" are not breaking changes. |
   | **High commit volume (>100)** | Large change sets carry higher combinatorial risk | Total row count in the commit Excel exceeds 100 |
   | **Any impact above Low** | Team has flagged elevated risk for at least one commit | ANY row in the **Impact** column contains `Medium`, `High`, `Critical`, or anything that is NOT `Low`, `None`, or empty |

   **Decision logic**:
   ```
   IF any_escalation_trigger_is_true THEN
       SDPType = "Conservative SDP"
   ELSE
       SDPType = "Standard SDP"
   END
   ```

   **Examples**:
   - 40 commits, all bug fixes and config changes, all Impact=Low → `Standard SDP`
   - 60 commits, one small feature behind disabled config flag, all Impact=Low → `Standard SDP`
   - 50 commits, one new live feature going to production → `Conservative SDP`
   - 30 commits, all bug fixes, but one commit has Impact=Medium → `Conservative SDP`
   - 120 commits, all trivial changes → `Conservative SDP` (volume alone triggers escalation)

3. **Derive TargetedRegions** — use the region mapping skill to compute targeted regions dynamically:
   ```powershell
   $excludedRegions = (Get-Content release.json | ConvertFrom-Json).excludedRegions  # short names from CCOA
   $targeted = .\.github\skills\zed-agent\scripts\Get-RegionMapping.ps1 -AllClouds -ExcludeRegions $excludedRegions
   $targetedRegions = $targeted | ForEach-Object { $_.DataCenterName }
   ```
   The skill fetches `AzureServiceConfig.json` from the region source-of-truth repo configured in `service-config.json` (`regions.ascRepo`), extracts all ACTIVE datacenters across **all 5 deployment clouds** (Public, Fairfax, Mooncake, USNat, USSec), adds any configured supplementary SafeFly regions (`regions.supplementaryRegions`) not yet in ASC, subtracts CCOA-excluded ones, and returns the targeted regions with their SafeFly display names.
   If `excludedRegions` is empty → all regions are targeted (no subtraction).

   > SafeFly expects **display names** (e.g., "East US 2", "Australia Central") — the skill's `DataCenterName` field provides these exactly.

4. **Run the SafeFly creation skill**:
   ```powershell
   $result = .\.github\skills\zed-agent\scripts\SafeFly\New-SafeFlyRequest.ps1 `
       -BuildId           "{release.json → buildId}" `
       -BuildNumber       "{release.json → buildNumber}" `
       -ReleaseId         "{release.json → releaseId}" `
       -ReleaseOwnerAlias      "{release.json → releaseOwner.alias}" `
       -DeploymentNature  $derivedNatures `
       -SDPType           $derivedSDPType `
       -TargetedRegions   $targetedRegions `
       -CommitExcelUrl    "{release.json → commitExcelUrl}" `
       -AdoBuildUrl       "{release.json → buildUrl, only when CONFIG[safefly.adoBuildLink]}"
   ```
   `-BuildNumber` is the `ev2.build` answer: the production run's buildNumber when `CONFIG[safefly.r2dBuildSource] == "productionRun"` (see above), else `release.json → buildNumber`. `core.rollback_strategy` comes from `CONFIG[safefly.rollbackStrategy]` (BCM: `Manual (TSG)`). Payload rules (enforced by the script, see SAFEFLY-API-REFERENCE.md): `CONFIG[safefly.tags]` names → V2 tag GUIDs (missing tag → skipped + warning, `tagIds: []`); multi-select answers (`core.regions`, `ev2.servicegroup`) are JSON arrays; regions = targeted regions ∩ live `getRegionsWithActiveCCOACoverage` (unmatched → `core.other_regions`, no hard-coded drop list); config `formId` must equal the active form. **Always dry-run first** (`-DryRun`) and record its summary in the audit, then file for real.
   **Idempotency**: before the real call, look for a request this release already created (`requests(filter: { serviceId, owner })` created since Step 13 started, title = rendered `titleTemplate`) — reuse it (a `saveRequest` draft left by a failed `submitRequest` included) instead of filing a duplicate.
   The skill handles: token acquisition, full payload construction, `saveRequest` → `submitRequest`, response parsing. **Verify** after creation: read the request back (`requestByDisplayId`) and check status, `ev2.build`, `ev2.servicegroup`, `core.regions` count, rollback and ADO build answers.

5. **Handle the result**:
   - **Success**: `$result` contains `safeFlyId`, `safeFlyRequestNumber`, `safeFlyUrl`, `requestStatus`
   - **Failure** (skill throws): Log full error, set step → `failed`, send failure email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-13-failed'` (default: current-owner-only — owner widens via `routing.13-create-r2d.failure`), then **HALT**. Do NOT post to Teams or any other channel.

6. **Store SafeFly details** in `release.json` via `Update-ReleaseState`:
   ```json
   {
     "safeFlyId": "<from $result.safeFlyId>",
     "safeFlyRequestNumber": "<from $result.safeFlyRequestNumber>",
     "safeFlyUrl": "<from $result.safeFlyUrl>",
     "safeFlyStatus": "<from $result.requestStatus>"
   }
   ```

7. **Send R2D notification email** via `SendEmailWithAttachments` MCP tool with rendered `templates/r2d-email.html`:
   - Recipients: resolve via `Resolve-NotificationRecipients -EventKey 'create-r2d'` — default cell (`routing.13-create-r2d.success`) CCs `notifications.groups.cc`; the current release owner is always on the To-line. Do **not** use `{{managerEmail}}` — managers are not separately tracked by this agent.
   - **Email format**:
     ```
     Subject: ✅ SafeFly R2D #{requestNumber} Created — Release {releaseId}

     Hi {releaseOwnerName},

     SafeFly R2D request has been created for the CONFIG[service.displayName] monthly release.

     | Field                | Value                                      |
     |----------------------|--------------------------------------------|
     | Request Number       | #{requestNumber}                            |
     | SafeFly URL          | {safeFlyUrl}                                |
     | Release              | {releaseId}                                 |
     | Branch               | {branchName}                                |
     | Title                | CONFIG[safefly.titleTemplate] — tokens {releaseName} (= release id, e.g. BCM2610_2), {Month}-{YY} |
     | SDP Type             | {sdpType}                                   |
     | Deployment Nature    | {nature1}, {nature2}, ...                   |
     | Targeted Regions     | {count} regions (CCOA exclusions applied)   |
     | Commit Excel         | {commitExcelUrl}                            |
     | Build Number         | {buildNumber}                               |
     | ADO Build ID         | {buildId}                                   |

     Next step: Present at CRB and get approval. The agent will auto-poll SafeFly approval every 60 minutes.
     ```

8. **No separate Teams notification** — the R2D creation broadcast is handled entirely by the email in action 7 (event `create-r2d` routes to release owner + CC per `routing.create-r2d`). No additional Teams post is sent (Rule 1).

**Dry run**: To validate the payload without submitting, the release owner can run:
```powershell
.\.github\skills\zed-agent\scripts\SafeFly\New-SafeFlyRequest.ps1 -BuildId 12345 -BuildNumber "Release-2604-2" -ReleaseId "2026-04" -ReleaseOwnerAlias "test" -DeploymentNature @("New feature","General bug fixes") -SDPType "Standard SDP" -TargetedRegions @("East Asia","West US 2") -CommitExcelUrl "https://microsoft.sharepoint.com/..." -DryRun
```

**State**: Step 13 → `completed`

## Step 14: Wait for SafeFly Approval + CRB Review

**Trigger**: Step 13 completed (SafeFly request created)

**Skill**: `.github/skills/zed-agent/scripts/SafeFly/Get-SafeFlyApproval.ps1`

This step polls SafeFly approval via the skill and waits for the release owner's CRB approval. Both gates must pass before proceeding.

**Actions**:

1. **Set up SafeFly approval polling** via watcher directive:
   ```json
   {
     "watcherDirective": {
       "action": "safefly-approval-poll",
       "safeFlyId": "<from release.json>",
       "pollIntervalSeconds": 3600,
       "timeoutHours": 72,
       "startedAt": "<current UTC ISO 8601>",
       "onSuccess": "SafeFly request <safeFlyId> approved for release {id}",
       "onTimeout": "safefly approval timeout for release {id}"
     }
   }
   ```
   `Get-SafeFlyApproval.ps1` reads SafeFly **V2** (`requests(filter: { objectId })` → `currentState`) whenever `CONFIG[safefly.graphQlEndpoint]` is set — the V1 `approvalstate` API returns HTTP 410. V2 states: `Approved` → Approved; `Draft` / `Submitted` / `Engineering Director Reviewed` / `R2D Reviewed` → Pending; `Rejected`; `Abandoned` → Invalidated.
   With `CONFIG[safefly.r2dBuildSource] == "productionRun"` the production run already exists (Step 13) and is parked on its Approval Service / ManualValidation gates; Step 14 is what authorizes approving them.
   The watcher tracks `startedAt + timeoutHours` and, when the timeout elapses without an `Approved` classification, re-invokes the agent with the `onTimeout` prompt. The agent then runs the timeout-handling action below (action 5) and re-arms the same directive to keep polling.

2. **On each watcher poll**, run the approval skill:
   ```powershell
   $status = .\.github\skills\zed-agent\scripts\SafeFly\Get-SafeFlyApproval.ps1 `
       -SafeFlyId "{release.json → safeFlyId}"
   ```
   The skill returns: `state`, `classification` (Approved|Pending|Rejected|Invalidated).

3. **Act on classification**:

   | Classification | Action |
   |----------------|--------|
   | `Approved` | ✅ SafeFly approved — update `state.json → step14.safeFlyApproved = true`, post Teams, check if CRB also approved |
   | `Pending` | ⏳ Continue polling |
   | `Rejected` | ❌ Set step → `failed`, notify Teams with rejection state, HALT |
   | `Invalidated` | ❌ Request invalidated — set step → `failed`, HALT |

4. **Track dual-gate approval** in `state.json`:
   ```json
   {
     "step14": {
       "safeFlyApproved": false,
       "safeFlyApprovalState": "<from skill>",
       "safeFlyApprovedAt": null,
       "crbApproved": false
     }
   }
   ```
   - When skill returns `Approved` → update `safeFlyApproved: true`, send email to release owner via `Resolve-NotificationRecipients -EventKey 'judgment'`: *"✅ SafeFly R2D #{number} approved!"* (no Teams per Rule 1)
   - When release owner runs `approve-crb` → update `crbApproved: true`
   - **Step 14 completes ONLY when both gates are true**

5. **Timeout handling**: If 72 hours pass without SafeFly approval:
   - Send email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'judgment'` (Rule 1: owner-only): *"SafeFly R2D #{number} has not been approved after 72 hours — please attend the next R2D review meeting or follow up with the SafeFly approvers."*
   - No Teams message (Rule 1) — release owner handles this offline
   - Keep step in `waiting-approval` (continue polling)

**State**: Step 14 → `waiting-approval` (dual-gate: SafeFly skill + release owner `approve-crb`)
**Release owner**: `approve-crb` — marks the CRB gate as done. If SafeFly is also approved, step proceeds.

## Step 15: Production Rollout (EV2 Managed) + Rollout Diagnostics

**Trigger**: Step 14 approved
**Production run already triggered at Step 13** (`CONFIG[safefly.r2dBuildSource] == "productionRun"`): when `state.productionPreTrigger.runs` exists, do NOT trigger again (actions 0–2 already ran at Step 13). Re-read each run: if it is no longer in progress before its approval gates were passed (cancelled/failed/approval expired), halt `failed` and ask the owner (`ack retry` re-triggers it and the R2D `ev2.build` must then be updated); otherwise go straight to action 3 (timer) and action 4 (email: "approve the Approval Service request / resume Pre-Deployment validation now").
**EV2 one-rollout-at-a-time**: before triggering, if any run in `state.ev2DeployedRuns.*` is still in progress (EV2 post-deployment validation), wait for it instead — see "EV2 deployment done → Before triggering Steps 7, 10, 15".
**Approval requests**: record every production run id in `state.triggeredPipelines.15` at trigger time — the approval side-channel watches them and mails/Teams the Approval Service links (see "Approval requests"). The Step 15 directive is `poll-ev2-rollout`, which does not scan approvals itself.
**Deploy-base**: every production run request carries `resources.builds` pinned to `release.buildId` — see Step 5 Action 2 "Deploy-base build pinning". Before triggering, re-run `PinResources`: if the release build has dropped out of the artifact feed's listed versions (busy branch, long CRB), stop with `failed` rather than deploy something else.
**⚠️ Test Mode Override**: When `testMode` is `true`, Step 15 **does not trigger EV2** — but it does **send the transition email notification** (action 4 below) using Step 10's captured production-trigger params for scope data, then marks Step 15 `skipped` with `reason: "test-run: EV2 rollout skipped, transition notification sent"`. The PROD-pipeline trigger-and-cancel validation happens at **Step 10** (see "Test Mode Overrides → Step 10"). Record the notification in `notifications-capture.json`.

**Actions — Phase 1: Trigger Pipelines + Start EV2 Monitoring**:
0. **Inventory gate** — same procedure as Step 10 action 0. Invoke `.github/skills/zed-agent/scripts/Test-InventoryGate.ps1` and halt on any non-`pass`/non-`skip` verdict. Step 15 is the production rollout to public regions — SDS drift between approval and trigger is exactly the failure class this gate exists to catch. Audit-log as `event: "inventory-gate"` with `step: 15`. Sovereign clouds (Fairfax / Mooncake / USNat / USSec / Bleu) reach this step with SDS as the *sole* stamp source, so the hash check is non-negotiable for them.
1. **Resolve trigger set, then trigger pipelines** in parallel via ADO API (same pattern as Step 5 canary — cluster type is a pipeline attribute, not a per-cloud attribute, so the resolver runs once):
   - Invoke `.github/skills/zed-agent/scripts/Resolve-PipelinesByClusterType.ps1 -Scope production`. In `productionRouting.mode == "static"` the resolver returns every `production.*` key; in `mode == "cluster-type"` the resolver runs `kusto.production.queryFile` and returns only the keys whose declared cluster type is currently live. Use `$res.resolved | ForEach-Object pipelineKey` as the Step 15 trigger set. Each resolved pipeline pushes to whichever clouds are listed under `CONFIG[pipelines.ev2CloudCoverage.<key>]` — cloud fan-out happens via EV2 inside the pipeline, NOT by triggering the same pipeline multiple times. Write one `cluster-type-routing` audit row plus a `production-trigger-set` row summarizing the resolved keys and their `ev2CloudCoverage`.
   - Pipeline IDs from `CONFIG[pipelines.production.*]` (loaded from pipeline-catalog.json) for each resolved key.
   - Parameters from `pipeline-catalog.json`: `ArtifactsBranch` = current release branch, `PubRegions` = regions from SafeFly R2D scope, `PublicExcludestamps` = CCOA-excluded stamps, `SdpType` = derived SDP type (Standard/Conservative), `ValidateOnlyRollOut` = `"false"`
   - **⛔ Geography coverage gate (L-16) — run AFTER params are resolved and BEFORE any pipeline is triggered.** Invoke `.github/skills/zed-agent/scripts/Assert-GeographyCoverage.ps1 -PipelineParams $resolvedParams -ReleaseId $ReleaseId`. It computes the **union** of every pipeline's covered geographies and **throws when any expected geography is uncovered**. This is the prot2608 failure class: that rollout was declared complete at **66 of 73** geographies because coverage was only ever checked per pipeline, never across them. Let the throw halt the step as `failed` — do **not** catch it, and do not proceed on a warning. The report it persists to `state.geographyCoverage` is also what feeds the scope note in action 4, so this gate must run before the email is composed or the note renders "not yet computed".
2. **Record pipeline trigger timestamps**: Save `pipelineTriggerTimestamps.step15.<pipelineKey> = <current UTC ISO 8601>` to `state.json`
3. **Write watcher directive**: `wait-timer` with `waitUntil` = 1 hour from now (UTC ISO 8601). EV2 rollouts start immediately when the pipeline triggers them, so we wait 1 hour before first poll to let initial SDP stages progress:
   - `onSuccess`: `"start ev2 monitoring for release {id}"`
   This replaces the old `poll-ado-pipelines` approach — we do **NOT** wait for ADO pipeline completion because:
   - ADO pipeline completion is irrelevant — the EV2 rollout runs independently
   - ADO builds may even show `Failed` (e.g., monitoring step timeout) while the EV2 rollout continues normally
4. Send transition email via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-15-completed'`. Use the template
   `templates/production-triggered-message.html` with tokens: `{{routeCount}}`, `{{geographyCount}}`, `{{regionListHtml}}`, `{{exclusionNoteHtml}}` (built by `Get-ScopeTemplateVars.ps1` — see scope note below). In **test mode**, call action 4 with scope data from Step 10's capture; EV2 portal link and the "N pipelines running" phrasing are omitted and replaced by `"[TEST MODE — production rollout was not triggered]"`. Record the notification to `.zed-agent/releases/<id>/notifications-capture.json` (see "Notification capture").
   - **Scope note (mandatory).** The email MUST state what is *not* in the rollout, not just how many pipelines are running. Build the tokens with:
     ```powershell
     . .\.github\skills\zed-agent\scripts\Get-ScopeTemplateVars.ps1
     $vars = Get-ScopeTemplateVars -ReleaseId $ReleaseId `
         -ServiceConfig $cfg `
         -InventoryDrift $readiness.inventory.drift `
         -ApprovedRegions $safeFlyApprovedRegions
     # → routeCount, geographyCount, regionListHtml, exclusionNoteHtml
     ```
     Append `{{exclusionNoteHtml}}` to the body under a **"Regions/stamps NOT in this rollout"** heading. It renders two clearly separated blocks: **🔴 unintended** (missing geographies from the L-16 gate, and stamps the inventory could not validate — these mean the rollout may be wrong) and **ℹ️ deliberate** (CCOA exclusions, regions outside the SafeFly R2D scope, other-cloud stamps).
   - ⚠️ **The note REPORTS, it never authorises.** Action 0b below still blocks the rollout on missing geographies. Never treat "it was mentioned in the email" as approval — every P0 in `lessons-learned.md` reached production because a warning was skimmed past under release pressure.
   - This is the same renderer the Teams path uses, so the two channels cannot state different scopes.

**Actions — Phase 2: EV2 Rollout Monitoring** (triggered by the 1-hour wait-timer completing):
5. **Write watcher directive**: `poll-ev2-rollout` with `pollIntervalSeconds = 3600` (1 hour) and targets from `pipeline-catalog.json → ev2ServiceGroups` — includes **all clouds** from `CONFIG[pipelines.ev2CloudCoverage]`. Each pipeline produces rollouts for multiple clouds. **The Release-Watcher polls the EV2 REST API for rollout progress — it does NOT check ADO pipeline status:**
   ```json
   { "action": "poll-ev2-rollout", "pollIntervalSeconds": 3600, "targets": [
       // Targets are dynamically generated from CONFIG[pipelines.ev2ServiceGroups]
       // and CONFIG[pipelines.ev2CloudCoverage] — one entry per serviceGroup × cloud combination.
       // Example entry:
       { "buildId": "<pipeline-build-id>", "serviceGroup": "<from CONFIG[pipelines.ev2ServiceGroups]>", "rolloutInfra": "<from CONFIG[pipelines.ev2CloudCoverage]>" }
     ],
     "onSuccess": "continue release {id}", "onFailure": "ev2 rollout failure report for release {id}" }
   ```
6. **On EV2 failure** (any region fails): Read `state.ev2Diagnostics` from `state.json`, then:
   a. For each `failedNode`, extract: `node.error` (summary), `node.errorCode`, `node.errorReason`, `node.errorDetail` (full StatusMessage)
   b. **Research the error** using the **EV2 Error Analysis — Dynamic Documentation Lookup** procedure (below): search MS Learn, ES Chat, and ADO wiki for the `errorCode`/`errorReason`, then synthesize findings into actionable `agentAnalysis` text
   c. No Teams post (Rule 1: failure notifications are owner-only email). The failure-report HTML (`ev2-failure-report-message.html`) is sent only as the email body.
   d. **Send failure email** via `SendEmailWithAttachments` MCP tool to recipients from `Resolve-NotificationRecipients -EventKey 'step-15-failed'` (default: current-owner-only — owner widens via `routing.15-production-rollout.failure`) — body = rendered `ev2-failure-report-message.html` with failed regions, actual error details, agent analysis, and suggested actions
   e. Set step → `failed`, halt for `ack retry` or `ack skip`
7. **On EV2 success**: All rollouts completed (all 10 targets show `Completed/Succeeded`) → Step 15 → `completed`. **ADO pipeline status is irrelevant** — a pipeline may show `Failed` in ADO but the EV2 rollout it triggered can still succeed independently.

**EV2 manages the staged rollout** through SDP nodes in `RolloutPolicyConfiguration.json` (ProdSdp, FairfaxSdp, MooncakeSdp, EXSdp, RXSdp). The agent does **not** manage individual region stages — it monitors and diagnoses.

> **⚠️ CRITICAL: Monitor EV2 rollout progress, NOT ADO pipeline status.**
> The ADO pipeline build status (`Completed`/`Failed`/`InProgress`) is **irrelevant** for rollout progress tracking. ADO builds can show `Failed` or `Completed` while the EV2 rollout is still actively progressing through SDP stages. The EV2 rollout is a separate long-running process that continues independently of the ADO pipeline run.
>
> - **Use EV2 REST API** (`Get-Ev2RolloutStatus.ps1`) to track per-region, per-stage rollout progress
> - **Never use ADO build status** to determine if a rollout is complete, failed, or in-progress
> - **ADO pipeline is only used for**: (1) triggering the rollout, (2) extracting the EV2 rollout ID from build logs
> - **EV2 rollout status** (`Running`/`Completed`/`Failed` from the EV2 API) is the single source of truth for deployment progress

**Multi-cloud diagnostics**:
- **Prod** → Direct EV2 REST API (`azureservicedeploy.msft.net`)
- **Fairfax/Mooncake** → Edge portal scraping via CDP (REST API DNS unreachable from CorpNet)

> **⚠️ Shared ServiceGroup:** Pipeline variants (e.g., SFMC/SFRP) may share a single EV2 ServiceGroup per CONFIG[pipelines.ev2ServiceGroups]. Always query by **BuildId or RolloutId** — never ServiceGroup alone — to avoid mixing variant data.

The gov-cloud scraper (`Invoke-Ev2PortalScrape.js`) connects to the user's running Edge via Chrome DevTools Protocol, reuses an existing browser tab (to inherit full session cookies), opens the EV2 portal page, and intercepts the portal's own XHR API response (raw JSON). This approach is immune to UI changes. Falls back to DOM text extraction if interception fails. Auth uses the user's existing Edge Microsoft session — no extra login needed.

**Gov-cloud auth-failure handling**: If any gov-cloud query returns `overallStatus = "AuthRequired"`, the agent MUST:
1. **Continue gracefully** — render the dashboard with Prod data and mark gov-clouds as "⚠️ Auth Required" (do NOT block on gov-cloud failures)
2. **Send a notification email** to recipients from `Resolve-NotificationRecipients -EventKey 'judgment'` (Rule 1: owner-only) via `SendEmailWithAttachments` MCP tool with:
   - **Subject**: `[ZED Agent] Gov-Cloud EV2 Auth Expired — Action Required`
   - **Body** (Text):
     ```
     The ZED release agent encountered an authentication failure while querying gov-cloud ({clouds}) EV2 rollout status.

     What happened:
     The agent uses Edge CDP (Chrome DevTools Protocol) to scrape rollout data from the EV2 portal for Fairfax/Mooncake clouds, because the EV2 REST API DNS is unreachable from CorpNet. This requires an active Microsoft auth session in Edge.

     Your Edge browser session for the EV2 portal has expired.

     Action required:
     1. Open Microsoft Edge
     2. Navigate to https://ra.ev2portal.azure.net
     3. Sign in when prompted
     4. Once the EV2 dashboard loads, ask the agent to re-query gov-cloud status

     Prod-cloud data was retrieved successfully. Only gov-cloud ({clouds}) data is affected.
     ```
   - Replace `{clouds}` with the specific clouds that failed (e.g., "Fairfax, Mooncake")
3. **Log it** — note the auth failure in the step status so subsequent polls know to retry

**State**: Step 15 → `in-progress` (Phase 1: pipelines triggered, 1h wait) → `in-progress` (Phase 2: EV2 monitoring, hourly polls) → `completed` or `failed`
**Note**: CCOA-excluded regions via `PublicExcludestamps`. `SdpType` (Standard/Conservative) controls rollout speed.
**Scripts**: `scripts/EV2/Get-Ev2RolloutStatus.ps1` (main), `scripts/EV2/Invoke-Ev2PortalScrape.js` (gov-cloud scraper), `scripts/EV2/Ensure-EdgeCDP.ps1` (Edge CDP helper), `scripts/EV2/Show-Ev2Dashboard.ps1` (terminal dashboard).

**Dashboard**: When the release owner asks for rollout status, rollout details, or EV2 diagnostics:
1. **Run `Show-Ev2Dashboard.ps1`** to collect data from EV2 APIs (Prod + gov-clouds)
2. **ALWAYS render the results as a per-stage markdown table** in your response — never dump the raw script output. Use this exact format:

```
## 🚀 EV2 Rollout Dashboard — {date} {time} IST

| Pipeline | Cloud | Stage | Status | Regions |
|----------|-------|-------|--------|---------|
| **<Pipeline-1>** | Prod | Canary | ✅ 2/2 | centraluseuap, eastus2euap |
| | | Low | ✅ 3/3 | westus2, eastus, northeurope |
| | | Medium | ✅ 5/5 | westeurope, southcentralus, ... |
| | | Heavy | ✅ 7/7 | australiaeast, japaneast, ... |
| | | Day1 | ✅ 5/5 | koreacentral, francecentral, ... |
| | | Day2 | 🔄 2/3 | ✅ westus, ✅ uksouth, 🔶 southeastasia |
| | Fairfax | Day4 | ✅ 1/1 | usgovarizona |
| | Mooncake | — | ⬚ N/A | SFMC doesn't deploy |
| **<Pipeline-2>** | Prod | Canary | ✅ 2/2 | ... |
| | | Low | ✅ 3/3 | ... |
| | | ... | ... | ... |
| | Fairfax | Day1 | ✅ 1/1 | usdodcentral |
| | | Day2 | ✅ 1/1 | usdodeast |
| | | Day3 | ⏳ 0/0 | — |
| | | Day4 | ⏳ 0/0 | — |
| | Mooncake | Day1 | ✅ 1/1 | chinanorth |
| | | Day2 | ✅ 1/1 | chinanorth2 |
| ...all pipelines × all clouds × all stages... |

**Summary:** X/12 rollouts complete | Y/Z regions done | **Remaining:** list any 🔶 regions
```

Table rules:
- **One row per pipeline×cloud×stage** — every SDP stage gets its own row
- Pipeline name only on first row of each pipeline group (blank for subsequent)
- Cloud name only on first row of each cloud group (blank for subsequent stages)
- Show **ALL stages** that exist in the rollout, including Waiting/NotStarted stages (so gov-clouds show Day1-Day4 even if only Day1-Day2 have completed)
- Stage ordering follows SDP order: Canary → ManagedValidation → Low → Medium → Heavy → Day1 → Day2 → ... → Day10
- Status column format: `{emoji} {completed}/{total}` — e.g., `✅ 3/3`, `🔄 2/3`, `⏳ 0/0`
- Status emojis: ✅ all complete, 🔄 in-progress, ❌ has failures, ⏳ waiting/not started, ⬚ N/A
- Regions column: comma-separated list of ALL regions in that stage. Prefix non-completed regions: `🔶 regionname` (in-progress), `❌ regionname` (failed), `⏳ regionname` (waiting). Completed regions listed without prefix. Show `—` if stage has no regions yet.
- For clouds that don't deploy (e.g., SFMC+Mooncake): single row with Stage=`—`, Status=`⬚ N/A`, Regions=`SFMC doesn't deploy`
- Use `batchStages[]` from `Get-Ev2RolloutStatus.ps1` to discover all parent stages, and `completedNodes[]`/`inProgressNodes[]`/`waitingNodes[]`/`failedNodes[]` to build per-stage region lists (nodes have `sdpNode` = stage name, `name` = region)
- Summary line at bottom with overall counts and any remaining regions

Usage:
```powershell
# Gather rollout data for all pipelines × clouds, then render dashboard
# Pipeline keys and cloud coverage come from CONFIG[pipelines.ev2ServiceGroups] and CONFIG[pipelines.ev2CloudCoverage]
$data = @{}
$authFailedClouds = @()
$pipelineKeys = $cfg.pipelines.ev2ServiceGroups.PSObject.Properties.Name  # e.g., keys from pipeline-catalog.json
foreach ($pipeKey in $pipelineKeys) {
    $data[$pipeKey] = @{}
    # ev2CloudCoverage is keyed by pipeline key directly (see pipeline-catalog.schema.json)
    $clouds = $cfg.pipelines.ev2CloudCoverage.$pipeKey  # e.g., @("Prod", "Fairfax")
    if (-not $clouds) {
        Write-Warning "Pipeline key '$pipeKey' has no entry in ev2CloudCoverage — skipping"
        continue
    }
    foreach ($cloud in $clouds) {
        $result = & .\.github\skills\zed-agent\scripts\EV2\Get-Ev2RolloutStatus.ps1 `
            -RolloutId "<id>" -ServiceGroup "<sg>" -RolloutInfra $cloud
        $data[$pipeKey][$cloud] = $result
        # Detect auth failure for gov-clouds
        if ($result.overallStatus -eq "AuthRequired" -and $cloud -notin $authFailedClouds) {
            $authFailedClouds += $cloud
        }
    }
}

# Render dashboard (works with partial data — auth-failed clouds show warning)
& .\.github\skills\zed-agent\scripts\EV2\Show-Ev2Dashboard.ps1 -RolloutData $data

# If auth failures detected, send notification email to release owner
if ($authFailedClouds.Count -gt 0) {
    $cloudList = $authFailedClouds -join ", "
    # → Use Mail MCP: SendEmailWithAttachments to release owner (see auth-failure handling above)
}
```

**⚠️ RULE**: Never show raw `Get-Ev2RolloutStatus.ps1` output to the release owner. Always pipe through `Show-Ev2Dashboard.ps1` for a consistent, presentable view.

### Step 15: Stage Transition Notifications (sub-procedure)

During `poll-ev2-rollout`, the agent MUST track batch-level stage transitions and send email notifications. `Get-Ev2RolloutStatus.ps1` returns `batchStages[]` with parent SDP stage status (Canary, Day1, Day2, etc.).

**State tracking**: Maintain `state.json → step15.ev2StageTracker` — a map of `{pipelineKey}.{cloud}` → `{ lastCompletedStage, lastNotifiedStage, waitingForPromotion }`:
```json
{
  "step15": {
    "ev2StageTracker": {
      "<pipelineKey>.<cloud>": { "lastCompletedStage": "Day1", "lastNotifiedStage": "Day1", "waitingForPromotion": false }
    }
  }
}
```

**On each poll cycle**, for each pipeline×cloud rollout:
1. Read `result.batchStages[]` — find the highest completed stage and the next stage's status
2. Compare against `ev2StageTracker[key].lastCompletedStage`
3. **Stage completion detected** (new completed stage > last tracked):
   - Update `lastCompletedStage` and `lastNotifiedStage`
   - Set `waitingForPromotion = false`
   - **Send stage progress email** via `SendEmailWithAttachments` MCP tool:
     - **Template**: `templates/ev2-stage-progress-email.html`
     - **Subject**: `[ZED] EV2 Stage Complete — {{completedStageName}} ✅ | {{releaseId}}`
     - **Recipients**: resolve via `Resolve-NotificationRecipients -EventKey 'ev2-stage-progress'` (maps to `15-production-rollout.success`; default seed broadcasts to `permanent` + `cc` email groups; owner always included on To-line).
     - **Body**: Render template with `{{dashboardRows}}` = current full dashboard table rows as HTML `<tr>` elements
4. **Waiting for manual promotion detected** (next stage has status `Waiting|NotStarted|Queued` AND all regions in current stage are completed AND `waitingForPromotion` was `false`):
   - Set `waitingForPromotion = true`
   - **Send promotion reminder email** via `SendEmailWithAttachments` MCP tool:
     - **Template**: `templates/ev2-promotion-reminder-email.html`
     - **Subject**: `[ZED] ⏳ Manual Promotion Needed — {{nextStageName}} | {{pipelineName}} {{cloud}}`
     - **To**: recipients from `Resolve-NotificationRecipients -EventKey 'ev2-promotion-reminder'` (maps to `15-production-rollout.halt`; default: owner-only — owners can widen via `routing.15-production-rollout.halt`)
     - **Body**: Render template with pipeline name, cloud, completed stage, next stage, dashboard table
5. **Avoid duplicate emails**: Only send if `lastNotifiedStage` differs from current completed stage, or `waitingForPromotion` transitioned from `false` → `true`

**SDP stage ordering** (for determining "next stage"):
`Canary → Low → Medium → Heavy → Day1 → Day2 → Day3 → Day4 → Day5`
Stages vary per SDP configuration — use `batchStages[]` order from the API response as the source of truth.

**Templates**: `templates/ev2-stage-progress-email.html` (stage completion), `templates/ev2-promotion-reminder-email.html` (promotion reminder). Both include `{{dashboardRows}}` placeholder for an HTML table with the current dashboard. Render using `Expand-Template`.

**Dashboard rows for email**: Convert the markdown dashboard table into HTML `<tr>` rows. Each row: `<tr><td>Pipeline</td><td>Cloud</td><td>Status</td><td>Progress</td><td>Current Stage</td><td>Regions</td></tr>`. Use the same data and format as the chat dashboard but in HTML table syntax.

### Step 15: EV2 Error Analysis — Dynamic Documentation Lookup (sub-procedure)

When composing failure reports or analyzing EV2 errors, the agent must **research the error in real time** using available documentation tools rather than relying on hardcoded error tables. The script (`Get-Ev2RolloutStatus.ps1`) extracts error details from `ResourceOperations[].StatusMessage` and populates `node.errorCode`, `node.errorReason`, and `node.errorDetail`.

#### Error Research Procedure

When an EV2 failure is detected with `node.errorCode` and/or `node.errorReason`:

1. **Search MS Learn docs** — Use `microsoft_docs_search` with the error code and reason as query terms (e.g., `"ClusterChildResourceOperationFailed UpgradeDomainTimeout Service Fabric"`). If a relevant page is found, use `microsoft_docs_fetch` to get the full remediation steps.
2. **Search internal engineering docs** — Use `es_search` (ES Chat) with keywords from the error (e.g., `"UpgradeDomainTimeout SFRP rollout failure"`). Internal docs often have runbooks and TSGs specific to our environment.
3. **Search ADO wiki** — Use `search_wiki` (Bluebird) with the error code to find team-specific troubleshooting pages or past incident write-ups.
4. **Synthesize findings** — Combine documentation results into a concise `agentAnalysis` paragraph that explains: what the error means, likely root cause, and recommended next steps. Cite the source (e.g., "Per MS Learn docs: ...").
5. **If no documentation is found** — State that no documentation was found for this specific error code and include the raw `node.errorDetail` so the release owner can investigate manually.

#### Analysis Heuristics (always apply regardless of lookup results)

When writing failure analysis for email reports:
1. If `errorReason` is present, lead with it: _"UpgradeDomainTimeout on ud:/zone1/3"_
2. If the same `errorCode` repeats across multiple retries with **different** context (e.g., different upgrade domains), note: _"Different targets are failing across retries, indicating a systemic issue rather than a single-resource problem."_
3. Include retry count and time span: _"This region has been failing for {hours}h across {count} retries."_
4. If retries ≥ 3 AND same error pattern persists, recommend: _"This error is persistent and unlikely to self-resolve. Consider: (1) skipping this region in EV2 portal, (2) engaging the owning team via ICM, or (3) investigating the underlying resource health directly."_
5. Always include `node.errorDetail` (full `StatusMessage`) in the email body so the release owner has the complete error without needing to query the API manually.



## Step 16: Create Merge-Back PR

**Deploy-base**: skipped (written as `skipped` at setup) — the release is the deployment branch itself, there is no release branch to merge back. Next month's RI (master → develop) carries any master-only changes.

**Trigger**: Step 15 completed (all EV2 rollouts reported `Completed/Succeeded` — ADO pipeline status is irrelevant per Step 15 spec)
**Actions**:
1. Create PR from `{branch}` to `CONFIG[ado.baseBranch]` via ADO MCP
2. Set PR title: "Merge back: {branch}"
3. Store `mergeBackPrId` in `release.json`
4. No notification (per `notifications.md`: `merge-back` has no email + no Teams)
5. Unregister Task Scheduler task
**State**: Step 16 → `completed`, release status → `completed`
**Watcher**: Cleared — watcher exits on next poll

---
