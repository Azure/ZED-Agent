<#
.SYNOPSIS
    Builds a Reverse-Integration (RI) or Forward-Integration (FI) merge branch for
    Step 2 sub-phases 2a / 2b (services with CONFIG[ado.integration.enabled] = true).

.DESCRIPTION
    Creates <IntegrationBranch> from <Remote>/<TargetBranch>, merges <Remote>/<SourceBranch>
    into it, and resolves the result with two deterministic rules:

      1. PRESERVE PATHS — everything under -PreservePaths (default '.config') is kept
         exactly as it is on the TARGET branch. This applies to conflicted files AND to
         files the source would have changed cleanly (they are reverted to target; files
         the source added there are removed).
            RI (master -> develop): develop's .config is kept.
            FI (develop -> master): master's .config is kept.

      2. NEWEST EDIT WINS (per file) — for every other conflicted file, the side whose
         most recent commit touching that file is newer (committer time) wins. Only the
         conflicting hunks are taken from the winner (git merge-file --ours/--theirs);
         non-conflicting changes from both sides are kept. If a hunk-level merge is not
         possible (binary file, delete-vs-modify, add/add without content merge) the
         winner's whole file (or its deletion) is taken. Ties go to the target branch.

    The merge runs in a throw-away `git worktree`, so the caller's checkout is never
    touched. With -Push the merge commit is pushed to <Remote>/<IntegrationBranch>; the
    caller (ZED Step 2) then raises the PR via ADO MCP using the returned summary.

    Idempotency:
      - Source already contained in target  → Status 'up-to-date' (no branch, no PR).
      - Remote integration branch already exists and already contains source → Status
        'reused' (nothing re-merged; caller re-uses the existing branch / PR).
      - Remote integration branch exists but does NOT contain source → throws.

.PARAMETER Direction
    'RI' or 'FI'. Only used for labels / commit message.

.PARAMETER SourceBranch
    Branch being merged in (RI: master, FI: develop). Short name, no refs/heads/.

.PARAMETER TargetBranch
    Branch the PR will target (RI: develop, FI: master). Short name.

.PARAMETER IntegrationBranch
    Name of the branch to create and push (e.g. 'zed/bcm-2611-ri-master-to-develop').

.PARAMETER RepoPath
    Local clone of the service repo. Defaults to the current directory.

.PARAMETER PreservePaths
    Repo-relative paths whose TARGET version always wins. Default: '.config'.

.PARAMETER Push
    Push the merge commit to <Remote>/<IntegrationBranch>. Without it the run is a
    dry-run (test mode): the merge + resolution is computed and reported, then discarded.

.PARAMETER ReportPath
    Optional path for the JSON report. A Markdown summary (PR description body) is written
    next to it with the same base name and a .md extension.

.OUTPUTS
    PSCustomObject: direction, sourceBranch, targetBranch, integrationBranch, status
    ('merged' | 'up-to-date' | 'reused'), sourceSha, targetSha, headSha, pushed,
    conflicts[], preservedFiles[], reviewFiles[], summaryMarkdown.

.EXAMPLE
    & .\Invoke-BranchIntegration.ps1 -Direction RI -SourceBranch master -TargetBranch develop `
        -IntegrationBranch 'zed/bcm-2611-ri-master-to-develop' -Push `
        -ReportPath .zed-agent/releases/2026-11/integration-ri.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('RI', 'FI')][string]$Direction,
    [Parameter(Mandatory)][string]$SourceBranch,
    [Parameter(Mandatory)][string]$TargetBranch,
    [Parameter(Mandatory)][string]$IntegrationBranch,
    [string]$RepoPath = (Get-Location).Path,
    [string]$Remote = 'origin',
    [string[]]$PreservePaths = @('.config'),
    [switch]$Push,
    [string]$ReportPath,
    [string]$CommitMessage
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$WorkDir = $RepoPath,
        [switch]$AllowFail
    )
    # Native stderr must not turn into terminating errors (PS 5.1 + EAP Stop).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $WorkDir -c core.quotepath=false @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $lines = @($out | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($GitArgs -join ' ') failed (exit $code): $($lines -join [Environment]::NewLine)"
    }
    [pscustomobject]@{ Code = $code; Out = $lines }
}

