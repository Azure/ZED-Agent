<#
.SYNOPSIS
    Shared, service-agnostic helpers for reading an Azure Pipelines YAML parameter
    surface and for learning a parameter model from prior runs.

.DESCRIPTION
    Dot-source this file. It defines pure functions only — no network, no auth,
    no side effects, no service-specific literals.

        ConvertFrom-YamlScalarQuoting Strip one matched pair of enclosing quotes.
        Get-YamlParameterBlock      Extract the pipeline's own `parameters:` block.
        Get-ParameterPartitionModel Discover cloud/scope partitions generically.
        Get-ParameterValueShape     Classify a literal parameter value's shape.
        Build-ParameterModel        Learn declaredDefault/shape/stability from runs.
        Select-LearnedParameterValue Pick the value of the newest non-deficient run.
        Get-ContainerElements       Split a `@(...)` / `name(...)` literal into items.
        New-ContainerLiteral        Rebuild such a literal from items.
        Resolve-BranchConditionalEnum Derive an enum value from the branch type.
        Test-ParameterPayload       Diff an assembled payload vs YAML + model.

    GENERICITY CONTRACT
    -------------------
    Nothing here may encode a partition name, region name, stamp name, service
    name or pipeline id. Partitions are DISCOVERED from the declared parameter
    names; value shapes are DERIVED from the observed literal.

    The only vocabulary constants are Azure Pipelines / SDP *syntax* tokens
    (`@(...)`, `@{...}`, `*`, `name(args)`), which are language forms — not
    service facts.
#>

# Facet suffixes of the partition "quad" idiom, longest-first so that
# `Excludestamps` wins over `stamps` and `ExcludeRegions` over `Regions`.
# These are Azure Pipelines SDP parameter-naming FACETS, not service names.
$script:ZedParamFacets = @(
    'ExcludeRegions'
    'Excludestamps'
    'ExcludeStamps'
    'Regions'
    'stamps'
    'Stamps'
    'Script'
)

# The facet that marks a partition "head" (its enable/disable toggle).
$script:ZedPartitionHeadFacet = 'Script'

function ConvertTo-CanonicalFacet {
    <#
    .SYNOPSIS
        Normalise a facet suffix to a stable camelCase key so that casing
        variants (`stamps` / `Stamps`, `Excludestamps` / `ExcludeStamps`)
        collapse onto one slot.
    #>
    param([string]$Facet)
    switch -Regex ($Facet) {
        '^ExcludeRegions$'    { return 'excludeRegions' }
        '^Exclude[Ss]tamps$'  { return 'excludeStamps' }
        '^Regions$'           { return 'regions' }
        '^[Ss]tamps$'         { return 'stamps' }
        '^Script$'            { return 'script' }
    }
    return $Facet.Substring(0,1).ToLowerInvariant() + $Facet.Substring(1)
}

function ConvertFrom-YamlScalarQuoting {
    <#
    .SYNOPSIS
        Remove ONE matched pair of enclosing YAML quotes from a scalar.

    .DESCRIPTION
        A YAML default written `default: "normal"` carries its quotes into the
        extracted text. Posting that verbatim to ADO sends the literal 5-char
        value `"normal"` — which fails template validation. The quotes are YAML
        syntax, not part of the value, so they are stripped once at extraction.

        The pair is only removed when it demonstrably encloses the WHOLE scalar:
        the same quote character must not appear anywhere inside. That refusal
        is what keeps `"a","b"` (two quoted items, not one quoted string) and
        `@{"a"="b"}` (a map literal) intact. Being conservative here can only
        leave a value untouched; being greedy would splice two literals into one.
    #>
    param([AllowNull()][AllowEmptyString()][object]$Value)

    if ($null -eq $Value) { return $Value }
    if ($Value -isnot [string]) { return $Value }

    $v = [string]$Value
    if ($v.Length -lt 2) { return $v }

    $q = $v[0]
    if ($q -ne "'" -and $q -ne '"') { return $v }
    if ($v[$v.Length - 1] -ne $q) { return $v }

    $inner = $v.Substring(1, $v.Length - 2)
    if ($inner.IndexOf($q) -ge 0) { return $v }

    return $inner
}

