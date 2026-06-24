# Observability Diagnostics Auditability Scorecard

Created: 2026-06-10

Initial score: **0/100**

Current score: **100/100**

Status: **complete**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`observability-diagnostics-auditability-evidence-manifest.md`](observability-diagnostics-auditability-evidence-manifest.md)

Inventory:
[`observability-diagnostics-auditability-inventory.md`](observability-diagnostics-auditability-inventory.md)
and
[`observability-diagnostics-auditability-inventory.tsv`](observability-diagnostics-auditability-inventory.tsv)

Invariant target:
[`../tests/observability_diagnostics_auditability_invariants.rs`](../tests/observability_diagnostics_auditability_invariants.rs)
with focused modules under
[`../tests/observability_diagnostics_auditability/`](../tests/observability_diagnostics_auditability/)

## Scope

This campaign proves important runtime decisions, failures, retries, grants,
provider calls, queue actions, logs, diagnostics bundles, and client/server
boundaries are inspectable from durable or user-initiated local surfaces without
guessing and without exposing bearer/API/OAuth secrets.

The campaign is an audit-and-hardening slice. It does not add provider-specific
diagnostics APIs, outbound analytics, automatic upload, or a restored
`system::get_diagnostics` product surface.

## Non-Negotiable Direction

- Stable IDs must join session events, provider request audits, primitive trace
  records, engine invocation ledger rows, stream rows, idempotency entries,
  queue rows, logs, and diagnostics bundles where those records exist.
- Diagnostics bundles remain local, user-initiated, redacted, and bounded.
- Provider details stay normalized into provider audit, stream, error, trace,
  and log surfaces.
- Log and trace reads must be bounded and scoped by owner APIs before rows are
  returned.
- Client diagnostics may hash correlation IDs, but must not include raw private
  paths, bearer values, API keys, OAuth fields, prompt text, capability
  arguments, or capability outputs.
- CLI and app diagnostics must expose machine-readable state without requiring
  app UI.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence contract | Closure | Checkpoint |
|----|------|-------:|--------|-------|-------------------|---------|------------|
| ODA-0 | Campaign harness, README/CI links, evidence/inventory scaffolding, invariant target | 7 | passed_after_fix | docs/static gates | Added the ODA scorecard, evidence manifest, inventory docs/TSV, invariant target, README living-doc links, local/GitHub closeout target wiring, and no-stale-closeout gates. | Closed. | ODA-0 harness checkpoint |
| ODA-1 | Source inventory for server, iOS, Mac, scripts, docs, and tests | 10 | passed_after_fix | inventory/static gates | Built a structured inventory covering 53 observed trace/log/event/provider/engine-ledger, client diagnostics, Mac feedback/log, CLI status/log, docs, and test surfaces. | Closed. | ODA-1 inventory checkpoint |
| ODA-2 | Correlation through session events, provider audits, primitive traces, replay, and engine ledger rows | 13 | passed_after_fix | session/engine/model | Source audit confirms provider request audits are persisted before response streaming, trace records carry trace/session/workspace/invocation/provider IDs, replay manifests include session events, provider audits, trace records, idempotency entries, invocation ledger rows, stream rows, and queue rows, and primitive trace tests exercise the model-facing read path. | Closed. | ODA-2 correlation checkpoint |
| ODA-3 | Error visibility for provider, transport, capability, grant, queue, cancellation, timeout, and replay failures | 10 | passed_after_fix | failure surfaces | Existing failure semantics and replay surfaces preserve canonical error details through events, transport envelopes, replay `engineError` details, provider streams, queue attempt records, and grant lifecycle events; ODA source guards pin the durable owners. | Closed. | ODA-3 error visibility checkpoint |
| ODA-4 | Logs are bounded, redacted, deduplicated, queryable, and loop-safe | 12 | passed_after_fix | logs/iOS/scripts | Fixed `logs::recent` so advertised `sessionId` and `workspaceId` filters are honored, added `traceId` filtering, returned `workspaceId` and `traceId` in rows, kept storage-owner redaction/truncation/deduplication, and hardened `tron logs` with exact session/workspace/trace filters plus quoted SQL literals. | Closed. | ODA-4 logs checkpoint |
| ODA-5 | Diagnostics bundles include useful local/server context while excluding secrets and private payloads | 10 | passed_after_fix | iOS/Mac diagnostics | iOS diagnostics now include hashed server-log workspace and trace IDs beside existing hashed session/log/origin IDs, still redacts messages and event error text, bounds logs/events/MetricKit payloads, and remains Mail/user initiated. Mac feedback continues to redact recent logs before composing a GitHub issue. | Closed. | ODA-5 diagnostics checkpoint |
| ODA-6 | Provider audit records are normalized and joinable without credentials or oversized raw payload leaks | 10 | passed_after_fix | model/session | Provider audit DTOs remain protocol-owned metadata rows, are built by the model responder boundary, persisted by the turn runner before provider streaming, and exported through replay provider-audit sections. | Closed. | ODA-6 provider audit checkpoint |
| ODA-7 | Runtime decisions leave durable postmortem evidence | 10 | passed_after_fix | engine runtime | Grants record lifecycle and budget-consumption events, engine invocations and idempotency entries are ledgered, queues retain delivery attempts and retry/dead-letter/cancel state, streams retain cursor/topic/scope payload hashes in replay, and catalog changes are persisted through the engine ledger. | Closed. | ODA-7 runtime decisions checkpoint |
| ODA-8 | CLI and dev UX expose bounded machine-readable state | 8 | passed_after_fix | scripts | `tron status --json` reports mode, listener PID, health, stale dev pid-file diagnostics, server/health/database/log paths, and dev LaunchAgent label; `tron logs --json` emits bounded JSON rows with session/workspace/trace IDs and hardened filters. | Closed. | ODA-8 CLI/dev UX checkpoint |
| ODA-9 | Closeout, verification, adversarial self-audit, and residual-risk review | 10 | passed_after_fix | static gates/verification | Closed the scorecard at 100/100, added invariant gates for evidence rows, inventory rows, source guards, and stale wording, updated README/docs, and recorded verification commands in the evidence manifest. | Closed. | ODA-9 closeout checkpoint |

