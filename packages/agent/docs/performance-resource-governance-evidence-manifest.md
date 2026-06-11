# Performance / Resource Governance Evidence Manifest

Status: **closed**
Current score: **100/100**

Branch: `codex/performance-resource-governance-recovery`
Base commit: `b114493199703a045636c1b3b46250f1af2f6a11`

Scorecard:
[`performance-resource-governance-scorecard.md`](performance-resource-governance-scorecard.md)

Inventory:
[`performance-resource-governance-inventory.md`](performance-resource-governance-inventory.md)
and
[`performance-resource-governance-inventory.tsv`](performance-resource-governance-inventory.tsv)

Invariant target:
[`../tests/performance_resource_governance_invariants.rs`](../tests/performance_resource_governance_invariants.rs)

## Source Inspection

- Confirmed the recovery branch `codex/performance-resource-governance-recovery`
  is based at `b114493199703a045636c1b3b46250f1af2f6a11`
  (`Harden provider model boundary discipline`).
- Read root `AGENTS.md`, the original campaign plan attachment at
  `/Users/<USER>/.codex/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt`,
  and relevant progressive module docs before source edits.
- Confirmed `@self-inspect` is referenced by project instructions but is not an
  available skill in this session; source inspection and direct `rg`/test
  evidence were used instead.
- Built the PRG inventory before source edits, then updated the proof columns
  after implementation to retain both the original risk and final bound.

## Row Evidence

| Row | Status | Evidence |
| --- | --- | --- |
| PRG-0 | passed | Added PRG scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, local `scripts/tron ci test` target, GitHub static-gate target, and predecessor preservation assertions. |
| PRG-1 | passed | `performance-resource-governance-inventory.tsv` covers 30 provider, agent, transport, logs, diagnostics, storage, retry, runtime, and static-harness resource surfaces. |
| PRG-2 | passed | Added byte/item ceilings for provider SSE/NDJSON lines, provider stream text/thinking/signatures/tool args/tool counts, agent stream state, and streaming journal WAL/recovery. Retained existing log, diagnostic payload, and storage payload bounds. |
| PRG-3 | passed | `/engine` outbound async push now uses try-send plus `OUTBOUND_SEND_TIMEOUT`, increments overload metrics, and closes slow consumers; existing stream page and queue capacity constants remain guarded. |
| PRG-4 | passed | `tron logs` CLI now rejects limits above 1,000 rows, matching server `MAX_RECENT_LIMIT`; client log ingest/message and diagnostic transport bounds remain guarded. |
| PRG-5 | passed | Startup retention/size-budget calls, runtime task registration, shutdown timeout constants, callback timeouts, and task abort paths remain source-guarded. |
| PRG-6 | passed | Storage payload thresholds, verbose retention days, retention runs, checkpoint/export helpers, and size-budget enforcement remain source-guarded without new public management surfaces. |
| PRG-7 | passed | Provider retry max attempts, max delay, and cancellation paths remain guarded; stream resource failures use canonical `StreamEvent::Error` so responder health/failure handling remains observable. |
| PRG-8 | passed | Focused unit/static tests cover oversized SSE lines, shared provider accumulator ceilings, Kimi/Ollama local handler overflows, agent stream overflow, streaming journal budget overflow, engine slow consumer closure, and log CLI limit rejection. |
| PRG-9 | passed | `performance_resource_governance_invariants` checks source constants, docs/gates, predecessor targets, OPSTC successor cleanup, and repo-managed skill absence. |
| PRG-10 | passed | README, progressive docs, scorecard, inventory, evidence, verification command matrix, iOS targeted-test rationale, clean status, and commit are recorded. |

## Verification Log

The exact required closeout commands below have passed in this worktree. During
closeout, earlier reruns surfaced formatting, clippy, HRA ownership/LOC,
post-HRA privacy/near-budget, and post-AHA split-plan guard failures; each was
patched and rerun to pass before this table was finalized.

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | pass | Required closeout command; final rerun passed after Rust formatting cleanup. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | pass | Required closeout command; also covered by final `scripts/tron ci fmt check clippy test`. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::logs --lib -- --nocapture` | pass | Required closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture` | pass | Required closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::runtime --lib -- --nocapture` | pass | Required closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::runtime --lib -- --nocapture` | pass | Required closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml providers::shared --lib -- --nocapture` | pass | Required closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | pass | Required closeout command; final PRG-specific rerun passed after evidence finalization. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture` | pass | Required predecessor closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | pass | Required predecessor closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | pass | Required predecessor closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | pass | Required predecessor closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture` | pass | Required predecessor closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | pass | Required predecessor closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | pass | Required closeout command. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | pass | Required closeout command. |
| `scripts/tron ci fmt check clippy test` | pass | Required full local quality gate; final rerun passed. |
| `scripts/personal-info-guard.sh` | pass | Required source privacy guard; final rerun reported no personal-info leaks. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | pass | Required iOS project drift check; no tracked project diff. |
| `cd packages/mac-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/mac-app/TronMac.xcodeproj` | pass | Required macOS project drift check; no tracked project diff. |
| `git diff --check` | pass | Required whitespace check. |
| `git ls-files -ci --exclude-standard` | pass | Required ignored-file check; no ignored tracked files were listed. |
| `git status --short` | pass | Required pre-commit status checkpoint; listed expected uncommitted PRG changes before staging. |

## Targeted iOS Test Rationale

No iOS/macOS protocol, diagnostics, log reader, or settings files were touched.
The log-reader change is the Rust-owned shell CLI `tron logs` cap mirroring the
server `logs::recent` limit, so no targeted iOS 26.5 simulator tests are
required. The required iOS and macOS XcodeGen drift checks remain part of
closeout.

## Residual Risk

No PRG-specific residual risk is accepted. Existing Rust dead-code warnings
remain outside this slice and were present before the PRG changes.
