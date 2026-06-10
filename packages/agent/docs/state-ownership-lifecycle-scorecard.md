# State Ownership And Lifecycle Scorecard

Created: 2026-06-10

Initial score: **0/100**

Current score: **59/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`state-ownership-lifecycle-evidence-manifest.md`](state-ownership-lifecycle-evidence-manifest.md)

Inventory:
[`state-ownership-lifecycle-inventory.md`](state-ownership-lifecycle-inventory.md)
and
[`state-ownership-lifecycle-inventory.tsv`](state-ownership-lifecycle-inventory.tsv)

Invariant target:
[`../tests/state_ownership_lifecycle_invariants.rs`](../tests/state_ownership_lifecycle_invariants.rs)

## Scope

This campaign proves every stateful surface in Tron has exactly one owner,
an explicit truth/projection/cache/ephemeral classification, and a documented
create, mutate, hydrate, retire, and shutdown lifecycle.

The campaign does not change public APIs, protocol DTOs, iOS behavior, schema,
or generated Xcode projects unless a lifecycle bug requires it and the fix is
documented and tested.

## Non-Negotiable Direction

- Prefer deleting dead state over documenting it.
- Retained state needs an owner, lifecycle, concurrency guard, cleanup path, and
  evidence.
- iOS local event DB rows, drafts, pairing, cursors, diagnostics, and shared
  content are projections or local device state, not server truth.
- Server settings and auth state stay server-authoritative and are mutated only
  through their owner stores.
- Engine state stores remain owner-private; outside callers use
  `EngineHostHandle` or domain facades.
- Historical evidence may preserve old wording, but active scorecards,
  inventories, and README entries must not describe closed work as open.

## Operating Loop

1. Close one SOL row at a time.
2. Update this scorecard, inventory, and evidence manifest with exact proof and
   open loops.
3. Run focused verification for the row.
4. Commit the checkpoint before starting the next row.

## Scenario Ledger

| Row | Requirement | Points | Status | Owner | Evidence | Open loops | Checkpoint |
|---|---|---:|---|---|---|---|---|
| SOL-0 | Campaign harness, red static gate, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix | docs/static gates | Added SOL scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, stale living-doc cleanup scope, and red final-state gates for inventory coverage and closeout. | Later rows must populate the full inventory, delete or own dead state, and close every final gate. | SOL-0 campaign harness checkpoint |
| SOL-1 | Whole-repo state inventory for Rust server, iOS app, scripts/CI state, docs-owned state claims | 10 | passed_after_fix | docs/static gates | Generated an initial 476-row TSV covering every tracked production Rust/Swift file with SOL lifecycle markers plus required script/CI/docs state rows; no `unclassified_owner` rows remain. SOL-4 added two narrower runtime service rows, bringing the active TSV to 478 rows. | Later rows refine and prove the lifecycle claims in those rows. | SOL-1 state inventory checkpoint |
| SOL-2 | Truth taxonomy for every state surface | 8 | passed_after_fix | docs/static gates | Added `sol_truth_taxonomy_is_owner_scoped`; verified every row uses exactly one allowed `state_class`, has no unclassified owner, prevents iOS/script/docs rows from claiming canonical server truth, restricts canonical truth to session/settings/profile owners, restricts secrets to auth/Keychain/token owners, and keeps local device preferences iOS-local. | Later rows add subsystem-specific lifecycle proof over the classified inventory. | SOL-2 truth taxonomy checkpoint |
| SOL-3 | Server bootstrap lifecycle | 10 | passed_after_fix | app/storage/auth/bootstrap | Added `sol_server_bootstrap_lifecycle_is_source_backed`; verified startup order from Tron Home and bearer-token materialization through canonical DB generation/archive/flock/migrations, logging, retention/size-budget startup maintenance, engine host durable catalog hydration, domain/worker registration, crash-journal recovery, background task registration, bind, graceful shutdown, log flush, and final checkpoint. | No SOL-3 open loops; later rows prove steady-state runtime tasks, engine substrate, sessions, settings/auth, iOS state, and observability. | SOL-3 server bootstrap lifecycle checkpoint |
| SOL-4 | Runtime task and memory lifecycle | 12 | passed_after_fix | agent runtime/orchestrator/shutdown | Deleted dead `SessionManager::plan_mode`; added `sol_runtime_task_memory_lifecycle_is_source_backed`; proved active-session cache processing flags, run/retain RAII guards, sequence/compaction cleanup, invocation abort registry guards, capability pending cleanup, shutdown task registry, blocking supervisor drain, runtime service cancellation, and bootstrap background-task registration. | No SOL-4 open loops; later rows prove durable engine substrate, sessions, settings/auth, iOS state, observability, and final closeout. | SOL-4 runtime task and memory lifecycle checkpoint |
| SOL-5 | Engine durable substrate lifecycle | 14 | passed_after_fix | engine durability/authority/shared storage | Added `sol_engine_durable_substrate_lifecycle_is_source_backed`; proved ledger catalog/invocation/idempotency rows, queues and attempts, streams and cursors, resources and versions, grants, leases, audit-only compensation, state store revisions, payload refs, retention, checkpoint, export, and SQLite/in-memory primitive store ownership. | No SOL-5 open loops; later rows prove sessions, settings/auth, iOS state, observability, and final closeout. | SOL-5 engine durable substrate lifecycle checkpoint |
| SOL-6 | Session/event-store lifecycle | 10 | pending | session/event store | Not started. | Create/resume/fork/archive/delete/end, append ordering, active cache eviction, reconstruction, and session-scoped cleanup need proof. | pending |
| SOL-7 | Settings/auth/secrets lifecycle | 10 | pending | settings/auth | Not started. | Server-authoritative settings, atomic sparse writes, rollback, snapshots, auth.json materialization, OAuth pending-flow TTL, and token refresh need proof. | pending |
| SOL-8 | iOS projection and local state lifecycle | 14 | pending | iOS engine/support/session/ui | Not started. | EventDatabase, sync cursors, SessionSynchronizer, EventStoreManager, connection tasks, settings snapshots, pairing/token stores, drafts/history/share/diagnostics need projection/local classification. | pending |
| SOL-9 | Observability/recovery evidence | 4 | pending | health/logs/recovery | Not started. | Health/deep status, logs, storage stats, retention runs, replay manifests, and shutdown drain visibility need evidence. | pending |
| SOL-10 | Final closeout | 3 | pending | static gates/verification | Not started. | Stale wording guards, unclassified-state scan, orphan task/map scan, full verification, and clean worktree proof remain. | pending |

