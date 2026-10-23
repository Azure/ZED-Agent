BeforeAll {
    $script:readPrior = Join-Path $PSScriptRoot '..\scripts\Read-PriorRun.ps1'
    $script:selfRuns  = Join-Path $PSScriptRoot '..\scripts\Get-SelfAuthoredRuns.ps1'

    # Mock bodies run in their own scope, so everything they need is inlined
    # rather than read from a test-scope variable.
    $script:AdoMock = {
        # Build API — how a run is traced back to its owning pipeline definition.
        if ($Uri -match '/_apis/build/builds/(\d+)') {
            $owners = @{ '900001' = 7001; '900002' = 7001; '900009' = 7002 }
            $bid = $Matches[1]
            return [pscustomobject]@{
                id         = [int]$bid
                definition = [pscustomobject]@{ id = $owners[$bid] }
            }
        }
        # Pipelines API — the run detail.
        if ($Uri -match '/_apis/pipelines/\d+/runs/(\d+)') {
            return [pscustomobject]@{
                id                 = [int]$Matches[1]
                name               = "run-$($Matches[1])"
                state              = 'completed'
                result             = 'canceled'
                finishedDate       = '2026-05-19T10:00:00Z'
                templateParameters = [pscustomobject]@{ alphaStamps = '*' }
                resources          = [pscustomobject]@{
                    repositories = [pscustomobject]@{
                        self = [pscustomobject]@{ refName = 'refs/heads/rel-1' }
                    }
                }
            }
        }
        throw "unexpected uri: $Uri"
    }
}

Describe 'Read-PriorRun -RunIds' {

    BeforeEach {
        Mock az { return 'fake-token' }
        Mock Invoke-RestMethod $script:AdoMock
    }

    It 'resolves the owning pipeline for each run without being told the pipeline id' {
        $runs = & $script:readPrior -Organization o -Project p -RunIds @(900001, 900002)
        @($runs).Count | Should -Be 2
        @($runs)[0].definitionId | Should -Be 7001
        @($runs)[1].definitionId | Should -Be 7001
    }

    It 'normalizes the run record' {
        $r = @(& $script:readPrior -Organization o -Project p -RunIds @(900001))[0]
        $r.runId        | Should -Be 900001
        $r.sourceBranch | Should -Be 'refs/heads/rel-1'
        $r.result       | Should -Be 'canceled'
        $r.templateParameters.alphaStamps | Should -Be '*'
    }

    It 'throws a precise error when a run does not belong to the requested pipeline' {
        { & $script:readPrior -Organization o -Project p -PipelineId 7001 -RunIds @(900009) } |
            Should -Throw '*7002*'
    }

    It 'accepts runs that do belong to the requested pipeline' {
        @(& $script:readPrior -Organization o -Project p -PipelineId 7001 -RunIds @(900001)) |
            Should -HaveCount 1
    }

    It 'stamps the supplied release group onto every run' {
        $runs = & $script:readPrior -Organization o -Project p -RunIds @(900001, 900002) -ReleaseGroup 'may-release'
        @($runs) | ForEach-Object { $_.releaseGroup | Should -Be 'may-release' }
    }

    It 'falls back to the source branch as the release group' {
        @(& $script:readPrior -Organization o -Project p -RunIds @(900001))[0].releaseGroup |
            Should -Be 'refs/heads/rel-1'
    }

    It 'keeps cancelled runs — release runs are routinely cancelled once verified' {
        @(& $script:readPrior -Organization o -Project p -RunIds @(900001))[0].result |
            Should -Be 'canceled'
    }
}

Describe 'Self-authored run exclusion' {

    BeforeAll {
        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zed-selfrun-" + [guid]::NewGuid().ToString('N'))
        $relDir = Join-Path $script:repoRoot '.zed-agent\releases\TEST-1'
        New-Item -ItemType Directory -Path $relDir -Force | Out-Null
        @(
            @{ runId = 900002; pipelineId = 7001; step = 2 }
            @{ runId = 900009; pipelineId = 7002; step = 5 }
        ) | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $relDir 'test-run-capture.json') -Encoding utf8NoBOM
    }

    AfterAll {
        if (Test-Path $script:repoRoot) { Remove-Item $script:repoRoot -Recurse -Force }
    }

    BeforeEach {
        Mock az { return 'fake-token' }
        Mock Invoke-RestMethod $script:AdoMock
    }

    It 'harvests run ids that the agent itself triggered' {
        $ids = @(& $script:selfRuns -RepoRoot $script:repoRoot -IdsOnly)
        $ids | Should -Contain 900002
        $ids | Should -Contain 900009
    }

    It 'excludes a self-authored run from the learning set' {
        # 900001 is human-authored; 900002 is in the ledger.
        $runs = & $script:readPrior -Organization o -Project p -RunIds @(900001, 900002) `
                    -RepoRoot $script:repoRoot -WarningAction SilentlyContinue
        @($runs) | Should -HaveCount 1
        @($runs)[0].runId | Should -Be 900001
    }

    It 'refuses to learn when every supplied run was authored by the agent' {
        { & $script:readPrior -Organization o -Project p -RunIds @(900002) `
              -RepoRoot $script:repoRoot -WarningAction SilentlyContinue } |
            Should -Throw '*authored by ZED itself*'
    }

    It 'can be overridden explicitly when the caller really wants agent runs' {
        @(& $script:readPrior -Organization o -Project p -RunIds @(900002) `
              -RepoRoot $script:repoRoot -IncludeSelfAuthored) | Should -HaveCount 1
    }
}
