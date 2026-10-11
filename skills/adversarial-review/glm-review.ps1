#Requires -Version 7
<#
.SYNOPSIS
    z.AI reviewer using the GLM Coding Plan through isolated Claude Code.
.NOTES
    PREFLIGHT_COMMAND: pwsh -NoProfile -File ~/.agents/skills/adversarial-review/glm-review.ps1 -Preflight -Model glm-5.3
    PREFLIGHT_SUCCESS: exit 0 and stdout is GLM_PREFLIGHT_OK (authenticated model response).
    Windows credential: Read-Host 'z.AI API key' -AsSecureString | Export-Clixml -LiteralPath "$env:LOCALAPPDATA/YourOrg/glm-trial/zai-key.clixml"
    No API fallback, repository access, tools, or normal Claude profile. Cost stays unknown.
#>
[CmdletBinding(DefaultParameterSetName='Review')]
param(
    [Parameter(Mandatory, ParameterSetName='Review')][string] $Instruction,
    [Parameter(Mandatory, ParameterSetName='Review')][string] $DiffPath,
    [string] $FindingsPath,
    [string[]] $ContextPath,
    [Parameter(Mandatory)][ValidateSet('glm-5.3','glm-5.3-flash')][string] $Model,
    [ValidateSet('low','medium','high','xhigh','max')][string] $Effort = 'high',
    [string] $OutPath,
    [string] $UsageSidecarPath,
    [Parameter(Mandatory, ParameterSetName='Preflight')][switch] $Preflight,
    [ValidateRange(30,2700)][int] $TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'

function New-GlmProcessInfo([string]$CliPath, [string]$ProfilePath, [string]$Model, [string]$Effort, [string]$Key) {
    $start = [Diagnostics.ProcessStartInfo]::new($CliPath)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment.Clear()
    foreach ($name in 'PATH','SystemRoot','WINDIR','COMSPEC','PATHEXT','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOMEDRIVE','HOMEPATH') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $start.Environment[$name] = $value }
    }
    $start.Environment['CLAUDE_CONFIG_DIR'] = $ProfilePath
    $start.Environment['ANTHROPIC_AUTH_TOKEN'] = $Key
    $start.Environment['ANTHROPIC_BASE_URL'] = 'https://api.z.ai/api/anthropic'
    $start.Environment['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
    $start.Environment['API_TIMEOUT_MS'] = '120000'
    foreach ($argument in @('-p','--model',$Model,'--effort',$Effort,'--output-format','stream-json','--verbose','--restricted','--safe-mode','--strict-mcp-config','--tools','','--no-session-persistence','--permission-mode','dontAsk','--system-prompt','Review only the supplied text. Follow the supplied phase brief exactly.')) {
        $start.ArgumentList.Add($argument)
    }
    return $start
}

function Read-GlmResponse([string]$JsonLines, [string]$Model) {
    $events = @($JsonLines -split '\r?\n' | Where-Object { $_.Trim() } | ConvertFrom-Json)
    $init = @($events | Where-Object subtype -eq 'init')
    if ($init.Count -ne 1 -or $init[0].tools.Count -ne 0 -or $init[0].mcp_servers.Count -ne 0) { throw 'GLM tool isolation was not confirmed.' }
    $models = @($events | Where-Object type -eq 'assistant' | ForEach-Object { $_.message.model } | Select-Object -Unique)
    if ($models.Count -ne 1 -or $models[0] -cne $Model) { throw 'GLM response model differs from the requested model.' }
    $result = @($events | Where-Object type -eq 'result')
    if ($result.Count -ne 1 -or $result[0].is_error -or $result[0].subtype -ne 'success' -or [string]::IsNullOrWhiteSpace($result[0].result)) { throw 'GLM did not return a successful, complete response.' }
    return $result[0]
}

if (-not $IsWindows) { throw 'GLM trial credential uses Windows DPAPI; configure this reviewer only on its Windows host.' }
$cli = Get-Command claude.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
$credentialRoot = Join-Path $env:LOCALAPPDATA 'YourOrg/glm-trial'
$prompt = if ($Preflight) { $Effort = 'low'; 'Reply exactly GLM_PREFLIGHT_OK.' } else {
    $parts = @($Instruction, '--- DIFF UNDER REVIEW ---', (Get-Content -LiteralPath $DiffPath -Raw))
    if ($FindingsPath) { $parts += @('--- POOLED FINDINGS (attribution removed) ---', (Get-Content -LiteralPath $FindingsPath -Raw)) }
    foreach ($path in @($ContextPath | ForEach-Object { $_ -split ';' } | Where-Object { $_.Trim() })) {
        $parts += @("--- CONTEXT: $path (background, not under review) ---", (Get-Content -LiteralPath $path.Trim() -Raw))
    }
    $parts -join "`n`n"
}
$secureKey = Import-Clixml -LiteralPath (Join-Path $credentialRoot 'zai-key.clixml')
if ($secureKey -isnot [Security.SecureString]) { throw 'Expected a DPAPI-encrypted SecureString credential.' }
$key = [Net.NetworkCredential]::new('', $secureKey).Password
if ([string]::IsNullOrWhiteSpace($key)) { throw 'Empty GLM credential.' }
$start = New-GlmProcessInfo $cli.Source (Join-Path $credentialRoot 'claude-profile') $Model $Effort $key
# No source tree is exposed; the prompt contains all evidence. Keep cwd separate from credentials.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('glm-review-' + [guid]::NewGuid().ToString('N'))
$process = [Diagnostics.Process]::new()
$started = $false
try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $start.WorkingDirectory = $scratch
    $process.StartInfo = $start
    $started = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine($prompt)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "GLM exceeded $TimeoutSeconds seconds; no completed review."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult().Replace($key, '[REDACTED]')
    $stderr = $stderrTask.GetAwaiter().GetResult().Replace($key, '[REDACTED]')
    if ($process.ExitCode -ne 0) { throw "GLM CLI exited $($process.ExitCode): $stderr $stdout" }
    $result = Read-GlmResponse $stdout $Model
    if ($Preflight) {
        # GLM echoes the prompt's closing full stop ("GLM_PREFLIGHT_OK."), observed 2026-10-07.
        if (($result.result.Trim() -replace '\.$', '') -ne 'GLM_PREFLIGHT_OK') { throw "Unexpected GLM preflight response: $($result.result.Trim())" }
        'GLM_PREFLIGHT_OK'
        return
    }
    if ($UsageSidecarPath) {
        @{vendor='zai';model=$Model;inputTokens=[long]$result.usage.input_tokens;outputTokens=[long]$result.usage.output_tokens;costUsd=0.0;costUnknown=$true;costEstimated=$false;billingRoute='coding-plan'} |
            ConvertTo-Json | Set-Content -LiteralPath $UsageSidecarPath -Encoding utf8
    }
    if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $result.result -Encoding utf8 }
    $result.result
} finally {
    if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
    $start.Environment.Remove('ANTHROPIC_AUTH_TOKEN') | Out-Null
    $key = $null
    $secureKey.Dispose()
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedScratch -Leaf) -like 'glm-review-*') {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
