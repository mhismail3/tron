# Determinism Replayability Evidence Manifest

Created: 2026-06-09

Current score: **100/100**

Status: **complete**

Branch: `codex/primitive-engine-teardown`

Scorecard:
[`determinism-replayability-scorecard.md`](determinism-replayability-scorecard.md)

Inventory:
[`determinism-replayability-inventory.md`](determinism-replayability-inventory.md)
and
[`determinism-replayability-inventory.tsv`](determinism-replayability-inventory.tsv)

## Row Status

| Row | Status | Evidence |
|-----|--------|----------|
| DRC-0 | passed_after_fix | Added scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, and CI/local test target wiring. |
| DRC-1 | passed_after_fix | Source inventory records replay-critical surfaces, storage owner, current order, replay gap, and planned proof owner. |
| DRC-2 | passed_after_fix | Static entropy/order guard scans source for raw time, UUIDv7, RNG, and timestamp-only ordering outside explicit owner paths. |
| DRC-3 | passed_after_fix | Deterministic event/session/workspace/fork identities and invocation-record timestamp constructor are implemented and tested. |
| DRC-4 | passed_after_fix | `model.provider_request` event, responder-boundary audit payload, provider exact-envelope marking, and pre-stream turn-runner persistence are implemented and tested. |
| DRC-5 | passed_after_fix | `tron.replay.v1` manifest builder, `session::replay_manifest`, and read-only `execute` operation `replay_manifest` are implemented and tested. |
| DRC-6 | passed_after_fix | Section and overall replay hashes use sorted-key canonical JSON; replay rows use stable non-timestamp-only order and focused tests cover byte stability. |
| DRC-7 | passed_after_fix | Idempotency entries, queue rows, stream rows, trace records, and invocation records now expose replay refs and request/result/payload/outcome hashes in the canonical manifest. |
| DRC-8 | passed_after_fix | `roundtrip_manifest` rebuilds replay evidence from a manifest value, recomputes canonical hashes, and validates cross-record refs without side-effect handles. |
| DRC-9 | passed_after_fix | README, protocol docs, session progressive docs, iOS event docs, and iOS architecture docs describe replay manifest parity; no new iOS event decoder is needed because replay manifests are capability results. |
| DRC-10 | passed_after_fix | Final closeout records 100/100 status, closes active DRC inventory and scorecard loops, guards stale closeout wording, and runs the focused plus full verification set. |

## DRC-0 Evidence

Files added:

- `packages/agent/docs/determinism-replayability-scorecard.md`
- `packages/agent/docs/determinism-replayability-evidence-manifest.md`
- `packages/agent/docs/determinism-replayability-inventory.md`
- `packages/agent/docs/determinism-replayability-inventory.tsv`
- `packages/agent/tests/determinism_replayability_invariants.rs`
- `packages/agent/tests/determinism_replayability/`

Files updated:

- `README.md`
- `scripts/tron.d/quality.sh`
- `.github/workflows/ci.yml`

Focused command:

```bash
cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture
```

Recorded result: pass after tightening the inventory wording for replay order
contracts.

Open rows after DRC-0: DRC-2, DRC-3, DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9,
and DRC-10.

## DRC-1 Evidence

Inventory command:

```bash
rg -n "session\\.export|replay|manifest|EventStore|append|sequence|provider_request|ModelResponder|respond|stream|Utc::now|SystemTime::now|Instant::now|Uuid::now_v7|rand::|random\\(|ORDER BY timestamp" /Users/<USER>/Downloads/projects/tron/packages/agent/src /Users/<USER>/Downloads/projects/tron/packages/agent/tests /Users/<USER>/Downloads/projects/tron/README.md
```

Inventory result: replay-critical storage surfaces and entropy/order sources
were recorded in `determinism-replayability-inventory.md` and
`determinism-replayability-inventory.tsv`.

Open rows after DRC-1: DRC-2, DRC-3, DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9,
and DRC-10.

## DRC-2 Evidence

Files updated:

- `packages/agent/tests/determinism_replayability/entropy_scanning.rs`

Proof:

- `replay_critical_entropy_is_allow_listed` scans `packages/agent/src/**/*.rs`
  for `Utc::now`, `SystemTime::now`, `Instant::now`, `Uuid::now_v7`, RNG, and
  `ORDER BY timestamp`.
