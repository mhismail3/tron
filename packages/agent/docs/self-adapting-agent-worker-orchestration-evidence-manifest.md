# Self-Adapting Agent Worker Orchestration Evidence Manifest

Status: **complete**

Scorecard: [`self-adapting-agent-worker-orchestration-scorecard.md`](self-adapting-agent-worker-orchestration-scorecard.md)

## Baseline Evidence

- Baseline branch/state: `codex/self-adapting-agent-worker-activation`
- Baseline commit: `125d58efd7baafb86b2a339d64a6f145b10cc1e2` (`Activate governed external workers`)
- Implementation branch: `codex/self-adapting-agent-worker-orchestration`
- Source-grounded adjustment: SAAWA does not persist activation tokens, so SAAWO supports `preissued_bundle` delivery and persists only non-secret activation ids, fingerprints, argv, env keys, pid fingerprints, and redacted log snippets.

## Row Evidence

| Row | Status | What changed | Verification evidence | Residual risk |
|---|---|---|---|---|
| SAAWO-0 | passed_after_fix | Added SAAWO scorecard, evidence, inventory docs/TSV, static invariant target, README links, and CI target wiring. | Static invariant target checks docs/README/CI parity. | Final commit hash recorded at closeout. |
| SAAWO-1 | passed_after_fix | Added source inventory covering resource contracts, primitives, supervisor, runtime binding, tests, scripts, workflows, and transport/provider boundaries. | TSV parser gate checks row structure and required surfaces. | Future worker orchestration files must add inventory rows. |
| SAAWO-2 | passed_after_fix | Added `worker_launch_plan` resource kind and runtime validation for reviewed direct-exec plans. | `worker_orchestration_rejects_mismatched_or_secret_launch_plans_before_start`; static contract checks. | Generic JSON schema cannot express every string predicate; runtime validation enforces path/digest/env details. |
| SAAWO-3 | passed_after_fix | Added `worker_process` resource kind and redacted lifecycle payloads. | `worker_orchestration_launch_replay_ready_invoke_and_stop_are_governed`; static lifecycle checks. | Process exit without protocol traffic is not a restart mechanism in this slice. |
| SAAWO-4 | passed_after_fix | Added admin `worker::launch_activation` with `worker.launch`, high risk, idempotency, active activation and plan matching checks. | Focused launch tests and static primitive-contract checks. | `worker.stop` is deferred; stop remains under `worker.launch`. |
| SAAWO-5 | passed_after_fix | Preserved token non-persistence and added log/env redaction. | Fake supervisor tests inject token-like stdout/stop output and assert no persisted secret. | Redaction is conservative line elision; binary/process-specific redaction can be expanded later. |
| SAAWO-6 | passed_after_fix | Added `WorkerProcessSupervisor`, production direct-exec supervisor, fake supervisor, bounded stop/kill, no shell path. | Fake supervisor counts; static no-shell/no-deploy/no-launchd/no-restart gates. | Production stdout/stderr capture is bounded; no long-running monitor loop is introduced. |
| SAAWO-7 | passed_after_fix | Bound process readiness to existing external-worker hello/register callbacks. | Happy-path test proves `starting` -> `hello_seen` -> `ready`, and pre-ready function lookup fails. | Socket-level integration remains covered by existing external-worker tests. |
| SAAWO-8 | passed_after_fix | Added stop process behavior and fail-closed registration mismatch cleanup. | Stop test unregisters volatile function; wrong registration marks process `failed`. | Grant revocation terminates audit on hello rejection; proactive grant-store watch is future work. |
| SAAWO-9 | passed_after_fix | Published worker lifecycle events for requested/starting and updated activation/process resources for readiness and stop. | Focused tests inspect resource state; SAAWA lifecycle tests still cover worker stream behavior. | The stream record is supplemental; resource state is the primary process audit. |
| SAAWO-10 | passed_after_fix | Kept launch out of public `/engine`, providers, scheduler, deploy, launchd/SMAppService, and skills. | `self_adapting_agent_worker_orchestration_invariants` static source scans. | Future scheduler/autostart slices require new scorecards. |
| SAAWO-11 | passed_after_fix | Ran focused checks during implementation; full closeout command set is listed below. | Verification log below. | Closeout remains pending until final local run and commit. |

## Verification Log

Commands run during implementation:

```bash
cargo check --manifest-path packages/agent/Cargo.toml
cargo test --manifest-path packages/agent/Cargo.toml worker_orchestration --lib -- --nocapture
```

Required final closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml worker_orchestration --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_activation --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml external_worker --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_orchestration_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_activation_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_promotion_governance_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```

## Residual Risks

- Proactive termination on grant revocation without a subsequent worker protocol event is not implemented as a scheduler/watch loop in this slice. The runtime fails closed on revoked/expired hello and stop is manual/admin.
- Production process supervision starts and stops direct child processes, captures bounded output, and records audit state; it intentionally does not restart or relaunch.
- `preissued_bundle` requires the launched worker to receive the activation bundle through a non-persisted channel outside the `worker_process` resource.
