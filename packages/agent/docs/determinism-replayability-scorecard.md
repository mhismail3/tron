# Determinism Replayability Scorecard

Created: 2026-06-09

Initial score: **0/100**

Current score: **90/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`determinism-replayability-evidence-manifest.md`](determinism-replayability-evidence-manifest.md)

Inventory:
[`determinism-replayability-inventory.md`](determinism-replayability-inventory.md)
and
[`determinism-replayability-inventory.tsv`](determinism-replayability-inventory.tsv)

Invariant target:
[`../tests/determinism_replayability_invariants.rs`](../tests/determinism_replayability_invariants.rs)

## Scope

This campaign proves Tron can deterministically reconstruct and audit a session
from durable records without calling model providers again, running tools again,
writing files, spawning processes, or mutating engine resources.

Replay v1 is audit and reconstruction replay. It is not side-effect
re-execution.

## Non-Negotiable Direction

- No provider re-contact during replay.
- No tool, process, file, queue, stream, resource, or provider side effects
  during replay.
- No fallback replay format, compatibility branch, legacy alias, or historical
  database adapter.
- No timestamp-only ordering in replay-critical sections.
- Canonical replay hashes use byte-stable JSON with sorted object keys.
- Provider request audit is persisted before a provider stream is opened.
- Production still uses wall-clock time and UUIDv7; replay-critical tests and
  constructors get explicit IDs and timestamps.

## Operating Loop

1. Close one DRC row at a time.
2. Update this scorecard and the evidence manifest with exact proof and open
   rows.
3. Run the focused DRC invariant target when the row touches replay behavior or
   closeout state.
4. Commit the checkpoint before starting the next row.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence contract | Open rows | Checkpoint |
|----|------|-------:|--------|-------|-------------------|-----------|------------|
| DRC-0 | Scorecard, evidence, inventory, invariant target, README, and CI wiring | 6 | passed_after_fix | docs_or_scorecard | Added DRC scorecard, evidence manifest, replay-critical inventory docs/TSV, invariant target scaffolding, README living-doc links, and local/GitHub closeout target wiring. | DRC-2 through DRC-10 own behavioral proof and final closeout. | DRC-0/1 formalization checkpoint |
| DRC-1 | Replay-critical source inventory | 8 | passed_after_fix | storage | Inventoried session events, provider request audits, trace records, engine invocation ledger rows, stream rows, queue items/attempts, resources, timestamps, IDs, provider envelopes, and replay hash/order owners. | DRC-2 through DRC-8 implement and prove the inventory contracts. | DRC-0/1 formalization checkpoint |
| DRC-2 | Entropy centralization and allow-list | 12 | passed_after_fix | storage | `replay_critical_entropy_is_allow_listed` scans Rust source for raw UTC/system/instant clocks, UUIDv7, RNG, and `ORDER BY timestamp`, failing outside explicit owner paths. | DRC-5/DRC-6 must keep replay builders outside entropy allow-list paths and use stable ordering. | DRC-2/3 entropy and identity checkpoint |
| DRC-3 | Deterministic constructors and injection seams | 12 | passed_after_fix | storage | Added explicit event/session/workspace/fork identities, `append_with_identity`, `create_session_with_identity`, `fork_with_identity`, and `InvocationRecord::from_result_at` with DB-boundary tests. | Queue/stream replay listing and manifest import/roundtrip use these seams in DRC-5 through DRC-8. | DRC-2/3 entropy and identity checkpoint |
| DRC-4 | Provider request audit before model streaming | 12 | passed_after_fix | model_loop | Added typed `model.provider_request` session event, responder-boundary request audit DTO, provider exact-envelope audit payloads, and turn-runner persistence before `respond`. | DRC-5/DRC-6 must include provider audits in the replay manifest and canonical hashes. | DRC-4 provider audit checkpoint |
| DRC-5 | Canonical `tron.replay.v1` manifest export | 14 | passed_after_fix | session | Added `session::replay_manifest` pure-read capability plus read-only `execute` operation `replay_manifest`; both delegate to the same server-owned builder and return session events, provider audits, traces, idempotency entries, invocations, streams, and queue rows. | No open loops after DRC-7/DRC-8. | DRC-5/6 replay manifest checkpoint |
| DRC-6 | Byte-stable replay hashes and stable ordering | 10 | passed_after_fix | storage | Added sorted-key canonical JSON hashing for every replay section plus overall `replayHash`; replay reads use sequence order, cursor ASC, timestamp ASC + id ASC, idempotency stable key order, rowid append order + invocation id, and queue ASC + created_at ASC + receipt_id ASC. | No open loops after DRC-7/DRC-8. | DRC-5/6 replay manifest checkpoint |
| DRC-7 | Replay references across idempotency, queue, stream, and trace records | 8 | passed_after_fix | engine | Added session-scoped idempotency replay reads, `engineIdempotencyEntries`, request/outcome/result/payload hashes, and roundtrip cross-record validation for provider audit refs, trace request/result hashes, queue attempt refs, stream parent refs, invocation idempotency refs, and idempotency invocation refs. | No open loops after DRC-7/DRC-8. | DRC-7/8 replay references and roundtrip checkpoint |
| DRC-8 | Offline replay roundtrip harness | 8 | passed_after_fix | test_harness | Added `roundtrip_manifest`, a pure manifest-to-report verifier that recomputes section hashes and `replayHash`, rebuilds durable section counts, validates cross-record references, and holds no handles capable of provider, tool, queue, stream, file, process, or resource side effects. | No open loops after DRC-7/DRC-8. | DRC-7/8 replay references and roundtrip checkpoint |
| DRC-9 | Progressive docs, README, protocol docs, and iOS decode parity | 4 | pending | docs_or_scorecard | Docs and iOS event decoding are updated for any transport-visible or persisted event surface change. | Awaiting event/protocol updates. | pending |
| DRC-10 | Final adversarial closeout | 6 | pending | test_harness | Score reaches 100/100, active docs contain no stale open-loop wording, focused/full verification is clean, and final checkpoint is committed. | Awaiting all implementation rows. | pending |

