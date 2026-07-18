$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\themes.json'
# themes.json ships EMPTY ({}) as a per-user starter — the skill populates it over successive
# runs. So an empty object is valid; we only assert that whatever IS present is well-formed:
# every theme carries home / aliases / seen. (It is NOT mirrored with real data — that is the
# user's own runtime ledger; publishing it would leak their repo names.)
$json = Get-Content $path -Raw | ConvertFrom-Json
$names = @($json.PSObject.Properties.Name | Where-Object { $_ })
foreach ($k in $names) {
  if (-not $json.$k.home)         { throw "theme $k missing 'home'" }
  if ($null -eq $json.$k.aliases) { throw "theme $k missing 'aliases'" }
  if ($null -eq $json.$k.seen)    { throw "theme $k missing 'seen'" }
}
"themes.json OK — $($names.Count) themes (empty starter is valid)"
