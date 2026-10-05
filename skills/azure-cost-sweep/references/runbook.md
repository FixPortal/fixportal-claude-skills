# Azure Cost Sweep Runbook

## Contents

- [0. Prior runs and drift](#0-prior-runs-and-drift)
- [1. Live cost and estate](#1-live-cost-and-estate)
- [2. Map cost to requirements](#2-map-cost-to-requirements)
- [3. Metrics and prices](#3-metrics-and-prices)
- [4. Report and persistence](#4-report-and-persistence)


## 0. Prior runs and drift

Before the bill, gather all four sources and select exactly one vault-log branch:

1. Use the runtime's ICM recall when exposed; otherwise resolve `icm.exe` on
   `PATH` and run a read-only cross-project recall for resource and repo names.
   If neither is available, record it as an **evidence gap** and continue — ICM can hold
   decisions that never reached the vault, so its absence weakens §0b's reconciliation,
   but it is not the load-bearing source and does not justify discarding everything else
   §0 gathered.
2. If a vault log exists, read the newest
   `<vault>\Claude\Azure Cost Sweep\<repo>\*.md` in full, especially Decisions,
   Rejected paths, Outcome, Persistence, and Follow-ups. If **no prior vault log**
   exists, record `FIRST RUN — no prior baseline` in the report, do not claim a
   prior-run reconciliation or a reverted saving, and continue with the live-estate
   evidence. The first run establishes the baseline for later reconciliation; it is
   not a stop.
3. Inspect owning IaC with `git log --follow -- <file>` and string-history
   searches for the SKU/tier.
4. Inspect sibling `.estate-audit-*`, `docs/audit`, and `docs/superpowers`
   folders.

When a prior log exists, compare every prior Outcome line with current spend:
`held`, `reverted`, or `partially held`. For a regression, calculate cost since
revert and use Azure activity logs to identify the writer. Live config agreeing
with IaC proves only that the last writer won. A human update followed by a
deploy-principal write is the usual revert fingerprint.

For suspected orphans, do not rely on `changedTime`. Resolve IaC naming
expressions for each environment and confirm deploy parameters select the live
name. Before deletion advice, check custom domains, recent deployments, inbound
links, and other load-bearing use. An undeclared but used resource is a
resilience finding even when it saves nothing.

## 1. Live cost and estate

Discover enabled subscriptions; never use a remembered ID. Include `--all` so
the filter is explicit, then select only records whose `state` is `Enabled`, whose
subscription `id` is non-empty, **and whose `name` is not the tenant pseudo-account label**
(`az` renders those as `N/A(tenant level account)`). Both conditions, because either alone
rests on an assumption:

> `UNVERIFIED:` that a tenant pseudo-account always carries an empty or absent `id`. The
> filter was the id test alone, and the contract test builds its own fixture with
> `id = $null` hard-coded — proving the filter works on the ASSUMED shape, which is not
> evidence the shape is real. Refuted by one run of `az account list --all -o json` under
> an identity with access to a second tenant: if every pseudo-account entry there shows an
> empty or absent `id`, the id test alone was sufficient. If any shows an `id` with
> `state: Enabled`, the id test alone would have queried Cost Management against
> `/subscriptions/<tenantId>/…`. The name test is correct under both shapes, which is why
> it stands regardless of how that run answers.

Query ActualCost through the Cost Management Query REST API grouped by ResourceId, over a fresh explicit
UTC window that **defaults to the last 30 days**: today's UTC date as the exclusive end,
30 days prior as the start.

The default is load-bearing. Every downstream requirement reports `£/month`, so
month-to-date, rolling-30-day and calendar-month runs all satisfy "a fresh explicit UTC
window" while producing monthly figures that are not comparable across runs — and §0b's
prior-run reconciliation compares exactly those figures. If a different window is
genuinely needed, state it in the report and normalise the headline to a 30-day
equivalent, saying that you did. Put JSON in a temporary file because PowerShell quoting
can corrupt inline bodies.

Use independent, copyable commands rather than a dependent shell variable:

```powershell
az account list --all --query "[?state=='Enabled' && id!=null && id!='' && name!='N/A(tenant level account)'].id" -o tsv
```

```powershell
az rest --method post --uri "https://management.azure.com/subscriptions/<subscription-id>/providers/Microsoft.CostManagement/query?api-version=2023-11-01" --body "@<workdir>\cost-query-body.json" -o json
```

Append `properties.rows` from every page. POST the same body to the exact
absolute `properties.nextLink`; do not rebuild its `$skiptoken`. Treat the first
page's columns and order as the row schema and stop if later pages differ. Sort
merged rows descending by Cost only after pagination ends.

Also enumerate live resources and request Azure Advisor Cost candidates.
Advisor is an input, never a verdict. Start with the largest billed lines.

## 2. Map cost to requirements

For each large line, find Bicep/Terraform/ARM, deployment scripts, and SDK use.
Extract tier-gated requirements before considering alternatives. Common checks:

| Cheaper move | Capability that may be lost |
|---|---|
| App/Container consumption or scale-to-zero | warm memory, long sockets, unbacked SignalR, cold-start SLA |
| Service Bus Premium to Standard | >256 KB messages, private endpoints/VNet, geo-DR, guaranteed throughput |
| App Service Premium to Basic/Free | slots, VNet, autoscale, Always On |
| SQL Business Critical to GP/serverless | local-SSD latency, read scale-out, zones, warm first query |
| Redis Premium to lower tier | persistence, clustering, VNet, SLA |
| Storage GRS to LRS | cross-region compliance/DR |
| Reservation/Savings Plan | workload flexibility |

Either rule out an unsafe move or pair it with the smallest required code
change and label its independent risk.

## 3. Metrics and prices

Pull utilisation before recommending a smaller SKU. Use the same stated window
as the cost comparison. Print returned point count and first/last timestamp;
Azure may silently truncate to retention. A later-than-requested first point
makes the omitted period UNVERIFIED.

Correlate peaks with activity-log writes so deployment/scale operations are not
mistaken for workload demand. When an older measurement is outside retention,
do not claim to refute it; state the evidence needed and default conservatively.

Estimate alternatives from Azure Retail Prices with `currencyCode='GBP'` and
verify each returned currency. Otherwise do not label the estimate `£`. Retail
pricing is an estimate; Cost Management billed data is the reconciliation truth.

## 4. Report and persistence

Open with prior-run reconciliation. For each resource, largest first, report:

- current config and billed £/month;
- code-required capabilities with `file:line` evidence;
- safe alternative or why none exists;
- estimated £/month and percentage saving with pricing basis;
- risk and prerequisite.

Total safe-now separately from with-work savings. At the start of persistence,
name the output with the current UTC timestamp:
`<vault>\Claude\Azure Cost Sweep\<repo>\<YYYY-MM-DDTHH-mm-ss.fffffffZ>.md`.
Create that exact path with `New-Item -ItemType File -ErrorAction Stop` before
writing it; if it already exists, use a newly captured UTC timestamp. Never
overwrite or force-write an older run. Include Decisions, measured Rejected
paths, Outcome before/after, Persistence owning `file:line`, and owned open
Follow-ups.

Use exactly:

| Status | Meaning |
|---|---|
| `APPLIED (live only) — NOT PERSISTED` | live changed; IaC unchanged |
| `PERSISTED — awaiting deploy` | IaC committed; live still old |
| `REALISED` | owning IaC committed and live re-read after deploy |

Only `REALISED` enters banked savings.
