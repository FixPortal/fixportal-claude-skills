$ErrorActionPreference = 'Stop'

# themes.json ships EMPTY ({}) as a per-user starter -- the skill populates it over successive
# runs. So an empty object is valid; we only assert that whatever IS present is well-formed.
# It is NOT mirrored with real data: that is the user's own runtime ledger, and publishing it
# would leak their repo names.

# Validate one theme. home: non-empty string. aliases / seen: collections of non-empty strings
# (SKILL.md treats them as collections used for substring matching and seen set-union; a null
# field, an object element, or a blank element would silently break matching or corrupt
# provenance -- an aliases: [""] entry becomes a catch-all that classifies every review).
# NOTE: ConvertFrom-Json UNWRAPS a single-element JSON array into a bare scalar, so a valid
# one-alias theme arrives as a string, not an array. Normalise with @(...) before validating
# rather than asserting [array]-ness, which would false-reject that legitimate single-element case.
function Test-Theme {
  param([string]$Name, $Theme)
  if ($Theme.home -isnot [string] -or [string]::IsNullOrWhiteSpace($Theme.home)) {
    throw "theme $Name 'home' must be a non-empty string"
  }
  foreach ($field in 'aliases','seen') {
    if ($null -eq $Theme.$field) { throw "theme $Name '$field' is missing" }
    foreach ($item in @($Theme.$field)) {
      if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
        throw "theme $Name '$field' must contain only non-empty strings"
      }
    }
  }
}

$path = Join-Path $PSScriptRoot '..\themes.json'
$json = Get-Content $path -Raw | ConvertFrom-Json
# Root must be a JSON object ({} or a map of themes). A null / array / scalar root is malformed and
# must fail loudly rather than pass as "0 themes".
if ($json -isnot [System.Management.Automation.PSCustomObject]) {
  throw "themes.json root must be a JSON object"
}
$names = @($json.PSObject.Properties.Name | Where-Object { $_ })
foreach ($k in $names) { Test-Theme -Name $k -Theme $json.$k }

# Fixtures -- the shipped file is {}, so exercise the validator branches directly.
Test-Theme -Name 'fixture-good' -Theme ([pscustomobject]@{ home = 'reviewer brief'; aliases = @('a','b'); seen = @('repo-x') })
# ...and via a JSON ROUND-TRIP with single-element arrays, the case ConvertFrom-Json unwraps to a
# scalar -- a valid one-alias/one-seen theme must still pass.
$rt = '{"solo":{"home":"reviewer brief","aliases":["only-one"],"seen":["only-repo"]}}' | ConvertFrom-Json
Test-Theme -Name 'solo' -Theme $rt.solo
$bad = @(
  @{ n = 'blank-home';    t = [pscustomobject]@{ home = '';   aliases = @('a'); seen = @('r') } },
  @{ n = 'null-aliases';  t = [pscustomobject]@{ home = 'h';  aliases = $null;  seen = @('r') } },
  @{ n = 'object-seen';   t = [pscustomobject]@{ home = 'h';  aliases = @('a'); seen = ([pscustomobject]@{}) } },
  @{ n = 'blank-alias';   t = [pscustomobject]@{ home = 'h';  aliases = @('');  seen = @('r') } },
  @{ n = 'nonstr-seen';   t = [pscustomobject]@{ home = 'h';  aliases = @('a'); seen = @(1) } }
)
foreach ($case in $bad) {
  $threw = $false
  try { Test-Theme -Name $case.n -Theme $case.t } catch { $threw = $true }
  if (-not $threw) { throw "verify-themes: fixture '$($case.n)' should have been rejected but passed" }
}

"themes.json OK -- $($names.Count) themes (empty starter is valid); validator fixtures pass"
