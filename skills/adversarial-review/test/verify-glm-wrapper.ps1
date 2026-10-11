$ErrorActionPreference = 'Stop'
$wrapper = Join-Path $PSScriptRoot '../glm-review.ps1'
if (-not (Test-Path $wrapper)) { throw 'GLM wrapper is missing' }
$ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$null, [ref]$null)
foreach ($name in 'New-GlmProcessInfo','Read-GlmResponse') {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing tested boundary $name" }
    Invoke-Expression $definition.Extent.Text
}
$original = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY')
try {
    $env:ANTHROPIC_API_KEY = 'unrelated-test-credential'
    $start = New-GlmProcessInfo -CliPath 'fixture-cli' -ProfilePath 'fixture-profile' -Model 'glm-5.3' -Effort 'high' -Key 'test-glm-key'
    if ($start.Environment.ContainsKey('ANTHROPIC_API_KEY') -or $start.Environment.ContainsKey('CLAUDE_CODE_OAUTH_TOKEN')) { throw 'Inherited credentials escaped isolation' }
    if ($env:ANTHROPIC_API_KEY -ne 'unrelated-test-credential') { throw 'Parent authentication was changed' }
    if ($start.Environment['ANTHROPIC_AUTH_TOKEN'] -ne 'test-glm-key' -or $start.Environment['ANTHROPIC_BASE_URL'] -ne 'https://api.z.ai/api/anthropic') { throw 'Coding-plan route not selected' }
    if (($start.ArgumentList -join ' ') -match 'test-glm-key') { throw 'Secret appears in command arguments' }
    foreach ($flag in '--safe-mode','--restricted','--strict-mcp-config','--no-session-persistence') {
        if (-not $start.ArgumentList.Contains($flag)) { throw "Isolation flag missing: $flag" }
    }
    $toolIndex = $start.ArgumentList.IndexOf('--tools')
    if ($toolIndex -lt 0 -or $start.ArgumentList[$toolIndex + 1] -ne '') { throw 'Tools must be disabled' }
    $frames = @(
        @{type='system';subtype='init';tools=@();mcp_servers=@()},
        @{type='assistant';message=@{model='glm-5.3';content=@(@{type='text';text='F1: AGREE - evidence'})}},
        @{type='result';subtype='success';is_error=$false;result='F1: AGREE - evidence';usage=@{input_tokens=7;output_tokens=8}}
    )
    $json = ($frames | ForEach-Object { ConvertTo-Json $_ -Depth 8 -Compress }) -join "`n"
    $response = Read-GlmResponse $json 'glm-5.3'
    if ($response.result -ne 'F1: AGREE - evidence' -or $response.usage.output_tokens -ne 8) { throw 'Cross-examination or usage was lost' }
    foreach ($bad in @(
        $json.Replace('glm-5.3','claude-sonnet-5'),
        $json.Replace('"is_error":false','"is_error":true'),
        $json.Replace('"tools":[]','"tools":["Bash"]'),
        (($frames[0..1] | ForEach-Object { ConvertTo-Json $_ -Depth 8 -Compress }) -join "`n")
    )) {
        $rejected = $false
        try { $null = Read-GlmResponse $bad 'glm-5.3' } catch { $rejected = $true }
        if (-not $rejected) { throw 'Malformed, tool-enabled, failed, or wrong-model output was accepted' }
    }
    $manifest = Get-Content (Join-Path $PSScriptRoot '../reviewers.json') -Raw | ConvertFrom-Json
    $seat = @($manifest.reviewers | Where-Object id -eq 'Z')
    if ($seat.Count -ne 1 -or $seat[0].supplemental -or $seat[0].expiresAt -or $seat[0].vendor -ne 'zai' -or $seat[0].repoAccess -or $seat[0].fallbackWrapper -or -not $seat[0].select) { throw 'GLM must be a counted, isolated registry-selected seat without a fallback wrapper' }
# Public mirror: the seat carries a literal `model` BESIDE its `select` as the registry-absent
# fallback (run-review.ps1 Resolve-SeatModel), and must pin the only id glm-review.ps1 accepts.
if ($seat[0].model -cne 'glm-5.3') { throw "GLM literal fallback must be glm-5.3, got '$($seat[0].model)'" }
    if (($manifest.roles | ConvertTo-Json -Depth 8) -match 'zai|glm') { throw 'GLM must not enter judging or verification' }
    $registryPath = Join-Path $PSScriptRoot '../../model-registry/registry.json'
    if (Test-Path -LiteralPath $registryPath) {
        $registry = Get-Content $registryPath -Raw | ConvertFrom-Json
        $entry = $registry.models.'glm-5.3'
        if ($entry.vendor -ne 'zai' -or $entry.tier -ne $seat[0].select.tier -or $entry.availability.cli -ne 'available' -or $entry.retired) { throw 'Seat Z select must resolve to the registry glm-5.3 entry' }
        $resolved = @(python (Join-Path $PSScriptRoot '../../model-registry/resolve.py') --vendor $seat[0].select.vendor --tier $seat[0].select.tier --channel $seat[0].select.channel)
        if ($resolved.Count -lt 1 -or $resolved[0] -cne 'glm-5.3') { throw "Seat Z select resolved to '$($resolved -join ',')', not glm-5.3 (the only model glm-review.ps1 accepts)" }
    } else {
        Write-Host 'SKIP: model-registry not present in this tree - registry resolution of seat Z not asserted; the literal fallback was checked above'
    }
    'GLM contracts passed: child-only auth, coding endpoint, no tools, model/error checks, phase-2 text, and a counted registry-selected seat.'
} finally { [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $original) }
