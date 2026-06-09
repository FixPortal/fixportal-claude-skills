$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\themes.json'
$json = Get-Content $path -Raw | ConvertFrom-Json
$required = @(
  'store-before-validate','check-then-set-race','swallowed-exception-aborts-loop',
  'culture-parse','utcnow-not-injected-clock','secret-in-log','anon-endpoint',
  'retry-burned-in-one-pass','inverted-min-max','lease-off-by-one'
)
foreach ($k in $required) {
  if (-not $json.PSObject.Properties.Name.Contains($k)) { throw "missing theme: $k" }
  if (-not $json.$k.home)    { throw "theme $k missing 'home'" }
  if ($null -eq $json.$k.aliases) { throw "theme $k missing 'aliases'" }
  if ($null -eq $json.$k.seen)    { throw "theme $k missing 'seen'" }
}
"themes.json OK — $($required.Count) seed themes"
