BeforeAll {
    $script:scriptRoot = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $script:scriptRoot 'Get-RolloutScopeReport.ps1')
    . (Join-Path $script:scriptRoot 'Get-ScopeTemplateVars.ps1')

    function New-Coverage {
        param(
            [string[]] $Missing = @(),
            [hashtable] $PerPipeline = @{ SFRP = @('eastus', 'westus') }
        )
        $pp = [PSCustomObject]@{}
        foreach ($k in $PerPipeline.Keys) {
            $pp | Add-Member -NotePropertyName $k -NotePropertyValue ([PSCustomObject]@{ regions = @($PerPipeline[$k]) })
        }
        [PSCustomObject]@{
            coveredGeographies = @('US')
            missingGeographies = @($Missing)
            missingCount       = @($Missing).Count
            perPipeline        = $pp
        }
    }
}

Describe 'Rollout scope note — classify what is NOT in the rollout' {

    Context 'Deliberate exclusions' {

        It 'reports CCOA-excluded stamps with their reason' {
            $cfg = [PSCustomObject]@{
                inventory = [PSCustomObject]@{
                    ccoaExclusions = [PSCustomObject]@{
                        stamps = @(
                            [PSCustomObject]@{ stampId = 'eus-05'; reason = 'CCOA freeze' },
                            'wus-02'
                        )
                    }
                }
            }

            $r = Get-RolloutScopeReport -Coverage (New-Coverage) -ServiceConfig $cfg

            $r.deliberateCount | Should -Be 2
            ($r.deliberate | Where-Object { $_.item -eq 'eus-05' }).reason | Should -Be 'CCOA freeze'
            ($r.deliberate | Where-Object { $_.item -eq 'wus-02' }).kind   | Should -Be 'ccoa'
            $r.hasUnintended | Should -BeFalse
        }

        It 'reports SafeFly-approved regions that are not in the rollout as deliberate r2dScope entries' {
            $r = Get-RolloutScopeReport -Coverage (New-Coverage -PerPipeline @{ SFRP = @('eastus') }) `
                -ApprovedRegions @('eastus', 'westeurope')

            $r2d = @($r.deliberate | Where-Object { $_.kind -eq 'r2dScope' })
            $r2d.Count   | Should -Be 1
            $r2d[0].item | Should -Be 'westeurope'
        }

        It 'does not flag an approved region that IS in the rollout, regardless of casing' {
            $r = Get-RolloutScopeReport -Coverage (New-Coverage -PerPipeline @{ SFRP = @('EastUS') }) `
                -ApprovedRegions @('eastus')

            @($r.deliberate | Where-Object { $_.kind -eq 'r2dScope' }).Count | Should -Be 0
        }
    }

    Context 'Unintended omissions — these must never be presented as normal' {

        It 'classifies missing geographies (L-16) as unintended, not deliberate' {
            $r = Get-RolloutScopeReport -Coverage (New-Coverage -Missing @('Sweden', 'Norway'))

            $r.unintendedCount | Should -Be 2
            $r.hasUnintended   | Should -BeTrue
            @($r.deliberate | Where-Object { $_.item -in @('Sweden', 'Norway') }).Count | Should -Be 0
        }

        It 'classifies stamps the inventory could not validate as unintended' {
            $drift = @(
                [PSCustomObject]@{ stampName = 'sec-01'; reason = 'serviceTag mismatch' },
                [PSCustomObject]@{ stampName = 'neu-03' }
            )

            $r = Get-RolloutScopeReport -Coverage (New-Coverage) -InventoryDrift $drift

            $r.unintendedCount | Should -Be 2
            ($r.unintended | Where-Object { $_.item -eq 'sec-01' }).reason | Should -Be 'serviceTag mismatch'
            ($r.unintended | Where-Object { $_.item -eq 'neu-03' }).kind   | Should -Be 'inventoryDrift'
        }

        It 'keeps the two classes separate when both are present' {
            $cfg = [PSCustomObject]@{
                inventory = [PSCustomObject]@{ ccoaExclusions = [PSCustomObject]@{ stamps = @('eus-05') } }
            }

            $r = Get-RolloutScopeReport -Coverage (New-Coverage -Missing @('Sweden')) `
                -ServiceConfig $cfg -InventoryDrift @([PSCustomObject]@{ stampName = 'sec-01' })

            $r.deliberateCount | Should -Be 1
            $r.unintendedCount | Should -Be 2
        }
    }

    Context 'Format-RolloutScopeNote' {

        It 'renders unintended omissions loudly and above the deliberate list' {
            $cfg = [PSCustomObject]@{
                inventory = [PSCustomObject]@{ ccoaExclusions = [PSCustomObject]@{ stamps = @('eus-05') } }
            }
            $r = Get-RolloutScopeReport -Coverage (New-Coverage -Missing @('Sweden')) -ServiceConfig $cfg

            $html = Format-RolloutScopeNote -Report $r

            $html | Should -Match 'NOT deployed — unintended'
            $html | Should -Match 'Sweden'
            $html | Should -Match 'Deliberately excluded'
            $html.IndexOf('unintended') | Should -BeLessThan $html.IndexOf('Deliberately excluded')
        }

        It 'says so plainly when nothing was excluded' {
            $html = Format-RolloutScopeNote -Report (Get-RolloutScopeReport -Coverage (New-Coverage))

            $html | Should -Match 'No regions or stamps were excluded'
        }

        It 'HTML-encodes item names and reasons' {
            $r = Get-RolloutScopeReport -Coverage (New-Coverage) `
                -InventoryDrift @([PSCustomObject]@{ stampName = '<script>'; reason = 'a&b' })

            $html = Format-RolloutScopeNote -Report $r

            $html | Should -Not -Match '<script>'
            $html | Should -Match '&lt;script&gt;'
            $html | Should -Match 'a&amp;b'
        }
    }

    Context 'Wiring into the shared comms token set' {

        It 'exposes exclusionNoteHtml so the email and Teams paths render the same note' {
            $cfg = [PSCustomObject]@{
                inventory = [PSCustomObject]@{ ccoaExclusions = [PSCustomObject]@{ stamps = @('eus-05') } }
            }

            $vars = Get-ScopeTemplateVars -Coverage (New-Coverage -Missing @('Sweden')) `
                -ServiceConfig $cfg -InventoryDrift @([PSCustomObject]@{ stampName = 'sec-01' })

            $vars.Keys | Should -Contain 'exclusionNoteHtml'
            $vars.exclusionNoteHtml | Should -Match 'Sweden'
            $vars.exclusionNoteHtml | Should -Match 'eus-05'
            $vars.exclusionNoteHtml | Should -Match 'sec-01'
        }

        It 'does not fabricate an exclusion breakdown when coverage has not been computed' {
            $vars = Get-ScopeTemplateVars -ReleaseId 'no-such-release' -StateRoot (Join-Path $TestDrive 'releases')

            $vars.exclusionNoteHtml | Should -Match 'unavailable'
        }
    }
}
