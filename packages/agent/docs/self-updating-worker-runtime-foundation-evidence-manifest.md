# Self-Updating Worker Runtime Foundation Evidence Manifest

Status: `complete`

Branch: `codex/self-updating-worker-runtime-foundation-current`
Baseline: `4cb2387f1a872f9fabaf58bdd88330065113b914`

## Evidence Summary

SUWRF-0 through SUWRF-10 are backed by source changes, focused tests, static
invariants, README/docs updates, and final closeout commands. Failed attempts
are retained here because they shaped the final implementation.

## Focused Evidence

- SUWRF-1: `domains::worker_lifecycle` is registered as an in-process domain
  worker in `domains::registration`; `/engine/workers` remains the external
  worker protocol host.
- SUWRF-2: `WorkerPackageManifest` validates `tron.worker_package.v1`, package
  identity/version/provenance, local source, no-shell argv, env allowlist,
  expected functions/triggers, requested grants, conformance, and rollback.
  Full validation computes a deterministic `sha256:` digest over every regular
  file under the canonical source root and rejects manifest mismatches.
- SUWRF-3: apply functions reject bootstrap grants and untrusted actor kinds;
  launch derives a narrower worker grant before minting `ScopedWorkerToken`.
- SUWRF-4: `SystemWorkerLauncher` uses `Command`, `env_clear`, explicit env,
  canonical package-root paths, no shell, `kill_on_drop(true)`, and
  `TRON_WORKER_ENDPOINT` / `TRON_WORKER_TOKEN_JSON`.
- SUWRF-5: `launch_worker` waits for live catalog conformance before returning
  `running`.
- SUWRF-6: lifecycle state is recorded as generic resources plus
  `worker.lifecycle` stream events.
- SUWRF-7: failed launch or failed conformance updates
  launch/package/installation state to `failed`; verified stop returns
  package/installation state to `enabled`; unowned stop fails without writing
  clean stopped evidence; lifecycle requests wait for startup reconciliation,
  which downgrades stale durable running attempts to `unhealthy`.
- SUWRF-8: no Swift DTO or native product-panel expansion was needed; generic
  resource and stream visibility is the iOS parity surface for this slice.
- SUWRF-9: `self_updating_worker_runtime_foundation_invariants` is the static
  gate for source and closeout parity.
- SUWRF-10: README, module docs, inventory, evidence, static gates, focused
  tests, and final closeout commands are complete.

## Failed Attempts and Fixes

- Initial failed-launch handling wrote a `worker_launch_attempt` update without
  schema-required `argv` and `endpoint` fields. The resource store rejected the
  update, leaving the installation enabled. Fix: failed launch payloads now
  preserve the full launch-attempt schema and the focused test asserts the
  installation becomes `failed`.
- Initial positive conformance fixture registered a workspace-visible test
  function without workspace provenance, so catalog visibility hid it. Fix: the
  fixture uses system visibility while production conformance remains
  visibility-aware.
- Diff audit found that a successful process spawn followed by conformance
  failure could leave the launch attempt optimistic while package/installation
  were failed, and `stop_worker` could overwrite launch-attempt payloads without
  required schema fields. Fix: conformance failures now mark the launch attempt
  failed with process evidence, stop preserves the current payload, and focused
  tests cover both paths.
- Full CI initially failed the primitive teardown README phrase guard after the
  new docs used the historical `worker pack` phrase in current behavior text.
  Fix: current docs now use package-lifecycle wording and leave the historical
  phrase only in historical evidence where predecessor gates allow it.
- Full CI then failed the determinism entropy guard because lifecycle code used
  direct `Utc::now` / `Instant::now` timestamps. Fix: package resources rely on
  resource-version timestamps, derived worker grants inherit parent expiry, and
  conformance waits use `tokio::time::timeout`.
- Full CI then failed the hierarchical file-budget guard because the first
  lifecycle implementation was a 2600+ line `mod.rs`. Fix: split the domain into
  authority, contract, handlers, launcher, manifest, params, resources, and test
  owners; HRA 35/35 passes with every lifecycle source file under budget.
- Full CI then failed the post-AHA README startup-domain anchor after the domain
  registration paragraph was rewritten. Fix: restored the expected anchor while
  documenting `worker_lifecycle` as the explicit post-baseline exception.
- Retrospective audit found three important gaps: stop left package and
  installation resources `running`, `packageDigest` was only syntax-checked,
  and launcher process ownership was volatile across restart. Fix: stop now
  updates package/installation resources back to `enabled` and supports
  immediate relaunch; install/launch full validation verifies the manifest
  digest against deterministic source-tree bytes with no exclusions; launcher
  stop fails when ownership is missing, child drop is fail-safe, and startup
  reconciliation marks durable running attempts `unhealthy` while returning the
  package/installation to relaunchable `enabled`.
- Retrospective re-audit found startup reconciliation could still race a new
  lifecycle launch request because it ran asynchronously outside request
  ordering. Fix: lifecycle functions now wait on the shared startup
  reconciliation cell before handling requests, and focused regression coverage
  pauses reconciliation at the old race window to prove current-process launches
  cannot be downgraded by stale startup ownership-loss reconciliation.

## Command Evidence

Focused and predecessor commands run:

```bash
cargo check --manifest-path packages/agent/Cargo.toml --all-targets
cargo test --manifest-path packages/agent/Cargo.toml worker_lifecycle -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test self_updating_worker_runtime_foundation_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants startup_domains_and_database_inventory_match_runtime_truth -- --nocapture
```

Final closeout commands passed before commit:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test self_updating_worker_runtime_foundation_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_lifecycle -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```

Final `scripts/tron ci fmt check clippy test` passed after the README startup
anchor fix. Final `git status --short` was run before staging and showed only
the intended SUWRF source, docs, README, workflow, and static-gate changes.

## iOS Parity Evidence

No Swift/protocol/UI behavior was changed. SUWRF uses existing generic engine
resource and stream surfaces, so iOS parity is the ability to observe
`worker_package*` resources and `worker.lifecycle` events through the current
generic runtime shell. No iOS 26.5 simulator run is required for this slice
unless later edits touch Swift, protocol DTOs, or UI behavior.
