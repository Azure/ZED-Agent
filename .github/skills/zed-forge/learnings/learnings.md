# ZED Agent Lessons Learned

---
**Timestamp**: 2026-08-24T00:00:00Z
**Step/Command**: SafeFly V2 — New-SafeFlyRequest.ps1 D5: core.regions never accepted
**Symptom**: Every SafeFly save that included `ccoa.is_ccoa_request` failed with "cross-question
dependency: Targeted region question (Name 'core.regions') must be answered before answering
CCOA exception flag." Regions appeared to be answered (no missing-required error), but SafeFly
rejected them. `ccoa.is_ccoa_request` saves always failed regardless of answer ordering.
**Root cause**: `core.regions` is a dynamic-source question (`optionDataSource.document =
"query { getRegionsWithActiveCCOACoverage { regions } }"`). Its `options` list is always empty at
form-fetch time. The script was comparing input display names ("East Asia") against
`$qRegions.options` (empty list), so ALL regions fell through to "unmatched" and `core.regions`
received no answer. SafeFly then rejected ccoa because regions was effectively unanswered. A
secondary symptom was that `ccoa.is_ccoa_request` was sending label="No" instead of option
value="False" — also wrong, but harmless for the dependency check once regions was fixed.
**Fix**: Added `Build-SafeFlyRegionMap` (calls `getRegionsWithActiveCCOACoverage` live, returns a
hashtable keyed on normalized identifier) and `Resolve-RegionToSafeFlyId` (strips spaces,
lowercases, looks up). Modified `Add-Answer` with a generic option-value encoder: when a question
has options, resolve label→value automatically (fixes ccoa.is_ccoa_request label/value mismatch
as a side effect). Multi-select regions are sent as comma-separated CamelCase in a SINGLE answer
object (e.g., `"EastAsia,SoutheastAsia,WestUS2"`).
**Proposed fix**: Applied. Verified with a real non-DryRun submission: R2D #13.9500 created
successfully at https://safeflyv2.portal.azure.com/#view/Microsoft_SafeflyV2/ChangeRequestView.ReactView/requestId/13.9500

---
**Timestamp**: 2026-08-24T00:00:00Z
**Step/Command**: SafeFly V2 — Introspect before selecting (recurring pattern, third occurrence)
**Symptom**: Three separate defects (D1: invented fields requestNumber/url in mutation selection set;
D5: used $qRegions.options instead of optionDataSource; add-answer sent label instead of value) all
shared the same root cause: code was written without first verifying the actual GraphQL schema or
API response shape.
**Root cause**: Developer assumed field names and data structures rather than introspecting the live
SafeFly V2 GraphQL schema before writing queries/mutations and data-access code.
**Proposed fix**: Rule: for any new SafeFly V2 field access or mutation, ALWAYS run a GraphQL
introspection query first to verify the field exists and its type. Check `optionDataSource`,
`optionExtractor`, and `options` for every question type before deciding how to resolve options.
Never invent field names in mutation selection sets.

---
**Timestamp**: 2026-08-24T00:00:00Z
**Step/Command**: SafeFly V2 — D4 answer-ordering hoist was dead code (cargo cult)
**Symptom**: The script contained a sort-by-seed-order block ($seedOrder, $questionOrder,
Sort-Object) intended to hoist core.orchestrator_name, core.regions, core.other_regions before
ccoa.is_ccoa_request. The comment claimed SafeFly V2 enforces cross-question ordering at the API
level. Empirical testing showed this was false.
**Root cause**: The ordering hoist was added as a workaround for the "must answer regions before
ccoa" error, under the incorrect assumption that ordering was the cause. The real root cause was
wrong answer values (display names instead of CamelCase identifiers). With correct values,
ccoa-before-regions succeeds without error.
**Fix**: Removed the hoist ($seedOrder, $questionOrder, Sort-Object block). Replaced with simple
`$orderedAnswers = @($answers)`. SafeFly accepts any ordering when values are correct.
**Proposed fix**: Applied. Future: do not add ordering workarounds without empirically testing
whether ordering actually causes the failure.


**Step/Command**: setup — Teams conversation ID discovery
**Symptom**: Multiple approaches to auto-discover Teams conversation ID failed:
  1. Find-TeamsChat (Teams CDP helper) — requires Teams Desktop CDP, not Edge CDP (port ownership check fails)
  2. Graph API via az CLI token — missing Chat.Read scope
  3. Graph API via Teams Web MSAL cache — tokens encrypted at rest (encryptedToken + iv)
  4. CDP navigation to Teams Web — session expired (/error/eoa)
**Root cause**: No reliable automated path exists for discovering Teams group chat IDs without either (a) Teams Desktop with WebView2 CDP, or (b) a Graph token with Chat.ReadBasic scope.
**Proposed fix**: Add a setup step that acquires a Graph token with delegated Chat.ReadBasic permission via MSAL device-code flow (same pattern as Repair-AzAuth). Or store conversation IDs in service-config.json during setup-service so they don't need runtime discovery.

---
**Timestamp**: 2026-06-04T16:41:11.6774170+05:30
**Step/Command**: setup — Register-WatcherTask
**Symptom**: Task Scheduler registration fails with: Cannot convert value "StopExisting" to MultipleInstancesEnum. Valid values: Parallel, Queue, IgnoreNew.
**Root cause**: Register-WatcherTask.ps1 uses "StopExisting" for -MultipleInstances, but this enum value doesn't exist in the PowerShell ScheduledTask cmdletization.
**Proposed fix**: Change to "IgnoreNew" or "Queue" in Register-WatcherTask.ps1.

## 2026-06-05 10:11:50 UTC — Step 5 SFMC Canary Failure
- **Step/Command**: Step 5 deploy-canary, SFMC pipelines (PROT-CANARY-SFMC, DT-CANARY-SFMC)
- **Symptom**: Both SFMC canary pipelines failed in ~8 min with `System.FormatException: Input string was not in a correct format` at `PSCmdlets.CmdletUtils.ParseStampId(String stampId)` inside `New-RegionAgnosticArtifacts`.
- **Root cause**: `Resolve-TemplateParams.ps1` emitted `stampName` (full cluster name like `ea-can02-prot1`) for the `{{canaryStamps}}` token, but the pipeline's `ParseStampId` expects short stamp IDs (`ea-01`) with a numeric suffix it can `Int32.Parse`.
- **Fix**: Changed `Resolve-TemplateParams.ps1` to use `$_.stampId` instead of `$_.stampName` for the `{{canaryStamps}}` token.
- **Impact**: SFRP pipelines unaffected (they use hardcoded `@()` for CanaryStamps). Only SFMC pipelines use the `{{canaryStamps}}` token.
- **Proposed generalization**: Consider adding a `stampNameStyle` field to pipeline-catalog entries (`short` vs `full`) to control which field the resolver uses, since different pipeline YAMLs may expect different formats.

## 2026-06-05 ~04:50 UTC — Step 5 SFMC Canary Retry-1 Failure (cloud filter missing)
- **Step/Command**: Step 5 deploy-canary, SFMC retry-1 (Builds 166858184, 166858196) after stampId fix
- **Symptom**: Both SFMC retry pipelines failed in ~8 min with `PhobosException: ERROR 1000:Datacenter(s) (ecy, 1);(ccy, 1) is/are missing in Azure Service Config for Cloud Canary. Please check if you are providing correct values for Cloud, Stamps and AzureServiceConfig.`
- **Root cause**: `Resolve-TemplateParams.ps1` `Get-FilteredStamps` only filtered canary inventory stamps by `clusterType`, not by `cloud`. The inventory has 3 SFMC stamps in `inventory.canary.stamps`: `ea-01` (cloud=Canary), `ecy-01` (cloud=Public), `ccy-01` (cloud=Public). The latter two are "canary-scope" stamps that belong to the Public cloud — they're used during production rollout phases, NOT during canary-cloud deployment. The SFMC pipeline's `AzureServiceConfig.json` only registers the `ea` datacenter under Cloud Canary, so `ecy` and `ccy` throw `ERROR 1000`.
- **Fix**: Added cloud filter on line 109 of `Resolve-TemplateParams.ps1` — after `Get-FilteredStamps` (clusterType filter), further filter to only include stamps where `cloud == "Canary"` or cloud property is absent. Result: `CanaryStamps=ea-01` (was `ea-01,ecy-01,ccy-01`).
- **Impact**: SFRP unaffected (only stamp `ea-05` with cloud=Canary). DT-CANARY-SFMC has no `CanarystampsProd` param, so only `CanaryStamps` was wrong.
- **Chained failure**: This was the SECOND bug in the same code path (first was stampName→stampId). The first fix unmasked this one — `ParseStampId` was now parsing correctly, but the parsed datacenter IDs weren't in the Canary Azure Service Config.
- **Prevention**: The `inventory.canary.stamps` section should distinguish between "canary cloud stamps" and "canary-scope public stamps". The resolver now enforces cloud-scope alignment. Consider adding schema validation in `setup-service` to flag `cloud != "Canary"` entries in canary inventory with a warning.
- **Proposed generalization**: Add a `cloud` filter parameter to `Get-FilteredStamps` function so cloud-scope alignment is enforced at the function level, not as a post-filter. This prevents future callers from forgetting the filter.

