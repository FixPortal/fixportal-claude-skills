# Validation checks

Run the relevant checks after changing the guidance or implementation named in
the purpose column; respect the owner's current test constraints. Resolve paths
from the loaded skill directory. PowerShell checks use
`pwsh -NoProfile -File test/<name>.ps1`; Python checks use
`python test/<name>.py`. Pester files use the repository's pinned runner, not
a direct script invocation.

These are skill contract checks, not evidence that a live application, vendor
API or estate audit has passed. Fixtures may write temporary files, start child
processes and temporarily change environment variables; inspect the linked
source before running them. A documented SKIP is unassessed coverage even when
the script exits zero. Record which portion skipped and why. Missing capabilities
without an explicit skip path remain failures.

This mirror does not publish the model registry, so the private set's
registry-selection check is omitted here. Checks below that read the registry
skip those assertions with a stated reason when it is absent.

| Check | Purpose / when relevant | Prerequisites and coverage limits |
|---|---|---|
| [verify-agy-review.ps1](../test/verify-agy-review.ps1) | Antigravity wrapper parameters, registry selection and child CLI invocation. | PowerShell 7, Python and the sibling model-registry files; fake child CLI fixture, not a live review. |
| [verify-batch-summary.ps1](../test/verify-batch-summary.ps1) | Accumulating chunk manifests and honest aggregation of failed or incomplete batches. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-claude-review-effort.ps1](../test/verify-claude-review-effort.ps1) | Forwarding the requested effort to the Claude child CLI. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-context-path-guard.ps1](../test/verify-context-path-guard.ps1) | Normalizing and rejecting invalid context paths before reviewers start. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-deepseek-wrapper.ps1](../test/verify-deepseek-wrapper.ps1) | Request/response model integrity and the counted repository-blind DeepSeek seat. | PowerShell 7 and sibling model-registry/registry.json; constructed responses, not a live API call. |
| [verify-moonshot-wrapper.ps1](../test/verify-moonshot-wrapper.ps1) | Request/response model integrity, omitted fixed sampling parameters, effort mapping, and the counted repository-blind Moonshot API seat. | PowerShell 7 and sibling model-registry/registry.json; constructed responses, not a live API call. |
| [verify-degrade-branch.ps1](../test/verify-degrade-branch.ps1) | Degrading failed wrappers without counting unavailable vendors. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-die-exit-codes.ps1](../test/verify-die-exit-codes.ps1) | Non-zero preflight exits for invalid context, targets and repository history. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-external-review.ps1](../test/verify-external-review.ps1) | Copilot fallback input isolation and scratch-only directory access. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-gemini-oauth-shadow.ps1](../test/verify-gemini-oauth-shadow.ps1) | Windows Gemini child credential isolation and usage sidecars. | PowerShell 7 on Windows; fake .cmd CLI and temporary credential fixture. Explicit SKIP off Windows. |
| [verify-glm-wrapper.ps1](../test/verify-glm-wrapper.ps1) | GLM child-only authentication, tool isolation, model checks and registry selection. | PowerShell 7, Python and sibling model-registry files; constructed responses, not a live vendor call. |
| [verify-ignored-parameters.ps1](../test/verify-ignored-parameters.ps1) | Warning when a CLI cannot apply a declared effort parameter. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-judge-input-integrity.ps1](../test/verify-judge-input-integrity.ps1) | Retaining substantive reviewer output for judging while assessing participation separately. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-kimi-review.ps1](../test/verify-kimi-review.ps1) | Refusing live repository access and accumulating streamed Kimi assistant frames. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-model-log-capture.ps1](../test/verify-model-log-capture.ps1) | Concurrent capture-stub appends without losing model-selection evidence. | PowerShell 7; concurrency fixture. Case-variant serialization coverage explicitly skips on a case-sensitive non-Windows filesystem. |
| [verify-model-telemetry.ps1](../test/verify-model-telemetry.ps1) | Failed-phase counting and separation of model selection from telemetry. | PowerShell 7, Git and Python; temporary repository and model-selection/telemetry fixtures. |
| [verify-no-superseded-conventions.ps1](../test/verify-no-superseded-conventions.ps1) | Rejecting the superseded explicit Opus approval requirement. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-observatory-endpoint.ps1](../test/verify-observatory-endpoint.ps1) | Environment-controlled telemetry endpoint with no private fallback. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-openai-base-url.ps1](../test/verify-openai-base-url.ps1) | Refusing an insecure HTTP gateway before credentials can be sent. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-phase-admission.ps1](../test/verify-phase-admission.ps1) | Finding admission, clean replies and round participation rules. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-registry-optional.ps1](../test/verify-registry-optional.ps1) | Literal-model fallback when the optional model registry is unavailable. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-report-shape.ps1](../test/verify-report-shape.ps1) | Report schema, reader agreement, repository coverage and remediation provenance. | PowerShell 7 and Git; temporary reports/repositories. Reader-agreement portion skips if sibling review-digest is absent; persisted-vault sweep requires OBSIDIAN_VAULT and the review directory. |
| [verify-round-diversity.ps1](../test/verify-round-diversity.ps1) | Per-round vendor diversity and rejection of misleading reused work. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
| [verify-start-patterns.ps1](../test/verify-start-patterns.ps1) | Round start patterns and timeout behavior without discarding useful prose. | PowerShell 7 and the shipped skill/reference/fixture files; see the linked source for the asserted cases. |
| [verify-trial-reviewers.ps1](../test/verify-trial-reviewers.ps1) | Trial-seat participation and its separation from counted panel requirements. | PowerShell 7 and Git; temporary driver/repository fixtures and stubbed reviewer processes. |
