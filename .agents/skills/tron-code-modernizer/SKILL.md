---
name: tron-code-modernizer
description: Modernize one bounded Tron capability when measured maintenance, workflow, dependency, bundle, or delivery value justifies replacing or removing an obsolete mechanism. Not for routine upgrades or tuning.
---

# Tron Code Modernizer

Modernize only when a bounded design produces proven net value. Prefer deletion,
simplification in place, existing platform capability, and existing dependencies
before adding software or abstraction. Revert changes that preserve neither
behavior nor the agreed benefit.

## Tron design constraints

- Preserve canonical runtime ownership and bounded projections. Do not recreate
  Engine, workers, event journals, SQLite session mirrors, duplicate settings or
  credential stores, or retired compatibility architecture.
- Production behavior must justify production code; remove test-only or
  speculative runtime surfaces instead of generalizing them.
- Code, focused tests, and owning documentation ship together.
- Gateway lifecycle transitions, production release/deployment, data migration,
  and local app replacement remain user/maintainer actions.

## Safety boundary

Read `AGENTS.md`, `CONTRIBUTING.md`, owning docs, manifests, Git status, public
contracts, persisted formats, and operational procedures. Preserve user changes
and isolate migration steps. Load `tron-ios` for all iOS build/artifact work.
Never apply a persisted-data/config migration outside a disposable copy, change a
public/product contract, adopt incompatible licensing, or modify external state
without explicit authorization. Never initiate Gateway lifecycle transitions.

## Workflow

1. **Define value.** Name the capability, current pain, affected user/developer/
   operator, protected behavior, success metric, constraints, and non-goals.
   Baseline behavior plus workflow steps, maintenance incidents, code/dependency
   duplication, bundle/startup cost, or delivery friction as applicable. Return
   `NO_CHANGE` for aesthetic or speculative modernization.
2. **Map the existing mechanism.** Trace owners, contracts, consumers, runtime
   registration, configuration, persisted data, dependencies, tests, docs, and
   failure/recovery paths. Record run-owned worktrees, processes, and artifacts.
3. **Evaluate options in order.** Compare retain, delete obsolete paths, simplify
   in place, use standard library/platform/framework capability, reuse installed
   dependency, then adopt external software. Consider workflow concepts removed,
   code/adapters added, dependency/bundle delta, security, license, runtime
   support, maintenance activity, operations, rollback, and lock-in.
4. **Close semantic gaps.** For replacements compare normalization, Unicode/time/
   precision, ordering, errors, cancellation, streaming, concurrency, bounds,
   security limits, lifecycle, and exit strategy. Use official evidence for the
   exact candidate version.
5. **Select or stop.** Record `SELECTED`/`REJECTED` alternatives. Ask for product
   direction only when public compatibility, licensing, persisted migration,
   vendor commitment, or irreversible operations materially change intent.
6. **Migrate at one boundary.** Add focused characterization/differential evidence
   when old and new can run on representative/adversarial inputs. Update required
   callers, types, config, registration, tests, generation, and owning docs. Keep
   compatibility only for a verified consumer with a removal trigger.
7. **Remove the old path.** Search dynamic imports, registries, reflection,
   generation, scripts, optional features, docs, config, and external entrypoints
   before deletion. Inspect the diff for churn and accidental contract changes.
8. **Prove net value.** Run focused then final relevant verification and compare
   the frozen benefit metric. `KEEP` only when behavior and value pass; otherwise
   `DISCARD` all run-owned migration changes and clean only run-owned resources.

## Report

Use `MODERNIZED`, `PARTIAL`, `NO_CHANGE`, or `BLOCKED`. Report target/baselines,
alternatives, semantic-gap evidence, migration steps, code/dependency/artifact
delta, test and documentation changes, metrics, rollback state, residual adapters,
external dependency risks, skipped authorization, and cleanup evidence.
