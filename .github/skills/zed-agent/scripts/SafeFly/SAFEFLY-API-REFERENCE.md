# SafeFly R2D API Reference

> Extracted from the SafeFly OpenAPI spec: `https://www.safefly.azure.com/swagger/v1/swagger.json`
> This document gives the ZED Agent full knowledge of SafeFly's API schema, valid enum values, and field constraints.

## Endpoints

> **V1 is deprecated.** As of mid-2026, V1 write endpoints return HTTP 410 (ReadOnlyMode).
> V2 is the supported write path. The script tries endpoints in order:
> 1. V2-live: `https://safeflyv2.live.azure.com/api/v1.0/requests`
> 2. V2-classic: `https://www.safefly.azure.com/api/RequestCreation/v2/requests`
> 3. V1-classic (fallback): `https://www.safefly.azure.com/api/RequestCreation/v1/requests`
>
> ⚠️ **[UNVERIFIED — none of these currently accept a write.]** Measured 2026-08-23 during a
> ZedForge validation run: V2-live returned **HTTP 405** on POST, V2-classic returned **HTTP 500**
> on every payload shape tried, V1-classic returns **HTTP 410 ReadOnlyMode**. The published
> migration guide (`aka.ms/safeflyv2/api-migration`) does not resolve. The V2 URLs above are
> therefore **best-guess shapes, not confirmed contracts** — do not treat them as working.
> **Step 13 R2D filing is externally blocked until SafeFly publishes a functional V2 write API.**
> V1 **read** endpoints (approval state, leases, request details) still work.
>
> When SafeFly V2 becomes available, confirm the real endpoint + payload shape and replace this
> cascade with the single verified endpoint. Do **not** resolve this by weakening
> `success-criteria.json → step.13.safeFlyFiled` — a release that cannot file an R2D must fail
> loudly, not be recorded as green.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | (see above — tried in order) | Create a new R2D request |
| `GET` | `/api/SafeFlyRequest/approvalstate?orgName={org}&requestId={id}` | Check approval status (V1 reads still work) |
| `GET` | `/api/SafeFlyLease/v1/lease/{serviceId}` | Get leases for a service (V1 reads still work) |
| `GET` | `/api/SafeFlyRequest/v1/request/{orgName}/{requestId}` | Get request details (V1 reads still work) |

## Authentication

- **Resource ID**: `api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6`
- **Method**: Azure AD bearer token via `az account get-access-token --resource {resourceId}`
- **Header**: `Authorization: Bearer {token}`

## Request Creation DTO — `SafeFlyApiRequestCreationDTO`

All fields for `POST /api/RequestCreation/v1/requests`:

### Identity & Organization

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `orgName` | string | Yes | `"r2d"` or `"r2dpreview"` |
| `serviceTreeId` | uuid | Yes | Service Tree ID onboarded to SafeFly |
| `additionalNotifiers` | string[] | No | Extra email aliases to notify |
| `r2DFranchiseName` | string | No | R2D franchise name |
| `tags` | string[] | No | Tags for the request |

### Deployment Details — `DeploymentDetail`

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `deploymentDetail.buildUrl` | string | Yes | URL to the build |
| `deploymentDetail.buildId` | string | Yes | Build ID |
| `deploymentDetail.buildNumber` | string | Yes | Build number |
| `deploymentDetail.deploymentTool` | string | Yes | See **DeploymentTool** enum below |
| `deploymentDetail.isGradualRollout` | boolean | Yes | `true` / `false` |
| `deploymentDetail.isIntegratedWithSDP` | boolean | Yes | `true` / `false` |
| `deploymentDetail.developmentDetails` | string | No | Dev details text |
| `deploymentDetail.pilotFishBuildInformation` | object | No | PilotFish-specific build info |

### Deployment Type — `DeploymentType`

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `deploymentType.deploymentTypeName` | string | Yes | See **DeploymentTypeName** enum below |
| `deploymentTypeOther` | string | If "Other" | Name of other deployment type |

### Timing

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `anticipatedStartTime` | datetime | Yes | Format: `YYYY-MM-DDTHH:MM:SS` |
| `anticipatedEndTime` | datetime | Yes | Format: `YYYY-MM-DDTHH:MM:SS` |
| `regionSpecificDeploymentEstimates` | array | No | Per-region start/end times |

