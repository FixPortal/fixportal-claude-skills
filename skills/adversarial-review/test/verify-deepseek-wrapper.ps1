$ErrorActionPreference = 'Stop'
$wrapper = Join-Path $PSScriptRoot '../deepseek-review.ps1'
if (-not (Test-Path $wrapper)) { throw 'DeepSeek wrapper is missing' }
$ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$null, [ref]$null)
foreach ($name in 'New-DeepseekRequestBody', 'Read-DeepseekResponse') {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing tested boundary $name" }
    Invoke-Expression $definition.Extent.Text
}
$body = New-DeepseekRequestBody 'any-future-model-id' 'prompt' | ConvertFrom-Json
if ($body.model -cne 'any-future-model-id' -or $body.messages.Count -ne 1 -or $body.PSObject.Properties.Name -contains 'tools') { throw 'Request must pass the model id through verbatim, with one message and no tools' }
$good = [pscustomobject]@{ model = 'm'; choices = @([pscustomobject]@{ finish_reason = 'stop'; message = [pscustomobject]@{ content = 'F1: AGREE' } }) }
if ((Read-DeepseekResponse $good 'm') -ne 'F1: AGREE') { throw 'Good response was lost' }
foreach ($bad in @(
        [pscustomobject]@{ model = 'other'; choices = $good.choices },
        [pscustomobject]@{ model = 'm'; choices = @([pscustomobject]@{ finish_reason = 'length'; message = [pscustomobject]@{ content = 'x' } }) },
        [pscustomobject]@{ model = 'm'; choices = @([pscustomobject]@{ finish_reason = 'stop'; message = [pscustomobject]@{ content = ' ' } }) }
    )) {
    $rejected = $false
    try { $null = Read-DeepseekResponse $bad 'm' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Wrong-model, truncated, or empty output was accepted' }
}
$manifest = Get-Content (Join-Path $PSScriptRoot '../reviewers.json') -Raw | ConvertFrom-Json
$seat = @($manifest.reviewers | Where-Object id -eq 'D')
if ($seat.Count -ne 1 -or $seat[0].supplemental -or $seat[0].vendor -ne 'deepseek' -or $seat[0].repoAccess -or $seat[0].wrapper -ne 'deepseek' -or -not $seat[0].model) { throw 'DeepSeek must be a counted, repo-blind, literal-pinned seat' }
if (($manifest.roles | ConvertTo-Json -Depth 8) -match 'deepseek') { throw 'DeepSeek must not enter judging or verification' }
if (@($manifest.reviewers | Where-Object { $_.id -eq 'K' }).Count) { throw 'Kimi must stay retired to alternates' }
$registryPath = Join-Path $PSScriptRoot '../../model-registry/registry.json'
if (Test-Path -LiteralPath $registryPath) {
    $entry = (Get-Content $registryPath -Raw | ConvertFrom-Json).models.($seat[0].model)
    if ($entry.vendor -ne 'deepseek' -or $null -ne $entry.tier) { throw 'Registry entry must exist and stay untriaged (tier null)' }
} else {
    Write-Host 'SKIP: model-registry not present in this tree - the untriaged registry entry is not asserted';
}
'DeepSeek contracts passed: verbatim model pass-through, response-model/finish/empty checks, counted repo-blind seat, no judge/verifier role, untriaged registry entry.'
