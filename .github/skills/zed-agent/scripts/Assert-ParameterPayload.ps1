<#
.SYNOPSIS
    Blocking pre-POST gate. Refuses to queue an ADO pipeline run whose
    templateParameters payload disagrees with the pipeline's own YAML
    declaration or with the model learned from real human releases.

.DESCRIPTION
    Every deploy defect this gate catches has already happened for real:

      UNDECLARED_PARAMETER        ADO rejects the entire queue for a single
                                  parameter the YAML no longer declares, so the
                                  release stalls with an opaque 400.
      MISSING_DECLARED_PARAMETER  ADO silently substitutes the YAML default.
                                  A default is not the release owner's intent.
      SHAPE_MISMATCH              '@("a","b")' where 'regions(a,b)' belonged is
                                  accepted by ADO and then deploys nothing.
      REGION_SET_SHRINK           A payload narrower than the last trustworthy
                                  release silently skips regions; nobody notices
                                  until a region is found weeks behind.

    All findings are reported together - one throw listing every problem beats
    a fix-one-rerun-discover-the-next loop.

    Findings carry a severity. A SHAPE_MISMATCH against a learned form the model
    is NOT confident in (stability other than 'constant', or lowConfidence) is
    surfaced via Write-Warning and left in `findings` without blocking - one
    release is not enough evidence to veto a run. Everything else blocks.

    The gate degrades honestly rather than silently: a pipeline with no YAML
    introspection and no learned model has nothing to check against, and that is
    surfaced as a warning naming the pipeline, not passed off as a clean bill.

.PARAMETER Payload
    The assembled templateParameters hashtable, exactly as it will be posted.

.PARAMETER PipelineKey
    Catalog key of the pipeline, used to look up its declaration and model and
    to name the pipeline in any failure.

.PARAMETER Scope
    Catalog scope holding the pipeline entry ('canary', 'production', ...).

.PARAMETER PipelineCatalogPath
    Path to pipeline-catalog.json. Defaults to the standard skill location.

.PARAMETER DeclaredParameters
    Pre-resolved declaration, bypassing the catalog lookup. Used by callers that
    already hold it (Resolve-TemplateParams.ps1 returns it) and by tests.

.PARAMETER Model
    Pre-resolved learned model, bypassing the catalog lookup.

.PARAMETER AllowMissingDeclared
    Downgrade MISSING_DECLARED_PARAMETER to a warning. For pipelines that
    deliberately rely on YAML defaults for some parameters.

.PARAMETER WarnOnly
    Report findings without throwing. For reporting paths that must not abort.

.OUTPUTS
    PSCustomObject: ok, findings[] (each with a severity), pipelineKey,
    checked (bool), reason.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable]$Payload,
    [Parameter(Mandatory)][string]$PipelineKey,
    [string]$Scope = 'production',
    [string]$PipelineCatalogPath,
    [AllowNull()][object[]]$DeclaredParameters,
    [AllowNull()][object]$Model,
    [switch]$AllowMissingDeclared,
    [switch]$WarnOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\YamlParamModel.ps1')

# Only consult the catalog for what the caller did not already supply.
if ($null -eq $DeclaredParameters -or $null -eq $Model) {
    if (-not $PipelineCatalogPath) {
        $PipelineCatalogPath = Join-Path (Get-Location) '.github/skills/zed-agent/pipeline-catalog.json'
    }
    if (Test-Path $PipelineCatalogPath) {
        $cat = Get-Content $PipelineCatalogPath -Raw | ConvertFrom-Json
        $entry = $null
        if ($cat.PSObject.Properties[$Scope] -and $cat.$Scope.PSObject.Properties[$PipelineKey]) {
            $entry = $cat.$Scope.$PipelineKey
        } else {
            # Scope is a convenience, not a contract: find the key wherever it lives.
            foreach ($sp in $cat.PSObject.Properties) {
                if ($sp.Name -like '_*') { continue }
                if ($sp.Value -and $sp.Value.PSObject.Properties -and $sp.Value.PSObject.Properties[$PipelineKey]) {
                    $entry = $sp.Value.$PipelineKey; break
                }
            }
        }
        if ($entry) {
            if ($null -eq $DeclaredParameters -and
                $entry.PSObject.Properties['yamlIntrospection'] -and $entry.yamlIntrospection -and
                $entry.yamlIntrospection.PSObject.Properties['parameters']) {
                $DeclaredParameters = @($entry.yamlIntrospection.parameters | Where-Object { $_ -and $_.name })
            }
            if ($null -eq $Model -and $entry.PSObject.Properties['_learnedFrom'] -and $entry._learnedFrom -and
                $entry._learnedFrom.PSObject.Properties['model']) {
                $Model = $entry._learnedFrom.model
            }
        }
    }
}

