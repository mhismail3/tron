---
name: tron-performance
description: Profile a real Tron bottleneck or compare implementations with controlled measurements and independent correctness checks. Use for latency, throughput, CPU, memory, I/O, and frame-performance work, not speculative tuning.
---

# Performance

Apply [project rules](../../../AGENTS.md). Measurements guide the decision; code
size, abstraction count, test duration, and a plausible hotspot are not evidence
of improved product performance. Keep experiments within the authorized scope.

## Choose the question

- **A reported bottleneck:** reproduce the user-visible cost, profile the full
  path, and rank contributors before editing. Separate computation, storage,
  serialization, contention, transport, rendering, and downstream waiting.
- **A choice between implementations:** compare the same complete task under
  equivalent conditions. Include setup, resource use, operational constraints,
  and maintenance cost where they affect the decision.

Reject correctness or configuration failures mislabeled as optimization. If no
representative baseline or credible bottleneck exists, report that limit and
leave production code unchanged. Fix the actual correctness issue through
[code health](../tron-code-health/SKILL.md).

## Freeze a small experiment

Before candidate results, record:

- The hypothesis and exact candidate revisions/configurations; ordinary, edge,
  and long-lived workloads representative of the reported problem.
- An independent correctness oracle and protected UI/UX, ordering, cancellation,
  identity, bounds, and cleanup behavior. Include known-good/bad controls and
  activation evidence so fallback or mixed execution cannot masquerade as success.
- Primary metric, units, measurement point, meaningful improvement threshold,
  allowed tradeoffs, repetitions, noise estimate, invalidation and stopping rules.
- Hardware, toolchain/build mode, data size, concurrency, warmup/cache state,
  instrumentation overhead, and other environmental controls.
- Run-owned resources, raw evidence locations, rollback, and the rule for retaining
  a change. Never register existing resources as experiment-owned cleanup targets.

Keep this proportional to the decision. Reuse existing diagnostics before adding
an instrument or harness. The measurement must see the effect being claimed;
simulator/debug timings cannot establish physical-device or release performance.

## Compare fairly and keep only demonstrated value

Test one causal change at a time. Favor deletion, simpler ownership, or existing
platform capabilities before introducing caches, batching, pools, or custom data
structures. Run correctness checks before interpreting speed.

Use matched workloads, permissions, timeouts, tuning budgets, and capture for all
candidates. Balance execution order; repeat the restored baseline when drift is
plausible. Preserve failures and raw samples. Report sample count, center, spread,
and relevant tail behavior; do not hide crashes, incorrect outputs, or exclusions
inside an average. Separate cold start, steady state, and saturation.

Retain a change only if correctness and the frozen improvement/tradeoff rule pass
beyond noise. Otherwise restore only experiment-owned edits. Establish a new
baseline after each retained change rather than attributing a compound result to
one edit. Stop when the target is met, gains disappear, or evidence runs out.

Report the decision as improved/selected, no change, or inconclusive, with exact
commands, before/after samples, rejected hypotheses, validation, cleanup, and
limits. Keep measured, synthetic, inferred, and qualitative claims distinct. A
simplification may be worthwhile without a speedup; label it as such rather than
manufacturing a performance claim.