function Get-YamlParameterBlock {
    <#
    .SYNOPSIS
        Extract the pipeline's own top-level `parameters:` block.

    .DESCRIPTION
        Azure Pipelines YAML permits a block sequence to sit at the SAME
        indentation as its owning key:

            parameters:
            - name: foo          <-- column 0

        as well as the indented form:

            parameters:
              - name: foo

        Both are valid YAML and both occur in the wild (the ADO
        `/pipelines/{id}/preview` endpoint emits the column-0 form). A walker
        that terminates on "any non-indented line" silently yields ZERO
        parameters for the column-0 form — the failure this function exists to
        prevent. Termination is therefore keyed on a column-0 *mapping key*
        (`something:`), never on a sequence entry (`- ...`).

    .OUTPUTS
        Array of PSCustomObject: name, type, default, displayName, values[].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Yaml,
        [string]$BlockKey = 'parameters'
    )

    $text  = $Yaml -replace "`r", ''
    $lines = $text -split "`n"

    $out        = [System.Collections.Generic.List[object]]::new()
    $inBlock    = $false
    $cur        = $null
    $itemIndent = -1
    $inValues   = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }

        if (-not $inBlock) {
            # Only a column-0 mapping key opens the pipeline's own block.
            if ($line -match "^$([regex]::Escape($BlockKey))\s*:\s*$") { $inBlock = $true }
            continue
        }

        if ($line.Trim().Length -eq 0) { continue }

        $indent = [regex]::Match($line, '^(\s*)').Groups[1].Length
        $trim   = $line.Trim()

        # A column-0 mapping key ends the block. A column-0 sequence entry does NOT.
        if ($indent -eq 0 -and $trim -notmatch '^-' -and $trim -match '^[^\s:]+\s*:') {
            break
        }

        if ($trim -match '^-\s*name\s*:\s*(.+)$') {
            # A `- name:` deeper than the parameter items belongs to a nested
            # structure (e.g. an object default), not to a new parameter.
            if ($itemIndent -ge 0 -and $indent -gt $itemIndent) {
                if ($cur -and $inValues) { $cur.values += (ConvertFrom-YamlScalarQuoting $trim.Substring(1).Trim()) }
                continue
            }
            if ($cur) { $out.Add([pscustomobject]$cur) | Out-Null }
            if ($itemIndent -lt 0) { $itemIndent = $indent }
            $inValues = $false
            $cur = [ordered]@{
                name        = ConvertFrom-YamlScalarQuoting $Matches[1].Trim()
                type        = $null
                default     = $null
                displayName = $null
                values      = @()
            }
            continue
        }

        if ($cur -and $trim -match '^(type|default|displayName)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()
            $inValues = $false
            # Enclosing YAML quotes are syntax, not value. They are stripped once
            # here so every downstream consumer — shape inference, the pre-POST
            # gate, and the declared-default fallback that actually gets POSTed —
            # sees the same unquoted literal. See ConvertFrom-YamlScalarQuoting
            # for why collection/map literals survive untouched.
            $cur[$key] = ConvertFrom-YamlScalarQuoting $val
            continue
        }

        if ($cur -and $trim -match '^values\s*:\s*$') { $inValues = $true; continue }

        if ($cur -and $inValues -and $trim -match '^-\s+(.+)$') {
            $cur.values += (ConvertFrom-YamlScalarQuoting $Matches[1].Trim())
            continue
        }
    }

    if ($cur) { $out.Add([pscustomobject]$cur) | Out-Null }
    # Emitted unrolled; callers wrap with @() so that 0- and 1-element results
    # behave identically.
    return @($out.ToArray())
}

