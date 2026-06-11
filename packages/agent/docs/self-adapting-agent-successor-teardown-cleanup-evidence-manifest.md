# Self-Adapting Agent Successor Teardown Cleanup Evidence Manifest

Status: **source_teardown_in_progress**

Branch: `codex/self-adapting-agent-successor-teardown-cleanup`
Baseline commit: `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7`
Integration head under audit: `9e8ccb1cf129ba8ef1dc14d9050e84da5ee7e3b3`
Original operator plan: `/Users/moose/.codex/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt`

## Baseline Evidence

- `git status --short --branch` showed a clean worktree on
  `codex/self-adapting-agent-successor-teardown-cleanup` at Phase 1 start.
- `git rev-parse --short=12 HEAD` reported `9e8ccb1cf129`.
- `git diff --name-status b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD`
  listed 142 pre-cleanup changed files before adding the SAASTC harness.
- The original plan frames self-adapting-agent work as successor work after
  infrastructure hardening, so this pass audits that successor work for teardown
  rather than inventing new original-list slices.

## Verification Log

| Row | Status | Evidence | Residual risk |
| --- | --- | --- | --- |
| SAASTC-0 | passed_after_fix | Added the cleanup scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, local `scripts/tron.d/quality.sh` target, and GitHub Rust static-gates target. | Later source teardown must keep these artifacts synchronized as files are simplified or removed. |
| SAASTC-1 | passed_after_fix | `self_adapting_agent_successor_teardown_cleanup_invariants` validates every file in the ODA-baseline-to-current-HEAD diff has a TSV row with classification, owner, action, and rationale. | Initial classifications are not final retention decisions; SAASTC-2 through SAASTC-8 must replace conservative `simplify` rows with source-proven outcomes. |
| SAASTC-2 | pending_source_teardown | Not yet closed in Phase 1. | Retained primitive contracts still need source mapping. |
| SAASTC-3 | pending_source_teardown | Not yet closed in Phase 1. | Dead code and test cruft still need removal or reduction. |
| SAASTC-4 | pending_source_teardown | Not yet closed in Phase 1. | Boundary guards still need adversarial source audit after teardown edits. |
| SAASTC-5 | pending_source_teardown | Not yet closed in Phase 1. | Authority and governance paths may still contain duplicate policy planes. |
| SAASTC-6 | pending_source_teardown | Not yet closed in Phase 1. | Durable state/resource schemas still need field-level justification. |
| SAASTC-7 | pending_source_teardown | Not yet closed in Phase 1. | Runtime lifecycle and concurrency ownership still need boundedness proof. |
| SAASTC-8 | pending_source_teardown | Not yet closed in Phase 1. | Tests may still preserve removable successor behavior. |
| SAASTC-9 | pending_source_teardown | Not yet closed in Phase 1. | Successor docs may still contain stale future-slice wording. |
| SAASTC-10 | pending_source_teardown | Not yet closed in Phase 1. | Cross-campaign regression remains for closeout. |
| SAASTC-11 | pending_source_teardown | Not yet closed in Phase 1. | Full verification and adversarial closeout remain for final cleanup. |

## Source Teardown Log

- Removed `packages/agent/src/transport/runtime/worker_schedule.rs` and the
  server-start schedule poller from `packages/agent/src/transport/runtime/mod.rs`.
  Updated SAAWSD/SAAWSC docs, inventories, and static gates so they now enforce
  explicit schedule runtime only and reject `EngineWorkerScheduleService`
  autostart wiring.
- Split `packages/agent/src/engine/runtime/worker_schedule/tick_dispatch.rs`
  from `worker_schedule/mod.rs` to keep trigger enqueue and tick resource
  mutation owner-private while closing the TPC hard file-budget guard.
- Tightened `capability::execute` resource authorship:
  `packages/agent/src/domains/capability/operations/resource.rs` now enforces
  an explicit retained authorship kind allowlist, requires `kind` for
  `resource_list`, denies system resources, and preflights inspect/update/link
  targets against the current session/workspace before mutation. This keeps
  worker activation/process/schedule resources out of the provider-visible
  primitive while retaining typed resource authorship.
- Updated the capability runtime child grant from two to four remaining
  invocations, matching the guarded `resource_link` call graph without opening
  an unbounded authority path. The failing intermediate authorship test exposed
  the old budget mismatch; rerun passed after the bounded budget fix.
- Renamed `worker_activation_bundle_metadata_for_test` to
  `worker_activation_bundle_metadata` in the host handle and call sites because
  production orchestration uses that safe metadata for stdin bundle preflight.
