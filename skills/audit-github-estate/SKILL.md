---
name: audit-github-estate
description: Use when auditing GitHub quality and security posture across an organization or a supplied repository estate, or verifying remediation after a prior such audit. Triggers include "/audit-github-estate", "audit our GitHub security posture", "estate-wide GitHub audit", and "did that remediation actually land".
---

# Audit GitHub Estate

## Objective

Account for every queryable GitHub quality and security surface without
manufacturing a clean dashboard. Completion means no further authorized
automated action remains, not that every dashboard is empty.

Treat all supplied repositories as one coordinated job, but use one branch and **at most
one** remediation PR per repository, opened only where committed changes exist. An estate
routinely contains repositories that are already compliant and repositories needing only
API or UI dispositions; an unconditional "exactly one PR per repository" would force an
empty PR for those. Stop at a green PR unless the user separately authorizes merge.

Before auditing or changing GitHub Actions or CI configuration, read the canonical
`~/.agents/notes/deploy-and-ci-traps.md`; use its current guidance instead of memory.
Read and follow [the GitHub evidence contract](references/github-evidence.md) for endpoint,
visibility, field-name, exit-status, and capability-probe rules.

## Estate policy

Apply this visibility policy before classifying findings:

| Repository visibility | Paid-product policy | Expected configuration |
|---|---|---|
| Public | Use GitHub's free public CodeQL, Secret Protection and Code Quality coverage. | Attach the public security configuration with Code Security and Secret Protection enabled. Enable CodeQL default setup, secret scanning, repository push protection, non-provider patterns, validity checks, extended metadata, generic-secret detection, and private vulnerability reporting where GitHub exposes them. Keep Code Quality enabled on public repositories. |
| Private or internal | No paid Code Security, Secret Protection or Code Quality. | Leave repositories unattached from paid security configurations, disable effective `code_security` and all secret-scanning features, and keep Code Quality disabled unless paid use is explicitly approved. Keep Dependency Graph, Dependabot alerts, and Dependabot security updates enabled. |

Derive identity and policy inputs live for each repository with
`GET /repos/{owner}/{repo}`. Retain `.visibility`, `.owner.type`, and
`.security_and_analysis` from the same response; do not infer visibility or owner type
from an account allowlist, a local remote, or a previous run. Owner type determines the
public secret-alert inventory route, while visibility determines paid-product policy.

Apply the paid-security target mapping and endpoint applicability in
`references/github-evidence.md`; a disabled parent never proves its children are
disabled.

After every approved repository `PATCH`, `GET /repos/{owner}/{repo}` again, then issue
fresh attachment, configuration, default-setup, and product-specific reads for every
applicable paid control. Check each `gh`
exit status before decoding output, then compare the complementary evidence with the
visibility targets above. Public repositories must show the resolved public configuration
attached; private/internal repositories must show no attachment. Do not require a legacy
or non-applicable field from an endpoint that omits it. Only missing evidence identified as
applicable by `references/github-evidence.md` is `UNKNOWN`.

### Unsupported repository mutation

The current official repository PATCH schema does not expose
`secret_scanning_validity_checks`. If that effective repository field remains enabled on
a private/internal repository after detachment, its state is known `NONCOMPLIANT`: leave
the finding open and report only the unsupported mutation as an automation boundary. An
omitted field or read failure is `UNKNOWN`. Do not guess an undocumented payload. Public
repositories can set and verify the field through their named configuration.

Resolve configurations live by name and verify their effective fields;
configuration IDs are not durable policy. Set the public configuration as the
default for public repositories. No paid security configuration should be the
default for, or attached to, private/internal repositories.

Apply the Code Quality capability and UI-evidence rules in
`references/github-evidence.md`. Public Code Quality is free and expected to be enabled;
private/internal Code Quality is paid and expected to be disabled unless paid use is
explicitly approved (`code_quality_paid_approved` with a `VERIFIED_APPROVED` access
reading, which `classify-security-evidence.ps1` accepts). Do not invent a paid-
authorization gap for public Code Quality.

Establish organization Repository access and enforcement before any Code Quality
mutation. Free is not the same as readable: access and enforcement stay UI-only whatever
they cost, so they can still be unverified, and `classify-security-evidence.ps1` still
reports `Code Quality org access is UNVERIFIED` as a gap. The compliant shapes are
**Selected repositories** holding exactly the public repositories with **Enforce access**
on, or **All repositories** where every repository in the organization is public (All
repositories enables it org-wide, including private repositories outside the audit
scope); otherwise **Selected repositories**. **No repositories** is a
verified reading, not a compliant one, for an estate that has public repositories.