function Get-ParameterPartitionModel {
    <#
    .SYNOPSIS
        Discover cloud/scope partitions generically from declared parameter names.

    .DESCRIPTION
        Applies the quad regex `^(?<partition>.*?)(?<facet>Script|stamps|
        Excludestamps|Regions|ExcludeRegions)$` to every declared parameter name.

        * An empty partition (`stamps`, `Regions`, …) is FLAT scope.
        * A non-empty partition qualifies when it owns the head facet
          (`<P>Script`) or at least two distinct facets — this rejects
          incidental suffix collisions.
        * Prefix aliasing: a qualifying candidate `A` that has NO head facet and
          is a strict prefix of a candidate `B` that DOES have one, with disjoint
          facets, is folded into `B` as an alias. This captures the common
          shorthand where some facets use a truncated partition prefix, WITHOUT
          naming any partition.

    .OUTPUTS
        PSCustomObject: partitions[] (name, aliases[], facets{facet->paramName}),
        flat{facet->paramName}, unmatched[].
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ParameterNames)

    $facetAlt = ($script:ZedParamFacets | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $rx = "^(?<partition>.*?)(?<facet>$facetAlt)$"

    $candidates = [ordered]@{}
    $flat       = [ordered]@{}
    $unmatched  = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $ParameterNames) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $m = [regex]::Match($name, $rx)
        if (-not $m.Success) { $unmatched.Add($name) | Out-Null; continue }

        $partition = $m.Groups['partition'].Value
        $facet     = ConvertTo-CanonicalFacet $m.Groups['facet'].Value

        if ($partition -eq '') { $flat[$facet] = $name; continue }
        # A partition must look like an identifier; anything else is a collision.
        if ($partition -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { $unmatched.Add($name) | Out-Null; continue }

        if (-not $candidates.Contains($partition)) { $candidates[$partition] = [ordered]@{} }
        $candidates[$partition][$facet] = $name
    }

    $headFacet = ConvertTo-CanonicalFacet $script:ZedPartitionHeadFacet

    # Qualification. A candidate is a real partition if it owns the head facet or
    # carries at least two facets. Single-facet candidates are held back as orphans:
    # they may still be a shortened spelling of a qualified partition (see aliasing).
    $qualified = [ordered]@{}
    $orphans   = [ordered]@{}
    foreach ($k in @($candidates.Keys)) {
        $facets = $candidates[$k]
        if ($facets.Contains($headFacet) -or $facets.Count -ge 2) { $qualified[$k] = $facets }
        else { $orphans[$k] = $facets }
    }

    # Prefix aliasing (headless candidate folded into its head-owning extension).
    $aliasOf = @{}
    foreach ($short in (@($qualified.Keys) + @($orphans.Keys))) {
        $shortFacets = if ($qualified.Contains($short)) { $qualified[$short] } else { $orphans[$short] }
        if ($shortFacets.Contains($headFacet)) { continue }
        $target = $null
        foreach ($long in @($qualified.Keys)) {
            if ($long -eq $short) { continue }
            if ($long.Length -le $short.Length) { continue }
            if (-not $long.StartsWith($short, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not $qualified[$long].Contains($headFacet)) { continue }
            $overlap = @($shortFacets.Keys | Where-Object { $qualified[$long].Contains($_) })
            if ($overlap.Count -gt 0) { continue }
            # Prefer the shortest qualifying extension.
            if (-not $target -or $long.Length -lt $target.Length) { $target = $long }
        }
        if ($target) { $aliasOf[$short] = $target }
    }

    # Orphans that found no home are not partitions at all.
    foreach ($k in @($orphans.Keys)) {
        if ($aliasOf.ContainsKey($k)) { continue }
        foreach ($n in $orphans[$k].Values) { $unmatched.Add($n) | Out-Null }
    }

    $partitions = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($qualified.Keys)) {
        if ($aliasOf.ContainsKey($k)) { continue }
        $facets = [ordered]@{}
        foreach ($f in $qualified[$k].Keys) { $facets[$f] = $qualified[$k][$f] }
        $aliases = @($aliasOf.GetEnumerator() | Where-Object { $_.Value -eq $k } | ForEach-Object { $_.Key } | Sort-Object)
        foreach ($a in $aliases) {
            $aFacets = if ($qualified.Contains($a)) { $qualified[$a] } else { $orphans[$a] }
            foreach ($f in $aFacets.Keys) { if (-not $facets.Contains($f)) { $facets[$f] = $aFacets[$f] } }
        }
        $partitions.Add([pscustomobject]@{
            name    = $k
            aliases = @($aliases)
            facets  = [pscustomobject]$facets
        }) | Out-Null
    }

    return [pscustomobject]@{
        partitions = @($partitions.ToArray())
        flat       = [pscustomobject]$flat
        unmatched  = @($unmatched.ToArray())
    }
}

function Get-FacetParameterNames {
    <#
    .SYNOPSIS
        Return every parameter name that carries a given facet, across all partitions.

    .DESCRIPTION
        Service-agnostic replacement for hardcoding a partition-specific parameter
        name (e.g. reading `PubRegions` directly). Returns every declared name whose
        trailing facet is `-Facet`, whatever the partition is called — including
        flat scope (`Regions`) and including partitions that `Get-ParameterPartitionModel`
        declines to qualify because they own only this one facet.

        Inclusiveness is deliberate. Callers union these values to compute coverage,
        so a name missed here UNDER-reports coverage, which is the unsafe direction.

    .OUTPUTS
        string[] — parameter names carrying the facet, partitioned names first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ParameterNames,
        [Parameter(Mandatory, Position = 1)][string]$Facet
    )

    $canonical = ConvertTo-CanonicalFacet $Facet
    $facetAlt  = ($script:ZedParamFacets | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $rx        = "^(?<partition>.*?)(?<facet>$facetAlt)$"

    $partitioned = [System.Collections.Generic.List[string]]::new()
    $flat        = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $ParameterNames) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $m = [regex]::Match($name, $rx)
        if (-not $m.Success) { continue }
        if ((ConvertTo-CanonicalFacet $m.Groups['facet'].Value) -ne $canonical) { continue }

        $partition = $m.Groups['partition'].Value
        if ($partition -eq '') {
            if (-not $flat.Contains($name)) { $flat.Add($name) | Out-Null }
            continue
        }
        # Anything that is not identifier-shaped is an incidental suffix collision.
        if ($partition -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { continue }
        if (-not $partitioned.Contains($name)) { $partitioned.Add($name) | Out-Null }
    }

    return @($partitioned.ToArray()) + @($flat.ToArray())
}