### Regions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `targetedRegions` | string[] | Conditional | Required if onboarded to Azure Update Tracker or active CCOA. Uses **display names** from the SafeFly UI list (e.g., "East US 2", "Australia Central"). See the full list of ~77 Public Regions + sovereign regions in the agent's Domain Knowledge. |
| `targetedRegionsOther` | string[] | If "Other" | Regions not in the standard SafeFly UI list — comma-separated free text |

### Deployment Nature & SDP

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `deploymentNature` | string[] | Yes | See **DeploymentNature** enum below |
| `sdpType` | string | Yes | See **SDPType** enum below |

### Change Description

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `customerFacingChangeTitle` | string | Yes | Title visible to customers |
| `customerFacingChangeDescription` | string | Yes | Description visible to customers |

### Impact & Blast Radius

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `impactType` | string[] | Yes | See **ImpactType** enum below |
| `impactDuration` | int32 | Yes | Duration in minutes |
| `blastRadius` | string | Yes | See **BlastRadius** enum below |
| `blastRadiusOther` | string | If "Other" | Custom blast radius |

### Rollback

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `rollback` | string | Yes | See **Rollback** enum below |
| `rollbackDetails` | string | If "Manual (TSG)" | How rollback will be performed |
| `rollbackRollforwardTesting` | boolean | Yes | Whether rollback/rollforward tested |
| `rollbackTimeInMinutes` | int32 | Yes | Expected rollback time |

### Health Signals

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sev2Alerting` | string | Yes | `"yes"` or `"no"` |
| `hasSev2AlertingDetails` | string | If "yes" | Details of health signal integration |
| `noSev2AlertingDetails` | string | If "no" | Why no health signals |

### Risk

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `teamAssessedRisk` | string | Yes | `"Low"`, `"Medium"`, `"High"` |
| `teamAssessedRiskJustification` | string | No | Justification text |
| `plansForRiskMitigation` | string | No | Risk mitigation plan |

### Pre-Production Testing — `PreProdTestingDetails[]`

| Field | Type | Required | Valid Values |
|-------|------|----------|-------------|
| `preProdTesting[].preProdTestingType` | string | Yes | See **PreProdTestingType** enum below |
| `preProdTesting[].preProdTestingDetail` | string | Yes | Link to test results |

### Retake

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hasRetake` | boolean | Yes | Whether this is a retake deployment |
| `retakeDetails` | string | No | Retake details |
| `deploymentRetakeDetails` | object | If retake | IcM ID, original SafeFly ID, justification |

### CCOA

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ccoaDetails.ccoaEventId` | string | Conditional | CCOA event ID |
| `ccoaDetails.ccoaExceptionJustification` | string | Conditional | Why deploying during CCOA |

### SFI Details — `SfiDetail`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sfiDetails` | object | No | SFI compliance information |

### Config Change (conditional)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `configChangeTypes` | string[] | If nature="Config change" | `"Service Config"`, `"Feature Flag"`, `"Secrets"`, `"Other"` |
| `globalConfigChange` | string | If nature="Config change" | `"yes"` or `"no"` |
| `configChangeTypesOther` | string | If type="Other" | Custom config change type |

### Breaking Change

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `isBreakingChange` | string | No | `"yes"`, `"no"`, or `"undetermined"` |
| `breakingChangeApprovedADOLink` | string | If "yes" | Link to approved ADO work item |

### Lease

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `isRequestCoveredByALease` | boolean | No | Whether covered by a lease |
| `coveredByLeaseId` | string | No | Lease ID |

### IDNA Questions — `IDNAQuestionsApiDTO`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `idnaQuestions.changeMechanism` | object | No | Change mechanism details |
| `idnaQuestions.changeMonitoring` | object | No | Change monitoring details |
| `idnaQuestions.changeRollback` | object | No | Change rollback details |
| `idnaQuestions.pullRequestLink` | string | No | PR link |

### Walmart

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `isDeploymentForWalmart` | boolean | No | Whether for Walmart |

---

## Enum Reference — All Valid Values

### DeploymentNature (string[], multi-select)
1. `Config change`
2. `CRI fixes`
3. `Critical security fixes`
4. `General bug fixes`
5. `Monitoring/health signals`
6. `New feature`
7. `Policy change`
8. `Secrets/Certificate management`
9. `Sev 1/2 repair`
10. `OS/Image patch`
11. `Other`

