# Fixed Product-Shell Replacement And Generated UI Coverage Phase

## Current Checkpoint

The product-shell readiness, dependency-tooling, and Mac production audit
checkpoint is complete:

- `docs/product-shell-reachability-map.md` now records replacement readiness
  for every remaining fixed iOS shell;
- no remaining fixed shell was deleted because each still has an active
  entrypoint or a missing generated/resource replacement;
- dependency/dead-code tools (`cargo machete`, `cargo udeps`,
  `cargo llvm-cov`, and `periphery`) are explicitly deferred with local
  availability evidence and revisit criteria;
- `docs/production-grade-codebase-audit.md` now includes a focused Mac app
  audit covering menu bar, onboarding wizard, server lifecycle, pairing,
  observability/feedback, bundled resources, generated project state, scripts,
  and tests;
- static gates require the readiness map, dependency-tooling decision, and Mac
  audit rows to remain current.

The repo-wide production-grade baseline is now `98/100`.

## Objective

Close the remaining repo-wide blockers without broadening the architecture by
replacing one fixed product shell only after the generated/resource path fully
covers the current operator role.

The safest first candidate is Prompt Library inspection/history/snippet
management because its durable server truth is already `artifact` resources.
Deletion of the entire Prompt Library sheet is not assumed: the chat composer
insertion affordance may remain a thin local UI if generated UI cannot express
inserting text into the draft composer. The phase should separate
server/resource inspection from local composer editing and remove only the
fixed surface area that is actually replaced.

No new public capability ids, storage tables, resource kinds, generated UI
catalogs, compatibility readers, fallback DTOs, `control::act`, iOS/Mac policy
ownership, marketplace flows, remote fetch, or alternate worker-spawn paths are
allowed.

## Implementation Plan

### 1. Select One Replacement Slice

Use the readiness table in `docs/product-shell-reachability-map.md` as the
gate. Select one surface or sub-surface where:

- the server truth is already resource/control/generated-UI backed;
- the generated surface can cover the existing operator workflow;
- no local hardware affordance, composer editing affordance, or live media
  renderer is required for that slice;
- the blast radius can be captured with Swift navigation/DTO/client tests and
  Rust static gates.

Recommended starting slice: Prompt Library resource inspection and management.
Likely keep: local composer insertion. Likely replace/remove: fixed snippet and
history list/detail management if generated `artifact` surfaces can provide the
same read/delete/update actions.

### 2. Build The Replacement Path First

For the selected slice:

- enumerate every Swift view, navigation path, DTO/client, state object, test,
  preview, project reference, and docs reference;
- identify the canonical server projection, resource refs, generated
  `ui_surface`, and stored actions that replace the fixed surface behavior;
- add replacement-path tests before deletion;
- update generated UI authoring only if the existing authoring path cannot
  produce the needed surface from substrate truth;
- keep `ui::submit_action` as the only generated action gateway.

The client must remain a thin renderer/action submitter. It must not construct
target function ids, grants, payload templates, resource lineage, or policy
decisions.

### 3. Remove Only Proven-Redundant Code

After replacement tests pass:

- delete fixed Swift views/state/client helpers that are no longer reachable;
- delete obsolete tests/previews/project references/docs in the same change;
- regenerate Xcode project files if Swift file membership changes;
- add absence gates for retired symbols and route names;
- update the product-shell readiness table from `defer with proof` to
  `converted` only for the exact replaced slice.

### 4. Static Gates

Add or update gates for:

- no fixed UI symbol for any removed product shell;
- no client-authored generated UI target/payload/grant;
- no generated UI fallback renderer;
- no prompt-library table recreation or runtime table reader;
- no package/source/policy/trust/audit tables;
- no `control::act`;
- no raw-scope authorization or worker-spawn bypass;
- no compatibility alias, fallback DTO reader, or migration reader.

### 5. Documentation And Scorecard

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

If Swift or project files change, which is expected for product-shell
replacement:

- `cd packages/ios-app && xcodegen generate`;
- targeted iOS tests for the removed/replaced surface plus Engine
  Console/generated UI DTO/cache tests;

Run Mac verification only if Mac files or project generation inputs change.

## Out Of Scope

- Remote package distribution or marketplace installation.
- New trust-root algorithms.
- New scheduler, package, source, policy, trust, audit, health, prompt, or
  product-shell state tables.
- Product redesign of chat.
- Runtime compatibility readers for old storage.
- Client-owned policy or generated UI mutation paths.
