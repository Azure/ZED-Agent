<#
.SYNOPSIS
    Scaffolds the ZED Agent skeleton into a target repository.

.DESCRIPTION
    Copies the ZED Agent skeleton (.github/agents/ZedAgent.agent.md plus the
    entire .github/skills/zed-agent/ directory, minus runtime artifacts) from
    this source location into a target repo.

    The two service configuration files — service-config.json and
    pipeline-catalog.json — are always written EMPTY in the target, regardless
    of what the source repo currently has. The empty skeletons are embedded
    inline below. After install, the release owner populates them either by hand in
    VS Code (the $schema reference gives IntelliSense), by running
    @ZedAgent setup-service in Copilot Chat, or any mix of the two.

.PARAMETER TargetRepoPath
    Absolute path to the root of the repo where ZED should be installed.

.PARAMETER SourcePath
    Optional path to the source ZED files. Defaults to the directory two levels
    above this script.

.PARAMETER Force
    Overwrite existing files in the target. Without -Force, the script aborts
    if any target file already exists.

.PARAMETER WhatIf
    Show what would be copied without actually copying anything.

.EXAMPLE
    pwsh -File Install-Zed.ps1 -TargetRepoPath D:\repos\Mgmt-RecoverySvcs-Foo

.NOTES
    After install, the release owner should:
      1. cd into the target repo
      2. Open `.github/skills/zed-agent/service-config.json` in VS Code and
         fill in whatever you know (schema-backed IntelliSense), and/or
      3. Open `.github/skills/zed-agent/pipeline-catalog.json` and do the same
      4. In Copilot Chat: @ZedAgent setup-service
         (the agent will read what you've already filled in and only ask
         about empty fields)
      5. Force-add and commit:
            git add -f .github/agents/ZedAgent.agent.md
            git add -f .github/skills/zed-agent/
            git add -f .github/skills/teams-chat/
            git add -f .github/skills/setup-service/
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TargetRepoPath,

    [string]$SourcePath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'


# ─── Resolve source ──────────────────────────────────────────────────────────
if (-not $SourcePath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    # scripts/ -> zed-agent/ -> skills/ -> .github/ -> repo root
    $SourcePath = Resolve-Path (Join-Path $scriptDir '..\..\..\..') | Select-Object -ExpandProperty Path
}

$srcAgentMd          = Join-Path $SourcePath '.github\agents\ZedAgent.agent.md'
$srcSkillDir         = Join-Path $SourcePath '.github\skills\zed-agent'
$srcTeamsChatDir     = Join-Path $SourcePath '.github\skills\teams-chat'
$srcSetupServiceDir  = Join-Path $SourcePath '.github\skills\setup-service'

if (-not (Test-Path $srcAgentMd))  { throw "Source agent file not found: $srcAgentMd" }
if (-not (Test-Path $srcSkillDir)) { throw "Source skill directory not found: $srcSkillDir" }
if (-not (Test-Path $srcTeamsChatDir)) { throw "Source teams-chat skill not found: $srcTeamsChatDir (required dependency for Send-TeamsMessage)" }
if (-not (Test-Path $srcSetupServiceDir)) { throw "Source setup-service skill not found: $srcSetupServiceDir (required for the setup-service onboarding wizard)" }

# ─── Resolve target ──────────────────────────────────────────────────────────
if (-not (Test-Path $TargetRepoPath)) { throw "Target repo path does not exist: $TargetRepoPath" }
$TargetRepoPath = Resolve-Path $TargetRepoPath | Select-Object -ExpandProperty Path

if (-not (Test-Path (Join-Path $TargetRepoPath '.git'))) {
    Write-Warning "Target path does not appear to be a git repository (no .git folder). Continuing anyway."
}

$tgtAgentMd          = Join-Path $TargetRepoPath '.github\agents\ZedAgent.agent.md'
$tgtSkillDir         = Join-Path $TargetRepoPath '.github\skills\zed-agent'
$tgtTeamsChatDir     = Join-Path $TargetRepoPath '.github\skills\teams-chat'
$tgtSetupServiceDir  = Join-Path $TargetRepoPath '.github\skills\setup-service'

# Files we never copy from source (runtime artifacts or live configs we'll
# replace with embedded empty skeletons below).
$excludedFromCopy = @(
    'service-config.json',
    'pipeline-catalog.json',
    'state.json',
    'state.json.bak'
)
# Directory names anywhere in the tree to skip wholesale.
$excludedDirs = @('node_modules', 'logs', '.zed-agent')

# ─── Pre-flight ──────────────────────────────────────────────────────────────
$existing = @()
foreach ($candidate in @($tgtAgentMd, (Join-Path $tgtSkillDir 'SKILL.md'))) {
    if (Test-Path $candidate) { $existing += $candidate }
}
if ($existing.Count -gt 0 -and -not $Force) {
    Write-Host "[!] Target already contains ZED files:" -ForegroundColor Yellow
    $existing | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    throw "Use -Force to overwrite. Aborting."
}

# ─── Copy agent.md ───────────────────────────────────────────────────────────
$tgtAgentDir = Split-Path -Parent $tgtAgentMd
if ($PSCmdlet.ShouldProcess($tgtAgentDir, 'Create directory')) {
    New-Item -Type Directory -Path $tgtAgentDir -Force | Out-Null
}
if ($PSCmdlet.ShouldProcess($tgtAgentMd, 'Copy ZedAgent.agent.md')) {
    Copy-Item -Path $srcAgentMd -Destination $tgtAgentMd -Force:$Force
}

# ─── Copy skill directory (excluding live configs, state, runtime dirs) ──────
if ($PSCmdlet.ShouldProcess($tgtSkillDir, 'Create directory')) {
    New-Item -Type Directory -Path $tgtSkillDir -Force | Out-Null
}

