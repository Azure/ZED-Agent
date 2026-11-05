# Release Health Simulation — BCM2610_2 Day2 (`3.0.886.0-master`)

**Run:** 2026-10-30 ~13:00Z · **Mode:** simulation (manual replay of the design; no email sent)
**Design:** [release-health-analysis.md](./release-health-analysis.md) · **Overview:** [release-health-overview.md](./release-health-overview.md)

---

## Verdict: 🟢 GO — no release regression found on Day2

> Build `3.0.886.0-master` on the 19 Day2 Public stamps, **~25 h after the switch** (six 4-hour
> backup cycles), shows **no health regression** compared with the previous release, `3.0.883.0-master`.
> Backups, restores, sub-operations, error logs, CPU, memory, and the service upgrade are all
> healthy. The automated first pass raised 5 Sev1 and 271 investigation findings. RCA showed that all of them were
> **environmental, customer-specific, pre-existing, or caused by rule defects in the simulation** (see §4).
>
> **Recommendation:** promote to the next stage when Day2 managed validation completes. Four
> watch items are listed in §5.

| Item | Value |
|---|---|
| Stage | Day2 (Public) — EV2 regions deployed 10/29; stage still in managed validation |
| Stamps (19) | acl, ase, inc, frc, gn, itn, jpe, jic, krc, mys, nwe, plc, san, sea, spc, sds, szn, uan, uks |
| T0 (telemetry) | 10/29 10:09–11:28Z; 99.76% of Day2 operations in the analysis window ran `886` |
| Bake analysed | T0+15 min → T0+24 h for each stamp (6 backup cycles; minimum required 8 h) |
| Previous-release baseline | Same stamps, same hours, one week earlier: 100% on `3.0.883.0-master` |
| Control | 29 stamps still on `3.0.883.0-master` in the same window |
| Second treatment cohort | 23 Low–Day1 stamps already on `886` (Earlier886) |
| Error classification | `ExpectedCloudErrors.xml` @ `develop` `f48d8a95e2` |
| Data freshness | 3–9 min ingestion lag on all six tables ✅ |

---

## 1. Scorecard (Day2, `886` vs same stamps on `883`)

| Area | This release | Previous release | Change | Control change | Result |
|---|---|---|---|---|---|
| **Backups** — service-failure rate | 0.011% (690,580 ops) | 0.011% (689,511 ops) | 0.93× | 0.55× | ✅ |
| Backups — volume | 690,580 | 689,511 | 1.00× | 1.00× | ✅ |
| Backups — ManagedFullBackUp p95 duration | 236 min | 245 min | −4% | 0% | ✅ |
| Backups — ManagedInstantRpBackUp p95 duration | 22 min | 22 min | 0% | −16% | ✅ |
| **Restores** — service-failure rate | 0.12% (824) | 0.21% (963) | 0.58× | 1.36× | ✅ |
| **Protection** — service-failure rate | 1.02% | 0.32% | 3.2× | 0.63× | ✅ after RCA (single-subscription, started before T0; §4) |
| **Sub-operations** — all failures per M ops (adjacent days) | 18,859 | 18,713 | +0.8% | +0.3% | ✅ |
| CRP calls — p95 latency (adjacent days) | — | — | −2% to 0% | −9% to −4% | ✅ |
| CRP `TaskCanceled` per M calls (adjacent days) | 538 | 575 | **−7%** | −19% | ✅ (§3) |
| **Errors** — Level ≤ 1 per M ops | 123,919 | 128,001 | 0.97× | 0.95× | ✅ |
| **Upgrade** — instances initialized on `886` | 19/19 stamps, all instances | — | — | — | ✅ |
| Upgrade — role start failures (`OnStart … role recycling`) | 0 | — | — | — | ✅ |
| Upgrade — unrequested stops / restart loops | 0 | — | — | — | ✅ (§4) |
| **CPU** — median per-VM p95 | 24.0% (max 48.8%) | 25.2% | −5% | +1% | ✅ |
| **Memory** — lowest available | 2,436 MB (frc) | 3,131 MB | — | — | ✅ (> 1 GB floor; watch) |
| Memory — committed growth (TEE) | ≤ 0.68%/h | — | — | — | ✅ (< 2%/h; watch frc) |
| CLR exceptions/sec (median p95) | 361 | 375 | −4% | +2% | ✅ |
| Process restarts (≥ 3 PIDs/instance-hour) | 0 | 0 | — | — | ✅ |
| Cycle bursts (30-min backup service-failure buckets) | 0 flagged | — | — | — | ✅ |

