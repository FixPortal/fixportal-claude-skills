# Audit Azure Runbook

## Contents

- [1. Resolve and authenticate](#1-resolve-and-authenticate)
- [2. Inventory](#2-inventory)
- [3. Join live resources to Bicep](#3-join-live-resources-to-bicep)
- [4. Decisions and reasons](#4-decisions-and-reasons)
- [5. Verdicts](#5-verdicts)
- [6. Report](#6-report)

Placeholders in angle brackets are values you supply; `<skill-dir>` is this skill's own
loaded directory. Every command stands alone; none depends on a variable set by another.

## 1. Resolve and authenticate

Confirm the login and that the named subscription is `Enabled`:

```powershell
az account list --all --output table
```

An error or an empty table is a stop: ask the user to run `az login`.

List the repositories. A repository is a top-level directory of the estate root that holds a
`.git` directory. A directory whose `.git` is a file is a worktree of another checkout, and
dot-directories hold worktree copies, so both are skipped and each repository is read once:

```powershell
Get-ChildItem -LiteralPath "<estate-root>" -Directory | Where-Object { -not $_.Name.StartsWith('.') -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container) } | Select-Object -ExpandProperty Name
```

Remove the excluded names, by exact match. For each repository that remains, record its
branch and commit, then list its infrastructure files and the workflows that deploy to
Azure. For one repository:

```powershell
git -C "<repository>" log -1 --format="%D %h %ad" --date=short
```

```powershell
git -C "<repository>" ls-files "*.bicep" "*.bicepparam" "*.tf" "*.tfvars"
```

```powershell
git -C "<repository>" grep -l -E "azure/login|az deployment|az containerapp|az webapp|az acr|static-web-apps-deploy|webapps-deploy" -- ".github/workflows"
```

An estate has dozens of repositories, so run each of the three across all of them in one
pass. This is the first as a loop; the other two take the same form:

```powershell
foreach ($repository in (Get-ChildItem -LiteralPath "<estate-root>" -Directory | Where-Object { -not $_.Name.StartsWith('.') -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container) })) { "$($repository.Name): $(git -C $repository.FullName log -1 --format='%D %h %ad' --date=short)" }
```

`git grep` exits 1 when a repository has no match, so a loop that ends on such a repository
reports an error that is not one. A match can also sit in a comment: open each workflow the
search lists and confirm it deploys before counting it.

`git ls-files` and `git grep` read tracked files only. That is the right set, because
infrastructure of record is committed, and it does not skip dot-directories the way a `**`
glob does. Say in the report that untracked files were not read. A repository that is not
on its default branch is read as it stands; name it in the report's scope. Do not fetch,
pull or check out.

**Truncated history.** A repository's history is truncated when its first commit already
holds the infrastructure files whole: an open-sourcing reset, a history rewrite, or an
export from another repository, however long ago. The commits that record its early reasons
are not in it. Find where its history starts:

```powershell
git -C "<repository>" log --reverse --format="%h %ad %s" --date=short
```

If a backups root was supplied, list it and match folders to the repository by name; there
may be several, and an older name for the same repository counts. A backup folder may hold a
checkout, a mirror or a bundle: use whichever `git log` can read. Search that history as
well when looking for reasons in section 4, and cite a backup commit as such.
With no backups root, or no backup, say in the report's scope that the repository's reasons
before that date could not be searched.

The estate name used in paths below is the estate root's folder name.

## 2. Inventory

Take one UTC timestamp for the run. It names the report and its evidence folder:

```powershell
[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ss.fffffffZ')
```

Create the evidence folder, then run the inventory into it:

```powershell
New-Item -ItemType Directory -Path "<vault>\Claude\Azure Audit\<estate>\<timestamp>-evidence" -ErrorAction Stop
```

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/Get-AzureInventory.ps1" -SubscriptionName "<subscription-name>" -OutFile "<vault>\Claude\Azure Audit\<estate>\<timestamp>-evidence\inventory.json"
```

The script covers every enabled subscription in the named subscription's tenant. It writes
the resource groups (empty ones included), every resource with its properties and tags, the
child settings named in `references/child-reads.json`, and for each subscription its role
assignments, management locks and budgets. It throws, and the run stops, when the login is
missing, the subscription is not found, a top-level listing fails, the output folder does
not exist, or the output file exists. A throttled read is retried three times; any other
failed read is recorded and the run goes on.

Every resource has a `children.diagnosticSettings` entry. Each workspace's `children.tables`
lists every table with its plan and retention; most are on the default plan, so filter for
the ones that are not. Each subscription's `reads` holds its `locks` and `budgets`.

`skippedSubscriptions` names each subscription in the tenant that is not `Enabled`, with its
state. Such a subscription can still hold resources. Name each in the report's scope as not
audited.

Role assignments hold principal object ids, not names. Naming a principal needs Microsoft
Graph, which this skill never calls. Match the ids against the parameter files first; what
is left is `Not observed`, and the report says which command the operator can run. A role
is held as a role definition id. A GET of that id returns the role's name, and that read is
allowed.

The evidence folder holds identifiers the report must not: principal object ids, firewall
addresses, full resource ids. Keep it beside the report and do not copy from it wholesale.

`ConvertFrom-Json` turns `observedAt` into a local date. Quote the timestamp from the file's
text, not from a parsed query.

Read the evidence by query, not whole. For example, the resource types and their counts:

```powershell
(Get-Content -LiteralPath "<evidence-file>" -Raw | ConvertFrom-Json).subscriptions.resources | Where-Object { -not $_.platformManaged } | Group-Object type | Sort-Object Count -Descending | Select-Object Count, Name
```

Every read lands in one of four shapes. Tell them apart by property name:

| Shape | Meaning |
|---|---|
| `{ "items": [...] }` | A list that was read. An empty `items` is an observed empty list |
| Any other object | A single setting that was read |
| `{ "absent": true, "reason": ... }` | Looked, and it does not exist. For example, a Container App with no platform auth, or a PostgreSQL server with Entra sign-in off |
| `{ "notObserved": true, "kind": ..., "reason": ... }` | Could not look |

Before going on, collect three things for the report's scope section:

- **`unmappedTypes`.** Each is a live resource type the child-reads table has no entry for,
  so its child settings were never read. Report each as not observed and say the table needs
  an entry. Do not edit the table during a run.
- **Every `notObserved`.** In a resource's `properties`, in any `children` entry, in
  `roleAssignments`, or in a subscription's `reads`. Record the kind and the reason. Kind `post-only` is expected: the only
  route to that setting is a POST, which this skill never issues. Kind `error` is a read
  that failed; quote its reason. This lists them:

```powershell
$inventory = Get-Content -LiteralPath "<evidence-file>" -Raw | ConvertFrom-Json; foreach ($subscription in $inventory.subscriptions) { if (@($subscription.roleAssignments.PSObject.Properties.Name) -contains 'notObserved') { "$($subscription.name) role assignments: $($subscription.roleAssignments.reason)" }; foreach ($read in $subscription.reads.PSObject.Properties) { if (@($read.Value.PSObject.Properties.Name) -contains 'notObserved') { "$($subscription.name) / $($read.Name): $($read.Value.reason)" } } }; foreach ($resource in $inventory.subscriptions.resources) { if (@($resource.properties.PSObject.Properties.Name) -contains 'notObserved') { "$($resource.name): $($resource.properties.reason)" }; foreach ($child in $resource.children.PSObject.Properties) { if (@($child.Value.PSObject.Properties.Name) -contains 'notObserved') { "$($resource.name) / $($child.Name): $($child.Value.kind) - $($child.Value.reason)" } } }
```

- **Platform-managed resources.** `platformManaged` is true for resources Azure created in a
  managed resource group. Count them. They carry no decisions.

Test for `notObserved` and `absent` by property name, as the command above does. Do not
write `if ($value.notObserved)` on something that may be an array: in PowerShell a missing
property read across two or more objects is an array of nulls, which is true. Count with the
same care: `@($null).Count` is 1, so a setting that is null is not a list of one.

`NotObserved` is not "empty". A setting that was not observed supports no verdict except
`Not observed`. `absent` is an observation and supports a verdict.

## 3. Join live resources to Bicep

For each live resource that is not platform-managed, find the Bicep module that declares
it: same resource type, and a name that the module's parameters resolve to.

Decide which environment is deployed by observation. Where a repository has several
parameter sets (dev, demo, prod), resolve the names for each and match them against the
evidence. A set whose names are live is deployed. A set that matches nothing is an
environment that no longer exists. Use the deploy workflow's parameters as the cross-check.
Where the two disagree, or a set matches only in part, name the ambiguity in the report and
make no join claim for those resources. A parameter set that targets a subscription or
tenant outside this run's scope is out of scope, not absent: say so, and do not call its
environment dead.

Each resource and each declaration lands in one class:

| Class | Meaning | What to report |
|---|---|---|
| Declared and live | The normal case | Nothing by itself |
| Live, not declared | Created by hand, or left behind | A resilience finding, even when harmless |
| Referenced, not declared | A template uses the resource as `existing`, or takes its id as a parameter | Live and known to the template, created elsewhere. Report what creates it |
| Declared, not live | A deleted stack or a dead environment | Listed separately; its decisions are not tested against live Azure |

The join class is not a verdict. A live resource still gets its decisions and one verdict
each in section 5, whatever its class; the join exceptions are listed as well, in their own
table.

Compare child resources too. An incremental ARM deployment does not delete a child resource
that was removed from a template, so a live firewall rule, auth configuration or custom
domain that no template declares is "live, not declared".

A search miss is not proof of absence. Call a resource "not declared" only after every
repository in scope was enumerated as in section 1, and name what was searched.

**Terraform.** Where a repository keeps a Terraform mirror, compare it with the Bicep it
mirrors, by resource type and by the settings in section 4. Report differences as one
low-priority class, "mirror drift". Terraform is never a source of decisions or reasons, and
is never compared with live Azure.

## 4. Decisions and reasons

A decision is a choice the estate embodies that had an alternative. Walk each resource
through these dimensions. The second column says where to look first; the evidence file is
the authority, not this table.

| Dimension | Where to look first |
|---|---|
| Platform or service chosen | The resource type itself, against what the workload needs |
| Topology | How many copies of a stack exist and why: environments, a separate demo stack, a split across resource groups |
| SKU or tier | `sku`, `properties.sku`, `kind` |
| Region | `location`, against its resource group and its neighbours |
| Scale and replicas | Container Apps `properties.template.scale`; plan `sku.capacity` |
| Identity type | `identity.type` and `identity.userAssignedIdentities` |
| Authentication mode | Entra-only settings and administrators in `children`; local or shared-key switches in `properties`; a password-based connection string named in configuration |
| Authorisation model | How access is granted: Key Vault role-based access or access policies (`properties.enableRbacAuthorization`); role assignments and their scope |
| Network exposure | `children.firewallRules`, `children.virtualNetworkRules`, `properties.publicNetworkAccess`, private endpoint connections, virtual network injection |
| Data protection | Backup retention, high availability, redundancy and soft delete, in `properties` and `children` |
| Retention and caps | Workspace and component retention, daily caps |

Group the same choice across resources into one decision that lists its resources. Seven
Static Web Apps on one tier is one decision.

A decision that fits no row still counts. Give it a plain one-word dimension (`health`,
`naming`, `deploy`) and use that word consistently in its key.

A stale comment or document gets a row of its own, keyed
`documentation / <repository> / <subject>`, with the verdict `Contradicted`. It does not
change the verdict of the decision it describes: a decision whose premise was observed true
still `Holds` when a README about it is out of date. Count documentation rows apart from
decisions in the summary.

Estate-level absences are decisions too. Report each once. Where the thing exists and no
template declares it, report that instead, as "live, not declared".

- No alert rule, or alert rules that reach no action group with a receiver.
- No network security group.
- No private endpoint, so each resource's own network rules and identity are its only gates.
- No diagnostic setting. An empty `children.diagnosticSettings.items` means that resource's
  logs and metrics go nowhere. `absent` there means the type does not support them.
- No management lock. Read each subscription's `reads.locks`.
- No budget. Read each subscription's `reads.budgets`. The inventory keeps what was decided:
  that a budget exists, its amount, its period and its thresholds. It drops current and
  forecast spend and contact addresses, because spend belongs to `azure-cost-sweep` and the
  evidence holds no contact details. The amount is in the subscription's billing currency.

**Deploy path.** For each workflow that deploys to the subscription, answer five questions
and no more. This is not a workflow review; `audit-ci` does that.

1. Is there a preview step (`what-if`) before the deployment?
2. Is there a rollback step, or a documented rollback?
3. Do database migrations run before the new revision, and must they stay compatible with
   the previous one?
4. Is there a fixed wait where a poll on the real condition would do?
5. Are images deployed by digest or commit SHA, or by a moving tag?

**Known limit.** A decision that lives only in application code, such as a shared service
key or which credential class a client uses, is not visible from resources or Bicep. Say so
in the report's scope.

### Reasons

Look for each decision's reason in this order, and stop at the first source that states one:

1. A comment at the declaration in the Bicep.
2. The repository's README, specs, plans and runbooks:

```powershell
git -C "<repository>" grep -n -i "<term>" -- "*.md"
```

3. Git history for the setting, which also dates the decision. Search the repository's
   pre-reset backup too, if section 1 found one:

```powershell
git -C "<repository>" log -S"<setting-text>" --reverse --format="%h %ad %s" --date=short -- "<file>"
```

4. Cost sweep logs under `<vault>\Claude\Azure Cost Sweep\`.
5. The decision log, if one was supplied.

Each reason carries a status and its source:

| Status | When |
|---|---|
| `Recorded` | A source states the reason. Cite the `file:line` or the commit. You may assign this. |
| `Backfilled` | Only when the decision log says so. Quote it with its date. |
| `Default applied` | Only when the decision log says so. Quote it with its date. |
| `Unknown` | No reason found. List the sources searched. |

Status belongs to a claim, not to a decision: one decision can have a recorded reason for
one part and nothing for another. Keep them apart. In the register's one status column,
write the status of the reason for the choice itself, and say in the reason column which
part is recorded and which is not.

Never fill a gap with a confident story. If a reconstruction is worth offering, write it
under the literal prefix `UNVERIFIED:` and say what would refute it. It is never the
decision's reason and never changes its status.

Never write that the owner decided something unless a record says so. Most of the estate was
written by agents and approved by merge. Where a record supports it, the wording is
"agent proposed, owner approved".

## 5. Verdicts

Give every decision exactly one verdict.

| Verdict | Meaning |
|---|---|
| `Holds` | A reason is recorded and its premise was observed to be true today |
| `Premise gone` | The recorded reason's condition is no longer true |
| `Contradicted` | A comment or document says one thing and the Bicep or live Azure says another |
| `Inconsistent` | The same choice is made differently across the estate with no recorded reason for the difference |
| `Unrecorded` | No reason was found, so there is nothing to test |
| `Not observed` | The check could not be made. Say what was missing |

How to test a premise:

- **The reason cites a constraint** (a region, a quota, a tier that gates a feature, an API
  limit). Re-observe that constraint today. A reason that says two resources are in
  different regions is tested by reading both `location` values.
- **The reason cites a requirement in code.** Find the code again. If it is gone, the
  premise is gone.
- **The reason cites cost.** Use the cost evidence rule in section 6. Never query cost.
- **A comment and the live setting disagree.** `Contradicted`. Quote both.
- **Like resources differ on one dimension.** `Inconsistent`, unless a recorded reason
  explains the difference.

A premise may need one more read. It follows the same rule as the inventory: an HTTP GET,
through `az rest --method get`, with `--output json`. Filter the result in PowerShell. Do
not put a URL with `&` or a `--query` with parentheses on the command line: `az` is a batch
file on Windows and `cmd` breaks both. If the only way to read a setting is a POST, the
verdict is `Not observed`. A GET can still return a secret-bearing value: never call a path
that ends in a list action, and quote only the setting the premise needs. The form is:

```powershell
az rest --method get --url "https://management.azure.com<resource-id>/<child-path>?api-version=<api-version>" --output json
```

A premise that is a platform rule (a feature needs a tier, a setting needs a network shape)
is tested against current vendor documentation, found with the runtime's web search or
fetch tools, and the page is cited. A rule that could not be confirmed is `Not observed`;
recall is not an observation.

For a quota premise, find the provider's read-only usage endpoint in current Microsoft
documentation, with the runtime's web search or fetch tools, before calling it; do not
recall it. If there is none, the verdict is `Not observed`, with what would settle it.
Observed 2026-11-13: the App Service `locations/<region>/usages` path answers a GET with
`MethodNotAllowed`, so an App Service quota premise has no read here.

A premise that this run did not observe itself, but that a cost sweep log measured within
the last 30 days, may still be `Holds`. Say that the observation is the sweep's and give
its date.

Every verdict cites its observation: a `file:line`, a path into the evidence file, or the
command and its result. A verdict with no observation is not a verdict.

Every verdict other than `Holds` carries one recommendation: change it, record the reason,
or leave it. Give the footprint of a change (which files, which repositories, whether live
traffic is affected). Apply nothing.

## 6. Report

Create the report beside the evidence folder, with the timestamp from section 2:

```powershell
New-Item -ItemType File -Path "<vault>\Claude\Azure Audit\<estate>\<timestamp>.md" -ErrorAction Stop
```

Never overwrite a report. If the path exists, take a new timestamp. A run never edits an
earlier report or its evidence. If your file tool refuses to write to a file it has not
read, read the empty file first; do not delete and recreate it.

Sections, in this order:

1. **Scope.** Subscriptions with their resource counts, zero included. Repositories read,
   with branch and commit, and repositories excluded. Inputs supplied and absent. Everything
   not observed: unmapped types, each `NotObserved`, untracked files, application-code
   decisions.
2. **Comparison with the previous report.** The previous report is the newest earlier `.md`
   in the same folder. With none, write `FIRST RUN` and compare nothing. Otherwise match
   decisions on their key and mark each earlier finding still open, closed or changed. A key
   that was present and is now absent is reported as closed or renamed, never dropped.
3. **Findings**, ranked: `Premise gone`, then `Contradicted`, then `Inconsistent`, then join
   exceptions, then `Unrecorded`.
4. **Decision register.** One row per decision: key, decision, where, reason, status, date,
   verdict. This is the section to quote from. It is generated by this run and is not a
   second source of truth.
5. **Terraform mirror drift.**
6. **Proposed decision log edits**, as a diff, only when a decision log was supplied: new
   entries for decisions the log lacks, a "what would change it" line for entries without
   one, and corrections where an entry's evidence no longer says what the entry claims.
   Nobody applies them in this run.

Register rules:

- **Key.** The dimension, the resource type, and the resource name, or `estate` for an
  estate-level absence: `network-exposure / Microsoft.Sql/servers / <name>`. A decision
  grouped across resources is keyed by dimension, type and the shared value. One that is
  `Inconsistent` has no shared value: key it by dimension, type and the word `mixed`.
- **Date.** When the decision was made, with its source: the date the decision log gives, or
  the date of the commit that introduced the setting. `not recorded` when neither exists.
  For a setting already present in the first commit of a truncated history, write
  `on or before <that commit's date>`.
  The date a decision was observed is the run's timestamp; do not repeat it per row.

Cost evidence: for a tier decision, cite the newest cost sweep log in the vault that covers
the subscription, with that log's date. If it is more than 30 days old, say the figure is
stale and recommend `azure-cost-sweep`. With no log, the tier's cost is `Not observed`.

Finish by telling the user the report path, the count of decisions by verdict, the ranked
findings in one line each, and what was not observed. Remediation belongs to the owning
repository in a separate session. Open no pull request and edit no file outside the vault
folder.
