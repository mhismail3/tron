# Determinism Replayability Scorecard

Created: 2026-06-09

Initial score: **0/100**

Current score: **14/100**

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
| DRC-2 | Entropy centralization and allow-list | 12 | pending | storage | Static guard rejects replay-critical raw time, UUID, RNG, and timestamp-only ordering outside approved owners. | Awaiting code guard and allow-list proof. | pending |
| DRC-3 | Deterministic constructors and injection seams | 12 | pending | storage | Replay-critical IDs/timestamps can be injected in tests and import/roundtrip paths without replacing production wall-clock behavior. | Awaiting constructors and tests. | pending |
| DRC-4 | Provider request audit before model streaming | 12 | pending | model_loop | A `model.provider_request` session event is written before the provider stream opens through the model responder boundary. | Awaiting event type, responder audit value, and turn-runner persistence proof. | pending |
| DRC-5 | Canonical `tron.replay.v1` manifest export | 14 | pending | session | `session::replay_manifest` returns session events, provider audits, traces, invocations, streams, and queue rows from one read-only builder. | Awaiting builder, contract, and operation. | pending |
| DRC-6 | Byte-stable replay hashes and stable ordering | 10 | pending | storage | Each replay section and the overall manifest use canonical JSON hashes and stable non-timestamp-only order. | Awaiting canonical serializer and hash/order tests. | pending |
| DRC-7 | Replay references across idempotency, queue, stream, and trace records | 8 | pending | engine | Durable records contain enough request/result hashes and replay refs to explain a turn. | Awaiting cross-record proof. | pending |
| DRC-8 | Offline replay roundtrip harness | 8 | pending | test_harness | A no-side-effect harness rebuilds a session from durable records and compares canonical hashes. | Awaiting harness. | pending |
| DRC-9 | Progressive docs, README, protocol docs, and iOS decode parity | 4 | pending | docs_or_scorecard | Docs and iOS event decoding are updated for any transport-visible or persisted event surface change. | Awaiting event/protocol updates. | pending |
| DRC-10 | Final adversarial closeout | 6 | pending | test_harness | Score reaches 100/100, active docs contain no stale open-loop wording, focused/full verification is clean, and final checkpoint is committed. | Awaiting all implementation rows. | pending |

Total weight: **100**

## Current Source Findings

- Session reconstruction already uses persisted event order and session-local
  sequence numbers.
- Engine invocation ledgers, stream rows, queue rows, resource rows, leases,
  compensation rows, and trace records exist in the unified SQLite file.
- `session.export` is session-only and not a replay manifest.
- Provider request audit is not yet persisted as a turn-scoped session event.
- Trace listing and several UI-oriented event/queue queries use newest-first or
  timestamp-oriented order; replay needs separate stable listing methods.
- Entropy is scattered across event factories, session creation, engine
  invocation records, queue/stream stores, provider cache helpers, health
  checks, OAuth, storage maintenance, and tests. DRC-2 owns the allow-list.

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

