$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\themes.json'
# themes.json ships EMPTY ({}) as a per-user starter -- the skill populates it over successive
# runs. So an empty object is valid; we only assert that whatever IS present is well-formed.
# It is NOT mirrored with real data: that is the user's own runtime ledger, and publishing it
# would leak their repo names.
$json = Get-Content $path -Raw | ConvertFrom-Json
$names = @($json.PSObject.Properties.Name | Where-Object { $_ })
foreach ($k in $names) {
  $t = $json.$k
  # home: a non-empty string.
  if ($t.home -isnot [string] -or [string]::IsNullOrWhiteSpace($t.home)) { throw "theme $k 'home' must be a non-empty string" }
  # aliases / seen: arrays of strings (SKILL.md treats them as collections; a scalar or object
  # would silently break alias matching and seen set-union at runtime). ConvertFrom-Json yields
  # [object[]] for a JSON array; a scalar stays a bare string; {} becomes a PSCustomObject.
  foreach ($field in 'aliases','seen') {
    $v = $t.$field
    if ($v -isnot [System.Array]) { throw "theme $k '$field' must be an array" }
    foreach ($item in $v) {
      if ($item -isnot [string]) { throw "theme $k '$field' must contain only strings" }
    }
  }
}
"themes.json OK -- $($names.Count) themes (empty starter is valid)"