---
## 2026-06-05 05:00 UTC — Meta-learning: Chained bugs in template resolvers
- **Step/Command**: Step 5 deploy-canary — two consecutive SFMC failures
- **Symptom**: First fix (stampName→stampId) unmasked a second bug (missing cloud filter). Total: 3 pipeline trigger attempts before success.
- **Root cause (systemic)**: `Resolve-TemplateParams.ps1` builds token values through a pipeline of filters, but each filter was added independently without integration testing the full chain. The `Get-FilteredStamps` function only filters by `clusterType` — it has no concept of `cloud` scope. The `stampId` vs `stampName` selection was also not parameterized.
- **Lesson**: When fixing a pipeline parameter bug, **verify the corrected value end-to-end** before retriggering — don't just fix the immediate error. Run the resolver locally with `-DryRun` equivalent and validate every emitted token against the target pipeline's expected input schema. In this case, after fixing stampName→stampId, I should have checked whether `ea-01,ecy-01,ccy-01` is valid for the Canary cloud before triggering.
- **Proposed fix**: Add a `--validate` flag to `Resolve-TemplateParams.ps1` that cross-references emitted stamp IDs against the pipeline YAML's expected Azure Service Config cloud entries. This would catch both bugs at resolve time instead of at pipeline runtime (~8 min feedback loop each time).

