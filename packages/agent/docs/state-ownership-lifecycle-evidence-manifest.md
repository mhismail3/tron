# State Ownership And Lifecycle Evidence Manifest

Status: **active**

Current score: **15/100**

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
| SOL-2 | pending | Not started. | Not run. | Truth taxonomy remains. | pending |
| SOL-3 | pending | Not started. | Not run. | Server bootstrap lifecycle proof remains. | pending |
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

## Residual Risk Log

- The `@self-inspect` project skill is not available in the current configured
  skill/tool list. The campaign therefore uses direct source scans and focused
  repository tests for the SOL-0 harness; later rows should use any available
  local database inspection paths when a lifecycle claim depends on runtime
  state under `~/.tron/internal/database/`.
