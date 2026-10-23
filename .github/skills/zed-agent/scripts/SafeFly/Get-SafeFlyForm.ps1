<#
.SYNOPSIS
    Resolves the active SafeFly V2 form for the configured franchise and change type.

.DESCRIPTION
    Calls the SafeFly V2 GraphQL activeForm query and returns a normalised list of
    questions: name, label, isRequired, renderType, isMultiSelect, conditionalRule,
    options { id, label, value }.

    Fails loudly if:
      * No active form exists for the configured franchise/changeType.
      * The returned question count is <= 1 (silent-truncation trap guard).

    The silent-truncation trap: selecting `staticOptions` on QuestionResponseBaseQuery
    silently returns 1 question instead of all questions (no error, no warning). This
    script never selects staticOptions; it always uses options { id label value }.
    Assert count > 1 at runtime to catch the trap if the query ever changes.

.PARAMETER ServiceConfigPath
    Path to service-config.json.

.OUTPUTS
    PSCustomObject { formId: string, questions: object[] }

.NOTES
    Config requirements:
      safefly.franchiseId   — SafeFly franchise GUID
      safefly.changeTypeId  — Change type GUID (e.g. 1bdba704-... for App deployment)
      safefly.changeTypeName — Human-readable name for error messages
      Plus Invoke-SafeFlyGraphQL requirements (graphQlEndpoint, tokenAudience).
#>
[CmdletBinding()]
param(
    [string] $ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = 'Stop'

$cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

$franchiseId    = if ($cfg.safefly.PSObject.Properties['franchiseId'])    { $cfg.safefly.franchiseId }    else { $null }
$changeTypeId   = if ($cfg.safefly.PSObject.Properties['changeTypeId'])   { $cfg.safefly.changeTypeId }   else { $null }
$changeTypeName = if ($cfg.safefly.PSObject.Properties['changeTypeName'])  { $cfg.safefly.changeTypeName } else { $changeTypeId }

if ([string]::IsNullOrWhiteSpace($franchiseId))  { throw "safefly.franchiseId is not configured in service-config.json." }
if ([string]::IsNullOrWhiteSpace($changeTypeId)) { throw "safefly.changeTypeId is not configured in service-config.json." }

# IMPORTANT: Do NOT add 'staticOptions' to this query — it silently truncates to 1 question.
# Use 'options { id label value }' with a sub-selection (server requirement too: bare
# 'options' without sub-selection is a GraphQL error).
$query = @'
query GetActiveForm($franchiseId: ID!, $changeTypeId: ID!) {
  activeForm(franchiseId: $franchiseId, changeTypeId: $changeTypeId, expandWidgetQuestionsInline: true) {
    id
    questions {
      id
      name
      label
      isRequired
      renderType
      isMultiSelect
      conditionalRule {
        operator
        conditions {
          triggerQuestionName
          comparisonOperator
          comparisonValue
        }
        actionSet {
          require
        }
      }
      options {
        id
        label
        value
      }
    }
  }
}
'@

$variables = @{ franchiseId = $franchiseId; changeTypeId = $changeTypeId }

Write-Verbose "Fetching SafeFly V2 activeForm: franchise=$franchiseId changeType=$changeTypeId ($changeTypeName)"

$data = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') `
    -Query $query -Variables $variables -ServiceConfigPath $ServiceConfigPath

# Fail loudly if no active form — never fall back to another change type.
if (-not $data -or -not $data.PSObject.Properties['activeForm'] -or -not $data.activeForm) {
    throw "SafeFly V2 returned no active form for franchise '$franchiseId' and change type " +
          "'$changeTypeName' ($changeTypeId). This change type may not have an active form yet. " +
          "Do NOT fall back to another change type — verify with the release owner. " +
          "Use changeTypesByService(serviceId) to list available forms."
}

$form      = $data.activeForm
$questions = @($form.questions)

# Silent-truncation guard: the App deployment form has 43 questions.
# If this returns <= 1, the query accidentally used staticOptions or similar.
if ($questions.Count -le 1) {
    throw "SafeFly V2 activeForm '$($form.id)' returned only $($questions.Count) question(s). " +
          "Expected > 1. Silent-truncation trap: verify the GraphQL query does NOT select " +
          "'staticOptions' — use 'options { id label value }' instead."
}

Write-Host "  [SafeFly] activeForm id=$($form.id): $($questions.Count) question(s)" -ForegroundColor Gray

return [PSCustomObject]@{
    formId    = $form.id
    questions = $questions
}