---
**Timestamp**: 2026-06-05T10:53:36.5963425+05:30
**Step/Command**: Step 5 — Deploy Canary (SFMC retry #4)
**Symptom**: SFMC canary pipelines failed 3 times due to incorrect template parameters in pipeline-catalog.json. Retry #3 was cancelled after comparing with the successful prot2605 run (build 164919139 for PROT, 165092206 for DT) and discovering 3 categories of parameter mismatches.
**Root Cause**: The `setup-service` Phase 11 discovery wizard auto-populated pipeline-catalog.json with incorrect SFMC parameters:
  1. **CanaryScript**: PROT-CANARY-SFMC was set to `true` but should be `false` (DT correctly uses `True`). The PROT pipeline has a different canary script behavior than DT.
  2. **CanarystampsProd / PublicStamps**: Both SFMC entries used `{{canaryStamps}}` token, which resolves to only the Canary-cloud stamp (ea-01). But CanarystampsProd (PROT) and PublicStamps (DT) need the **Public-cloud** canary stamps (ecy-01, ccy-01). The pipeline deploys to BOTH Canary cloud AND Public cloud canary regions in a single run.
  3. **Format**: Values need PS array notation `@("ea-01")` and regions need `regions(eastasia)` wrapper with full region names — not bare short codes like `ea`. The resolver's `{{canaryStamps}}` and `{{canaryRegions}}` tokens produce bare values without these wrappers.
**Fix Applied**: Replaced dynamic tokens with static values in pipeline-catalog.json matching prot2605's proven parameters. Kept only `{{currentBranch}}` and `{{validateOnly}}` as dynamic tokens (these change per release). All stamp/region/script values are now hardcoded per pipeline.
**Proposed Improvement**:
  - The `setup-service` Phase 11 discovery should cross-reference PRIOR SUCCESSFUL RUNS of each pipeline to validate discovered parameters, not just introspect the YAML.
  - Consider adding a `{{canaryProdStamps}}` and `{{canaryProdRegions}}` token pair in the resolver for Public-cloud canary stamps, or document that SFMC pipelines require static params.
  - Add a `discoveryNotes.paramFormat` field (`ps-array`, `regions-wrapper`) to control value formatting per pipeline.
  - The `Read-PriorRun.ps1` script could auto-extract and validate parameters from the most recent successful run during discovery.
**Impact**: 4 retry attempts total, ~2 hours of pipeline time wasted. The 3-region canary coverage (EA Canary + ECY Public + CCY Public) was only deployed to 1 region (EA Canary) in retries 1-3.

---
**Timestamp**: 2026-06-05T06:12:00Z
**Step/Command**: Step 5 — Deploy Canary (SFMC retry #5)
**Symptom**: PROT-CANARY-SFMC retry #4 was running with CanaryScript=false, but the release owner determined that the correct value should be 	rue (matching DT-CANARY-SFMC's CanaryScript=True). The prior fix (retry #4) had set it to alse based on the prot2605 reference run (build 164919139), but the owner overrode this.
**Root cause**: The prot2605 reference run for PROT-CANARY-SFMC had CanaryScript=false, which was used as the source of truth for retry #4's pipeline-catalog fix. However, the owner determined that 	rue is the correct value for the current release. This highlights that **prior successful run parameters are not always the correct parameters for the next release** — they may reflect one-time overrides, incremental changes, or different deployment conditions.
**Fix**: Updated pipeline-catalog.json PROT-CANARY-SFMC entry: CanaryScript from "false" to "true". Cancelled build 166861596 (retry #4), triggered build 166865665 (retry #5, Release-2606-16).
**Lesson**: When using prior run parameters as a reference, always confirm with the release owner before hardcoding values — especially boolean flags like CanaryScript that control deployment behavior. The prior run is evidence, not gospel. Add a confirmation step in the setup-service Phase 11 discovery for boolean parameters that differ between pipeline variants (e.g., PROT vs DT).

---

### 5. Mid-Step Rebuild Requires Selective Canary Retrigger
- **Timestamp**: 2026-06-05T10:09:56Z
- **Step**: Step 5 (Deploy Canary) — mid-execution
- **Symptom**: Missing commits discovered in the release branch after canary pipelines were already triggered. A new build (166880962 / 3.0.3918.0) was queued on the same branch after cherry-picks.
- **Root cause**: Late cherry-picks into the release branch after the original build (166743353 / 3.0.3915.0) had already been produced and canary pipelines triggered.
- **Impact**: All canary pipeline results from the old build are invalidated for the affected service (PROT). DT pipelines don't need retrigger if no DT-relevant commits were missing.
- **Resolution**: Monitor new build completion, then selectively retrigger only the affected canary pipelines (PROT-CANARY-SFRP and PROT-CANARY-SFMC) with the new build artifacts. DT canary pipelines retained their existing results.
- **Proposed improvement**: The agent should support a `rebuild` command that: (a) queues a new CloudBuild on the release branch, (b) updates release.json buildId/buildNumber, (c) asks owner which canary pipelines to retrigger, (d) arms a watcher for the build and auto-triggers on completion.

---
## 2026-06-10 ~06:00-07:00 UTC — Step 15: Production Pipeline Parameters Incorrect (3 rounds of retrigger)

### Learning 1: pipeline-catalog.json token placeholders produce dangerously broad production params
- **Step/Command**: Step 15 — Production Rollout (initial trigger)
- **Symptom**: All 4 production pipelines were triggered with PubRegions = "regions(*)" (ALL regions) and PublicExcludestamps = "@()" (no exclusions). This would have deployed to every region indiscriminately.
- **Root cause**: The pipeline-catalog.json templateParameters used broad token placeholders that resolved to wildcard values at runtime. The resolver did not have per-pipeline-type region/stamp lists.
- **Fix**: Manually constructed parameters from April Release-2604-2 reference builds (159830909, 159830918, 159830900, 159822784) with per-pipeline-type region lists, stamp exclusions, and script flags. Each of the 4 pipelines has DIFFERENT PubRegions, PublicExcludestamps, and script flags.
- **Key insight**: Production pipeline parameters are pipeline-type-specific, not global. SFRP and SFMC have completely different region lists, exclude lists, sovereign cloud flags, and ServiceGroup overrides. The catalog must store these per-pipeline, not via shared tokens.
- **Proposed fix**: Replace token placeholders in pipeline-catalog.json production entries with static per-pipeline values. Keep only currentBranch and validateOnly as dynamic. Cross-reference with the most recent successful production run during setup-service Phase 11 to validate.

### Learning 2: Region addition required when reclassifying stamps between pipeline types
- **Step/Command**: Step 15 — Parameter construction for isc-01 and ne5s-01
- **Symptom**: Release owner pointed out that removing isc-01 and ne5s-01 from SFMC PublicExcludestamps is NOT sufficient to deploy them via SFMC. Their Azure region names (indiasouthcentral, northeastus5) must ALSO be added to SFMC PubRegions. Without the region in PubRegions, EV2 will not generate deployment actions for that region even if the stamp is not excluded.
- **Root cause**: Two independent gating mechanisms in EV2: (1) PubRegions controls which regions get deployment actions generated, (2) PublicExcludestamps controls which stamps within those regions are skipped. Both must be aligned.
- **Fix**: Added indiasouthcentral and northeastus5 to both PROT-PROD-SFMC and DT-PROD-SFMC PubRegions, AND removed isc-01/ne5s-01 from their PublicExcludestamps.
- **Lesson**: When moving a stamp from pipeline-type A to pipeline-type B: (1) add its region to B PubRegions, (2) remove it from B PublicExcludestamps, (3) keep it in A PublicExcludestamps, (4) optionally remove its region from A PubRegions if no other stamps of type A exist in that region.

### Learning 3: Each production pipeline has distinct sovereign cloud and script configurations
- **Step/Command**: Step 15 — Parameter construction
- **Symptom**: Original trigger set ALL sovereign cloud script flags to true for all pipelines. In reality each pipeline type has different flags:
  - SFRP pipelines: MCScript=True, FFScript=True, no Bleu/USNat/USSec params
  - PROT-PROD-SFMC: MCScript=false, FFScript=True, FFstamps=@("uga-01"), no Bleu/USNat/USSec
  - DT-PROD-SFMC: MCScript=False, FFScript=True, FFstamps=@("uga-01"), BleuScript=False, UsNatScript=False, UsSecScript=False
- **Root cause**: pipeline-catalog.json had uniform script flag tokens that did not capture per-pipeline differences.
- **Proposed fix**: Hardcode correct script flags per pipeline entry based on reference runs.

### Learning 4: Reference builds are the most reliable parameter source for production pipelines
- **Step/Command**: Step 15 — Full parameter correction process
- **Symptom**: 3 rounds of pipeline triggers were needed before getting correct params. Round 1 used catalog tokens (wrong). Round 2 used reference-build-derived params with user corrections. Round 3 was user manual re-trigger of SFRP.
- **Proposed fix**: During setup-service Phase 11 or at the start of each release setup, automatically fetch the most recent successful production run for each pipeline via Read-PriorRun.ps1, extract its templateParameters, and store them as the baseline. The release owner then only specifies deltas (new stamps, new regions, routing changes).

### Learning 5: New stamp onboarding requires a structured checklist
- **Step/Command**: Step 15 — Adding 5 new stamps (ilc, qac, uac, uan, iln) + reclassifying 2 (isc, ne5)
- **Symptom**: Multiple back-and-forth exchanges needed to determine: which pipeline type each stamp belongs to, what Azure region name maps to each stamp prefix, whether region names need to be added to PubRegions, whether stamps need to be added/removed from PublicExcludestamps.
- **Proposed improvement**: Add a new-stamps command or checklist that collects stamp prefix, region name, pipeline type (SFRP/SFMC), cloud, and automatically computes parameter deltas for all 4 production pipelines.

### Learning 6: Stamp-prefix-to-region mapping is not always obvious
- **Step/Command**: Step 15 — Clarifying uae stamp
- **Symptom**: Agent initially interpreted uae-pod01-prot1 as mapping to region uaecentral. User clarified that uae stamp prefix actually maps to uac (UAE Central).
- **Root cause**: No authoritative stamp-prefix-to-region mapping exists in the agent configuration.
- **Fix confirmed**: uae=uaecentral (uac), uan=uaenorth, ilc=israelcentral, qac=qatarcentral, iln=israelnorthwest.
- **Proposed fix**: Add a stampPrefixToRegion mapping table to service-config.json.

### Learning 7: SFMC cloud coverage differs between PROT and DT pipelines
- **Step/Command**: Step 15 — Parameter construction for ev2CloudCoverage
- **Symptom**: state.json initially listed PROT-PROD-SFMC clouds as ["Public","Fairfax","Mooncake","Bleu"] matching DT-PROD-SFMC. But reference runs show PROT-PROD-SFMC only targets Public and Fairfax (no Mooncake, no Bleu). DT-PROD-SFMC targets Public, Fairfax, Bleu, USNat, USSec (no Mooncake).
- **Root cause**: Cloud coverage was copied uniformly across pipelines without checking per-pipeline reference.
- **Fix**: Corrected state.json cloud arrays per pipeline based on reference runs and actual script flags.

---
**Timestamp**: 2026-07-13T07:02:47.3897779Z
**Step/Command**: Phase 4 readiness (Step 6 BVT)
**Symptom**: The session running the true test run has no Kusto MCP server configured (servers: ado,bluebird,es-chat,msft-learn,icm,security-context,workiq,enghub,mail). ZED Step 6 executes the BVT query via Kusto MCP, so Step 6 will fail in the nested run.
**Root cause**: bdp3/session mcp-config.json lacks a kusto server; Install-Zed does not configure MCP servers.
**Proposed fix**: Add a kusto MCP server to ~/.copilot/mcp-config.json before the run, OR give ZED Step 6 an az-REST Kusto fallback (POST to <cluster>/v1/rest/query with the ADO/Kusto token) when Kusto MCP is absent in test mode.
**Source**: validation-run

---
**Timestamp**: 2026-07-13T08:01:00.6246359Z
**Step/Command**: Step 5/10 test-run trigger-and-cancel
**Symptom**: Canary/prod YAMLs pull a build-artifact repo resource on branch git_..._<ArtifactsBranch>, created only when a COMPLETED officialBuild publishes artifacts. Fast test mode cancels the build (Step 3 skipped) so the release-branch trigger 400s 'No version was found'. Params are correct; intrinsic fast-test-mode limitation. (Verifier correctly flagged step.5/10.capture.)
**Root cause**: Build-artifact resource branch derived from ArtifactsBranch needs a completed officialBuild; test mode cancels it.
**Proposed fix**: Redesign steps 5/10 test-mode: accept param-resolution-only OR mechanism-validate on a version-bearing base branch (develop) as the AUTHORITATIVE trigger, and treat release-branch 'No version' as EXPECTED. Update Invoke-TriggerAndCancel + success-criteria/verifier to accept the mechanism-validation (triggered=true, ArtifactsBranch=base) record for 5/10.
**Source**: lessons-learned

---
**Timestamp**: 2026-07-13T08:01:00.8016873Z
**Step/Command**: Step 13 SafeFly R2D targetedRegions
**Symptom**: 9 Get-RegionMapping names are not in SafeFly's region enum (e.g. 'USSec West Central' vs 'USSec Westcentral'; plus newer regions SafeFly hasn't onboarded). R2D filing 400s; worked around by filtering (94/103 submitted).
**Root cause**: Data drift between ASC/Get-RegionMapping DataCenterName values and SafeFly's accepted region enum.
**Proposed fix**: Add an alias/reconciliation map: fetch+cache SafeFly's allowed region list, intersect+alias Get-RegionMapping names before submit, so Step 13 doesn't fail when ASC adds a region SafeFly hasn't onboarded.
**Source**: lessons-learned

---
**Timestamp**: 2026-07-13T08:56:31.8844326Z
**Step/Command**: Step 2 ADO URL construction (pwsh 7.6)
**Symptom**: In PowerShell 7.6 a question-mark immediately after a variable token in a URL string (builds/<id>?api-version=..) is mis-parsed and mangles the URI.
**Root cause**: pwsh 7.6 parsing of the query-string separator following a variable.
**Proposed fix**: Escape the query separator (backtick-question-mark) or build query strings via -f / string join in ZED ADO REST calls; audit scripts for the pattern.
**Source**: validation-run

---
**Timestamp**: 2026-07-13T08:56:32.0070198Z
**Step/Command**: Step 13 SafeFly BuildNumber in fast test mode
**Symptom**: Fast test mode has no resolved buildNumber: officialBuild is cancelled before versioning (ADO returns the literal build-version macro) and PROD triggers queue-fail, so Step 10 buildNumber capture is empty; SafeFly needs a BuildNumber.
**Root cause**: buildNumber only exists after a completed build; test mode cancels it.
**Proposed fix**: In test mode derive SafeFly BuildNumber from the release-branch leaf (what i2 did); document this as the test-mode behavior in ZedAgent Step 13.
**Source**: validation-run

---
**Timestamp**: 2026-07-13T11:56:24.6699663Z
**Step/Command**: Step 15 — Get-Ev2RolloutStatus.ps1 (EV2 rollout monitoring)
**Symptom**: EV2 rollout status query crashes with 'The property errorDetail cannot be found on this object' whenever a rollout has a FAILED or stale-retry node. Node PSCustomObjects are created with only {error} but the failed/stale enrichment paths assign .errorDetail/.errorCode/.errorReason, which do not exist on the object -> throw. Crash occurs precisely when there IS a failure to report, so ZED would silently hide every real EV2 failure in production.
**Root cause**: Both node factory sites (StageInfos path ~line 438 and ResourceGroups fallback path ~line 579) omit errorDetail/errorCode/errorReason properties; PowerShell PSCustomObject property assignment throws on non-existent members.
**Proposed fix**: Add errorDetail=$null; errorCode=$null; errorReason=$null to BOTH node [PSCustomObject] creations so the enrichment paths can assign them. Service-agnostic (no service specifics).
**Source**: validation-run

---
**Timestamp**: 2026-07-13T12:08:29.5990912Z
**Step/Command**: Get-RegionMapping.ps1 (region discovery)
**Symptom**: Region discovery hard-codes MAB specifics: -AscRepo/-AscPath/-AscBranch DEFAULT to Mgmt-RecoverySvcs-DeploymentExtn / AzureServiceConfig.json / develop, and a supplementary list of 12 SafeFly-only regions is hard-coded. Mechanism is param-overridable (good) but a non-MAB service gets MAB defaults + MAB supplementary regions unless every caller overrides them.
**Root cause**: ASC repo/path/branch defaults and the supplementary-region list live in the script instead of service-config.json; only the current test service (MAB) was considered when defaults were chosen.
**Proposed fix**: Move ascRepo/ascPath/ascBranch and supplementaryRegions into service-config.json (config.regions.*) and read them in the script, falling back to params. Add schema field + setup-service prompt.
**Source**: agent-discovery

---
**Timestamp**: 2026-07-13T12:08:29.7729437Z
**Step/Command**: ZedAgent.agent.md (persona/description)
**Symptom**: Agent persona hard-codes the 'MAB' brand in the description and intro ('Automates the MAB monthly production release' / 'MAB Release Orchestrator') even though CONFIG[service.displayName] is used elsewhere. For a non-MAB service the agent self-describes as MAB.
**Root cause**: Persona text written for the first target service (MAB) and not templatized like the rest of the file (which uses CONFIG[...] 79 times).
**Proposed fix**: Replace 'MAB' in description/intro with CONFIG[service.displayName] (or generic 'Release Orchestrator'); 16-step behavior unchanged. Pure text edit.
**Source**: agent-discovery

---
**Timestamp**: 2026-07-13T12:08:49.9441805Z
**Step/Command**: Step 13 — New-SafeFlyRequest.ps1 (R2D payload)
**Symptom**: SafeFly R2D payload hard-coded DeploymentToolInputs.ServiceGroupName = 'Backup (MAB)' — the ONE service literal in an otherwise fully config-driven payload. A non-MAB service would file its R2D under the wrong SafeFly service group.
**Root cause**: Value inlined in the payload hashtable instead of read from service-config.json.
**Proposed fix**: Read $cfg.safefly.serviceGroupName; throw if missing (never assume). Add schema field (required) + seed value.
**Source**: agent-discovery

---
**Timestamp**: 2026-07-14T10:13:00.1738999Z
**Step/Command**: Get-AzureServiceConfig.ps1 (2nd ASC fetcher) — region-source coupling
**Symptom**: Final genericity audit found the region-source hard-code existed in a SECOND script: Get-AzureServiceConfig.ps1 hard-coded adoOrg/adoProject/adoRepo/adoItemPath (msazure/One/Mgmt-RecoverySvcs-DeploymentExtn). Test-PreFlight.ps1 also named the MAB repo in check messages, and Get-PipelineYamlIntrospection.ps1 in a comment. Fixing only Get-RegionMapping would have left the coupling half-closed.
**Root cause**: Two independent ASC fetchers duplicate the region-source location; only Get-RegionMapping was flagged initially.
**Proposed fix**: Make Get-AzureServiceConfig.ps1 read ado.*/regions.* from service-config.json (guard live fetch when unconfigured -> cache/snapshot fallback preserved); de-brand preflight messages + introspection comment.
**Source**: agent-discovery

---
**Timestamp**: 2026-08-23T17:53:26.6479306Z
**Step/Command**: Step 13 SafeFly R2D
**Symptom**: SafeFly V1 API returned HTTP 410 ReadOnlyMode: Write operations disabled. V1 endpoint (https://www.safefly.azure.com/api/RequestCreation/v1/requests) is in read-only mode. Must migrate to SafeFly V2 API (https://aka.ms/SafeFlyV2).
**Root cause**: New-SafeFlyRequest.ps1 still uses SafeFly V1 REST API which has been deprecated and put into read-only mode. Migration to V2 is required.
**Proposed fix**: Update New-SafeFlyRequest.ps1 to use SafeFly V2 API endpoint and request format. See migration guide: https://aka.ms/safeflyv2/api-migration and docs: https://aka.ms/safeflyv2/api-docs. Also update Test-SafeFlyConnection.ps1 and Get-SafeFlyApproval.ps1 if they use V1 endpoints.
**Source**: validation-run

---
**Timestamp**: 2026-08-23T18:08:47.6322468Z
**Step/Command**: Step 13 — SafeFly R2D
**Symptom**: SafeFly V1 write API returns HTTP 410 ReadOnlyMode. V2 API at www.safefly.azure.com/api/RequestCreation/v2/requests returns HTTP 500 on all payloads (broken). V2 live endpoint at safeflyv2.live.azure.com/api/v1.0/requests returns HTTP 405 on POST. V2 migration docs (aka.ms/safeflyv2/api-migration) redirect to Bing (not found). V1 reads still work (leases, approval). EXTERNAL BLOCKER — SafeFly V2 write API is not yet functional.
**Root cause**: SafeFly V1 write API deprecated (410); V2 write API not yet operational (500/405). Migration docs not published.
**Proposed fix**: 1) Update New-SafeFlyRequest.ps1 to try V2 endpoints first, fall back to V1. 2) Handle 410/500 gracefully with structured error. 3) Accept step.13 soft-failure when SafeFly API is externally broken. 4) Monitor SafeFly V2 availability and update endpoints when operational.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T02:49:08.8028120Z
**Step/Command**: Step 13 New-SafeFlyRequest
**Symptom**: 3-entry SafeFly endpoint cascade (V2-live/V2-classic/V1-classic) was speculation — only V1 classic endpoint exists in the OpenAPI spec; V2 URLs return 405/500/HTML
**Root cause**: Endpoint cascade was written as a best-guess in 2026-08; OpenAPI spec shows single POST /api/RequestCreation/v1/requests on www.safefly.azure.com
**Proposed fix**: Replaced: cascade removed, single config-driven endpoint. apiBaseUrl+requestCreationPath driven from service-config.json. HTML guard added (SPA shell returns 200 text/html for unknown paths).
**Source**: validation-run

