# SafeFly R2D API Reference

> Updated: 2026-08-24 -- **SafeFly V2 GraphQL is now the write path.** V1 REST write endpoint
> (`https://www.safefly.azure.com/api/RequestCreation/v1/requests`) is in permanent read-only mode
> (HTTP 410). All R2D creation uses the V2 GraphQL API at `https://safeflyv2.live.azure.com/api/v1.0/graphql`.
> V1 REST **read** endpoints were said to remain operational; on 2026-10-20 the V1 `approvalstate` read also returned HTTP 410 — approval state is read from V2 (see "V2 approval state").

---

## V2 GraphQL API (Current -- Write Path)

### Transport

| Property | Value |
|----------|-------|
| Endpoint | `https://safeflyv2.live.azure.com/api/v1.0/graphql` |
| Method | `POST` |
| Content-Type | `application/json` |
| Accept | `application/json` |
| Auth | Azure AD bearer token -- audience `api://f6f1426c-4d1b-44d8-8e36-db5824a21fe2` |

> **Gotcha**: `Invoke-WebRequest.Content` returns a `byte[]` -- decode with
> `[System.Text.Encoding]::UTF8.GetString($r.Content)`. Do NOT cast to string directly.

> **Gotcha**: A bare `GET` returns HTTP 400. Always `POST` even for queries.

> **Gotcha**: GraphQL errors arrive in the response **body** (`$.errors[]`), not as HTTP error
> codes. Always check `$response.errors` -- a HTTP 200 with an `errors` array is a failure.

### HTML Guard

`safeflyv2.live.azure.com` may return `text/html` (SPA shell fallback) for misconfigured paths.
Always check `Content-Type` before parsing as JSON. ZED scripts throw `SAFEFLY_HTML_RESPONSE`
when an HTML body is detected.

### V2 Authentication

```powershell
$token = az account get-access-token `
    --resource 'api://f6f1426c-4d1b-44d8-8e36-db5824a21fe2' `
    --query accessToken -o tsv
```

#### Required Caller Identity for V2 Writes

| Field | Value |
|-------|-------|
| App role | `ExternalStandardAccess` (id `1ae39048-fba8-4242-9f99-4bec0a89c4fe`) |
| Resource | `safeflyv2-prod` audience `api://f6f1426c-4d1b-44d8-8e36-db5824a21fe2` |
| MAB SP | "BCDR SafeFly App" appId `62308d56-4ed4-41de-8a5c-ca98bb971ffc` (objectId `51c27a26-68f6-4ddb-b3ce-5856a81bf167`) |
| ADO service connection | `712dc115-726d-45e5-8573-f174f12f836a` (msazure/One) |

Configure via `safefly.tokenAudience` + `safefly.graphQlEndpoint` +
`safefly.requestCreatorAdoServiceConnectionId` in `service-config.json`.

### V2 Script Helpers

| Script | Purpose |
|--------|---------|
| `Invoke-SafeFlyGraphQL.ps1` | Config-driven GraphQL transport: auth, byte-array decode, `errors[]` surfacing, 429/5xx retry (non-retry on 401/403/410), HTML guard |
| `Get-SafeFlyForm.ps1` | Queries `activeForm(franchiseId, changeTypeId, expandWidgetQuestionsInline: true)`; asserts question count > 1 (truncation guard) |
| `New-SafeFlyRequest.ps1` | Full V2 flow: form fetch -> SDP mapping -> answer assembly -> `Resolve-EffectiveRequired` -> fail-closed -> 14-field payload -> DryRun gate -> `submitRequest` mutation |

### MAB-Specific V2 GUIDs (msazure/One/Mgmt-RecoverySvcs-BackupDataPlane)

| Key | Value |
|-----|-------|
| `franchiseId` | `b52a8292-9c66-4139-9086-acb61009fad6` |
| `serviceId` | `fb10185a-465d-42cd-b339-7d0d9331c340` |
| `changeTypeId` | `1bdba704-213b-4239-8dd7-691457341440` ("App deployment") |
| `formId` | `9561b383-3538-46c2-849f-e2756292d665` (active since 13.14983; 13.12038 used `3cc72aed-…`) |

### GraphQL Queries

#### Fetch Active Form

```graphql
query GetActiveForm($franchiseId: ID!, $changeTypeId: ID!) {
  activeForm(
    franchiseId: $franchiseId
    changeTypeId: $changeTypeId
    expandWidgetQuestionsInline: true
  ) {
    id
    questions {
      id
      name
      label
      required
      type
      options { id label value }
      conditionalRule { type questionId value }
    }
  }
}
```

> **Critical gotcha**: Using `staticOptions` instead of `options { id label value }` silently
> truncates results to **1 question**. Always use the `options { id label value }` sub-selection.

#### Submit Request Mutation

```graphql
mutation SubmitRequest($input: SaveRequestRequestBaseInput!) {
  submitRequest(input: $input) {
    id
    requestNumber
    status
    url
  }
}
```

### `SaveRequestRequestBaseInput` -- exactly 14 fields

| Field | Type | Notes |
|-------|------|-------|
| `requestId` | string | New UUID for this request |
| `changeTitle` | string | Title of the change |
| `changeDescription` | string | Description of the change |
| `franchiseId` | ID | From config |
| `changeTypeId` | ID | From config |
| `serviceId` | ID | From config |
| `formId` | ID | From config |
| `requestType` | string | `"New"` |
| `answers` | QuestionAnswer[] | Array of `{ questionId, value }` |
| `tagIds` | ID[] | `[]` (empty) |
| `shouldSuppressIcmErrors` | boolean | `false` |
| `requestExceptions` | string[] | `[]` (empty) |
| `owner` | string | Release owner alias |
| `ownerAssignmentNotes` | string | `""` |