function Test-UnderPreservePath {
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    foreach ($pp in $PreservePaths) {
        if ([string]::IsNullOrWhiteSpace($pp)) { continue }
        $norm = ($pp -replace '\\', '/').TrimEnd('/')
        if ($p -ieq $norm -or $p.StartsWith("$norm/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-LastCommitTime {
    param([string]$Ref, [string]$Path)
    $r = Invoke-Git -GitArgs @('log', '-1', '--format=%ct', $Ref, '--', $Path) -AllowFail
    $v = ($r.Out | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    if ($v) { return [long]$v } else { return [long]0 }
}

function ConvertTo-IsoTime {
    param([long]$Epoch)
    if ($Epoch -le 0) { return $null }
    [DateTimeOffset]::FromUnixTimeSeconds($Epoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$null = Invoke-Git -GitArgs @('rev-parse', '--git-dir')

if (-not $CommitMessage) {
    $CommitMessage = "${Direction}: Merge $SourceBranch into $TargetBranch (ZED)"
}

# --- Fetch the exact refs we merge (explicit refspecs keep remote-tracking refs fresh) ---
foreach ($b in @($SourceBranch, $TargetBranch)) {
    $null = Invoke-Git -GitArgs @('fetch', '--quiet', $Remote, "+refs/heads/${b}:refs/remotes/$Remote/$b")
}
$sourceSha = (Invoke-Git -GitArgs @('rev-parse', "refs/remotes/$Remote/$SourceBranch")).Out[0].Trim()
$targetSha = (Invoke-Git -GitArgs @('rev-parse', "refs/remotes/$Remote/$TargetBranch")).Out[0].Trim()

$result = [ordered]@{
    direction         = $Direction
    sourceBranch      = $SourceBranch
    targetBranch      = $TargetBranch
    integrationBranch = $IntegrationBranch
    status            = $null
    sourceSha         = $sourceSha
    targetSha         = $targetSha
    headSha           = $null
    pushed            = $false
    preservePaths     = @($PreservePaths)
    conflicts         = @()
    preservedFiles    = @()
    reviewFiles       = @()
    generatedAt       = (Get-Date).ToUniversalTime().ToString('o')
    summaryMarkdown   = $null
}

function Write-Report {
    param($Res)
    $md = New-Object System.Text.StringBuilder
    $arrow = "$($Res.sourceBranch) → $($Res.targetBranch)"
    [void]$md.AppendLine("## $($Res.direction): $arrow")
    [void]$md.AppendLine()
    switch ($Res.status) {
        'up-to-date' { [void]$md.AppendLine("``$($Res.targetBranch)`` already contains ``$($Res.sourceBranch)`` ($($Res.sourceSha.Substring(0,8))). No integration needed.") }
        'reused'     { [void]$md.AppendLine("Re-using existing integration branch ``$($Res.integrationBranch)`` (head $($Res.headSha.Substring(0,8))), which already contains ``$($Res.sourceBranch)``.") }
        default {
            [void]$md.AppendLine("Integration branch ``$($Res.integrationBranch)`` created from ``$($Res.targetBranch)`` ($($Res.targetSha.Substring(0,8))) with ``$($Res.sourceBranch)`` ($($Res.sourceSha.Substring(0,8))) merged in. Generated by ZED.")
            [void]$md.AppendLine()
            $ppList = (@($Res.preservePaths) | ForEach-Object { '`' + $_ + '`' }) -join ', '
            [void]$md.AppendLine("**Rules applied**")
            [void]$md.AppendLine("- Kept ``$($Res.targetBranch)`` version of: $ppList")
            [void]$md.AppendLine("- Other conflicts: newest edit wins per file (last commit time on each branch); only conflicting hunks are taken from the winner. Ties go to ``$($Res.targetBranch)``.")
            [void]$md.AppendLine()
            $pf = @($Res.preservedFiles)
            [void]$md.AppendLine("**Preserved from ``$($Res.targetBranch)`` (non-conflicting source changes reverted): $($pf.Count)**")
            foreach ($f in ($pf | Select-Object -First 50)) { [void]$md.AppendLine("- ``$f``") }
            if ($pf.Count -gt 50) { [void]$md.AppendLine("- … and $($pf.Count - 50) more (see report JSON)") }
            [void]$md.AppendLine()
            $cf = @($Res.conflicts)
            [void]$md.AppendLine("**Conflicts auto-resolved: $($cf.Count)**")
            if ($cf.Count -gt 0) {
                [void]$md.AppendLine()
                [void]$md.AppendLine("| File | Kept | Why | $($Res.sourceBranch) last commit | $($Res.targetBranch) last commit | Resolution |")
                [void]$md.AppendLine("|---|---|---|---|---|---|")
                foreach ($c in ($cf | Select-Object -First 200)) {
                    $kept = if ($c.winner -eq 'source') { $Res.sourceBranch } else { $Res.targetBranch }
                    [void]$md.AppendLine("| ``$($c.path)`` | $kept | $($c.reason) | $($c.sourceLastCommit) | $($c.targetLastCommit) | $($c.resolution) |")
                }
                if ($cf.Count -gt 200) { [void]$md.AppendLine("| … $($cf.Count - 200) more | | | | | |") }
            }
            $rf = @($Res.reviewFiles)
            if ($rf.Count -gt 0) {
                [void]$md.AppendLine()
                [void]$md.AppendLine("**⚠ Please review (whole-file pick or deletion — the other side's edits to these files were dropped): $($rf.Count)**")
                foreach ($f in $rf) { [void]$md.AppendLine("- ``$f``") }
            }
        }
    }
    $Res.summaryMarkdown = $md.ToString()

    if ($ReportPath) {
        $dir = Split-Path -Parent $ReportPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]$Res | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
        $mdPath = [System.IO.Path]::ChangeExtension($ReportPath, '.md')
        $Res.summaryMarkdown | Set-Content -LiteralPath $mdPath -Encoding UTF8
    }
    return [pscustomobject]$Res
}

# --- Nothing to integrate? ---
$isAncestor = Invoke-Git -GitArgs @('merge-base', '--is-ancestor', $sourceSha, $targetSha) -AllowFail
if ($isAncestor.Code -eq 0) {
    $result.status = 'up-to-date'
    $result.headSha = $targetSha
    return Write-Report $result
}

# --- Integration branch already on the remote? (resume after crash / ack retry) ---
$remoteHead = Invoke-Git -GitArgs @('ls-remote', '--heads', $Remote, "refs/heads/$IntegrationBranch")
if (@($remoteHead.Out | Where-Object { $_ -match '\S' }).Count -gt 0) {
    $null = Invoke-Git -GitArgs @('fetch', '--quiet', $Remote, "+refs/heads/${IntegrationBranch}:refs/remotes/$Remote/$IntegrationBranch")
    $intSha = (Invoke-Git -GitArgs @('rev-parse', "refs/remotes/$Remote/$IntegrationBranch")).Out[0].Trim()
    $contains = Invoke-Git -GitArgs @('merge-base', '--is-ancestor', $sourceSha, $intSha) -AllowFail
    if ($contains.Code -eq 0) {
        $result.status = 'reused'
        $result.headSha = $intSha
        $result.pushed = $true
        return Write-Report $result
    }
    throw "Remote branch '$IntegrationBranch' already exists but does not contain $Remote/$SourceBranch ($($sourceSha.Substring(0,8))). Delete it or use a different integration branch name."
}

# --- Merge in a throw-away worktree ---
$wt = Join-Path ([System.IO.Path]::GetTempPath()) ("zed-int-{0}-{1}" -f $Direction.ToLower(), [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = Invoke-Git -GitArgs @('worktree', 'add', '--quiet', '-B', $IntegrationBranch, $wt, $targetSha)

try {
    $merge = Invoke-Git -WorkDir $wt -GitArgs @('merge', '--no-ff', '--no-commit', '-m', $CommitMessage, $sourceSha) -AllowFail
    if ($merge.Code -ne 0 -and $merge.Code -ne 1) {
        throw "git merge failed (exit $($merge.Code)): $($merge.Out -join [Environment]::NewLine)"
    }

    # Unmerged index entries: "<mode> <sha> <stage>\t<path>"
    $unmerged = [ordered]@{}
    foreach ($line in (Invoke-Git -WorkDir $wt -GitArgs @('ls-files', '-u')).Out) {
        if ($line -notmatch '^(\d+) ([0-9a-f]+) ([123])\t(.+)$') { continue }
        $path = $Matches[4]
        if (-not $unmerged.Contains($path)) { $unmerged[$path] = @{} }
        $unmerged[$path][[int]$Matches[3]] = $Matches[2]
    }
    if ($merge.Code -eq 1 -and $unmerged.Count -eq 0) {
        throw "git merge reported failure but left no conflicted files: $($merge.Out -join [Environment]::NewLine)"
    }

    $conflicts = New-Object System.Collections.Generic.List[object]
    $review = New-Object System.Collections.Generic.List[string]

    foreach ($path in $unmerged.Keys) {
        $stages = $unmerged[$path]
        $tSrc = Get-LastCommitTime -Ref $sourceSha -Path $path
        $tTgt = Get-LastCommitTime -Ref $targetSha -Path $path

        if (Test-UnderPreservePath $path) {
            $winner = 'target'; $reason = 'preserve-path'
        } elseif ($tSrc -gt $tTgt) {
            $winner = 'source'; $reason = 'newer-on-source'
        } elseif ($tTgt -gt $tSrc) {
            $winner = 'target'; $reason = 'newer-on-target'
        } else {
            $winner = 'target'; $reason = 'tie-target-kept'
        }
        $winStage  = if ($winner -eq 'target') { 2 } else { 3 }
        $loseStage = if ($winner -eq 'target') { 3 } else { 2 }
        $sideFlag  = if ($winner -eq 'target') { '--ours' } else { '--theirs' }

        if (-not $stages.ContainsKey($winStage)) {
            $null = Invoke-Git -WorkDir $wt -GitArgs @('rm', '--quiet', '--force', '--', $path)
            $resolution = 'deleted (winner deleted the file)'
            if ($reason -ne 'preserve-path') { $review.Add($path) }
        } elseif (-not $stages.ContainsKey($loseStage) -or $reason -eq 'preserve-path') {
            $null = Invoke-Git -WorkDir $wt -GitArgs @('checkout', $sideFlag, '--', $path)
            $null = Invoke-Git -WorkDir $wt -GitArgs @('add', '--force', '--', $path)
            $resolution = 'whole file'
            if ($reason -ne 'preserve-path') { $review.Add($path) }
        } else {
            # Hunk-level: keep clean changes from both sides, take conflicting hunks from winner.
            $tmp = (Invoke-Git -WorkDir $wt -GitArgs @('checkout-index', '--stage=all', '--temp', '--', $path)).Out |
                Where-Object { $_ -match "\t" } | Select-Object -First 1
            $names = ($tmp -split "`t")[0] -split ' '
            $baseTmp = if ($names[0] -ne '.') { Join-Path $wt $names[0] } else { $null }
            $oursTmp = Join-Path $wt $names[1]
            $theirsTmp = Join-Path $wt $names[2]
            $emptyBase = $null
            if (-not $baseTmp) {
                $emptyBase = Join-Path $wt ('.zed-empty-base-' + [guid]::NewGuid().ToString('N'))
                [System.IO.File]::WriteAllBytes($emptyBase, [byte[]]@())
                $baseTmp = $emptyBase
            }
            try {
                $mf = Invoke-Git -WorkDir $wt -GitArgs @('merge-file', $sideFlag, '-L', $TargetBranch, '-L', 'base', '-L', $SourceBranch, $oursTmp, $baseTmp, $theirsTmp) -AllowFail
                if ($mf.Code -eq 0) {
                    Copy-Item -LiteralPath $oursTmp -Destination (Join-Path $wt $path) -Force
                    $null = Invoke-Git -WorkDir $wt -GitArgs @('add', '--force', '--', $path)
                    $resolution = 'conflicting hunks from winner'
                } else {
                    $null = Invoke-Git -WorkDir $wt -GitArgs @('checkout', $sideFlag, '--', $path)
                    $null = Invoke-Git -WorkDir $wt -GitArgs @('add', '--force', '--', $path)
                    $resolution = 'whole file (not text-mergeable)'
                    $review.Add($path)
                }
            } finally {
                foreach ($f in @($oursTmp, $theirsTmp, $baseTmp)) {
                    if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force }
                }
            }
        }

        $conflicts.Add([pscustomobject]@{
            path             = $path
            winner           = $winner
            reason           = $reason
            resolution       = $resolution
            sourceLastCommit = ConvertTo-IsoTime $tSrc
            targetLastCommit = ConvertTo-IsoTime $tTgt
        })
    }

    # Preserve paths: revert any non-conflicting source change under them to the target version.
    $preserved = New-Object System.Collections.Generic.List[string]
    foreach ($pp in $PreservePaths) {
        if ([string]::IsNullOrWhiteSpace($pp)) { continue }
        $changed = (Invoke-Git -WorkDir $wt -GitArgs @('diff', '--cached', '--name-only', '--no-renames', $targetSha, '--', $pp)).Out |
            Where-Object { $_ -match '\S' }
        foreach ($f in $changed) {
            $inTarget = (Invoke-Git -WorkDir $wt -GitArgs @('cat-file', '-e', "${targetSha}:$f") -AllowFail).Code -eq 0
            if ($inTarget) {
                $null = Invoke-Git -WorkDir $wt -GitArgs @('checkout', $targetSha, '--', $f)
            } else {
                $null = Invoke-Git -WorkDir $wt -GitArgs @('rm', '--quiet', '--force', '--', $f)
            }
            $preserved.Add($f)
        }
    }

    $left = (Invoke-Git -WorkDir $wt -GitArgs @('diff', '--name-only', '--diff-filter=U')).Out | Where-Object { $_ -match '\S' }
    if (@($left).Count -gt 0) {
        throw "Unresolved conflicts remain after auto-resolution: $($left -join ', ')"
    }

    $null = Invoke-Git -WorkDir $wt -GitArgs @('commit', '--quiet', '-m', $CommitMessage)
    $headSha = (Invoke-Git -WorkDir $wt -GitArgs @('rev-parse', 'HEAD')).Out[0].Trim()

    if ($Push) {
        $null = Invoke-Git -WorkDir $wt -GitArgs @('push', '--quiet', $Remote, "HEAD:refs/heads/$IntegrationBranch")
        $result.pushed = $true
    }

    $result.status = 'merged'
    $result.headSha = $headSha
    $result.conflicts = $conflicts.ToArray()
    $result.preservedFiles = $preserved.ToArray()
    $result.reviewFiles = [string[]]@($review.ToArray() | Select-Object -Unique)
} finally {
    $null = Invoke-Git -GitArgs @('worktree', 'remove', '--force', $wt) -AllowFail
    if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
    $null = Invoke-Git -GitArgs @('worktree', 'prune') -AllowFail
    $null = Invoke-Git -GitArgs @('branch', '-D', $IntegrationBranch) -AllowFail
}

return Write-Report $result
