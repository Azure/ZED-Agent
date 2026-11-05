<#
.SYNOPSIS
    Scaffolds a service-owned release-health skill from the ZED skeleton.

.DESCRIPTION
    Copies templates/service-health-skill/ into <repo>/.github/skills/<SkillName>/:
      SKILL.md            (from SKILL.md.template)
      health-config.json  (from health-config.template.json, $schema -> ../zed-agent/health-config.schema.json)
      queries/*.kql
    Existing files are kept unless -Force. With -UpdateServiceConfig, writes
    releaseHealth.skillPath (and enabled=false until validated) into service-config.json.
    Used by setup-service group 11; the agent then fills every TODO with the owner's answers.

.EXAMPLE
    pwsh .github/skills/zed-agent/scripts/Health/New-ServiceHealthSkill.ps1 -ServiceName BCM -UpdateServiceConfig
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServiceName,
    [string]$SkillName,
    [string]$RepoRoot,
    [switch]$Force,
    [switch]$UpdateServiceConfig
)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..')) }
if (-not $SkillName) { $SkillName = (($ServiceName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) + '-release-health' }
if ($SkillName -notmatch '^[a-z0-9][a-z0-9-]*$') { throw "SkillName '$SkillName' must be lowercase letters, digits and dashes." }
$template = Join-Path $PSScriptRoot '..\..\templates\service-health-skill'
$target = Join-Path $RepoRoot ".github\skills\$SkillName"
$created = [System.Collections.Generic.List[string]]::new(); $kept = [System.Collections.Generic.List[string]]::new()

$tokens = @{ '__SERVICE__' = $ServiceName; '__SKILL_NAME__' = $SkillName; '__SCHEMA_PATH__' = '../zed-agent/health-config.schema.json' }
$map = @(
    @{ From = 'SKILL.md.template'; To = 'SKILL.md' }
    @{ From = 'health-config.template.json'; To = 'health-config.json' }
)
foreach ($q in Get-ChildItem -LiteralPath (Join-Path $template 'queries') -Filter '*.kql') { $map += @{ From = "queries\$($q.Name)"; To = "queries\$($q.Name)" } }
foreach ($m in $map) {
    $dest = Join-Path $target $m.To
    if ((Test-Path -LiteralPath $dest) -and -not $Force) { $kept.Add($m.To); continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    $text = Get-Content -LiteralPath (Join-Path $template $m.From) -Raw -Encoding UTF8
    foreach ($k in $tokens.Keys) { $text = $text.Replace($k, $tokens[$k]) }
    Set-Content -LiteralPath $dest -Value $text -Encoding UTF8 -NoNewline
    $created.Add($m.To)
}

$skillPath = ".github/skills/$SkillName"
if ($UpdateServiceConfig) {
    $svcPath = Join-Path $RepoRoot '.github\skills\zed-agent\service-config.json'
    $svc = Get-Content -LiteralPath $svcPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $svc.PSObject.Properties['releaseHealth'] -or -not $svc.releaseHealth) {
        $svc | Add-Member -NotePropertyName releaseHealth -NotePropertyValue ([pscustomobject]@{ enabled = $false; mode = 'shadow'; skillPath = $skillPath }) -Force
    } else {
        $svc.releaseHealth | Add-Member -NotePropertyName skillPath -NotePropertyValue $skillPath -Force
    }
    $svc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $svcPath -Encoding UTF8
}
[pscustomobject]@{ skillPath = $skillPath; skillDir = $target; created = $created.ToArray(); kept = $kept.ToArray() }
