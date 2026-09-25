# GitHub evidence contract

Use API version `2026-03-10`. Capture every `gh api` call as exit code, HTTP status,
and response body. Check the exit code before decoding the body; `gh` can print an
error body to stdout. A failed call or missing applicable field is `UNKNOWN`, never a
disabled control or an empty queue.

## Endpoint and visibility rules

GitHub's repository and configuration APIs use different names for some controls:

| Effective repository field | Configuration counterpart | Public | Private/internal |
|---|---|---|---|
| `code_security` | `code_security` | `enabled` | `disabled` |
| `secret_scanning` | `secret_scanning` | `enabled` | `disabled` |
| `secret_scanning_push_protection` | `secret_scanning_push_protection` | `enabled` | `disabled` |
| `secret_scanning_ai_detection` | `secret_scanning_generic_secrets` | `enabled` | `disabled` |
| `secret_scanning_non_provider_patterns` | `secret_scanning_non_provider_patterns` | `enabled` | `disabled` |
| `secret_scanning_validity_checks` | `secret_scanning_validity_checks` | `enabled` | `disabled` |
| `secret_scanning_delegated_alert_dismissal` | `secret_scanning_delegated_alert_dismissal` | `disabled` | `disabled` |
| `secret_scanning_delegated_bypass` | `secret_scanning_delegated_bypass` | `disabled` | `disabled` |

Configuration-only targets:

| Configuration field | Public configuration | Private/internal |
|---|---|---|
| `secret_protection` | `enabled` | `not attached` |
| `code_scanning_default_setup` | `enabled` | `not attached` |
| `code_scanning_delegated_alert_dismissal` | `disabled` | `not attached` |
| `secret_scanning_extended_metadata` | `enabled` | `not attached` |
| `private_vulnerability_reporting` | `enabled` | `not attached` |

Inventory legacy `advanced_security`, but do not use `advanced_security` as a substitute for the individual `code_security` and `secret_protection` fields. Configuration
`secret_protection` and repository secret-scanning children remain separate evidence.

| Evidence | Public | Private/internal |
|---|---|---|
| `GET /repos/{owner}/{repo}` | Derive visibility, owner type, and the secret-scanning fields actually returned. An omitted legacy `code_security` field is not required. | Require effective `code_security`, `secret_scanning`, push protection, non-provider patterns, and validity checks to be disabled. Delegated and AI-detection fields may be omitted and are not evidence gaps — but where one **is** returned it must also be `disabled`, since an enabled paid control is the drift this audit exists to catch. |
| `GET /repos/{owner}/{repo}/code-security-configuration` | Require `200` with `status: attached` or `status: enforced` (the API's key is `status`, and identity lives under the response's `configuration` object, not at the top level). **Every** comparable field of that object — `id`, `name` — must match the separately loaded required public configuration; a match on `name` alone is an evidence gap, not a pass, because the wrong configuration can share a display name. | Require the documented no-content `204`; `200` is paid configuration drift. |
| Named code-security configuration | Verify every field returned by the named public configuration. `code_security` and `secret_protection` may be omitted; use product-specific endpoints for those products. | Not applicable when unattached. |
| `GET /repos/{owner}/{repo}/code-scanning/default-setup` | Required `state: configured`. | Not queried under the paid-product policy. |
| Code Scanning analyses | Latest successful default-branch analysis uses `commit_sha`; compare it with the live default-branch SHA. | Not queried under the paid-product policy. |
| Actions workflow runs | Latest required run uses `head_sha`; compare it with the live default-branch SHA. | Same. |
| `GET /repos/{owner}/{repo}/code-quality/setup` | Require the policy-expected enabled/configured state for public repositories. | Require the policy-expected disabled/not-configured state for private/internal repositories. |
| Code Quality findings/analysis | Query for public repositories where Code Quality is enabled by policy. | Do not query when Code Quality is disabled by policy. |

Organization Code Quality repository access and enforcement remain UI-only, and being
free does not make them readable. When the operator has not supplied them, record
`Code Quality org access: UNVERIFIED (UI-only, awaiting operator)`. Continue read-only
repository setup inspection and every non-Code-Quality surface. Gate Code Quality
mutations, not the whole audit — `classify-security-evidence.ps1` still raises
`Code Quality org access is UNVERIFIED` as a gap, and it is a gap in what was READ.

Free public Code Quality changed the EXPECTATION, not this evidence rule: public
repositories are expected enabled and private/internal disabled. Do not record a
paid-authorization gap for public Code Quality, and do not gate public findings reads on
billing evidence.

## Secret-scanning alert capability probe

For each public repository, call
`GET /repos/{owner}/{repo}/secret-scanning/alerts` first. A successful `200` is the
inventory source, including an empty array. If it is unavailable and the owner is an
organization, call `GET /orgs/{org}/secret-scanning/alerts` and filter the response by
exact `repository.full_name`. Classify the inventory as UI-only/UNKNOWN only after every
route available to that owner has failed. Never infer a zero queue from `404`.

## Executable response check

Store captured responses in the sanitized envelope shape used under `test/fixtures/`
and run `scripts/classify-security-evidence.ps1`. The script intentionally accepts
omitted non-applicable fields and fails closed on CLI failure, malformed JSON, stale
`commit_sha`/`head_sha`, or missing applicable evidence.