function Get-PartitionFacetPairs {
    <#
    .SYNOPSIS
        Pair two facets across parameter names, tolerating a truncated prefix spelling.

    .DESCRIPTION
        `Get-ParameterPartitionModel` only folds a short partition spelling into a
        longer one when the longer one owns the head facet (`<P>Script`). Pipeline
        authors are not that consistent: a real pipeline pairs `PubRegions` with
        `PublicExcludestamps` and declares no `PublicScript` at all, so the two
        facets land in two different candidates and never meet.

        A safety gate that needs BOTH facets cannot afford to go quiet in that case.
        This pairs them directly off the names: same partition wins, otherwise the
        closest prefix-compatible partner (either spelling may be the truncated one).

        Nothing here names a partition, a cloud, or a service.

    .OUTPUTS
        PSCustomObject[]: partition, partnerPartition, aliases[], a{name}, b{name}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ParameterNames,
        [Parameter(Mandatory)][string]$FacetA,
        [Parameter(Mandatory)][string]$FacetB
    )

    $facetAlt = ($script:ZedParamFacets | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $rx       = "^(?<partition>.*?)(?<facet>$facetAlt)$"
    $wantA    = ConvertTo-CanonicalFacet $FacetA
    $wantB    = ConvertTo-CanonicalFacet $FacetB

    $aByPart = [ordered]@{}
    $bByPart = [ordered]@{}
    foreach ($name in $ParameterNames) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $m = [regex]::Match($name, $rx)
        if (-not $m.Success) { continue }
        $partition = $m.Groups['partition'].Value
        if ($partition -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { continue }
        $facet = ConvertTo-CanonicalFacet $m.Groups['facet'].Value
        if ($facet -eq $wantA -and -not $aByPart.Contains($partition)) { $aByPart[$partition] = $name }
        if ($facet -eq $wantB -and -not $bByPart.Contains($partition)) { $bByPart[$partition] = $name }
    }

    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($pa in @($aByPart.Keys)) {
        $partner = $null
        if ($bByPart.Contains($pa)) {
            $partner = $pa
        } else {
            foreach ($pb in @($bByPart.Keys)) {
                $compatible = $pa.StartsWith($pb, [System.StringComparison]::OrdinalIgnoreCase) -or
                              $pb.StartsWith($pa, [System.StringComparison]::OrdinalIgnoreCase)
                if (-not $compatible) { continue }
                # Prefer the closest spelling, so `Pub` pairs with `Public` rather
                # than with some longer unrelated extension of the same prefix.
                if (-not $partner -or
                    [math]::Abs($pb.Length - $pa.Length) -lt [math]::Abs($partner.Length - $pa.Length)) {
                    $partner = $pb
                }
            }
        }
        if (-not $partner) { continue }

        # The longer spelling is the more complete partition name; the shorter is
        # the shorthand. Report the long one so inventory lookups have the best key.
        $canonical = if ($partner.Length -gt $pa.Length) { $partner } else { $pa }
        $shorthand = if ($partner.Length -gt $pa.Length) { $pa }      else { $partner }
        $aliases   = if ($canonical -eq $shorthand) { @() } else { @($shorthand) }

        $pairs.Add([pscustomobject]@{
            partition        = $canonical
            partnerPartition = $shorthand
            aliases          = $aliases
            a                = [pscustomobject]@{ name = $aByPart[$pa] }
            b                = [pscustomobject]@{ name = $bByPart[$partner] }
        }) | Out-Null
    }
    return @($pairs.ToArray())
}

function Get-ParameterValueShape {
    <#
    .SYNOPSIS
        Classify the SHAPE of an observed parameter literal.

    .DESCRIPTION
        Shape vocabulary (fixed):
            wildcard        `*`
            list            `@("a","b")`
            regionsWildcard `<fn>(*)`
            regionsList     `<fn>(a,b)`
            empty           `@()`, `<fn>()`, '' or whitespace
            map             `@{...}`
            scalar          anything else

        Derivation is purely syntactic: collection (`@(...)`), map (`@{...}`)
        and function-call (`name(args)`) forms are recognised as LANGUAGE forms.
        No allow-list of names or values is consulted; the actual function token
        observed is reported separately as `container`.

    .OUTPUTS
        PSCustomObject: shape, container (the collection/function token), isEmpty.
    #>
    param([AllowNull()][AllowEmptyString()][object]$Value)

    $raw = if ($null -eq $Value) { '' } else { [string]$Value }
    $v   = $raw.Trim()

    # Strip one balanced layer of surrounding quotes (YAML defaults carry them).
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2).Trim()
    }

    $mk = @{ shape = 'scalar'; container = $null; isEmpty = $false }

    if ($v -eq '')  { $mk.shape = 'empty'; $mk.isEmpty = $true; return [pscustomobject]$mk }
    if ($v -eq '*') { $mk.shape = 'wildcard'; return [pscustomobject]$mk }

    if ($v -match '^@\{[\s\S]*\}$') { $mk.shape = 'map'; $mk.container = '@{}'; return [pscustomobject]$mk }

    if ($v -match '^@\(([\s\S]*)\)$') {
        $mk.container = '@()'
        $inner = $Matches[1].Trim()
        if ($inner -eq '') { $mk.shape = 'empty'; $mk.isEmpty = $true } else { $mk.shape = 'list' }
        return [pscustomobject]$mk
    }

    # Generic function-call form: `<token>(<args>)`.
    if ($v -match '^(?<fn>[A-Za-z_][A-Za-z0-9_]*)\((?<args>[\s\S]*)\)$') {
        $mk.container = $Matches['fn']
        $inner = $Matches['args'].Trim()
        if ($inner -eq '')      { $mk.shape = 'empty'; $mk.isEmpty = $true }
        elseif ($inner -eq '*') { $mk.shape = 'regionsWildcard' }
        else                    { $mk.shape = 'regionsList' }
        return [pscustomobject]$mk
    }

    return [pscustomobject]$mk
}