Get-ChildItem -Path $srcSkillDir -Recurse -File | ForEach-Object {
    $rel  = $_.FullName.Substring($srcSkillDir.Length).TrimStart('\','/')
    $segs = $rel -split '[\\/]'
    if ($excludedFromCopy -contains $_.Name) {
        Write-Verbose "Skipping live config (will write empty skeleton): $rel"
        return
    }
    if ($segs | Where-Object { $excludedDirs -contains $_ }) {
        Write-Verbose "Skipping runtime dir entry: $rel"
        return
    }
    $dst    = Join-Path $tgtSkillDir $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, 'Create directory')) {
            New-Item -Type Directory -Path $dstDir -Force | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($dst, "Copy $rel")) {
        Copy-Item -Path $_.FullName -Destination $dst -Force:$Force
    }
}

# ─── Copy teams-chat sibling skill (hard dependency for Send-TeamsMessage) ───
if ($PSCmdlet.ShouldProcess($tgtTeamsChatDir, 'Create directory')) {
    New-Item -Type Directory -Path $tgtTeamsChatDir -Force | Out-Null
}
Get-ChildItem -Path $srcTeamsChatDir -Recurse -File | ForEach-Object {
    $rel    = $_.FullName.Substring($srcTeamsChatDir.Length).TrimStart('\','/')
    $segs   = $rel -split '[\\/]'
    if ($segs | Where-Object { $excludedDirs -contains $_ }) {
        Write-Verbose "Skipping runtime dir entry: $rel"
        return
    }
    $dst    = Join-Path $tgtTeamsChatDir $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, 'Create directory')) {
            New-Item -Type Directory -Path $dstDir -Force | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($dst, "Copy teams-chat/$rel")) {
        Copy-Item -Path $_.FullName -Destination $dst -Force:$Force
    }
}

# ─── Copy setup-service sibling skill (one-time onboarding wizard) ───────────
if ($PSCmdlet.ShouldProcess($tgtSetupServiceDir, 'Create directory')) {
    New-Item -Type Directory -Path $tgtSetupServiceDir -Force | Out-Null
}
Get-ChildItem -Path $srcSetupServiceDir -Recurse -File | ForEach-Object {
    $rel    = $_.FullName.Substring($srcSetupServiceDir.Length).TrimStart('\','/')
    $segs   = $rel -split '[\\/]'
    if ($segs | Where-Object { $excludedDirs -contains $_ }) {
        Write-Verbose "Skipping runtime dir entry: $rel"
        return
    }
    $dst    = Join-Path $tgtSetupServiceDir $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, 'Create directory')) {
            New-Item -Type Directory -Path $dstDir -Force | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($dst, "Copy setup-service/$rel")) {
        Copy-Item -Path $_.FullName -Destination $dst -Force:$Force
    }
}

# ─── Write the empty config skeletons (generated from schema) ────────────────
$scriptDir = Split-Path -Parent $PSCommandPath
$generator = Join-Path $scriptDir 'New-EmptyFromSchema.ps1'
foreach ($pair in @(
    @{ Path = (Join-Path $tgtSkillDir 'service-config.json');   Schema = (Join-Path $tgtSkillDir 'service-config.schema.json');   Name = 'service-config.json' }
    @{ Path = (Join-Path $tgtSkillDir 'pipeline-catalog.json'); Schema = (Join-Path $tgtSkillDir 'pipeline-catalog.schema.json'); Name = 'pipeline-catalog.json' }
)) {
    if ((Test-Path $pair.Path) -and -not $Force) {
        Write-Host "[i] Already present (kept as-is): $($pair.Name)" -ForegroundColor Cyan
        continue
    }
    if ($PSCmdlet.ShouldProcess($pair.Path, 'Write empty skeleton (from schema)')) {
        $obj  = & $generator -SchemaPath $pair.Schema
        $json = $obj | ConvertTo-Json -Depth 32
        Set-Content -Path $pair.Path -Value $json -Encoding UTF8
        Write-Host "[+] Generated $($pair.Name) from schema" -ForegroundColor Green
    }
}

# ─── Next-steps banner ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ZED Agent installed into: $TargetRepoPath" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Files placed:" -ForegroundColor White
Write-Host "  .github/agents/ZedAgent.agent.md"
Write-Host "  .github/skills/zed-agent/  (scripts, schema, queries, templates)"
Write-Host "  .github/skills/teams-chat/ (CDP-based Teams messaging — auto-discovers conversation IDs)"
Write-Host "  .github/skills/setup-service/ (one-time onboarding wizard — Copilot CLI skill)"
Write-Host "  .github/skills/zed-agent/service-config.json    [empty]"
Write-Host "  .github/skills/zed-agent/pipeline-catalog.json  [empty]"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open the two empty JSON files in VS Code and pre-fill any fields"
Write-Host "     you already know (the `$schema` reference gives IntelliSense)."
Write-Host "  2. In Copilot Chat:  @ZedAgent setup-service"
Write-Host "     The agent reads what you filled in and only asks about the rest."
Write-Host "     (Or just run it without pre-filling anything — same flow.)"
Write-Host "  3. Use `@ZedAgent setup-service validate` to re-check at any time."
Write-Host ""
Write-Host "Then commit (note -f because .github/ is often gitignored):" -ForegroundColor Cyan
Write-Host "  git add -f .github/agents/ZedAgent.agent.md"
Write-Host "  git add -f .github/skills/zed-agent/"
Write-Host "  git add -f .github/skills/teams-chat/"
Write-Host "  git add -f .github/skills/setup-service/"
Write-Host "  git commit -m `"feat(zed): onboard ZED Agent`""
Write-Host ""
