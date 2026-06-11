# Self-Adapting Agent Successor Teardown Cleanup Scorecard

Status: **source_teardown_in_progress**
Current score: **15/100**
Passing threshold: **100/100**

Branch: `codex/self-adapting-agent-successor-teardown-cleanup`
Baseline commit: `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7`
Integration head under audit: `9e8ccb1cf129ba8ef1dc14d9050e84da5ee7e3b3`

Invariant target:
`packages/agent/tests/self_adapting_agent_successor_teardown_cleanup_invariants.rs`.

This cleanup scorecard audits the successor self-adapting-agent work added after
the ODA baseline. The cleanup must reduce SAA authorship, promotion governance,
worker activation, orchestration, bundle handoff, trigger launch, schedule
dispatch, and schedule capacity to source-proven primitive-engine content only.
Rows not closed here remain pending source teardown; Phase 1 closes only the
harness and full initial diff inventory.

## Hard Boundaries

- Do not add provider-visible tools beyond the existing `execute` contract.
- Do not add public `/engine` surfaces for SAA worker launch, schedule, or
  activation.
- Do not reintroduce repo-managed first-party skills under `packages/agent/skills/`.
- Do not add production deploy, launchd/SMAppService, iOS settings,
  restart-loop, retry-loop, or post-ready payload-replay behavior.

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| SAASTC-0 | Harness and baseline | 5 | passed_after_fix | Clean worktree at start, correct branch/base/head recorded, cleanup scorecard/evidence/inventory/invariant target created and wired into README/local/GitHub gates. |
| SAASTC-1 | Full successor diff inventory | 10 | passed_after_fix | Every tracked file changed in `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD` has an initial classification, owner, action, and rationale in the cleanup inventory TSV. |
| SAASTC-2 | Primitive-contract retention | 10 | pending_source_teardown | Retained SAA/SAPG/SAAW behavior must map to explicit primitive-engine contracts, not product aspirations or future-slice placeholders. |
| SAASTC-3 | Dead-code and cruft removal | 12 | pending_source_teardown | Unused helpers, wrappers, duplicate docs, speculative fields, unreachable branches, excessive fixtures, and stale open-loop docs must be removed or reduced. |
| SAASTC-4 | Boundary preservation | 10 | pending_source_teardown | Static/source guards must prove no provider/public/deploy/iOS/launchd/repo-skill/restart/retry/payload-replay surface remains. |
| SAASTC-5 | Authority and governance simplification | 8 | pending_source_teardown | Promotion, activation, trigger, schedule, and worker authority paths must be minimal, parent-first where applicable, and fail closed without duplicate policy planes. |
| SAASTC-6 | Durable state/resource hygiene | 8 | pending_source_teardown | Retained resources, schedule scan state, activation/process/tick records, lifecycle state, and vault custody must store only necessary safe metadata and no secrets. |
| SAASTC-7 | Runtime lifecycle and concurrency hygiene | 8 | pending_source_teardown | Retained worker/scheduler/orchestration tasks must have bounded ownership, cancellation, idempotency, no unbounded production channels, and no hidden autonomous mutation loops. |
| SAASTC-8 | Test suite quality | 8 | pending_source_teardown | Focused tests must prove retained behavior with low fixture duplication; tests that only preserve removed cruft must be deleted or rewritten. |
| SAASTC-9 | Documentation/evidence integrity | 8 | pending_source_teardown | Scorecards, inventories, README, evidence manifests, and progressive-disclosure docs must be truthful after cleanup and reject stale wording. |
| SAASTC-10 | Cross-campaign regression | 6 | pending_source_teardown | Predecessor hardening invariants and retained SAA/SAPG/SAAW invariants must still pass. |
| SAASTC-11 | Closeout and adversarial audit | 7 | pending_source_teardown | Full verification, personal-info guard, XcodeGen drift check, ignored-files check, clean status, committed cleanup, and residual-risk note must be recorded. |

## Phase 1 Notes

- The cleanup inventory is intentionally conservative. `simplify` means source
  teardown must prove a minimal retained contract or remove the row's code/tests.
- `docs-only` means the file is evidence or README mapping, not a live runtime
  contract.
- `predecessor-bookkeeping` means an older hardening artifact changed because of
  successor work and must stay synchronized without preserving successor cruft.
- No source retention decision is final until SAASTC-2 through SAASTC-8 are
  closed by source inspection and focused verification.

## Source Teardown Log

- Removed `packages/agent/src/transport/runtime/worker_schedule.rs` and the
  `EngineRuntimeServices::start` schedule-poller task. The retained schedule
  runtime is explicit-only; future cadence ownership requires a successor
  scorecard.
- Split `packages/agent/src/engine/runtime/worker_schedule/tick_dispatch.rs`
  out of the schedule runtime facade so trigger enqueue and tick mutation stay
  owner-private while `worker_schedule/mod.rs` remains below the TPC hard file
  budget.
- Tightened `capability::execute` resource operations so provider-visible
  authorship remains inside the existing `execute` contract but can operate
  only on retained authorship resource kinds and only on current
  session/workspace resources. `resource_list` now requires an allowed kind,
  and inspect/update/link preflight resource scope and kind before mutation.
- Bounded the per-call capability runtime child grant at four invocations to
  cover the retained guarded `resource_link` call graph:
  `capability::execute`, source inspect, target inspect, and link.
- Renamed the activation bundle metadata host accessor from
  `worker_activation_bundle_metadata_for_test` to
  `worker_activation_bundle_metadata`; the accessor is safe metadata used by
  production launch preflight, not a test-only hook.
