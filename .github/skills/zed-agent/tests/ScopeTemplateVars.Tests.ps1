BeforeAll {
    $script:scriptRoot = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $script:scriptRoot 'Get-ScopeTemplateVars.ps1')
    . (Join-Path $script:scriptRoot 'Expand-Template.ps1')
    $script:templateRoot = Join-Path $PSScriptRoot '..\templates'
}

Describe 'L-18: release comms state the route/geography scope' {

    Context 'Get-ScopeTemplateVars' {

        It 'derives route count, geography count and a per-pipeline region table from the coverage report' {
            $coverage = [PSCustomObject]@{
                coveredGeographies = @('US', 'Europe', 'Asia Pacific')
                coveredCount       = 3
                missingGeographies = @()
                missingCount       = 0
                perPipeline        = [PSCustomObject]@{
                    SFRP = [PSCustomObject]@{ regions = @('eastus', 'westus') }
                    SFMC = [PSCustomObject]@{ regions = @('northeurope') }
                }
            }

            $vars = Get-ScopeTemplateVars -Coverage $coverage

            $vars.routeCount     | Should -Be '2'
            $vars.geographyCount | Should -Be '3'
            $vars.regionListHtml | Should -Match 'SFRP'
            $vars.regionListHtml | Should -Match 'eastus, westus'
            $vars.regionListHtml | Should -Match 'northeurope'
        }

        It 'repeats the L-16 missing-geography warning instead of reporting a clean partial scope' {
            $coverage = [PSCustomObject]@{
                coveredGeographies = @('US')
                coveredCount       = 1
                missingGeographies = @('Sweden', 'Norway')
                missingCount       = 2
                perPipeline        = [PSCustomObject]@{ SFRP = [PSCustomObject]@{ regions = @('eastus') } }
            }

            $vars = Get-ScopeTemplateVars -Coverage $coverage

            $vars.regionListHtml | Should -Match '2 geograph\(ies\) NOT covered'
            $vars.regionListHtml | Should -Match 'Sweden, Norway'
        }

        It 'reports "not yet computed" rather than fabricating a scope when no coverage exists' {
            $vars = Get-ScopeTemplateVars -ReleaseId 'nonexistent-release' -StateRoot (Join-Path $TestDrive 'releases')

            $vars.routeCount     | Should -Be 'not yet computed'
            $vars.geographyCount | Should -Be 'not yet computed'
            $vars.regionListHtml | Should -Match 'not been computed'
        }

        It 'HTML-encodes pipeline keys and regions' {
            $coverage = [PSCustomObject]@{
                coveredGeographies = @('US')
                missingCount       = 0
                perPipeline        = [PSCustomObject]@{ '<script>' = [PSCustomObject]@{ regions = @('a&b') } }
            }

            $vars = Get-ScopeTemplateVars -Coverage $coverage

            $vars.regionListHtml | Should -Not -Match '<script>'
            $vars.regionListHtml | Should -Match '&lt;script&gt;'
            $vars.regionListHtml | Should -Match 'a&amp;b'
        }

        It 'reads the coverage report persisted in release state by Assert-GeographyCoverage' {
            $stateRoot = Join-Path $TestDrive 'releases'
            New-Item -ItemType Directory -Path (Join-Path $stateRoot 'prot9999') -Force | Out-Null
            @{
                releaseId         = 'prot9999'
                geographyCoverage = @{
                    coveredGeographies = @('US', 'Europe')
                    missingCount       = 0
                    perPipeline        = @{ SFRP = @{ regions = @('eastus') } }
                }
            } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $stateRoot 'prot9999\release.json') -Encoding UTF8

            $vars = Get-ScopeTemplateVars -ReleaseId 'prot9999' -StateRoot $stateRoot

            $vars.geographyCount | Should -Be '2'
            $vars.routeCount     | Should -Be '1'
        }
    }

    Context 'Templates render with the scope tokens supplied' {

        # Expand-Template runs with -StrictPlaceholders ON, so an unsupplied token throws.
        # These tests prove the WP-FGHI template edits are actually renderable.

        It 'canary-approval-request.html renders with no unsubstituted placeholders' {
            $coverage = [PSCustomObject]@{
                coveredGeographies = @('US', 'Europe')
                missingCount       = 0
                perPipeline        = [PSCustomObject]@{ SFRP = [PSCustomObject]@{ regions = @('eastus') } }
            }
            $vars = @{
                releaseId = 'prot2609'; buildVersion = '1.2.3'; branch = 'main'
                approvalRows = '<tr><td>x</td></tr>'; ev2Links = '<a href="#">ev2</a>'
                releaseOwner = 'Test Owner'
            }
            foreach ($kv in (Get-ScopeTemplateVars -Coverage $coverage).GetEnumerator()) { $vars[$kv.Key] = $kv.Value }

            $rendered = Expand-Template -TemplatePath (Join-Path $script:templateRoot 'canary-approval-request.html') -Variables $vars

            $rendered | Should -Not -Match '\{\{'
            $rendered | Should -Match '2 route\(s\)|1 route\(s\)'
            $rendered | Should -Match 'geograph'
        }

        It 'throws when the scope tokens are omitted — proving the tokens are load-bearing' {
            $vars = @{
                releaseId = 'prot2609'; buildVersion = '1.2.3'; branch = 'main'
                approvalRows = 'x'; ev2Links = 'y'; releaseOwner = 'Test Owner'
            }

            { Expand-Template -TemplatePath (Join-Path $script:templateRoot 'canary-approval-request.html') -Variables $vars } |
                Should -Throw '*unsubstituted placeholders*'
        }
    }
}
