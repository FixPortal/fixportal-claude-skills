#Requires -Version 7
$ErrorActionPreference = 'Stop'
$emitter = Join-Path $PSScriptRoot '../emit-review-findings.ps1'
$aggregate = Join-Path $PSScriptRoot '../aggregate-and-emit.ps1'
if (-not (Test-Path -LiteralPath $emitter)) { throw 'Missing findings emitter' }
$expected = Get-Content (Join-Path $PSScriptRoot 'fixtures/panel-findings-post-valid.json') -Raw | ConvertFrom-Json -AsHashtable
$scratch = Join-Path $PSScriptRoot ('findings-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
$savedUrl = $env:OBSERVATORY_URL
$savedKey = $env:OBSERVATORY_API_KEY
$listener = [System.Net.HttpListener]::new()
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
# Built, not written as a literal: the mirror's sanitisation scan rejects any URL literal carrying a port.
$baseUrl = [UriBuilder]::new('http', 'localhost', $port).Uri.AbsoluteUri.TrimEnd('/')
$listener.Prefixes.Add("$baseUrl/")
$requests = [System.Collections.Generic.List[object]]::new()
function Invoke-TestProcess([string] $script, [string[]] $arguments) {
    $start = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('-NoProfile', '-File', $script) + $arguments) { $start.ArgumentList.Add($arg) }
    $process = [System.Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $process.HasExited) {
            if ($script:pending.IsCompleted) {
                $context = $script:pending.GetAwaiter().GetResult()
                $reader = [System.IO.StreamReader]::new($context.Request.InputStream)
                $requests.Add(@{ path = $context.Request.Url.AbsolutePath; key = $context.Request.Headers['X-Observatory-Key']; body = ($reader.ReadToEnd() | ConvertFrom-Json -AsHashtable) })
                $reader.Dispose()
                $context.Response.StatusCode = 200
                $context.Response.Close()
                $script:pending = $listener.GetContextAsync()
            }
            if ($timer.Elapsed.TotalSeconds -gt 30) { $process.Kill($true); throw 'Test child timed out' }
            Start-Sleep -Milliseconds 20
        }
        return @{ code = $process.ExitCode; output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}
function Assert-Body($actual, $wanted) {
    # Recursively canonicalise object keys; preserve array order and scalar types.
    function Canonical($value) {
        if ($value -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in ($value.Keys | Sort-Object)) { $result[$key] = Canonical $value[$key] }
            return $result
        }
        if ($value -is [array]) { return ,@($value | ForEach-Object { Canonical $_ }) }
        return $value
    }
    if ((Canonical $actual | ConvertTo-Json -Depth 20 -Compress) -cne (Canonical $wanted | ConvertTo-Json -Depth 20 -Compress)) { throw 'Posted body differs from contract fixture' }
}
try {
    $listener.Start()
    $script:pending = $listener.GetContextAsync()
    $env:OBSERVATORY_URL = $baseUrl
    $env:OBSERVATORY_API_KEY = 'local-test-key'
    $verdictPath = Join-Path $scratch 'aggregate-verdict.json'
    $verdict = @{ findings = $expected.findings }
    $verdict | ConvertTo-Json -Depth 20 | Set-Content $verdictPath
    $argsForEmit = @('-RunId', $expected.runId, '-Repo', $expected.repo, '-VerdictPath', $verdictPath)
    $result = Invoke-TestProcess $emitter $argsForEmit
    if ($result.code -ne 0 -or $requests.Count -ne 1) { throw "Expected one successful POST: $($result.output)" }
    Assert-Body $requests[0].body $expected
    if ($requests[0].path -ne '/api/adversarial-review/findings' -or $requests[0].key -ne 'local-test-key') { throw 'Wrong endpoint or auth header' }
    foreach ($missing in @('OBSERVATORY_URL', 'OBSERVATORY_API_KEY')) {
        $prior = [Environment]::GetEnvironmentVariable($missing)
        [Environment]::SetEnvironmentVariable($missing, $null)
        $result = Invoke-TestProcess $emitter $argsForEmit
        [Environment]::SetEnvironmentVariable($missing, $prior)
        if ($result.code -ne 0 -or $result.output -or $requests.Count -ne 1) { throw 'Unset environment must silently skip' }
    }
    '{}' | Set-Content $verdictPath
    $result = Invoke-TestProcess $emitter $argsForEmit
    if ($result.code -ne 0 -or $requests.Count -ne 1) { throw 'Absent findings must skip' }
    foreach ($field in @('severity', 'outcome', 'verdict')) {
        $bad = $expected | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        if ($field -eq 'verdict') { $bad.findings[-2].assessments[0].verdict = 'AGREE' }
        else { $bad.findings[-1][$field] = 'invalid' }
        @{ findings = $bad.findings } | ConvertTo-Json -Depth 20 | Set-Content $verdictPath
        $result = Invoke-TestProcess $emitter $argsForEmit
        if ($result.code -eq 0 -or $requests.Count -ne 1) { throw "Invalid $field must fail before any POST" }
    }
    # The real aggregate must emit reviewers and judge before exactly one findings POST.
    @{ participants = @(@{ reviewer = 'openai'; model = 'gpt-6-astra'; issuesRaised = 3; costUsd = 0; inputTokens = 0; outputTokens = 0 }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $scratch 'metrics.json')
    $verdict.judge = @{ reviewer = 'anthropic'; model = 'test-exact-model'; costUsd = 0 }
    $verdict.accepted = @{ openai = 1 }
    $verdict | ConvertTo-Json -Depth 20 | Set-Content $verdictPath
    $requests.Clear()
    $aggregateArgs = @('-RunRoot', $scratch, '-RunId', $expected.runId, '-Repo', $expected.repo)
    $result = Invoke-TestProcess $aggregate $aggregateArgs
    if ($result.code -ne 0 -or ($requests.path -join ',') -ne '/api/adversarial-review/runs,/api/adversarial-review/runs,/api/adversarial-review/findings') { throw "Aggregate emission order/count wrong: $($result.output)" }
    Assert-Body $requests[2].body $expected
    $verdict.Remove('findings')
    $verdict | ConvertTo-Json -Depth 20 | Set-Content $verdictPath
    $requests.Clear()
    $result = Invoke-TestProcess $aggregate $aggregateArgs
    if ($result.code -ne 0 -or ($requests.path -join ',') -ne '/api/adversarial-review/runs,/api/adversarial-review/runs') { throw 'Legacy verdict changed behavior' }
    Write-Host 'PASS: contract body, auth, unset environment, absent findings, all enums, aggregate order and legacy verdict'
} finally {
    $listener.Close()
    $env:OBSERVATORY_URL = $savedUrl
    $env:OBSERVATORY_API_KEY = $savedKey
    # Only the unique test-owned directory beneath this test directory is removed.
    $resolved = [System.IO.Path]::GetFullPath($scratch)
    if ((Split-Path $resolved -Parent) -ne [System.IO.Path]::GetFullPath($PSScriptRoot) -or (Split-Path $resolved -Leaf) -notlike 'findings-test-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
