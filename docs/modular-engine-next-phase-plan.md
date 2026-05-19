# Final Product-Shell Boundary Decision And 100% Readiness Phase

## Current Checkpoint

The Prompt Library generated management checkpoint is complete:

- `ui::surface_for_target` now authors narrow `resource_collection` surfaces
  for Prompt Library snippet and history artifact collections;
- generated surfaces own snippet/history create, update, delete, clear, and
  refresh management actions through stored canonical `prompt_library::*`
  actions;
- `PromptLibrarySheet` no longer owns fixed add/edit/delete/clear controls and
  remains only a local picker/composer insertion affordance;
- `GeneratedUISurfaceView` seeds editable form state from server-provided
  `value` props and keeps unsupported/stale/expired/damaged surfaces closed;
- static gates protect generated Prompt Library management and forbid client
  target-function/payload/grant construction.

The repo-wide production-grade baseline is now `99/100`.

## Objective

Close the final repo-wide blocker without broadening the architecture: decide
whether the Prompt Library composer insertion picker is an intentionally local
thin shell or whether it should be replaced by a narrow generated-result bridge
that can safely insert selected prompt text into the draft composer.

Do not chase a nominal 100/100 by deleting useful local editing UI. The bar is
proof: either composer insertion becomes a safe generated-UI-compatible
handoff, or the remaining picker is documented, gated, and scored as a
permanent local affordance that owns no durable truth or policy.

No new public capability ids, storage tables, resource kinds, generated UI
catalogs, compatibility readers, fallback DTOs, `control::act`, iOS/Mac policy
ownership, marketplace flows, remote fetch, or alternate worker-spawn paths are
allowed.

## Implementation Plan

### 1. Decide The Composer Insertion Boundary

Use the readiness table in `docs/product-shell-reachability-map.md` as the
gate. For Prompt Library insertion, prove:

- the fixed sheet owns no create/update/delete/clear management;
- the picker reads bounded server truth and calls only `onSelect(text)`;
- insertion into the draft composer is local editing state, not durable engine
  truth;
- no server policy, resource lineage, target function, payload template, grant,
  or generated action is constructed locally;
- Settings may still call explicit Prompt Library clear-history only if that
  path remains intentionally outside the picker management slice.

If those statements are true, convert the blocker into a documented permanent
thin-shell exception with static gates. If not, implement a generated-result
handoff that lets a server-authored surface select a prompt resource and return
text to the composer without allowing arbitrary client action construction.

### 2. Prove Or Implement The Boundary

If retaining the picker:

- add source/static tests proving the picker has selection-only behavior;
- document the local-editing exception in the reachability map and rubric;
- update score to 100/100 only if every remaining blocker is converted or
  explicitly accepted with gates.

If replacing the picker:

- design a server-authored read-only selection surface that returns a selected
  resource/text result without mutating durable state;
- keep mutation through `ui::submit_action` and stored actions only;
- add Swift tests showing the client consumes only the returned selected text
  and never constructs target functions/payloads/grants.

### 3. Remove Or Gate The Remaining Fixed Code

After the boundary decision:

- delete any code proven redundant;
- keep and gate any code proven intentionally local;
- regenerate Xcode project files if Swift file membership changes;
- update README/docs and absence/static gates in the same change.

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