Total weight: **100**

## Findings

- The direct `logs::recent` worker accepted `sessionId` and `workspaceId` in
  its schema but ignored both, queried all recent log rows, did not accept a
  `traceId` filter, and omitted `workspaceId`/`traceId` from response rows.
- `tron logs` already emitted `workspaceId` and `traceId` in JSON output, but
  filtered only by a loosely interpolated session predicate. The closed slice
  adds exact session/workspace/trace filters and quotes string predicates.
- `tron logs` combined multiple predicates through a Bash `IFS` array join that
  used only the first `IFS` character, producing invalid SQL when multiple
  filters were active. The closed slice adds an explicit `AND` join helper.
- iOS diagnostics server-log entries hashed log/origin/session IDs but did not
  include workspace or trace hash fields. The closed slice adds those hashes
  while continuing to exclude raw IDs and private payload text.

## Static Gates

`packages/agent/tests/observability_diagnostics_auditability_invariants.rs`
and focused modules under
`packages/agent/tests/observability_diagnostics_auditability/` enforce:

- ODA row weights sum to 100 and current score equals closed row weights.
- README, local CI, and GitHub static-gate lists reference the ODA invariant
  target.
- Every closed ODA checkpoint has a manifest evidence row.
- Inventory TSV rows are structured, reference tracked or newly added files,
  and classify observed signals, correlation IDs, redaction boundaries, query
  behavior, and proof targets.
- `logs::recent`, `log_recent`, `tron logs`, iOS diagnostics, and Mac log
  readers keep their correlation and redaction source guards.
- Completed ODA artifacts reject stale active or unresolved wording.

## Verification Commands

Focused ODA target:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture
```

Required final closeout:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::logs --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/DiagnosticsBundleBuilderTests -only-testing:TronMobileTests/ClientLogIngestionServiceTests -only-testing:TronMobileTests/LogsClientTests
cd ../mac-app && xcodegen generate
xcodebuild test -scheme TronMac -destination 'platform=macOS' -only-testing:TronMacTests/DiagnosticsRedactorTests -only-testing:TronMacTests/MacSourceGuardTests -only-testing:TronMacTests/MenuBarLogReaderTests
cd ../..
git diff --check
git ls-files -ci --exclude-standard
git status --short
```