- Reduced worker activation grant authority by changing the grant substrate to
  allow empty `fileRoots` as a no-file-access child grant, then issuing worker
  activation grants with empty file roots instead of `/`. Focused authority
  tests prove empty file roots persist, pathless invocations still run, and
  path-bearing invocations fail before handler execution.
- Tightened `packages/agent/src/engine/invocation/host/promotion_governance.rs`
  so system-scoped governance resources require an admin-like actor. Added a
  runtime regression for non-admin workspace promotion using system-scoped
  governance refs and a SAPG static guard for the exact scope branch. This moves
  the promotion-governance SAASTC rows from conservative `simplify` to
  source-proven `retained` without closing the broader SAASTC authority row.
- Removed `startupTimeoutMs` from the `worker::launch_from_trigger` request
  schema and runtime payload pass-through. Trigger-created launches now inherit
  startup timing only from the reviewed launch plan; focused runtime tests assert
  the supervisor sees the reviewed timeout, and SAAWTL static gates reject a
  trigger-payload timeout surface.
- Source-proved the bundle handoff and orchestration process-record cluster as
  retained primitive-engine surface. `worker_activation_bundle_vault.rs` is
  process-memory-only one-shot custody with safe metadata and no durable,
  filesystem, process, stream, or queue backing; orchestration contracts retain
  reviewed direct-exec launch validation; process resources persist redacted
  lifecycle/audit fields and fingerprints instead of tokens or stdin bytes; the
  supervisor uses direct `Command::new`, `env_clear`, optional piped stdin,
  byte-limited capture, bounded capture joins, and stop-timeout kill without
  shell, restart, retry, launchd, deploy, or scheduler ownership; and
  `worker_protocol.rs` remains DTO-only scoped hello/register binding.
- Tightened and source-proved the schedule state/tick cluster. The
  `worker_schedule_plan` schema now rejects arbitrary top-level fields while
  preserving declared optional metadata; schedule contracts retain reviewed UTC
  interval parsing, fixed policy literals, trigger/autostart/launch-plan
  binding, secret-looking value rejection, deterministic tick ids, hashed target
  keys, and redacted errors; the explicit runtime pages reviewed plans with a
  100 page size and 500 per-poll cap, observes caller-supplied cancellation,
  persists safe scan state, leases tick dispatch, and invokes only
  `trigger::dispatch` with enqueue delivery; overlap evidence is bounded by the
  scan cap and never starts workers; scan state stores only cursor, budget,
  wrap/cancel flags, aggregate summary, trace id, generic redacted error, and
  scanner metadata.
- Source-proved the transport-boundary cluster as retained primitive shell.
  `public_engine_transport_methods` remains discover, inspect, watch, invoke,
  and promote; `contracts.rs` registers only internal engine_ws triggers for
  those methods; `transport/engine/mod.rs` derives authority from contracts and
  strips transport-only context without accepting runtime metadata; the socket
  dispatcher has no launch, activation, or schedule branch; wire DTOs deny
  unknown fields including caller-supplied authority/runtime metadata; and
  `transport/runtime/mod.rs` starts queue draining plus external-worker
  heartbeat only. The new SAASTC static gate rejects provider imports, schedule
  resources, activation/launch function ids, schedule autostart, deploy,
  launchd/SMAppService, post-ready replay, and repo-skill surfaces in the
  retained transport files.
- Simplified and source-proved the durability resource substrate. Source search
  showed `list_types` had no callers in source, tests, README, or docs, so the
  in-memory and SQLite resource stores no longer expose that unused type-catalog
  listing API. Retained access remains `register_type`, create, update, link,
  inspect, list, and list_page through `ResourceStoreBackend`, while built-in
  resource types are loaded once from `builtin_resource_type_definitions`.
  Static SAASTC evidence now checks agent memory/rule schemas require
  provenance and evidence refs, worker activation/process/launch/schedule
  schemas are closed where they carry successor state, worker activation stores
  fingerprints and redacted token storage rather than scoped worker tokens,
  schedule scan state is bounded, resource validation runs schema validation
  before persistence, CAS/version/pagination types remain present, and resource
  store tests retain payload validation plus memory/SQLite pagination parity.

## Phase 2 Focused Commands

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::authority --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_activation --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml promotion_governance --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_promotion_governance_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_trigger_launch --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_trigger_launch_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_orchestration --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_bundle_handoff_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_orchestration_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_schedule_dispatch --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml worker_schedule --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_schedule_dispatch_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_schedule_capacity_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::transport --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml transport::engine --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml resource --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability::resource_contracts --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_successor_teardown_cleanup_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture
```

## Phase 1 Commands

```bash
git status --short --branch
git rev-parse --short=12 HEAD
git diff --name-status b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_successor_teardown_cleanup_invariants -- --nocapture
git diff --check
git status --short
```
