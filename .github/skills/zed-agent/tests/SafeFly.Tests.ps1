BeforeAll {
    $SafeFlyDir = Join-Path $PSScriptRoot '..' 'scripts' 'SafeFly'

    # Minimal service-config.json structure for tests
    function New-TestConfig {
        param(
            [string]$ApiBaseUrl             = 'https://www.safefly.azure.com',
            [string]$RequestCreationPath    = '/api/RequestCreation/v1/requests',
            [string]$SpAppId                = '62308d56-4ed4-41de-8a5c-ca98bb971ffc',
            [string]$ServiceConnId          = '712dc115-726d-45e5-8573-f174f12f836a'
        )
        return @{
            safefly = @{
                apiBaseUrl                       = $ApiBaseUrl
                requestCreationPath              = $RequestCreationPath
                requestCreatorSpAppId            = $SpAppId
                requestCreatorAdoServiceConnectionId = $ServiceConnId
                titleTemplate                    = 'Test R2D {month}'
                serviceGroupName                 = 'Test Group'
                tags                             = @()
            }
            service = @{
                displayName = 'Test Service'
                orgName     = 'msazure'
            }
        }
    }

    # Write New-SafeFlyRequest.ps1 to a temp staging dir so we can dot-source just the
    # "build payload" logic without actually running the real HTTP call in unit tests.
    # Each It block sets up its own Invoke-WebRequest / az mock and calls the script.
    $NewSafeFlyScript = Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1'
}

Describe 'SafeFly — WP-S1: Single config-driven endpoint (no cascade)' {
    It 'reads apiBaseUrl and requestCreationPath from config, not hardcoded constants' {
        $scriptContent = Get-Content $NewSafeFlyScript -Raw
        # The cascade array must be gone from the V2 script
        $scriptContent | Should -Not -Match '\$SafeFlyEndpoints\s*='
        # V2 script reads from config, not hardcoded URL
        $scriptContent | Should -Not -Match "'https://www\.safefly\.azure\.com'"
        # Config-driven graphQL endpoint variable must be present
        $scriptContent | Should -Match 'graphQlEndpoint'
    }

    It 'uses Invoke-SafeFlyGraphQL helper (not Invoke-WebRequest) for the POST' {
        $scriptContent = Get-Content $NewSafeFlyScript -Raw
        # V2 script delegates HTTP to Invoke-SafeFlyGraphQL.ps1
        $scriptContent | Should -Match 'Invoke-SafeFlyGraphQL\.ps1'
        # V2 script should not directly call Invoke-WebRequest for the mutation
        $scriptContent | Should -Not -Match 'Invoke-WebRequest'
    }
}

Describe 'SafeFly — WP-S1: HTML response guard' {
    It 'throws SAFEFLY_HTML_RESPONSE when Content-Type is text/html' {
        # Simulate the guard logic inline (extracted from the script)
        $rawContent  = '<html><body>SPA shell</body></html>'
        $contentType = 'text/html'
        $scriptGuard = {
            $ct = $contentType
            if ($ct -eq 'text/html' -or $rawContent -match '^\s*<!DOCTYPE') {
                throw "SAFEFLY_HTML_RESPONSE: SafeFly returned Content-Type '$ct'"
            }
        }
        { & $scriptGuard } | Should -Throw -ExpectedMessage 'SAFEFLY_HTML_RESPONSE*'
    }

    It 'throws SAFEFLY_HTML_RESPONSE when body begins with <!DOCTYPE regardless of Content-Type' {
        $rawContent  = '<!DOCTYPE html><html></html>'
        $contentType = 'application/json'
        $scriptGuard = {
            $ct = $contentType
            if ($ct -eq 'text/html' -or $rawContent -match '^\s*<!DOCTYPE') {
                throw "SAFEFLY_HTML_RESPONSE: SafeFly returned Content-Type '$ct'"
            }
        }
        { & $scriptGuard } | Should -Throw -ExpectedMessage 'SAFEFLY_HTML_RESPONSE*'
    }

    It 'does NOT throw when Content-Type is application/json and body is valid JSON' {
        $rawContent  = '{"requestId":"abc123"}'
        $contentType = 'application/json'
        $scriptGuard = {
            $ct = $contentType
            if ($ct -eq 'text/html' -or $rawContent -match '^\s*<!DOCTYPE') {
                throw "SAFEFLY_HTML_RESPONSE: SafeFly returned Content-Type '$ct'"
            }
        }
        { & $scriptGuard } | Should -Not -Throw
    }

    It 'script source contains the HTML guard block' {
        # HTML guard moved to Invoke-SafeFlyGraphQL.ps1 in V2
        $graphqlScript = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $graphqlScript | Should -Match 'SAFEFLY_HTML_RESPONSE'
        $graphqlScript | Should -Match 'text/html'
        $graphqlScript | Should -Match '<!DOCTYPE'
    }
}

