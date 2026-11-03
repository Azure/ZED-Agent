<!-- Read on demand by ZedAgent: release health check (post-deployment analysis, GO / HOLD / NO-GO). -->

# Release Health

After every deployment wave (canary, then each production stage), ZED decides whether the new build is healthy enough to continue. It compares the deployed stamps **before and after** the upgrade (previous day, same hours; previous week as confirmation). It also compares them with **control** stamps still on the previous build, so environment-wide shifts — a dependency outage, a CRP incident, a holiday dip — cancel out. Every check sends one plain-language email with a verdict and its justification.

| Verdict | Meaning | Mail |
|---|---|---|
| **GO** | No release-correlated degradation after the minimum bake time | `release-health-go` |
| **HOLD** | Something changed by ≥ 10 % (statistically significant) and needs a human look, or a serious signal with uncertain attribution | `release-health-hold` |
| **NO-GO** | Serious regression on the new build (Sev1): large failure-rate jump, new error code or error log on ≥ 2 stamps, CPU/memory limit, restart loop, role start failure, missing telemetry | `release-health-no-go` |
| **INCONCLUSIVE** | Not enough data yet, stale telemetry or a failed query — never treated as GO | `release-health-inconclusive` |
| early warning | A Sev1 found by a tripwire/checkpoint before the final verdict | `release-health-early-warning` (on-call) |
| interim | New Investigate findings at a checkpoint | `release-health-interim` (owner only) |

## Who owns what

| Part | Where | Owner |
|---|---|---|
| Engine: statistics, cohorts, windows, signal rules, verdict, report, scheduling | `zed-agent/scripts/Health/*.ps1`, `health-config.schema.json`, `templates/release-health-email.html` | ZED |
| Skeleton for new services | `zed-agent/templates/service-health-skill/` (scaffolded by `New-ServiceHealthSkill.ps1`) | ZED |
| Service health skill: Kusto tables, KQL, thresholds, markers, suppressions, RCA knowledge | `<repo>/.github/skills/<service>-release-health/` (`SKILL.md`, `health-config.json`, `queries/*.kql`) | Service team |
| Switches, on-call list, routing | `service-config.json → releaseHealth`, `notifications.groups.healthOnCall`, `notifications.routing['release-health' / 'release-health-tripwire']` | Service team (`setup-service group 11`) |

`releaseHealth.mode`: `shadow` — every health mail goes to the owner only (use for the first release). `advisory` — mails follow routing; the verdict informs promotion decisions. `acknowledge` — like advisory, and a HOLD/NO-GO on a wave must be acknowledged (`health override` or `health accept`) before the owner approves the next gate (see *Gates*).

## Flow (no agent involvement until a mail is due)

1. `Release-Watcher.ps1` calls `Invoke-HealthSideChannel.ps1 -Action Start` every 60 s; when a run is due (`timing.planIntervalMinutes`) it starts `-Action Run` as a **background** pwsh process (the watcher never blocks on Kusto).
2. The run finds the stamps on the exact build ZED deployed (`<buildNumber>-<branch>` from `state.json`), groups them into waves (canary first, then by deployment time gaps, labelled with EV2 stage names), and per wave runs at most one check:
   - **tripwire** — every `tripwireIntervalMinutes` from `firstCheckAfterT0Minutes`: Sev1 only, never GO.
   - **checkpoint** — after each completed workload cycle.
   - **final** — after the minimum bake and minimum cycles, once EV2 reports the stage complete or `finalVerdictAfterHours` elapsed. An INCONCLUSIVE final is retried on the next cycle (one mail).
3. Each check writes `.zed-agent/releases/<id>/health/<waveId>/<tier>-<ts>.json` + `.html` and, when a mail is due, queues `state.releaseHealth.notifications.<id>` (status `pending`).
4. The watcher invokes you: **`release health notify <notificationId> for release <releaseId>`**, then marks the notification sent (exit 0) or failed (retried up to 3 times). Do **not** call `-Action Mark` yourself.

## `release health notify <id> for release <rid>` — agent contract

Run non-interactively and EXIT when done. Do not run any release step.

1. **Load.** `Invoke-HealthSideChannel.ps1 -Action Status -ReleaseId <rid>` and read `state.releaseHealth.notifications.<id>` → `kind`, `eventKey`, `json`, `html`, `waveId`. Read the report JSON. Read the service skill `SKILL.md` (`report.config.skillPath`) — it holds the service's failure patterns, dependencies and RCA playbook.
2. **RCA** for every unsuppressed, unaccepted `Sev1` / `Investigate` finding (top 5 by severity if more). Use evidence, not guesses:
   - Drill-downs defined by the service: `Invoke-ReleaseHealthCheck.ps1 -ReleaseId <rid> -Wave <waveId> -AsOf <report.asOf> -Drilldown <id> -DrilldownParams @{ ... }` (same stamps, windows and placeholders as the check).
   - Read-only ad-hoc KQL against `report.config.cluster` / `database` (Kusto MCP), starting from each finding's `queries[].adxLink`. Always filter by unit and time first.
   - Is it on the control stamps too (environmental)? Did it exist on other builds (pre-existing)? Is it one subscription/customer (customer)? Is it on all release stamps from T0 (regression)? Suspect changes: Step 4 commit list (`state.step4ExcelUrl` / `commits.xlsx`) — name commits only when the code path matches the error.
   - Classify: `regression` | `environmental` | `customer` | `pre-existing` | `data-quality` | `unknown`; confidence `high` | `medium` | `low`.