### Answer Assembly Rules

#### Value encoding (verified against stored requests 13.14983 / 13.12038, 2026-10)

| Question kind | Encoding | Example |
|---------------|----------|---------|
| `isMultiSelect: true` (`core.regions`, `ev2.servicegroup`, …) | JSON array string | `["microsoft.azure.backup.cntl.bcm.active"]` |
| option-based single select | the option **value** (not the label) | `core.sdp` label `Standard SDP (Normal Rollout)` → `Standard SDP`; `ado.build_na` `Applicable` → `False` |
| free text | plain string | `ev2.build` = `Release-2610-1` (the production pipeline run's buildNumber) |

- `core.regions` values come from `getRegionsWithActiveCCOACoverage` (127 CamelCase ids on 2026-10-20). There is **no** hard-coded drop list — targeted regions not in the live list go to `core.other_regions`.
- `tagIds` are **tag GUIDs**. `tags(name:)` is a case-insensitive *contains* match — keep the exact-name hit only. A configured tag that does not exist (e.g. `BCM_Regular_Rollout`) is skipped with a warning; never send names.
- The config `formId` must equal the active form's id (question ids come from the active form) — `New-SafeFlyRequest.ps1` fails closed on a mismatch.

#### V2 approval state (read)

`requests(filter: { objectId: { equalTo: <id> } }) { data { currentState } }` — the V1
`/api/SafeFlyRequest/approvalstate` read returns **HTTP 410** (2026-10). V2 `currentState` values:
`Approved`; `Draft`, `Submitted`, `Engineering Director Reviewed`, `R2D Reviewed` (pending);
`Rejected`; `Abandoned`. `Get-SafeFlyApproval.ps1` uses this when `safefly.graphQlEndpoint` is set.

#### SDP Mapping (V1 -> V2 option labels)

| V1 value | V2 option label |
|----------|----------------|
| `Standard SDP` | `Standard SDP (Normal Rollout)` |
| `Conservative SDP` | `Conservative SDP` |

#### EV2 Partition Filtering

The App deployment form has **43 questions** but only `ev2.*` questions apply to EV2 orchestrated
deployments. Skip non-EV2 prefixes: `azdeployer.`, `lsm.`, `pilotfish.`, `storage.`, `other.`

#### Effective-Required Derivation

Never hardcode the required question set. Derive at runtime from each question's `conditionalRule`:

```powershell
function Resolve-EffectiveRequired($questions, $answers) {
    $questions | Where-Object { $_.required } | Where-Object {
        $r = $_.conditionalRule
        if (-not $r) { return $true }  # always required
        $parentAnswer = ($answers | Where-Object { $_.questionId -eq $r.questionId }).value
        $parentAnswer -eq $r.value     # required only if parent equals expected value
    }
}
```

#### Fail-Closed Validation

After answer assembly, verify every effective-required question has an answer. If any are missing,
throw with the list of unanswered required question names. Never submit an incomplete R2D.

### DryRun Gate

`New-SafeFlyRequest.ps1` accepts a `-DryRun` switch. When set, the script logs the full
14-field payload as JSON but **does NOT execute the `submitRequest` mutation**. Always use
`-DryRun` in test mode. The true test run never submits to production.

---

## V1 REST API (Legacy -- Read-Only)

> V1 **write** endpoint returns HTTP 410 permanently. As of 2026-10 the V1 `approvalstate` **read** also returns HTTP 410 — use the V2 approval-state read above.

### V1 Authentication

```powershell
$token = az account get-access-token `
    --resource 'api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6' `
    --query accessToken -o tsv
```

### V1 Read Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/SafeFlyRequest/approvalstate?orgName={org}&requestId={id}` | Check approval status |
| `GET` | `/api/SafeFlyLease/v1/lease/{serviceId}` | Get leases for a service |
| `GET` | `/api/SafeFlyRequest/v1/request/{orgName}/{requestId}` | Get request details |

### SPA-HTML Silent-Success Trap (V1)

`www.safefly.azure.com` returns **HTTP 200 Content-Type: text/html** for any unknown `/api/...`
path (SPA shell catch-all). Always check Content-Type before treating the body as JSON. The
SafeFly scripts throw `SAFEFLY_HTML_RESPONSE` when an HTML body is detected.

### Required Caller Identity for V1 (historical)

| Field | Value |
|-------|-------|
| App role | `SafeFly.Request` (id `91767177-5551-4c8f-8491-f054949f3360`) |
| Resource | Safefly_API appId `6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6` |
| MAB SP | "BCDR SafeFly App" appId `62308d56-4ed4-41de-8a5c-ca98bb971ffc` |
| ADO service connection | `712dc115-726d-45e5-8573-f174f12f836a` (msazure/One) |

---

## V1 Request Creation DTO (historical reference)

### Identity & Organization

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `orgName` | string | Yes | `"r2d"` or `"r2dpreview"` |
| `serviceTreeId` | uuid | Yes | Service Tree ID onboarded to SafeFly |
| `additionalNotifiers` | string[] | No | Extra email aliases to notify |
| `r2DFranchiseName` | string | No | R2D franchise name |
| `tags` | string[] | No | Tags for the request |