### SDPType (string, single-select)
1. `Bypass SDP` — No SDP at all (emergency/livesite only)
2. `SDP Exception` — Exception granted to skip SDP
3. `Abbreviated SDP` — Shortened SDP process
4. `Custom SDP` — Custom-defined SDP stages
5. `Prioritized SDP` — Prioritized/fast-tracked SDP
6. `Standard SDP` — Standard multi-ring deployment
7. `Conservative SDP` — Most cautious, longest bake time

### DeploymentTypeName (string, single-select)
1. `Livesite Mitigation`
2. `Hotfix`
3. `Critical Rollout`
4. `Regular`
5. `Regular Maintenance`
6. `Capacity and Buildout`
7. `Config Change`
8. `Decommission`
9. `Other`

### DeploymentTool (string, single-select)
1. `EV2`
2. `AzDeployer`
3. `WARM`
4. `CIS`
5. `PilotFish`
6. `Wan_Warpops`
7. `CDT`
8. `clockwerk`
9. `Fuse`
10. `ACIS_Geneva`
11. `XDeploy`
12. `AGSWorkloadConfiguration`
13. `ConfigV2Platform`
14. `DCMConfiguration`
15. `ESTSBRS`
16. `1PGitADOPipeline`
17. `GatewayConfig`
18. `LivesiteManagerLSM`
19. `Oaas`
20. `Other`

### ImpactType (string[], single-select despite array)
1. `Blackout`
2. `Brownout`
3. `Grayout`
4. `Reboot`
5. `DBFailover`
6. `Latency`
7. `None`

### BlastRadius (string, single-select)
1. `Single Node`
2. `Single Customer`
3. `Single Scale Unit (slice/partition)`
4. `Single Rack`
5. `Single Cluster`
6. `Single Cell`
7. `Single AZ`
8. `Single Region`
9. `Single Deployment Ring`
10. `Multiple Racks`
11. `Multiple Cluster`
12. `Multiple AZs`
13. `Multiple Regions`
14. `Multiple Scale Units`
15. `Global`
16. `Other`

### Rollback (string, single-select)
1. `Fully automated`
2. `Manual (TSG)`
3. `No Rollback`
4. `Rollforward`
5. `DRI determines rollback or rollforward in real time based on the issue`

### Risk / TeamAssessedRisk (string, single-select)
1. `Low`
2. `Medium`
3. `High`

### PreProdTestingType (string, single-select per entry)
1. `Compatibility Testing`
2. `Config Testing`
3. `Configuration matrix Testing`
4. `Configuration Schema Validation Testing`
5. `End to End Testing`
6. `Feature Flags Testing`
7. `Hotfix Testing`
8. `Integration Testing`
9. `IPv6 Testing`
10. `Performance Testing`
11. `Resiliency/Chaos Testing`
12. `Rollback Testing`
13. `Runners and Monitoring Testing`
14. `Security Testing`
15. `Stress Testing`
16. `Unit Testing`
17. `Upgrade Testing`
18. `Other`

### RequestState (response only)
`Archived`, `Unsubmitted`, `Draft`, `EngineeringDirectorPending`, `EngineeringDirectorRejected`, `ServiceManagerPending`, `ServiceManagerRejected`, `BuddyPending`, `BuddyRejected`, `ReadyToDeployPending`, `CvpPending`, `CvpRejected`, `Completed`, `ApprovedForDeployment`, `Deployed`, `Deleted`, `Unknown`, `DeploymentInProgress`, `DeploymentCompleted`, `DeploymentPaused`, `DeploymentCancelled`, `AutoApproved`, `Template`

### CloudType
`Azure`, `AzureGovernment`, `AzureChina`

### SafeFlyFormType
`Version1`, `Version2`, `Cloudnet`, `ReadyToDeploy`, `ReadyToDeployV2`

---

## Response DTO — `SafeFlyApiRequestCreationResponse`

| Field | Type | Description |
|-------|------|-------------|
| `safeFlyId` | string | The SafeFly request GUID |
| `safeFlyUrl` | string | URL to view the request in SafeFly portal |
| `requestNumber` | string | Numeric request number |
| `requestStatus` | string | Current status (e.g., `EdApproved`) |
| `message` | string | Confirmation message |

---

## Source

Full OpenAPI spec: `https://www.safefly.azure.com/swagger/v1/swagger.json`
