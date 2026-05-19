# Final Product-Shell Replacement And Legacy Schema Cleanup Phase

## Current Checkpoint

The product-shell reachability and Prompt Library resource conversion checkpoint
is complete:

- `docs/product-shell-reachability-map.md` classifies the remaining fixed iOS
  shells by entrypoint, DTO/client, server/event dependency, tests, current
  operator role, and keep/convert/defer decision;
- `prompt_library::history_*` and `prompt_library::snippet_*` use `artifact`
  resources as durable truth;
- retired `prompt_history` and `prompt_snippets` rows are ignored by runtime
  prompt-library code;
- prompt-library mutating responses preserve existing fields and add
  top-level `resourceRefs`;
- static gates prevent the deleted prompt store and product-shell proof map
  from drifting;
- the maturity scorecard baseline is now `99/100`.

## Objective

Close the final cleanup gap without broadening the architecture: replace or
remove remaining fixed product-shell surfaces only when generated UI/control/
resource projections cover their current role, and remove inert retired schema
surface only behind a deliberate clean storage boundary.

This phase should move the scorecard from `99/100` to `100/100` only if the
remaining product-shell and retired-schema blockers are resolved with tests,
docs, and static gates. Do not add new public capability ids, resource kinds,
storage tables, generated UI catalogs, compatibility readers, fallback DTOs,
`control::act`, iOS policy, marketplace flows, remote fetch, or alternate
worker-spawn paths.

## Implementation Plan

### 1. Choose One Remaining Fixed Shell

Use `docs/product-shell-reachability-map.md` as the deletion bar. Pick exactly
one active surface whose current operator role can be replaced by existing
control/generated UI/resource projections, likely:

- AgentControl inspection cards, if generated session/context/source-control
  surfaces can cover the same information;
- Prompt Library sheet, if generated UI can safely author snippet/history
  operations and chat composer insertion remains ergonomic;
- notification inbox, only if notification delivery/read semantics first have
  a resource-backed contract.

If no surface meets the bar, do not delete UI. Instead, document the missing
generated UI/control primitive and keep the scorecard at `99/100`.

### 2. Replace Before Removing

For the selected shell:

- identify every Swift entrypoint, navigation path, DTO/client, test, preview,
  and doc reference;
- identify the canonical server projection or `ui_surface` that replaces it;
- add tests for the replacement path before deleting fixed UI;
- delete the fixed surface, navigation case, DTO/client code, tests/previews,
  and docs in the same checkpoint;
- add static absence gates for the retired symbols and route names.

No client-owned target functions, grants, payload templates, resource lineage,
or policy decisions are allowed.

### 3. Legacy Schema Decision

Audit the consolidated SQLite schema for inert tables that no runtime code reads
after recent resource conversions:

- `prompt_history`;
- `prompt_snippets`;
- any other tables made inert by the modular-engine conversion.

If removing them requires a clean storage generation boundary, draft and
implement a new generation reset. Do not add migration readers or compatibility
paths. If the generation reset is not justified, leave the tables documented as
inert and keep runtime static gates proving they are not read.

### 4. Final Static Gates

Add or update gates for:

- no fixed UI symbol for any removed shell;
- no runtime prompt-library table reader;
- no old prompt store module;
- no generated UI fallback renderer;
- no client-authored generated UI action target/payload/grant;
- no `control::act`;
- no package/source/policy/trust/audit tables;
- no compatibility alias or fallback DTO reader;
- no raw-scope authorization or worker-spawn bypass.

### 5. Documentation And Scorecard

Update:

- `README.md` for any removed iOS shell or database-schema boundary;
- `docs/product-shell-reachability-map.md` with the replacement/removal proof;
- `docs/modular-engine-cleanup-audit.md` with the final decision;
- `docs/modular-engine-maturity-scorecard.md` only after verification passes;
- progressive module/view docs for any touched area;
- `~/LEDGER.jsonl`.

## Verification

Run focused tests for any touched shell/domain, then:

- `cd packages/agent && cargo test prompt_library --lib -- --nocapture`;
- `cd packages/agent && cargo test generated_ui --lib -- --nocapture`;
- `cd packages/agent && cargo test resource_ --lib -- --nocapture`;
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`;
- `git diff --check`;
- `scripts/tron ci fmt check clippy test`.

If Swift/project files change:

- `cd packages/ios-app && xcodegen generate`;
- targeted tests for the removed/replaced surface plus Engine Console/generated
  UI DTO/cache tests.

## Out Of Scope

- Remote package distribution or marketplace installation.
- New trust-root algorithms.
- New scheduler, package, source, policy, trust, audit, health, or prompt tables.
- Product redesign of chat.
- Broad storage deletion without a clean generation decision.
