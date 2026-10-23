BeforeAll {
    $script:resolveScript = "$PSScriptRoot\..\scripts\Resolve-StatePaths.ps1"
}

Describe 'Resolve-StatePaths' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        Push-Location $testRoot
    }

    AfterEach { Pop-Location }

    Context 'Local fallback (no .zed-release/)' {
        It 'returns .zed-agent/ paths when .zed-release/ does not exist' {
            $result = & $script:resolveScript -ReleaseId '2026-04'
            $result.StateFile | Should -BeLike '*.zed-agent*'
            $result.StateFile | Should -BeLike '*state.json'
            $result.AuditFile | Should -BeLike '*audit.jsonl'
            $result.IsDurableMode | Should -BeFalse
        }
    }

    Context 'Durable path exists' {
        BeforeEach {
            $durableDir = Join-Path $testRoot '.zed-release/releases/2026-04'
            New-Item -ItemType Directory -Path $durableDir -Force | Out-Null
            @{ releaseId = '2026-04' } | ConvertTo-Json | Set-Content (Join-Path $durableDir 'state.json') -Encoding UTF8
        }

        It 'returns .zed-release/ paths when durable dir exists' {
            $result = & $script:resolveScript -ReleaseId '2026-04'
            $result.DurableBase | Should -BeLike '*.zed-release*'
            $result.IsDurableMode | Should -BeTrue
        }
    }

    Context '-PreferDurable creates structure' {
        It 'creates .zed-release/ directory when PreferDurable is set' {
            $result = & $script:resolveScript -ReleaseId '2026-05' -PreferDurable
            $result.IsDurableMode | Should -BeTrue
            Test-Path (Split-Path $result.StateFile -Parent) | Should -BeTrue
        }
    }

    Context 'Scratch path is always .zed-agent/' {
        It 'returns scratch paths under .zed-agent/' {
            $result = & $script:resolveScript -ReleaseId '2026-04'
            $result.ScratchBase | Should -BeLike '*.zed-agent*'
            $result.LockFile | Should -BeLike '*.zed-agent*'
        }
    }
}
