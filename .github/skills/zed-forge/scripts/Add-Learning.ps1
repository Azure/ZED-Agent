<#
.SYNOPSIS
    Append a new FREEFORM lesson to learnings.md, or mark an existing entry
    implemented (recorded in forge-state.json → implementedLearnings).

.DESCRIPTION
    APPEND (default): append a new lesson in the ZED lessons-learned shape.
      Add-Learning.ps1 -StepCommand "Step 5 canary" -Learning "<symptom/what>" `
                       -RootCause "<why>" -ProposedFix "<how>"

    MARK: record an existing entry (by its 12-char key from Get-Learnings) as
    implemented. Status lives in forge-state.json, keyed by the entry's stable
    hash — the learnings.md text is NOT modified (keys stay stable, file stays clean).
      Add-Learning.ps1 -MarkImplemented <key> -AppliedTo "a.ps1,b.md" -Iteration 2

.PARAMETER LearningsPath  Override. Default <skill>/learnings/learnings.md.
.PARAMETER StatePath      Override. Default <skill>/state/forge-state.json.
#>
[CmdletBinding(DefaultParameterSetName = 'append')]
param(
    [Parameter(ParameterSetName = 'append', Mandatory)][string]$Learning,
    [Parameter(ParameterSetName = 'append')][string]$ProposedFix = '',
    [Parameter(ParameterSetName = 'append')][string]$StepCommand = '',
    [Parameter(ParameterSetName = 'append')][string]$RootCause = '',
    [Parameter(ParameterSetName = 'append')][ValidateSet('owner', 'validation-run', 'lessons-learned', 'agent-discovery')][string]$Source = 'validation-run',

    [Parameter(ParameterSetName = 'mark', Mandatory)][string]$MarkImplemented,
    [Parameter(ParameterSetName = 'mark')][string]$AppliedTo = '',
    [Parameter(ParameterSetName = 'mark')][int]$Iteration = 0,

    [string]$LearningsPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LearningsStore.ps1')
if (-not $LearningsPath) { $LearningsPath = Join-Path $PSScriptRoot '..\learnings\learnings.md' }
if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot '..\state\forge-state.json' }

if ($PSCmdlet.ParameterSetName -eq 'mark') {
    $entries = @(Read-Learnings -Path $LearningsPath -StatePath $StatePath)
    $target = $entries | Where-Object { $_.key -eq $MarkImplemented }
    if (-not $target) { throw "Learning key '$MarkImplemented' not found in $LearningsPath. Run Get-Learnings.ps1 to list keys." }
    $applied = @()
    if ($AppliedTo) { $applied = @($AppliedTo -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    Set-ImplementedLearning -StatePath $StatePath -Record @{
        key       = $MarkImplemented
        title     = $target.title
        iteration = $Iteration
        appliedTo = $applied
        at        = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-Host "Learning $MarkImplemented -> implemented (iter $Iteration; appliedTo: $AppliedTo)"
    return $target
}

# APPEND — freeform block in the ZED lessons-learned shape
$dir = Split-Path $LearningsPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$ts = (Get-Date).ToUniversalTime().ToString('o')
$block = @()
$block += "---"
$block += "**Timestamp**: $ts"
if ($StepCommand) { $block += "**Step/Command**: $StepCommand" }
$block += "**Symptom**: $Learning"
if ($RootCause) { $block += "**Root cause**: $RootCause" }
if ($ProposedFix) { $block += "**Proposed fix**: $ProposedFix" }
$block += "**Source**: $Source"
$blockText = ($block -join "`n")

$existing = if (Test-Path $LearningsPath) { (Get-Content $LearningsPath -Raw -Encoding UTF8).TrimEnd() } else { '# ZED Agent Lessons Learned' }
Set-Content -Path $LearningsPath -Value ("$existing`n`n$blockText`n") -Encoding UTF8

$key = Get-LearningKey -Text (@($block | Where-Object { $_ -notmatch '^\s*---\s*$' }) -join "`n")
Write-Host "Learning added (pending, key $key): $Learning"
return [pscustomobject]@{ key = $key; status = 'pending'; text = $blockText }
