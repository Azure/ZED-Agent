<#
.SYNOPSIS
    Pester tests for the shared commit tracker (commitExcel.mode = "tracker"):
    lib/CommitTrackerLib.ps1 helpers, Invoke-CommitTracker.ps1 (Graph mocked),
    the Step 4 side-channel tracker branch, and Load-ServiceConfig validation.
    (Live behavior against Excel Online was verified on a scratch copy of the BCM tracker.)
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\CommitTrackerLib.ps1')
    $script:Tracker = Join-Path $PSScriptRoot '..\scripts\Invoke-CommitTracker.ps1'

    $script:Columns = @(
        [pscustomobject]@{ header = 'Date'; source = 'date'; width = 166.5 }
        [pscustomobject]@{ header = 'Author'; source = 'author' }
        [pscustomobject]@{ header = 'PR/Commit Link'; source = 'link' }
        [pscustomobject]@{ header = 'Description of Changes'; source = 'description' }
        [pscustomobject]@{ header = 'Risk Assessment(Low/Medium/High)'; required = $true; aliases = @('Risk Assesment(Low/Medium/High)') }
        [pscustomobject]@{ header = 'Testing Done'; required = $true }
        [pscustomobject]@{ header = 'IsChangeUnderConfig'; required = $true }
    )
    $global:ZedTrackerHeader = @('Date', 'Author', 'PR/Commit Link', 'Description of Changes', 'Risk Assessment(Low/Medium/High)', 'Testing Done', 'IsChangeUnderConfig')

    function New-TrackerEnv {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [ordered]@{
            ado = @{ organization = 'msazure'; project = 'One'; repository = 'Repo' }
            commitExcel = [ordered]@{
                mode = 'tracker'; sheetNameTemplate = 'BCM{{YYMM}}'; sharePointFolder = '/x'
                excludeAuthors = @('OneBranch GitPushVersion Account')
                tracker = [ordered]@{
                    url = 'https://example.sharepoint.com/x'; dateFormat = 'dd-mm-yyyy'
                    headerStyle = @{ fill = '#1F4E79'; fontColor = '#FFFFFF'; bold = $true; wrapText = $true }
                    columns = $script:Columns
                }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'service-config.json') -Encoding UTF8
        @(
            [ordered]@{ CommitID = 'aaa1111'; Author = 'Dev One'; Date = 'Tue, 6 Oct 2026 10:00:00 +0530'; Subject = 'Merged PR 17000001: Feature A'; Comments = '[Production-impacting] [NewFeature] Feature A' }
            [ordered]@{ CommitID = 'bbb2222'; Author = 'OneBranch GitPushVersion Account'; Date = 'Tue, 6 Oct 2026 11:00:00 +0530'; Subject = 'Incrementing build version'; Comments = 'bump' }
            [ordered]@{ CommitID = 'ccc3333'; Author = 'Dev Two'; Date = 'Mon, 5 Oct 2026 09:00:00 +0530'; Subject = 'Merged PR 17000002: Fix "quotes" B'; Comments = '=SUM(1,2) looks like a formula' }
            [ordered]@{ CommitID = 'ddd4444'; Author = 'Dev Three'; Date = 'Wed, 7 Oct 2026 09:00:00 +0530'; Subject = 'Direct push'; Comments = 'direct' }
        ) | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'commits.json') -Encoding UTF8
        return $dir
    }

    function Invoke-Tracker([string]$Dir, [string]$Action, [hashtable]$Extra = @{}) {
        $splat = @{
            Action = $Action; ReleaseId = '2026-11'; ServiceConfigPath = (Join-Path $Dir 'service-config.json')
            DriveId = 'drv'; ItemId = 'itm'; AccessToken = 'tok'; RepoPath = $Dir; MaxAttempts = 1
        }
        if ($Action -eq 'Publish') { $splat.CommitsJsonPath = (Join-Path $Dir 'commits.json') }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $script:Tracker @splat
    }
}

AfterAll { Remove-Variable -Name ZedTrackerCalls, ZedTrackerHeader -Scope Global -ErrorAction SilentlyContinue }

