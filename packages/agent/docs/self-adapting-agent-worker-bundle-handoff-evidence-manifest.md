# Self-Adapting Agent Worker Bundle Handoff Evidence Manifest

Status: **complete**

Scorecard: [`self-adapting-agent-worker-bundle-handoff-scorecard.md`](self-adapting-agent-worker-bundle-handoff-scorecard.md)

## Baseline Evidence

- Implementation branch: `codex/self-adapting-agent-worker-bundle-handoff`
- Baseline commit: `2d3cf28eb130bcf6ba22b59b55556ba22abea650`
- Source-grounded adjustment: existing SAAWA tokens are scoped policy objects carried inside the activation bundle, so SAAWBH treats the whole activation bundle as secret-bearing and persists only fingerprints plus expected ids.

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk |
|---|---|---|---|---|
| SAAWBH-0 | passed_after_fix | Added SAAWBH docs, inventory, invariant target, README links, and CI target wiring. | Static invariant docs/CI parity checks. | Final hash recorded at closeout. |
| SAAWBH-1 | passed_after_fix | Inventory covers activation issue, vault, redaction, launch, supervisor, replay, and boundaries. | TSV parser gate checks tracked rows and required surfaces. | New files require inventory updates. |
| SAAWBH-2 | passed_after_fix | Added explicit durable redaction for `worker::issue_activation`. | Activation tests inspect ledger/idempotency replay snapshot. | Redaction is intentionally narrow. |
| SAAWBH-3 | passed_after_fix | Added `WorkerActivationBundleVault`. | Static gate proves no SQLite/resource/stream, filesystem, queue, or process backing; tests inspect safe metadata only. | In-memory custody is lost on restart by design. |
| SAAWBH-4 | passed_after_fix | Issue activation stores live bundle in vault and keeps resource fingerprint-only. | `worker_activation_issues_scoped_resource_grant_token_and_replays_idempotently`. | First caller still receives the live one-time bundle. |
| SAAWBH-5 | passed_after_fix | Added `stdin_activation_bundle_v1` launch plan mode and secret material validation. | Orchestration tests and static contract scans. | String heuristics complement exact structural checks. |
| SAAWBH-6 | passed_after_fix | Supervisor request carries optional secret stdin; production writes once to piped stdin. | Static supervisor scan and fake supervisor safe metadata test. | OS-specific child behavior remains covered by direct-exec abstraction. |
| SAAWBH-7 | passed_after_fix | Launch consumes matching vault bundle before supervisor start; replay returns original process. | `worker_orchestration_stdin_activation_bundle_consumes_vault_once`. | Failed start requires new activation. |
| SAAWBH-8 | passed_after_fix | Durable/process audit stores only redaction markers, fingerprints, and byte counts. | Focused tests serialize durable/process payloads. | Broader sentinel sweep lives in invariant/static gates. |
| SAAWBH-9 | passed_after_fix | Existing SAAWA readiness path unchanged. | SAAWA/SAAWO focused tests continue to pass. | No scheduler restart is introduced. |
| SAAWBH-10 | passed_after_fix | No public/provider/scheduler/deploy/service-manager surface added. | `self_adapting_agent_worker_bundle_handoff_invariants`. | Future autostart requires successor scorecard. |
| SAAWBH-11 | passed_after_fix | Closeout command set listed below. | Final verification log. | None beyond existing dead-code warnings emitted by broad Rust builds. |

## Verification Log

Final local closeout commands all passed on this branch:

```bash
cargo test --manifest-path packages/agent/Cargo.toml worker_bundle_handoff --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_orchestration --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_activation --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml external_worker --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_bundle_handoff_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_orchestration_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_activation_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_promotion_governance_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```

Notes:

- `worker_bundle_handoff` is a required lib-test filter and currently matches no lib tests; the dedicated integration invariant target carries the SAAWBH static gates.
- The broad Rust commands still emit pre-existing dead-code warnings in provider and durability modules; no new failure was introduced.
- The SAASTC teardown pass re-audited SAAWBH custody and tightened the static
  guard so the vault cannot gain durable storage, filesystem, process, queue, or
  stream backing while claiming process-memory-only one-shot custody.
- SAAWTL reuses SAAWBH custody for trigger-created launch. The trigger bridge
  issues a fresh activation, leaves the live bundle in the in-memory vault, and
  launches only through `stdin_activation_bundle_v1`; attempt audit records keep
  ids, fingerprints, statuses, and redacted errors only.
- SAAWSD reuses SAAWBH custody indirectly through SAAWTL. Schedule ticks persist
  only safe queue/tick metadata and never store activation bundles, stdin
  payloads, vault material, process environment, or raw idempotency secrets.
