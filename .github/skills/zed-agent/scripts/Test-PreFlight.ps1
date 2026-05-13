function Test-PreFlight {
    <#
    .SYNOPSIS
        Pre-flight readiness check for ZED Agent.
        Returns a structured result with pass/warn/fail items and an overall verdict.
        When ReleaseId is provided, also validates the release-specific files (release.json, state.json).
        When SendTestEmail is provided, sends a test email to that address as a live verification.
    #>
    param(
        [string]$ReleaseId,
        [string]$SendTestEmail,
        [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\service-config.json'),
        # Tenant used for auto-remediation login. Defaults to microsoft.com.
        [string]$Tenant = 'microsoft.com'
    )

    $ErrorActionPreference = 'Stop'

    # --- Load service config ---
    $cfg = & (Join-Path $PSScriptRoot 'Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

    $checks = @()
    $baseDir = Join-Path (Get-Location) ".zed-agent"
    $skillDir = Join-Path (git rev-parse --show-toplevel) ".github\skills\zed-agent"

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
    try {
        $azVer = az version 2>$null | ConvertFrom-Json
        $azLoggedIn = az account show --query user.name -o tsv 2>$null

        # Inline helper so we can re-run the same validation after AutoFix without duplicating logic.
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

            Write-Host "[Auto-remediate] az CLI not usable ($initialErr). Clearing MSAL cache and re-authenticating against tenant '$Tenant'..." -ForegroundColor Yellow
            az account clear 2>&1 | Out-Null

            # Try interactive (browser/WAM) login first — device-code flow is blocked by
            # Conditional Access in many tenants, so it must not be the first attempt.
            Write-Host "[Auto-remediate] Attempt 1: az login --tenant $Tenant (interactive browser). Complete sign-in in the browser window." -ForegroundColor Yellow
            az login --tenant $Tenant | Out-Host
            $loginExit = $LASTEXITCODE
            $azLoggedIn = az account show --query user.name -o tsv 2>$null

            # Fall back to device code only if the interactive flow failed (e.g., no browser available on the box).
            if ($loginExit -ne 0 -or -not $azLoggedIn) {
                Write-Host "[Auto-remediate] Attempt 1 failed (exit $loginExit). Falling back to: az login --tenant $Tenant --use-device-code" -ForegroundColor Yellow
                Write-Host "[Auto-remediate] Note: device-code flow is blocked by Conditional Access in some tenants; if this also fails, contact your tenant admin." -ForegroundColor Yellow
                az login --tenant $Tenant --use-device-code | Out-Host
                $loginExit = $LASTEXITCODE
                $azLoggedIn = az account show --query user.name -o tsv 2>$null
            }

            if ($loginExit -eq 0 -and $azLoggedIn) {
                $recheck = & $validateAzToken $azLoggedIn
                if ($recheck.ok) {
                    $checks += @{ name = "Azure CLI"; status = "pass"; detail = "[Auto-remediated] $($recheck.detail)" }
                } else {
                    $checks += @{ name = "Azure CLI"; status = "fail"; detail = "[Auto-remediate] Login succeeded but token still invalid. Error: $($recheck.error)" }
                }
            } else {
                $checks += @{ name = "Azure CLI"; status = "fail"; detail = "[Auto-remediate] az login failed after both interactive and device-code attempts (last exit $loginExit). Original error: $initialErr. Contact your tenant admin if Conditional Access is blocking sign-in." }
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

    # Outlook COM (email transport)
    try {
        $olApp = New-Object -ComObject Outlook.Application
        $ns = $olApp.GetNamespace("MAPI")
        $acct = $ns.Accounts | Select-Object -First 1
        if ($acct) {
            $checks += @{ name = "Outlook COM (email)"; status = "pass"; detail = "Account: $($acct.SmtpAddress)" }

            # Send test email if requested (during setup)
            if ($SendTestEmail) {
                try {
                    . "$PSScriptRoot\Send-Email.ps1"
                    $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) "templates\setup-test-email.html"
                    $releaseOwnerName = az ad signed-in-user show --query displayName -o tsv 2>$null
                    if (-not $releaseOwnerName) { $releaseOwnerName = $acct.SmtpAddress -replace '@.*', '' }
                    $result = Send-Email -To $SendTestEmail -Subject "[Setup] ZED Agent — Email Test" `
                        -BodyHtmlPath $templatePath -Variables @{ releaseOwnerName = $releaseOwnerName }
                    if ($result.success) {
                        $checks += @{ name = "Test email send"; status = "pass"; detail = "Test email sent to $SendTestEmail" }
                    } else {
                        $checks += @{ name = "Test email send"; status = "fail"; detail = "Send failed: $($result.error)" }
                    }
                } catch {
                    $checks += @{ name = "Test email send"; status = "fail"; detail = "Send error: $($_.Exception.Message)" }
                }
            }
        } else {
            $checks += @{ name = "Outlook COM (email)"; status = "fail"; detail = "Outlook COM available but no email account configured. Open Outlook and set up your account." }
        }
    } catch {
        $checks += @{ name = "Outlook COM (email)"; status = "fail"; detail = "Cannot create Outlook COM object. Ensure Outlook is installed and has been opened at least once." }
    }

    # ── 4b. Kusto connectivity ──
    $kustoCluster = $cfg.kusto.canary.cluster
    $kustoDb = $cfg.kusto.canary.database
    if ([string]::IsNullOrWhiteSpace($kustoCluster) -or [string]::IsNullOrWhiteSpace($kustoDb)) {
        $checks += @{ name = "Kusto connectivity"; status = "fail"; detail = "kusto.canary.cluster or kusto.canary.database not set in service-config.json. Populate both before running pre-flight." }
    } else {
        try {
            # Resource must match the actual cluster so the token's audience is correct;
            # a hardcoded generic resource yields tokens the cluster rejects with 401.
            $kustoTokenRaw = az account get-access-token --resource $kustoCluster --query accessToken -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and $kustoTokenRaw) {
                $kustoToken = ($kustoTokenRaw | Out-String).Trim()
                $kustoHeaders = @{ Authorization = "Bearer $kustoToken"; 'Content-Type' = 'application/json' }
                $testBody = @{ db = $kustoDb; csl = ".show database ['$kustoDb'] schema | take 1" } | ConvertTo-Json
                $kustoResp = Invoke-RestMethod -Uri "$kustoCluster/v1/rest/query" -Method Post -Headers $kustoHeaders -Body $testBody -TimeoutSec 15 -ErrorAction Stop
                $checks += @{ name = "Kusto connectivity"; status = "pass"; detail = "Connected to $kustoCluster / $kustoDb" }
            } else {
                $errMsg = ($kustoTokenRaw | Out-String).Trim()
                $checks += @{ name = "Kusto connectivity"; status = "fail"; detail = "Cannot get Kusto token for $kustoCluster. Run: az account clear; az login --tenant microsoft.com. Error: $errMsg" }
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

    # ── 5. Skill scripts ──
    $requiredScripts = @(
        "Update-ReleaseState.ps1", "Expand-Template.ps1", "Send-TeamsMessage.ps1",
        "Send-Email.ps1", "New-CommitExcel.ps1", "Upload-ToSharePoint.ps1",
        "Register-WatcherTask.ps1", "Release-Watcher.ps1", "Get-RegionMapping.ps1",
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
            $taskName = "$($cfg.operational.watcherTaskPrefix)-$ReleaseId"
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                $checks += @{ name = "Watcher task"; status = "pass"; detail = "Task '$taskName' registered" }
            } else {
                $checks += @{ name = "Watcher task"; status = "warn"; detail = "Task '$taskName' not registered — watcher will need manual start" }
            }
        } else {
            $checks += @{ name = "Release directory"; status = "fail"; detail = "Not found: $relDir. Run setup to initialize this release." }
        }
    }

    # ── Compute verdict ──
    $failCount = ($checks | Where-Object { $_.status -eq "fail" }).Count
    $warnCount = ($checks | Where-Object { $_.status -eq "warn" }).Count
    $passCount = ($checks | Where-Object { $_.status -eq "pass" }).Count

    $verdict = if ($failCount -gt 0) { "fail" } elseif ($warnCount -gt 0) { "warn" } else { "pass" }

    return @{
        checks  = $checks
        summary = @{ pass = $passCount; warn = $warnCount; fail = $failCount }
        verdict = $verdict
    }
}