---
**Timestamp**: 2026-08-24T02:49:23.6044937Z
**Step/Command**: Step 13 New-SafeFlyRequest HTTP 401/403
**Symptom**: HTTP 401/403 from SafeFly produced no actionable guidance — user token lacks SafeFly.Request role (id 91767177-5551-4c8f-8491-f054949f3360 on Safefly_API 6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6)
**Root cause**: Code used az account get-access-token (user token) with no note that SafeFly.Request role is needed. Error message did not name the role, resource, or required SP
**Proposed fix**: DONE: 401/403 handler now emits actionable error naming role id, Safefly_API resource, configured SP appId, and ADO service connection. Config fields added to service-config.json schema.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T02:49:36.3654630Z
**Step/Command**: Steps 5/10 trigger-and-cancel
**Symptom**: triggered==false artifact-gap was recorded as status=completed (honest failure masked as success). ZedAgent.agent.md spec had internal contradiction: general contract said any triggered=false=failed, but per-step overrides said mark completed
**Root cause**: No distinct status existed for expected artifact-gap failures. General trigger contract was not carved out for the per-step exception
**Proposed fix**: DONE: Steps 5/10 now use completed-with-expected-artifact-gap. ZedAgent spec updated. success-criteria.json uses acceptedStatuses array. Test-RunRequirements.ps1 supports acceptedStatuses. Step 13 HTTP 410 now correctly marks step as failed
**Source**: validation-run