function Build-ParameterModel {
    <#
    .SYNOPSIS
        Learn a per-parameter model from owner-supplied prior runs.

    .PARAMETER Runs
        Normalized run objects (Read-PriorRun.ps1 shape), most recent first.
        Each needs `templateParameters` and, ideally, `runId` plus a
        `releaseGroup` naming the release the run belongs to. Independence is
        counted per releaseGroup — two runs from the SAME release are one data
        point, which is why two releases are the stated minimum.

    .PARAMETER DeclaredParameters
        Optional YAML-declared parameters (Get-YamlParameterBlock output) used
        to populate `declaredDefault`.

    .PARAMETER KnownDeficientRunIds
        Runs the release owner has flagged as producing WRONG values (e.g. a
        release where a bug skipped part of the region set). They remain full
        evidence for SHAPE and stability — the parameter surface they exercised
        is still real — but they are excluded from value selection so their bad
        values can never be inherited.

    .OUTPUTS
        PSCustomObject: runs[], independentReleaseCount, model{ <param> ->
        { declaredDefault, shape, container, stability, lastValue, selectedValue,
          selectedFromRunId, observedIn, lowConfidence, observedValues[],
          observations[] } }.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs,
        [object[]]$DeclaredParameters = @(),
        [int[]]$KnownDeficientRunIds = @()
    )

    $declared = @{}
    foreach ($d in $DeclaredParameters) { if ($d -and $d.name) { $declared[[string]$d.name] = $d } }

    $deficient = @{}
    foreach ($k in @($KnownDeficientRunIds)) { $deficient[[string]$k] = $true }

    function Get-RunGroup {
        param($Run)
        if ($Run.PSObject.Properties['releaseGroup'] -and $Run.releaseGroup) { return [string]$Run.releaseGroup }
        return "run:$($Run.runId)"
    }

    # Most-recent-first ordering is what "newer runs win on values" depends on.
    # Callers usually supply that order already; when the runs carry a finish
    # timestamp we re-sort on it so the guarantee does not rest on call order.
    $ordered = @($Runs)
    $haveDates = @($ordered | Where-Object {
        $_.PSObject.Properties['finishedAt'] -and $_.finishedAt
    }).Count
    if ($haveDates -eq $ordered.Count -and $ordered.Count -gt 1) {
        $ordered = @($ordered | Sort-Object -Property @{ Expression = { [datetime]$_.finishedAt } } -Descending)
    }

    $groups = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ordered) {
        $g = Get-RunGroup $r
        if (-not $groups.Contains($g)) { $groups.Add($g) | Out-Null }
    }
    $independent = $groups.Count

    # Collect observations keyed by parameter name.
    $obs = [ordered]@{}
    foreach ($r in $ordered) {
        $tp = $r.templateParameters
        if (-not $tp) { continue }
        $names = if ($tp -is [System.Collections.IDictionary]) { @($tp.Keys) } else { @($tp.PSObject.Properties.Name) }
        $g = Get-RunGroup $r
        foreach ($n in $names) {
            $val = if ($tp -is [System.Collections.IDictionary]) { $tp[$n] } else { $tp.$n }
            if (-not $obs.Contains($n)) { $obs[$n] = [System.Collections.Generic.List[object]]::new() }
            $obs[$n].Add([pscustomobject]@{
                group          = $g
                runId          = $r.runId
                knownDeficient = [bool]$deficient[[string]$r.runId]
                value          = if ($null -eq $val) { '' } else { [string]$val }
            }) | Out-Null
        }
    }

    # A parameter declared in YAML but never observed still deserves a slot.
    foreach ($n in $declared.Keys) { if (-not $obs.Contains($n)) { $obs[$n] = [System.Collections.Generic.List[object]]::new() } }

    $model = [ordered]@{}
    foreach ($n in $obs.Keys) {
        $entries  = $obs[$n].ToArray()
        $distinct = @(@($entries | ForEach-Object { $_.value }) | Select-Object -Unique)
        $seenIn   = @(@($entries | ForEach-Object { $_.group }) | Select-Object -Unique).Count

        $lastValue = if ($entries.Count -gt 0) { $entries[0].value } else { $null }
        $stability = if ($entries.Count -eq 0) { 'unobserved' }
                     elseif ($distinct.Count -le 1) { 'constant' }
                     else { 'volatile' }

        # L1 + L3: newest run that is NOT known-deficient supplies the value.
        $pick = @($entries | Where-Object { -not $_.knownDeficient }) | Select-Object -First 1
        if (-not $pick -and $entries.Count -gt 0) { $pick = $entries[0] }

        # Shape follows the selected (trustworthy) observation, not merely the
        # newest one, so a deficient run cannot dictate the emitted form either.
        $shapeInfo = if ($pick) { Get-ParameterValueShape $pick.value }
                     elseif ($declared.ContainsKey($n)) { Get-ParameterValueShape $declared[$n].default }
                     else { Get-ParameterValueShape $null }

        # Confidence: a constant needs agreement across >= 2 independent
        # releases, and the parameter must appear in every supplied release.
        $lowConfidence = ($seenIn -lt 2) -or ($seenIn -lt $independent) -or ($entries.Count -eq 0)

        $declaredDefault = if ($declared.ContainsKey($n)) { $declared[$n].default } else { $null }

        $model[$n] = [pscustomobject]@{
            declaredDefault   = $declaredDefault
            shape             = $shapeInfo.shape
            container         = $shapeInfo.container
            stability         = $stability
            lastValue         = $lastValue
            selectedValue     = if ($pick) { $pick.value } else { $null }
            selectedFromRunId = if ($pick) { $pick.runId } else { $null }
            observedIn        = $seenIn
            lowConfidence     = $lowConfidence
            observedValues    = @($distinct)
            observations      = @($entries)
        }
    }

    return [pscustomobject]@{
        runs                    = @($ordered | ForEach-Object { $_.runId })
        knownDeficientRuns      = @($KnownDeficientRunIds)
        independentReleaseCount = $independent
        model                   = [pscustomobject]$model
    }
}