Total weight: **100**

## Initial Findings

- `packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs`
  contained `SessionManager::plan_mode: DashMap<String, bool>` with only local
  setter/getter references; SOL-4 deleted it rather than documenting dead state.
- Engine compensation records in
  `packages/agent/src/engine/authority/compensation.rs` are durable audit
  records with a single `Recorded` status. SOL-5 proved this is audit-only
  durable state; future automated rollback requires a new owner, status
  transitions, and tests rather than overloading the audit record.
- `packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager+Sync.swift`
  merges server session info with local projections. SOL-8 owns proof that local
  counts/head/root never become canonical server truth.
- README living architecture docs label completed 100/100 campaigns as active.
  SOL-0 starts the cleanup and SOL-10 guards final stale wording.
- iOS local-only state surfaces include pairing store, Keychain tokens, drafts,
  input history, pending share content, stream cursors, diagnostics, and the
  temporary event DB. SOL-8 owns explicit local/projection classification.

## Static Gates

`packages/agent/tests/state_ownership_lifecycle_invariants.rs` enforces:

- Scorecard weights sum to 100 and every row closes as `passed_after_fix`.
- Inventory rows use only allowed `state_class` values and cover every tracked
  production Rust/Swift file containing lifecycle markers.
- Scripts, CI workflows, and docs-owned state claims have explicit inventory
  rows.
- Canonical lifecycle state cannot be an unowned boolean/map without an
  inventory row and retirement path.
- Production `tokio::spawn` and long-lived iOS `Task` state has shutdown,
  cancellation, or scoped ownership documented.
- Settings/auth/profile writes stay behind owner stores.
- Engine state stores remain owner-private.
- iOS event DB, drafts, cursors, pairing, Keychain tokens, diagnostics, and
  pending share content are documented as projections/local state, never server
  truth.
- Active campaign docs reject stale open-loop wording after closeout.

## Verification Commands

Focused SOL target:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture
```

Focused implementation targets:

```bash
cargo test --manifest-path packages/agent/Cargo.toml session_manager --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml begin_run --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml retain --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml invocation_abort_registry --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml capability_invocation_tracker --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle::shutdown --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml shared::server::context --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml transport::runtime --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml app::bootstrap --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::authority --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::invocation::idempotency --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::invocation::meta_primitives --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::runtime::external_worker --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::auth --lib -- --nocapture
```

iOS focused targets:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EventStoreManagerTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConnectionReconnectTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SettingsStateTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/PairedServerStoreTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/DraftStoreTests
```

Final closeout:

```bash
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../..
git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```