- The test failed before fix on unlisted OAuth flow timing and an agent-runner
  test UUID owner, then passed after those owners were explicitly allowed.
- P2AER-S2 refreshed the allow-list for `domains/approval`: live
  request/decision handlers write UTC audit/freshness timestamps, and replayed
  approval checks use the deterministic `check_approval_at` timestamp seam.
- The restoration consolidation refreshed the allow-list for
  `domains/capability/mod.rs`: the capability worker captures a UTC
  `startup_cutoff` for jobs reconciliation so stale pre-startup running-state
  cleanup stays bounded to process startup instead of replay identity.

Open rows after DRC-2: DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9, and DRC-10.
DRC-5/DRC-6 must keep replay builders out of the entropy allow-list and prove
stable replay ordering.

## DRC-3 Evidence

Files added:

- `packages/agent/src/domains/session/event_store/identity.rs`

Files updated:

- `packages/agent/src/domains/session/event_store/mod.rs`
- `packages/agent/src/domains/session/event_store/factory/mod.rs`
- `packages/agent/src/domains/session/event_store/sqlite/repositories/session/mod.rs`
- `packages/agent/src/domains/session/event_store/sqlite/repositories/workspace.rs`
- `packages/agent/src/domains/session/event_store/store/event_store/event_log.rs`
- `packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs`
- `packages/agent/src/engine/invocation/model.rs`

Proof:

- `append_with_identity` persists explicit event ID/timestamp while preserving
  session sequence/head behavior.
- `create_session_with_identity` and `fork_with_identity` persist explicit
  workspace/session/root event identities and deterministic activity timestamps.
- `InvocationRecord::from_result_at` persists an explicit completion timestamp.

Open rows after DRC-3: DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9, and DRC-10.

## DRC-4 Evidence

Files added:

- `packages/agent/src/shared/protocol/model_audit.rs`
- `packages/agent/src/domains/session/event_store/types/payloads/model.rs`

Files updated:

- `packages/agent/src/shared/protocol/mod.rs`
- `packages/agent/src/domains/model/responder/mod.rs`
- `packages/agent/src/domains/model/providers/shared/provider.rs`
- `packages/agent/src/domains/model/providers/anthropic/provider/mod.rs`
- `packages/agent/src/domains/model/providers/google/provider/mod.rs`
- `packages/agent/src/domains/model/providers/kimi/provider.rs`
- `packages/agent/src/domains/model/providers/minimax/provider.rs`
- `packages/agent/src/domains/model/providers/ollama/provider.rs`
- `packages/agent/src/domains/model/providers/openai/provider/mod.rs`
- `packages/agent/src/domains/agent/loop/turn_runner/mod.rs`
- `packages/agent/src/domains/agent/loop/turn_runner/persistence/mod.rs`
- `packages/agent/src/domains/agent/loop/orchestrator/agent_runner.rs`
- `packages/agent/src/domains/session/event_store/mod.rs`
- `packages/agent/src/domains/session/event_store/types/generated.rs`
- `packages/agent/src/domains/session/event_store/types/payloads/mod.rs`
- `packages/agent/src/domains/session/event_store/types/tests.rs`
- `packages/ios-app/Sources/Engine/Events/Live/EventTypeRegistry.swift`
- `packages/ios-app/Sources/Engine/Persistence/SQLite/EventTypes.swift`
- `packages/ios-app/Sources/Engine/Persistence/SQLite/SessionEvent+Summary.swift`
- `packages/ios-app/Tests/Engine/Events/EventTypeRegistryTests.swift`
- `README.md`

Proof:

- `ModelResponder::request_audit` builds a durable audit payload from the same
  stream options later used by `respond`.
- Provider-backed responders store provider exact-envelope audit bodies when
  providers expose them; the trait default stores a provider-independent
  snapshot for custom responders.
- `execute_turn` persists `model.provider_request` through
  `persist_model_provider_request_audit` before calling `responder.respond`.
- `provider_request_audit_persist_failure_prevents_model_response` aborts the
  persister worker and proves `respond` is not called.
- `provider_request_audit_persists_before_assistant_message` proves the audit
  row is persisted before the assistant message row in session sequence order.

Open rows after DRC-4: DRC-5, DRC-6, DRC-7, DRC-8, DRC-9, and DRC-10.

## DRC-5 Evidence

Files added:

- `packages/agent/src/domains/session/replay/mod.rs`
- `packages/agent/src/domains/session/replay/tests.rs`
- `packages/agent/src/domains/capability/operations/replay.rs`
- `packages/agent/src/engine/durability/replay.rs`

Files updated:

- `packages/agent/src/domains/session/mod.rs`
- `packages/agent/src/domains/session/contract.rs`
- `packages/agent/src/domains/session/query/mod.rs`
- `packages/agent/src/domains/session/query/operations.rs`
- `packages/agent/src/domains/capability/operations/mod.rs`
- `packages/agent/src/domains/capability/contract.rs`
- `packages/agent/src/engine/invocation/host/substrate_handle.rs`
- `packages/agent/src/engine/catalog/registry/mod.rs`
- `packages/agent/src/engine/durability/mod.rs`
- `packages/agent/tests/primitive_trace_execution.rs`

Proof:

- `session::replay_manifest` is registered as a `PureRead` session capability.
- The manifest builder returns `format: "tron.replay.v1"` with sections for
  session row, resolved session events, provider audit events, trace records,
  engine invocations, stream rows, and queue rows.
- `capability::execute` operation `replay_manifest` delegates to the same
  builder for the current session and bypasses execute trace creation so the
  read does not mutate trace records.
- `execute_replay_manifest_is_read_only_and_does_not_create_trace_record`
  proves the execute surface returns a manifest without adding a trace row.

Open rows after DRC-5: DRC-7, DRC-8, DRC-9, and DRC-10.

## DRC-6 Evidence

Files updated:

- `packages/agent/src/domains/session/replay/mod.rs`
- `packages/agent/src/domains/session/event_store/sqlite/repositories/trace.rs`
- `packages/agent/src/domains/session/event_store/store/event_store/trace_log.rs`
- `packages/agent/src/engine/durability/ledger/mod.rs`
- `packages/agent/src/engine/durability/ledger/memory.rs`
- `packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs`
- `packages/agent/src/engine/durability/queue/memory.rs`
- `packages/agent/src/engine/durability/queue/sqlite_store.rs`
- `packages/agent/src/engine/durability/streams/memory.rs`
- `packages/agent/src/engine/durability/streams/sqlite_store.rs`
- `packages/agent/src/engine/primitives/stores.rs`
- `packages/agent/src/engine/tests/fixtures/mod.rs`

Proof:

- `canonical_hash` serializes sorted-object JSON and hashes with SHA-256 hex.
- Replay section hashes cover each section, and `replayHash` covers the
  manifest without the self-referential `replayHash` field.
- Replay ordering is section-specific and stable: session event sequence,
  provider audit event sequence, trace `timestamp ASC, id ASC`, invocation
  durable append order plus invocation id, stream cursor ASC, and queue
  `queue ASC, created_at ASC, receipt_id ASC`.
- `replay_manifest_is_byte_stable_and_covers_durable_sections` proves repeated
  exports are equal, hashes are present, provider audits are included, trace
  timestamp ties use id order, streams are session-scoped, queue rows use the
  durable key order, and engine invocations are included.
- `canonical_hash_sorts_nested_object_keys` proves nested object key sorting.

Open rows after DRC-6: DRC-7, DRC-8, DRC-9, and DRC-10.

## DRC-7 Evidence

Files added:

- `packages/agent/tests/determinism_replayability/replay_references.rs`

Files updated:

- `packages/agent/src/domains/session/replay/mod.rs`
- `packages/agent/src/domains/session/replay/tests.rs`
- `packages/agent/src/engine/catalog/registry/mod.rs`
- `packages/agent/src/engine/durability/ledger/mod.rs`
- `packages/agent/src/engine/durability/ledger/memory.rs`
- `packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs`
- `packages/agent/src/engine/durability/replay.rs`
- `packages/agent/src/engine/invocation/host/substrate_handle.rs`
- `packages/agent/src/engine/tests/fixtures/mod.rs`

Proof:

- `EngineLedgerStore::list_idempotency_by_session` and
  `LiveCatalog::ledger_idempotency_by_session` expose idempotency entries
  through the engine owner boundary, not through session-domain SQLite queries.
- SQLite replay idempotency ordering uses stable durable keys:
  `function_id ASC, scope_kind ASC, scope_value ASC, idempotency_key ASC`.
