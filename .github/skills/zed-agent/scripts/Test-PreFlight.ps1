function Test-PreFlight {
    <#
    .SYNOPSIS
        Pre-flight readiness check for ZED Agent.
        Returns a structured result with pass/warn/fail items and an overall verdict.
        When ReleaseId is provided, also validates the release-specific files (release.json, state.json).
        Email transport is Mail MCP (Graph) only — preflight does not probe Outlook because Outlook
        is not used. The actual Mail MCP test send happens during `setup` action 10 (the agent itself
        invokes the MCP tool — a PowerShell script cannot).
    #>
    param(
        [string]$ReleaseId,
        [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\service-config.json'),
        # Tenant used for auto-remediation login. Defaults to microsoft.com.
        [string]$Tenant = 'microsoft.com'
    )

    $ErrorActionPreference = 'Stop'

    $checks = @()
    $baseDir = Join-Path (Get-Location) ".zed-agent"
    $skillDir = Join-Path (git rev-parse --show-toplevel) ".github\skills\zed-agent"

    # --- Load service config (tolerant) ---
    # Preflight is documented as runnable on a fresh clone BEFORE setup-service
    # has populated service-config.json. Load-ServiceConfig.ps1 is strict and
    # throws on the first empty required field — catch that here, register a
    # single fail row pointing at setup-service, and let every other check run.
    $cfg = $null
    try {
        $cfg = & (Join-Path $PSScriptRoot 'Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath
        $checks += @{ name = "Service config"; status = "pass"; detail = $ServiceConfigPath }
    } catch {
        $msg = $_.Exception.Message
        $checks += @{ name = "Service config"; status = "fail"; detail = "service-config.json is incomplete: $msg Run 'setup-service' to populate it." }
    }

    # ── 1. Pipeline catalog ──
    $catalogPath = Join-Path $skillDir "pipeline-catalog.json"
    if (Test-Path $catalogPath) {
        $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
        $checks += @{ name = "Pipeline catalog"; status = "pass"; detail = $catalogPath }

    # ── 1a. Pipeline definitions validation ──
        $pipelineIssues = @()
        if (-not $catalog.officialBuild -or -not $catalog.officialBuild.id) {
            $pipelineIssues += "officialBuild pipeline missing or has no ID"
        }
        $canaryCount = 0
        if ($catalog.canary) {
            foreach ($prop in $catalog.canary.PSObject.Properties) {
                $canaryCount++
                $entry = $prop.Value
                if (-not $entry.name) { $pipelineIssues += "canary pipeline '$($prop.Name)' has no name" }
                if ($null -eq $entry.id) { $pipelineIssues += "canary pipeline '$($prop.Name)' has null ID" }
            }
        }
        if ($canaryCount -eq 0) { $pipelineIssues += "No canary pipelines defined" }
        $prodCount = 0
        if ($catalog.production) {
            foreach ($prop in $catalog.production.PSObject.Properties) {
                $prodCount++
                $entry = $prop.Value
                if (-not $entry.name) { $pipelineIssues += "production pipeline '$($prop.Name)' has no name" }
                if ($null -eq $entry.id) { $pipelineIssues += "production pipeline '$($prop.Name)' has null ID" }
            }
        }
        if ($prodCount -eq 0) { $pipelineIssues += "No production pipelines defined" }

        if ($pipelineIssues.Count -gt 0) {
            $checks += @{ name = "Pipeline definitions"; status = "fail"; detail = ($pipelineIssues -join '; ') }
        } else {
            $checks += @{ name = "Pipeline definitions"; status = "pass"; detail = "officialBuild + $canaryCount canary + $prodCount production pipelines configured" }
        }
    } else {
        $checks += @{ name = "Pipeline catalog"; status = "fail"; detail = "Not found: $catalogPath" }
        $checks += @{ name = "Pipeline definitions"; status = "fail"; detail = "Cannot check — pipeline-catalog.json missing" }
    }

    # ── 2. Environment config ──
    $envPath = Join-Path $baseDir "environment.json"
    if (Test-Path $envPath) {
        $envCfg = Get-Content $envPath -Raw | ConvertFrom-Json
        $checks += @{ name = "Environment config"; status = "pass"; detail = $envPath }

        # Validate repoRoot
        if ($envCfg.repoRoot -and (Test-Path $envCfg.repoRoot)) {
            $checks += @{ name = "Repo root path"; status = "pass"; detail = $envCfg.repoRoot }
        } else {
            $checks += @{ name = "Repo root path"; status = "fail"; detail = "repoRoot '$($envCfg.repoRoot)' does not exist or is not set" }
        }

        # Validate tenantId
        if ($envCfg.tenantId) {
            $checks += @{ name = "Tenant ID"; status = "pass"; detail = "Configured" }
        } else {
            $checks += @{ name = "Tenant ID"; status = "warn"; detail = "Not set in environment.json — auto-detect will be attempted" }
        }

        # Validate SharePoint site ID
        if ($envCfg.sharePointSiteId) {
            $checks += @{ name = "SharePoint site ID"; status = "pass"; detail = "Configured" }
        } else {
            $checks += @{ name = "SharePoint site ID"; status = "warn"; detail = "Not set — commit Excel upload (Step 4) will fail" }
        }
    } else {
        $checks += @{ name = "Environment config"; status = "fail"; detail = "Not found: $envPath. Run setup to create it." }
        $checks += @{ name = "Repo root path"; status = "fail"; detail = "Cannot check — environment.json missing" }
    }

    # ── 3. Secrets ──
    $secretsPath = Join-Path $baseDir "secrets.json"
    if (Test-Path $secretsPath) {
        $secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json
        # Check Teams conversation IDs (CDP-based messaging)
        if ($secrets.teamsChats) {
            $allProps = @($secrets.teamsChats.PSObject.Properties)
            $configuredProps = @($allProps | Where-Object { $_.Value -and $_.Value -notmatch '^\{\{' -and $_.Value -ne '<conversation-id>' })
            $chatCount = $configuredProps.Count
            $totalChats = $allProps.Count
            if ($chatCount -eq $totalChats -and $chatCount -gt 0) {
                $names = ($configuredProps | ForEach-Object { $_.Name }) -join ', '
                $checks += @{ name = "Secrets (Teams chats)"; status = "pass"; detail = "$chatCount conversation ID(s) configured: $names" }
            } elseif ($chatCount -gt 0) {
                $checks += @{ name = "Secrets (Teams chats)"; status = "warn"; detail = "$chatCount of $totalChats conversation IDs configured. Some Teams notifications may fail." }
            } else {
                $checks += @{ name = "Secrets (Teams chats)"; status = "warn"; detail = "No conversation IDs configured. Teams notifications will be skipped." }
            }
        } else {
            $checks += @{ name = "Secrets (Teams chats)"; status = "warn"; detail = "No teamsChats section in secrets.json. Teams notifications will be skipped." }
        }

        # Check CDP reachability
        try {
            $cdpPort = if ($env:TEAMS_CDP_PORT) { $env:TEAMS_CDP_PORT } else { 9222 }
            $null = Invoke-RestMethod -Uri "http://localhost:$cdpPort/json" -TimeoutSec 5 -ErrorAction Stop
            $checks += @{ name = "Teams CDP"; status = "pass"; detail = "CDP reachable on port $cdpPort" }
        } catch {
            $checks += @{ name = "Teams CDP"; status = "warn"; detail = "CDP not reachable on port $cdpPort. Teams notifications require Teams running with CDP enabled." }
        }
    } else {
        $checks += @{ name = "Secrets (Teams chats)"; status = "fail"; detail = "secrets.json not found. Run setup to create it." }
    }

    # ── 4. Prerequisites (tools) ──
    # az CLI
    #
    # Shared remediation helper — dot-sources Repair-AzAuth.ps1 so the cascade logic
    # lives in exactly one place. Same script is invoked by in-flight steps (5/7/10)
    # when they hit a token error mid-run.
    $repairScript = Join-Path $PSScriptRoot 'Repair-AzAuth.ps1'
    $invokeAzAuthRemediation = {
        param([string]$tenant, [string]$resource)
        if ($resource) {
            & $repairScript -Tenant $tenant -Resource $resource
        } else {
            & $repairScript -Tenant $tenant
        }
    }

    try {
        $azVer = az version 2>$null | ConvertFrom-Json
        $azLoggedIn = az account show --query user.name -o tsv 2>$null

        # Inline helper so we can re-run the same validation without duplicating logic.
        $validateAzToken = {
            param([string]$signedInUser)
            $probe = az account get-access-token --query expiresOn -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and $probe) {
                return @{ ok = $true; detail = "Logged in as $signedInUser (token valid until $probe)" }
            }
            return @{ ok = $false; error = ($probe | Out-String).Trim() }
        }

        if (-not $azLoggedIn -or -not (& $validateAzToken $azLoggedIn).ok) {
            $initialErr = if ($azLoggedIn) { (& $validateAzToken $azLoggedIn).error } else { "Not logged in" }
            Write-Host "[Auto-remediate] az CLI not usable ($initialErr). Starting full remediation cascade against tenant '$Tenant'..." -ForegroundColor Yellow

            $remediation = & $invokeAzAuthRemediation $Tenant $null

            if ($remediation.ok) {
                $recheck = & $validateAzToken $remediation.user
                $checks += @{ name = "Azure CLI"; status = "pass"; detail = "[Auto-remediated] $($recheck.detail)" }
            } else {
                $checks += @{ name = "Azure CLI"; status = "fail"; detail = "[Auto-remediate] All 3 attempts (interactive / WAM-disabled / device-code) failed. Original error: $initialErr. Last error: $($remediation.lastError). Contact your tenant admin if Conditional Access is blocking sign-in." }
            }
        } else {
            $ok = & $validateAzToken $azLoggedIn
            $checks += @{ name = "Azure CLI"; status = "pass"; detail = $ok.detail }
        }
    } catch {
        $checks += @{ name = "Azure CLI"; status = "fail"; detail = "Not found or not working: $($_.Exception.Message)" }
    }

    # git
    $gitVer = git --version 2>$null
    if ($gitVer) {
        $checks += @{ name = "Git"; status = "pass"; detail = $gitVer }
    } else {
        $checks += @{ name = "Git"; status = "fail"; detail = "Not found in PATH" }
    }

    # pwsh
    $pwshVer = pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
    if ($pwshVer) {
        $checks += @{ name = "PowerShell 7"; status = "pass"; detail = "v$pwshVer" }
    } else {
        $checks += @{ name = "PowerShell 7"; status = "warn"; detail = "pwsh not found — using current shell" }
    }

    # ImportExcel module
    $excelMod = Get-Module -ListAvailable ImportExcel 2>$null
    if ($excelMod) {
        $checks += @{ name = "ImportExcel module"; status = "pass"; detail = "v$($excelMod.Version)" }
    } else {
        $checks += @{ name = "ImportExcel module"; status = "warn"; detail = "Not installed. Step 4 (commit Excel) will fail. Install: Install-Module ImportExcel" }
    }

    # Email transport: Mail MCP only (no preflight probe — see header).
    # The agent runs the live Mail MCP test send in setup action 10.

    # ── 4b. Kusto connectivity ──
    $kustoCluster = if ($cfg) { $cfg.kusto.canary.cluster } else { $null }
    $kustoDb      = if ($cfg) { $cfg.kusto.canary.database } else { $null }
    if ([string]::IsNullOrWhiteSpace($kustoCluster) -or [string]::IsNullOrWhiteSpace($kustoDb)) {
        $checks += @{ name = "Kusto connectivity"; status = "fail"; detail = "kusto.canary.cluster or kusto.canary.database not set in service-config.json. Populate both before running pre-flight." }
    } else {
        try {
            # Resource must match the actual cluster so the token's audience is correct;
            # a hardcoded generic resource yields tokens the cluster rejects with 401.
            $kustoTokenRaw = az account get-access-token --resource $kustoCluster --query accessToken -o tsv 2>&1
            $kustoTokenAcquired = ($LASTEXITCODE -eq 0 -and $kustoTokenRaw)

            # If the token acquisition fails — most commonly the WAM-broker-can't-issue-custom-resource-tokens
            # bug — invoke the shared remediation cascade (clear cache → login → disable WAM → device code).
            if (-not $kustoTokenAcquired) {
                $initialKustoErr = ($kustoTokenRaw | Out-String).Trim()
                Write-Host "[Auto-remediate] Kusto token acquisition failed for $kustoCluster. Triggering auth remediation (likely WAM broker bug)..." -ForegroundColor Yellow
                $remediation = & $invokeAzAuthRemediation $Tenant $kustoCluster
                if ($remediation.ok) {
                    Write-Host "[Auto-remediated] Auth fixed. Re-acquiring Kusto token..." -ForegroundColor Green
                    $kustoTokenRaw = az account get-access-token --resource $kustoCluster --query accessToken -o tsv 2>&1
                    $kustoTokenAcquired = ($LASTEXITCODE -eq 0 -and $kustoTokenRaw)
                    if (-not $kustoTokenAcquired) {
                        $checks += @{ name = "Kusto connectivity"; status = "fail"; detail = "[Auto-remediate] Auth remediation succeeded but Kusto token still unavailable. Initial: $initialKustoErr. Latest: $(($kustoTokenRaw | Out-String).Trim())." }
                    }
                } else {
                    $checks += @{ name = "Kusto connectivity"; status = "fail"; detail = "[Auto-remediate] Cannot get Kusto token for $kustoCluster after full remediation cascade. Initial error: $initialKustoErr. Last error: $($remediation.lastError)." }
                }
            }

            if ($kustoTokenAcquired) {
                $kustoToken = ($kustoTokenRaw | Out-String).Trim()
                $kustoHeaders = @{ Authorization = "Bearer $kustoToken"; 'Content-Type' = 'application/json' }
                $testBody = @{ db = $kustoDb; csl = ".show database ['$kustoDb'] schema | take 1" } | ConvertTo-Json
                $kustoResp = Invoke-RestMethod -Uri "$kustoCluster/v1/rest/query" -Method Post -Headers $kustoHeaders -Body $testBody -TimeoutSec 15 -ErrorAction Stop
                $checks += @{ name = "Kusto connectivity"; status = "pass"; detail = "Connected to $kustoCluster / $kustoDb" }
            }
        } catch {
            $checks += @{ name = "Kusto connectivity"; status = "fail"; detail = "Kusto query failed: $($_.Exception.Message.Substring(0, [Math]::Min(120, $_.Exception.Message.Length)))" }
        }
    }

    # ── 4c. EV2 API connectivity ──
    try {
        $ev2Token = az account get-access-token --resource "https://azureservicedeploy.msft.net" --query accessToken -o tsv 2>$null
        if ($ev2Token) {
            $checks += @{ name = "EV2 API token"; status = "pass"; detail = "Token acquired for azureservicedeploy.msft.net" }
        } else {
            $checks += @{ name = "EV2 API token"; status = "warn"; detail = "Cannot acquire EV2 token. Step 15 rollout diagnostics will be limited." }
        }
    } catch {
        $checks += @{ name = "EV2 API token"; status = "warn"; detail = "EV2 token check failed: $($_.Exception.Message)" }
    }

    # ── 4d. AzureServiceConfig (live cloud/region directory) ──
    # ADO source-of-truth for cloud/region/stamp topology, consumed by
    # Get-StampInventory.ps1. Live fetch is the goal; cache + committed
    # snapshot are degraded fallbacks that surface a warning here.
    $ascSnapshot = Join-Path $skillDir 'fixtures\AzureServiceConfig.snapshot.json'
    if (-not (Test-Path $ascSnapshot)) {
        $checks += @{ name = "ASC snapshot"; status = "fail"; detail = "Missing offline fallback at $ascSnapshot. Restore from the configured region source (regions.ascRepo)." }
    } else {
        $checks += @{ name = "ASC snapshot"; status = "pass"; detail = "Offline fallback present ($([math]::Round((Get-Item $ascSnapshot).Length/1KB,1)) KB)" }
    }
    try {
        $ascScript = Join-Path $PSScriptRoot 'Get-AzureServiceConfig.ps1'
        if (-not (Test-Path $ascScript)) {
            $checks += @{ name = "ASC live reachability"; status = "fail"; detail = "Get-AzureServiceConfig.ps1 missing at $ascScript" }
        } else {
            $asc = & $ascScript -NoCache -ErrorAction Stop 3>$null 4>$null
            if ($asc -and $asc.source -eq 'live' -and @($asc.data.Clouds).Count -gt 0) {
                $checks += @{ name = "ASC live reachability"; status = "pass"; detail = "Fetched $(@($asc.data.Clouds).Count) clouds live from the configured region source" }
            } else {
                $checks += @{ name = "ASC live reachability"; status = "fail"; detail = "Live fetch returned no Clouds. Investigate ADO permissions on the configured region source (regions.ascRepo)." }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        $checks += @{ name = "ASC live reachability"; status = "warn"; detail = "Live ASC fetch failed: $($msg.Substring(0, [Math]::Min(160, $msg.Length))). Get-StampInventory will fall back to cache/snapshot." }
    }

    # ── 4e. Stamp inventory cache freshness (Layer 2) ──
    # Production inventory is sourced from Kusto by Get-StampInventory.ps1
    # and persisted at .zed-agent/cache/inventory.production.json on each
    # successful pull. Canary inventory comes from service-config and is not
    # cached. Missing production cache is acceptable on first run; stale
    # cache is a warn (release steps pass -NoCache anyway, but setup-service
    # discovery loops read it).
    try {
        $repoRoot     = (git rev-parse --show-toplevel 2>$null)
        $invCacheProd = if ($repoRoot) { Join-Path $repoRoot '.zed-agent/cache/inventory.production.json' } else { $null }
        if (-not $invCacheProd -or -not (Test-Path $invCacheProd)) {
            $checks += @{ name = "Inventory cache (production)"; status = "info"; detail = "Not yet populated. First cluster-type production resolver run will create $invCacheProd." }
        } else {
            $ageH = ((Get-Date).ToUniversalTime() - (Get-Item $invCacheProd).LastWriteTimeUtc).TotalHours
            if ($ageH -gt 24) {
                $checks += @{ name = "Inventory cache (production)"; status = "warn"; detail = "Cache is $([math]::Round($ageH,1))h old (>24h). Release steps will re-fetch live; setup-service discovery may read stale data." }
            } else {
                $checks += @{ name = "Inventory cache (production)"; status = "pass"; detail = "Fresh ($([math]::Round($ageH,1))h old) at $invCacheProd" }
            }
        }
    } catch {
        $checks += @{ name = "Inventory cache (production)"; status = "warn"; detail = "Could not check cache: $($_.Exception.Message)" }
    }

    # ── 5. Skill scripts ──
    $requiredScripts = @(
        "Update-ReleaseState.ps1", "Expand-Template.ps1", "Send-TeamsMessage.ps1",
        "New-CommitExcel.ps1", "Upload-ToSharePoint.ps1",
        "Register-WatcherTask.ps1", "Release-Watcher.ps1", "Get-RegionMapping.ps1",
        "Get-AzureServiceConfig.ps1", "Get-StampInventory.ps1", "Get-StampsForPipeline.ps1",
        "Resolve-PipelinesByClusterType.ps1", "Invoke-DriftHalt.ps1",
        "SafeFly\New-SafeFlyRequest.ps1", "SafeFly\Get-SafeFlyApproval.ps1",
        "SafeFly\Get-SafeFlyLeases.ps1", "SafeFly\Test-SafeFlyConnection.ps1",
        "Add-Learning.ps1", "Apply-Learning.ps1", "Get-Learnings.ps1",
        "EV2\Get-Ev2RolloutStatus.ps1"
    )
    $missingScripts = @()
    foreach ($s in $requiredScripts) {
        if (-not (Test-Path (Join-Path $skillDir "scripts" $s))) { $missingScripts += $s }
    }
    if ($missingScripts.Count -gt 0) {
        $checks += @{ name = "Skill scripts"; status = "fail"; detail = "Missing: $($missingScripts -join ', ')" }
    } else {
        $checks += @{ name = "Skill scripts"; status = "pass"; detail = "All $($requiredScripts.Count) scripts present" }
    }

    # ── 5b. Kusto queries ──
    if ($cfg -and $cfg.kusto -and $cfg.kusto.bvt -and $cfg.kusto.bvt.queryFile) {
        $requiredQueries = @($cfg.kusto.bvt.queryFile)
        $missingQueries = @()
        foreach ($q in $requiredQueries) {
            if (-not (Test-Path (Join-Path $skillDir "queries" $q))) { $missingQueries += $q }
        }
        if ($missingQueries.Count -gt 0) {
            $checks += @{ name = "Kusto queries"; status = "fail"; detail = "Missing: $($missingQueries -join ', ')" }
        } else {
            $checks += @{ name = "Kusto queries"; status = "pass"; detail = "All $($requiredQueries.Count) query files present" }
        }
    } else {
        $checks += @{ name = "Kusto queries"; status = "warn"; detail = "Cannot check — service-config.json missing kusto.bvt.queryFile. Will be validated after setup-service." }
    }

    # ── 6. Templates ──
    $templateDir = Join-Path $skillDir "templates"
    if (Test-Path $templateDir) {
        $templateCount = (Get-ChildItem $templateDir -File).Count
        $checks += @{ name = "Templates"; status = "pass"; detail = "$templateCount template files found" }
    } else {
        $checks += @{ name = "Templates"; status = "warn"; detail = "Templates directory not found — notifications will use fallback text" }
    }

    # ── 7. Release-specific checks (only when ReleaseId provided) ──
    if ($ReleaseId) {
        $relDir = Join-Path $baseDir "releases/$ReleaseId"
        if (Test-Path $relDir) {
            $checks += @{ name = "Release directory"; status = "pass"; detail = $relDir }

            # release.json
            $relJsonPath = Join-Path $relDir "release.json"
            if (Test-Path $relJsonPath) {
                $rel = Get-Content $relJsonPath -Raw | ConvertFrom-Json
                $relIssues = @()
                if (-not $rel.currentBranch) { $relIssues += "currentBranch not set" }
                if (-not $rel.previousBranch) { $relIssues += "previousBranch not set" }
                if (-not $rel.dates.branchCut) { $relIssues += "branchCut date not set" }
                if (-not $rel.releaseOwner.alias) { $relIssues += "release owner alias not set" }
                if ($relIssues.Count -gt 0) {
                    $checks += @{ name = "Release config (release.json)"; status = "fail"; detail = ($relIssues -join '; ') }
                } else {
                    $checks += @{ name = "Release config (release.json)"; status = "pass"; detail = "Release owner: $($rel.releaseOwner.alias), Branch: $($rel.currentBranch), Cut: $($rel.dates.branchCut)" }
                }
            } else {
                $checks += @{ name = "Release config (release.json)"; status = "fail"; detail = "Not found: $relJsonPath" }
            }

            # state.json
            $stateJsonPath = Join-Path $relDir "state.json"
            if (Test-Path $stateJsonPath) {
                $st = Get-Content $stateJsonPath -Raw | ConvertFrom-Json
                $checks += @{ name = "Release state (state.json)"; status = "pass"; detail = "Status: $($st.status), Current step: $($st.currentStep), Steps: $($st.steps.Count)" }
            } else {
                $checks += @{ name = "Release state (state.json)"; status = "fail"; detail = "Not found: $stateJsonPath" }
            }

            # watcher task
            $watcherPrefix = if ($cfg -and $cfg.operational -and $cfg.operational.watcherTaskPrefix) { $cfg.operational.watcherTaskPrefix } else { $null }
            $taskName = if ($watcherPrefix) { "$watcherPrefix-$ReleaseId" } else { $null }
            $task = if ($taskName) { Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } else { $null }
            if ($task) {
                $checks += @{ name = "Watcher task"; status = "pass"; detail = "Task '$taskName' registered" }
            } else {
                $checks += @{ name = "Watcher task"; status = "warn"; detail = "Task '$taskName' not registered — watcher will need manual start" }
            }
        } else {
            $checks += @{ name = "Release directory"; status = "fail"; detail = "Not found: $relDir. Run setup to initialize this release." }
        }
    }

    # ── Categorize checks ──
    # Each check row is tagged with one of three categories so callers can
    # apply the right gate:
    #   env     — machine-readiness (az/git/pwsh/modules/MCP/ASC/skill scripts).
    #             Hard blocker for EVERY downstream command (setup-service,
    #             setup, run). If env is red, nothing else can succeed.
    #   config  — service-config.json / pipeline-catalog.json completeness.
    #             Expected to be red on a fresh clone — setup-service IS the
    #             remediation. Not a blocker for setup-service itself; IS a
    #             blocker for setup and run.
    #   release — per-release artefacts created by `setup` (environment.json,
    #             secrets.json, releases/<id>/*). Out of scope for both
    #             test-preflight standalone AND setup-service; only setup/run
    #             treat these as blockers.
    $envChecks = @(
        'Azure CLI','Git','PowerShell 7','ImportExcel module','EV2 API token',
        'ASC snapshot','ASC live reachability','Skill scripts','Templates','Teams CDP'
    )
    $configChecks = @(
        'Service config','Pipeline catalog','Pipeline definitions',
        'Kusto connectivity','Kusto queries','Inventory cache (production)'
    )
    $releaseChecks = @(
        'Environment config','Repo root path','Tenant ID','SharePoint site ID',
        'Secrets (Teams chats)','Release directory','Release config (release.json)',
        'Release state (state.json)','Watcher task'
    )

    foreach ($c in $checks) {
        $c.category = if ($envChecks -contains $c.name) { 'env' }
                      elseif ($configChecks -contains $c.name) { 'config' }
                      elseif ($releaseChecks -contains $c.name) { 'release' }
                      else { 'env' } # default = treat unknown as env (fail-safe)
    }

    # ── Compute verdicts ──
    function _verdictOf {
        param([array]$Rows)
        $f = ($Rows | Where-Object { $_.status -eq 'fail' }).Count
        $w = ($Rows | Where-Object { $_.status -eq 'warn' }).Count
        if ($f -gt 0) { 'fail' } elseif ($w -gt 0) { 'warn' } else { 'pass' }
    }

    $failCount = ($checks | Where-Object { $_.status -eq "fail" }).Count
    $warnCount = ($checks | Where-Object { $_.status -eq "warn" }).Count
    $passCount = ($checks | Where-Object { $_.status -eq "pass" }).Count

    $verdict        = if ($failCount -gt 0) { 'fail' } elseif ($warnCount -gt 0) { 'warn' } else { 'pass' }
    $envVerdict     = _verdictOf ($checks | Where-Object { $_.category -eq 'env' })
    $configVerdict  = _verdictOf ($checks | Where-Object { $_.category -eq 'config' })
    $releaseVerdict = _verdictOf ($checks | Where-Object { $_.category -eq 'release' })

    # ── Persist readiness.preflight ──
    $failureDetails = @($checks | Where-Object { $_.status -eq 'fail' } | ForEach-Object { "$($_.name): $($_.detail)" })
    $warningDetails = @($checks | Where-Object { $_.status -eq 'warn' } | ForEach-Object { "$($_.name): $($_.detail)" })

    try {
        & (Join-Path $PSScriptRoot 'Write-Readiness.ps1') -Stage 'preflight' -Data @{
            status         = $verdict
            verdict        = $verdict
            envVerdict     = $envVerdict
            configVerdict  = $configVerdict
            releaseVerdict = $releaseVerdict
            summary        = @{ pass = $passCount; warn = $warnCount; fail = $failCount }
            failures       = $failureDetails
            warnings       = $warningDetails
            overridden     = $false
        } | Out-Null
    } catch {
        Write-Warning "Could not persist readiness.preflight: $_"
    }

    return @{
        checks         = $checks
        summary        = @{ pass = $passCount; warn = $warnCount; fail = $failCount }
        verdict        = $verdict
        envVerdict     = $envVerdict
        configVerdict  = $configVerdict
        releaseVerdict = $releaseVerdict
    }
}
