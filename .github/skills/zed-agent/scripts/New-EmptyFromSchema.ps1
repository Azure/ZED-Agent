<#
.SYNOPSIS
    Generate an empty config object from a JSON Schema, honouring `default` values.

.DESCRIPTION
    Walks a JSON Schema (draft-07) and emits a PSCustomObject whose shape matches
    `properties`, with sensible empty values: "" for strings, 0 for numbers,
    false for booleans, [] for arrays, {} for free-form objects. When a `default`
    keyword is present it wins over the type-based default. When `enum` is
    present and no `default`, the first enum value is used.

    Used by Install-Zed.ps1 to write empty service-config.json + pipeline-catalog.json
    into target repos without maintaining a duplicate heredoc skeleton.

    Limitations (intentional — keep the generator simple):
    - $ref / $defs are resolved one hop (sufficient for our two schemas).
    - oneOf / anyOf / allOf / if-then-else are ignored (validators, not shapers).
    - patternProperties / additionalProperties:<schema> on object nodes emit {}.

.PARAMETER SchemaPath
    Path to a JSON Schema file (draft-07).

.OUTPUTS
    PSCustomObject — the generated empty config.

.EXAMPLE
    $cfg = & .\New-EmptyFromSchema.ps1 -SchemaPath .\service-config.schema.json
    $cfg | ConvertTo-Json -Depth 32 | Set-Content service-config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SchemaPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SchemaPath)) {
    throw "Schema not found: $SchemaPath"
}

$schemaRoot = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json

function Resolve-SchemaRef {
    param($Node, $Root)
    if ($Node -and ($Node.PSObject.Properties.Name -contains '$ref')) {
        $ref = $Node.'$ref'
        if ($ref -match '^#/(\$defs|definitions)/(.+)$') {
            $bucket = $Matches[1]
            $name   = $Matches[2]
            return $Root.$bucket.$name
        }
    }
    return $Node
}

function ConvertTo-EmptyValue {
    param($Node, $Root)

    $Node = Resolve-SchemaRef -Node $Node -Root $Root
    if ($null -eq $Node) { return $null }

    if ($Node.PSObject.Properties.Name -contains 'default') { return $Node.default }
    if ($Node.PSObject.Properties.Name -contains 'enum')    { return $Node.enum[0] }

    switch ($Node.type) {
        'string'  { return '' }
        'integer' { return 0 }
        'number'  { return 0 }
        'boolean' { return $false }
        'array'   { return ,@() }
        'object'  {
            $obj = [ordered]@{}
            if ($Node.PSObject.Properties.Name -contains 'properties') {
                foreach ($prop in $Node.properties.PSObject.Properties) {
                    if ($prop.Name.StartsWith('_')) { continue }
                    $obj[$prop.Name] = ConvertTo-EmptyValue -Node $prop.Value -Root $Root
                }
            }
            return [PSCustomObject]$obj
        }
        default   { return $null }
    }
}

ConvertTo-EmptyValue -Node $schemaRoot -Root $schemaRoot
