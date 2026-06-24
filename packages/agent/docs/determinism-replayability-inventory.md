# Determinism Replayability Inventory

Created: 2026-06-09

Status: DRC-10 `passed_after_fix`; replay v1 campaign complete

Machine-readable inventory:
[`determinism-replayability-inventory.tsv`](determinism-replayability-inventory.tsv)

## Classification

- `source`: durable data that replay must include or explicitly exclude.
- `entropy`: raw time, UUID, RNG, or ordering source relevant to replay.
- `hash`: canonical byte-stable digest owner.
- `api`: capability or operation surface that exposes replay data.
- `proof`: invariant or harness that proves replay behavior.

## Replay-Critical Sources

| Source | Durable owner | Current order | Replay contract | Gap owner |
|--------|---------------|---------------|-----------------|-----------|
| Session events | `events` table through `EventStore` | `session_id`, `sequence ASC` for session exports | Include every event for the requested session, including provider request audit events, in sequence order / sequence ASC. | DRC-5/DRC-6 passed |
| Provider request audit | `model.provider_request` event | session sequence | Persist provider/model/request audit before provider stream open; include it in replay manifest/hashes. | DRC-4/DRC-5/DRC-6 passed |
| Trace records | `trace_records` table through `EventStore` | current list is newest-first by timestamp | Replay list uses ascending stable order: timestamp ASC + id ASC. | DRC-5/DRC-6 passed |
| Engine invocations | `engine_invocations` table through engine ledger | ledger append order | Include session-scoped invocation records in append order plus invocation IDs and result hashes. | DRC-7 passed |
| Engine idempotency entries | `engine_idempotency_entries` table through engine ledger | stable key order | Include entries that are session-scoped or referenced by first/latest session invocation; carry payload fingerprint request hash, outcome hash, first/latest invocation refs, replay behavior, and status. | DRC-7 passed |
| Engine streams | `engine_stream_events` table | cursor ascending for poll/list-by-trace | Include session-scoped stream rows by cursor ASC. | DRC-5/DRC-6 passed |
| Queue items and attempts | `engine_queue_items` table | current list is queue-scoped by creation time | Replay list uses stable durable key order: queue ASC + created_at ASC + receipt_id ASC, includes attempt records, and adds payload hashes. | DRC-7 passed |
| Resources | engine resource tables | resource/version/link order varies by API | Replay v1 records resource refs and hashes carried by invocation, trace, queue attempt, lease, compensation, and produced-resource rows; direct resource table export is not part of replay v1. | DRC-7 passed |
| Logs | `logs` table | newest-first UI query | Replay v1 excludes log text unless trace records reference it; logs remain diagnostics, not replay causality. | DRC-7 passed |
| Storage payload blobs | `storage_payloads`/`blobs` | referenced by owner IDs | Replay resolves stored JSON payload refs before hashing manifest sections. | DRC-5/DRC-6 passed |

## Entropy Sources

| Pattern | Current owner examples | Replay stance | Gap owner |
|---------|------------------------|---------------|-----------|
| `chrono::Utc::now` / `Utc::now` | event/store identity owner, approval request/decision audit timestamps, session rows, engine ledger, queues, streams, traces, memory resource/prompt-trace audit timestamps, capability startup jobs-reconciliation cutoff, job lifecycle audit timestamps, Git index-change and commit resource audit timestamps, storage maintenance, settings, tests | Static guard allow-lists approved owners; replay-critical event/session constructors now accept explicit IDs/timestamps, approval checks expose `check_approval_at` for replayed freshness evaluation, and memory/job/git resource timestamps stay append-only audit metadata rather than replay ordering keys. | DRC-2/DRC-3 passed; DRC-5/DRC-6 guard replay builders; P2AER-S2 approval refresh; P2AER-S3 memory foundation; P2AER Slice 5A jobs foundation; P2AER Slice 6B git index mutation; P2AER Slice 6C git commit evidence |
| `std::time::SystemTime::now` | provider cache pruning, Gemini/Ollama stream helpers | Allowed only for provider/runtime non-replay jitter or diagnostics unless audit fields depend on it. | DRC-2 |
| `std::time::Instant::now` | health, bootstrap, shutdown, provider duration, turn timing, capability duration, transcription sidecar elapsed time, job process elapsed time and timeout checks | Allowed for durations and health timing; replay hashes use persisted values, not live instants. Transcription and job elapsed time are execution diagnostics, not replay identity. | DRC-2 |
| `Uuid::now_v7` | `event_store::identity`, engine ID helpers, streams, payload refs, OAuth flow IDs, transcription sidecar temp/request IDs | Replay-critical event/session/workspace/fork IDs get deterministic constructors; security/platform and sidecar-local correlation IDs stay allowed by path. | DRC-2/DRC-3 passed; DRC-5/DRC-8 consume seams |
| `rand::random` / `rand::rng` | OAuth PKCE, onboarding bearer tokens, SQLite contention jitter | Allowed for security tokens and contention jitter; rejected from replay builders. | DRC-2 |
| `ORDER BY timestamp` | trace lists, workspace/global event lists, queue trace list | UI/diagnostic latest views may keep timestamp order; replay paths use deterministic tie-breakers. | DRC-2/DRC-6 |

## API Surfaces

