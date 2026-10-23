<#
.SYNOPSIS
    Self-contained smoke test for Test-RunRequirements.ps1 (verifier unit test).
    Writes its OWN minimal catalog + synthetic run artifacts (independent of the
    real seed catalog) and asserts:
      1) a clean golden run PASSES,
      2) an unresolved {{token}} in step-2 sourceBranch FAILS (step.2.capture),
      3) excluding isc-01/ne5s-01 in PublicExcludestamps FAILS (step.10.capture).
    Dependency-free. Exits 0 on success, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
$skill    = Split-Path $PSScriptRoot -Parent
$verifier = Join-Path $skill 'scripts\Test-RunRequirements.ps1'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("zedforge-vtest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$rid  = 'TEST-2026-07'
$relDir = Join-Path $root ".zed-agent/releases/$rid"
$catDir = Join-Path $root '.github/skills/zed-agent'
New-Item -ItemType Directory -Path $relDir -Force | Out-Null
New-Item -ItemType Directory -Path $catDir -Force | Out-Null

# Minimal self-contained catalog (golden syntax; only currentBranch/validateOnly dynamic).
@{
    officialBuild = @{ name = 'Official'; id = 1; sourceBranch = 'refs/heads/{{currentBranch}}'; templateParameters = @{ CloudBuildQueue = 'Q'; debug = 'False' } }
    canary        = @{ 'PROT-SFMC' = @{ name = 'c'; id = 2; sourceBranch = 'refs/heads/{{currentBranch}}'; templateParameters = @{ ArtifactsBranch = '{{currentBranch}}'; CanaryScript = 'true'; Canarystamps = '@("ea-01")'; CanaryRegions = 'regions(eastasia)'; CanarystampsProd = '@("ecy-01","ccy-01")'; ValidateOnlyRollOut = '{{validateOnly}}'; rolloutType = 'normal' } } }
    production    = @{ 'PROT-SFMC' = @{ name = 'p'; id = 3; sourceBranch = 'refs/heads/{{currentBranch}}'; templateParameters = @{ ArtifactsBranch = '{{currentBranch}}'; Publicstamps = '*'; PublicExcludestamps = '@()'; PubRegions = 'regions(eastus2euap,centralus,eastasia)'; SdpType = 'Standard'; ValidateOnlyRollOut = '{{validateOnly}}'; rolloutType = 'normal' } } }
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $catDir 'pipeline-catalog.json') -Encoding UTF8

$branch = 'zedforge/test-2607'
@{ releaseId = $rid; testMode = $true; currentBranch = $branch; commitExcelUrl = 'https://sp/commits.xlsx'; safeFlyId = 'R2D-123' } |
    ConvertTo-Json | Set-Content (Join-Path $relDir 'release.json') -Encoding UTF8

$steps = [ordered]@{}
'1', '2', '4', '5', '6', '10', '13' | ForEach-Object { $steps["$_"] = @{ status = 'completed' } }
'3', '7', '8', '9', '11', '12', '14', '15', '16' | ForEach-Object { $steps["$_"] = @{ status = 'skipped' } }
@{ releaseId = $rid; status = 'completed'; steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $relDir 'state.json') -Encoding UTF8

function New-Capture($excludeStamps, $step5Err = 'Response status code does not indicate success: 400 (Bad Request). | ...No version was found for the pipeline...') {
    @(
        @{ step = 2; pipelineKey = 'officialBuild'; triggered = $true; runId = 111; sourceBranch = "refs/heads/$branch"; postedParameters = @{ CloudBuildQueue = 'Q'; debug = 'False' } },
        @{ step = 5; pipelineKey = 'canary:PROT-SFMC'; triggered = $false; runId = $null; error = $step5Err; postedParameters = @{ ArtifactsBranch = $branch; CanaryScript = 'true'; Canarystamps = '@("ea-01")'; CanaryRegions = 'regions(eastasia)'; CanarystampsProd = '@("ecy-01","ccy-01")'; ValidateOnlyRollOut = 'false'; rolloutType = 'normal' } },
        @{ step = 6; queryRan = $true; rowCount = 0 },
        @{ step = 10; pipelineKey = 'production:PROT-SFMC'; triggered = $false; runId = $null; error = 'Response status code does not indicate success: 400 (Bad Request). | ...No version was found for the pipeline...'; postedParameters = @{ ArtifactsBranch = $branch; Publicstamps = '*'; PublicExcludestamps = $excludeStamps; PubRegions = 'regions(eastus2euap,centralus,eastasia)'; SdpType = 'Standard'; ValidateOnlyRollOut = 'false'; rolloutType = 'normal' } }
    )
}
$captureFile = Join-Path $relDir 'test-run-capture.json'
$fail = $false

(New-Capture '@()') | ConvertTo-Json -Depth 8 | Set-Content $captureFile -Encoding UTF8
$r1 = & $verifier -TargetRepo $root -ReleaseId $rid
if ($r1.verdict -ne 'pass') { Write-Host "FAIL: golden run should PASS (got $($r1.verdict): $([string]::Join(';',@($r1.failedRequirements.detail))))" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: golden run -> pass" -ForegroundColor Green }

$cap2 = New-Capture '@()'; $cap2[0].sourceBranch = 'refs/heads/{{currentBranch}}'
$cap2 | ConvertTo-Json -Depth 8 | Set-Content $captureFile -Encoding UTF8
$r2 = & $verifier -TargetRepo $root -ReleaseId $rid
if ($r2.verdict -ne 'fail' -or (@($r2.failedRequirements.id) -notcontains 'step.2.capture')) { Write-Host "FAIL: unresolved sourceBranch should FAIL step.2.capture" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: unresolved sourceBranch -> fail (step.2.capture)" -ForegroundColor Green }

(New-Capture '@("isc-01","ne5s-01")') | ConvertTo-Json -Depth 8 | Set-Content $captureFile -Encoding UTF8
$r3 = & $verifier -TargetRepo $root -ReleaseId $rid
if ($r3.verdict -ne 'fail' -or (@($r3.failedRequirements.id) -notcontains 'step.10.capture')) { Write-Host "FAIL: isc/ne5s exclusion should FAIL step.10.capture" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: isc/ne5s exclusion -> fail (step.10.capture)" -ForegroundColor Green }

# Scenario 4 — step 5 fails with a NON-artifact error -> acceptance is scoped, so it still FAILS
(New-Capture '@()' 'Response status code does not indicate success: 500 (Internal Server Error).') | ConvertTo-Json -Depth 8 | Set-Content $captureFile -Encoding UTF8
$r4 = & $verifier -TargetRepo $root -ReleaseId $rid
if ($r4.verdict -ne 'fail' -or (@($r4.failedRequirements.id) -notcontains 'step.5.capture')) { Write-Host "FAIL: non-artifact 500 should FAIL step.5.capture" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: non-artifact error -> fail (step.5.capture)" -ForegroundColor Green }

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "`nSMOKE TEST FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nSMOKE TEST PASSED" -ForegroundColor Green; exit 0
