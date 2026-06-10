# Security Authority Capability Boundaries Evidence Manifest

Status: **active**

Current score: **15/100**

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
| SACB-2 | pending | Not started. | Not run. | Open: public route/auth/loopback proof. | pending |
| SACB-3 | pending | Not started. | Not run. | Open: public context trust hardening. | pending |
| SACB-4 | pending | Not started. | Not run. | Open: grants, file roots, network policy, bootstrap proof. | pending |
| SACB-5 | pending | Not started. | Not run. | Open: catalog visibility and direct invocation proof. | pending |
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