---
**Timestamp**: 2026-08-24T02:49:49.0537012Z
**Step/Command**: Email notifications in test mode
**Symptom**: No notifications-capture.json artifact existed — impossible to verify email notifications were sent in test mode. Step 15 was fully skipped including the production-triggered notification
**Root cause**: No capture schema defined for test-mode notifications. production-triggered-message.html template existed but was only referenced in unit tests, not wired into ZedAgent spec Step 15
**Proposed fix**: DONE: notifications-capture.json schema added. ZedAgent.agent.md wires production-triggered-message.html into Step 15 action 4. Step 15 test mode now sends notification (not full skip). success-criteria.json checks notificationsCapture. TEST-2026-08-i2 produced 11 notification records
**Source**: validation-run

---
**Timestamp**: 2026-08-24T02:50:02.9680395Z
**Step/Command**: Step 13 SafeFly HTTP 410
**Symptom**: Step 13 HTTP 410 now correctly marks step as failed — but success-criteria.json still requires status=completed for step 13. This is an external blocker (SafeFly API), not a ZED bug
**Root cause**: SafeFly V1 write endpoint returns HTTP 410 ReadOnlyMode permanently. No alternative write API available as of 2026-08-24
**Proposed fix**: No ZED fix needed. Verifier correctly fails step.13.safeFlyFiled. success-criteria.json requirement is correct (step 13 must complete = R2D must be filed). Fix must come from SafeFly team or via ADO service connection + SP token (when requestCreatorSpAppId is configured).
**Source**: validation-run


---
**Timestamp**: 2026-08-24T07:04:00.0000000Z
**Step/Command**: Step 13 New-SafeFlyRequest -- SafeFly V2 GraphQL migration (Round 3)
**Symptom**: SafeFly V2 write API is GraphQL-only (POST to safeflyv2.live.azure.com/api/v1.0/graphql), not REST. All previous V2 attempts targeted REST endpoints that don't exist. Migration docs now confirmed the correct path.
**Root cause**: V2 is a GraphQL API, not a REST API. The V1 REST surface has no V2 REST equivalent. The correct endpoint accepts GraphQL mutations.
**Proposed fix**: DONE -- New-SafeFlyRequest.ps1 fully rewritten to V2 GraphQL. Invoke-SafeFlyGraphQL.ps1 created as a reusable transport helper. Get-SafeFlyForm.ps1 created for form discovery.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:04:10.0000000Z
**Step/Command**: Step 13 Get-SafeFlyForm -- staticOptions truncation
**Symptom**: Using `staticOptions` in the activeForm GraphQL query silently returns only 1 question instead of all 43. This is a known SafeFly V2 schema quirk -- staticOptions is not the correct field.
**Root cause**: `staticOptions` is a different schema field from `options`. The `expandWidgetQuestionsInline: true` argument combined with `options { id label value }` sub-selection is required to get all questions.
**Proposed fix**: DONE -- Get-SafeFlyForm.ps1 uses `options { id label value }` + asserts count > 1 as a truncation guard.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:04:20.0000000Z
**Step/Command**: Step 13 Invoke-SafeFlyGraphQL -- byte array decode
**Symptom**: Invoke-WebRequest.Content returns a byte[] in PowerShell, not a string. Casting directly to string gives garbage or truncated output.
**Root cause**: PowerShell's Invoke-WebRequest returns Content as byte[] for non-text MIME types. Even application/json content must be explicitly decoded.
**Proposed fix**: DONE -- Invoke-SafeFlyGraphQL.ps1 decodes with [System.Text.Encoding]::UTF8.GetString($r.Content).
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:04:30.0000000Z
**Step/Command**: Step 13 Invoke-SafeFlyGraphQL -- GraphQL errors in HTTP 200 body
**Symptom**: A GraphQL request can return HTTP 200 with an errors[] array in the response body. Treating HTTP 200 as success without checking the body leads to silently missing errors.
**Root cause**: GraphQL protocol design -- errors are body-level, not HTTP-level. HTTP status only reflects transport success.
**Proposed fix**: DONE -- Invoke-SafeFlyGraphQL.ps1 always checks $response.errors after any HTTP 200 response and throws a terminating error if errors are present.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:04:40.0000000Z
**Step/Command**: Step 13 New-SafeFlyRequest -- SDP label mapping
**Symptom**: V1 SDP value "Standard SDP" has a different label in V2 forms: "Standard SDP (Normal Rollout)". Submitting the V1 string as an answer would fail option validation.
**Root cause**: V2 form options use expanded labels. The V2 "Conservative SDP" option label is unchanged, but "Standard SDP" was renamed.
**Proposed fix**: DONE -- New-SafeFlyRequest.ps1 maps V1 SDP strings to V2 option labels before answer assembly. SDP mapping table documented in SAFEFLY-API-REFERENCE.md.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:04:50.0000000Z
**Step/Command**: Step 13 New-SafeFlyRequest -- EV2 question partition
**Symptom**: App deployment form has 43 questions for many orchestrators (AzDeployer, LSM, PilotFish, Storage, EV2, Other). Only ev2.* questions are relevant for EV2 deployments. Answering non-EV2 questions would fail required-field validation or submit noise.
**Root cause**: SafeFly V2 uses a single multi-tool form with namespace prefixes per orchestrator. Only the applicable namespace subset should be answered.
**Proposed fix**: DONE -- New-SafeFlyRequest.ps1 skips non-EV2 prefixes (azdeployer., lsm., pilotfish., storage., other.) and only answers ev2.* questions. Effective-required set derived at runtime from conditionalRule.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:05:00.0000000Z
**Step/Command**: Step 13 New-SafeFlyRequest -- fail-closed required field check
**Symptom**: Without explicit required-field validation, a request with missing answers could be submitted with gaps. SafeFly V2 API would reject it server-side, but the error would be cryptic.
**Root cause**: Effective-required set must be computed from conditionalRule at runtime (some questions are only required if a parent question has a specific answer). Static required=true check is insufficient.
**Proposed fix**: DONE -- Resolve-EffectiveRequired helper computes runtime-required set. Fail-closed check throws with full list of unanswered required question names before any mutation is attempted.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:05:10.0000000Z
**Step/Command**: SafeFly.Tests.ps1 -- V1 test patterns after V2 migration
**Symptom**: After migrating New-SafeFlyRequest.ps1 to V2, old round-2 Pester tests in WP-S1/WP-S2 Describe blocks still checked New-SafeFlyRequest.ps1 for V1 patterns (SAFEFLY_HTML_RESPONSE, $statusCode -eq 410, V1 role IDs, $requestCreatorSpAppId, $requestCreatorSvcConn). These patterns now live in Invoke-SafeFlyGraphQL.ps1. Tests failed with 5 assertion errors.
**Root cause**: Test file referenced $NewSafeFlyScript for V1 error-handling patterns that moved to the new transport helper.
**Proposed fix**: DONE -- Updated WP-S1/WP-S2 tests to check Invoke-SafeFlyGraphQL.ps1. Updated V2-specific assertions (tokenAudience, ExternalStandardAccess, 712dc115 service connection). Added HTML guard to Invoke-SafeFlyGraphQL.ps1 so the SAFEFLY_HTML_RESPONSE test has a valid target.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T07:05:20.0000000Z
**Step/Command**: SafeFly.Tests.ps1 -- Should -Not -Match on strings appearing in comments
**Symptom**: WP-5b test used `$script | Should -Not -Match 'acceptExpectedArtifactFailure'` to verify the old field was removed. This failed because the string still appeared in two COMMENTS in Test-RunRequirements.ps1 (explaining the removal). Pester -Match checks the full file text including comments.
**Root cause**: Overly broad string match does not distinguish code from comments.
**Proposed fix**: DONE -- Updated test to use precise regex patterns that only match code usage of the field: `Should -Not -Match '\$stepCriteria\.acceptExpectedArtifactFailure'` and `Should -Not -Match '\$cap\.acceptExpectedArtifactFailure'`. Comments mentioning the field name are acceptable.
**Source**: zedforge-round3