---

## 2. What the automated first pass flagged

Using week-over-week comparison and the rules as first implemented, the simulation found:

| Severity | Area | Count |
|---|---|---|
| Sev1 | Upgrade — "restart loop" on sea, jpe, san | 3 |
| Sev1 | Errors — "new" Level ≤ 1 signatures | 2 |
| Investigate | Error-log signatures | 234 |
| Investigate | Sub-operation failures | 16 |
| Investigate | Latency | 13 |
| Investigate | Protection | 8 |

As written, the rules would have produced **NO-GO**. RCA cleared every finding, as shown below. The
design must change so that these cases do not reach the team (§6).

---

## 3. Key RCA: CRP `TaskCanceled` and latency (BCM2609-2 pattern)

Week over week, Day2 `TaskCanceled` errors on CRP calls were **2.2× higher**. `CRPRequestFailedForManagedDisks`
errors were **2.0× higher**, and CRP p95 latency was 10–18% higher. Because BCM2609-2 had a
`TaskCanceledException` regression, this needed a definitive answer.

**Adjacent-day before/after (same stamps, same 22.5 h of day, only the build changes):**

| Cohort | Build before → after | `TaskCanceled` / M CRP calls | `CRPRequestFailedForManagedDisks` / M |
|---|---|---|---|
| **Day2** | `883` → `886` | 575 → 538 (**−7%**) | 54.1 → 48.1 (**−11%**) |
| Control | `883` → `883` | 708 → 572 (−19%) | 59.6 → 46.4 (−22%) |
| Earlier886 | `886` → `886` | 918 → 939 (+2%) | 90.8 → 70.7 (−22%) |

**Conclusion:** Day2 stamps were already at 575 per M on 10/28 while running `883`, compared with 249 per M
one week earlier. The increase happened **before** `886` arrived, and the rate fell after the switch.
This is an **environmental CRP change** that affected all builds this week, **not a release regression**. CRP p95 latency
was also flat in the adjacent-day comparison: Day2 changed by −2% to 0% on all eight CRP calls. Two non-CRP calls rose
by less than 10%: `ModifyProtection` +5% and `CloudQueueAddMessage` +9%.

---

## 4. RCA of every first-pass finding

| Finding | Evidence | Classification |
|---|---|---|
| **Sev1 restart loop** — sea, jpe, san | Each flagged instance had **one** `stopRequested = True` on `883`, followed by 2–3 identical `initialized = True` lines on `886` within the same minute. There were no unrequested stops, and no instance had ≥ 3 PIDs in any hour. | ❌ False positive — duplicate log lines from one restart |
| **Sev1 new signature** `Retrying GetILRSasTier1` (27 on 3 stamps) | Also on `883` (114, 18 stamps) and `881` (91, 13 stamps) since 10/15. ILR volume is low, so the two comparison windows happened to contain none. | Pre-existing |
| **Sev1 new signature** `ResourceGroupNotFound … 'dedica…'` (22 on 2 stamps) | Error text contains a customer resource-group name; the resource group is missing in the customer subscription. | Customer error |
| Protection service failures 3.2× (`RemoveProtection`, `CatalogInternalError` 147 vs 1) | On `frc`, **one subscription** issued bulk `RemoveProtection` calls. Errors started at **07:00–08:00Z on 10/29, before `frc` switched builds at 10:10Z**. Control stamps on `883` had 227–387 `CatalogInternalError` errors per day on 10/22–24 and 10/27–28. Earlier886 stamps had none on 10/29–30. | Pre-existing; one customer |
| Protection failures with `ErrorCode = Success` on `uan` (33) | One subscription, `RemoveProtection` (BMS-side result coding) | Customer/BMS anomaly; watch |
| Sub-operation `BeginCreateManagedDisk` 27% failures (`CreateManagedDisksFailed`) | 272/339 on `frc`, **one subscription**, CRP `InternalOperationError`, with repeated retries of the same customer restore | Dependency (CRP) / one customer |
| CRP `TaskCanceled` ↑, `CRPRequestFailedForManagedDisks` ↑, CRP p95 ↑ 10–18% | Adjacent-day comparison is flat or improved on Day2 (§3) | Environmental (this week) |
| `CloudServiceRetryableError`, `AzureOperationFailed`, `GetManagedRestorePointCollectionFailed` | Adjacent days: +3%, +7%, +15 failures (below the 20-failure minimum). All failures together rose +0.8%. | No regression |
| `UserErrorSubscriptionNotFound`, `UserErrorUltraDisk…` in sub-operations | User errors under `ExpectedCloudErrors.xml` | Customer error (rule defect: sub-operation codes were not classified) |
| 234 error-log signatures | Most contain customer resource names or URIs on **1 stamp**. Adjacent-day error rates were flat (0.97× overall). | Noise (signature normalization defect) |

