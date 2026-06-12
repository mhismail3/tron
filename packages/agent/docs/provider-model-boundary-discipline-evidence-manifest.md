# Provider / Model Boundary Discipline Evidence Manifest

Status: **complete**
Branch: `codex/provider-model-boundary-discipline-current`
Base commit: `c7deea13d1bcb37b0348406329d503c043933ae6`

## Lineage

- Verified starting checkout was detached at
  `c7deea13d1bcb37b0348406329d503c043933ae6` (`Reconcile off-plan cleanup lineage`).
- Created fresh current-lineage branch
  `codex/provider-model-boundary-discipline-current`.
- Inspected stale branch `codex/provider-model-boundary-discipline` at
  `b11449319` only for audit questions. No merge, cherry-pick, or wholesale copy
  was used.

## Source Audit Evidence

The current-lineage audit read these source families before closure:

- `packages/agent/src/domains/model/mod.rs`
- `packages/agent/src/domains/model/providers/mod.rs`
- `packages/agent/src/domains/model/providers/{openai,anthropic,google,kimi,minimax,ollama}/`
- `packages/agent/src/domains/model/providers/shared/{provider,retry,sse,error_parsing,stream_common,stream_pipeline}.rs`
- `packages/agent/src/domains/model/providers/factory/mod.rs`
- `packages/agent/src/domains/model/protocol/{capability_parsing,id_remapping}.rs`
- `packages/agent/src/domains/model/responder/mod.rs`
- `packages/agent/src/domains/model/routing/`
- `packages/agent/src/domains/model/tokens/`
- `packages/agent/src/domains/auth/credentials/`
- `packages/agent/src/shared/protocol/model_audit.rs`
- `packages/agent/src/domains/session/event_store/{event_log,redaction}.rs`
- `README.md`, `scripts/tron.d/quality.sh`, and `.github/workflows/ci.yml`
- predecessor inventories for PPACD, OPSAA, PCC, TPC, HRA, and SACB

## Closure Evidence

| Row | Evidence |
| --- | --- |
| PMBD-0 | Branch and ancestry verified with `git rev-parse HEAD`, `git merge-base --is-ancestor c7deea13d1bcb37b0348406329d503c043933ae6 HEAD`, and stale branch inspection limited to `git diff`/`git show`. |
| PMBD-1 | `provider-model-boundary-discipline-inventory.md` and `.tsv` cover provider/model boundary source and test surfaces. |
| PMBD-2 | `provider_model_boundary_discipline_invariants` scans non-provider source for provider-native imports and wire markers outside owned boundaries. |
| PMBD-3 | Credential custody proven through `domains/auth/credentials/*` loaders and `providers/factory/mod.rs`; auth-specific tests cover active credential selection and no cross-provider fallback. |
| PMBD-4 | Provider stream/message converter tests cover OpenAI malformed arguments and duplicate deltas, Anthropic/Kimi/Ollama ID remapping and argument object handling, and Google non-object argument fail-closed behavior. |
| PMBD-5 | `ProviderError::to_failure`, `ModelResponseError`, shared redaction, retry events, and session event redaction tests cover canonical failure and redaction behavior. |
| PMBD-6 | `providers/shared/retry.rs` tests cover bounded retry, retry-after, cancellation, non-retryable auth, and redacted retry events. |
| PMBD-7 | `routing/models/registry.rs`, provider model type tests, and `tokens/{normalization,pricing}.rs` tests cover provider detection, auth-path profiles, context limits, capability flags, and token/cost normalization. |
| PMBD-8 | `shared/protocol/model_audit.rs` validates the audit format marker, exact-envelope/snapshot classification, recursive redaction, and 1 MiB payload bound before persistence. |
| PMBD-9 | README, local CI, GitHub CI, PMBD artifacts, and predecessor inventory rows include PMBD. |
| PMBD-10 | Verification commands are recorded below. |

## Verification Commands

Final command results recorded during closeout:

| Command | Result |
| --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers --lib --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::responder --lib --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::auth::credentials --lib --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::tokens --lib --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::routing --lib --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants --quiet` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants --quiet` | passed after restoring replay-manifest protocol docs wording |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed |
| `scripts/tron ci fmt check clippy test` | passed after SACB inventory row updates |
| `scripts/personal-info-guard.sh` | passed |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed |
| `git diff --check` | passed |
| `git ls-files -ci --exclude-standard` | passed |
| `git status --short` | passed: pre-commit status contained only PMBD changes; final clean status is verified after commit |

Swift/protocol DTO changes: none. Only Rust docs and Rust protocol audit code
changed, and the generated Xcode project drift check passed. iOS 26.5 simulator
tests were not required because no Swift source, generated project file, or
public DTO consumed by Swift changed.

## Residual Risk

Provider-owned request builders still intentionally construct exact provider
envelopes for audit/replay. The PMBD guard now redacts and bounds those bodies,
but it does not prove every future provider field is semantically replayable;
future provider additions must keep exact-envelope vs snapshot semantics
explicit in `ProviderAuditPayload`.