3. **Annotate.** Write an RCA file and apply it — this re-renders the HTML and updates subject / eventKey:
   ```json
   { "agentNotes": "One-paragraph summary for the team.",
     "findings": { "F-1a2b3c4d5e": { "classification": "regression", "confidence": "high", "summary": "...", "evidence": ["..."], "suspects": ["commit abc123 — ..."], "recommendation": "Roll back the wave / hold promotion / no action" } },
     "escalate": { "verdict": "NO-GO", "reason": "..." } }
   ```
   `Invoke-HealthSideChannel.ps1 -Action Annotate -ReleaseId <rid> -NotificationId <id> -RcaFile <file>` → returns the updated notification.
   You may only **escalate** (GO → HOLD/NO-GO, HOLD/INCONCLUSIVE → NO-GO) and must give a reason. Never lower a verdict — owners do that with `health override` / `health accept`. If RCA shows a Sev1 is environmental or a customer issue, say so in `rca` and recommend `health accept`; the verdict stays.
4. **Send.** Recipients: `Resolve-NotificationRecipients.ps1 -EventKey <notification.eventKey>` (shadow mode → owner only; on-call gets early warnings and NO-GO by default). `SendEmailWithAttachments` with subject = `notification.subject`, HTML body = the file at `notification.html`, attachment = the report JSON. For HOLD / NO-GO / early-warning also post a short Teams message (verdict, top reason, link to the dashboard) to the routed Teams groups.
5. **Audit + lessons.** `Annotate` writes `health-annotated`; append a `health-mail-sent` audit row with recipients count. Threshold or query problems found during RCA → `Add-Lesson.ps1` and tell the owner which `health-config.json` field to tune.
6. EXIT 0. If mail fails, exit non-zero (the watcher retries).

## Owner commands

| Command | Action |
|---|---|
| `health status` | `-Action Status`: per wave — stamps, T0, latest tier and verdict, final verdict, override, report link; pending mails; last run summary. |
| `health run [wave]` | `-Action Start -Force` (background run now). With a wave: `Invoke-ReleaseHealthCheck.ps1 -ReleaseId <rid> -Wave <id> -Tier checkpoint` in the foreground and show the result. |
| `health report [wave]` | Open/summarize the latest report HTML of the wave (verdict, reasons, findings with RCA). |
| `health accept <findingId> <reason>` | `-Action Accept -FindingId … -Reason … -By <owner>` — the finding stops counting from the next check (e.g. confirmed environmental). |
| `health override <wave> GO\|HOLD\|NO-GO <reason>` | `-Action Override -WaveId … -Verdict … -Reason … -By <owner>` — owner decision, shown in every later report. |
| `health suppress <signalId> <keyRegex> <reason> [expires]` | Add to the service skill `health-config.json → suppressions[]` (commit to the service repo) — permanent known noise. |
| `health backtest <build> <asOf> [wave]` | `Invoke-ReleaseHealthCheck.ps1 -ReleaseVersion <build> -AsOf <asOf> [-Wave …] -OutDir .zed-agent/health-runs/...` — replay a past release (no mail). |
| `health validate` | `Test-ServiceHealthSkill.ps1` — schema, TODOs, live dry run of every query. |

## Gates

- **Step 6 (`approve-bvt`)** and **Steps 9 / 12**: before approving, show the canary wave's latest health verdict (`health status`). In `acknowledge` mode refuse the approval while the canary wave's verdict is HOLD/NO-GO without an override; in `advisory` mode warn and continue.
- **Step 15 (EV2 promotion reminders, `ev2-promotion-reminder`)**: include the verdict of the waves already deployed. In `acknowledge` mode do not recommend promoting past a wave with HOLD/NO-GO without an override. ZED never promotes or rolls back automatically on a health verdict — the owner decides.

## State (`state.releaseHealth`)

`releaseVersion`, `previousVersion`, `errorClassificationCommit` (pinned for the whole release), `waves.<id>` {label, isCanary, units, t0First, t0Last, lastTripwireAt, lastCheckpointCycle, finalAt, finalVerdict, reports[], alertedKeys, reportedKeys}, `notifications.<id>` {kind, eventKey, waveId, tier, verdict, subject, json, html, status, attempts}, `accepted[]`, `overrides.<waveId>`, `running`, `lastRunAt`, `lastRunSummary`. Audit events: `health-run-started`, `health-check`, `health-check-error`, `health-run-error`, `health-notification`, `health-annotated`, `health-accepted`, `health-override`.

## Onboarding a service

`setup-service group 11` — asks every service detail (telemetry tables, unit and version formats, workload tables, error classification source, error logs, counters, upgrade markers and role start-failure prefixes per role, timing, thresholds, RCA knowledge), scaffolds the service skill with `New-ServiceHealthSkill.ps1`, fills it, validates it with `Test-ServiceHealthSkill.ps1` and offers backtests. The skeleton README (`templates/service-health-skill/README.md`) defines the placeholders and the output columns every query must return.
