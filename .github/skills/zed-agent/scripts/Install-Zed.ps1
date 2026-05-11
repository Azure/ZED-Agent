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
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TargetRepoPath,

    [string]$SourcePath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ─── Empty skeletons (embedded so the installer works even when the source
#     repo's live configs are populated with another service's data) ─────────

$EmptyServiceConfig = @'
{
  "$schema": "./service-config.schema.json",
  "_comment": "Fill in fields you know directly here (VS Code's $schema gives autocomplete) and/or run `@ZedAgent setup-service` — it reads this file first and only prompts for empty fields. Run `@ZedAgent setup-service validate` at any time to check the file.",
  "version": "1.0",

  "service": {
    "name": "",
    "displayName": "",
    "description": ""
  },

  "serviceTreeIds": {
    "safefly": "",
    "ev2": {
      "Prod": "",
      "Fairfax": "",
      "Mooncake": ""
    }
  },

  "ado": {
    "organization": "",
    "project": "",
    "repository": "",
    "branchPrefix": "",
    "baseBranch": "develop",
    "releaseBranchPattern": ""
  },

  "kusto": {
    "bvt": {
      "cluster": "",
      "database": "",
      "queryFile": "",
      "queryVariables": {}
    },
    "canary": {
      "cluster": "",
      "database": "",
      "serviceFilter": ""
    }
  },

  "commitExcel": {
    "sheetNameTemplate": "",
    "sharePointFolder": "",
    "excludeAuthors": []
  },

  "sharepoint": {
    "sitePath": ""
  },

  "notifications": {
    "groups": {
      "permanent": [],
      "cc": [],
      "releaseOwner": [],
      "teams": [],
      "teamsExtended": []
    },
    "routing": {
      "reminder":               { "emailGroups": ["permanent"], "teamsGroups": ["teams"] },
      "build-status":           { "emailGroups": ["owner"] },
      "commit-request":         { "teamsGroups": ["teamsExtended"] },
      "canary-status":          { "emailGroups": ["permanent"] },
      "bvt-check":              {},
      "rollback-status":        { "emailGroups": ["permanent"] },
      "rollforward-status":     { "emailGroups": ["permanent"] },
      "create-r2d":             { "emailGroups": ["releaseOwner"], "ccGroups": ["cc"] },
      "production-rollout":     { "emailGroups": ["permanent"] },
      "ev2-stage-progress":     { "emailGroups": ["permanent", "owner"] },
      "ev2-promotion-reminder": { "emailGroups": ["owner"] },
      "timeout-alert":          { "emailGroups": ["releaseOwner"] }
    }
  },

  "safefly": {
    "titleTemplate": "[MAB][{serviceName}] {serviceDisplayName} monthly release for {month}-{yy}",
    "descriptionTemplate": "Monthly {serviceName} release {releaseId}",
    "tags": [],
    "additionalNotifiers": [],
    "genevaMdmLink": ""
  },

  "operational": {
    "buildTimeoutMinutes": 300,
    "bvtWaitHours": 24,
    "bvtQueryTimeoutMinutes": 120,
    "excelCompletionTimeoutHours": 48,
    "canaryBakeTimeHours": 24,
    "reminderBeforeCutDays": 2,
    "canaryRegions": [],
    "watcherPollIntervalSeconds": 3600,
    "watcherTestModePollIntervalSeconds": 1800,
    "watcherMaxRetries": 3,
    "watcherTaskPrefix": "ZED-ReleaseWatcher"
  },

  "stepGates": {
    "_comment": "Per-step approval gates. true = owner must approve before next step. false = auto-advance. Step 14 is always true (non-overridable). Override at runtime via `gate on/off <step>`.",
    "1-send-reminder":             false,
    "2-cut-branch":                false,
    "3-wait-build":                false,
    "4-collect-commits":           false,
    "5-deploy-canary":             false,
    "6-bvt-check":                 true,
    "7-rollback":                  false,
    "8-post-rollback-bvt":         false,
    "9-post-rollback-signoff":     true,
    "10-roll-forward":             false,
    "11-post-rollforward-bvt":     false,
    "12-post-rollforward-signoff": true,
    "13-create-r2d":               false,
    "14-crb-review":               true,
    "15-production-rollout":       false,
    "16-merge-back":               false
  },

  "agentFeedbackEmail": "gwazire@microsoft.com"
}
'@

$EmptyPipelineCatalog = @'
{
  "$schema": "./pipeline-catalog.schema.json",
  "_comment": "Fill in pipeline IDs and templateParameters here directly, and/or run `@ZedAgent setup-service` — it reads this file first and only prompts for empty/missing entries. templateParameters is a free-form key-value map: the agent passes whatever keys you provide verbatim to ADO. Use {{currentBranch}}, {{excludeStamps}}, {{pubRegions}}, {{ffStamps}}, {{ffRegions}}, {{sdpType}}, {{validateOnly}} as runtime placeholders — the agent substitutes these per release. The _examples block at the bottom shows expected entry shape; delete it once your real entries are in.",
  "description": "Pipeline definitions for <ServiceName> release automation.",

  "canaryRouting": {
    "_comment": "How Steps 5 (canary deploy) and 7 (rollback) pick which pipelines to trigger. mode='static' (default): the agent triggers EVERY entry under canary.* in parallel. mode='cluster-type': the agent runs a Kusto query, parses the DeploymentUnit suffix (e.g., '-sfmc', '-sf'), and uses clusterTypeMap to route each suffix to a canary pipeline key. Use 'static' if your canary pipelines are split by region (one pipeline per region). Use 'cluster-type' if a single canary region hosts multiple cluster-type variants served by separate pipelines (e.g., PROT SFMC/SFRP).",
    "mode": "static"
  },

  "productionRouting": {
    "_comment": "How Step 10 (roll-forward — PROD pipelines targeting canary regions) picks which pipelines to trigger. Same mode semantics as canaryRouting but reads from production.*. Independent from canaryRouting because many services have asymmetric topology (e.g., N canary pipelines + 1 production pipeline).",
    "mode": "static"
  },

  "ev2ServiceTreeIds": {
    "Prod":     "",
    "Fairfax":  "",
    "Mooncake": ""
  },

  "ev2ServiceGroups": {
  },

  "ev2CloudCoverage": {
  },

  "officialBuild": {
    "name": "",
    "id": 0,
    "sourceBranch": "refs/heads/{{currentBranch}}",
    "templateParameters": {
    }
  },

  "canary": {
  },

  "production": {
  },

  "_examples": {
    "_comment": "Reference shapes — REMOVE this _examples block once you've populated canary/production above.",
    "canaryEntry": {
      "name": "<Repo>-<Service>-Canary-SDP-<Variant>",
      "id": 0,
      "sourceBranch": "refs/heads/develop",
      "templateParameters": {
        "rolloutType": "normal",
        "ArtifactsBranch": "{{currentBranch}}"
      }
    },
    "productionEntry": {
      "name": "<Repo>-<Service>-PROD-SDP-<Variant>",
      "id": 0,
      "sourceBranch": "refs/heads/develop",
      "templateParameters": {
        "BranchPrefix": "<repo_branch_prefix>",
        "rolloutType": "normal",
        "ArtifactsBranch": "{{currentBranch}}",
        "PublicExcludestamps": "{{excludeStamps}}",
        "PubRegions": "{{pubRegions}}",
        "FFstamps": "{{ffStamps}}",
        "FFRegions": "{{ffRegions}}",
        "SdpType": "{{sdpType}}",
        "ValidateOnlyRollOut": "{{validateOnly}}"
      }
    }
  }
}
'@

# ─── Resolve source ──────────────────────────────────────────────────────────
if (-not $SourcePath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    # scripts/ -> zed-agent/ -> skills/ -> .github/ -> repo root
    $SourcePath = Resolve-Path (Join-Path $scriptDir '..\..\..\..') | Select-Object -ExpandProperty Path
}

$srcAgentMd  = Join-Path $SourcePath '.github\agents\ZedAgent.agent.md'
$srcSkillDir = Join-Path $SourcePath '.github\skills\zed-agent'

if (-not (Test-Path $srcAgentMd))  { throw "Source agent file not found: $srcAgentMd" }
if (-not (Test-Path $srcSkillDir)) { throw "Source skill directory not found: $srcSkillDir" }

# ─── Resolve target ──────────────────────────────────────────────────────────
if (-not (Test-Path $TargetRepoPath)) { throw "Target repo path does not exist: $TargetRepoPath" }
$TargetRepoPath = Resolve-Path $TargetRepoPath | Select-Object -ExpandProperty Path

if (-not (Test-Path (Join-Path $TargetRepoPath '.git'))) {
    Write-Warning "Target path does not appear to be a git repository (no .git folder). Continuing anyway."
}

$tgtAgentMd  = Join-Path $TargetRepoPath '.github\agents\ZedAgent.agent.md'
$tgtSkillDir = Join-Path $TargetRepoPath '.github\skills\zed-agent'

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

# ─── Write the empty config skeletons ────────────────────────────────────────
foreach ($pair in @(
    @{ Path = (Join-Path $tgtSkillDir 'service-config.json');   Body = $EmptyServiceConfig;   Name = 'service-config.json' }
    @{ Path = (Join-Path $tgtSkillDir 'pipeline-catalog.json'); Body = $EmptyPipelineCatalog; Name = 'pipeline-catalog.json' }
)) {
    if ((Test-Path $pair.Path) -and -not $Force) {
        Write-Host "[i] Already present (kept as-is): $($pair.Name)" -ForegroundColor Cyan
        continue
    }
    if ($PSCmdlet.ShouldProcess($pair.Path, 'Write empty skeleton')) {
        Set-Content -Path $pair.Path -Value $pair.Body -Encoding UTF8 -NoNewline
        Write-Host "[+] Wrote empty $($pair.Name)" -ForegroundColor Green
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
Write-Host "  git commit -m `"feat(zed): onboard ZED Agent`""
Write-Host ""
