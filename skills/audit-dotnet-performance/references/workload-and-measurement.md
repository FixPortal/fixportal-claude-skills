# Workload and measurement

Choose a workload in this order:

1. Trusted existing benchmark.
2. Representative existing test or executable workload.
3. Supplied trace or artifact.
4. Ephemeral harness, only after explicit single-harness approval or verification against an explicit enumerated batch approval.
5. A static opportunity classified `Unmeasured` when none is safe.

First decide whether a measurement is warranted. If repository inventory shows no
materially performance-sensitive path, performance contract, or plausible scale
risk, record `No benchmark required` and why; do not invent a workload, create a
harness, or leave performance as an unassessed gap. If a material performance
question exists but no representative workload or supplied artifact can answer it,
record that specific evidence gap as `Unmeasured` and stop. Lack of an existing
benchmark project alone does not decide either outcome.

Measured claims require a Release build; baseline and candidate identities; warmup; multiple measured iterations; environment capture; raw artifact retention; and profile-first attribution before proposing a fix. Include the workload, environment, command, raw artifact location, repetitions, statistic, baseline identity, and limitations.

Consider throughput, latency percentile, allocation, CPU, GC, startup, I/O, lock/contention, and exceptions, but report a dimension only when it is evidenced. Use native choices suited to the evidence: an existing BenchmarkDotNet benchmark, `dotnet-counters`, `dotnet-trace`, or framework logging/metrics. Do not install or prescribe every tool. Process and GC dumps are excluded in v1 even for controlled non-production processes.

Do not treat a single-invocation `Stopwatch`, Debug build, one run, elapsed time without workload count, or mixed-machine results as fully benchmarked evidence.

For an enumerated batch, record every repository path, proposed operation, permitted package/tool dependency, and isolated external root in the approval request. The batch avoids repeated prompts; it does not permit an unlisted repository, a broader workload, another dependency, or a repository-local harness.
