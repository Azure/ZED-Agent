<#
.SYNOPSIS
    Revert bits (Step 7 pre-phase, service-config.json → revertBits.enabled): a branch forked from
    the PREVIOUS release commit that carries only the settings the owner chooses to keep from the
    CURRENT release (always including revertBits.preserveAlways, e.g. BCMTeeWorkflowVersion).

.DESCRIPTION
    Actions
      Plan     Resolves the previous and current release commits, diffs every settings object
               ('.../Properties') of each revertBits.files entry between them, and writes a
               numbered list to .zed-agent/releases/<id>/revert-bits-plan.json/.md.
               Returns Status 'needs-previous-commit' (with candidates) when the previous release
               commit cannot be determined — ask the owner, then re-run with -PreviousCommit.
      Prepare  Creates <revert branch> at the previous commit (branch create only — no commit, so the
               releases/* branch policies are respected), then commits the chosen settings onto a
               work branch forked from the same commit and pushes it. The caller opens the PR
               work branch → revert branch. Values are written byte-for-byte from the current
               release file; every other byte of the file is unchanged. With no settings to carry,
               only the revert branch is created (Status 'no-config-changes').
               -DryRun computes and validates everything without pushing.

    Commit resolution
      current : -CurrentCommit, else release.json → currentCommit (deploy-base), else the source commit
                of release.json → buildId (ADO), else origin/<release.currentBranch>.
      previous: -PreviousCommit, else state.revertBits.previousCommit, else release.json → previousCommit
                (deploy-base), else the source commit of the
                previous ZED release's build (.zed-agent/releases/<prev>/release.json → buildId),
                else origin/<release.previousBranch> when that is a dedicated release branch.

.OUTPUTS
    PSCustomObject: Success, Action, Status, PreviousCommit, CurrentCommit, RevertBranch, TopicBranch,
    Changes[], Selected[], Applied[], Skipped[], Candidates[], HeadSha, Pushed, PlanPath, SummaryMarkdown, Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Prepare')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$PreviousCommit,
    [string]$CurrentCommit,
    # Prepare: 'all' | 'none' | comma-separated plan numbers and/or change ids. preserveAlways keys are always included.
    [string]$Preserve = 'none',
    [string]$OwnerAlias,
    [string]$RepoPath = (Get-Location).Path,
    [string]$Remote = 'origin',
    [string]$ServiceConfigPath,
    [string]$ReleaseFile,
    [string]$StateFile,
    [string]$PlanPath,
    [string]$AccessToken,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\SdsJsonLib.ps1')

$out = [pscustomobject]@{
    Success = $false; Action = $Action; Status = $null; PreviousCommit = $null; CurrentCommit = $null
    RevertBranch = $null; TopicBranch = $null; Changes = @(); Selected = @(); Applied = @(); Skipped = @()
    Candidates = @(); HeadSha = $null; Pushed = $false; PlanPath = $null; SummaryMarkdown = $null; Error = $null
}

function Invoke-Git([string[]]$GitArgs, [string]$WorkDir = $RepoPath, [switch]$AllowFail) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & git -C $WorkDir -c core.quotepath=false @GitArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $lines = @($o | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $AllowFail) { throw "git $($GitArgs -join ' ') failed (exit $code): $($lines -join ' ')" }
    [pscustomobject]@{ Code = $code; Out = $lines }
}

function Get-BlobBytes([string]$Rev, [string]$Path) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process git -ArgumentList @('-C', $RepoPath, 'cat-file', 'blob', "${Rev}:$Path") -RedirectStandardOutput $tmp -RedirectStandardError ([IO.Path]::GetTempFileName()) -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) { return $null }
        return , [IO.File]::ReadAllBytes($tmp)
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Resolve-Commit([string]$Rev) {
    $r = Invoke-Git @('rev-parse', '--verify', '--quiet', "$Rev^{commit}") -AllowFail
    if ($r.Code -ne 0 -or -not $r.Out) { return $null }
    return $r.Out[0].Trim()
}

function Get-BuildSourceVersion($BuildId) {
    if (-not $BuildId) { return $null }
    try {
        $tok = $script:AccessToken
        if (-not $tok) {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $tok = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null } finally { $ErrorActionPreference = $prev }
        }
        if (-not $tok) { return $null }
        $b = Invoke-RestMethod "https://dev.azure.com/$($script:Org)/$($script:Proj)/_apis/build/builds/$($BuildId)?api-version=7.1" -Headers @{ Authorization = "Bearer $tok" } -ErrorAction Stop
        return [string]$b.sourceVersion
    } catch { return $null }
}

function Expand-Template([string]$Template, $Release) {
    # {{YYMM}} {{releaseId}} {{releaseName}} {{releaseNameLower}} {{releaseTag}} {ownerAlias} — lib\ReleaseNameLib.ps1
    . (Join-Path $PSScriptRoot 'lib\ReleaseNameLib.ps1')
    return Expand-ReleaseTokens $Template $ReleaseId $Release $OwnerAlias
}

function Format-Plan($Changes, $PrevSha, $CurSha, $RevertBranch) {
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("Settings changed between the previous release ($($PrevSha.Substring(0,9))) and this release ($($CurSha.Substring(0,9))) — revert branch ``$RevertBranch``.")
    [void]$md.AppendLine()
    $n = @($Changes | Where-Object { $_.number }).Count
    if ($n -eq 0) { [void]$md.AppendLine('No settings changed — the revert bits will be the previous release commit as is.') }
    else {
        [void]$md.AppendLine('| # | Keep? | Scope | Setting | Previous release | This release |')
        [void]$md.AppendLine('|---|---|---|---|---|---|')
        foreach ($c in ($Changes | Where-Object { $_.number })) {
            $keep = if ($c.autoPreserve) { '**always**' } else { '' }
            $pv = if ($c.kind -eq 'added') { '_(not set)_' } else { "``$($c.previous)``" }
            $cv = if ($c.kind -eq 'removed') { '_(removed)_' } else { "``$($c.current)``" }
            [void]$md.AppendLine("| $($c.number) | $keep | $($c.scopeLabel) | ``$($c.key)`` | $pv | $cv |")
        }
    }
    $info = @($Changes | Where-Object { -not $_.number })
    if ($info.Count) {
        [void]$md.AppendLine()
        [void]$md.AppendLine('Not carried (whole scopes added/removed in this release — e.g. new stamps): ' + (($info | ForEach-Object { "$($_.kind) $($_.scopeLabel)" }) -join '; '))
    }
    return $md.ToString()
}

try {
    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rb = $svc.revertBits
    if (-not $rb -or $rb.enabled -ne $true) { throw "service-config.json → revertBits.enabled is not true." }
    $script:Org = $svc.ado.organization; $script:Proj = $svc.ado.project; $script:AccessToken = $AccessToken

    $relDir = Join-Path $RepoPath ".zed-agent/releases/$ReleaseId"
    if (-not $ReleaseFile) { $ReleaseFile = Join-Path $relDir 'release.json' }
    if (-not $StateFile) { $StateFile = Join-Path $relDir 'state.json' }
    if (-not $PlanPath) { $PlanPath = Join-Path $relDir 'revert-bits-plan.json' }
    $release = if (Test-Path -LiteralPath $ReleaseFile) { Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $state = if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

    $files = @($rb.files)
    if ($files.Count -eq 0) { throw "revertBits.files is empty." }
    $always = @($rb.preserveAlways | Where-Object { $_ })
    $revertBranch = Expand-Template ([string]$rb.branchTemplate) $release
    $topicTmpl = if ($rb.topicBranchTemplate) { [string]$rb.topicBranchTemplate } else { 'users/{ownerAlias}/{{releaseTag}}-revert-config' }
    $topicBranch = Expand-Template $topicTmpl $release
    $out.RevertBranch = $revertBranch; $out.TopicBranch = $topicBranch

    $null = Invoke-Git @('fetch', '--quiet', $Remote)

    # ---- current release commit ----
    $cur = $null
    if ($CurrentCommit) { $cur = Resolve-Commit $CurrentCommit; if (-not $cur) { throw "Current commit '$CurrentCommit' not found." } }
    if (-not $cur -and $release -and $release.PSObject.Properties['currentCommit'] -and $release.currentCommit) { $cur = Resolve-Commit ([string]$release.currentCommit) }
    if (-not $cur -and $release -and $release.PSObject.Properties['buildId']) { $sv = Get-BuildSourceVersion $release.buildId; if ($sv) { $cur = Resolve-Commit $sv } }
    if (-not $cur -and $release -and $release.currentBranch) { $cur = Resolve-Commit "$Remote/$($release.currentBranch)" }
    if (-not $cur) { throw "Could not determine the current release commit — pass -CurrentCommit." }
    $out.CurrentCommit = $cur

    # ---- previous release commit ----
    $prev = $null
    if ($PreviousCommit) { $prev = Resolve-Commit $PreviousCommit; if (-not $prev) { throw "Previous commit '$PreviousCommit' not found." } }
    if (-not $prev -and $state -and $state.PSObject.Properties['revertBits'] -and $state.revertBits -and $state.revertBits.previousCommit) { $prev = Resolve-Commit ([string]$state.revertBits.previousCommit) }
    # deploy-base releases record the previous release commit at setup (from the last production rollout).
    if (-not $prev -and $release -and $release.PSObject.Properties['previousCommit'] -and $release.previousCommit) { $prev = Resolve-Commit ([string]$release.previousCommit) }
    $candidates = New-Object System.Collections.Generic.List[object]
    if (-not $prev) {
        $rels = Join-Path $RepoPath '.zed-agent/releases'
        if (Test-Path $rels) {
            # previous ZED release = newest other (non-test) release created before this one
            $myCreated = if ($release -and $release.dates -and $release.dates.created) { [datetime]$release.dates.created } else { [datetime]::MaxValue }
            $older = Get-ChildItem $rels -Directory | Where-Object { $_.Name -ne $ReleaseId -and (Test-Path (Join-Path $_.FullName 'release.json')) } | ForEach-Object {
                $r = Get-Content (Join-Path $_.FullName 'release.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                $c = if ($r -and $r.dates -and $r.dates.created) { [datetime]$r.dates.created } else { $null }
                if ($r -and -not $r.testMode -and $c -and $c -lt $myCreated) { [pscustomobject]@{ FullName = $_.FullName; Created = $c } }
            } | Sort-Object Created -Descending | Select-Object -First 1
            if ($older) {
                $pr = Get-Content (Join-Path $older.FullName 'release.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($pr -and $pr.PSObject.Properties['buildId'] -and -not $pr.testMode) { $sv = Get-BuildSourceVersion $pr.buildId; if ($sv) { $prev = Resolve-Commit $sv } }
            }
        }
    }
    $base = [string]$svc.ado.baseBranch
    $dev = if ($svc.ado.PSObject.Properties['integration'] -and $svc.ado.integration) { [string]$svc.ado.integration.developBranch } else { 'develop' }
    if (-not $prev -and $release -and $release.previousBranch -and @($base, $dev, 'main', 'master', 'develop') -notcontains [string]$release.previousBranch) {
        $prev = Resolve-Commit "$Remote/$($release.previousBranch)"
    }
    if (-not $prev) {
        # Offer the release points on the base branch: release merges and the build-version commit right after each.
        $log = Invoke-Git @('log', '--first-parent', '--format=%H%x1f%ad%x1f%s', '--date=short', '-200', "$cur") -AllowFail
        $rows = @($log.Out | ForEach-Object { $f = $_ -split [char]0x1f; [pscustomobject]@{ sha = $f[0]; date = $f[1]; subject = $f[2] } })
        for ($i = 1; $i -lt $rows.Count -and $candidates.Count -lt 6; $i++) {
            if ($rows[$i].subject -match '(?i)develop\s*to\s*master|\brelease\b.*\d{4}|\bRI\b|\bFI\b') {
                $pick = if ($rows[$i - 1].subject -match '(?i)incrementing build version') { $rows[$i - 1] } else { $rows[$i] }
                if ($pick.sha -eq $cur) { continue }
                $candidates.Add([pscustomobject]@{ sha = $pick.sha; date = $pick.date; subject = $pick.subject; after = $rows[$i].subject })
            }
        }
        $out.Candidates = $candidates.ToArray()
        $out.Status = 'needs-previous-commit'
        $out.Success = $true
        return $out
    }
    $out.PreviousCommit = $prev
    if ($prev -eq $cur) { throw "Previous and current release commits are the same ($prev)." }
    $isAncestor = (Invoke-Git @('merge-base', '--is-ancestor', $prev, $cur) -AllowFail).Code -eq 0

    # ---- diff ----
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $pb = Get-BlobBytes $prev $f; $cb = Get-BlobBytes $cur $f
        if ($null -eq $pb -or $null -eq $cb) { throw "Settings file '$f' is missing in $(if ($null -eq $pb) { 'the previous' } else { 'the current' }) release commit." }
        foreach ($ch in (Compare-SdsSettings $pb $cb $f)) { $changes.Add($ch) }
    }
    $num = 0
    foreach ($ch in $changes) {
        $isSetting = $ch.kind -in @('modified', 'added', 'removed')
        $n = $null
        if ($isSetting) { $num++; $n = $num }
        Add-Member -InputObject $ch -NotePropertyName number -NotePropertyValue $n
        Add-Member -InputObject $ch -NotePropertyName autoPreserve -NotePropertyValue ([bool]($isSetting -and ($always -contains $ch.key)))
    }
    $out.Changes = $changes.ToArray()

    if ($Action -eq 'Plan') {
        $md = Format-Plan $changes $prev $cur $revertBranch
        if (-not $isAncestor) { $md = "⚠ The previous release commit is not an ancestor of this release's commit — check that the right commits were picked.`n`n" + $md }
        $plan = [ordered]@{ releaseId = $ReleaseId; previousCommit = $prev; currentCommit = $cur; revertBranch = $revertBranch; topicBranch = $topicBranch; files = $files; preserveAlways = $always; previousIsAncestor = $isAncestor; changes = $changes.ToArray(); generatedAt = (Get-Date).ToUniversalTime().ToString('o') }
        $dir = Split-Path -Parent $PlanPath; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $PlanPath -Encoding UTF8
        $md | Set-Content -LiteralPath ([IO.Path]::ChangeExtension($PlanPath, '.md')) -Encoding UTF8
        $out.PlanPath = $PlanPath; $out.SummaryMarkdown = $md
        $out.Status = 'planned'; $out.Success = $true
        return $out
    }

    # ---- Prepare: selection ----
    $sel = @{}
    foreach ($ch in $changes) { if ($ch.autoPreserve) { $sel[$ch.id] = $ch } }
    $tokens = @(([string]$Preserve) -split '[,\s]+' | Where-Object { $_ })
    foreach ($t in $tokens) {
        switch -Regex ($t) {
            '^(?i)all$' { foreach ($ch in $changes) { if ($ch.number) { $sel[$ch.id] = $ch } } }
            '^(?i)none$' { }
            '^\d+$' {
                $hit = @($changes | Where-Object { $_.number -eq [int]$t })
                if ($hit.Count -ne 1) { throw "There is no setting number $t (valid: 1..$num)." }
                $sel[$hit[0].id] = $hit[0]
            }
            '^[0-9a-f]{8}$' {
                $hit = @($changes | Where-Object { $_.id -eq $t -and $_.number })
                if ($hit.Count -ne 1) { throw "Unknown change id '$t'." }
                $sel[$hit[0].id] = $hit[0]
            }
            default { throw "Cannot read '$t' in -Preserve. Use 'all', 'none', or setting numbers like 1,4,7." }
        }
    }
    $selected = @($changes | Where-Object { $sel.ContainsKey($_.id) })
    $out.Selected = $selected

    # ---- revert branch (create at previous commit; never commit to it directly) ----
    $remoteHead = (Invoke-Git @('ls-remote', '--heads', $Remote, "refs/heads/$revertBranch")).Out | Where-Object { $_ -match '\S' } | Select-Object -First 1
    if ($remoteHead) {
        $rsha = ($remoteHead -split '\s+')[0]
        $null = Invoke-Git @('fetch', '--quiet', $Remote, "+refs/heads/${revertBranch}:refs/remotes/$Remote/$revertBranch")
        if ((Invoke-Git @('merge-base', '--is-ancestor', $prev, $rsha) -AllowFail).Code -ne 0) {
            throw "Branch '$revertBranch' already exists at $($rsha.Substring(0,9)), which does not contain the previous release commit $($prev.Substring(0,9)). Delete or rename it, or pass the matching -PreviousCommit."
        }
        $revertBase = $rsha
    } else {
        if (-not $DryRun) { $null = Invoke-Git @('push', '--quiet', $Remote, "${prev}:refs/heads/$revertBranch"); $out.Pushed = $true }
        $revertBase = $prev
    }

    if ($selected.Count -eq 0) {
        $out.HeadSha = $revertBase
        $out.Status = 'no-config-changes'
        $out.SummaryMarkdown = "Revert bits ``$revertBranch`` = previous release commit $($prev.Substring(0,9)) with no settings carried."
        $out.Success = $true
        return $out
    }

    # ---- work branch with the carried settings ----
    $wt = Join-Path ([IO.Path]::GetTempPath()) ("zed-revert-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $localTopic = "zed-tmp/" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $null = Invoke-Git @('worktree', 'add', '--quiet', '-b', $localTopic, $wt, $revertBase)
    try {
        $applied = New-Object System.Collections.Generic.List[object]; $skipped = New-Object System.Collections.Generic.List[object]
        foreach ($f in $files) {
            $mine = @($selected | Where-Object { $_.file -eq $f })
            if ($mine.Count -eq 0) { continue }
            $pb = [IO.File]::ReadAllBytes((Join-Path $wt $f))
            $cb = Get-BlobBytes $cur $f
            $res = Invoke-SdsPreserve $pb $cb $mine
            Test-SdsJson $res.bytes
            # verify: only the selected settings now differ from the base, and they equal the current release
            $verify = @(Compare-SdsSettings $pb $res.bytes $f | Where-Object { $_.kind -in @('modified', 'added', 'removed') })
            $want = @($res.applied | ForEach-Object { "$($_.scope)|$($_.key)" } | Sort-Object)
            $got = @($verify | ForEach-Object { "$($_.scope)|$($_.key)" } | Sort-Object)
            if (($want -join "`n") -ne ($got -join "`n")) { throw "Verification failed for $($f): the edit changed a different set of settings than selected." }
            $resid = @(Compare-SdsSettings $res.bytes $cb $f | Where-Object { $sel.ContainsKey($_.id) -or ($_.kind -in @('modified', 'added', 'removed') -and $want -contains "$($_.scope)|$($_.key)") })
            if ($resid.Count -gt 0) { throw "Verification failed for $($f): $($resid.Count) carried setting(s) still differ from this release." }
            [IO.File]::WriteAllBytes((Join-Path $wt $f), [byte[]]$res.bytes)
            foreach ($a in $res.applied) { $applied.Add($a) }; foreach ($s in $res.skipped) { $skipped.Add($s) }
            $null = Invoke-Git @('add', '--force', '--', $f) -WorkDir $wt
        }
        $out.Applied = $applied.ToArray(); $out.Skipped = $skipped.ToArray()
        $tag = Expand-Template '{{releaseTag}}' $release
        $msg = "Revert bits ${tag}: keep $($applied.Count) setting(s) from release $tag on top of the previous release`n`n" + (($applied | ForEach-Object { "- $($_.scopeLabel): $($_.key) $(if ($_.kind -eq 'removed') { '(removed)' } else { '= ' + $_.current })" }) -join "`n")
        $msgFile = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($msgFile, $msg)
        try { $null = Invoke-Git @('commit', '--quiet', '-F', $msgFile) -WorkDir $wt } finally { Remove-Item $msgFile -ErrorAction SilentlyContinue }
        $head = (Invoke-Git @('rev-parse', 'HEAD') -WorkDir $wt).Out[0].Trim()
        $out.HeadSha = $head

        if (-not $DryRun) {
            $existing = (Invoke-Git @('ls-remote', '--heads', $Remote, "refs/heads/$topicBranch")).Out | Where-Object { $_ -match '\S' } | Select-Object -First 1
            if ($existing) {
                $esha = ($existing -split '\s+')[0]
                $null = Invoke-Git @('fetch', '--quiet', $Remote, "+refs/heads/${topicBranch}:refs/remotes/$Remote/$topicBranch")
                $same = (Invoke-Git @('diff', '--quiet', $esha, $head) -AllowFail).Code -eq 0
                if (-not $same) { throw "Work branch '$topicBranch' already exists with different content. Delete it (or merge/abandon its PR) and retry." }
                $out.HeadSha = $esha
            } else {
                $null = Invoke-Git @('push', '--quiet', $Remote, "${head}:refs/heads/$topicBranch")
                $out.Pushed = $true
            }
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Revert bits for release **$tag**: ``$revertBranch`` is the previous release commit $($prev.Substring(0,9)). This PR keeps $($applied.Count) setting(s) from this release ($($cur.Substring(0,9))) — every other setting stays as in the previous release. Generated by ZED.")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Scope | Setting | Previous release | Kept value |'); [void]$sb.AppendLine('|---|---|---|---|')
        foreach ($a in $applied) {
            $pv = if ($a.kind -eq 'added') { '_(not set)_' } else { "``$($a.previous)``" }
            $cv = if ($a.kind -eq 'removed') { '_(removed)_' } else { "``$($a.current)``" }
            [void]$sb.AppendLine("| $($a.scopeLabel) | ``$($a.key)`` | $pv | $cv |")
        }
        if ($skipped.Count) { [void]$sb.AppendLine(); [void]$sb.AppendLine('Not applied: ' + (($skipped | ForEach-Object { "$($_.change.scopeLabel) $($_.change.key) ($($_.reason))" }) -join '; ')) }
        $out.SummaryMarkdown = $sb.ToString()
        $out.Status = if ($DryRun) { 'dry-run' } else { 'prepared' }
        $out.Success = $true
    } finally {
        $null = Invoke-Git @('worktree', 'remove', '--force', $wt) -AllowFail
        if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
        $null = Invoke-Git @('worktree', 'prune') -AllowFail
        $null = Invoke-Git @('branch', '-D', $localTopic) -AllowFail
    }
} catch {
    $out.Error = $_.Exception.Message
    throw
}

return $out
