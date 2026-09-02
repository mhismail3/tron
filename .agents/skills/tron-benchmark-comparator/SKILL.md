---
name: tron-benchmark-comparator
description: Compare Tron tools or implementations with symmetric reproducible A/B workloads, independent correctness oracles, and controlled measurements. Use to choose alternatives, not optimize a known bottleneck.
---

# Tron Benchmark Comparator

Compare alternatives under a frozen experiment contract. Correctness and task
completeness precede speed, tokens, cost, or code size. Do not redesign scenarios
or decision rules after seeing a preferred candidate.

## Hard boundaries

- Read `AGENTS.md`, repository instructions, and Git status before creating any
  harness, worktree, temporary account, or dataset.
- Keep the source baseline unchanged unless the user explicitly approves a
  benchmark harness as repository work. Use clean isolated copies from one commit.
- Never benchmark against production, mutate canonical sessions/data, expose
  credentials or personal content, or initiate Gateway lifecycle, deployment,
  release, archive, app replacement, or device-install operations.
- For iOS benchmarks load `tron-ios`; use only the owned scheme/configuration,
  simulator/device, repository helpers, and signed-artifact authority.
- Record every run-owned path, process, cache, account, dataset, and artifact.
  Never clean pre-existing resources or credentials.

## Workflow

1. **Freeze the decision.** State candidates, intended users, representative
   ordinary and edge scenarios, non-goals, inputs, prohibited effects, expected
   outcomes, and an oracle independent of candidate self-report.
2. **Freeze metrics and rule.** Define primary/secondary metrics, units,
   measurement point, correctness threshold, allowed tradeoffs, tie/inconclusive
   rule, invalidation rules, minimum meaningful effect, and pilot-derived
   repetitions or bounded stopping rule. Hash scenarios, fixtures, runner, parser,
   and rule before candidate results.
3. **Build a symmetric harness.** Use the same revision, runner, timeouts, logging,
   permissions, environment, hardware, runtime, data, model/prompts when relevant,
   cache/warmup policy, network conditions, tuning budget, and artifact capture.
   Inventory global instructions, plugins, hooks, credentials, and caches that
   could contaminate one arm.
4. **Validate the harness.** Prove parser/oracle/metrics on known pass and fail
   fixtures. Add activation evidence showing the intended candidate actually ran
   without fallback or mixed execution. Separate one-time setup from steady state.
5. **Execute fairly.** Balance or randomize order. Capture start/end state,
   command, status, timing/resources, logs, outputs, diff, tests, activation, and
   artifacts. Grade completeness and correctness before performance. Preserve raw
   failures and classify timeout, crash, malformed output, setup, environment,
   fallback, and incorrect result separately.
6. **Analyze validity.** Exclude only predeclared invalid cases and report whether
   exclusion changes the conclusion. Show per-scenario raw values, sample size,
   center, spread, failures, and relevant confidence. Keep different units and
   workloads separate; label measured, derived, estimated, synthetic, and
   qualitative evidence.
7. **Decide and clean.** Use `WIN <candidate>` only when correctness and the frozen
   rule pass; `TIE` for operationally negligible/balanced outcomes;
   `INCONCLUSIVE` for inadequate or conflicting valid evidence; `BLOCKED` when
   candidates are not comparable, effects cannot be isolated, or no independent
   oracle exists. Clean only ledger-owned resources.

## Report

Return the hashed experiment contract, exact candidate configuration, activation
proof, harness validation, per-scenario results, invalid/excluded runs,
confounders, setup and maintenance cost, verdict rationale, sensitivity and
falsification conditions, reproducible commands/artifacts, cleanup proof, and
residual decision risks.