- `EngineReplaySnapshot` includes idempotency entries alongside invocation,
  stream, and queue rows.
- The canonical replay manifest now includes `engineIdempotencyEntries` with
  `payloadFingerprint`, `requestHash`, `outcomeHash`, first/latest invocation
  refs, replay behavior, status, and outcome.
- Manifest projections add `resultHash` to engine invocations and `payloadHash`
  to stream and queue rows. Trace records already persist request/result hashes
  in Agent Trace metadata written by `execute`.
- `replay_manifest_is_byte_stable_and_covers_durable_sections` now proves
  idempotency entries are present, request hashes match payload fingerprints,
  completed idempotency outcomes have hashes, invocation results have hashes,
  and stream/queue payloads have hashes.
- `replay_manifest_carries_cross_record_hashes_and_refs` statically guards the
  cross-record implementation markers.

Open rows after DRC-7: DRC-9 and DRC-10.

## DRC-8 Evidence

Files added:

- `packages/agent/src/domains/session/replay/roundtrip.rs`
- `packages/agent/tests/determinism_replayability/offline_roundtrip.rs`

Files updated:

- `packages/agent/src/domains/session/replay/mod.rs`
- `packages/agent/src/domains/session/replay/tests.rs`

Proof:

- `roundtrip_manifest` accepts only a manifest `serde_json::Value`; it has no
  event-store, engine, model, tool, file, process, queue, stream, or resource
  handles.
- The harness recomputes every section hash, recomputes the manifest hash after
  removing `replayHash`, rebuilds durable section counts, and validates
  provider audit event refs, trace request/result hashes, idempotency
  request/outcome hashes, invocation result/idempotency refs, queue attempt
  invocation refs, and stream parent invocation refs.
- Hash or reference mismatches return errors. There is no compatibility branch,
  fallback parser, alternate replay format, or side-effect re-execution path.
- `replay_manifest_is_byte_stable_and_covers_durable_sections` runs the offline
  roundtrip against a generated manifest and asserts empty hash/reference
  mismatch lists.
- `offline_roundtrip_harness_is_wired_without_side_effect_handles` statically
  guards the harness markers.

Open rows after DRC-8: DRC-9 and DRC-10.

## DRC-9 Evidence

Files added:

- `packages/agent/tests/determinism_replayability/docs_parity.rs`

Files updated:

- `README.md`
- `packages/agent/src/domains/session/mod.rs`
- `packages/agent/src/shared/protocol/mod.rs`
- `packages/agent/src/shared/protocol/model_audit.rs`
- `packages/ios-app/docs/architecture.md`
- `packages/ios-app/docs/events.md`
- `packages/agent/tests/determinism_replayability/mod.rs`
- `packages/agent/tests/determinism_replayability/scorecard_inventory.rs`

Proof:

- README now documents `engineIdempotencyEntries`, idempotency request/outcome
  hashes, invocation `resultHash`, stream/queue `payloadHash`, and the replay
  manifest's no-side-effect capability-result status.
- Session progressive docs identify replay idempotency refs and the offline
  roundtrip harness.
- Protocol docs state that `model.provider_request` DTOs feed canonical replay
  manifest provider-audit sections.
- iOS docs state that `model.provider_request` is metadata-only persisted audit
  evidence and `replay_manifest` is not a live or persisted iOS event.
- `drc_docs_and_protocol_parity_are_current` guards README, protocol, session,
  and iOS docs against drift.

Open rows after DRC-9: DRC-10.

Historical open-row lines above preserve point-in-time evidence for earlier DRC
checkpoints. The active scorecard and inventory now record no open loops.

## DRC-10 Evidence

Files updated:

- `packages/agent/docs/determinism-replayability-scorecard.md`
- `packages/agent/docs/determinism-replayability-evidence-manifest.md`
- `packages/agent/docs/determinism-replayability-inventory.md`
- `packages/agent/docs/determinism-replayability-inventory.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv`
- `packages/agent/docs/primitive-code-cleanup-file-inventory.tsv`
- `packages/agent/docs/true-modularity-boundary-inventory.tsv`
- `packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv`
- `packages/agent/tests/determinism_replayability/closeout.rs`
- `packages/agent/tests/determinism_replayability/scorecard_inventory.rs`
- `packages/agent/tests/determinism_replayability/replay_references.rs`

Proof:

