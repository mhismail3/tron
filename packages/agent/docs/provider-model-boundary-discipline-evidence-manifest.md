# Provider / Model Boundary Discipline Evidence Manifest

Status: **closed**
Current score: **100/100**
Branch: `codex/provider-model-boundary-discipline`
Base commit: `07ba69b4f`

Scorecard:
[`provider-model-boundary-discipline-scorecard.md`](provider-model-boundary-discipline-scorecard.md)

Inventory:
[`provider-model-boundary-discipline-inventory.md`](provider-model-boundary-discipline-inventory.md)
and
[`provider-model-boundary-discipline-inventory.tsv`](provider-model-boundary-discipline-inventory.tsv)

Invariant target:
[`../tests/provider_model_boundary_discipline_invariants.rs`](../tests/provider_model_boundary_discipline_invariants.rs)

## Source Inspection

- Read the original campaign plan attachment at
  `/Users/moose/.codex/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt`;
  it identifies Provider / Model Boundary Discipline as one of the original
  remaining hardening slices.
- Inspected model domain roots, provider shared helpers, concrete provider
  implementations, responder boundary, protocol id/argument helpers,
  routing/catalog/tokens, auth credentials, failure/model audit protocol, agent
  turn-runner consumers, and iOS model/provider projections.
- Confirmed `@self-inspect` is referenced by project instructions but is not an
  available skill in this session; source inspection and direct `rg`/test
  evidence were used instead.

## Row Evidence

| Row | Status | Evidence |
| --- | --- | --- |
| PMBD-0 | passed | Added PMBD scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, local `scripts/tron ci test` target, and GitHub static-gate target. |
| PMBD-1 | passed | Built the PMBD TSV inventory across model roots, provider shared helpers, provider families, responder/factory/auth, protocol helpers, routing/catalog/tokens, audit/failure surfaces, agent consumers, and iOS mirrors. |
| PMBD-2 | passed | Static guard rejects provider-native imports and `ProviderError`/`ProviderStreamOptions` references outside provider roots and `domains::model::responder`; source inspection confirmed agent consumers call `ModelResponder`. |
| PMBD-3 | passed | Provider request shaping remains in provider modules; responder only converts canonical `ModelReasoningLevel` into provider stream options and providers build headers/bodies/base URLs locally. |
| PMBD-4 | passed | Existing provider stream tests cover malformed capability arguments and id remapping; PMBD static guard confines provider wire names to providers/protocol/catalog projections. |
| PMBD-5 | passed | Provider error conversion remains via `ProviderError::to_failure` and `ModelResponseError::from_provider_error`; retry events and provider error logs now redact provider-derived message text. |
| PMBD-6 | passed | `DefaultProviderFactory` reloads auth from custody on create, creates ephemeral provider credentials, and audit payloads now call `redacted_and_bounded()` before persistence. |
| PMBD-7 | passed | Routing/catalog/token modules remain server-authoritative; focused `routing::models` and provider/catalog tests cover model detection, context windows, capabilities, pricing, and auth-path filtering. |
| PMBD-8 | passed | PMBD invariant target scans provider-native wire markers and fails if they appear outside provider/protocol/routing/token/protocol-event boundaries. |
| PMBD-9 | passed | Added explicit redaction and oversized audit payload tests; retained existing malformed tool/capability, missing auth, unsupported model, cancellation, provider error, stream parse, and wrong-provider routing tests. |
| PMBD-10 | passed | README, model/provider/shared docs, scorecard, evidence, inventory, static gates, and closeout commands were updated and verified. |

## Verification Log

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed | Formatting check passed before and after PMBD/SACB inventory fixes. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Compile check passed; existing provider/engine dead-code warnings remain. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model --lib -- --nocapture` | passed | 971 model-domain lib tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml providers --lib -- --nocapture` | passed | 779 provider-focused lib tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml model::responder --lib -- --nocapture` | passed | 7 responder tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml model::protocol --lib -- --nocapture` | passed | 27 protocol parsing/id-remapping tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml routing::models --lib -- --nocapture` | passed | 100 routing/catalog model tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture` | passed | 7 PMBD invariant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | passed | 9 FSC invariant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | failed_then_fixed | Initial DRC docs parity failure required restoring the exact replay-manifest audit ownership phrase in `shared/protocol/mod.rs`; rerun passed with 17 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | passed | 11 ODA invariant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | passed | 5 DISEMD invariant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | failed_then_fixed | Initial SACB run flagged inherited redaction coverage markers and missing inventory rows for provider-boundary files; rerun passed with 17 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | passed | 5 PPACD invariant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | 8 primitive trace execution tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | 2 integration tests passed. |
| `scripts/tron ci fmt check clippy test` | failed_then_fixed | First full wrapper run failed on duplicate PCC/HRA `model_audit.rs` inventory rows; after removing duplicates, the exact command reran and passed all fmt/check/clippy/test gates. |
| `scripts/personal-info-guard.sh` | passed | Full scan reported no personal-info leaks in source. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | iOS project regenerated with no `TronMobile.xcodeproj` drift. |
| `cd packages/mac-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/mac-app/TronMac.xcodeproj` | passed | macOS project regenerated with no `TronMac.xcodeproj` drift. |
| `git diff --check` | passed | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | passed | No tracked ignored files. |
| `git status --short` | passed | Reported only expected PMBD slice changes before staging. |
| `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::model_audit --lib -- --nocapture` | passed | 2 model audit redaction/bounds tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml shared::foundation::redaction --lib -- --nocapture` | failed_then_fixed | Initial test expected generic unquoted `token=` redaction; corrected to established `access_token=` policy. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | passed | 16 PCC invariant tests passed after removing the duplicate PMBD `model_audit.rs` row. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | passed | 35 HRA invariant tests passed after removing the duplicate PMBD `model_audit.rs` row. |

## Residual Risk

No PMBD-specific residual risk is currently accepted. Existing Rust dead-code
warnings remain outside this slice; they were present in focused and full closeout
runs and did not hide provider-boundary test failures.