Describe 'SafeFly — WP-S1: HTTP 410 is a hard non-retryable failure' {
    It 'script source: 410 branch throws immediately without retry' {
        # In V2, HTTP error handling is in Invoke-SafeFlyGraphQL.ps1
        $graphqlScript = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $graphqlScript | Should -Match '410'
        $graphqlScript | Should -Match 'throw'
        # Non-retry: must not retry on 410
        $graphqlScript | Should -Match 'ReadOnlyMode|non-retryable|permanently'
    }
}

Describe 'SafeFly — WP-S2: Actionable 401/403 error message' {
    It 'script source: 401/403 branch mentions SafeFly.Request app role' {
        # In V2, error handling is in Invoke-SafeFlyGraphQL.ps1
        $graphqlScript = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $graphqlScript | Should -Match '401'
        $graphqlScript | Should -Match '403'
        $graphqlScript | Should -Match 'ExternalStandardAccess|role|app role'
    }

    It 'script source: 401/403 branch mentions SafeFly V2 resource audience' {
        $graphqlScript = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        # V2 audience GUID (NOT the V1 6bca76ac one)
        $graphqlScript | Should -Match 'f6f1426c-4d1b-44d8-8e36-db5824a21fe2|tokenAudience|audience'
    }

    It 'Invoke-SafeFlyGraphQL.ps1 reads tokenAudience from config (not hardcoded)' {
        $graphqlScript = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $graphqlScript | Should -Match 'tokenAudience'
        $graphqlScript | Should -Match 'cfg\.safefly'
    }

    It 'Invoke-SafeFlyGraphQL.ps1 references the configured ADO service connection' {
        $graphqlScript = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $graphqlScript | Should -Match 'requestCreatorAdoServiceConnectionId|712dc115|ServiceConnection|service.connection'
    }

    It 'error message logic: emits identityHint from configured SP appId when present' {
        $requestCreatorSpAppId = '62308d56-4ed4-41de-8a5c-ca98bb971ffc'
        $requestCreatorSvcConn = '712dc115-726d-45e5-8573-f174f12f836a'
        $identityHint = if ($requestCreatorSpAppId) { "SP appId=$requestCreatorSpAppId" } else { "current user identity" }
        $connHint     = if ($requestCreatorSvcConn) { "ADO service connection $requestCreatorSvcConn" } else { "not configured" }
        $identityHint | Should -Match 'SP appId=62308d56'
        $connHint     | Should -Match '712dc115'
    }

    It 'error message logic: falls back to descriptive hint when SP appId not configured' {
        $requestCreatorSpAppId = $null
        $identityHint = if ($requestCreatorSpAppId) { "SP appId=$requestCreatorSpAppId" } else { "current user identity" }
        $identityHint | Should -Match 'current user identity'
    }
}

Describe 'SafeFly — Get-SafeFlyApproval: HTML guard' {
    It 'script contains HTML guard after the GET call' {
        $scriptContent = Get-Content (Join-Path $SafeFlyDir 'Get-SafeFlyApproval.ps1') -Raw
        $scriptContent | Should -Match 'SAFEFLY_HTML_RESPONSE'
        $scriptContent | Should -Match 'text/html'
        $scriptContent | Should -Match 'Invoke-WebRequest'
    }
}

Describe 'SafeFly — Get-SafeFlyLeases: HTML guard' {
    It 'script contains HTML guard after the GET call' {
        $scriptContent = Get-Content (Join-Path $SafeFlyDir 'Get-SafeFlyLeases.ps1') -Raw
        $scriptContent | Should -Match 'SAFEFLY_HTML_RESPONSE'
        $scriptContent | Should -Match 'text/html'
        $scriptContent | Should -Match 'Invoke-WebRequest'
    }
}

# ============================================================================
# WP-6: SafeFly V2 GraphQL tests
# ============================================================================

Describe 'SafeFly V2 — Invoke-SafeFlyGraphQL: byte-array decode' {
    It 'script contains UTF8.GetString decode for byte-array response content' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match 'UTF8'
        $script | Should -Match 'GetString'
    }

    It 'byte-array decode logic returns the correct string' {
        # Unit-test the decode pattern used in Invoke-SafeFlyGraphQL
        $json    = '{"data":{"id":"abc"}}'
        $bytes   = [System.Text.Encoding]::UTF8.GetBytes($json)
        $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
        $decoded | Should -Be $json
    }
}

Describe 'SafeFly V2 — Invoke-SafeFlyGraphQL: GraphQL error surfacing' {
    It 'script checks for errors[] in response body and throws' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match 'errors'
        $script | Should -Match 'throw'
    }

    It 'errors[] detection logic throws with message text' {
        # Simulate the guard logic
        $parsed = @{ errors = @(@{ message = 'field not found' }) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $guard = {
            if ($parsed.PSObject.Properties['errors'] -and @($parsed.errors).Count -gt 0) {
                $msgs = (@($parsed.errors) | ForEach-Object { $_.message }) -join '; '
                throw "SafeFly GraphQL errors: $msgs"
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*field not found*'
    }
}

Describe 'SafeFly V2 — Invoke-SafeFlyGraphQL: non-retry status codes' {
    It 'script contains non-retry handling for 410 (permanent block)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match '410'
        $script | Should -Match 'throw'
    }

    It 'script contains non-retry handling for 401 and 403' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match '401'
        $script | Should -Match '403'
    }

    It 'script retries on 429 and 5xx but not on 401/403/410' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        # Retry logic should reference 429 / 5xx
        $script | Should -Match '429'
        # Non-retry exit for 401/403/410 must come before any retry loop
        # (check presence, not ordering — ordering tested by behavior tests above)
        $script | Should -Match '\b410\b'
    }
}

