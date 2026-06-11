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
- Tightened the per-call capability runtime child grant from a broad
  four-invocation default into an operation-scoped shape. Direct model targets
  receive only their target capability and target authority scope with the
  normal two-invocation budget; `capability::execute` adds only the nested
  state/resource primitives required by the selected operation, and
  `resource_link` alone receives the four-invocation call graph budget for
  execute, source inspect, target inspect, and link.
- Renamed the activation bundle metadata host accessor from
  `worker_activation_bundle_metadata_for_test` to
  `worker_activation_bundle_metadata`; the accessor is safe metadata used by
  production launch preflight, not a test-only hook.
- Narrowed worker activation filesystem authority. Grant derivation now accepts
  an empty `fileRoots` list as explicit no-file-access authority, while all
  other grant axes still require non-empty values and canonical file-root
  narrowing remains intact. `worker::issue_activation` uses empty file roots
  instead of inheriting `/`, and authority tests prove path-bearing invocations
  fail before handler execution under that grant.
- Tightened promotion governance resource authority. System-scoped
  decision/evidence/candidate resources now require an admin-like actor before
  `engine::promote` can use them, so a workspace actor cannot borrow parent
  system governance refs to widen a session function.
- Removed the trigger-launch timeout override. `worker::launch_from_trigger`
  now accepts only reviewed autostart input plus optional launch reason; startup
  timing comes from the reviewed launch plan, not trigger dispatch payload.
- Source-proved the bundle handoff and orchestration process-record cluster as
  retained primitive-engine surface. The retained contract is the process-memory
  one-shot activation bundle vault, reviewed direct-exec launch contracts,
  redacted worker_process audit payloads, byte-limited direct-exec supervisor
  capture, and scoped hello/register protocol binding. This moves the cluster's
  cleanup inventory rows out of `simplify` but does not close broader SAASTC
  rows until every successor cluster receives the same teardown treatment and
  full closeout runs.
- Tightened and source-proved the schedule state/tick cluster. The retained
  contract is an explicit-only schedule runtime with no transport autostart
  poller, closed top-level `worker_schedule_plan` schema, safe
  `worker_schedule_tick` and `worker_schedule_scan_state` records, bounded
  100-page/500-per-poll scanning, cooperative cancellation, deterministic
  tick/idempotency fingerprints, active-overlap evidence, and enqueue-only
  `trigger::dispatch` composition. This reduces the schedule cluster's
  `simplify` rows without closing SAASTC rows outside the cluster.
- Source-proved the public transport boundary cluster as retained primitive
  shell. `/engine` transport still registers only discover, inspect, watch,
  invoke, and promote; the socket layer accepts only protocol framing,
  stream-subscription, heartbeat, and those public methods; wire DTOs reject
  undeclared authority/runtime metadata; and server runtime starts queue
  draining plus external-worker heartbeat only, with no worker launch, worker
  activation, schedule, provider, deploy, launchd, retry, or repo-skill public
  surface. This moves the transport-boundary rows out of `simplify` but leaves
  SAASTC rows pending until all successor clusters are audited.
- Simplified and source-proved the durability resource substrate. Removed the
  unused in-memory and SQLite `list_types` API, leaving registered resource
  type access owned by `builtin_resource_type_definitions` and the
  `PrimitiveStores` resource backend create/update/link/inspect/list/list_page
  contract. Retained definitions cover agent records, worker activation,
  worker process, trigger launch attempts, schedule records, schema payload
  validation, CAS/version state, deterministic pagination, and memory/SQLite
  parity tests without adding a public type-catalog or secret-bearing store
  API.
- Tightened and source-proved the provider/execute boundary. Capability worker
  registration still rejects any operation key except `execute`, the execute
  schema remains a direct primitive-operation payload without catalog target
  fields, execute operations require trusted agent/system context plus derived
  least-privilege grants, and the OpenAI converter now filters provider tool
  entries and instruction text through the retained `execute` primitive only.
  The updated provider regression passes `inspect` and `launch_activation`
  capabilities and proves only `execute` is serialized.
- Simplified and source-proved the invocation-host governance boundary. Removed
  the `EngineHostHandle::promote_function_visibility` shortcut that bypassed
  `engine::promote`; the only retained host promotion path now validates
  idempotency, actor authority, decision resources, verified evidence, and
  candidate chains before catalog visibility mutation. The one runtime test
  that needed a promoted target performs direct catalog setup under its local
  test host lock instead of preserving a runtime host API.
- Tightened and source-proved the primitive surface. The retained primitive
  contract is internal module wiring, host-dispatched catalog/worker/UI/storage
  dispatch, resource/state/queue/stream/grant/lease/compensation store adapters,
  built-in resource type installation, and worker activation governance. Worker
  activation now matches promotion governance by requiring admin-like actors for
  system-scoped decision/evidence/candidate resources, so an ordinary agent with
  `worker.activate` cannot borrow parent system governance refs to issue a
  session activation.
- Source-proved the external-worker runtime lifecycle cluster as retained
  bounded primitive runtime surface. `EngineExternalWorkerRuntime` owns only
  loopback bearer hello/register/heartbeat/disconnect protocol state, validates
  active scoped-token grants before connection acceptance, unregisters volatile
  catalog entries on disconnect or heartbeat timeout, marks durable entries
  unhealthy instead of replaying readiness, updates activation lifecycle through
  the existing resource CAS path, and does not own launch, schedule, deploy,
  provider, restart, retry, or post-ready replay behavior.
- Source-proved the engine catalog/module export cluster as retained primitive
  fabric. `engine/mod.rs` keeps `authority`, `catalog`, `durability`,
  `invocation`, `kernel`, `primitives`, and `runtime` as crate-private
  submodules behind a narrow facade; the catalog registry exposes only
  engine-scoped prepared-invocation and idempotency decisions plus `LiveCatalog`.
  Registry code owns canonical idempotency reservation/replay, activation bundle
  redaction before durable ledger writes, grant-backed prepared invocation,
  output-contract finish recording, durable external-worker hydration as
  stopped/unhealthy, owner/namespace registration checks, volatile cleanup, and
  trigger policy checks without provider, deploy, schedule, launch, restart,
  retry, or repo-skill ownership.
- Source-proved and tightened the final test-quality cluster. Engine catalog,
  durability, invocation, fixture, runtime, and activation tests are retained
  because they guard primitive catalog ownership/idempotency, resource
  schema/CAS/relation behavior, public/internal meta invocation trust, shared
  primitive fixtures, runtime suite wiring, and scoped activation lifecycle
  behavior. The SAA authorship invariant target remains retained only as
  primitive-surface/evidence-integrity coverage, and its support fixture now
  derives operation-scoped grants for `resource_create`, `resource_inspect`, and
  `resource_link`, failing closed for any other operation instead of preserving
  the previous broad resource/state fixture grant. This removes the last
  `simplify` classifications from the cleanup inventory, while SAASTC rows stay
  pending until the full focused and closeout verification suite passes.
