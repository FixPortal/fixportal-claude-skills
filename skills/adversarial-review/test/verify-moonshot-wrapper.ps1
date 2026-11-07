$ErrorActionPreference = 'Stop'
$wrapper = Join-Path $PSScriptRoot '../moonshot-review.ps1'
if (-not (Test-Path $wrapper)) { throw 'Moonshot wrapper is missing' }
$ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$null, [ref]$null)
foreach ($name in 'ConvertTo-MoonshotReasoningEffort', 'New-MoonshotRequestBody', 'Read-MoonshotResponse') {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing tested boundary $name" }
    Invoke-Expression $definition.Extent.Text
}
$body = New-MoonshotRequestBody 'any-future-model-id' 'prompt' 'high' | ConvertFrom-Json
if ($body.model -cne 'any-future-model-id' -or $body.messages.Count -ne 1 -or $body.PSObject.Properties.Name -contains 'tools') { throw 'Request must pass the model id through verbatim, with one message and no tools' }
foreach ($fixed in 'temperature', 'top_p', 'n', 'presence_penalty', 'frequency_penalty') {
    if ($body.PSObject.Properties.Name -contains $fixed) { throw "K3.x fixes $fixed server-side; the request must omit it" }
}
foreach ($case in @(@('low', 'low'), @('minimal', 'low'), @('high', 'high'), @('medium', 'high'), @('', 'high'), @('max', 'max'), @('xhigh', 'max'))) {
    if ((ConvertTo-MoonshotReasoningEffort $case[0]) -ne $case[1]) { throw "Effort '$($case[0])' must map to '$($case[1])'" }
}
$good = [pscustomobject]@{ model = 'm'; choices = @([pscustomobject]@{ finish_reason = 'stop'; message = [pscustomobject]@{ content = 'F1: AGREE' } }) }
if ((Read-MoonshotResponse $good 'm') -ne 'F1: AGREE') { throw 'Good response was lost' }
foreach ($bad in @(
        [pscustomobject]@{ model = 'other'; choices = $good.choices },
        [pscustomobject]@{ model = 'm'; choices = @([pscustomobject]@{ finish_reason = 'length'; message = [pscustomobject]@{ content = 'x' } }) },
        [pscustomobject]@{ model = 'm'; choices = @([pscustomobject]@{ finish_reason = 'stop'; message = [pscustomobject]@{ content = ' ' } }) }
    )) {
    $rejected = $false
    try { $null = Read-MoonshotResponse $bad 'm' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Wrong-model, truncated, or empty output was accepted' }
}
$manifest = Get-Content (Join-Path $PSScriptRoot '../reviewers.json') -Raw | ConvertFrom-Json
if ($manifest.wrappers.moonshot -ne 'moonshot-review.ps1') { throw 'moonshot wrapper must be registered' }
$seat = @($manifest.reviewers | Where-Object id -eq 'M')
if ($seat.Count -ne 1 -or $seat[0].supplemental -or $seat[0].vendor -ne 'moonshot' -or $seat[0].repoAccess -or $seat[0].wrapper -ne 'moonshot' -or $seat[0].select.channel -ne 'api') { throw 'Moonshot API seat must be a counted, repo-blind seat selecting the api channel' }
if (-not $seat[0].enabled) { throw 'Moonshot API seat must be enabled' }
if (@($manifest.reviewers | Where-Object vendor -eq 'moonshot').Count -ne 1) { throw 'Moonshot must hold exactly one counted seat' }
if (@($manifest.alternates | Where-Object id -eq 'M').Count) { throw 'Seat M must not also sit in alternates' }
if (@($manifest.alternates | Where-Object id -eq 'K' | Where-Object enabled).Count) { throw 'The retired Kimi CLI seat K must stay disabled' }
if (($manifest.roles | ConvertTo-Json -Depth 8) -match 'moonshot') { throw 'Moonshot must not enter judging or verification' }
$registryPath = Join-Path $PSScriptRoot '../../model-registry/registry.json'
if (Test-Path -LiteralPath $registryPath) {
    $entry = (Get-Content $registryPath -Raw | ConvertFrom-Json).models.'kimi-k3.1-pro'
    if ($entry.vendor -ne 'moonshot' -or $entry.availability.api -ne 'available' -or $entry.tier -ne 'workhorse') { throw 'Registry entry must exist, be api-available and triaged workhorse' }
    $price = @($entry.pricing | Where-Object channel -eq 'api')
    if ($price.Count -ne 1 -or $price[0].price_in -ne 2.0 -or $price[0].price_out -ne 10.0) { throw 'Registry api price must be the list rate 2.00 in / 10.00 out per 1M tokens' }
} else {
    Write-Host 'SKIP: model-registry not present in this tree - the workhorse-triaged registry entry and its api price are not asserted'
}
'Moonshot contracts passed: verbatim model pass-through, fixed sampling params omitted, effort mapping, response-model/finish/empty checks, counted repo-blind seat, retired CLI seat K still disabled, no judge/verifier role, workhorse-triaged registry entry.'
