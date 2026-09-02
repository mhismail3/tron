---
name: tron-surgical-change-implementer
description: Implement one bounded Tron product-code change through the smallest complete root-cause solution with focused tests and owning documentation. Use for scoped delivery, not audits, upgrades, modernization, or tuning.
---

# Tron Surgical Change Implementer

Deliver one approved outcome with the fewest concepts, states, branches, files,
dependencies, and changed lines that form a complete root-cause solution.
Surgical does not mean superficial: fix the canonical owner once and remove the
superseded mechanism.

## Tron constraints

- Read `AGENTS.md`, `CONTRIBUTING.md`, nearest package docs, architecture decisions,
  and Git status. Preserve unrelated user work.
- Code, focused tests, and owning documentation ship together.
- Preserve canonical runtime ownership, per-session serialization, command-ID
  receipts, disconnect/reconnect semantics, bounded projections, credential
  stores, and manual release/deployment boundaries.
- Do not recreate retired Engine/workers, event journals, session mirrors, or
  speculative compatibility paths. Production behavior must justify production code.
- Never initiate Gateway rebuild/update/rollback/promotion/restart, mutating
  `scripts/tron dev`, production release/deployment, `/Applications` replacement,
  archive/upload, device install, or persisted/external mutation beyond explicit
  task authority. Load `tron-ios` for all iOS work.

## Workflow

1. **Establish the contract.** Resolve business outcome, affected user/operator,
   acceptance evidence, approved mutation scope, protected behavior, constraints,
   and non-goals. Turn each applicable requirement into a traceable acceptance row.
   Stop `BLOCKED` rather than inventing product intent or a safe edit boundary.
2. **Trace ownership.** Follow the observable entrypoint through owning logic,
   state, persistence/integration, failure handling, tests, docs, configuration,
   callers, and public/internal contracts. Distinguish baseline/user changes.
3. **Choose the lowest complete rung.** Evaluate in order:
   `NO_CHANGE`, `DELETE_OR_CONFIGURE`, `REUSE_LOCAL`, `USE_PLATFORM_OR_STDLIB`,
   `REUSE_INSTALLED`, `ADOPT_DEPENDENCY`, then `MINIMAL_CUSTOM`. Record why lower
   rungs fail. Judge total system complexity and risk, not syntax length.
4. **Challenge the design.** Reject symptom patches, copied policy, duplicate
   state, wrappers around clear APIs, speculative abstractions, hidden branching,
   custom infrastructure the platform owns, and compatibility with no consumer.
   Define coherent edit, deletion, evidence, and rollback boundaries before editing.
5. **Implement at the owner.** Follow repository conventions for naming, types,
   configuration, errors/logging, security, accessibility, concurrency,
   transactions, cancellation, bounds, and resource lifecycle. Use native
   generation/package workflows; never hand-edit lockfiles/generated artifacts.
6. **Delete superseded paths.** Remove obsolete branches, helpers, flags, aliases,
   exports, config, dependencies, tests, and docs. Before deletion inspect dynamic
   imports, reflection, registries, generation, scripts, optional features, and
   external consumers. Keep a temporary bridge only for a verified consumer with
   an owner and removal trigger.
7. **Build proportionate evidence.** Map each acceptance row and material regression
   to existing evidence. For each affected test/gap choose `KEEP`, `ADD`, `UPDATE`,
   `MERGE`, `DELETE`, or justified `NO_TEST`. Prefer the widest reliable observable
   boundary, but use a focused owner when it proves the risk more deterministically.
8. **Verify efficiently.** Run the smallest owning checks after the coherent edit;
   expand to relevant build/type/test/policy/package checks only after they pass.
   Exercise material error, authorization, transaction, concurrency, retry,
   cancellation, and rollback boundaries. Run `scripts/personal-info-guard.sh`.
9. **Prove completeness.** Trace every requirement to code and observed result,
   search for stale/duplicate mechanisms, explain every changed file, and remove
   opportunistic cleanup. `KEEP` only when acceptance and required gates pass;
   otherwise discard only run-owned edits without touching user work.

## Report

Use `DELIVERED`, `NO_CHANGE`, or `BLOCKED`. Report change contract, selected rung,
acceptance traceability, canonical owner, additions/removals, focused and final
commands/results, test portfolio decisions, owning documentation updates,
unchanged external/persisted state, deviations, cleanup, and residual risks.
