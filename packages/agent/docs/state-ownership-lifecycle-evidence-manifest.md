# State Ownership And Lifecycle Evidence Manifest

Status: **active**

Current score: **33/100**

Scorecard:
[`state-ownership-lifecycle-scorecard.md`](state-ownership-lifecycle-scorecard.md)

Inventory:
[`state-ownership-lifecycle-inventory.md`](state-ownership-lifecycle-inventory.md)
and
[`state-ownership-lifecycle-inventory.tsv`](state-ownership-lifecycle-inventory.tsv)

## Row Ledger

| Row | Status | Evidence | Verification | Open loops | Checkpoint |
|---|---|---|---|---|---|
| SOL-0 | passed_after_fix | Added the campaign scorecard, evidence manifest, inventory scaffolding, machine-readable TSV header, invariant target, and README living-doc links. The invariant target is intentionally red for later rows until inventory coverage and closeout are complete. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture` expected to fail on final-state gates at SOL-0. | SOL-1 through SOL-10 remain open by design. | SOL-0 campaign harness checkpoint |
| SOL-1 | passed_after_fix | Generated `state-ownership-lifecycle-inventory.tsv` with 476 rows covering every tracked production Rust/Swift file containing SOL lifecycle markers plus README, SOL docs, scripts, and CI workflow state surfaces. Owner pass removed all `unclassified_owner` rows. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory -- --nocapture` -> exit 0, 3 passed. | Later rows refine lifecycle proof for bootstrap, runtime tasks, engine substrate, session/event store, settings/auth, iOS local state, and observability. | SOL-1 state inventory checkpoint |
| SOL-2 | passed_after_fix | Added and passed owner-scoped truth taxonomy guards over the 476-row TSV: allowed classes are documented; `unclassified_owner` is rejected; iOS/script/CI/docs rows cannot claim canonical server truth; canonical truth is restricted to session event-store, settings profile, and shared profile owners; secret rows are restricted to auth/Keychain/token owners; local device preferences remain iOS-local. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_truth_taxonomy -- --nocapture` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_rows_are_structured_and_classified -- --nocapture` -> exit 0. | Later rows prove lifecycle behavior behind each classified owner. | SOL-2 truth taxonomy checkpoint |
| SOL-3 | passed_after_fix | Source-backed bootstrap lifecycle proof now covers directories, bearer-token materialization, canonical DB policy, generation archive, process flock, integrity check, migrations, shared storage schema, logging, startup retention/size-budget maintenance, engine host durable catalog hydration, domain/worker registration, crash-journal recovery, background task registration, bind, graceful shutdown, log flush, and final checkpoint. | `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_server_bootstrap_lifecycle_is_source_backed -- --nocapture` -> exit 0; implementation targets listed in the SOL-3 evidence section passed. | Later rows prove steady-state runtime tasks, engine substrate, sessions, settings/auth, iOS state, and observability. | SOL-3 server bootstrap lifecycle checkpoint |
| SOL-4 | pending | Not started. | Not run. | Runtime task/memory lifecycle proof and dead `plan_mode` cleanup remain. | pending |
| SOL-5 | pending | Not started. | Not run. | Engine durable substrate lifecycle proof remains. | pending |
| SOL-6 | pending | Not started. | Not run. | Session/event-store lifecycle proof remains. | pending |
| SOL-7 | pending | Not started. | Not run. | Settings/auth/secrets lifecycle proof remains. | pending |
| SOL-8 | pending | Not started. | Not run. | iOS projection/local state lifecycle proof remains. | pending |
| SOL-9 | pending | Not started. | Not run. | Observability/recovery evidence remains. | pending |
| SOL-10 | pending | Not started. | Not run. | Final verification and clean worktree proof remain. | pending |

## SOL-0 Evidence

Artifacts added:

- `packages/agent/docs/state-ownership-lifecycle-scorecard.md`
- `packages/agent/docs/state-ownership-lifecycle-evidence-manifest.md`
- `packages/agent/docs/state-ownership-lifecycle-inventory.md`
- `packages/agent/docs/state-ownership-lifecycle-inventory.tsv`
- `packages/agent/tests/state_ownership_lifecycle_invariants.rs`
- Root README living architecture links for the SOL artifacts.

Initial red findings captured in the scorecard:

- Unowned/dead `SessionManager::plan_mode`.
- Audit-only compensation status requires proof or terminal lifecycle.
- iOS event-store session metadata merges local projections with server
  session info and needs server-truth proof.
- README living-doc status wording still needs a stale active-label cleanup pass.
- iOS local-only stores need explicit local/projection classifications.

## SOL-1 Evidence

Inventory coverage:

- Total TSV rows: 476.
- State class counts: `ephemeral_runtime` 260, `projection_cache` 71,
  `durable_substrate` 68, `canonical_truth` 41, `secret` 16,
  `diagnostic_buffer` 11, `local_device_preference` 9.
- Required non-Rust/Swift surfaces are covered: `README.md`,
  `scripts/tron`, `scripts/tron.d/dev.sh`, `scripts/tron.d/quality.sh`,
  `scripts/tron-lib.d/service.sh`, and `.github/workflows/ci.yml`.
- Owner audit: no `unclassified_owner` rows remain.

## SOL-2 Evidence

Taxonomy guard:

- `sol_truth_taxonomy_is_owner_scoped` requires every allowed state class to be
  documented and rejects taxonomy drift in the TSV.
- Canonical truth rows are limited to `session_event_store`,
  `settings_profile`, and `shared_foundation`.
- iOS, script, CI, and docs rows cannot claim canonical server truth.
- Secrets are limited to auth credentials, Keychain, and paired-server token
  storage.
- Local device preference rows are iOS-owned.

## SOL-3 Evidence

Bootstrap lifecycle proof:

- `run_server` performs directory seeding and bearer-token materialization before
  opening the database, then opens the canonical event-store DB, loads profile
  runtime/settings, initializes SQLite-backed logging, runs startup retention
  and size-budget maintenance, constructs the event store and engine host,
  recovers crash journals, registers domain/worker surfaces, starts owned
  runtime services, binds the server, and drains through graceful shutdown.
- `init_database` resolves the production `tron.sqlite` path, creates the
  parent directory, archives non-current storage generations, acquires the
  process `flock` before opening the pool, checks integrity, runs session
  migrations, and ensures shared storage schema.
- `onboarding::load_or_create_bearer_token` reads an existing token or
  serializes first-run materialization through the auth storage writer and
  atomic save path.
- `StorageRuntime` applies WAL/busy-timeout/foreign-key pragmas, records the
  current storage generation, archives stale generation sidecars, and records
  checkpoints.
- `EngineHost::open_sqlite` prepares the shared active DB, checkpoints it,
  opens the SQLite ledger, hydrates durable catalog definitions, attaches
  SQLite primitive stores, and bootstraps primitive/meta capabilities.
- Durable external-worker restart behavior is covered by
  `sqlite_restart_marks_durable_worker_unhealthy_without_socket_reconnect`, so
  a persisted worker definition hydrates as non-runnable until the worker
  reconnects.

## Verification Log

- SOL-0 harness proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_campaign_harness_exists -- --nocapture`
  -> exit 0.
- SOL-0 red static proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 3 passing scaffold/shape tests and 8 expected later-row
  failures: inventory coverage, script/CI/docs rows, dead `plan_mode`, Rust
  `tokio::spawn` lifecycle guards, Swift `Task` lifecycle guards, settings/auth
  owner-private write guard, iOS local-state classification rows, and final
  closeout.
- SOL-0 formatting/whitespace proof:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check &&
  git diff --check` -> exit 0.
- SOL-1 focused verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory -- --nocapture`
  -> exit 0, 3 passed.
- SOL-1 full-target status:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture`
  -> exit 101, with 9 passing gates and 2 expected remaining failures:
  `dead_plan_mode_state_is_removed` and `final_closeout_is_complete`.
- SOL-2 focused verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_truth_taxonomy -- --nocapture`
  -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_inventory_rows_are_structured_and_classified -- --nocapture`
  -> exit 0.
- SOL-3 static source-backed verification:
  `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants sol_server_bootstrap_lifecycle_is_source_backed -- --nocapture`
  -> exit 0.
- SOL-3 implementation verification:
  `cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle --lib -- --nocapture`
  -> exit 0, 43 passed; `cargo test --manifest-path packages/agent/Cargo.toml app::bootstrap --lib -- --nocapture`
  -> exit 0, 80 passed; `cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture`
  -> exit 0, 6 passed; `cargo test --manifest-path packages/agent/Cargo.toml sqlite_restart_marks_durable_worker_unhealthy_without_socket_reconnect --lib -- --nocapture`
  -> exit 0, 1 passed; `cargo test --manifest-path packages/agent/Cargo.toml process_lock --lib -- --nocapture`
  -> exit 0, 11 passed.

## Residual Risk Log

- The `@self-inspect` project skill is not available in the current configured
  skill/tool list. The campaign therefore uses direct source scans and focused
  repository tests for the SOL-0 harness; later rows should use any available
  local database inspection paths when a lifecycle claim depends on runtime
  state under `~/.tron/internal/database/`.
