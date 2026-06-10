# Security Authority Capability Boundaries Evidence Manifest

Status: **active**

Current score: **61/100**

Scorecard:
[`security-authority-capability-boundaries-scorecard.md`](security-authority-capability-boundaries-scorecard.md)

Inventory:
[`security-authority-capability-boundaries-inventory.md`](security-authority-capability-boundaries-inventory.md)
and
[`security-authority-capability-boundaries-inventory.tsv`](security-authority-capability-boundaries-inventory.tsv)

## Row Ledger

| Row | Status | Evidence | Verification | Closure | Checkpoint |
|---|---|---|---|---|---|
| SACB-0 | passed_after_fix | Added scorecard, evidence manifest, inventory summary, machine-readable TSV header/seed rows, invariant target, README links, local/GitHub CI closeout wiring, and cross-campaign PCC/HRA rows for new SACB artifacts. Initial findings record the public transport context trust gap and grant derivation file-root narrowing gap discovered during baseline source inspection. | SACB target passed with 6 tests; PCC inventory target passed with 16 tests; HRA inventory target passed with 35 tests; rustfmt check and whitespace checks passed. | Closed for harness. Open rows SACB-1 through SACB-10 remain explicitly pending in the scorecard. | SACB-0 campaign harness checkpoint |
| SACB-1 | passed_after_fix | Replaced the SACB-0 seed TSV with a 601-row marker-derived inventory covering tracked server, iOS, Mac, script, workflow, docs, tests, and TSV evidence surfaces for public transport, authority grants, runtime metadata, primitive execution, external workers, secret storage, pairing lifecycle, and static gates. Added static marker coverage so every tracked security-marker file must have a SACB row. | SACB target passed with the marker coverage and boundary-class guards. | Closed for whole-repo inventory. Later rows must keep the inventory current as they delete unsafe fields or add focused tests. | SACB-1 boundary inventory checkpoint |
| SACB-2 | passed_after_fix | Added worker route tests in `packages/agent/src/app/bootstrap/server.rs` for missing bearer and loopback bearer upgrade, plus a direct worker peer guard test for non-loopback `403` rejection. Added SACB static route/auth guards for `/engine`, `/engine/workers`, `ws_auth_gate`, strict bearer parsing, and loopback worker `ConnectInfo<SocketAddr>` enforcement. Existing auth tests already cover missing, wrong, rotated, wrong-scheme, trailing-whitespace, malformed, and constant-time bearer behavior. | Server bootstrap target passed with 24 tests; SACB invariant target passed with 9 tests. | Closed for public route/auth/loopback boundary. Later SACB-3 owns public context trust. | SACB-2 public transport boundary checkpoint |
| SACB-3 | passed_after_fix | Removed public `authorityScopes` and `runtimeMetadata` from `/engine` wire context and the transport-neutral `EngineTransportContext`, deleted the copy loops that inserted caller context scopes/metadata into `CausalContext`, removed silent top-level `authorityScopes` stripping, added DTO tests that reject those fields, and added static SACB guards for the deletion. README documents public context as identity/correlation-only. | Engine transport unit target passed with 16 tests; SACB invariant target passed with 10 tests; formatting and whitespace checks passed. | Closed for public context trust. Later SACB-4 owns grant derivation and bootstrap grant proof. | SACB-3 public context trust checkpoint |
| SACB-4 | passed_after_fix | Added `packages/agent/src/engine/authority/grants/paths.rs` as the shared canonical path-containment helper, changed grant derivation to canonicalize and normalize child file roots before comparing to canonical parent roots, removed the raw `root.starts_with(parent)` boundary, added prefix-sibling and unresolved parent-component escape regressions, and added bootstrap root-grant proof for explicit wildcard policy plus `engine.bootstrap` provenance. Updated PCC, TPC, HRA, TMB, SOL, and SACB inventories for the new helper. | Authority grant target passed with 9 tests; SACB invariant target passed with 11 tests; PCC, TPC, HRA, TMB, and SOL inventory targets passed with focused coverage; formatting and whitespace checks passed. | Closed for grant derivation, file roots, network policy/budget proof, and bootstrap grant proof. Later SACB-5 owns catalog visibility/direct invocation. | SACB-4 authority grant boundary checkpoint |
| SACB-5 | passed_after_fix | Tightened internal catalog visibility so `engine.internal.invoke` is accepted only from trusted runtime actor kinds, changed hidden agent prompt/apply delegation to run under `system:agent-runtime` with `engine-system` authority instead of cloning public client causality, added direct `engine::invoke` tests proving public client contexts cannot reach internal/admin/worker-only targets and raw public internal scope is denied, and added public transport/static guards proving `/engine` does not mint the internal scope. | Policy target passed with 2 tests; prompt helper target passed with 1 test; engine meta invocation target passed with 12 tests; transport target passed with 17 tests; SACB invariant target passed with 12 tests; formatting passed. | Closed for catalog visibility and direct invocation. Later SACB-6 owns `capability::execute` least privilege. | SACB-5 catalog visibility/direct invocation checkpoint |
| SACB-6 | pending | Not started. | Not run. | Open: primitive execute least-privilege proof. | pending |
| SACB-7 | pending | Not started. | Not run. | Open: external worker protocol isolation proof. | pending |
| SACB-8 | pending | Not started. | Not run. | Open: secrets, redaction, auth custody proof. | pending |
| SACB-9 | pending | Not started. | Not run. | Open: iOS/Mac pairing lifecycle proof. | pending |
| SACB-10 | pending | Not started. | Not run. | Open: final closeout. | pending |