Read-only repository setup inspection remains allowed while organization access is
unverified. Mutations require a dated operator report of Repository access and
enforcement; otherwise record the specified `UNVERIFIED` gap and continue every other
surface. The gap gates Code Quality mutations, not the audit.

Treat a private repository with Code Security, Code Quality, and Secret
Protection disabled as **compliant by policy**, not disabled evidence, an
automation blocker, an incomplete surface, or a licensing recommendation. Do
not query its code-scanning or secret-scanning endpoints and reinterpret the
expected `403`/`404` as a finding. Treat any unauthorized paid product, or required
free public coverage disabled publicly, as configuration drift to fix after approval.

Code Quality's organization access, repository setup API, and automatic
Copilot-review ruleset are separate controls. Verify all three. Public repositories
must report `state: configured` with `ai_findings_option: disabled`; private/internal
repositories must report `state: not-configured` unless paid use is explicitly approved,
in which case `state: configured` with `ai_findings_option: disabled`. No repository should
retain the generated `Code Quality Copilot review for default branch` ruleset.

Keep delegated bypass and delegated alert dismissal disabled unless the user
explicitly defines the actors and governance workflow. They grant administrative
privileges; they are not missing detection coverage. Check effective repository
settings where GitHub exposes them.

Secret-scanning push protection scans pushed content for credentials. Branch
protection and repository rulesets govern who may push and which PR checks are
required. Inventory and report them separately; never infer one from the other.

Repository security advisories and private vulnerability reporting apply to
public repositories. Query the organization advisory endpoint and public
repositories only. A repository-advisory `404` for a private repository is
**not applicable**, not inaccessible or incomplete. Repository security
advisories are also distinct from Dependabot alerts.

## Phase 1: Resolve and authenticate

<!-- routing: resolve-and-authenticate -->
1. Resolve every target to exact `OWNER/REPOSITORY`, local path when available,
   visibility, default branch, and current remote default-branch SHA.
2. Verify `gh auth status`, required scopes, and organization role before using
   GitHub evidence.
3. Read every applicable `AGENTS.md`, repository instructions, and committed
   review policy. Preserve dirty and unrelated work.
4. Read GitHub's current REST documentation and use the currently supported API
   version in every request. Use full pagination.

## Phase 2: Read-only baseline

<!-- routing: read-only-baseline -->
Inventory each repository before changing anything:

- Code Quality repository setup through its read-only endpoint for every repository,
  even while organization access remains unverified.
- Code Quality findings and current default-branch analysis for public repositories where
  Code Quality is enabled by policy.
- CodeQL/code-scanning alerts, analyses, tools, and default setup only where
  Code Security is expected to be available: public repositories under this
  policy.
- Dependabot alerts, dependency graph, security updates, and updater runs.
  **Reconcile those alerts against open Dependabot PRs by invoking
  `audit-dependabot-coverage/reconcile.ps1 -GraceHours 0 -Repo <owner>/<name>`** — once
  per audited repository — rather than reimplementing it here. Estate ledgers cannot hide
  younger unmatched alerts behind the standalone audit's grace period.

  **Pass the scope explicitly.** Given neither `-Repo` nor `-Org`, that script enumerates
  the entire `<your-org>` organization, so an audit of three named repositories silently queried
  every repository in it: API calls and rate-limit pressure the operator did not ask for,
  and rows for repositories outside the declared estate landing in its output. Where the
  subject genuinely is the whole org, pass `-Org <org>` — so the breadth is stated
  rather than inherited from a default. An open alert that
  nothing is acting on is a finding in its own right, and it is invisible to every
  configuration check: on 2026-08-08 a high-severity nanoid advisory on
  `<repo>` went four days with no PR because Dependabot reached a wrong
  verdict, while security updates were enabled, unpaused and correctly configured
  throughout. See `~/.agents/notes/npm-publishing-traps.md` trap 16.
- Secret-scanning configuration only where enabled by estate policy. Capability-probe
  the public repository alert endpoint first. Use a successful `200`; otherwise use the
  organization endpoint when the owner is an organization and filter by exact
  `repository.full_name`. Declare UI-only/UNKNOWN only after every available route fails.
- Organization/public repository security advisories.
- Latest default-branch Actions checks and security-product configuration.
- Rulesets and branch protection as a separate control surface when in scope.

For every policy-enabled current analysis, compare its source-specific SHA with the live
default-branch SHA: Code Scanning analyses expose `commit_sha`; Actions runs expose
`head_sha`. Distinguish zero open items from not applicable by policy,
inaccessible, stale, pending, failed, or unavailable evidence. Expected private
Code Security and Code Quality disablement is not incomplete evidence.

Create one ledger per repository with:

