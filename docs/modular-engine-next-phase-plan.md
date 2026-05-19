# Product Shell Replacement, Dependency Audit, And Client Thinness Phase

## Current Checkpoint

The domain test ownership and retired prompt schema cleanup checkpoint is
complete:

- broad/high-churn Rust domain tests for memory retain, MCP product protocol,
  and session commands now use focused `tests/` module trees with
  declaration-only roots and shared support fixtures;
- storage generation is `modular-engine-v3`;
- fresh consolidated SQLite schema no longer creates retired
  `prompt_history`, `prompt_snippets`, or prompt-library indexes;
- Prompt Library history/snippets continue to use `artifact:prompt-*`
  resources as durable truth and tests prove behavior with retired tables
  absent;
- static gates protect the new domain test layout, clean storage generation,
  prompt-table absence, and resource-backed Prompt Library runtime.

The repo-wide production-grade baseline is now `96/100`.

## Objective

Close the remaining repo-wide blockers without broadening the architecture:

1. replace or remove one remaining fixed product-shell surface only when
   generated UI/control/resource projections cover the current role;
2. add or explicitly defer dependency/dead-code tooling with a stable local
   workflow;
3. perform a focused Mac app production-grade audit comparable to the Rust/iOS
   audit depth.

No new public capability ids, storage tables, resource kinds, generated UI
catalogs, compatibility readers, fallback DTOs, `control::act`, iOS/Mac policy
ownership, marketplace flows, remote fetch, or alternate worker-spawn paths are
allowed.

## Implementation Plan

### 1. Re-evaluate Product-Shell Reachability

Use `docs/product-shell-reachability-map.md` as the deletion bar. For each
remaining fixed shell, verify current entrypoints, DTO/client dependencies,
server capability/event dependencies, tests, and operator role:

- AgentControl inspection cards;
- SourceChanges sheets;
- subagent sheets/plugins;
- notification inbox/detail views;
- Prompt Library sheets/state;
- display stream views;
- voice recording affordances.

Classify exactly one candidate as ready for generated UI/control replacement,
or document why no candidate meets the bar. Do not delete an active surface
unless the map proves the replacement preserves the current operator workflow.

### 2. Replace Before Removing

For the selected shell:

- identify every Swift view, navigation path, DTO/client, view model, test,
  preview, project reference, and README/doc reference;
- identify the canonical server projection, resource refs, or generated
  `ui_surface` that replaces it;
- add replacement-path tests before deletion;
- delete the fixed surface, stale navigation, DTO/client code, tests/previews,
  and docs in the same checkpoint;
- add absence gates for retired symbols and route names.

The client must remain a thin renderer/action submitter. It must not construct
target function ids, grants, payload templates, resource lineage, or policy
decisions.

### 3. Dependency And Dead-Code Tooling Decision

Evaluate stable local tooling for the repo:

- Rust dependency hygiene: `cargo machete`, `cargo udeps`, or a documented
  explicit defer if toolchain support is unstable;
- Swift dead-code/dependency scan: use a stable local tool only if already
  available or trivial to document without adding maintenance risk;
- generated Xcode project drift: ensure `xcodegen generate` remains the
  canonical verification path for touched clients.

If a tool is adopted, add it to docs and static/CI guidance only when it is
reliable locally. If deferred, record the reason and the trigger for revisiting.

### 4. Mac App Focused Audit

Create or extend audit evidence for `packages/mac-app`:

- menu bar entrypoints;
- onboarding wizard;
- server lifecycle control;
- pairing and local connection management;
- services and test coverage;
- generated project ownership;
- scripts and signing/build assumptions.

Classify each area as `thin client`, `platform/support`, `test/support`,
`generated`, `remove candidate`, or `defer with reason`. Identify whether any
Mac code owns policy, secrets, durable state, or server truth incorrectly.

### 5. Static Gates

Add or update gates for:

- no fixed UI symbol for any removed product shell;
- no client-authored generated UI target/payload/grant;
- no generated UI fallback renderer;
- no prompt-library table recreation or runtime table reader;
- no package/source/policy/trust/audit tables;
- no `control::act`;
- no raw-scope authorization or worker-spawn bypass;
- no compatibility alias, fallback DTO reader, or migration reader.

If dependency tooling is deferred, add a rubric entry that makes the defer
explicit instead of letting it become invisible debt.

### 6. Documentation And Scorecard

Update:

- `README.md` for any removed client surface, schema boundary, or tool command;
- `docs/product-shell-reachability-map.md` with replacement/removal proof;
- `docs/production-grade-codebase-audit.md` with dependency/Mac audit evidence;
- `docs/production-grade-rubric.md` with a conservative new score only after
  verification;
- `docs/modular-engine-cleanup-audit.md` for any removal/consolidation;
- progressive docs near touched client/server modules;
- `~/LEDGER.jsonl`.

## Verification

Run focused tests for any touched shell/domain, then:

- `cd packages/agent && cargo test generated_ui --lib -- --nocapture`;
- `cd packages/agent && cargo test resource_ --lib -- --nocapture`;
- `cd packages/agent && cargo test prompt_library --lib -- --nocapture`;
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`;
- `cd packages/agent && RUSTFLAGS="-D warnings" cargo check --all-targets`;
- `git diff --check`;
- `scripts/tron ci fmt check clippy test`.

If Swift or project files change:

- `cd packages/ios-app && xcodegen generate`;
- targeted iOS tests for the removed/replaced surface plus Engine
  Console/generated UI DTO/cache tests;
- `cd packages/mac-app && xcodegen generate`;
- targeted Mac tests for server lifecycle, pairing, and touched views/services.

## Out Of Scope

- Remote package distribution or marketplace installation.
- New trust-root algorithms.
- New scheduler, package, source, policy, trust, audit, health, prompt, or
  product-shell state tables.
- Product redesign of chat.
- Runtime compatibility readers for old storage.
- Client-owned policy or generated UI mutation paths.