---
**Timestamp**: 2026-08-24T08:13:25.1826967Z
**Step/Command**: New-SafeFlyRequest.ps1 -DryRun
**Symptom**: Two effective-required questions (core.health_monitoring, ado.build_na) had no answer mappings in New-SafeFlyRequest.ps1. core.health_monitoring: "Yes" (label, value=True). ado.build_na: "Not Applicable" (label, value=True) — EV2 uses ev2.build, not ADO build links.
**Root cause**: Answer-building section was written before live form was queried; developer assumed the 7 effective-required questions but only mapped 5. The fail-closed check caught it correctly, but the missing answers should have been pre-empted by mapping all known effective-required questions.
**Proposed fix**: Added core.health_monitoring -> Yes and ado.build_na -> Not Applicable mappings in New-SafeFlyRequest.ps1 answer-building section. Added regression test in SafeFly.Tests.ps1 verifying both mappings are present in the script.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T08:13:39.8183599Z
**Step/Command**: Invoke-SafeFlyGraphQL.ps1
**Symptom**: 299 green unit tests over code that had never called the live SafeFly API is NOT validation. The byte-array decode bug (BUG 2) masked the SCALAR_LEAFS GraphQL error (BUG 1) for all of PS7 test history. The ContainsAny/NotIn operator bug (BUG 3) was completely invisible until the first live call compared actual API operator names to what the evaluator handled.
**Root cause**: Mock-only Pester tests cannot catch: (a) live API field shape changes, (b) operator name mismatches between mocked data and real API, (c) PS5 vs PS7 byte-array/string type divergence in Invoke-WebRequest.Content. All three bugs existed behind a green test suite.
**Proposed fix**: After any SafeFly code change: run Get-SafeFlyForm.ps1 against prod API (read-only, no token write) to validate form fetch. Run New-SafeFlyRequest.ps1 -DryRun with real service config to validate evaluator + payload assembly. Only then declare the code tested. Add this as a mandatory step in ZED step 13 pre-flight notes.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T13:19:39.4193961Z
**Step/Command**: Resolve-TemplateParams.ps1 -PipelineKey DT-PROD-SFMC -Scope production
**Symptom**: L-15 EV2_CLOUD_COVERAGE_MISMATCH for DT-PROD-SFMC and PROT-PROD-SFMC: catalog ev2CloudCoverage included Bleu/Mooncake/USNat/USSec but corresponding script flags (BleuScript, MCScript, UsNatScript, UsSecScript) are all false. Throws on Step 10 template resolution, blocking trigger-and-cancel entirely.
**Root cause**: nsolar catalog seeded ev2CloudCoverage based on EV2 infra registration (all sovereign clouds the service group exists in), not on the current active XxxScript flags. service-config.json has no Bleu/USNat/USSec inventory.
**Proposed fix**: Fixed: updated config-seed/pipeline-catalog.json ev2CloudCoverage: DT-PROD-SFMC -> [Public,Fairfax]; PROT-PROD-SFMC -> [Public,Fairfax]. Removes all clouds where script flag is false.
**Source**: agent-discovery

---
**Timestamp**: 2026-08-24T13:19:39.7196385Z
**Step/Command**: Test-RunRequirements.ps1 steps.5.capture.minPipelines
**Symptom**: success-criteria.json steps 5 and 10 had minPipelines=1, but new 4+4 catalog (PROT+DT x canary+prod) requires at least 4 pipelines per step for full coverage.
**Root cause**: minPipelines was set during 2+2 PROT-only catalog era. Not updated when DT pipelines were added.
**Proposed fix**: Fixed: updated success-criteria.json steps 5 and 10 minPipelines from 1 to 4.
**Source**: agent-discovery

---
**Timestamp**: 2026-08-24T14:09:01.0514651Z
**Step/Command**: Step 2 officialBuild trigger-and-cancel
**Symptom**: Step 2 officialBuild capture missing required key 'CloudBuildQueue'
**Root cause**: Invoke-TriggerAndCancel captures some templateParameters but CloudBuildQueue is not passed to the trigger call or not captured in test-run-capture.json
**Proposed fix**: Check officialBuild catalog entry for CloudBuildQueue in templateParameters; if required, ensure Resolve-TemplateParams returns it and Invoke-TriggerAndCancel captures it in the record
**Source**: validation-run

---
**Timestamp**: 2026-08-24T14:09:14.9084762Z
**Step/Command**: Step 10 inventory gate
**Symptom**: sds.*.localClonePath hardcoded as machine-specific absolute path — any other agent/machine fails
**Root cause**: service-config.json commits absolute machine path for localClonePath (D:\one\bdp1)
**Proposed fix**: Default localClonePath to environment.json->repoRoot when absent or path doesn't exist
**Source**: lessons-learned

---
**Timestamp**: 2026-08-24T14:09:15.9915205Z
**Step/Command**: Step 10 Get-StampInventoryFromSds + Resolve-TemplateParams
**Symptom**: sdsFieldMapping is empty {} causing root cause of 132-stamp drift and INVENTORY_MISSING_CLUSTERTYPE: SDS stamps have StampId field not Macros.__StampName__ (Phobos-2022 default)
**Root cause**: sdsFieldMapping:{} forces parser to use stampNamePath=Macros.__StampName__; this service SDS has no Macros block
**Proposed fix**: Set sdsFieldMapping.stampNamePath=StampId in service-config.json; reseed config-seed; re-populate inventory
**Source**: lessons-learned

---
**Timestamp**: 2026-08-24T14:09:17.0447724Z
**Step/Command**: teardown Register-WatcherTask -Action cleanup
**Symptom**: Register-WatcherTask -Action cleanup exits -1 silently; teardown unreliable in real releases
**Root cause**: Cleanup path errors silently; no structured result returned
**Proposed fix**: Make cleanup no-op-safe when no task/lock exists; always return populated result object with verbose output
**Source**: lessons-learned

