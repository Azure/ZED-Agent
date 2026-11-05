# Service release-health skill — skeleton and contracts

ZED's release health check is split in two:

| Part | Lives in | Owns |
|---|---|---|
| **Engine** (service-agnostic) | ZED-Agent: `.github/skills/zed-agent/scripts/Health/*`, `health-config.schema.json` | Cohorts and waves, comparison windows, statistics, verdict rules, reports, watcher scheduling, notifications |
| **Service skill** (service-owned) | The service repo: `.github/skills/<service>-release-health/` | Tables, columns, KQL, markers, error classification source, thresholds, RCA knowledge |

`setup-service group 11` (or `scripts/Health/New-ServiceHealthSkill.ps1`) copies this skeleton into the service
repo, asks the release owner for every value, and validates each query against Kusto with
`scripts/Health/Test-ServiceHealthSkill.ps1`. Nothing service-specific is ever added to the engine.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | Service-specific validation knowledge for the agent: telemetry, signals, RCA playbook, known background issues |
| `health-config.json` | All settings (validated against `zed-agent/health-config.schema.json`) |
| `queries/*.kql` | One query per signal or drill-down, implementing the contracts below |

## Engine placeholders (substituted in every query)

| Placeholder | Value |
|---|---|
| `{{UNITS}}` | `dynamic([...])` — every unit (stamp) in this query's windows. **Filter on it before any join** (big tables). |
| `{{RELEASE_UNITS}}`, `{{CONTROL_UNITS}}` | `dynamic([...])` of release / control units |
| `{{WINDOWS}}` | `datatable(Unit:string, Cohort:string, Window:string, WStart:datetime, WEnd:datetime)[...]` — `Cohort` is `release` or `control`; `Window` is `current`, `previousDay` or `previousWeek` |
| `{{MIN_TIME}}`, `{{MAX_TIME}}` | `datetime(...)` bounds of all windows (spans the whole week when `previousWeek` is used) |
| `{{TIME_FILTER}}` | Predicate `(TIMESTAMP between (..) or TIMESTAMP between (..))` covering only the windows' ranges — **use it as the first filter of windowed queries** on big tables (assumes the time column is `TIMESTAMP`; otherwise use `MIN_TIME`/`MAX_TIME`) |
| `{{WINDOWS_WIDE}}`, `{{WINDOW_CASE}}` | One row per unit (`Unit, Cohort, currentStart, currentEnd, previousDayStart, …`) and the matching `case(TIMESTAMP between …, 'current', …, '')`. Use `lookup kind=inner ({{WINDOWS_WIDE}}) on Unit \| extend Window = {{WINDOW_CASE}} \| where isnotempty(Window)` on **raw** rows — 1:1, no fan-out |
| `{{T0S}}` | `datatable(Unit:string, T0:datetime)[...]` — when each release unit switched to the new build |
| `{{RELEASE_VERSION}}`, `{{PREVIOUS_VERSION}}` | Quoted version strings as they appear in telemetry |
| `{{AS_OF}}` | `datetime(...)` — evaluation time (supports backtests) |
| `{{LOOKBACK_START}}`, `{{LOOKBACK_END}}` | Cohort / signature-history lookback |
| `{{SIGNATURE_EXPR}}` | KQL expression that normalizes the column `Message` into a stable signature (from `signatureNormalization`) |
| `{{SIGNATURES}}` | `dynamic([...])` candidate signatures (signature-history query only) |
| `{{COUNTER_NAMES}}` | `dynamic([...])` counter names of a `counters` signal |
| `{{PARAM_<NAME>}}` | Every key in the signal's `params` (camelCase → UPPER_SNAKE): strings quoted, numbers raw, arrays as `dynamic([...])` |

The standard window pattern — **pre-aggregate per minute (t-digest / hll for percentiles and distinct counts) before
joining the windows**; each row matches up to three windows, so a raw join on a big table exceeds Kusto's memory
budget (the engine treats partial results as a failed query → INCONCLUSIVE):
```kql
let W = {{WINDOWS}};
MyTable
| where {{TIME_FILTER}}
| where Stamp in ({{UNITS}})
| summarize Total = count(), Failures = countif(not(Ok)) by Unit = Stamp, TIMESTAMP = bin(TIMESTAMP, 1m), Operation
| join kind=inner hint.strategy=broadcast (W) on Unit
| where TIMESTAMP between (WStart .. WEnd)
| summarize Total = sum(Total), Failures = sum(Failures) by Unit, Window, Operation   // or Cohort, Window for cohort-level kinds
```