# @($null).Count is 1, so an unsupplied -DeclaredParameters would otherwise read as
# "one declaration" and the gate would report checked=$true having verified nothing.
$declaredCount = @($DeclaredParameters | Where-Object { $_ -and $_.name }).Count
$hasModel      = $false
if ($Model) {
    $modelProps = if ($Model -is [System.Collections.IDictionary]) { @($Model.Keys) } else { @($Model.PSObject.Properties.Name) }
    $hasModel = (@($modelProps).Count -gt 0)
}

if ($declaredCount -eq 0 -and -not $hasModel) {
    $reason = ("NO_VALIDATION_SOURCE: pipeline '$PipelineKey' has neither yamlIntrospection nor a learned model, " +
               "so its $($Payload.Count)-parameter payload was posted unchecked. " +
               "Operator action: run Get-PipelineYamlIntrospection.ps1 and New-ParameterModel.ps1 for this pipeline.")
    Write-Warning $reason
    return [pscustomobject]@{
        ok = $true; findings = @(); pipelineKey = $PipelineKey; checked = $false; reason = $reason
    }
}

$result = Test-ParameterPayload -Payload $Payload `
                                -DeclaredParameters @($DeclaredParameters) `
                                -Model $Model `
                                -AllowMissingDeclared:$AllowMissingDeclared

# A shape break against a model that is not confident in that shape is real
# evidence but not proof, so it is reported without vetoing the queue. It is
# never dropped: it stays in `findings` and is printed.
$warnings = @($result.findings | Where-Object { [string]$_.severity -eq 'warning' })
$errors   = @($result.findings | Where-Object { [string]$_.severity -ne 'warning' })

$format = {
    param($f)
    "  [$($f.code)/$(if ($f.severity) { $f.severity } else { 'error' })] $($f.parameter)`n      $($f.detail)`n      expected: $($f.expected)`n      actual:   $($f.actual)"
}

$out = [pscustomobject]@{
    ok          = $result.ok
    findings    = @($result.findings)
    pipelineKey = $PipelineKey
    checked     = $true
    reason      = if (-not $result.ok) { 'see findings' }
                  elseif ($warnings.Count -gt 0) { "payload accepted with $($warnings.Count) warning(s); see findings" }
                  else { 'payload agrees with declaration and learned model' }
}

if ($warnings.Count -gt 0) {
    Write-Warning ("PARAMETER_PAYLOAD_WARNINGS: pipeline '$PipelineKey' — $($warnings.Count) non-blocking finding(s); " +
                   "the model is not confident enough in these forms to veto the run.`n" +
                   (($warnings | ForEach-Object { & $format $_ }) -join "`n") + "`n" +
                   "Operator action: if these are genuine, re-learn the model from more releases with New-ParameterModel.ps1 " +
                   "so the next occurrence blocks instead of warning.")
}

if ($result.ok) { return $out }

$lines = @($errors | ForEach-Object { & $format $_ })
$msg = ("PARAMETER_PAYLOAD_REJECTED: pipeline '$PipelineKey' — $(@($errors).Count) blocking finding(s); the run was NOT queued.`n" +
        ($lines -join "`n") + "`n" +
        "Operator action: correct pipeline-catalog.json -> $Scope.$PipelineKey (or re-learn the model from the " +
        "latest real release with New-ParameterModel.ps1), then re-run. Nothing was posted to ADO.")

if ($WarnOnly) { Write-Warning $msg; return $out }
throw $msg