function Get-ContainerElements {
    <#
    .SYNOPSIS
        Split a container literal into its elements, whatever the container is.

    .DESCRIPTION
        Understands the same LANGUAGE forms Get-ParameterValueShape classifies:
        `@("a","b")`, `<fn>(a,b)` and a bare comma-separated scalar. No name is
        recognised or special-cased; the container token is returned so the
        caller can rebuild the literal in the exact form it arrived in.

    .OUTPUTS
        PSCustomObject: container, elements[], isWildcard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Literal')]
        [AllowNull()][AllowEmptyString()][object]$Value
    )

    $v = (ConvertFrom-YamlScalarQuoting (([string]$Value).Trim()))
    if ($null -eq $v) { $v = '' }
    $v = ([string]$v).Trim()

    $container = $null
    $inner     = $v

    if ($v -match '^@\(([\s\S]*)\)$')                              { $container = '@()';  $inner = $Matches[1] }
    elseif ($v -match '^(?<fn>[A-Za-z_][A-Za-z0-9_]*)\((?<a>[\s\S]*)\)$') { $container = $Matches['fn']; $inner = $Matches['a'] }

    $inner = $inner.Trim()
    if ($inner -eq '*') {
        return [pscustomobject]@{ container = $container; elements = @(); isWildcard = $true }
    }

    $elements = @()
    if ($inner -ne '') {
        $elements = @($inner -split ',' | ForEach-Object {
            $e = (ConvertFrom-YamlScalarQuoting $_.Trim())
            if ($null -ne $e) { ([string]$e).Trim() } else { '' }
        } | Where-Object { $_ -ne '' })
    }

    return [pscustomobject]@{ container = $container; elements = @($elements); isWildcard = $false }
}

function New-ContainerLiteral {
    <#
    .SYNOPSIS
        Rebuild a container literal in the SAME form the pipeline was observed
        to accept.

    .DESCRIPTION
        `@()` elements are individually quoted (that is how the observed list
        literals are written); a function-call container joins bare elements.
        Emitting the observed form is what keeps ZED's payload shape-identical
        to a human release instead of merely semantically equivalent.
    #>
    param(
        [AllowNull()][string]$Container,
        [AllowEmptyCollection()][string[]]$Elements = @(),
        [switch]$QuoteElements
    )

    $items = @($Elements | Where-Object { $_ -ne $null -and $_ -ne '' })

    if ($Container -eq '@()') {
        if ($items.Count -eq 0) { return '@()' }
        $q = $items | ForEach-Object { '"' + $_ + '"' }
        return '@(' + ($q -join ',') + ')'
    }

    if ($Container) {
        if ($items.Count -eq 0) { return "$Container()" }
        $body = if ($QuoteElements) { ($items | ForEach-Object { '"' + $_ + '"' }) -join ',' } else { $items -join ',' }
        return "$Container($body)"
    }

    if ($items.Count -eq 0) { return '' }
    if ($QuoteElements) { return (($items | ForEach-Object { '"' + $_ + '"' }) -join ',') }
    return ($items -join ',')
}