## Output contracts

| Query | Required columns | Notes |
|---|---|---|
| `cohortQuery` | `Unit, Version, FirstSeen, LastSeen, Ops` | One row per unit × build seen between `{{LOOKBACK_START}}` and `{{AS_OF}}`. T0 = `FirstSeen` of the release build. |
| `exposureQuery` | `Unit, Window, Version, Ops, Instances` | Operation volume per window and build. Used for version purity, silent units and normalization. |
| `freshness.queryFile` | `Source, Latest, LagMinutes` | One row per table the signals read. |
| kind `outcomes` | `Unit, Window, Operation, ErrorCode, Total, Failures` (+ optional `TopSubscriptionFailures`) | `ErrorCode` must be `''` for successes. `Total` counts all rows in the group, so the sum of `Total` = all operations. Compute `TopSubscriptionFailures` over **real** subscriptions only (exclude empty / all-zero GUID placeholders), or every failure without a subscription looks like one customer. |
| kind `latency` | `Cohort, Window, Operation, N, P50, P95` | Cohort-level percentiles (successful operations). |
| kind `signatures` | `Cohort, Window, Signature, Count, Stamps, Instances` (+ optional `TopSubscriptionCount`) | Use `extend Signature = {{SIGNATURE_EXPR}}` on error-level rows. |
| `historyQueryFile` | `Signature, Count` | Occurrences of `{{SIGNATURES}}` on any build other than `{{RELEASE_VERSION}}` between `{{LOOKBACK_START}}` and `{{LOOKBACK_END}}`. |
| kind `counters` | `Unit, Window, RoleInstance, Counter, Avg, P95, Min, Max` | One row per machine and counter. |
| kind `series` | `Unit, Role, Counter, Bucket, Avg` | Hourly averages in the `current` window (leak detection). |
| kind `lifecycle` | `Unit, RoleInstance, Service, Event, Version, Timestamp` (+ optional `Pid`) | `Event` ∈ `init`, `init-failed`, `stop-requested`, `stop-unrequested`, from `T0 - 45m` to `{{AS_OF}}`. |
| `startFailureQueryFile` | `Unit, Role, Version, Count, First, Sample` | Role start failures (role recycling) since T0. |
| RCA drill-downs | free-form | Run by the agent during RCA; keep them capped (`take`). |

## Signal kinds and what the engine decides

| Kind | Finding rules (defaults; override per signal in `thresholds`) |
|---|---|
| `outcomes` | Service-failure rate (user errors excluded via `errorClassification`) ≥ 10% worse than the previous build, q ≤ 0.01, ≥ 20 extra failures and not explained by the control → **Investigate**. `thresholds.sev1` (e.g. ratio 2, absDelta 0.01) → **Sev1**. Also per operation, per unit, per error code, new service error codes on ≥ 2 units (Sev1), volume drop ≥ 30% (Sev1). Codes concentrated in one subscription → **Watch**. |
| `latency` | p95 ≥ 10% and ≥ `minDeltaMs` slower than the previous build, not explained by the control → Investigate. |
| `signatures` | Signature rate ≥ 10% worse on ≥ 2 units → Investigate; `thresholds.sev1` → Sev1; a signature absent from both baseline windows, the control and the lookback history on every other build → Sev1. |
| `counters` | `p95-shift` / `avg-shift`: ≥ `relativeDelta` and ≥ `minDelta` worse → Investigate; `ceiling` → Sev1. `floor`: below → Sev1. |
| `series` | Growth ≥ `maxGrowthPctPerHour` over ≥ `minHours` → Sev1 (leak). |
| `lifecycle` | Role start failure, failed init, unrequested stop of the new build, ≥ `loopRestarts` starts within `loopWindowMinutes` (duplicates within `dedupeMinutes` collapsed) → Sev1; no lifecycle events → Inconclusive. |

Verdict: any release-correlated Sev1 → **NO-GO**; data-quality problem or bake not reached → **INCONCLUSIVE**;
any open Investigate → **HOLD**; otherwise **GO**. NO-GO is a notification only.
