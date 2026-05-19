# Production-Grade Robustness Rubric

Last scored: 2026-05-19 on `next/modular-capability-engine`.

This rubric measures the whole repository, not only the modular engine
substrate. The existing modular-engine maturity scorecard remains the
substrate-specific score. This document covers Rust, iOS, Mac, scripts, docs,
tests, generated projects, CI, schemas, and repo support.

## Scoring Rules

Each axis receives one of these maturity levels:

- `0%`: no implementation or proof;
- `25%`: documented intent only;
- `50%`: implementation exists with targeted tests or static gates;
- `75%`: integration/failure coverage exists and docs are current;
- `100%`: complete evidence links, no known blockers, no duplicate path.

Current repo-wide score: **93/100**.

The score is intentionally lower than the modular-engine score because this
rubric includes remaining product-shell surfaces, older mixed domain test
layouts, Mac app coverage, dependency tooling, and retired schema ambiguity.

## Rubric

| Axis | Points | Current | 100% Definition |
|---|---:|---:|---|
| Architecture and ownership | 12 | 11 | Every package/submodule has one documented owner, purpose, and dependency direction |
| Folder and test organization | 10 | 8 | Folder layout mirrors architecture; tests are grouped by owning concern with no large catch-all files |
| Reachability and dead code | 10 | 8 | Every tracked source artifact is reachable or explicitly classified; dead code has absence gates |
| State and persistence | 10 | 8 | Durable truth, caches, projections, schemas, and generated files are all correctly classified |
| Security and authority | 12 | 12 | No raw-scope/client-policy trust; grants, secrets, sandboxing, file/network bounds are enforced |
| Resource/output correctness | 8 | 8 | Durable outputs are resource-backed or explicitly non-durable projections |
| Runtime reliability | 10 | 9 | Retry, crash, cleanup, recovery, idempotency, and partial failure paths are tested |
| Client thinness | 7 | 6 | iOS/Mac clients render server truth and do not own policy, lineage, grants, or durable state incorrectly |
| Observability and operations | 7 | 6 | Operators can inspect health, state, lineage, risks, actions, storage, and recovery paths |
| Dependency and supply-chain hygiene | 5 | 3 | Dependencies, generated code, package config, signing/trust, and scripts are justified and scanned |
| Docs and drift protection | 6 | 6 | README, progressive docs, architecture docs, and static gates stay synchronized |
| Deletion discipline | 3 | 3 | Removed/retired behavior has no compatibility aliases, fallback readers, stale docs, or hidden callers |

Total: **93/100**.

## Axis Evidence And Blockers

### Architecture and ownership - 11/12

Evidence:

- `README.md` maps top-level Rust modules and repository structure.
- `docs/production-grade-codebase-audit.md` classifies packages, engine
  primitives, resource submodules, module primitive submodules, domains, iOS,
  Mac, scripts, docs, and generated projects.
- `docs/modular-engine-cleanup-audit.md` and
  `docs/collapsed-modular-engine-architecture.md` define the collapsed
  substrate and cleanup decisions.
- `packages/agent/src/engine/tests/mod.rs` now acts as a declaration-only
  ownership map for engine tests, with shared fixtures isolated in
  `packages/agent/src/engine/tests/support.rs`.

Blockers:

- Some older domains still use historical folder/test conventions.
- Mac app ownership is classified at package/subsystem level, but it has not
  had the same depth of cleanup pressure as the Rust engine.

Next action:

- Migrate high-churn domain test layouts opportunistically, then run a Mac app
  focused ownership pass.

### Folder and test organization - 8/10

Evidence:

- Engine tests are fully in focused modules under
  `packages/agent/src/engine/tests/`; `mod.rs` has declarations only and
  `support.rs` owns shared fixtures.
- iOS and Mac tests are grouped under top-level Xcode test roots.
- Static gates protect several concern-owned engine test boundaries.
- `docs/production-grade-codebase-audit.md` documents the Rust Test Placement
  Convention for large subsystem test trees, sibling test files, and inline
  helper tests.

Blockers:

- Rust domains mix inline `#[cfg(test)]`, sibling `tests.rs`, and
  `*_tests.rs` layouts.

Next action:

- Apply the documented Rust test placement convention to broad/high-churn
  domains when those domains are touched.

### Reachability and dead code - 8/10

Evidence:

- `docs/product-shell-reachability-map.md` classifies remaining iOS product
  shells by entrypoint, DTO/client, server dependency, tests, and operator
  role.
- Static gates keep deleted Automations, fixed Voice Notes list, and Safari
  wrapper symbols absent.
- Runtime Prompt Library and Voice Notes no longer read old bespoke durable
  stores as source truth.

Blockers:

- Some deferred product-shell surfaces remain active pending generated UI or
  resource-backed replacement.
- Optional dependency dead-code tools are not installed in the local workflow.

Next action:

- Replace or remove one fixed product shell only after reachability proof shows
  a generated UI/control replacement.

### State and persistence - 8/10

Evidence:

- Modular engine state is collapsed into resources, invocations, grants,
  workers, queues, leases, approvals, decisions, evidence, streams, and
  generated UI resources.
- Prompt Library and Voice Notes durable outputs are resource-backed.
- Xcode projects are generated from `project.yml` and regenerate cleanly.

Blockers:

- Retired `prompt_history` and `prompt_snippets` tables still exist in the
  consolidated schema as inert documented tables.
- Notifications and some chat/product-shell state remain outside the resource
  model by explicit defer decisions.

Next action:

- Decide whether final cleanup needs a clean storage generation reset or keeps
  inert tables with permanent static gates.

### Security and authority - 12/12

Evidence:

- `grant::*` is the engine-owned authority path.
- Static gates forbid raw-scope authorization, worker token authority fallback,
  dynamic UI catalogs, `control::act`, action multiplexers, package/source/
  policy/trust/audit tables, and direct module process spawn/kill.
- Generated UI submits stored action coordinates only.

Blockers:

- No current blocker.

Next action:

- Keep adding adversarial tests at every new authority boundary.

### Resource/output correctness - 8/8

Evidence:

- `engine/tests/resource_kernel.rs` verifies resource refs, invalid outputs,
  damaged versions, CAS, and materialized file behavior.
- Prompt Library and Voice Notes conversions prove durable outputs are
  resource-backed.
- Filesystem/process/program/agent/module durable-output paths have resource
  contracts or explicit non-durable projection semantics.

Blockers:

- No current blocker for converted durable-output paths.

Next action:

- Audit deferred domains before any new durable output is added.

### Runtime reliability - 9/10

Evidence:

- Module activation, health, recovery, trust audit, queue retry, and local
  process soak tests exist.
- Full Rust CI passes with thousands of unit/integration/static tests.

Blockers:

- Longer soak, explicit interrupted process exit, and worker registration
  timeout fixtures remain future hardening work.

Next action:

- Add targeted lifecycle interruption/timeout tests after fixture design is
  stable.

### Client thinness - 6/7

Evidence:

- iOS Engine Console/generated UI tests prove server-authored action
  submission and fail-closed rendering.
- iOS project generation and targeted Engine Console/generated UI tests pass.
- Product-shell reachability map classifies remaining fixed surfaces.

Blockers:

- Remaining AgentControl, SourceChanges, Subagent, Notification, Prompt
  Library, display, and voice recording shells are not all generated UI yet.
- Mac app has not had equivalent generated UI/thin-client scoring depth.

Next action:

- Convert or justify one fixed shell at a time, starting from the reachability
  map.

### Observability and operations - 6/7

Evidence:

- Control projections, generated UI surfaces, module trust/health/recovery
  diagnostics, storage stats, and action consequence summaries exist.
- Module trust audit status and retention review are projection/evidence based.

Blockers:

- Operator consequences are strong for module/control surfaces, but not all
  remaining product shells expose generated resource lineage yet.

Next action:

- Expand generated UI/control replacement for one active shell.

### Dependency and supply-chain hygiene - 3/5

Evidence:

- Cargo lockfile and XcodeGen project inputs are tracked.
- Local Ed25519 package trust and module source policy are tested.
- Full Rust CI and targeted iOS generation/tests pass.

Blockers:

- `cargo machete`, `cargo udeps`, and `cargo llvm-cov` were not installed
  during the last audit.
- No Swift dead-code tool is part of the documented workflow.

Next action:

- Decide whether to add optional dependency/dead-code tools to the documented
  audit workflow or explicitly defer them.

### Docs and drift protection - 6/6

Evidence:

- README links architecture/audit/maturity docs.
- Static gates verify scorecards, cleanup maps, product-shell maps, and
  forbidden symbols.
- Progressive disclosure docs exist for key Rust module areas.

Blockers:

- No current blocker, assuming new production-grade docs remain linked and
  gated.

Next action:

- Keep README and local module docs updated with every structural change.

### Deletion discipline - 3/3

Evidence:

- Removed iOS product-shell surfaces have absence gates.
- Old Prompt Library store code remains deleted.
- Runtime ignores retired prompt tables and tests prove they are not source
  truth.

Blockers:

- No current deletion-discipline blocker; remaining items are classified as
  deferred rather than silently retained.

Next action:

- Continue remove-with-proof only; no compatibility aliases or fallback readers.

## Ranked 100% Backlog

1. Standardize Rust domain test placement where broad/high-churn domain test
   files still obscure ownership.
2. Resolve retired prompt schema ambiguity with either a clean storage reset or
   permanent inert-table gates.
3. Replace or remove one remaining fixed iOS product shell using generated UI
   and the reachability map.
4. Add or explicitly defer optional dependency/dead-code tooling.
5. Run a Mac app focused production-grade audit.