| Surface | Current state | Replay change |
|---------|---------------|---------------|
| `session::export` | returns `format: "tron.session.v1"` with session row and session events only | Keep as session backup/export; do not overload it into replay. |
| `session::replay_manifest` | implemented pure read | Returns canonical `format: "tron.replay.v1"` manifest with section hashes and overall `replayHash`. |
| `execute` operation `replay_manifest` | implemented read-only current-session operation | Delegates to the same session replay builder and does not create a trace record. |
| `engineIdempotencyEntries` | implemented manifest section | Carries request/outcome hashes and first/latest invocation refs for idempotency replay proof. |
| `roundtrip_manifest` | implemented offline harness | Recomputes section and replay hashes, rebuilds counts, and validates cross-record references without side-effect handles. |
| iOS persisted event decoding | `model.provider_request` decodes as non-rendering metadata | DRC-9 passed; replay manifests are capability results, not persisted/live iOS events. |

## Proof Surfaces

| Proof | Purpose | Gap owner |
|-------|---------|-----------|
| `determinism_replayability_invariants` | Static and focused behavioral DRC target | DRC-10 passed |
| Provider-audit test | Proves audit persists before stream open | DRC-4 passed |
| Replay manifest hash test | Proves canonical JSON/hash stability | DRC-5/DRC-6 passed |
| Replay ordering test | Proves no timestamp-only replay order | DRC-6 passed |
| Cross-record reference test | Proves trace/queue/stream/invocation/idempotency refs explain a turn | DRC-7 passed |
| Offline roundtrip test | Rebuilds from durable records without side effects | DRC-8 passed |
| Docs/protocol/iOS parity test | Guards README, protocol docs, session progressive docs, and iOS replay/event parity docs | DRC-9 passed |
| Final closeout test | Enforces 100/100 and no stale active open-loop wording | DRC-10 passed |

## DRC-2/DRC-3 Closure Notes

- `packages/agent/tests/determinism_replayability/entropy_scanning.rs` is now
  the source-level allow-list for raw replay-critical entropy.
- `packages/agent/src/domains/session/event_store/identity.rs` owns explicit
  event/session/workspace/fork identities for deterministic replay/import tests.
- `EventStore::append_with_identity`, `EventStore::create_session_with_identity`,
  and `EventStore::fork_with_identity` persist explicit IDs/timestamps at the
  SQLite boundary.
- `InvocationRecord::from_result_at` is the deterministic engine invocation
  timestamp seam.
- `approval::check_approval_at` is the deterministic freshness seam for
  replaying approval checks against an explicit timestamp; live approval
  request/decision handlers keep UTC timestamps as durable audit evidence.
- Memory foundation UTC timestamps are limited to resource lifecycle,
  migration-envelope, and prompt-trace audit fields; replay paths must continue
  to use explicit resource refs/hashes and stable row ordering rather than live
  clocks.
- Job lifecycle UTC timestamps and elapsed-time measurements are limited to
  durable audit state, timeout checks, and output metadata; replay paths consume
  resource refs/hashes and stream/trace evidence, not live clocks.
- Replay builders are guarded against new raw clock/UUID/RNG calls and
  timestamp-only ordering.

## DRC-4 Closure Notes

- `model.provider_request` is now a typed session event.
- The shared `ModelProviderRequestAudit` payload records format, provider,
  model, context window, session id, reasoning level, provider-visible message
  and capability counts, stream options, and provider request body.
- Provider-backed responders mark exact provider envelopes explicitly; custom
  responders receive a provider-independent snapshot through the trait default.
- `execute_turn` persists the audit before `responder.respond(model_request)`;
  persistence failure returns a turn error without opening the model stream.

## DRC-5/DRC-6 Closure Notes

- `packages/agent/src/domains/session/replay/` owns the canonical
  `tron.replay.v1` manifest builder, sorted-key JSON hashing, section hashes,
  and overall replay hash.
- `session::replay_manifest` is a pure-read capability with required
  `sessionId`.
- `execute` operation `replay_manifest` delegates to the same builder for the
  current session and bypasses execute trace creation so it does not mutate the
  manifest it exports.
- Engine-owned replay rows are read through narrow owner APIs:
  `ledger_invocations_by_session`, `ledger_idempotency_by_session`, stream
  `list_by_session`, queue `list_by_session`, and
  `EngineHostHandle::replay_snapshot`.
  Session-owned trace replay rows use `timestamp ASC + id ASC`.

## DRC-7/DRC-8 Closure Notes

- The manifest includes `engineIdempotencyEntries` plus `requestHash`,
  `outcomeHash`, first/latest invocation refs, replay behavior, status, and
  stable scope keys.
- Engine invocation projections include `resultHash`; stream and queue
  projections include `payloadHash`; trace records keep Agent Trace
  `requestHash` and `resultHash` metadata.
- `roundtrip_manifest` rebuilds counts, recomputes all canonical hashes, and
  validates provider-audit, trace, idempotency, invocation, queue, and stream
  cross-record references from a manifest value only.
- No replay path calls providers, executes tools, writes files, spawns
  processes, mutates queues/streams/resources, or performs side-effect
  re-execution.

## DRC-10 Closure Notes

- The scorecard and evidence manifest record `100/100` and `complete` status.
- The active scorecard and inventory have no unresolved closeout wording.
- `drc_closeout_is_complete` guards the final state and final TSV proof row.
- No open loops remain.