- DRC score is `100/100`; every DRC row is `passed_after_fix`.
- Active scorecard and inventory docs contain no stale unresolved closeout
  phrases.
- `drc_closeout_is_complete` guards final score, row status, evidence status,
  inventory status, final TSV proof, and unresolved wording.
- Full CI red proof caught missing cleanup-inventory classifications for the
  new DRC docs/source/test files; the final checkpoint classifies every tracked
  DRC file in `primitive-code-cleanup-file-inventory.tsv`.
- Full CI then caught the same missing DRC coverage in the hierarchical
  rearchitecture inventories; the final checkpoint adds matching HRA file and
  ownership rows.
- Closeout inventory audit also added DRC rows to the TPC retention inventory
  and TMB boundary inventory before the final full-suite rerun.
- Full CI then caught raw user home paths copied from the external plan into
  DRC docs and assertions; committed DRC artifacts now use `/Users/<USER>`.
- Final verification command results are recorded in the verification log.
- No open loops remain.

## Verification Log

| Time | Command | Exit | Notes |
|------|---------|-----:|-------|
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | Initial DRC-0/1 run caught missing exact `cursor ASC` replay-order contract text in the inventory. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-0/1 invariant target passed: 9 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 1 | Rustfmt found formatter drift in the new invariant test files; fixed with `cargo fmt`. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | Post-format DRC-0/1 invariant target passed: 9 passed, 0 failed. |
| 2026-06-09 | `git diff --check` | 0 | DRC-0/1 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-2 guard caught missing allow-list owners for OAuth flow timing and an agent-runner test UUID. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-2/3 invariant target passed: 11 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml with_identity --lib -- --nocapture` | 101 | DRC-3 constructor tests exposed non-deterministic `last_activity_at` updates after root event persistence. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml with_identity --lib -- --nocapture` | 0 | Deterministic identity tests passed: 4 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml invocation_record_from_result_at_pins_timestamp --lib -- --nocapture` | 0 | Invocation-record timestamp seam passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | DRC-2/3 Rust formatting applied cleanly. |
| 2026-06-09 | `git diff --check` | 0 | DRC-2/3 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml domains::session::event_store:: --lib -- --nocapture` | 0 | Session event-store slice passed after explicit activity timestamp changes: 403 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC invariant target caught stale DRC-0/1 score/status expectations after DRC-2/3 docs were updated. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | Final DRC-2/3 invariant target passed: 11 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 0 | DRC-2/3 formatted state verified. |
| 2026-06-09 | `git diff --check` | 0 | Final DRC-2/3 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml provider_backed_request_audit_uses_stream_options_and_exact_payload --lib -- --nocapture` | 101 | DRC-4 compile caught a stale unused `Value` import after changing provider audit return type. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml provider_backed_request_audit_uses_stream_options_and_exact_payload --lib -- --nocapture` | 0 | Model responder audit test passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml provider_request_audit_persist_failure_prevents_model_response --lib -- --nocapture` | 0 | Pre-stream audit persistence failure test passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml typed_payload_model_provider_request --lib -- --nocapture` | 0 | Typed payload test for `model.provider_request` passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml provider_request_audit --lib -- --nocapture` | 0 | Agent-runner DRC-4 tests passed: 2 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-4 invariant run caught test-only `AtomicUsize`/`Ordering` imports at module scope. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-4 invariant target passed: 11 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml domains::session::event_store::types:: --lib -- --nocapture` | 0 | Event type/payload tests passed after adding `model.provider_request`: 69 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 0 | DRC-4 Rust formatting verified. |
| 2026-06-09 | `xcodegen generate` | 0 | iOS project regenerated after event registry changes. |
| 2026-06-09 | `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests` | 65 | iOS build caught missing `modelProviderRequest` summary switch case. |
| 2026-06-09 | `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests` | 0 | SourceGuard passed after adding non-chat provider request summary: 39 passed, 0 failed. |
| 2026-06-09 | `git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | 0 | `xcodegen generate` left the project file unchanged. |
| 2026-06-09 | `cargo check --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | Agent crate check passed for DRC-4 changes. |
| 2026-06-09 | `git diff --check` | 0 | DRC-4 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml replay --lib -- --nocapture` | 101 | Initial DRC-5/6 replay test compile caught missing trait methods on test ledger fixtures and an invalid synthetic authority grant. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml replay --lib -- --nocapture` | 0 | Replay builder/hash test passed: 12 filtered replay-related tests passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml execute_replay_manifest_is_read_only_and_does_not_create_trace_record --test primitive_trace_execution -- --nocapture` | 0 | Execute replay manifest read-only test passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-5/6 invariant target passed: 13 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml clarification_includes_capability_execution_guidance --lib -- --nocapture` | 0 | Provider primer guidance test passed after adding `replay_manifest` and its trace exception. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml execute_schema_exposes_primitive_operations_not_catalog_targets --lib -- --nocapture` | 0 | Capability schema test passed after adding `replay_manifest` to the provider-visible operation description. |
| 2026-06-09 | `cargo check --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | Agent crate check passed for DRC-5/6 changes. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml replay --lib -- --nocapture` | 101 | DRC-7/8 compile caught an unused `ReplayRoundtripReport` re-export. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml replay --lib -- --nocapture` | 0 | DRC-7/8 replay slice passed: 12 filtered replay-related tests passed, including manifest idempotency/hash assertions and offline roundtrip. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-7/8 invariant target passed: 16 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml replay --lib -- --nocapture && cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | Post-`cfg(test)` roundtrip harness verification passed both compile paths. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml engine::tests::durability::ledger_idempotency --lib -- --nocapture` | 0 | Engine ledger idempotency module passed: 11 passed, including shared in-memory/SQLite storage contract for session idempotency listing. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 0 | DRC-7/8 Rust formatting verified. |
| 2026-06-09 | `cargo check --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | Agent crate check passed for DRC-7/8 changes. |
| 2026-06-09 | `git diff --check` | 0 | DRC-7/8 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-9 docs parity guard caught README replay manifest/event wording split across Markdown lines. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-9 docs parity guard caught iOS replay manifest/event wording split across Markdown lines. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-9 docs parity guard caught missing exact protocol provenance marker in `model_audit.rs`. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-9 invariant target passed: 17 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 0 | DRC-9 Rust formatting verified. |
| 2026-06-09 | `cargo check --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | Agent crate check passed for DRC-9 docs/protocol changes. |
| 2026-06-09 | `git diff --check` | 0 | DRC-9 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/<USER>/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-10 focused closeout target passed: 17 passed, 0 failed. |
| 2026-06-09 | `/Users/<USER>/Downloads/projects/tron/scripts/tron ci fmt check clippy test` | 1 | Initial DRC-10 full CI caught missing `primitive-code-cleanup-file-inventory.tsv` classifications for DRC files; fixed by adding retained DRC closeout rows. |
| 2026-06-09 | `/Users/<USER>/Downloads/projects/tron/scripts/tron ci fmt check clippy test` | 1 | Second DRC-10 full CI caught missing HRA file and ownership inventory rows for DRC files; fixed by adding retained DRC closeout rows. |
| 2026-06-09 | `/Users/<USER>/Downloads/projects/tron/scripts/tron ci fmt check clippy test` | 1 | Third DRC-10 full CI caught raw home paths in DRC docs/tests through the personal-info guard; fixed by normalizing committed paths to `/Users/<USER>`. |
| 2026-06-09 | `/Users/<USER>/Downloads/projects/tron/scripts/tron ci fmt check clippy test` | 0 | Full DRC-10 final verification passed on the final edited tree. |
| 2026-06-09 | `/Users/<USER>/Downloads/projects/tron/scripts/personal-info-guard.sh` | 0 | Full personal-info guard passed. |
| 2026-06-09 | `git diff --check` | 0 | Final DRC-10 diff has no whitespace errors. |
| 2026-06-09 | `git ls-files -ci --exclude-standard` | 0 | Ignored tracked-file audit returned no output. |
| 2026-06-09 | `git status --short` | 0 | Post-checkpoint clean worktree proof returned no output. |

## Residual Risk Log

| Risk | Owner Row | State |
|------|-----------|-------|
| Direct resource table export is intentionally excluded from replay v1 because invocation rows, trace rows, queue attempts, leases, compensation refs, and produced resource refs carry the replay-causal resource references required to explain a turn. | DRC-7 | Closed. |
| Offline replay harness exists and rejects hash/reference mismatches without holding side-effect handles. | DRC-8 | Closed. |