Describe 'CommitTrackerLib' {
    It 'expands the sheet name from the release id' {
        Expand-SheetName 'BCM{{YYMM}}' '2026-11' | Should -Be 'BCM2611'
        Expand-SheetName 'Prot{{YYMM}}Commits' '2027-01' | Should -Be 'Prot2701Commits'
    }

    It 'rejects invalid Excel sheet names' {
        Test-SheetName 'BCM2611' | Should -BeNullOrEmpty
        Test-SheetName 'a/b' | Should -Match 'contains'
        Test-SheetName ('x' * 32) | Should -Match '31'
    }

    It 'derives row keys from the link text styles used in the tracker' -ForEach @(
        @{ t = 'Pull Request 17071159: Add Cancel flow'; k = 'pr:17071159' }
        @{ t = 'PR 16490753'; k = 'pr:16490753' }
        @{ t = "`nPR 16623906"; k = 'pr:16623906' }
        @{ t = 'https://dev.azure.com/o/p/_git/r/pullrequest/12345'; k = 'pr:12345' }
        @{ t = 'Commit abc1234: hotfix'; k = 'commit:abc1234' }
        @{ t = ''; k = $null }
    ) {
        Get-RowKey $t | Should -Be $k
    }

    It 'matches short and full commit shas' {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$set.Add('commit:abc1234def')
        Test-KeyPresent 'commit:abc1234' $set | Should -BeTrue
        Test-KeyPresent 'commit:abc9999' $set | Should -BeFalse
    }

    It 'maps headers ignoring spaces/case and accepts aliases' {
        $hm = Get-HeaderMap @('Date', 'Author', 'PR/Commit Link', 'Description of Changes', 'Risk Assesment(Low/Medium/High)', 'Testing Done', 'Is Change Under Config') $script:Columns
        $hm.missing.Count | Should -Be 0
        $hm.map[(ConvertTo-HeaderKey 'IsChangeUnderConfig')] | Should -Be 6
        $hm.map[(ConvertTo-HeaderKey 'Risk Assessment(Low/Medium/High)')] | Should -Be 4
    }

    It 'parses git %aD dates' {
        (ConvertFrom-GitDate 'Tue, 6 Oct 2026 10:00:00 +0530').ToString('yyyy-MM-dd') | Should -Be '2026-10-06'
        ConvertFrom-GitDate 'garbage' | Should -BeNullOrEmpty
    }

    It 'builds PR rows with a HYPERLINK formula and escaped quotes' {
        $r = ConvertTo-TrackerRow ([pscustomobject]@{ CommitID = 'ccc3333'; Author = 'Dev'; Date = 'Mon, 5 Oct 2026 09:00:00 +0530'; Subject = 'Merged PR 17000002: Fix "quotes" B'; Comments = 'x' }) 'msazure' 'One' 'Repo' @{}
        $r.key | Should -Be 'pr:17000002'
        $r.linkText | Should -Be 'Pull Request 17000002: Fix "quotes" B'
        Get-CellFormula $r 'link' | Should -Be '=HYPERLINK("https://dev.azure.com/msazure/One/_git/Repo/pullrequest/17000002","Pull Request 17000002: Fix ""quotes"" B")'
    }

    It 'builds commit rows for direct pushes using the full sha when known' {
        $r = ConvertTo-TrackerRow ([pscustomobject]@{ CommitID = 'ddd4444'; Author = 'Dev'; Date = ''; Subject = 'Direct push'; Comments = '' }) 'o' 'p' 'r' @{ 'ddd4444' = 'ddd4444' + ('0' * 33) }
        $r.key | Should -Be 'commit:ddd4444'
        $r.linkUrl | Should -Be ('https://dev.azure.com/o/p/_git/r/commit/ddd4444' + ('0' * 33))
        $r.linkText | Should -Be 'Commit ddd4444: Direct push'
    }
}

