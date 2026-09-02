---
name: tron-performance-optimizer
description: Optimize a measured Tron latency, throughput, memory, CPU, allocation, or I/O bottleneck through profiling and reversible experiments. Use for known bottlenecks, not speculative tuning or A/B selection.
---

# Tron Performance Optimizer

Retain a change only when comparable measurements improve a predefined metric
beyond noise and correctness, resource safety, and operational constraints pass.
Do not optimize by aesthetics or against a workload different from the problem.

## Hard boundaries

- Read `AGENTS.md`, `CONTRIBUTING.md`, owning package docs, and Git status.
  Preserve user work and isolate experiments when generated data or edits could
  interfere.
- Never load-test production, expose sensitive payloads, open a canonical session
  in another runtime, or initiate Gateway rebuild/update/rollback/promotion/
  restart, mutating `scripts/tron dev`, deployment, release, archive, or install.
  Never `SIGSTOP` or otherwise OS-suspend Gateway-owned work; use its owning
  session's soft interrupt or stop control.
- For iOS profiling/build/test/device work, load `tron-ios`. Use
  `Tron Device Performance` + `DevicePerformance` only for the owned physical
  hosted-test route and never install it through the ordinary device helper.
- Start with focused owning correctness tests. Reserve full suites for the final
  retained state.

## Workflow

1. **Freeze the experiment contract.** Define user-visible problem, target path,
   representative workload, environment/build mode, primary metric, repetitions,
   minimum meaningful improvement, constraints, and stop rule before editing.
   Reject correctness, configuration, capacity, dependency, or observability
   failures incorrectly framed as performance work.
2. **Protect state.** Record every run-owned worktree, temporary path, process,
   cache, profile, and artifact. Never register pre-existing resources for cleanup.
3. **Establish baseline.** Match the observed metric: latency distribution,
   throughput, CPU, memory, allocations, I/O, query count, lock wait, frame time,
   or energy. Fix data size, concurrency, cache/warmup, toolchain, hardware, and
   network. Preserve raw samples, center, spread, failures, and environment.
4. **Profile end to end.** Build a ranked cost map before focusing on a function.
   Trace top costs through Gateway, Mac, iOS, backing SDK, storage, and external
   services in scope. Separate cold start, steady state, saturation, debug-build
   artifacts, measurement overhead, and downstream symptoms.
5. **Form bounded hypotheses.** For each candidate state mechanism, expected metric
   delta, affected files, regression risk, dependencies, and rollback. Check
   existing platform/runtime/dependency capabilities before custom caching,
   batching, pools, schedulers, serializers, or data structures.
6. **Run one reversible experiment at a time.** Make the smallest coherent edit.
   Protect ordering, idempotency, cancellation, backpressure, timeouts, bounds,
   invalidation, canonical ownership, and disconnect/retry semantics. Run focused
   correctness checks, repeat the exact benchmark, and inspect the diff.
7. **Keep or discard.** `KEEP` only beyond noise with every constraint passing;
   otherwise revert only the run-owned experiment. After a keep, establish the
   compound baseline before another hypothesis.
8. **Finalize.** Stop at the target, diminishing returns, exhausted evidence, or a
   missing prerequisite. Run relevant final build/tests and policy guards; clean
   only ledger-owned resources.

## Verdicts

- `IMPROVED`: at least one retained change beats the frozen threshold.
- `NO_CHANGE`: all experiments are discarded and the baseline is restored.
- `BLOCKED`: no reproducible baseline, safe proxy, required environment, or safe
  restoration path exists.

## Report

Return target and frozen contract; baseline/profile table; each kept/discarded
hypothesis; raw and summarized before/after measurements; correctness and policy
checks; changed tests/docs; cleanup evidence; limitations; and residual
bottlenecks. Label measured, synthetic, estimated, and qualitative evidence.
