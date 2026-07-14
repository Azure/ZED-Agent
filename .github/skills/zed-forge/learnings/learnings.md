# ZED Agent Lessons Learned


---
**Timestamp**: 2026-06-04T16:14:11.6483282+05:30
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