Describe 'Invoke-CommitTracker (Graph mocked)' {
    BeforeEach {
        $global:ZedTrackerCalls = New-Object System.Collections.Generic.List[object]
        Mock Invoke-RestMethod -ParameterFilter { $Method -in @('PATCH', 'POST') } -MockWith {
            $global:ZedTrackerCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
            if ($Uri -like '*/createSession') { return [pscustomobject]@{ id = 'sess-1' } }
            return [pscustomobject]@{}
        }
    }

    Context 'Publish to a new sheet' {
        It 'creates the sheet, writes header + styling, then appends sorted rows (bot excluded)' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/worksheets?*' } -MockWith { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'BCM2610' }) } }
            $d = New-TrackerEnv
            $r = Invoke-Tracker $d 'Publish'
            $r.Status | Should -Be 'created'
            $r.SheetName | Should -Be 'BCM2611'
            $r.Appended | Should -Be 3

            $posts = @($global:ZedTrackerCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/worksheets' })
            $posts.Count | Should -Be 1
            ($posts[0].Body | ConvertFrom-Json).name | Should -Be 'BCM2611'

            $hdr = @($global:ZedTrackerCalls | Where-Object { $_.Uri -like "*range(address='A1:G1')" })[0]
            ($hdr.Body | ConvertFrom-Json).values[0] | Should -Be $global:ZedTrackerHeader
            @($global:ZedTrackerCalls | Where-Object { $_.Uri -like '*A1:G1'')/format/fill' }).Count | Should -Be 1
            @($global:ZedTrackerCalls | Where-Object { $_.Uri -like "*range(address='A:A')/format" }).Count | Should -Be 1

            $rowCalls = @($global:ZedTrackerCalls | Where-Object { $_.Uri -like "*range(address='A2:G4')" })
            $rowCalls.Count | Should -Be 2
            # number formats first (text columns '@'), then formulas
            $nf = ($rowCalls[0].Body | ConvertFrom-Json).numberFormat
            $nf[0][0] | Should -Be 'dd-mm-yyyy'; $nf[0][2] | Should -Be 'General'; $nf[0][3] | Should -Be '@'
            $f = ($rowCalls[1].Body | ConvertFrom-Json).formulas
            $f[0][2] | Should -BeLike '=HYPERLINK(*Pull Request 17000002*'   # 5 Oct sorts first
            $f[0][3] | Should -Be '=SUM(1,2) looks like a formula'
            $f[1][2] | Should -BeLike '*Pull Request 17000001*'
            $f[2][2] | Should -BeLike '*Commit ddd4444: Direct push*'
            $f[0][4] | Should -Be ''
            ($f | ForEach-Object { $_[1] }) | Should -Not -Contain 'OneBranch GitPushVersion Account'

            @($global:ZedTrackerCalls | Where-Object { $_.Uri -like '*/closeSession' }).Count | Should -Be 1
        }
    }

    Context 'Publish to an existing sheet' {
        BeforeEach {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/worksheets?*' } -MockWith { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'BCM2611' }) } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*usedRange*' } -MockWith { [pscustomobject]@{ address = "'BCM2611'!A1:G3" } }
        }

        It 'adopts it and appends only missing rows after the last used row' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like "*range(address='A1:G3')*" } -MockWith {
                [pscustomobject]@{ text = @(
                    , $global:ZedTrackerHeader
                    , @('06-10-2026', 'Dev One', 'Pull Request 17000001: Feature A', 'team text', 'Low', 'BVT', 'No')
                    , @('', '', '', '', '', '', '')
                ) }
            }
            $d = New-TrackerEnv
            $r = Invoke-Tracker $d 'Publish'
            $r.Status | Should -Be 'appended'
            $r.Created | Should -BeFalse
            $r.AlreadyPresent | Should -Be 1
            $r.Appended | Should -Be 2
            @($global:ZedTrackerCalls | Where-Object { $_.Uri -like '*/worksheets' -and $_.Method -eq 'POST' }).Count | Should -Be 0
            @($global:ZedTrackerCalls | Where-Object { $_.Uri -like "*address='A1:G1'*" }).Count | Should -Be 0
            @($global:ZedTrackerCalls | Where-Object { $_.Uri -like "*range(address='A4:G5')" }).Count | Should -Be 2
        }

        It 'is a no-op when every commit is already present' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like "*range(address='A1:G3')*" } -MockWith {
                [pscustomobject]@{ text = @(
                    , $global:ZedTrackerHeader
                    , @('', '', 'Pull Request 17000001: Feature A', '', '', '', '')
                    , @('', '', 'PR 17000002', '', '', '', '')
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*usedRange*' } -MockWith { [pscustomobject]@{ address = "'BCM2611'!A1:G4" } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like "*range(address='A1:G4')*" } -MockWith {
                [pscustomobject]@{ text = @(
                    , $global:ZedTrackerHeader
                    , @('', '', 'Pull Request 17000001: Feature A', '', '', '', '')
                    , @('', '', 'PR 17000002', '', '', '', '')
                    , @('', '', 'Commit ddd4444: Direct push', '', '', '', '')
                ) }
            }
            $d = New-TrackerEnv
            $r = Invoke-Tracker $d 'Publish'
            $r.Status | Should -Be 'up-to-date'
            $r.Appended | Should -Be 0
            @($global:ZedTrackerCalls | Where-Object { $_.Method -eq 'PATCH' }).Count | Should -Be 0
        }

        It 'refuses a sheet whose header lacks a configured column and writes nothing' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like "*range(address='A1:G3')*" } -MockWith {
                [pscustomobject]@{ text = @(
                    , @('Date', 'Author', 'PR/Commit Link', 'Description of Changes', 'Risk', 'Testing Done', 'IsChangeUnderConfig')
                    , @('', '', 'PR 1', '', '', '', '')
                    , @('', '', '', '', '', '', '')
                ) }
            }
            $d = New-TrackerEnv
            { Invoke-Tracker $d 'Publish' } | Should -Throw '*missing: Risk Assessment(Low/Medium/High)*'
            @($global:ZedTrackerCalls | Where-Object { $_.Method -eq 'PATCH' }).Count | Should -Be 0
        }
    }

    Context 'Poll and Read' {
        BeforeEach {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/worksheets?*' } -MockWith { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'BCM2611' }) } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*usedRange*' } -MockWith { [pscustomobject]@{ address = "'BCM2611'!A1:G5" } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'GET' -and $Uri -like "*range(address='A1:G5')*" } -MockWith {
                [pscustomobject]@{ text = @(
                    , $global:ZedTrackerHeader
                    , @('05-10-2026', 'Dev Two', 'Pull Request 17000002: B', 'desc', 'Low', 'BVT', 'No')
                    , @('06-10-2026', 'Dev One', 'Pull Request 17000001: A', 'desc', 'Medium', '', 'Yes')
                    , @('', '', '', 'stray note without a link', '', '', '')
                    , @('07-10-2026', 'Dev Three', 'Commit ddd4444: C', '', ' ', 'n/a', 'NA')
                ) }
            }
        }

        It 'counts only rows with a link and requires every required column' {
            $d = New-TrackerEnv
            $r = Invoke-Tracker $d 'Poll'
            $r.Success | Should -BeTrue
            $r.TotalRows | Should -Be 3
            $r.Filled | Should -Be 1
            $r.Pct | Should -Be 33
            $r.Status | Should -Be 'incomplete'
            $r.Missing[0].row | Should -Be 3
            $r.Missing[0].missingColumns | Should -Be @('Testing Done')
            $r.Missing[1].missingColumns | Should -Be @('Risk Assessment(Low/Medium/High)')
            @($global:ZedTrackerCalls | Where-Object { $_.Method -eq 'PATCH' }).Count | Should -Be 0
        }

        It 'Read returns rows keyed by header' {
            $d = New-TrackerEnv
            $r = Invoke-Tracker $d 'Read'
            $r.Rows.Count | Should -Be 3
            $r.Rows[1].'PR/Commit Link' | Should -Be 'Pull Request 17000001: A'
            $r.Rows[1].IsChangeUnderConfig | Should -Be 'Yes'
        }

        It 'Poll reports a missing sheet as an error without throwing' {
            $d = New-TrackerEnv
            $r = Invoke-Tracker $d 'Poll' @{ SheetName = 'BCM9999' }
            $r.Success | Should -BeFalse
            $r.Error | Should -Match 'does not exist'
        }
    }

    Context 'Test mode' {
        It 'never touches the shared workbook' {
            Mock Invoke-RestMethod { throw 'no Graph calls in test mode' }
            $d = New-TrackerEnv
            @{ releaseId = '2026-11'; testMode = $true } | ConvertTo-Json | Set-Content (Join-Path $d 'release.json')
            $r = Invoke-Tracker $d 'Publish' @{ ReleaseFile = (Join-Path $d 'release.json') }
            $r.Status | Should -Be 'skipped-test-mode'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }
}

