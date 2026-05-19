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

Current repo-wide score: **98/100**.

The score is intentionally lower than the modular-engine score because this
rubric includes remaining product-shell surfaces, deferred dependency tooling,
and optional deeper lifecycle/soak proof.

## Rubric

| Axis | Points | Current | 100% Definition |
|---|---:|---:|---|
| Architecture and ownership | 12 | 12 | Every package/submodule has one documented owner, purpose, and dependency direction |
| Folder and test organization | 10 | 9 | Folder layout mirrors architecture; tests are grouped by owning concern with no large catch-all files |
| Reachability and dead code | 10 | 8 | Every tracked source artifact is reachable or explicitly classified; dead code has absence gates |
| State and persistence | 10 | 10 | Durable truth, caches, projections, schemas, and generated files are all correctly classified |
| Security and authority | 12 | 12 | No raw-scope/client-policy trust; grants, secrets, sandboxing, file/network bounds are enforced |
| Resource/output correctness | 8 | 8 | Durable outputs are resource-backed or explicitly non-durable projections |
| Runtime reliability | 10 | 9 | Retry, crash, cleanup, recovery, idempotency, and partial failure paths are tested |
| Client thinness | 7 | 6 | iOS/Mac clients render server truth and do not own policy, lineage, grants, or durable state incorrectly |
| Observability and operations | 7 | 6 | Operators can inspect health, state, lineage, risks, actions, storage, and recovery paths |
| Dependency and supply-chain hygiene | 5 | 4 | Dependencies, generated code, package config, signing/trust, and scripts are justified and scanned |
| Docs and drift protection | 6 | 6 | README, progressive docs, architecture docs, and static gates stay synchronized |
| Deletion discipline | 3 | 3 | Removed/retired behavior has no compatibility aliases, fallback readers, stale docs, or hidden callers |

Total: **98/100**.

## Axis Evidence And Blockers

### Architecture and ownership - 12/12

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
- `docs/product-shell-reachability-map.md` now records replacement readiness
  for every remaining fixed iOS shell.
- `docs/production-grade-codebase-audit.md` now includes a focused Mac app
  audit covering menu bar, onboarding wizard, server lifecycle, pairing,
  observability/feedback, bundled resources, generated project state, scripts,
  and tests.

Blockers:

- No current blocker for package/submodule ownership classification. Remaining
  product-shell replacement work is tracked under reachability and client
  thinness rather than ownership ambiguity.

Next action:

- Keep ownership gates current when any package, client surface, primitive, or
  script is added or removed.

### Folder and test organization - 9/10

Evidence:

- Engine tests are fully in focused modules under
  `packages/agent/src/engine/tests/`; `mod.rs` has declarations only and
  `support.rs` owns shared fixtures.
- Broad/high-churn domain tests for memory retain, MCP product protocol, and
  session commands now use focused `tests/` module trees with declaration-only
  roots and shared `support.rs` fixtures.
- iOS and Mac tests are grouped under top-level Xcode test roots.
- Static gates protect concern-owned engine and high-churn domain test
  boundaries.
- `docs/production-grade-codebase-audit.md` documents the Rust Test Placement
  Convention for large subsystem test trees, sibling test files, and inline
  helper tests.

Blockers:

- Some smaller domains still use sibling or inline tests by convention. They
  are acceptable today, but should be split if they become broad/high-churn.

Next action:

- Keep the convention enforced and split any future broad test file before it
  becomes a catch-all ownership problem.

### Reachability and dead code - 8/10

Evidence:

- `docs/product-shell-reachability-map.md` classifies remaining iOS product
  shells by entrypoint, DTO/client, server dependency, tests, and operator
  role.
- The same map now records replacement candidate, blocking gap, deletion risk,
  next prerequisite, and phase decision for AgentControl, SourceChanges,
  subagent sheets/plugins, notifications, Prompt Library, display stream, and
  voice recording.
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

### State and persistence - 10/10

Evidence:

- Modular engine state is collapsed into resources, invocations, grants,
  workers, queues, leases, approvals, decisions, evidence, streams, and
  generated UI resources.
- Prompt Library and Voice Notes durable outputs are resource-backed.
- Storage generation `modular-engine-v3` is a clean break that removes retired
  Prompt Library tables from fresh schemas. Static gates prove the active
  consolidated schema no longer creates `prompt_history`, `prompt_snippets`, or
  their indexes.
- Xcode projects are generated from `project.yml` and regenerate cleanly.

Blockers:

- No current blocker for known durable-output ownership. Notifications and
  remaining product-shell state are classified separately as transport,
  projection, or explicit deferred work before conversion.

Next action:

- Keep fresh-schema absence gates on and require resource-backed durable output
  for any newly converted domain.

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

### Dependency and supply-chain hygiene - 4/5

Evidence:

- Cargo lockfile and XcodeGen project inputs are tracked.
- Local Ed25519 package trust and module source policy are tested.
- Full Rust CI and targeted iOS generation/tests pass.
- `docs/production-grade-codebase-audit.md` records the current local
  dependency-tooling decision: `cargo machete: deferred`, `cargo udeps:
  deferred`, `cargo llvm-cov: deferred`, and `periphery: deferred`, each with
  revisit criteria.
- Mac release/package inputs, generated project ownership, helper staging, and
  signing/notarization assumptions are documented in Mac docs and the focused
  audit.

Blockers:

- Optional dependency/dead-code tools are explicitly deferred rather than
  adopted. The current repo does not yet have a pinned, low-noise
  dependency/dead-code scan for Rust or Swift.

Next action:

- Adopt a stable optional tool only after it is installed or pinned, configured
  for this repo, and proven low-noise enough for repeatable local/CI use.

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
- Retired Prompt Library tables are absent from fresh modular-engine-v3
  schemas; runtime Prompt Library truth is `artifact:prompt-*` resources.

Blockers:

- No current deletion-discipline blocker; remaining items are classified as
  deferred rather than silently retained.

Next action:

- Continue remove-with-proof only; no compatibility aliases or fallback readers.

## Ranked 100% Backlog

1. Replace or remove one remaining fixed iOS product shell using generated UI
   and the reachability map.
2. Adopt optional dependency/dead-code tooling when a stable, pinned, low-noise
   workflow exists. Current state is explicitly deferred with revisit criteria.
3. Add longer lifecycle/soak tests if runtime reliability target rises.
4. Standardize Rust domain test placement where broad/high-churn domain test
   files still obscure ownership. Completed for the current broad blockers
   (`memory::retain`, `mcp::product_protocol`, and `session::commands`); keep
   splitting future broad files before they become catch-alls.
5. Resolve retired prompt schema ambiguity. Completed by the
   modular-engine-v3 clean storage reset; keep absence gates on the fresh
   schema and Prompt Library runtime.
6. Product-shell readiness proof, dependency-tooling decision, and Mac app
   focused audit are completed evidence for the 98/100 checkpoint.
