<#
.SYNOPSIS
    Reusable GraphQL transport helper for SafeFly V2 API.

.DESCRIPTION
    POSTs a GraphQL query or mutation to the SafeFly V2 GraphQL endpoint.
    Handles authentication, response decoding (Invoke-WebRequest returns byte[],
    not a string), surfaces GraphQL errors[] as a terminating error, and retries
    only on transient faults (429/5xx) with exponential backoff.

    NEVER retries 401/403/410 — those are non-retryable and fail immediately with
    an actionable message naming the required audience, app role, service principal,
    and ADO service connection.

.PARAMETER Query
    GraphQL query or mutation string.

.PARAMETER Variables
    Optional hashtable of GraphQL variables.

.PARAMETER ServiceConfigPath
    Path to service-config.json. Defaults to two levels up from this script
    (i.e. the repo's .github/skills/zed-agent/ directory).

.OUTPUTS
    The `data` object from the GraphQL response (PSCustomObject).
    Throws on any GraphQL error, HTTP error, or config validation failure.

.NOTES
    Config requirements (service-config.json safefly block):
      safefly.graphQlEndpoint  — SafeFly V2 GraphQL URL (e.g. https://safeflyv2.live.azure.com/api/v1.0/graphql)
      safefly.tokenAudience    — AAD app audience (api://f6f1426c-4d1b-44d8-8e36-db5824a21fe2)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Query,
    [object]  $Variables         = @{},
    [string]  $ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = 'Stop'

$cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

$graphQlEndpoint = if ($cfg.safefly.PSObject.Properties['graphQlEndpoint']) { $cfg.safefly.graphQlEndpoint } else { $null }
$tokenAudience   = if ($cfg.safefly.PSObject.Properties['tokenAudience'])   { $cfg.safefly.tokenAudience }   else { $null }

if ([string]::IsNullOrWhiteSpace($graphQlEndpoint)) {
    throw "safefly.graphQlEndpoint is not configured in service-config.json. Add the SafeFly V2 GraphQL endpoint, e.g. https://safeflyv2.live.azure.com/api/v1.0/graphql"
}
if ([string]::IsNullOrWhiteSpace($tokenAudience)) {
    throw "safefly.tokenAudience is not configured in service-config.json. Add the SafeFly V2 token audience: api://f6f1426c-4d1b-44d8-8e36-db5824a21fe2"
}

Write-Verbose "SafeFly V2: acquiring token (audience: $tokenAudience)"
$token = az account get-access-token --resource $tokenAudience --query accessToken -o tsv
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Failed to acquire SafeFly V2 token for audience '$tokenAudience'. Run 'az login --tenant microsoft.com' first."
}

$bodyObj = @{ query = $Query; variables = $Variables }
$bodyStr = $bodyObj | ConvertTo-Json -Depth 10 -Compress
$headers = @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/json'
    Accept         = 'application/json'
}

$maxRetries = 3
$delaySec   = 2
$raw        = $null

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $raw = $null
    try {
        $raw = Invoke-WebRequest -Uri $graphQlEndpoint -Method POST -Headers $headers -Body $bodyStr -UseBasicParsing
        break
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }

        # Decode error body — may be byte[] (PS5) or string (PS7+)
        $rawDetail = $_.ErrorDetails.Message
        $detail = if ($rawDetail -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($rawDetail) } else { "$rawDetail" }

        # Surface GraphQL errors[] from an HTTP-error response body (e.g. 400 with errors[])
        if ($detail) {
            try {
                $errParsed = $detail | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($errParsed -and $errParsed.PSObject.Properties['errors'] -and $errParsed.errors) {
                    $graphqlMsgs = (@($errParsed.errors) | ForEach-Object { $_.message }) -join '; '
                    $detail = "GraphQL error(s): $graphqlMsgs"
                }
            } catch {}
        }

        # Non-retryable: auth failures
        if ($statusCode -in @(401, 403)) {
            throw "SafeFly V2 GraphQL HTTP $statusCode — caller lacks 'ExternalStandardAccess' app role " +
                  "(id 1ae39048-fba8-4242-9f99-4bec0a89c4fe) on safeflyv2-prod (audience: $tokenAudience). " +
                  "Required SP: 'BCDR SafeFly App' appId 62308d56-4ed4-41de-8a5c-ca98bb971ffc " +
                  "(objectId 51c27a26-68f6-4ddb-b3ce-5856a81bf167) via ADO service connection " +
                  "712dc115-726d-45e5-8573-f174f12f836a. Do NOT retry. Detail: $detail"
        }
        # Non-retryable: endpoint gone
        if ($statusCode -eq 410) {
            throw "SafeFly V2 GraphQL HTTP 410 Gone — endpoint permanently removed. Do NOT retry. Detail: $detail"
        }
        # Transient: retry with backoff
        if ($statusCode -eq 429 -or $statusCode -ge 500) {
            if ($attempt -lt $maxRetries) {
                Write-Warning "SafeFly V2 HTTP $statusCode (attempt $attempt/$maxRetries) — retrying in ${delaySec}s"
                Start-Sleep -Seconds $delaySec
                $delaySec *= 2
                continue
            }
        }
        throw "SafeFly V2 GraphQL HTTP $($statusCode ?? '?') — $detail"
    }
}

if (-not $raw) {
    throw "SafeFly V2 GraphQL: no response received after $maxRetries attempt(s) to '$graphQlEndpoint'"
}

# Decode content — Invoke-WebRequest.Content may be byte[] (PS5) or string (PS7+)
$c = $raw.Content
if ($c -is [byte[]]) { $c = [System.Text.Encoding]::UTF8.GetString($c) }
$responseText = $c

# HTML response guard: some Azure frontends return HTTP 200 Content-Type: text/html
# (SPA shell fallback) when the path is unrecognized. An HTML body is never a valid
# GraphQL response and must fail loudly here rather than confusing later JSON parsing.
$ct = if ($raw.Headers['Content-Type']) { ($raw.Headers['Content-Type'] -split ';')[0].Trim() } else { '' }
if ($ct -eq 'text/html' -or $responseText -match '^\s*<!DOCTYPE') {
    throw "SAFEFLY_HTML_RESPONSE: SafeFly V2 returned Content-Type '$ct' instead of application/json. " +
          "The endpoint '$graphQlEndpoint' served a SPA shell or redirect page — verify the configured graphQlEndpoint in service-config.json."
}

$gqlResponse = $responseText | ConvertFrom-Json

# Surface GraphQL-level errors as a real terminating error.
if ($gqlResponse.PSObject.Properties['errors'] -and $gqlResponse.errors) {
    $errs = @($gqlResponse.errors)
    if ($errs.Count -gt 0) {
        $messages = ($errs | ForEach-Object { $_.message }) -join '; '
        throw "SafeFly V2 GraphQL error(s): $messages"
    }
}

return $gqlResponse.data