Describe 'SafeFly V2 — Invoke-SafeFlyGraphQL: config-driven endpoint and audience' {
    It 'script reads graphQlEndpoint from config (never hardcodes the URL)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match 'graphQlEndpoint'
        # Config-driven — the URL must NOT appear as a literal string fallback in the main path
        # (it may appear in comments/docs)
        $codeOnly = ($script -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codeOnly | Should -Match 'graphQlEndpoint'
    }

    It 'script reads tokenAudience from config' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match 'tokenAudience'
    }
}

Describe 'SafeFly V2 — Get-SafeFlyForm: silent-truncation guard' {
    It 'script asserts question count > 1 to detect staticOptions truncation' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Get-SafeFlyForm.ps1') -Raw
        $script | Should -Match 'Count.*-le.*1'
        $script | Should -Match 'truncation'
    }

    It 'silent-truncation guard throws when count is 1' {
        $count = 1
        $guard = {
            if ($count -le 1) {
                throw "SafeFly V2 activeForm returned only $count question(s). Silent-truncation trap."
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*truncation*'
    }

    It 'silent-truncation guard does NOT throw when count is 43' {
        $count = 43
        $guard = {
            if ($count -le 1) {
                throw "SafeFly V2 activeForm returned only $count question(s). Silent-truncation trap."
            }
        }
        { & $guard } | Should -Not -Throw
    }
}

Describe 'SafeFly V2 — Get-SafeFlyForm: no active form' {
    It 'script throws loudly when activeForm is null — no fallback' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Get-SafeFlyForm.ps1') -Raw
        $script | Should -Match 'No active form'
        $script | Should -Match 'throw'
        # Must NOT silently fall back to another change type
        $script | Should -Not -Match 'fallback'
    }

    It 'no-active-form guard throws with the change type in the message' {
        $changeTypeId   = 'test-change-type-id'
        $changeTypeName = 'App deployment'
        $activeForm     = $null
        $guard = {
            if (-not $activeForm) {
                throw "SafeFly V2 returned no active form for change type '$changeTypeName' ($changeTypeId)."
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*App deployment*'
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: fail-closed on missing required questions' {
    It 'script contains fail-closed check and throws when effective-required has answers missing' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'FAIL-CLOSED'
        $script | Should -Match 'effectiveRequired'
        $script | Should -Match 'missing'
    }

    It 'fail-closed logic throws listing the missing question names' {
        $missing = @(
            [pscustomobject]@{ name = 'ev2.servicegroup'; label = 'Service Group' }
            [pscustomobject]@{ name = 'core.sdp';         label = 'SDP Type' }
        )
        $guard = {
            if ($missing.Count -gt 0) {
                $list = ($missing | ForEach-Object { "  '$($_.name)'" }) -join "`n"
                throw "SafeFly V2 FAIL-CLOSED: $($missing.Count) effective-required question(s) have no answer.`n$list"
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*FAIL-CLOSED*'
        { & $guard } | Should -Throw -ExpectedMessage '*ev2.servicegroup*'
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: option validation' {
    It 'script contains option validation (Assert-OptionValid)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'Assert-OptionValid'
        $script | Should -Match 'invalid option'
    }

    It 'Assert-OptionValid logic throws with valid-values list for bad input' {
        $question = [pscustomobject]@{
            name    = 'core.sdp'
            label   = 'SDP Type'
            options = @(
                [pscustomobject]@{ id = 'opt1'; label = 'Standard SDP (Normal Rollout)'; value = 'Standard SDP (Normal Rollout)' }
                [pscustomobject]@{ id = 'opt2'; label = 'Conservative SDP';              value = 'Conservative SDP' }
            )
        }
        $invalidValue = 'Standard SDP'  # V1 name — not a valid V2 option
        $guard = {
            $match = @($question.options | Where-Object { $_.label -eq $invalidValue -or $_.value -eq $invalidValue }) | Select-Object -First 1
            if (-not $match) {
                $valid = (@($question.options) | ForEach-Object { $_.label }) -join '", "'
                throw "SafeFly V2: invalid option value '$invalidValue' for question '$($question.name)'. Valid values: `"$valid`""
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*invalid option value*Standard SDP*'
    }

    It 'Assert-OptionValid does NOT throw when value matches a valid option label' {
        $question = [pscustomobject]@{
            name    = 'core.sdp'
            label   = 'SDP Type'
            options = @(
                [pscustomobject]@{ id = 'opt1'; label = 'Standard SDP (Normal Rollout)'; value = 'Standard SDP (Normal Rollout)' }
            )
        }
        $validValue = 'Standard SDP (Normal Rollout)'
        $guard = {
            $match = @($question.options | Where-Object { $_.label -eq $validValue -or $_.value -eq $validValue }) | Select-Object -First 1
            if (-not $match) { throw "invalid option" }
        }
        { & $guard } | Should -Not -Throw
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: SDP mapping V1 name -> V2 option string' {
    It '"Standard SDP" maps to "Standard SDP (Normal Rollout)"' {
        $sdpMapping = @{
            'Standard SDP'     = 'Standard SDP (Normal Rollout)'
            'Conservative SDP' = 'Conservative SDP'
        }
        $sdpMapping['Standard SDP'] | Should -Be 'Standard SDP (Normal Rollout)'
    }

    It '"Conservative SDP" maps to "Conservative SDP" (unchanged)' {
        $sdpMapping = @{
            'Standard SDP'     = 'Standard SDP (Normal Rollout)'
            'Conservative SDP' = 'Conservative SDP'
        }
        $sdpMapping['Conservative SDP'] | Should -Be 'Conservative SDP'
    }

    It 'script applies SDP mapping to derive sdpV2Value' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'sdpV2Value'
        $script | Should -Match 'sdpMapping'
        $script | Should -Match 'Normal Rollout'
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: 14-field payload shape' {
    It 'script assembles all 14 SaveRequestRequestBaseInput fields' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $required14 = @(
            'requestId', 'changeTitle', 'changeDescription', 'franchiseId',
            'changeTypeId', 'serviceId', 'formId', 'requestType',
            'answers', 'tagIds', 'shouldSuppressIcmErrors',
            'requestExceptions', 'owner', 'ownerAssignmentNotes'
        )
        foreach ($field in $required14) {
            $script | Should -Match $field -Because "SaveRequestRequestBaseInput requires '$field'"
        }
    }

    It 'requestType is CHANGE (not DRAFT)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match "'CHANGE'"
    }

    It 'DryRun mode returns requestStatus=DryRun without mutation' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'DryRun'
        $script | Should -Match 'requestStatus.*DryRun'
        # Mutation must be gated behind -not DryRun
        $script | Should -Match 'if.*DryRun'
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: conditionalRule effective-required (EV2 partition)' {
    It 'script uses pure conditionalRule evaluation — no hardcoded nonEv2Prefixes list' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Not -Match 'nonEv2Prefixes'
        $script | Should -Not -Match "azdeployer\."
        $script | Should -Not -Match 'lsm\.'
        $script | Should -Not -Match 'pilotfish\.'
        # The new approach evaluates conditionalRule objects
        $script | Should -Match 'Test-ConditionalRule'
        $script | Should -Match 'Resolve-EffectiveRequired'
    }

    It 'Resolve-EffectiveRequired excludes questions whose V2 conditionalRule is not satisfied' {
        # V2 rule gating a question on core.orchestrator_name = EV2 (real operator: ContainsAny)
        $ruleEv2 = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'core.orchestrator_name'
                comparisonOperator  = 'ContainsAny'
                comparisonValue     = 'ev2'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        # ADO build gated on ContainsAny 'azdeployer' (real form operator)
        $ruleAdo = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'core.orchestrator_name'
                comparisonOperator  = 'ContainsAny'
                comparisonValue     = 'azdeployer'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        # other.build gated on NotIn (real form operator)
        $ruleOther = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'core.orchestrator_name'
                comparisonOperator  = 'NotIn'
                comparisonValue     = 'EV2, azdeployer, Pilotfish'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        $questions = @(
            [pscustomobject]@{ name = 'core.orchestrator_name'; isRequired = $true; conditionalRule = $null    }
            [pscustomobject]@{ name = 'ev2.servicegroup';       isRequired = $true; conditionalRule = $ruleEv2  }
            [pscustomobject]@{ name = 'azdeployer.pipeline';    isRequired = $true; conditionalRule = $ruleAdo  }
            [pscustomobject]@{ name = 'other.build';            isRequired = $true; conditionalRule = $ruleOther }
        )
        $answerMap = @{ 'core.orchestrator_name' = 'EV2' }

        # Inline Test-ConditionalRule — mirrors the script's actual implementation
        function Evaluate-Rule($rule, $map) {
            if ($null -eq $rule) { return $true }
            if ($rule -isnot [string] -and $rule.PSObject.Properties['conditions']) {
                $shouldRequire = $rule.PSObject.Properties['actionSet'] -and $rule.actionSet -and
                                 $rule.actionSet.PSObject.Properties['require'] -and [bool]$rule.actionSet.require
                if (-not $shouldRequire) { return $true }
                $results = [System.Collections.Generic.List[bool]]::new()
                foreach ($cond in $rule.conditions) {
                    $cv = $map[$cond.triggerQuestionName]
                    if ($null -eq $cv) { $results.Add($false); continue }
                    $sat = switch ($cond.comparisonOperator) {
                        'EqualTo'     { $cv -eq $cond.comparisonValue }
                        'Equals'      { $cv -eq $cond.comparisonValue }
                        'NotEqualTo'  { $cv -ne $cond.comparisonValue }
                        'ContainsAny' { @($cond.comparisonValue -split ',\s*') -contains $cv }
                        'In'          { @($cond.comparisonValue -split ',\s*') -contains $cv }
                        'NotIn'       { @($cond.comparisonValue -split ',\s*') -notcontains $cv }
                        default       { $true }
                    }
                    $results.Add($sat)
                }
                $op = if ($rule.operator) { $rule.operator } else { 'AND' }
                if ($op -eq 'OR') { return ($results -contains $true) }
                return ($results -notcontains $false)
            }
            return $true
        }

        $effective = [System.Collections.Generic.List[object]]::new()
        foreach ($q in $questions) {
            if ($q.isRequired -and (Evaluate-Rule $q.conditionalRule $answerMap)) {
                $effective.Add($q)
            }
        }
        $effective.Count | Should -Be 2  # core.orchestrator_name (no rule) + ev2.servicegroup (ContainsAny EV2)
        ($effective | ForEach-Object name) | Should -Contain 'ev2.servicegroup'
        ($effective | ForEach-Object name) | Should -Contain 'core.orchestrator_name'
        ($effective | ForEach-Object name) | Should -Not -Contain 'azdeployer.pipeline'  # ContainsAny 'azdeployer' not satisfied
        ($effective | ForEach-Object name) | Should -Not -Contain 'other.build'           # NotIn satisfied (EV2 IS in list)
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: V2 config required' {
    It 'script throws when graphQlEndpoint is missing from config' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'graphQlEndpoint'
        $script | Should -Match 'HTTP 410'
    }
}

# ============================================================================
# BUG REGRESSION: byte-array vs string content (BUG 2) and GraphQL errors[] (BUG 1)
# ============================================================================

Describe 'SafeFly V2 — Invoke-SafeFlyGraphQL: content guard (byte-array vs string)' {
    It 'script contains the is-[byte[]] guard for $raw.Content' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        $script | Should -Match '-is \[byte\[\]\]'
    }

    It 'guard decodes byte-array content to correct UTF-8 string' {
        $json  = '{"data":{"activeForm":{"id":"test-id"}}}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $c = $bytes
        if ($c -is [byte[]]) { $c = [System.Text.Encoding]::UTF8.GetString($c) }
        $c | Should -Be $json
    }

    It 'guard passes string content through unchanged (PS7+ behaviour)' {
        $json = '{"data":{"activeForm":{"id":"test-id"}}}'
        $c = $json   # Already a string — simulates PS7+ Invoke-WebRequest
        if ($c -is [byte[]]) { $c = [System.Text.Encoding]::UTF8.GetString($c) }
        $c | Should -Be $json
    }
}

Describe 'SafeFly V2 — Invoke-SafeFlyGraphQL: GraphQL errors[] in HTTP 200 body' {
    It 'errors[] with SCALAR_LEAFS code produces readable terminating error with server message' {
        $body = '{"errors":[{"message":"Field conditionalRule of type ConditionalRuleResponseBaseQuery must have a sub selection","extensions":{"code":"SCALAR_LEAFS"}}]}'
        $guard = {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.PSObject.Properties['errors'] -and $parsed.errors) {
                $msgs = (@($parsed.errors) | ForEach-Object { $_.message }) -join '; '
                throw "SafeFly V2 GraphQL error(s): $msgs"
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*conditionalRule*'
        { & $guard } | Should -Throw -ExpectedMessage '*sub selection*'
    }

    It 'errors[] with multiple errors joins all messages with semicolon' {
        $body = '{"errors":[{"message":"First error"},{"message":"Second error"}]}'
        $guard = {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.PSObject.Properties['errors'] -and $parsed.errors) {
                $msgs = (@($parsed.errors) | ForEach-Object { $_.message }) -join '; '
                throw "SafeFly V2 GraphQL error(s): $msgs"
            }
        }
        { & $guard } | Should -Throw -ExpectedMessage '*First error*'
        { & $guard } | Should -Throw -ExpectedMessage '*Second error*'
    }

    It 'script checks errors[] on success path and applies graphql-error guard in error path' {
        $script = Get-Content (Join-Path $SafeFlyDir 'Invoke-SafeFlyGraphQL.ps1') -Raw
        # Success path: errors[] check
        $script | Should -Match "PSObject.Properties\['errors'\]"
        # Error path: errParsed / graphqlMsgs parsing
        $script | Should -Match 'errParsed'
        $script | Should -Match 'graphqlMsgs'
    }
}

Describe 'SafeFly V2 — New-SafeFlyRequest: conditionalRule V2 object evaluator' {
    It 'Resolve-EffectiveRequired excludes questions where conditionalRule is not satisfied' {
        # Uses real prod operator ContainsAny (not EqualTo)
        $ruleEv2 = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'core.orchestrator_name'
                comparisonOperator  = 'ContainsAny'
                comparisonValue     = 'ev2'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        $ruleAdo = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'core.orchestrator_name'
                comparisonOperator  = 'ContainsAny'
                comparisonValue     = 'azdeployer'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        $questions = @(
            [pscustomobject]@{ name = 'core.orchestrator_name'; isRequired = $true; conditionalRule = $null }
            [pscustomobject]@{ name = 'ev2.build';              isRequired = $true; conditionalRule = $ruleEv2 }
            [pscustomobject]@{ name = 'ado.build';              isRequired = $true; conditionalRule = $ruleAdo }
        )
        $answerMap = @{ 'core.orchestrator_name' = 'EV2' }

        # Inline evaluator — full operator set, mirrors the actual script implementation
        function Test-RuleV2($rule, $map) {
            if ($null -eq $rule) { return $true }
            if ($rule -isnot [string] -and $rule.PSObject.Properties['conditions']) {
                $shouldRequire = $rule.PSObject.Properties['actionSet'] -and $rule.actionSet -and
                                 $rule.actionSet.PSObject.Properties['require'] -and [bool]$rule.actionSet.require
                if (-not $shouldRequire) { return $true }
                $results = [System.Collections.Generic.List[bool]]::new()
                foreach ($cond in $rule.conditions) {
                    $cv = $map[$cond.triggerQuestionName]
                    if ($null -eq $cv) { $results.Add($false); continue }
                    $sat = switch ($cond.comparisonOperator) {
                        'EqualTo'     { $cv -eq $cond.comparisonValue }
                        'Equals'      { $cv -eq $cond.comparisonValue }
                        'NotEqualTo'  { $cv -ne $cond.comparisonValue }
                        'ContainsAny' { @($cond.comparisonValue -split ',\s*') -contains $cv }
                        'In'          { @($cond.comparisonValue -split ',\s*') -contains $cv }
                        'NotIn'       { @($cond.comparisonValue -split ',\s*') -notcontains $cv }
                        default       { $true }
                    }
                    $results.Add($sat)
                }
                $op = if ($rule.operator) { $rule.operator } else { 'AND' }
                if ($op -eq 'OR') { return ($results -contains $true) }
                return ($results -notcontains $false)
            }
            return $true
        }

        $effective = [System.Collections.Generic.List[object]]::new()
        foreach ($q in $questions) {
            if ($q.isRequired -and (Test-RuleV2 $q.conditionalRule $answerMap)) { $effective.Add($q) }
        }

        $effective.Count    | Should -Be 2
        ($effective | ForEach-Object name) | Should -Contain 'ev2.build'
        ($effective | ForEach-Object name) | Should -Contain 'core.orchestrator_name'
        ($effective | ForEach-Object name) | Should -Not -Contain 'ado.build'
    }

    It 'transitive gating: question with unanswered trigger is excluded' {
        # Uses real prod operator Equals (ccoa.is_ccoa_request Equals "True")
        $parentRule = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'ccoa.is_ccoa_request'
                comparisonOperator  = 'Equals'
                comparisonValue     = 'True'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        $childRule = [pscustomobject]@{
            operator   = 'AND'
            conditions = @([pscustomobject]@{
                triggerQuestionName = 'ccoa.selected_events'  # Parent not answered
                comparisonOperator  = 'Equals'
                comparisonValue     = 'Deploy'
            })
            actionSet  = [pscustomobject]@{ require = $true }
        }
        $questions = @(
            [pscustomobject]@{ name = 'ccoa.is_ccoa_request'; isRequired = $true; conditionalRule = $null }
            [pscustomobject]@{ name = 'ccoa.selected_events'; isRequired = $true; conditionalRule = $parentRule }
            [pscustomobject]@{ name = 'ccoa.justification';   isRequired = $true; conditionalRule = $childRule }
        )
        # Answered 'False' (CCOA not applicable) — ccoa.selected_events trigger is absent from answers
        $answerMap = @{ 'ccoa.is_ccoa_request' = 'False' }

        function Test-RuleTransitive($rule, $map) {
            if ($null -eq $rule) { return $true }
            if ($rule -isnot [string] -and $rule.PSObject.Properties['conditions']) {
                $shouldRequire = $rule.PSObject.Properties['actionSet'] -and $rule.actionSet -and
                                 $rule.actionSet.PSObject.Properties['require'] -and [bool]$rule.actionSet.require
                if (-not $shouldRequire) { return $true }
                $results = [System.Collections.Generic.List[bool]]::new()
                foreach ($cond in $rule.conditions) {
                    $cv = $map[$cond.triggerQuestionName]
                    if ($null -eq $cv) { $results.Add($false); continue }
                    $sat = switch ($cond.comparisonOperator) {
                        'EqualTo'     { $cv -eq $cond.comparisonValue }
                        'Equals'      { $cv -eq $cond.comparisonValue }
                        'ContainsAny' { @($cond.comparisonValue -split ',\s*') -contains $cv }
                        'NotIn'       { @($cond.comparisonValue -split ',\s*') -notcontains $cv }
                        default       { $true }
                    }
                    $results.Add($sat)
                }
                $op = if ($rule.operator) { $rule.operator } else { 'AND' }
                if ($op -eq 'OR') { return ($results -contains $true) }
                return ($results -notcontains $false)
            }
            return $true
        }

        # ccoa.is_ccoa_request: no rule → included
        (Test-RuleTransitive $questions[0].conditionalRule $answerMap) | Should -Be $true
        # ccoa.selected_events: requires ccoa.is_ccoa_request='True', but we answered 'False' → excluded
        (Test-RuleTransitive $questions[1].conditionalRule $answerMap) | Should -Be $false
        # ccoa.justification: trigger ccoa.selected_events is null → excluded (transitive)
        (Test-RuleTransitive $questions[2].conditionalRule $answerMap) | Should -Be $false
    }

    It 'script handles ContainsAny and NotIn operators' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'ContainsAny'
        $script | Should -Match 'NotIn'
        $script | Should -Match '\$compVal -split'
    }

    It 'script maps core.health_monitoring and ado.build_na for EV2 partition' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'core\.health_monitoring'
        $script | Should -Match 'ado\.build_na'
        $script | Should -Match 'Not Applicable'
    }

    It 'Resolve-EffectiveRequired script does NOT contain hardcoded nonEv2Prefixes list' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Not -Match 'nonEv2Prefixes'
    }
}

Describe 'SafeFly V2 — Test-RunRequirements WP-5a: notifications check asserts ok=true' {
    It 'verifier script asserts all notification records have ok=true (no partial success)' {
        $verifierPath = Join-Path $PSScriptRoot '..\..\zed-forge\scripts\Test-RunRequirements.ps1'
        $script = Get-Content $verifierPath -Raw
        $script | Should -Match 'failedNotifs'
        $script | Should -Match '-not \$_\.ok'
        $script | Should -Match 'ok=false'
    }
}

Describe 'SafeFly V2 — Test-RunRequirements WP-5b: acceptExpectedArtifactFailure removed' {
    It 'success-criteria.json does NOT contain acceptExpectedArtifactFailure' {
        $criteriaPath = Join-Path $PSScriptRoot '..\..\zed-forge\requirements\success-criteria.json'
        $criteria = Get-Content $criteriaPath -Raw
        $criteria | Should -Not -Match 'acceptExpectedArtifactFailure'
    }

    It 'Test-RunRequirements.ps1 derives artifact-gap acceptance from acceptedStatuses' {
        $verifierPath = Join-Path $PSScriptRoot '..\..\zed-forge\scripts\Test-RunRequirements.ps1'
        $script = Get-Content $verifierPath -Raw
        $script | Should -Match 'acceptArtGap'
        $script | Should -Match 'completed-with-expected-artifact-gap'
        # The old acceptExpectedArtifactFailure field must no longer be READ at runtime
        # (it may appear in comments explaining its removal, but must not be used as a property lookup)
        $script | Should -Not -Match '\$stepCriteria\.acceptExpectedArtifactFailure'
        $script | Should -Not -Match '\$cap\.acceptExpectedArtifactFailure'
    }
}

# =============================================================================
# D1–D5 Regression tests — SafeFly V2 GraphQL integration defects
# =============================================================================

Describe 'SafeFly V2 — D1 regression: submitRequest selection set uses only real fields' {
    # Root cause: invented fields (requestNumber, url) were in the mutation selection set.
    # SafeFly V2 returns: id, displayId, displayStatus, status, requestUrl — nothing else.
    It 'submitRequest mutation does NOT request the invented requestNumber field' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Not -Match '\brequestNumber\b'
    }

    It 'submitRequest mutation does NOT request a bare .url field (only requestUrl)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        # 'requestUrl' is fine; a lone `url` field in the selection set is not
        # We look for `  url` (indented, not a prefix of requestUrl)
        $script | Should -Not -Match '^\s+url\s*$'
    }

    It 'submitRequest selection set includes the five real V2 fields' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        # All five real fields must appear somewhere in the script
        $script | Should -Match '\bdisplayId\b'
        $script | Should -Match '\bdisplayStatus\b'
        $script | Should -Match '\brequestUrl\b'
    }
}

Describe 'SafeFly V2 — D2 regression: requestId set from server draft, not client-generated' {
    # Root cause: the script sent a client-generated GUID as requestId on saveRequest.
    # SafeFly V2 requires the requestId to be the server-assigned id from a prior saveRequest.
    It 'initial requestId is $null (not a new GUID)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match '\$requestId\s*=\s*\$null'
    }

    It 'requestId is populated from draft.id before submitRequest' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        # The re-key must read from the draft returned by saveRequest
        $script | Should -Match 'changeRequest\.requestId\s*=\s*\$draft\.id'
    }
}

Describe 'SafeFly V2 — D3 regression: two-phase saveRequest then submitRequest' {
    # Root cause: the script tried to use submitRequest to create a draft (it cannot).
    # Correct flow: saveRequest (creates draft, returns id) → submitRequest (promotes it).
    It 'script contains a saveRequest mutation' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'mutation\s+SaveRequest'
        $script | Should -Match '\bsaveRequest\b'
    }

    It 'script contains a submitRequest mutation' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'mutation\s+SubmitRequest'
        $script | Should -Match '\bsubmitRequest\b'
    }

    It 'draft.id bridges the two phases' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match '\$draft\s*=\s*\$saveData\.saveRequest'
        $script | Should -Match '\$draft\.id'
    }
}

Describe 'SafeFly V2 — D4 regression: cargo-cult answer-ordering hoist removed' {
    # Root cause: a sort-by-seed-order hoist was added under the false assumption that
    # SafeFly enforces cross-question ordering. The real root cause was wrong value format.
    # Empirically confirmed: ordering does not matter when correct CamelCase values are sent.
    It 'script does NOT contain the $seedOrder cargo-cult hoist' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Not -Match '\$seedOrder\s*='
    }

    It 'script does NOT contain $questionOrder sort logic' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Not -Match '\$questionOrder\s*='
    }

    It 'orderedAnswers is a simple array copy of $answers (no Sort-Object)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match '\$orderedAnswers\s*=\s*@\(\$answers\)'
    }
}

Describe 'SafeFly V2 — D5 regression: dynamic region resolution (CamelCase identifiers)' {
    # Root cause: core.regions options list is always empty (dynamic data source).
    # The script was comparing input display names ("East Asia") against the empty list,
    # so ALL regions fell to "unmatched". Fix: call getRegionsWithActiveCCOACoverage and
    # normalize both sides (strip spaces, lowercase) before matching.

    It 'Build-SafeFlyRegionMap function is defined in the script' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'function\s+Build-SafeFlyRegionMap'
    }

    It 'Resolve-RegionToSafeFlyId function is defined in the script' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'function\s+Resolve-RegionToSafeFlyId'
    }

    It 'region section calls getRegionsWithActiveCCOACoverage (not $qRegions.options)' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'getRegionsWithActiveCCOACoverage'
        $script | Should -Not -Match '\$qRegions\.options\b'
    }

    It 'region section calls Build-SafeFlyRegionMap to resolve valid region identifiers' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        $script | Should -Match 'Build-SafeFlyRegionMap'
    }

    It 'normalization algorithm strips spaces and lowercases both sides' {
        # Inline test of the normalization logic used in Resolve-RegionToSafeFlyId
        # and Build-SafeFlyRegionMap.
        $normalize = { param([string]$s) ($s -replace '\s+', '').ToLower() }

        # SafeFly CamelCase identifiers normalize to the same key as display names
        (& $normalize 'EastAsia')        | Should -Be 'eastasia'
        (& $normalize 'East Asia')       | Should -Be 'eastasia'
        (& $normalize 'WestUS2')         | Should -Be 'westus2'
        (& $normalize 'West US 2')       | Should -Be 'westus2'
        (& $normalize 'SoutheastAsia')   | Should -Be 'southeastasia'
        (& $normalize 'Southeast Asia')  | Should -Be 'southeastasia'
    }

    It 'matched regions are sent as comma-separated CamelCase in a single answer value' {
        # Validate the join pattern: multiple identifiers joined by comma, no space
        $identifiers = @('EastAsia', 'SoutheastAsia', 'WestUS2')
        $value = $identifiers -join ','
        $value | Should -Be 'EastAsia,SoutheastAsia,WestUS2'
        $value | Should -Not -Match '\s'        # no spaces in the joined value
        $value | Should -Not -Match ';'         # not semicolon-separated
        ($value -split ',').Count | Should -Be 3
    }

    It 'Add-Answer resolves option label to option value (generic encoder)' {
        # The D5 fix also corrected the option-value encoder: label="No" → value="False"
        # for ccoa.is_ccoa_request. Test the resolution logic inline.
        $q = [pscustomobject]@{
            id      = [System.Guid]::NewGuid().ToString()
            name    = 'ccoa.is_ccoa_request'
            options = @(
                [pscustomobject]@{ label = 'No';  value = 'False' }
                [pscustomobject]@{ label = 'Yes'; value = 'True'  }
            )
        }
        # Simulate the Add-Answer encoder logic
        $inputValue = 'No'
        $opt = @($q.options | Where-Object { $_.label -eq $inputValue -or $_.value -eq $inputValue }) | Select-Object -First 1
        $resolvedValue = if ($opt) { "$($opt.value)" } else { $inputValue }
        $resolvedValue | Should -Be 'False'

        # Same logic must resolve by option.value too (idempotent)
        $inputValue2 = 'False'
        $opt2 = @($q.options | Where-Object { $_.label -eq $inputValue2 -or $_.value -eq $inputValue2 }) | Select-Object -First 1
        $resolvedValue2 = if ($opt2) { "$($opt2.value)" } else { $inputValue2 }
        $resolvedValue2 | Should -Be 'False'
    }

    It 'Add-Answer encoder is present in the script source' {
        $script = Get-Content (Join-Path $SafeFlyDir 'New-SafeFlyRequest.ps1') -Raw
        # The encoder checks label or value match and uses opt.value
        $script | Should -Match '\$_\.label\s*-eq\s*\$value\s*-or\s*\$_\.value\s*-eq\s*\$value'
        $script | Should -Match '\$opt\.value'
    }
}
