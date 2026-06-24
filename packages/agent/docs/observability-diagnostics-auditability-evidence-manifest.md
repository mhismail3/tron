# Observability Diagnostics Auditability Evidence Manifest

Status: **complete**

Current score: **100/100**

Scorecard:
[`observability-diagnostics-auditability-scorecard.md`](observability-diagnostics-auditability-scorecard.md)

Inventory:
[`observability-diagnostics-auditability-inventory.md`](observability-diagnostics-auditability-inventory.md)
and
[`observability-diagnostics-auditability-inventory.tsv`](observability-diagnostics-auditability-inventory.tsv)

## Row Ledger

| Row | Status | Evidence | Verification | Closure | Checkpoint |
|---|---|---|---|---|---|
| ODA-0 | passed_after_fix | Added ODA scorecard, evidence manifest, inventory summary, machine-readable TSV, invariant target, focused static modules, README links, and local/GitHub closeout target wiring. | ODA invariant target covers harness links, row weights, README/CI target presence, evidence row presence, and stale closeout wording. | Closed. | ODA-0 harness checkpoint |
| ODA-1 | passed_after_fix | Inventoried server trace/log/event/provider/engine-ledger owners, iOS diagnostics/log feedback owners, Mac logs/feedback owners, CLI log/status owners, active docs, and ODA tests. | ODA invariant target validates TSV structure, row count, tracked paths, required observed paths, and row references. | Closed. | ODA-1 inventory checkpoint |
| ODA-2 | passed_after_fix | Source audit confirmed `model.provider_request` typed events, turn-runner audit persistence before model response, trace records with trace/session/workspace/invocation/provider IDs, and replay sections for session events, provider audits, trace records, idempotency entries, invocations, streams, and queue items. | ODA source guards plus existing `primitive_trace_execution` and DRC replay gates preserve the correlation chain. | Closed. | ODA-2 correlation checkpoint |
| ODA-3 | passed_after_fix | Error visibility remains normalized through failure-semantics envelope mapping, provider stream failures, transport response errors, capability result errors, engine replay error details, queue attempt outcomes, and grant lifecycle/budget events. | ODA source guards pin the durable error and runtime-decision owners; FSC invariants remain the canonical behavioral gate. | Closed. | ODA-3 error visibility checkpoint |
| ODA-4 | passed_after_fix | Fixed `logs::recent` to honor `sessionId`, `workspaceId`, and `traceId`; added workspace/trace IDs to Rust, iOS, and Mac recent-log DTOs; added storage and worker tests; hardened `tron logs` exact session/workspace/trace filters with SQL literal quoting. | Focused Rust `domains::logs` and event-store tests cover filtering; iOS LogsClient tests cover optional filter DTOs; Mac MenuBarLogReader tests cover decoded correlation fields; ODA source guards reject regression. | Closed. | ODA-4 logs checkpoint |
| ODA-5 | passed_after_fix | iOS diagnostics server-log records now include hashed workspace and trace IDs in addition to existing hashed log/origin/session IDs; diagnostics tests prove raw IDs are absent while hash fields are present. Mac feedback/log paths continue to redact before display or issue composition. | Focused iOS diagnostics bundle tests and ODA source guards cover hashed correlation IDs and redaction boundaries. | Closed. | ODA-5 diagnostics checkpoint |
| ODA-6 | passed_after_fix | Provider audit remains protocol-owned in `shared/protocol/model_audit.rs`, built by the model responder boundary, persisted as `model.provider_request` by turn-runner persistence, and exported in replay provider-audit sections. | DRC provider audit wiring tests plus ODA source guards cover pre-stream persistence and replay inclusion. | Closed. | ODA-6 provider audit checkpoint |
| ODA-7 | passed_after_fix | Engine ledger rows, idempotency entries, queue attempt records, stream rows, catalog changes, grant events, and external-worker lifecycle/registration validations leave durable or replay-exportable evidence for runtime decisions. | Existing SOL/CSD/SACB gates plus ODA source guards preserve runtime-decision evidence owners. | Closed. | ODA-7 runtime decisions checkpoint |
| ODA-8 | passed_after_fix | `tron status --json` reports mode, service/dev loaded state, listener PID, stale pid-file state, health, server URL, database path, log path, and dev LaunchAgent label. `tron logs --json` emits bounded JSON rows with session/workspace/trace IDs and exact filters. | ODA source guards pin JSON status keys and CLI log filter implementation. | Closed. | ODA-8 CLI/dev UX checkpoint |
| ODA-9 | passed_after_fix | Closed scorecard at 100/100, updated README and progressive docs, added final closeout gates, and recorded residual risk. | Final verification commands are recorded below. | Closed. | ODA-9 closeout checkpoint |