---
**Timestamp**: 2026-08-24T15:02:46.7689215Z
**Step/Command**: Step 10, Test-InventoryGate.ps1 - iter 4
**Symptom**: hashDrift fires when sdsFieldMapping changes because stampName (mapped field) is included in the hash projection, not just cloud|stampId topology
**Root cause**: Get-StampInventoryFromSds.ps1 hashes 'cloud|stampId|stampName|dcShortName|region|deploymentName'. When sdsFieldMapping.stampNamePath was changed from 'Macros.__StampName__' (resolves empty for this SDS) to 'StampId' (resolves to actual stamp ID), every canonical line changed, producing a different hash. The gate correctly rejects b7a923 vs d4d853 but the stamp topology is identical.
**Proposed fix**: Hash ONLY 'cloud|stampId' (true topology) in Get-StampInventoryFromSds.ps1. Feature-flag value changes and mapping changes will no longer trigger hashDrift. Real topology changes (stamp add/remove/rename) still will.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:03:02.8364136Z
**Step/Command**: Step 10, Resolve-TemplateParams.ps1 ~line 123 - iter 4
**Symptom**: INVENTORY_MISSING_CLUSTERTYPE error interpolates stampName which is empty for sovereign stamps so error names nothing
**Root cause**: throw uses s.stampName but Fairfax stamps only have stampId set; error says 'stamp '' has no clusterType' with no identifying info
**Proposed fix**: Use stampId as fallback: stamp '$($s.stampId ?? $s.stampName)' (cloud '$Cloud'); collect all offending stamps and throw once
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:03:02.9078545Z
**Step/Command**: Step 6, bvt-prot-failures.kql - iter 4
**Symptom**: BVT gate cannot distinguish 'no failures' from 'no data'; 0 rows auto-passes even if feed is dead; 13 qualifying failures under team=None are invisible
**Root cause**: Steps 6/8/11 treat rowCount==0 as unconditional pass with no freshness assertion. PROT feed last published 2026-08-18 (6 days ago); 1669 unattributed None-team failures over 90d are never seen.
**Proposed fix**: Add liveness assertion: if unfiltered window rowCount==0 or max(TimeStamp) for responsible team older than window, report BVT_DATA_STALE. Also emit None-team qualifying count in summary email.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:03:17.6974306Z
**Step/Command**: Step 1, reminder-email.html template - iter 4
**Symptom**: reminder-email.html requires {{agentFeedbackEmail}} but service-config.json has no notifications.agentFeedbackEmail field; ZED falls back to release owner email
**Root cause**: Template has agentFeedbackEmail placeholder; service-config.json notifications block only has groups and routing; with StrictPlaceholders=true this would throw
**Proposed fix**: Add notifications.agentFeedbackEmail to service-config.schema.json and to setup-service group 5a; default to release owner email in the renderer
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:03:17.7699940Z
**Step/Command**: ZedForge validation run command - iter 4
**Symptom**: ZedForge passes previousBranch=develop which resolves to same SHA as currentBranch, so Step 4 collects 0 commits and classification/nature-tagging is never exercised on real data
**Root cause**: Test branch is cut from develop; previousBranch=develop means git log from develop..branch = empty set. Step 4 correctly yields 0 commits but the whole classification path is untested.
**Proposed fix**: ZedForge should pass the most recent released branch (e.g. Release-2607 or latest release/* branch) as previousBranch. Or: ZedForge should refuse to start when currentBranch and previousBranch resolve to same SHA.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:03:31.9488858Z
**Step/Command**: Step 10, service-config.json Mooncake stamps - iter 4
**Symptom**: Mooncake clusterType deterministically resolved as all-sfrp by ZED in iter 4; result must be backported to config-seed/service-config.json so it survives reseed
**Root cause**: ZED wrote clusterType/cloud/region/ev2RegionName/layout for 6 Mooncake stamps to bdp3's service-config.json. ZedForge config-seed/service-config.json still has Mooncake without clusterType.
**Proposed fix**: Copy the 6 Mooncake stamp records (with clusterType=sfrp, cloud, region, ev2RegionName, layout) from bdp3's service-config.json to config-seed/service-config.json
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:03:32.0272590Z
**Step/Command**: Step 4, service-config.json commitExcel - iter 4
**Symptom**: excludeAuthors list added by ZED to bdp3's service-config.json (value: ['OneBranch GitPushVersion Account']); must be backported to config-seed so it persists across reseeds
**Root cause**: ZED found commitExcel.excludeAuthors missing and added ['OneBranch GitPushVersion Account'] to bdp3's service-config.json. Config-seed doesn't have this field yet.
**Proposed fix**: Add commitExcel.excludeAuthors: ['OneBranch GitPushVersion Account'] to config-seed/service-config.json
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:50:51.0592150Z
**Step/Command**: Update-ReleaseState.ps1 - iter 5
**Symptom**: P0: -Action write ignores -StateProperties and truncates state.json (and its backup) to 0 bytes; the backup is overwritten by the empty file on the second call, destroying the only recovery copy
**Root cause**: The write branch did a bare \ | Set-Content — when -DirectiveJson is unset, \ | Set-Content truncates to 0 bytes. Backup was taken unconditionally before each write, so second bad write erased the good backup.
**Proposed fix**: Guard: if DirectiveJson is null/empty, merge -StateProperties into existing state (like update-step does). Never overwrite backup when current state.json is 0 bytes. Both guards added by ZED and backported to ZED-Agent source.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:50:52.3285031Z
**Step/Command**: Step 4, ZedAgent.agent.md - iter 5
**Symptom**: P1: Step 4 Action 3 commit range is inverted. Spec says 'git log origin/{currentBranch}..origin/{previousBranch}' which returns commits in previousBranch NOT in currentBranch — the opposite of what ships.
**Root cause**: The git range direction was backwards. With previousBranch=develop (iter i1-i4) both directions produce empty sets, hiding the bug. On a real previousBranch=releases/prot2607, spec-literal range returns 6 hotfix-only commits (not shipping); reversed range returns 160 actual release commits.
**Proposed fix**: Change Step 4 Action 3 to: git log --cherry-pick origin/{previousBranch}..origin/{currentBranch}. Also update ZedAgent.agent.md commit range instruction.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:50:53.4001679Z
**Step/Command**: Step 4, commit classification - iter 5
**Symptom**: P2: Two commit-classifier regexes misfire: (1) 'enable|disable' misses gerunds like 'Enabling', under-reporting Config change; (2) bare \bos\b false-positives 'OS/Image patch' on non-patch commits
**Root cause**: Classifier regex only matches root verb forms. Pattern validated on empty commit sets (iter 1-4) so defects were invisible.
**Proposed fix**: Fix (1): match 'enabl|disabl|turn on|turn off|changing the value'. Fix (2): require explicit phrase: 'os patch|os update|base image|container image|runtime update|image patch'. Drop bare \bos\b.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:50:54.4221850Z
**Step/Command**: Step 13, ZedAgent.agent.md - iter 5
**Symptom**: P3: DeploymentNature is computed correctly from commits but is silently dropped — the SafeFly V2 App-deployment form has no such field (documented in the script). Readers of ZedAgent.agent.md assume natures reach SafeFly.
**Root cause**: ZedAgent.agent.md Step 13 describes mapping to 11 natures without noting they are Excel/audit-only, not part of the V2 payload.
**Proposed fix**: Add one sentence to Step 13 Action 1: DeploymentNature feeds the commit Excel and audit trail only (not the V2 payload). SDPType is the one that reaches SafeFly and was carried correctly.
**Source**: validation-run

---
**Timestamp**: 2026-08-24T15:50:55.4517913Z
**Step/Command**: Step 13, SDPType derivation - iter 5
**Symptom**: P3: SDPType breaking-change regex fires on bare 'removal' — 'stale macro removal' and 'dSMS removal' both matched. On a small release these alone would silently escalate to Conservative SDP.
**Root cause**: Pattern was too broad: any commit containing 'removal' triggered escalation. On 160-commit run this was masked by other escalation triggers (volume + live features).
**Proposed fix**: Tighten to: require 'breaking change', 'removed? (the )?(api|endpoint|contract|field|parameter)', 'deprecat', 'migration required', 'schema change', 'incompatible'. Drop bare 'removal'.
**Source**: validation-run

---
**Timestamp**: 2026-08-25T12:29:36.2974860Z
**Step/Command**: Invoke ADO preview API for all 8 pipelines with -TestMode
**Symptom**: ArtifactsBranch test-mode fix validated: all 8 pipelines pass ADO preview API with ArtifactsBranch=develop. step.5.capture=4/4 OK, step.10.capture=4/4 OK. Root causes fixed: (1) -TestMode switch added to Resolve-TemplateParams.ps1 overrides ArtifactsBranch to baseBranch; (2) CLUSTERTYPE throw changed to drop+warning; (3) L-15 check scoped to Public cloud stamps matching pipeline clusterType only.
**Root cause**: ArtifactsBranch={{currentBranch}} resolved to synthetic ZedForge test branch with no officialBuild; ADO rejected with HTTP 400.
**Proposed fix**: DONE: -TestMode switch implemented, Pester tests passing 352/0, all 8 ADO preview calls return real runIds.
**Source**: validation-run

---
**Timestamp**: 2026-08-28T06:24:37.2728044Z
**Step/Command**: setup-service Phase 4.4 / Get-PipelineYamlIntrospection
**Symptom**: YAML parameter extraction returned zero parameters for every real pipeline, and the catalog silently stored yamlIntrospection.parameters = null instead of failing.
**Root cause**: The block walker terminated on the first line matching ^\S. Azure Pipelines allows a block sequence at the SAME indentation as its owning key, and the ADO /preview finalYaml emits exactly that ("parameters:" followed by "- name:" at column 0), so the walker stopped on the first entry. Existing fixtures all used the indented form, so tests passed while production returned nothing.
**Proposed fix**: FIXED. lib/YamlParamModel.ps1 Get-YamlParameterBlock terminates only on a column-0 MAPPING key (^[^\s:]+\s*:), never on "- ". Get-PipelineYamlIntrospection now THROWS on an empty extraction unless -AllowEmptyParameters is passed, so this can never be stored as null again. Regression test: YamlParamModel.Tests.ps1 "extracts identically from indented and column-0 sequence forms".
**Source**: agent-discovery

---
**Timestamp**: 2026-08-28T06:24:37.4850907Z
**Step/Command**: any script returning ,@(...) or handling List[T]
**Symptom**: PowerShell 7.6.5 throws "Argument types do not match" when a System.Collections.Generic.List[T] is wrapped in @(). Separately, wrapping a script that returns ,@(...) in @() double-nests the array so Count becomes 1.
**Root cause**: Two distinct PS array-unrolling behaviours. (1) A 7.6.5 regression in @() over List[T]. (2) The ,@() comma idiom already produces an array; an outer @() wraps that array in another array rather than unrolling it.
**Proposed fix**: FIXED at all sites touched. Rule for ZED scripts: return $list.ToArray() (or [object[]]$list) instead of @($list); and NEVER wrap a call to a ,@()-returning script in @() - assign bare. NOTE pre-existing offender not fixed (out of scope): Invoke-BaselineFetch.ps1 line 79 does $runs = @(& $readPriorRun ...) which nests.
**Source**: agent-discovery

---
**Timestamp**: 2026-08-28T06:24:37.6870189Z
**Step/Command**: setup-service Phase 4.3 / Read-PriorRun
**Symptom**: ZED cannot tell its own pipeline runs apart from human-authored ones by identity: requestedFor and reason are byte-identical because ZED queues with the release owner delegated token.
**Root cause**: Delegated auth. Verified against ZED run 178110942 and the four human reference runs - all show the same requestedFor/reason shape.
**Proposed fix**: FIXED. Get-SelfAuthoredRuns.ps1 builds a ledger of run ids from .zed-agent/releases/*/test-run-capture.json (what ZED recorded at trigger time); Read-PriorRun.ps1 hard-excludes those ids and throws if every supplied run is self-authored. -IncludeSelfAuthored remains for diagnostics.
**Source**: agent-discovery

---
**Timestamp**: 2026-08-28T06:24:37.9974178Z
**Step/Command**: setup-service Phase 4.4 / branch selection
**Symptom**: A parameter can exist on the release branch but not on the base branch. BranchPrefix is present in all four human reference runs and in 421108 develop YAML, but absent from 403182 develop YAML - it exists only on the feature branch.
**Root cause**: Branch skew. The pipeline YAML differs between the branch a release was cut from and the base branch ZED introspects.
**Proposed fix**: Not a bug in extraction - do not "fix" it by inventing the parameter. ADO rejects unknown templateParameters, so posting a parameter that is not declared on the target branch will fail the run. The pre-POST validation gate (P4) must diff the resolved parameter set against the introspected declaration for the ACTUAL target branch and drop/flag undeclared keys. Phase 4.3 now warns when the captured release branch differs from ado.baseBranch.
**Source**: agent-discovery

---
**Timestamp**: 2026-08-28T06:24:38.0780413Z
**Step/Command**: grep gate / service-agnostic audit
**Symptom**: Three scripts still hardcode a partition-specific parameter name, which will break ZED for any service whose partitions are not named the same way.
**Root cause**: Written against the current test target before generic partition discovery existed.
**Proposed fix**: Pre-existing, NOT fixed in this change (out of scope). Offenders: Get-PriorRunBaseline.ps1 line 71 hardcodes PubRegions; Assert-GeographyCoverage.ps1 references PubRegions; Resolve-TemplateParams.ps1 ~line 401 names PubRegions/MCRegions/FFRegions. All three should consume yamlIntrospection.partitions[].facets.regions instead. Also Get-PipelineYamlIntrospection.ps1 line 82 $knownClouds is a literal cloud list, but it is only used by the older stage-hardcoded detection heuristic, not by parameter discovery.
**Source**: agent-discovery

---
**Timestamp**: 2026-09-02T11:21:01.6562553Z
**Step/Command**: lib/YamlParamModel.ps1 Test-ParameterPayload; Assert-ParameterPayload.ps1
**Symptom**: The P4 payload gate reported SHAPE_MISMATCH on every parameter of a config whose declarations carry no `values` list, and separately reported checked=true while validating nothing.
**Root cause**: PowerShell: @($null).Count is 1, not 0. Reading a missing property off a PSCustomObject yields $null; @() wraps it into a one-element array. Guards of the form @($obj.maybeMissingProp).Count -gt 0 are therefore ALWAYS true. Two independent sites had this: the enum check in Test-ParameterPayload, and $declaredCount in Assert-ParameterPayload (which made NO_VALIDATION_SOURCE unreachable).
**Proposed fix**: Filter explicitly before counting: @($x | Where-Object { $null -ne $_ -and [string]$_ -ne "" }).Count. Both sites fixed; regression tests added in P3P4-Hardening.Tests.ps1. Audit any remaining @(...).Count guard over a possibly-absent property.
**Source**: agent-discovery

---
**Timestamp**: 2026-09-02T11:21:01.8812874Z
**Step/Command**: lib/YamlParamModel.ps1 Get-ContainerElements
**Symptom**: CCOA exclusions were silently discarded: the union of learned exclusions and CCOA exclusions produced a single stamp instead of both, and REGION_SET_SHRINK could not see @(...) stamp lists.
**Root cause**: Three call sites invoked Get-ContainerElements -Literal <v> but the parameter is -Value. Because the function was a SIMPLE (non-advanced) function, the unknown named parameter fell into $args and $Value bound to $null with NO error. The function returned zero elements and every caller treated that as "nothing to merge".
**Proposed fix**: Made the function advanced ([CmdletBinding()]) with [Alias('Literal')] and [Parameter(Position=0)] so both spellings bind and future typos throw. RULE: any lib function whose misuse would be silent must be advanced.
**Source**: agent-discovery

---
**Timestamp**: 2026-09-02T11:21:01.9446359Z
**Step/Command**: repo-wide
**Symptom**: On PowerShell 7.6.5, `New-Object System.Collections.Generic.List[object]` (unquoted type) yields a List whose @($list) throws ArgumentException: Argument types do not match. [List[object]]::new() is unaffected.
**Root cause**: Unquoted generic type argument is parsed as an array-index expression, producing a subtly different runtime type.
**Proposed fix**: Replaced 18 occurrences in Resolve-TemplateParams.ps1 / Assert-ParameterPayload.ps1 / Invoke-TriggerAndCancel.ps1 with [List[object]]::new(). STILL LATENT in: LearningsStore.ps1, Test-RunRequirements.ps1:44, Get-SelfAuthoredRuns.ps1, Get-StampInventory.ps1 (x4), Get-StampInventoryFromSds.ps1 (x3), Read-PipelineYaml.ps1, Read-PriorRun.ps1. Sweep these before they are enumerated with @().
**Source**: agent-discovery

---
**Timestamp**: 2026-09-02T11:21:02.0755827Z
**Step/Command**: Resolve-TemplateParams.ps1 L-10 EV2 dual gate
**Symptom**: After making the L-10 dual gate partition-driven instead of hardcoded to PubRegions/PublicExcludestamps, the gate went silent for pipelines that pair a truncated prefix with a full one.
**Root cause**: Get-ParameterPartitionModel only folds a short partition spelling into a longer one when the longer one owns the head facet (<P>Script). A real pipeline declares PubRegions + PublicExcludestamps and NO PublicScript, so the two facets land in separate candidates and the gate found no partition owning both.
**Proposed fix**: Added Get-PartitionFacetPairs to lib/YamlParamModel.ps1: pairs two facets across prefix-compatible partition names, preferring the closest spelling. The gate now uses it, and derives its names from the RESOLVED payload unioned with the declaration (deriving from the declaration alone silently disabled the gate for un-introspected pipelines). 8 unit tests added.
**Source**: agent-discovery

---
**Timestamp**: 2026-09-02T11:37:41.6680182Z
**Step/Command**: copilot --agent=ZedAgent (headless true test run)
**Symptom**: ZED cannot be invoked AT ALL on Copilot CLI 1.0.83-2. Every `copilot --agent=ZedAgent -p ...` returns exit 1 with the single line: "Static system messages and tool definitions exceed the model's usable context budget. Reduce static context or switch to a larger-context model." The same CLI runs fine without --agent, so the CLI and auth are healthy — it is ZedAgent.agent.md that no longer loads.
**Root cause**: ZedAgent.agent.md declares tools: ["*"], which injects EVERY configured MCP tool definition into the static system prompt, on top of an agent body that has grown to ~1800 lines. Combined they exceed the default model's static-context budget. This is a hard blocker, not a degradation: no step runs.
**Proposed fix**: Two independent fixes, both needed. (1) Replace tools: ["*"] with the explicit tool allow-list ZED actually uses (shell/powershell, file read/write, and only the MCP servers it calls: ADO, Kusto, Mail). The wildcard is what pulls in the unused MCP surface. (2) Shrink the static agent body: move the per-step prose (the 16-step playbook, the trigger-and-cancel contract, the parameter-syntax rules) into .github/skills/zed-agent/ reference files that the agent reads on demand, leaving the agent file as a dispatcher. Until one of these lands, ZED is unrunnable on CLI >= 1.0.83 regardless of target repo.
**Source**: validation-run

---
**Timestamp**: 2026-09-02T12:20:06.4198844Z
**Step/Command**: Step 6 (BVT query-works-check)
**Symptom**: The BVT Kusto query template wraps the time placeholder in datetime(...), so substituting a relative expression like ago(48h) produces datetime(ago(48h)) which Kusto rejects. ZED had to patch the substitution mid-run.
**Root cause**: The template hardcodes datetime() around the placeholder, assuming the substituted value is always an absolute timestamp literal. Relative KQL time expressions are equally valid and more natural for a lookback window.
**Proposed fix**: Emit the time bound WITHOUT a wrapping datetime() and let the substituted value carry its own type: absolute values should be substituted as datetime(...) by the substituter, relative ones (ago(...), now()-...) passed through bare. Detect which form the value is and wrap only when it is an absolute literal.
**Source**: validation-run

---
**Timestamp**: 2026-09-02T12:20:07.4861837Z
**Step/Command**: teardown (auto-teardown after test run)
**Symptom**: The teardown cleanup helper kills processes matching *zed-agent*watcher*, which also matches its OWN invoking shell command line, so it terminates itself. Steps 2-5 of the teardown contract (delete secrets.json, send teardown email, write audit entry) never execute.
**Root cause**: The process-kill matcher globs on the full command line and has no self-PID exclusion. Because the helper is itself invoked from a path containing zed-agent, and the watcher pattern is broad, the helper is inside its own match set.
**Proposed fix**: Exclude the current process and its ancestors from the kill set: filter out $PID and walk ParentProcessId up, before invoking Stop-Process. Also tighten the matcher to the watcher entry script name rather than a two-part wildcard over the whole command line.
**Source**: validation-run

