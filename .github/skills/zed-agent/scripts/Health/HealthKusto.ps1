<#
.SYNOPSIS
    Kusto access for the release health check (dot-source).

.DESCRIPTION
    Invoke-HealthKql runs one query through the Kusto REST API (v1) with an `az` token,
    a server timeout, a row cap and retries on throttling/transient errors, and returns
    the primary table as PSCustomObjects. Watcher-safe: the token call is time-boxed.
#>

$script:HealthKustoTokens = @{}

function Get-HealthKustoToken {
    param([Parameter(Mandatory)][string]$Cluster)
    $resource = ([uri]$Cluster).GetLeftPart([UriPartial]::Authority)
    $cached = $script:HealthKustoTokens[$resource]
    if ($cached -and $cached.Expires -gt (Get-Date).AddMinutes(5)) { return $cached.Token }
    $job = Start-Job -ScriptBlock { param($r) az account get-access-token --resource $r -o json 2>&1 } -ArgumentList $resource
    if (-not (Wait-Job $job -Timeout 60)) { Stop-Job $job; Remove-Job $job -Force; throw "az token acquisition for $resource timed out after 60s" }
    $out = Receive-Job $job; Remove-Job $job -Force
    try { $t = ($out -join "`n") | ConvertFrom-Json } catch { throw "az token for $resource failed: $($out -join ' ')" }
    if (-not $t.accessToken) { throw "az token for $resource failed: $($out -join ' ')" }
    $expires = try { [datetime]$t.expiresOn } catch { (Get-Date).AddMinutes(30) }
    $script:HealthKustoTokens[$resource] = @{ Token = $t.accessToken; Expires = $expires }
    $t.accessToken
}

function Invoke-HealthKql {
    param(
        [Parameter(Mandatory)][string]$Cluster,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutMinutes = 15,
        [int]$MaxRows = 500000,
        [int]$MaxAttempts = 3
    )
    $props = @{ Options = @{ servertimeout = ('00:{0:00}:00' -f [math]::Min($TimeoutMinutes, 59)); truncationmaxrecords = $MaxRows } } | ConvertTo-Json -Compress -Depth 4
    $body = @{ db = $Database; csl = $Query; properties = $props } | ConvertTo-Json -Depth 4
    $uri = $Cluster.TrimEnd('/') + '/v1/rest/query'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $token = Get-HealthKustoToken -Cluster $Cluster
            $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec (($TimeoutMinutes + 2) * 60) -ErrorAction Stop
            $table = $resp.Tables[0]
            $cols = @($table.Columns | ForEach-Object ColumnName)
            # Partial failures (e.g. E_RUNAWAY_QUERY / LimitsExceeded) come back as HTTP 200 with an in-band
            # { Exceptions: [...] } row — never treat incomplete results as data.
            foreach ($t in @($resp.Tables)) {
                foreach ($r in @($t.Rows)) {
                    if ($r -isnot [System.Array] -and $r.PSObject.Properties['Exceptions']) {
                        $ex = @($r.Exceptions)[0]
                        $m = if ($ex -is [string]) { $ex } elseif ($ex.error) { "$($ex.error.code): $($ex.error.message)" } else { ($ex | ConvertTo-Json -Compress -Depth 4) }
                        throw [System.InvalidOperationException]::new("Kusto partial query failure: $($m.Substring(0, [math]::Min(500, $m.Length)))")
                    }
                }
            }
            $rows = foreach ($r in $table.Rows) {
                $o = [ordered]@{}
                for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $r[$i] }
                [pscustomobject]$o
            }
            return , @($rows)
        } catch {
            $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            $msg = $_.Exception.Message
            $detail = try { $_.ErrorDetails.Message } catch { $null }
            $transient = $status -in @(0, 408, 429, 500, 502, 503, 504) -and $msg -notmatch 'Syntax|Semantic|BadRequest|partial query failure'
            if ($status -eq 401) { $script:HealthKustoTokens.Clear(); $transient = $true }
            if (-not $transient -or $attempt -eq $MaxAttempts) {
                throw "Kusto query failed (HTTP $status): $msg $(if ($detail) { $detail.Substring(0, [math]::Min(600, $detail.Length)) })"
            }
            Start-Sleep -Seconds ([math]::Min(10 * [math]::Pow(2, $attempt - 1), 60))
        }
    }
}
