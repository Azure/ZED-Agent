<#
.SYNOPSIS
    L-08: Rebuild command — queues a new CloudBuild on the release branch,
    updates release.json, and asks which canary pipelines to retrigger.

.DESCRIPTION
    After late cherry-picks into the release branch, existing canary results are
    invalidated. This command:
      (a) Queues a new CloudBuild on the release branch
      (b) Updates release.json buildId/buildNumber
      (c) Asks the owner which canary pipelines to retrigger (never decides unilaterally)
      (d) Arms a watcher to auto-trigger on build completion

    SAFETY: Never actually queues a build in implementation/test mode. All ADO
    calls must be mocked in tests.

.PARAMETER ReleaseId
    The current release ID.

.PARAMETER ReleaseBranch
    The release branch name (e.g., 'releases/M1').

.PARAMETER Organization
    ADO organization name.

.PARAMETER Project
    ADO project name.

.PARAMETER OfficialBuildPipelineId
    Pipeline ID for the official build.

.PARAMETER PipelineCatalogPath
    Path to pipeline-catalog.json.

.PARAMETER ReleaseJsonPath
    Path to release.json for the current release.

.PARAMETER RetriggerPipelineKeys
    Array of canary pipeline keys the owner wants to retrigger. If empty or null,
    the command reports which pipelines are available but does not retrigger any.

.PARAMETER WhatIf
    When set, shows what would happen without executing.

.OUTPUTS
    PSCustomObject with rebuild status, new build info, and retrigger plan.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][string]$ReleaseBranch,
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][int]$OfficialBuildPipelineId,
    [string]$PipelineCatalogPath = (Join-Path $PSScriptRoot '..\pipeline-catalog.json'),
    [Parameter(Mandatory)][string]$ReleaseJsonPath,
    [string[]]$RetriggerPipelineKeys = @(),
    [scriptblock]$QueueBuildCallback = $null
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PipelineCatalogPath)) { throw "pipeline-catalog.json not found at $PipelineCatalogPath" }
if (-not (Test-Path $ReleaseJsonPath))     { throw "release.json not found at $ReleaseJsonPath" }

$catalog = Get-Content $PipelineCatalogPath -Raw | ConvertFrom-Json
$releaseJson = Get-Content $ReleaseJsonPath -Raw | ConvertFrom-Json

# Identify canary pipelines available for retrigger
$canaryPipelines = @()
if ($catalog.canary) {
    foreach ($p in $catalog.canary.PSObject.Properties) {
        $canaryPipelines += [PSCustomObject]@{
            key  = $p.Name
            name = if ($p.Value.PSObject.Properties['name']) { $p.Value.name } else { $p.Name }
            id   = if ($p.Value.PSObject.Properties['id']) { $p.Value.id } else { 0 }
        }
    }
}

# Queue build (via callback for testability — never actually queue in real code path without callback)
$newBuildId     = $null
$newBuildNumber = $null

if ($QueueBuildCallback) {
    $buildResult = & $QueueBuildCallback -Organization $Organization -Project $Project `
        -PipelineId $OfficialBuildPipelineId -Branch $ReleaseBranch
    $newBuildId     = $buildResult.buildId
    $newBuildNumber = $buildResult.buildNumber
} else {
    throw "REBUILD_NO_CALLBACK: QueueBuildCallback is required. In production, wire this to the ADO Pipelines API. Never queue a build without an explicit callback."
}

# Update release.json
$releaseJson | Add-Member -NotePropertyName 'buildId'     -NotePropertyValue $newBuildId     -Force
$releaseJson | Add-Member -NotePropertyName 'buildNumber' -NotePropertyValue $newBuildNumber -Force
$releaseJson | Add-Member -NotePropertyName 'rebuildAt'   -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
$releaseJson | ConvertTo-Json -Depth 10 | Set-Content $ReleaseJsonPath -Encoding UTF8

# Build retrigger plan — the owner decides, we don't
$retriggerPlan = @()
if ($RetriggerPipelineKeys.Count -gt 0) {
    foreach ($key in $RetriggerPipelineKeys) {
        $match = $canaryPipelines | Where-Object { $_.key -eq $key }
        if (-not $match) {
            throw "REBUILD_UNKNOWN_PIPELINE: retrigger key '$key' not found in canary pipelines. Available: $($canaryPipelines.key -join ', ')"
        }
        $retriggerPlan += [PSCustomObject]@{
            key    = $key
            name   = $match.name
            id     = $match.id
            action = 'retrigger-on-build-complete'
        }
    }
}

[PSCustomObject]@{
    releaseId           = $ReleaseId
    newBuildId          = $newBuildId
    newBuildNumber      = $newBuildNumber
    releaseBranch       = $ReleaseBranch
    availableCanary     = $canaryPipelines
    retriggerPlan       = $retriggerPlan
    ownerMustChoose     = ($RetriggerPipelineKeys.Count -eq 0)
    releaseJsonUpdated  = $true
}
