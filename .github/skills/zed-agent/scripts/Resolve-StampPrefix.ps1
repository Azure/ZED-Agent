<#
.SYNOPSIS
    L-14: Resolves a stamp prefix to its Azure region using the stampPrefixToRegion
    map in service-config.json.

.DESCRIPTION
    Stamps are named {prefix}-{layout}-{serviceTag}{n} and the prefix is NOT always
    the literal region code (e.g. 'uae' maps to 'uaecentral' via short code 'uac').
    This function looks up the prefix in the service-config map and THROWS on an
    unknown prefix rather than guessing.

    Confirmed mappings from field evidence:
      uae = uaecentral (uac)
      uan = uaenorth
      ilc = israelcentral
      qac = qatarcentral
      iln = israelnorthwest

.PARAMETER StampPrefix
    The stamp prefix to resolve (e.g., 'uae', 'ilc').

.PARAMETER ServiceConfigPath
    Path to service-config.json containing stampPrefixToRegion.

.OUTPUTS
    String — the Azure region short name.

.NOTES
    Throws UNKNOWN_STAMP_PREFIX on any prefix not found in the map. Never guesses.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StampPrefix,
    [Parameter(Mandatory)][string]$ServiceConfigPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ServiceConfigPath)) {
    throw "service-config.json not found at $ServiceConfigPath"
}

$cfg = Get-Content $ServiceConfigPath -Raw | ConvertFrom-Json

if (-not $cfg.PSObject.Properties['stampPrefixToRegion'] -or -not $cfg.stampPrefixToRegion) {
    throw "UNKNOWN_STAMP_PREFIX: prefix '$StampPrefix' cannot be resolved — stampPrefixToRegion is not configured in service-config.json. Run 'setup-service group 4' to populate it."
}

$map = $cfg.stampPrefixToRegion
$normalizedPrefix = $StampPrefix.ToLower()

if (-not $map.PSObject.Properties[$normalizedPrefix]) {
    $knownPrefixes = @($map.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
    throw "UNKNOWN_STAMP_PREFIX: prefix '$StampPrefix' is not in stampPrefixToRegion. Known prefixes: [$knownPrefixes]. Do NOT guess — add the mapping to service-config.json → stampPrefixToRegion after confirming the correct Azure region."
}

return [string]$map.$normalizedPrefix