function Resolve-BranchConditionalEnum {
    <#
    .SYNOPSIS
        Derive an enum parameter's value from the branch being released, using
        the rule the pipeline author wrote in the parameter's own displayName.

    .DESCRIPTION
        Some enum parameters are not free choices — the displayName states which
        option applies to which kind of branch, e.g.

            "Branch Prefix for Build (Use 1st option for 'develop/master'
             branches, 2nd for private branches)"

        Nothing here knows what "develop" or a "prefix" means. The rule is read
        out of the declaration itself:

          * each "<N>(st|nd|rd|th) option for <descriptor>" clause becomes a rule
            selecting values[N-1];
          * quoted tokens inside the descriptor (split on / , or "or") are the
            branch names that rule matches — matching the branch's short name
            exactly or as a leading path segment;
          * a clause with no quoted tokens is the otherwise-case.

        Returns $null when the declaration encodes no such rule, so the caller
        keeps whatever value it already had.

    .OUTPUTS
        PSCustomObject: value, ordinal, matchedTokens[], rule — or $null.
    #>
    param(
        [AllowNull()][string]$DisplayName,
        [AllowEmptyCollection()][string[]]$Values = @(),
        [AllowNull()][string]$BranchName
    )

    if (-not $DisplayName -or @($Values).Count -eq 0) { return $null }

    $short = [string]$BranchName
    if ($short -match '^refs/heads/(.+)$') { $short = $Matches[1] }
    $short = $short.Trim()

    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($DisplayName, '(?<n>\d+)\s*(?:st|nd|rd|th)\s+(?:option|value|choice)?\s*(?<desc>[^,;.)]*)', 'IgnoreCase')) {
        $idx = [int]$m.Groups['n'].Value - 1
        if ($idx -lt 0 -or $idx -ge @($Values).Count) { continue }
        $desc = $m.Groups['desc'].Value
        $tokens = @()
        foreach ($qm in [regex]::Matches($desc, "'([^']+)'|""([^""]+)""")) {
            $t = if ($qm.Groups[1].Success) { $qm.Groups[1].Value } else { $qm.Groups[2].Value }
            $tokens += @($t -split '[/,]| or ' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $rules.Add([pscustomobject]@{
            ordinal = $idx + 1
            value   = @($Values)[$idx]
            tokens  = @($tokens)
            rule    = $m.Value.Trim()
        }) | Out-Null
    }

    if ($rules.Count -eq 0) { return $null }

    foreach ($r in $rules) {
        foreach ($t in $r.tokens) {
            if ($short -eq $t -or $short -like "$t/*") {
                return [pscustomobject]@{ value = $r.value; ordinal = $r.ordinal; matchedTokens = @($t); rule = $r.rule }
            }
        }
    }

    $fallback = @($rules | Where-Object { @($_.tokens).Count -eq 0 }) | Select-Object -First 1
    if ($fallback) {
        return [pscustomobject]@{ value = $fallback.value; ordinal = $fallback.ordinal; matchedTokens = @(); rule = $fallback.rule }
    }

    return $null
}

function Test-ParameterPayload {
    <#
    .SYNOPSIS
        Diff an assembled template-parameter payload against the pipeline's YAML
        declaration and its learned model. Pure; returns findings.

    .DESCRIPTION
        Four classes of finding, each of which has actually broken a real run:

          MISSING_DECLARED_PARAMETER  declared in YAML, absent from the payload
          UNDECLARED_PARAMETER        in the payload, not declared by the YAML
                                      (ADO rejects the queue outright)
          SHAPE_MISMATCH              value form differs from the learned shape
          REGION_SET_SHRINK           a container-shaped value carries fewer
                                      elements than the newest trustworthy run

        Enum membership is checked as part of SHAPE_MISMATCH when the YAML
        declares `values`, since an out-of-enum value fails validation too.

    .OUTPUTS
        PSCustomObject: ok, findings[] { code, parameter, detail, expected, actual }.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Payload,
        [AllowEmptyCollection()][object[]]$DeclaredParameters = @(),
        [AllowNull()][object]$Model,
        [switch]$AllowMissingDeclared
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    $declared = [ordered]@{}
    foreach ($d in @($DeclaredParameters)) { if ($d -and $d.name) { $declared[[string]$d.name] = $d } }

    $modelMap = @{}
    if ($Model) {
        $props = if ($Model -is [System.Collections.IDictionary]) { @($Model.Keys) } else { @($Model.PSObject.Properties.Name) }
        foreach ($p in $props) { $modelMap[[string]$p] = if ($Model -is [System.Collections.IDictionary]) { $Model[$p] } else { $Model.$p } }
    }

    if ($declared.Count -gt 0) {
        foreach ($name in $declared.Keys) {
            if (-not $Payload.ContainsKey($name)) {
                if ($AllowMissingDeclared) { continue }
                $findings.Add([pscustomobject]@{
                    code = 'MISSING_DECLARED_PARAMETER'; parameter = $name
                    detail = "Pipeline declares '$name' but the payload omits it."
                    expected = 'present'; actual = '<absent>'
                }) | Out-Null
            }
        }
        foreach ($name in @($Payload.Keys)) {
            if (-not $declared.Contains($name)) {
                $findings.Add([pscustomobject]@{
                    code = 'UNDECLARED_PARAMETER'; parameter = $name
                    detail = "Payload carries '$name' which the pipeline YAML does not declare - ADO will reject the queue."
                    expected = '<not sent>'; actual = [string]$Payload[$name]
                }) | Out-Null
            }
        }
    }

    foreach ($name in @($Payload.Keys)) {
        $actual = [string]$Payload[$name]

        if ($declared.Contains($name)) {
            # NOTE: @($obj.missingProp) yields @($null) whose Count is 1, so an absent
            # `values` property must be filtered out explicitly or every parameter of a
            # declaration that omits `values` would be reported as an enum violation.
            $vals = @($declared[$name].values | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
            if ($vals.Count -gt 0 -and ($vals -notcontains $actual)) {
                $findings.Add([pscustomobject]@{
                    code = 'SHAPE_MISMATCH'; parameter = $name
                    detail = "Value is not one of the enum values the pipeline declares for '$name'."
                    expected = ($vals -join ' | '); actual = $actual
                }) | Out-Null
                continue
            }
        }

        $m = $modelMap[$name]
        if (-not $m) { continue }
        if (-not $m.PSObject.Properties['shape'] -or -not $m.shape) { continue }
        if ($m.shape -eq 'unobserved') { continue }

        $actualShape = Get-ParameterValueShape $actual

        # `empty` and its populated sibling are the same form with nothing in it;
        # a partition legitimately switched off must not read as a shape break.
        $compatible = @{
            'list'            = @('list','empty')
            'empty'           = @('list','empty','regionsList','regionsWildcard','wildcard','scalar')
            'regionsList'     = @('regionsList','regionsWildcard','empty')
            'regionsWildcard' = @('regionsList','regionsWildcard','empty')
            'wildcard'        = @('wildcard','list','empty','scalar')
            'map'             = @('map')
            'scalar'          = @('scalar','wildcard','empty')
        }
        $allowed = if ($compatible.ContainsKey([string]$m.shape)) { $compatible[[string]$m.shape] } else { @([string]$m.shape) }

        if ($allowed -notcontains $actualShape.shape) {
            $findings.Add([pscustomobject]@{
                code = 'SHAPE_MISMATCH'; parameter = $name
                detail = "Value form '$($actualShape.shape)' is incompatible with the learned form '$($m.shape)'."
                expected = "$($m.shape)$(if ($m.container) { " in $($m.container)(...)" })"
                actual   = "$($actualShape.shape) -> $actual"
            }) | Out-Null
            continue
        }

        if ($m.container -and $actualShape.container -and $m.container -ne $actualShape.container) {
            $findings.Add([pscustomobject]@{
                code = 'SHAPE_MISMATCH'; parameter = $name
                detail = "Container token differs from the learned form for '$name'."
                expected = $m.container; actual = $actualShape.container
            }) | Out-Null
            continue
        }

        # Shrink guard: only meaningful when the reference is an enumerated set.
        $ref = $null
        foreach ($refProp in 'selectedValue', 'lastValue', 'value') {
            if ($m.PSObject.Properties[$refProp] -and $null -ne $m.$refProp -and [string]$m.$refProp -ne '') { $ref = $m.$refProp; break }
        }
        if ($null -eq $ref -or [string]$ref -eq '') { continue }
        $refShape = Get-ParameterValueShape $ref
        if ($refShape.shape -notin @('regionsList','list')) { continue }
        if ($actualShape.shape -notin @('regionsList','list')) { continue }

        $refEl = Get-ContainerElements $ref
        $actEl = Get-ContainerElements $actual
        if (@($refEl.elements).Count -gt @($actEl.elements).Count) {
            $lost = @($refEl.elements | Where-Object { $actEl.elements -notcontains $_ })
            $findings.Add([pscustomobject]@{
                code = 'REGION_SET_SHRINK'; parameter = $name
                detail = ("'$name' carries $(@($actEl.elements).Count) entries but the newest trustworthy run used " +
                          "$(@($refEl.elements).Count). Dropped: $($lost -join ', ')")
                expected = "$(@($refEl.elements).Count) entries (run $($m.selectedFromRunId))"
                actual   = "$(@($actEl.elements).Count) entries"
            }) | Out-Null
        }
    }

    return [pscustomobject]@{
        ok       = (@($findings).Count -eq 0)
        findings = @($findings.ToArray())
    }
}