Describe 'Tracker mode wiring' {
    It 'Step 4 side-channel completes Step 4 from the tracker poll' {
        $relDir = Join-Path $TestDrive 'sc'; New-Item -ItemType Directory $relDir -Force | Out-Null
        $state = Join-Path $relDir 'state.json'
        @{
            releaseId = '2026-11'; step4InlineCompleted = $true; step4ExcelUrl = 'https://example.sharepoint.com/x'
            step4Tracker = @{ sheetName = 'BCM2611'; driveId = 'drv'; itemId = 'itm' }
            steps = @(@{ number = 4; status = 'in-progress' }); lastUpdated = (Get-Date -Format 'o')
        } | ConvertTo-Json -Depth 5 | Set-Content $state -Encoding UTF8
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/worksheets?*' } -MockWith { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'BCM2611' }) } }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*usedRange*' } -MockWith { [pscustomobject]@{ address = "'BCM2611'!A1:G2" } }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*range(address='A1:G2')*" } -MockWith {
            [pscustomobject]@{ text = @(
                , $global:ZedTrackerHeader
                , @('05-10-2026', 'Dev', 'PR 17000002', 'd', 'Low', 'BVT', 'No')
            ) }
        }
        $cfgDir = New-TrackerEnv
        $r = & (Join-Path $PSScriptRoot '..\scripts\Invoke-Step4SideChannel.ps1') -ReleaseId '2026-11' -StateFile $state -StateLock (Join-Path $relDir 'l') -AuditFile (Join-Path $relDir 'a.jsonl') -AccessToken 'tok' -ServiceConfigPath (Join-Path $cfgDir 'service-config.json')
        $r.Error | Should -BeNullOrEmpty
        $r.Success | Should -BeTrue
        $r.ImpactPct | Should -Be 100
        $r.StepCompleted | Should -BeTrue
        ((Get-Content $state -Raw | ConvertFrom-Json).steps | Where-Object number -eq 4).status | Should -Be 'completed'
    }

    It 'watcher routes poll-onedrive-file directives with a tracker to Invoke-CommitTracker' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match "PSObject.Properties\['tracker'\]"
        $w | Should -Match 'Invoke-CommitTracker\.ps1'
    }

    Context 'Load-ServiceConfig validation' {
        BeforeAll {
            $script:Loader = Join-Path $PSScriptRoot '..\scripts\Load-ServiceConfig.ps1'
            function Write-Cfg($CommitExcel) {
                $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                [ordered]@{
                    service = @{ name = 'BCM'; displayName = 'BCM' }; serviceTreeIds = @{ safefly = 'x' }
                    ado = @{ organization = 'o'; project = 'p'; repository = 'r'; branchPrefix = 'b'; baseBranch = 'master' }
                    kusto = @{ bvt = @{ cluster = 'c' }; canary = @{ cluster = 'c' } }; sharepoint = @{ sitePath = '/s' }
                    notifications = @{ groups = @{ permanent = @('a@b.c') }; routing = @{} }; stepGates = @{ x = $false }
                    commitExcel = $CommitExcel
                } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'service-config.json')
                '{}' | Set-Content (Join-Path $dir 'pipeline-catalog.json')
                return (Join-Path $dir 'service-config.json')
            }
        }

        It 'accepts per-release configs without a mode' {
            { & $Loader -ServiceConfigPath (Write-Cfg @{ sheetNameTemplate = 'P{{YYMM}}'; sharePointFolder = '/x'; excludeAuthors = @() }) } | Should -Not -Throw
        }
        It 'accepts a valid tracker config' {
            { & $Loader -ServiceConfigPath (Write-Cfg @{ mode = 'tracker'; sheetNameTemplate = 'BCM{{YYMM}}'; sharePointFolder = '/x'; excludeAuthors = @(); tracker = @{ url = 'https://x'; columns = $script:Columns } }) } | Should -Not -Throw
        }
        It 'rejects <case>' -ForEach @(
            @{ case = 'an unknown mode'; ce = @{ mode = 'shared'; sheetNameTemplate = 'B{{YYMM}}' }; msg = '*not supported*' }
            @{ case = 'a missing url'; ce = @{ mode = 'tracker'; sheetNameTemplate = 'B{{YYMM}}'; tracker = @{ url = ''; columns = @(@{ header = 'L'; source = 'link' }, @{ header = 'R'; required = $true }) } }; msg = '*tracker.url*' }
            @{ case = 'no link column'; ce = @{ mode = 'tracker'; sheetNameTemplate = 'B{{YYMM}}'; tracker = @{ url = 'u'; columns = @(@{ header = 'R'; required = $true }) } }; msg = "*source 'link'*" }
            @{ case = 'no required column'; ce = @{ mode = 'tracker'; sheetNameTemplate = 'B{{YYMM}}'; tracker = @{ url = 'u'; columns = @(@{ header = 'L'; source = 'link' }) } }; msg = '*required*' }
            @{ case = 'a fixed sheet name'; ce = @{ mode = 'tracker'; sheetNameTemplate = 'Commits'; tracker = @{ url = 'u'; columns = @(@{ header = 'L'; source = 'link' }, @{ header = 'R'; required = $true }) } }; msg = '*{{YYMM}}*' }
        ) {
            { & $Loader -ServiceConfigPath (Write-Cfg $ce) } | Should -Throw $msg
        }
    }
}
