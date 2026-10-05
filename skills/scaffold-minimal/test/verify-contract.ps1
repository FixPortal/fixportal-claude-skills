$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$main = Get-Content (Join-Path $root 'SKILL.md') -Raw
$referencePath = Join-Path $root 'references' 'controller-conversion.md'
if (-not (Test-Path $referencePath)) { throw 'missing controller conversion reference' }
$reference = Get-Content $referencePath -Raw
$all = $main + "`n" + $reference
$words = ([regex]::Matches($main, '\b[\p{L}\p{N}][\p{L}\p{N}''.-]*\b')).Count

if ($words -gt 500) { throw "SKILL.md is $words words" }
foreach ($needle in 'existing ASP.NET project', 'Do not use to create a new project', 'scaffold-dotnet first') {
    if ($main -notmatch [regex]::Escape($needle)) { throw "missing scope boundary: $needle" }
}
foreach ($needle in '[Authorize]', '[AllowAnonymous]', 'ApiBehaviorOptions', 'binding source',
                    'content negotiation', 'IRouteTemplateProvider', '[controller]', '[action]',
                    'EndpointDataSource', 'exact multiset match', 'stop and keep the controller') {
    if ($all -notmatch [regex]::Escape($needle)) { throw "missing conversion invariant: $needle" }
}
foreach ($needle in 'preserve its existing gating', 'existing surfaces keep their gating', 'JsonOptions', 'Accept: application/json') {
    if ($all -notmatch [regex]::Escape($needle)) { throw "missing back-ported guidance: $needle" }
}
foreach ($stale in 'IFusionCache', 'FakeDatabase', 'GetOrSet', 'CompanyController') {
    if ($reference -match [regex]::Escape($stale)) { throw "example still depends on undefined collaborator: $stale" }
}
foreach ($needle in 'GreetingController', 'WithName("GetGreeting")') {
    if ($reference -notmatch [regex]::Escape($needle)) { throw "self-contained example missing: $needle" }
}

# Scope this to the CODE BLOCKS, not the whole document. The needle used to be a bare
# 'TypedResults.Ok' over the full file, which pinned the very call that broke the parity
# contract the skill promises - and once the example was corrected, the same needle went on
# passing because the words still appear in the prose EXPLAINING why not to use it. A guard
# satisfied by its own rationale is not a guard.
$codeBlocks = ([regex]::Matches($reference, '(?s)```csharp(.*?)```') | ForEach-Object { $_.Groups[1].Value }) -join "`n"
if ($codeBlocks -notmatch [regex]::Escape('Results.Text(')) {
    throw 'the worked conversion example must use Results.Text for a string-returning action'
}
if ($codeBlocks -match [regex]::Escape('TypedResults.Ok($"Hello')) {
    throw 'the greeting example uses TypedResults.Ok, which JSON-serialises a bare string and changes both body and content type - the exact contract break this skill forbids'
}
foreach ($needle in 'StringOutputFormatter', 'text/plain', 'application/json') {
    if ($reference -notmatch [regex]::Escape($needle)) {
        throw "the example must explain the string-serialisation difference it avoids: $needle"
    }
}

foreach ($needle in 'Directory.Packages.props', 'PackageReference', 'Microsoft.OpenApi 3.x', '<3.0.0', 'source generation') {
    if ($reference -notmatch [regex]::Escape($needle)) {
        throw "missing OpenAPI compatibility guard: $needle"
    }
}

$compatibilityCases = @(
    @{ Target = 'ASP.NET Core 10 and earlier'; Framework = '`net10.0` or earlier'; OpenApi = '`2.x` (`<3.0.0`)' },
    @{ Target = 'ASP.NET Core 11 and later'; Framework = '`net11.0` or later'; OpenApi = 'supported `3.x`' }
)
foreach ($case in $compatibilityCases) {
    $row = "| $($case.Target) | $($case.Framework) | $($case.OpenApi) |"
    if ($reference -notmatch [regex]::Escape($row)) {
        throw "missing OpenAPI compatibility fixture: $row"
    }
}
foreach ($needle in 'inspect the target framework and the resolved `Microsoft.AspNetCore.OpenApi` dependency',
                    'do not force a universal Microsoft.OpenApi ceiling') {
    if ($all -notmatch [regex]::Escape($needle)) {
        throw "missing TFM/package compatibility rule: $needle"
    }
}
# Both declaration schemes must be covered, AND named as alternatives. The two are
# mutually exclusive - a centrally managed project carries versionless PackageReference
# entries by design - so wording that reads as "check both places" invites treating a
# versionless reference as a missing pin and adding a version that CPM then fights.
foreach ($needle in 'alternatives, not layers', 'versionless `PackageReference`', 'is not a missing pin') {
    if ($reference -notmatch [regex]::Escape($needle)) {
        throw "the OpenAPI compatibility guard must present the two package schemes as alternatives: $needle"
    }
}
if ($main -notmatch [regex]::Escape('scaffold-dotnet first')) {
    throw 'brand-new projects must route through scaffold-dotnet before minimal API work'
}

"scaffold-minimal contract OK — $words words"