Total weight: **100**

## Current Source Findings

- Session reconstruction already uses persisted event order and session-local
  sequence numbers.
- Engine invocation ledgers, stream rows, queue rows, resource rows, leases,
  compensation rows, and trace records exist in the unified SQLite file.
- `session.export` is session-only and not a replay manifest.
- `session::replay_manifest` now returns canonical `format:
  "tron.replay.v1"` manifests with section hashes and an overall replay hash.
- The replay manifest includes `engineIdempotencyEntries`, payload hashes for
  stream/queue rows, result hashes for engine invocations, and outcome hashes
  for completed idempotency entries.
- `roundtrip_manifest` verifies replay manifests offline by recomputing hashes
  and checking cross-record references without any runtime side-effect handles.
- Provider request audit is persisted as a turn-scoped `model.provider_request`
  session event before the model responder opens the provider stream.
- Trace listing and several UI-oriented event/queue queries use newest-first or
  timestamp-oriented order; replay uses separate stable listing methods.
- Replay-critical session/event/invocation constructors now have explicit
  identity/timestamp seams while production paths still use UUIDv7 and
  wall-clock timestamps.
- Raw time, UUIDv7, RNG, and timestamp-only ordering are guarded by a DRC source
  scan with explicit owner-path allow-list entries for non-replay runtime,
  security, maintenance, and diagnostic cases.

## Verification Commands

Focused DRC target:

```bash
cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture
```

Final closeout target set:

```bash
/Users/moose/Downloads/projects/tron/scripts/tron ci fmt check clippy test
/Users/moose/Downloads/projects/tron/scripts/personal-info-guard.sh
git diff --check
git ls-files -ci --exclude-standard
git status --short
```
