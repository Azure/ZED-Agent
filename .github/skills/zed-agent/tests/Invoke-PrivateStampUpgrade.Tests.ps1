<#
.SYNOPSIS
    Pester tests for Invoke-PrivateStampUpgrade.ps1 (private stamp upgrade side track: both legs
    deployed in parallel, then the classic BVT release with PrivateStampVaultId, then owner sign-off).
    ADO / VSRM REST calls are mocked. (The BVT release payload was also validated live as a draft
    release on definition 64863 and deleted.)
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-PrivateStampUpgrade.ps1'
    $script:Vault = '/subscriptions/5288acd1-ba79-4377-9205-9f220331a44a/resourceGroups/rg-1/providers/Microsoft.RecoveryServices/vaults/bvt-vault'

    function New-Env {
        param([string]$Step3 = 'completed', [bool]$TestMode = $false, [bool]$Enabled = $true, [bool]$Bvt = $true, [bool]$Pinned = $false, [bool]$Restore = $false, [string]$RestoreOverrides = $null)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $steps = 1..16 | ForEach-Object { [ordered]@{ number = $_; name = "s$_"; status = 'pending' } }
        $steps[0].status = 'completed'; $steps[1].status = 'completed'; $steps[2].status = $Step3
        [ordered]@{ releaseId = '2026-11'; steps = $steps; watcherDirective = $null; lastUpdated = $null } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'state.json') -Encoding UTF8
        [ordered]@{ releaseId = '2026-11'; currentBranch = 'releases/bcm-2611'; previousBranch = 'releases/bcm-2610'; testMode = $TestMode; buildId = 950; releaseOwner = @{ alias = 'o'; email = 'o@x.com' } } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'release.json') -Encoding UTF8
        $psu = [ordered]@{
            enabled = $Enabled
            id = 396863
            sourceBranch = '{currentBranch}'
            portSpan = 2
            templateParameters = [ordered]@{ rolloutType = 'normal'; DepToolsArtifactBranch = 'develop'; debug = 'False' }
            parameterNames = [ordered]@{ instance = 'PrivateInstance'; port = 'WebRolePort'; artifactBranch = 'ArtifactBranch'; serviceOverrides = 'ServiceOverrideSettings' }
            serviceOverrideSettingsTemplate = '@{"BCMAppConfig->WorkflowQueueName"="{queueName}";}'
        }
        if ($Pinned) { $psu.artifact = [ordered]@{ resourceAlias = 'svc_build'; type = 'CloudVaultArtifacts-v3'; connectionId = 'conn-1'; connectionName = 'CloudVault API - cdpxofficialbuilds'; sourceId = 'fb10185a'; feedBranchPrefix = 'Mgmt_RecoverySvcs_IaaSCoord_'; buildDefinitionId = 223537 } }
        if ($Restore) { $psu.restoreAfterSignOff = $true }
        if ($RestoreOverrides) { $psu.restoreServiceOverrideSettings = $RestoreOverrides }
        if ($Bvt) { $psu.bvtRelease = [ordered]@{ definitionId = 64863; environmentName = 'IaaSVM BVT Private Stamp'; vaultIdVariable = 'PrivateStampVaultId' } }
        [ordered]@{ privateStampUpgrade = $psu } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'pipeline-catalog.json') -Encoding UTF8
        return $dir
    }

    function Invoke-Psu {
        param([string]$Dir, [string]$Action, [hashtable]$Extra = @{})
        $splat = @{
            Action = $Action; ReleaseId = '2026-11'
            StateFile = (Join-Path $Dir 'state.json'); StateLock = (Join-Path $Dir 'state.json.lock')
            AuditFile = (Join-Path $Dir 'audit.jsonl'); ReleaseFile = (Join-Path $Dir 'release.json')
            PipelineCatalogPath = (Join-Path $Dir 'pipeline-catalog.json')
            Organization = 'msazure'; Project = 'One'; AccessToken = 'tok'
        }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $ScriptPath @splat
    }

    $script:GoodInputs = @{ Instance = 'a'; LastPort = 10060; CurrentPort = 10062; LastArtifactBranch = 'releases/bcm-2610'; QueueName = 'TeeQ-Upgrade.1'; VaultId = $script:Vault; By = 'owner' }

    function Get-Track([string]$Dir) { (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json).privateStampUpgrade }
    function Set-Step3([string]$Dir, [string]$Status) {
        $p = Join-Path $Dir 'state.json'
        $s = Get-Content $p -Raw | ConvertFrom-Json
        ($s.steps | Where-Object number -eq 3).status = $Status
        $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
    }

    # Mock helpers -----------------------------------------------------------
    function Mock-Queue([int[]]$Ids) {
        $global:PsuQueueIds = [System.Collections.Generic.Queue[int]]::new([int[]]$Ids)
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/396863/runs*' } -MockWith { [pscustomobject]@{ id = $global:PsuQueueIds.Dequeue() } }
    }
    function Mock-Pinning([hashtable]$Builds, [hashtable]$Feeds) {
        # $Builds: id -> @{ def; result; branch; number }   $Feeds: feed -> @(buildIds published)
        $global:PsuPinBuilds = $Builds; $global:PsuPinFeeds = $Feeds
        Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' -and $Uri -match '/build/builds/(\d+)\?' -and $global:PsuPinBuilds.ContainsKey([int]$Matches[1]) } -MockWith {
            $null = $Uri -match '/build/builds/(\d+)\?'; $id = [int]$Matches[1]; $b = $global:PsuPinBuilds[$id]
            [pscustomobject]@{ id = $id; buildNumber = $b.number; status = 'completed'; result = $b.result; sourceBranch = "refs/heads/$($b.branch)"; definition = [pscustomobject]@{ id = $b.def; name = "def$($b.def)" } }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*vsrm*/Release/artifacts/versions*' } -MockWith {
            $feed = (($Body | ConvertFrom-Json) | Select-Object -First 1).definitionReference.branch.id
            $ids = if ($global:PsuPinFeeds.ContainsKey($feed)) { @($global:PsuPinFeeds[$feed]) } else { @() }
            [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'svc_build'; errorMessage = $null; versions = @($ids | ForEach-Object { [pscustomobject]@{ id = "ver-$_"; name = "3_0_1_0_$_ ($feed)" } }) }) }
        }
    }
    function Mock-Builds([hashtable]$Results) {
        # $Results: runId -> 'inProgress' | result string
        $global:PsuBuildResults = $Results
        Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' -and $Uri -like '*/build/builds/*' } -MockWith {
            $id = [int](($Uri -split '/builds/')[1] -split '\?')[0]
            $r = $global:PsuBuildResults[$id]
            if ($r -eq 'inProgress') { [pscustomobject]@{ id = $id; status = 'inProgress'; result = $null } }
            else { [pscustomobject]@{ id = $id; status = 'completed'; result = $r; finishTime = '2026-11-05T10:00:00Z' } }
        }
    }
    function Mock-BvtCreate([int]$ReleaseIdValue = 17880001) {
        $global:PsuBvtId = $ReleaseIdValue
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*vsrm*/artifacts/versions*' } -MockWith {
            [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'Build'; defaultVersion = [pscustomobject]@{ id = 'b7c84da8'; name = '3.0.200.1759 (git_mgmt_recoverysvcs_test_develop)' }; errorMessage = $null }) }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*vsrm*/releases?*' } -MockWith {
            [pscustomobject]@{ id = $global:PsuBvtId; name = 'Release-852'; status = 'active'; _links = [pscustomobject]@{ web = [pscustomobject]@{ href = 'https://msazure.visualstudio.com/One/_release?releaseId=17880001' } } }
        }
    }
    function Mock-BvtStatus([string]$Publish, [string]$Bvt, [string]$ReleaseStatus = 'active') {
        $global:PsuBvtEnv = @{ p = $Publish; b = $Bvt; r = $ReleaseStatus }
        Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' -and $Uri -like '*vsrm*/releases/*' } -MockWith {
            [pscustomobject]@{ id = 17880001; status = $global:PsuBvtEnv.r; environments = @(
                [pscustomobject]@{ name = 'Publish VSO DROP'; rank = 1; status = $global:PsuBvtEnv.p }
                [pscustomobject]@{ name = 'IaaSVM BVT Private Stamp'; rank = 2; status = $global:PsuBvtEnv.b }) }
        }
    }
}

AfterAll { Remove-Variable -Name PsuQueueIds, PsuBuildResults, PsuBvtId, PsuBvtEnv, PsuPinBuilds, PsuPinFeeds -Scope Global -ErrorAction SilentlyContinue }

Describe 'Invoke-PrivateStampUpgrade' {

    Context 'Init (Step 5 kick-off)' {
        It 'creates the track once and asks the owner for inputs' {
            $d = New-Env
            $r = Invoke-Psu $d 'Init'
            $r.Status | Should -Be 'awaiting-input'
            $r.NotifyEvent | Should -Be 'private-stamp-input-needed'
            $r2 = Invoke-Psu $d 'Init'
            $r2.Status | Should -Be 'awaiting-input'
            $r2.NotifyEvent | Should -BeNullOrEmpty
        }

        It 'skips the track in test mode' {
            $d = New-Env -TestMode $true
            $r = Invoke-Psu $d 'Init'
            $r.Status | Should -Be 'skipped'
            (Get-Track $d).skipReason | Should -Be 'test-mode'
        }

        It 'reports disabled when the catalog block is off' {
            $d = New-Env -Enabled $false
            (Invoke-Psu $d 'Init').Status | Should -Be 'disabled'
            Get-Track $d | Should -BeNullOrEmpty
        }
    }

    Context 'SetInputs validation' {
        It 'rejects <case>' -ForEach @(
            @{ case = 'overlapping ports (port + HTTP port)'; patch = @{ CurrentPort = 10061 }; msg = '*overlap*' }
            @{ case = 'a queue name with quotes';               patch = @{ QueueName = 'q";x' };   msg = '*TeeWorkflowQueueName*' }
            @{ case = 'the current release branch as last build'; patch = @{ LastArtifactBranch = 'releases/bcm-2611' }; msg = '*PREVIOUS build*' }
            @{ case = 'an invalid instance';                    patch = @{ Instance = 'A B' }; msg = '*Instance*' }
            @{ case = 'a missing vault id';                     patch = @{ VaultId = '' }; msg = '*Recovery Services vault ARM id*' }
            @{ case = 'a vault id that is not an RSV ARM id';   patch = @{ VaultId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/s' }; msg = '*Recovery Services vault ARM id*' }
        ) {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $in = $GoodInputs.Clone(); foreach ($k in $patch.Keys) { $in[$k] = $patch[$k] }
            { Invoke-Psu $d 'SetInputs' $in } | Should -Throw $msg
            (Get-Track $d).status | Should -Be 'awaiting-input'
        }

        It 'stores the vault id with the inputs' {
            Mock-Queue @(1, 2)
            $d = New-Env -Step3 'in-progress'
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            (Get-Track $d).inputs.vaultId | Should -Be $script:Vault
        }
    }

    Context 'Happy path: both legs in parallel -> BVT release -> sign-off' {
        It 'queues both legs at once with the right parameters, then runs the BVT with PrivateStampVaultId' {
            Mock-Queue @(1001, 1002)
            $d = New-Env -Step3 'in-progress'
            $null = Invoke-Psu $d 'Init'
            (Invoke-Psu $d 'SetInputs' $GoodInputs).Status | Should -Be 'inputs-ready'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }

            Set-Step3 $d 'completed'
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'deploying'
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/396863/runs*' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST' -or $Uri -notlike '*/pipelines/*') { return $false }
                $b = $Body | ConvertFrom-Json
                $b.templateParameters.WebRolePort -eq '10060' -and $b.templateParameters.ArtifactBranch -eq 'releases/bcm-2610' -and
                $b.templateParameters.PrivateInstance -eq 'A' -and $b.resources.repositories.self.refName -eq 'refs/heads/releases/bcm-2611' -and
                $b.templateParameters.ServiceOverrideSettings -eq '@{"BCMAppConfig->WorkflowQueueName"="TeeQ-Upgrade.1";}'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST' -or $Uri -notlike '*/pipelines/*') { return $false }
                $b = $Body | ConvertFrom-Json
                $b.templateParameters.WebRolePort -eq '10062' -and $b.templateParameters.ArtifactBranch -eq 'releases/bcm-2611'
            }
            $t = Get-Track $d
            $t.runs.last.runId | Should -Be 1001
            $t.runs.current.runId | Should -Be 1002

            # one leg done, the other still running -> keep waiting, no BVT yet
            Mock-Builds @{ 1001 = 'succeeded'; 1002 = 'inProgress' }
            Mock-BvtCreate
            (Invoke-Psu $d 'Poll').Status | Should -Be 'deploying'
            (Get-Track $d).runs.last.result | Should -Be 'succeeded'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*vsrm*/releases?*' }

            # both done -> BVT release created with the vault id and the latest test build
            Mock-Builds @{ 1001 = 'succeeded'; 1002 = 'succeeded' }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'bvt-running'
            $r.NotifyEvent | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST' -or $Uri -notlike '*vsrm*/releases?*') { return $false }
                $b = $Body | ConvertFrom-Json
                $Uri -like 'https://vsrm.dev.azure.com/msazure/One/_apis/release/releases?*' -and
                $b.definitionId -eq 64863 -and $b.isDraft -eq $false -and
                $b.variables.PrivateStampVaultId.value -eq $script:Vault -and
                $b.artifacts[0].alias -eq 'Build' -and $b.artifacts[0].instanceReference.id -eq 'b7c84da8'
            }
            (Get-Track $d).runs.bvt.releaseId | Should -Be 17880001

            Mock-BvtStatus 'partiallySucceeded' 'inProgress'
            (Invoke-Psu $d 'Poll').Status | Should -Be 'bvt-running'

            Mock-BvtStatus 'partiallySucceeded' 'partiallySucceeded'
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'awaiting-bvt'
            $r.NotifyEvent | Should -Be 'private-stamp-bvt-ready'
            (Get-Track $d).bvtOutcome | Should -Be 'partiallySucceeded'
            (Invoke-Psu $d 'Poll').NotifyEvent | Should -BeNullOrEmpty

            $s = Invoke-Psu $d 'SignOff' @{ By = 'owner' }
            $s.Status | Should -Be 'signed-off'
        }

        It 'goes straight to owner sign-off when no BVT release is configured' {
            Mock-Queue @(1, 2)
            $d = New-Env -Bvt $false
            $in = $GoodInputs.Clone(); $in.VaultId = ''
            (Invoke-Psu $d 'SetInputs' $in).Status | Should -Be 'deploying'
            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded' }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'awaiting-bvt'
            $r.NotifyEvent | Should -Be 'private-stamp-bvt-ready'
        }

        It 'refuses sign-off before the BVT has run' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            { Invoke-Psu $d 'SignOff' @{ By = 'owner' } } | Should -Throw '*once the BVT has run*'
        }
    }

    Context 'Pinned builds (privateStampUpgrade.artifact)' {
        BeforeEach {
            $script:PinInputs = $GoodInputs.Clone(); $script:PinInputs.Remove('LastArtifactBranch')
            $script:PinInputs.LastBuild = 'https://msazure.visualstudio.com/One/_build/results?buildId=900&view=results'
            $script:StdBuilds = @{
                900 = @{ def = 223537; result = 'succeeded'; branch = 'releases/bcm-2610'; number = '3.0.881.1' }
                950 = @{ def = 223537; result = 'succeeded'; branch = 'releases/bcm-2611'; number = '3.0.890.0' }
                901 = @{ def = 111111; result = 'succeeded'; branch = 'releases/bcm-2610'; number = 'x' }
                902 = @{ def = 223537; result = 'failed'; branch = 'releases/bcm-2610'; number = '3.0.881.2' }
                903 = @{ def = 223537; result = 'succeeded'; branch = 'develop'; number = '3.0.1.0' }
            }
            $script:StdFeeds = @{ 'Mgmt_RecoverySvcs_IaaSCoord_releases_bcm_2610' = @(899, 900, 905); 'Mgmt_RecoverySvcs_IaaSCoord_releases_bcm_2611' = @(950, 951); 'Mgmt_RecoverySvcs_IaaSCoord_develop' = @(1000) }
        }

        It 'resolves a build link to its exact artifact version and branch' {
            Mock-Pinning $StdBuilds $StdFeeds
            $d = New-Env -Pinned $true -Step3 'in-progress'
            $null = Invoke-Psu $d 'SetInputs' $PinInputs
            $t = Get-Track $d
            $t.inputs.lastBuild.buildId | Should -Be 900
            $t.inputs.lastBuild.versionId | Should -Be 'ver-900'
            $t.inputs.lastBuild.feed | Should -Be 'Mgmt_RecoverySvcs_IaaSCoord_releases_bcm_2610'
            $t.inputs.lastArtifactBranch | Should -Be 'releases/bcm-2610'
        }

        It 'rejects <case>' -ForEach @(
            @{ case = 'a branch name';                    ref = 'releases/bcm-2610'; msg = '*must be a build link*' }
            @{ case = 'a build of another pipeline';      ref = '901'; msg = '*not the official build*' }
            @{ case = 'a failed build';                   ref = '902'; msg = '*completed successfully*' }
            @{ case = 'a build missing from its feed';    ref = '903'; msg = '*is not among the 1 newest versions*' }
            @{ case = "this release's own build";        ref = '950'; msg = "*this release's own build*" }
            @{ case = 'an unknown build';                 ref = '424242'; msg = '*was not found*' }
        ) {
            Mock-Pinning $StdBuilds $StdFeeds
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' -and $Uri -like '*/build/builds/424242?*' } -MockWith { throw '404' }
            $d = New-Env -Pinned $true -Step3 'in-progress'
            $null = Invoke-Psu $d 'Init'
            $in = $PinInputs.Clone(); $in.LastBuild = $ref
            { Invoke-Psu $d 'SetInputs' $in } | Should -Throw $msg
            (Get-Track $d).status | Should -Be 'awaiting-input'
        }

        It 'pins the current leg to release.buildId and posts both pins' {
            Mock-Pinning $StdBuilds $StdFeeds
            Mock-Queue @(61, 62)
            $d = New-Env -Pinned $true
            $r = Invoke-Psu $d 'SetInputs' $PinInputs
            $r.Status | Should -Be 'deploying'
            $t = Get-Track $d
            $t.inputs.currentBuild.buildId | Should -Be 950
            $t.runs.last.pinnedBuildId | Should -Be 900
            $t.runs.current.pinnedBuildId | Should -Be 950
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST' -or $Uri -notlike '*/pipelines/396863/runs*') { return $false }
                $b = $Body | ConvertFrom-Json
                $b.resources.builds.svc_build.version -eq 'ver-900' -and $b.templateParameters.ArtifactBranch -eq 'releases/bcm-2610' -and $b.templateParameters.WebRolePort -eq '10060'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST' -or $Uri -notlike '*/pipelines/396863/runs*') { return $false }
                $b = $Body | ConvertFrom-Json
                $b.resources.builds.svc_build.version -eq 'ver-950' -and $b.templateParameters.ArtifactBranch -eq 'releases/bcm-2611' -and $b.templateParameters.WebRolePort -eq '10062'
            }
        }

        It 'waits while the current build is not in the feed yet, then fails after 6 hours' {
            $feeds = $StdFeeds.Clone(); $feeds['Mgmt_RecoverySvcs_IaaSCoord_releases_bcm_2611'] = @(949)
            Mock-Pinning $StdBuilds $feeds
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/*' } -MockWith { throw 'must not queue' }
            $d = New-Env -Pinned $true
            $r = Invoke-Psu $d 'SetInputs' $PinInputs
            $r.Status | Should -Be 'inputs-ready'
            (Get-Track $d).waitingFor | Should -Match 'build 950'
            $p = Join-Path $d 'state.json'; $s = Get-Content $p -Raw | ConvertFrom-Json
            $s.privateStampUpgrade.waitingSince = (Get-Date).ToUniversalTime().AddHours(-7).ToString('o')
            $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            $r.NotifyEvent | Should -Be 'private-stamp-failed'
            (Get-Track $d).error | Should -Match 'did not appear'
        }
    }

    Context 'Failures and retry' {
        It 'waits for both legs, fails with the failed leg only, and retry re-queues just that leg' {
            Mock-Queue @(11, 12, 13)
            $d = New-Env
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Mock-Builds @{ 11 = 'succeeded'; 12 = 'failed' }
            Mock-BvtCreate
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            $r.NotifyEvent | Should -Be 'private-stamp-failed'
            @((Get-Track $d).failedLegs) | Should -Be @('current')

            $r = Invoke-Psu $d 'Retry' @{ By = 'owner' }
            $r.Status | Should -Be 'deploying'
            $t = Get-Track $d
            $t.runs.current.runId | Should -Be 13
            $t.runs.last.runId | Should -Be 11
            $t.runs.last.result | Should -Be 'succeeded'
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/*' }

            Mock-Builds @{ 11 = 'succeeded'; 13 = 'succeeded' }
            (Invoke-Psu $d 'Poll').Status | Should -Be 'bvt-running'
        }

        It 'fails both legs when queueing fails for both' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { throw 'TF400898: boom' }
            $d = New-Env
            $r = Invoke-Psu $d 'SetInputs' $GoodInputs
            $r.Status | Should -Be 'failed'
            @((Get-Track $d).failedLegs | Sort-Object) | Should -Be @('current', 'last')
            (Get-Track $d).error | Should -Match 'TF400898'
        }

        It 'a rejected BVT fails the track; retry re-runs only the BVT; the owner can also sign off anyway' {
            Mock-Queue @(21, 22)
            $d = New-Env
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Mock-Builds @{ 21 = 'succeeded'; 22 = 'succeeded' }
            Mock-BvtCreate 17880001
            $null = Invoke-Psu $d 'Poll'
            Mock-BvtStatus 'succeeded' 'rejected'
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            $r.NotifyEvent | Should -Be 'private-stamp-failed'
            @((Get-Track $d).failedLegs) | Should -Be @('bvt')

            Mock-BvtCreate 17880002
            $r = Invoke-Psu $d 'Retry' @{ By = 'owner' }
            $r.Status | Should -Be 'bvt-running'
            (Get-Track $d).runs.bvt.releaseId | Should -Be 17880002
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/*' }

            Mock-BvtStatus 'succeeded' 'rejected'
            $null = Invoke-Psu $d 'Poll'
            $s = Invoke-Psu $d 'SignOff' @{ By = 'owner' }
            $s.Status | Should -Be 'signed-off'
            (Get-Track $d).signedOffDespiteBvt | Should -Be 'rejected'
        }

        It 'treats a BVT stage that never starts (earlier stage canceled) as finished' {
            Mock-Queue @(31, 32)
            $d = New-Env
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Mock-Builds @{ 31 = 'succeeded'; 32 = 'succeeded' }
            Mock-BvtCreate
            $null = Invoke-Psu $d 'Poll'
            Mock-BvtStatus 'canceled' 'notStarted'
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            (Get-Track $d).bvtOutcome | Should -Be 'notStarted'
        }

        It 'fails a BVT release that cannot resolve its test build' {
            Mock-Queue @(41, 42)
            $d = New-Env
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Mock-Builds @{ 41 = 'succeeded'; 42 = 'succeeded' }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*vsrm*/artifacts/versions*' } -MockWith { [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'Build'; defaultVersion = $null; errorMessage = 'No builds' }) } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*vsrm*' } -MockWith { throw 'must not create' }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            (Get-Track $d).error | Should -Match 'No builds'
        }

        It 'fails a stale trigger claim instead of double-queueing' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $p = Join-Path $d 'state.json'
            $s = Get-Content $p -Raw | ConvertFrom-Json
            $s.privateStampUpgrade.status = 'triggering'
            $s.privateStampUpgrade | Add-Member -NotePropertyName claimedAt -NotePropertyValue ((Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')) -Force
            $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
            Mock Invoke-RestMethod { throw 'should not be called' }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'Poll never throws on API errors' {
            Mock-Queue @(51, 52)
            $d = New-Env
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' } -MockWith { throw 'network down' }
            $r = Invoke-Psu $d 'Poll'
            $r.Success | Should -BeFalse
            $r.Error | Should -Match 'network down'
            $r.Status | Should -Be 'deploying'
        }

        It 'skip releases the track from any open state' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $r = Invoke-Psu $d 'Skip' @{ By = 'owner'; Reason = 'stamp unavailable' }
            $r.Status | Should -Be 'skipped'
            (Get-Track $d).previousStatus | Should -Be 'awaiting-input'
        }
    }

    Context 'Restore after sign-off (restoreAfterSignOff)' {
        BeforeEach {
            $global:PsuBodies = [System.Collections.Generic.List[object]]::new()
            $global:PsuQueueIds = [System.Collections.Generic.Queue[int]]::new([int[]](1..8))
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/396863/runs*' } -MockWith {
                $global:PsuBodies.Add(($Body | ConvertFrom-Json)); [pscustomobject]@{ id = $global:PsuQueueIds.Dequeue() }
            }
            $script:In = $GoodInputs.Clone(); $script:In.VaultId = ''
        }
        AfterEach { Remove-Variable -Name PsuBodies -Scope Global -ErrorAction SilentlyContinue }

        It 'is off by default: sign-off does not redeploy' {
            $d = New-Env -Bvt $false
            $null = Invoke-Psu $d 'SetInputs' $script:In
            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded' }
            $null = Invoke-Psu $d 'Poll'
            (Invoke-Psu $d 'SignOff' @{ By = 'owner' }).Status | Should -Be 'signed-off'
            $global:PsuBodies.Count | Should -Be 2
            (Get-Track $d).restore | Should -BeNullOrEmpty
        }

        It 'redeploys both builds on the same ports without the queue override, then reports restored' {
            $d = New-Env -Bvt $false -Restore $true
            $null = Invoke-Psu $d 'SetInputs' $script:In
            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded'; 3 = 'inProgress'; 4 = 'inProgress' }
            $null = Invoke-Psu $d 'Poll'
            $s = Invoke-Psu $d 'SignOff' @{ By = 'owner' }
            $s.Status | Should -Be 'signed-off'
            $s.Transition | Should -BeLike 'signed-off; restore pending -> deploying*'
            $global:PsuBodies.Count | Should -Be 4
            $global:PsuBodies[0].templateParameters.ServiceOverrideSettings | Should -Be '@{"BCMAppConfig->WorkflowQueueName"="TeeQ-Upgrade.1";}'
            foreach ($b in $global:PsuBodies[2..3]) {
                $b.templateParameters.PSObject.Properties.Name | Should -Not -Contain 'ServiceOverrideSettings'
                $b.templateParameters.PrivateInstance | Should -Be 'A'
                $b.templateParameters.rolloutType | Should -Be 'normal'
            }
            @($global:PsuBodies[2..3] | ForEach-Object { $_.templateParameters.WebRolePort }) | Should -Be @('10060', '10062')
            @($global:PsuBodies[2..3] | ForEach-Object { $_.templateParameters.ArtifactBranch }) | Should -Be @('releases/bcm-2610', 'releases/bcm-2611')
            $t = Get-Track $d
            $t.status | Should -Be 'signed-off'
            $t.restore.status | Should -Be 'deploying'
            $t.restore.runs.last.runId | Should -Be 3
            $t.runs.last.runId | Should -Be 1

            (Invoke-Psu $d 'Poll').NotifyEvent | Should -BeNullOrEmpty
            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded'; 3 = 'succeeded'; 4 = 'succeeded' }
            $r = Invoke-Psu $d 'Poll'
            $r.NotifyEvent | Should -Be 'private-stamp-restored'
            $r.Status | Should -Be 'signed-off'
            (Get-Track $d).restore.status | Should -Be 'completed'
            (Invoke-Psu $d 'Poll').NotifyEvent | Should -BeNullOrEmpty
            $global:PsuBodies.Count | Should -Be 4
        }

        It 'uses restoreServiceOverrideSettings when configured' {
            $d = New-Env -Bvt $false -Restore $true -RestoreOverrides '@{"BCMAppConfig->ServiceName"="ic";}'
            $null = Invoke-Psu $d 'SetInputs' $script:In
            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded'; 3 = 'inProgress'; 4 = 'inProgress' }
            $null = Invoke-Psu $d 'Poll'
            $null = Invoke-Psu $d 'SignOff' @{ By = 'owner' }
            $global:PsuBodies[3].templateParameters.ServiceOverrideSettings | Should -Be '@{"BCMAppConfig->ServiceName"="ic";}'
        }

        It 'reports a failed restore and re-runs only the failed leg on private-stamp restore' {
            $d = New-Env -Bvt $false -Restore $true
            $null = Invoke-Psu $d 'SetInputs' $script:In
            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded'; 3 = 'succeeded'; 4 = 'failed' }
            $null = Invoke-Psu $d 'Poll'
            $null = Invoke-Psu $d 'SignOff' @{ By = 'owner' }
            $r = Invoke-Psu $d 'Poll'
            $r.NotifyEvent | Should -Be 'private-stamp-restore-failed'
            (Get-Track $d).restore.failedLegs | Should -Be @('current')

            Mock-Builds @{ 1 = 'succeeded'; 2 = 'succeeded'; 3 = 'succeeded'; 4 = 'failed'; 5 = 'succeeded' }
            $null = Invoke-Psu $d 'Restore' @{ By = 'owner' }
            $global:PsuBodies.Count | Should -Be 5
            $global:PsuBodies[4].templateParameters.WebRolePort | Should -Be '10062'
            $r = Invoke-Psu $d 'Poll'
            $r.NotifyEvent | Should -Be 'private-stamp-restored'
            (Get-Track $d).restore.runs.last.runId | Should -Be 3
            (Get-Track $d).restore.runs.current.runId | Should -Be 5
        }

        It 'lets the owner restore after a skip, and refuses while the test is running or a restore is active' {
            $d = New-Env -Bvt $false
            $null = Invoke-Psu $d 'SetInputs' $script:In
            { Invoke-Psu $d 'Restore' @{ By = 'owner' } } | Should -Throw "*still 'deploying'*"
            $null = Invoke-Psu $d 'Skip' @{ By = 'owner'; Reason = 'stamp broken' }
            Mock-Builds @{ 3 = 'inProgress'; 4 = 'inProgress' }
            (Invoke-Psu $d 'Restore' @{ By = 'owner' }).Status | Should -Be 'skipped'
            (Get-Track $d).restore.status | Should -Be 'deploying'
            (Get-Track $d).restore.reason | Should -Be 'manual'
            { Invoke-Psu $d 'Restore' @{ By = 'owner' } } | Should -Throw "*already 'deploying'*"
        }

        It 'refuses a restore when nothing was deployed' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $null = Invoke-Psu $d 'Skip' @{ By = 'owner'; Reason = 'n/a' }
            { Invoke-Psu $d 'Restore' @{ By = 'owner' } } | Should -Throw '*Nothing to restore*'
        }
    }
}
Describe 'privateStampUpgrade wiring' {
    BeforeAll {
        $script:ResolverPath = Join-Path $PSScriptRoot '..\scripts\Resolve-NotificationRecipients.ps1'
    }

    It 'routes <key> to 5-deploy-canary.<outcome>' -ForEach @(
        @{ key = 'private-stamp-input-needed'; outcome = 'halt' }
        @{ key = 'private-stamp-bvt-ready';    outcome = 'halt' }
        @{ key = 'private-stamp-failed';       outcome = 'failure' }
        @{ key = 'private-stamp-restored';     outcome = 'success' }
        @{ key = 'private-stamp-restore-failed'; outcome = 'failure' }
    ) {
        $rule = [pscustomobject]@{ emailGroups = @('permanent') }
        $step = [pscustomobject]@{}
        $step | Add-Member -NotePropertyName $outcome -NotePropertyValue $rule
        $cfg = [pscustomobject]@{
            notifications = [pscustomobject]@{
                groups  = [pscustomobject]@{ permanent = @('dl@example.com') }
                routing = [pscustomobject]@{ '5-deploy-canary' = $step }
            }
        }
        $rel = [pscustomobject]@{ releaseOwner = [pscustomobject]@{ alias = 'o'; email = 'owner@example.com' } }
        $r = & $ResolverPath -EventKey $key -Config $cfg -Release $rel
        $r.EmailTo | Should -Contain 'dl@example.com'
        $r.EmailTo | Should -Contain 'owner@example.com'
    }

    It 'watcher and cold resume poll the side track every tick' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match "Invoke-PrivateStampUpgrade\.ps1"
        $w | Should -Match "Action\s*=\s*'Poll'"
        $w | Should -Match 'private stamp upgrade \$\(\$psu\.NotifyEvent\)'
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match "Invoke-PrivateStampUpgrade\.ps1"
        $c | Should -Match 'PrivateStampSideChannel'
        # a restore after sign-off keeps the side track polled
        $w | Should -Match 'restore\.status -match ''\^\(pending\|triggering\|deploying\)\$'''
        $c | Should -Match 'restore\.status -match ''\^\(pending\|triggering\|deploying\)\$'''
    }
}