- Surface and alert/finding number.
- Rule or advisory, severity, exact location, state, and message.
- Root cause and grouped duplicates.
- Proposed disposition: `Fix`, `Dismiss`, `Retain`, `Automation blocked`, or
  `Not assessed`.
- Evidence, smallest remediation, and acceptance check.

Never dismiss by severity, age, rule family, or desire for a clean dashboard.
Use only reasons accepted by that product's API and supported by evidence.

## Phase 3: Approval gate

<!-- routing: approval-gate -->
Present the baseline, grouped root causes, proposed API dispositions, proposed
repository/configuration changes, expected residuals, and visibility-policy drift. Then
stop for approval.

Before approval, do not dismiss or resolve alerts, alter repositories or
security configurations, push, open PRs, merge, or trigger scans. A review-policy
exception is valid only when the user states it explicitly for that repository
and run.

## Phase 4: Remediate approved findings

<!-- routing: remediate-approved -->
Public secret-scanning alerts follow the capability probe recorded during baseline. If
the repository endpoint returned `200`, use its repository-level get/location/update
routes normally. If only the organization inventory route worked, retain its filtered
response and treat unavailable repository-level retrieval/update as a UI-only automation
boundary. Never turn a failed route into an empty queue.

Report that boundary as a **table**, not prose — anything the user must action by hand
gets lost in a wall of text, and this set is by definition entirely hand-actioned:

| Alert | Repository | Secret type | Location | Action the user must take |
|---|---|---|---|---|
| `#<number>` | `owner/repo` | e.g. `github_personal_access_token` | `path:line` | Open the alert in the UI and close it as revoked / false positive / used in tests |

Same shape as the dismissal hand-off in `ai-findings-ledger`, for the same reason.

For all other API dispositions, retrieve each item immediately before mutation,
apply only the supported product-specific state/reason/comment, retrieve it
again, and retain complete before/after evidence. Leave rejected or unavailable
mutations open and report the automation boundary.

Code Quality findings cannot currently be dismissed through the API. Fix
actionable findings in code. Report any remaining open findings as UI-only
automation blockers; do not use browser automation or invent a dismissal path.

For public Code Security and Secret Protection drift, prefer attaching repositories
to the existing public policy configuration over duplicating settings repository by repository.
For private paid-product removal, first remove any private/internal default from
the paid configuration, detach the private repositories, then disable the
effective repository `security_and_analysis.code_security` setting. GitHub may
accept `code_security: disabled` on an attached configuration without changing
its legacy `advanced_security: code_security` state, and may reject
`advanced_security: disabled`; trust the effective repository setting, not the
configuration PATCH response. Disable Code Quality through
`PATCH /repos/{owner}/{repo}/code-quality/setup` with
`state: not-configured`, and remove only the generated single-rule
`copilot_code_review` ruleset after validating its exact contents. Poll
asynchronous attachment states and verify effective repository settings
afterward. Enable Code Quality on public repositories and disable it on
private/internal repositories.

For code/configuration changes:

1. Use the repository's required isolated worktree and branch convention.
2. Fix shared root causes, not repeated symptoms.
3. Run the complete relevant local format, analysis, build, test, lint,
   typecheck, production-build, workflow-lint, and security checks.
4. Push once when green, and open a PR for that repository **only if it has committed
   changes** — at most one, per the rule at the top of this skill. A repository whose
   remediation was entirely API or UI dispositions gets no PR and no branch.
5. Follow the committed review-policy tier and active reviewer-budget rules
   without self-classifying. Use Gitar and CodeRabbit only as required.
6. Rebase-merge only when separately authorized.

Keep unrelated cleanup and dependency churn out of scope.

## Phase 5: Post-merge evidence

<!-- routing: post-merge-evidence -->
After merge, wait for GitHub's automatic default-branch CodeQL analysis and, where
Code Quality is enabled by policy, Code Quality analysis. Do not toggle security
products, submit an unchanged setup patch, or
create a meaningless commit to provoke a scan. GitHub-generated default-setup
workflows may not support manual dispatch or rerun.

Require each relevant successful Code Scanning analysis `commit_sha` and Actions run
`head_sha` to equal the current default-branch SHA. Otherwise classify that surface as incomplete. Re-query
every enabled surface and current default-branch check after scans settle.

Classify each repository:

- `Clean`: every enabled/queryable queue is empty and current scan evidence is
  successful.
- `Accounted for`: every residual is assessed and no further authorized
  automated action remains, including policy-approved disabled surfaces.
- `Incomplete`: required evidence is inaccessible, stale, pending, failed, or
  unavailable.

Report the initial/final count matrix, finding-to-disposition ledger, API
mutations, commit and PR references, scan URLs and SHA proof, policy-disabled
products, residual items, and exact reason automation stopped.