---

## 5. Watch items for the next stage

1. **`frc` TEE memory:** committed bytes are growing **0.68%/h** over 25 h; the lowest available memory is 2.4 GB.
   This is below the limits (2%/h, 1 GB) and is probably post-restart warm-up. Confirm that it levels off at the next checkpoint.
2. **CRP `TaskCanceled` is elevated across all regions this week** (all builds, compared with the week of 10/22).
   It is not caused by the release, but it matters because of the BCM2609-2 history. Track it in the next stage.
3. **Earlier886 stamps:** `CloudServiceRetryableError` doubled between 10/28 and 10/30, while those stamps ran `886` on both days.
   This is environmental for those stamps; watch it.
4. **Protection anomalies affecting one subscription each** (`CatalogInternalError` on `frc`, `ErrorCode = Success` on `uan`): consider informing BMS.

---

## 6. Design learnings from this simulation

| # | Learning | Design change |
|---|---|---|
| 1 | **Week-over-week comparison alone produced false regressions** when the environment changed between weeks (CRP this week). The control's previous week was also **57% on `881`**, the BCM2609-2 build, so the control baseline was contaminated. | Make the **adjacent-day before/after comparison around T0, on the same stamps** a primary comparison. Before using a control baseline, check that it ran only the expected version. |
| 2 | Restart-loop rule fired on duplicate `initialized` lines from one restart. | Count **distinct restarts** (PID change or unrequested stop), not log lines. Ignore duplicates within 5 min. |
| 3 | "New signature" checked only two windows, so a low-volume, pre-existing ILR retry looked new. | Look back **14 days across all versions** before calling a signature new. |
| 4 | 234 of 271 investigation findings were error-log signatures with customer identifiers on one stamp. | Remove quoted names, URIs, resource-group and VM names from signatures. Require **≥ 2 stamps** for error-log investigation findings. |
| 5 | Several findings came from **one subscription**. | Automatically classify a finding as customer/dependency when ≥ 80% of failures come from one subscription, and show it as a watch item. |
| 6 | Sub-operation error codes were not classified as user or service errors. | Apply `ExpectedCloudErrors.xml` to sub-operation error codes too. |
| 7 | `OperationStatsLocalAll` and `TraceLogMessageAll` queries failed or took more than 10 min without stamp pre-filters. The error-log scan took 8 min for 48 stamps over 2 days. | Always filter `DeploymentUnit in (…)` before joins. For error-log checks, use sampled or hourly pre-aggregated signatures. Set query budgets per checkpoint. |

---

## 7. Method (as run)

- **Cohorts from telemetry:** `OperationStatsLocalAll.ProcessVersion` gives T0 per stamp. Control = stamps still on `883`.
- **Windows:**
  - Current: T0+15 min → T0+24 h for each stamp.
  - Previous release: the same hours 7 days earlier.
  - RCA comparisons: adjacent days, 10/28 11:35–10/29 10:05Z versus 10/29 11:45–10/30 10:15Z.
- **Statistics:**
  - One-sided two-proportion z-tests for rates and Poisson rate tests for counts (normalized per operation).
  - Benjamini–Hochberg correction across 7,589 tests.
  - The 10% investigation rule, with q ≤ 0.01, at least 20 extra failures, and difference-in-differences against the control.
- **Data:** aggregate queries only, from `BCMBackupStatsAllClusters`, `BCMRecoveryStatsAllClusters`, `BMSProtectionStatsAll`,
  `OperationStatsLocalAll`, `CounterEventsLocalAllClusters` (`ServiceName == "ic"`), and `TraceLogMessageAll`.