## Baseline Evidence

| Surface | Finding | Required Row |
|---|---|---|
| `packages/agent/src/domains/logs/mod.rs` | `logs::recent` advertised `sessionId` and `workspaceId` but queried `RecentLogQuery::all`, so filters were ignored. | ODA-4 |
| `packages/agent/src/domains/logs/mod.rs` | Direct recent-log responses omitted stored `workspaceId` and `traceId`, weakening joins from app/Mac diagnostics to server logs. | ODA-4/ODA-5 |
| `scripts/tron-lib.d/logs.sh` | `tron logs` emitted trace/workspace JSON fields but filtered only by session and used loose interpolated SQL. | ODA-4/ODA-8 |
| `scripts/tron-lib.d/logs.sh` | `tron logs` joined multiple predicates through Bash `IFS`, which used a space separator rather than `AND` and produced invalid SQL for combined filters. | ODA-8 |
| `packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleTypes.swift` | Diagnostics server-log entries hashed session IDs but not workspace or trace IDs. | ODA-5 |

## Verification Log

| Command | Result | Evidence |
|---|---|---|
| `git status --short --branch` | exit 0 | Baseline worktree was clean on `codex/primitive-engine-teardown` at `9b463945d`. |
| `git log --oneline --decorate -n 12` | exit 0 | Baseline HEAD was `9b463945d Fix delegated engine invoke budget ordering`. |
| `rg` source audit for trace/log/provider/diagnostics/runtime surfaces | exit 0 | Mapped server trace/log/event/provider/engine-ledger owners, iOS diagnostics/log feedback, Mac logs/feedback, and CLI status/log paths before editing. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | exit 101 | Initial closeout gate failed because this manifest still contained placeholder verification rows; no product-code failure was reported. The manifest was updated and the gate was rerun. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | exit 0 | Focused ODA static gate passed after evidence closeout. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | exit 0 | Primitive trace execution and replay manifest evidence read path passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store --lib -- --nocapture` | exit 0 | Event-store log query, trace, replay, and provider-event owner tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::logs --lib -- --nocapture` | exit 0 | Direct `logs::recent` filter and response correlation tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | exit 0 | Public `/engine` smoke and primitive fail-closed integration target passed. |
| `scripts/tron ci fmt check clippy test` | exit 0 | Broad Rust formatting, check, clippy, and test closeout passed. |
| `scripts/personal-info-guard.sh` | exit 0 | Secret/personal-literal guard passed. |
| Temporary SQLite probe of `tron logs --json -s <quoted> -w <quoted> -t <quoted> -q <quoted>` | exit 1 then exit 0 after fix | The first probe exposed invalid SQL from the CLI quote helper and predicate join; the rerun returned one matching JSON row with session/workspace/trace fields. |
| `cd packages/ios-app && xcodegen generate` | exit 0 | iOS generated project regeneration completed before focused tests. |
| `xcodebuild test -quiet -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/DiagnosticsBundleBuilderTests -only-testing:TronMobileTests/ClientLogIngestionServiceTests -only-testing:TronMobileTests/LogsClientTests` | exit 0 | iOS source, diagnostics bundle, client-log ingestion, and logs DTO focused verification passed. |
| `cd packages/mac-app && xcodegen generate` | exit 0 | Mac generated project regeneration completed before focused tests. |
| `xcodebuild test -quiet -scheme TronMac -destination 'platform=macOS' -only-testing:TronMacTests/DiagnosticsRedactorTests -only-testing:TronMacTests/MacSourceGuardTests -only-testing:TronMacTests/MenuBarLogReaderTests` | exit 0 | Mac diagnostics redactor, source guard, and logs window focused verification passed. |
| `git diff --check` | exit 0 | Whitespace verification passed. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files were reported. |
| `git status --short` | exit 0 | Final intended changes were present before staging and commit. |

## Residual Risk

No known ODA blocker remains in the completed slice. The retained risk is that
runtime-scale correlation proof still depends on existing replay/trace/unit
fixtures rather than a long-running live production session, which is acceptable
for this audit-and-hardening campaign because production deployment is
manual-only and out of scope.