## Baseline Evidence

| Surface | Finding | Required Row |
|---|---|---|
| `packages/agent/src/transport/engine/socket/wire.rs` | `WireContext` accepts public `authorityScopes` and `runtimeMetadata`. | SACB-3 |
| `packages/agent/src/transport/engine/mod.rs` | `build_engine_transport_request` copies caller context authority scopes and runtime metadata into causal context. | SACB-3 |
| `packages/agent/src/domains/capability/operations/filesystem.rs` | `RUNTIME_METADATA_WORKING_DIRECTORY` controls primitive file and process working directories. | SACB-3/SACB-6 |
| `packages/agent/src/engine/authority/grants/derivation.rs` | Child grant file roots are narrowed with string-prefix checks. | SACB-4 |
| `packages/agent/src/engine/authority/grants/model.rs` | Bootstrap grants are wildcard root grants and must be explicitly inventoried. | SACB-4 |

## Verification Log

| Command | Result | Evidence |
|---|---|---|
| `git status --short --branch` | exit 0 | Worktree was clean on `codex/primitive-engine-teardown` before SACB-0 edits. |
| `find /Users/moose/.tron/internal/database -maxdepth 2 -type f` | exit 0 | Runtime databases available for direct inspection when later rows depend on runtime state. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB scaffold target passed: 6 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | Existing PCC tracked-file inventory target passed after adding SACB rows: 16 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | Existing HRA tracked-file ownership target passed after adding SACB rows: 35 tests. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Rust formatting check passed after rustfmt applied to new invariant modules. |
| `git diff --check --cached && git diff --check` | exit 0 | Staged and unstaged whitespace checks passed. |
| `node` marker inventory generator | exit 0 | Generated 601 SACB inventory rows from tracked security-marker files after excluding non-security token-accounting/model-catalog surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB-1 inventory coverage target passed after adding marker coverage and boundary-class guards: 8 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml app::bootstrap::server --lib -- --nocapture` | exit 0 | SACB-2 focused server route/auth/loopback verification passed: 24 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB-2 static route/auth guard verification passed: 9 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::engine --lib -- --nocapture` | exit 0 | SACB-3 focused engine transport context verification passed: 16 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB-3 static public context trust guard verification passed: 10 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::authority --lib -- --nocapture` | exit 0 | SACB-4 focused authority grant derivation/authorization/bootstrap verification passed: 9 tests, including prefix-sibling and unresolved parent-component path escape regressions. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB-4 static authority grant guard verification passed: 11 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants primitive_code_cleanup_inventory_covers_tracked_files -- --nocapture` | exit 0 | SACB-4 PCC inventory verification for new helper passed: 1 test. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants tracked_source_inventory_is_formalized -- --nocapture` | exit 0 | SACB-4 TPC retention inventory verification passed after adding campaign artifact rows discovered by the guard: 1 test. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants tracked_files_have_rearchitecture_inventory_rows -- --nocapture` | exit 0 | SACB-4 HRA inventory verification for new helper passed: 1 test. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants boundary_inventory_covers_tracked_sources -- --nocapture` | exit 0 | SACB-4 TMB inventory verification for new helper passed: 1 test. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_rows_are_structured_and_classified -- --nocapture` | exit 0 | SACB-4 SOL inventory structure verification passed: 1 test. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_covers_stateful_marker_sources -- --nocapture` | exit 0 | SACB-4 SOL stateful marker inventory verification passed after adding the missing capability copy button row: 1 test. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | SACB-4 formatting check passed. |
| `git diff --check` | exit 0 | SACB-4 whitespace check passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::kernel::policy --lib -- --nocapture` | exit 0 | SACB-5 internal visibility policy verification passed: 2 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::agent::prompt::prompt::tests::hidden_prompt_child_context_is_engine_owned_not_public_caller --lib -- --nocapture` | exit 0 | SACB-5 hidden agent prompt delegation causality verification passed: 1 test. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::invocation::meta_primitives --lib -- --nocapture` | exit 0 | SACB-5 direct `engine::invoke` visibility verification passed: 12 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::engine --lib -- --nocapture` | exit 0 | SACB-5 public transport verification passed: 17 tests, including the guard that public `engine::invoke` never mints `engine.internal.invoke`. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB-5 static guard verification passed: 12 tests. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | SACB-5 formatting check passed after applying rustfmt. |
| `git diff --check` | exit 0 | SACB-5 whitespace check passed. |
