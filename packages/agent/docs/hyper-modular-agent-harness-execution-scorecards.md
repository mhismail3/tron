# Hyper Modular Agent Harness Execution Scorecard Portfolio

Created: 2026-06-02

Initial score: **0/100**

Current score: **62.25/100**

Status: **running**

Scope:
- Fresh, source-backed implementation scorecard portfolio for reaching the
  north star: a hyper modular, plug-and-play Tron agent harness where the
  agent and the human use the same live substrate to install, author, test,
  inspect, operate, promote, roll back, and remove capabilities.
- Current-baseline audit across the Tron live engine fabric, capability
  `execute` harness, worker/module primitives, generated UI, iOS Engine
  Console, safety/ledger primitives, tests, README, and completed scorecards.
- Evidence contracts, row weights, static gates, stop-on-failure rules, and
  closeout criteria for the execution campaign.

Out of scope:
- Implementing these rows in this planning checkpoint.
- Treating iii as a runtime dependency or copying iii engine internals.
- Reopening completed cleanup, collapsed-engine, token-accounting, iPad, or
  post-scorecard hardening rows except as baseline evidence.

## Summary

The iii source material reframes an agent harness as installable, live,
inspectable worker composition rather than a framework import or bespoke
sidecar layer. The Tron end state is the same philosophy specialized for a
local-first agent: every harness job is a worker/function/trigger/resource/grant
participant in the engine substrate; the provider-facing model sees a tiny
`execute` primitive; the agent knows it can change the harness; iOS makes that
power intuitive for a human; and the ledger proves every mutation, approval,
retry, promotion, and rollback.

Canonical truth owner: the Rust server engine substrate. iOS is the native
human harness and projection surface. Provider prompts are instruction surfaces.
Neither may own executable routing, policy, approval truth, generated action
targets, module trust, or durable state.

## Source-Derived Requirements

The two pasted iii texts attached to the thread are the primary philosophy
source. They define the target shape this portfolio translates into Tron work:

- The substrate is not a bespoke architecture project. It is an installable,
  shared system surface. iii names the operation `iii worker add`; Tron needs
  the equivalent capability-native operation for local workers/modules.
- Three primitives flatten the graph: worker, trigger, function. State, queue,
  pubsub, stream, cron, HTTP, observability, sandbox, model routing,
  credentials, approvals, policy, hooks, sessions, budgets, skills, and turn
  orchestration are all workers on the same bus rather than integration edges.
- The decisive property is live discovery. A worker connects, registers
  functions/triggers, the catalog changes, and other participants see that new
  capability without restart, redeploy, or prompt schema rebuild.
- The agent and the human use the same operation to extend the same system. A
  human installs or swaps a worker; an agent can do the same under scoped
  authority, then discover, test, invoke, and explain it.
- The harness is a composition slider, not a thin-vs-thick fork. Adding policy,
  approvals, budget tracking, compaction, hooks, or Slack approval is adding or
  replacing workers that keep the same bus-level function ids.
- Same contract, both sides: platform workers and application workers register
  functions/triggers through the same protocol, so replacing a layer means
  registering the same public function ids, not rewriting neighbors.
- Skills and prompt assembly are also harness workers. Function guidance is
  fetched on demand from the live system, not frozen as a static prompt dump.
- Approval, policy, queue, and observability must fail closed and remain
  traceable. A missing policy worker denies; queued work records retries and
  DLQ; one trace crosses worker, state, queue, approval, and UI boundaries.

Public iii docs and repository pages checked on 2026-06-02 support the same
facts: functions/triggers/workers are the core primitives; discovery is a live
engine registry pushed to workers; trigger modes include sync, Void, and
Enqueue; queues provide retries/concurrency/FIFO/DLQ; the worker protocol is
WebSocket JSON; `iii worker add` incrementally adds local or registry workers;
and the iii engine license boundary differs from SDK/docs.

Official source URLs checked for this portfolio:

- https://iii.dev/docs/0-10-0/primitives-and-concepts/functions-triggers-workers
- https://iii.dev/docs/0-10-0/primitives-and-concepts/discovery
- https://iii.dev/docs/0-10-0/how-to/use-functions-and-triggers
- https://iii.dev/docs/0-10-0/how-to/trigger-actions
- https://iii.dev/docs/0-10-0/how-to/use-queues
- https://iii.dev/docs/0-10-0/advanced/protocol
- https://iii.dev/docs
- https://iii.dev/docs/quickstart
- https://iii.dev/docs/workers/managed-worker-lockfile
- https://github.com/iii-hq/iii

## Current Tron Baseline

Current evidence from this worktree:

- `packages/agent/docs/engine-redesign/README.md` already names the live
  capability fabric: canonical `namespace::function` functions, live catalog,
  engine ledger, streams, queues, state, approvals, scoped worker tokens, and
  session-scoped promotion.
- `packages/agent/docs/engine-redesign/iii-teardown.md` already maps iii's
  worker/function/trigger model to Tron-specific authority, idempotency,
  visibility, causality, and guardrail requirements.
- `packages/agent/src/engine/mod.rs` documents the server-owned engine fabric:
  live catalog, primitive workers, resource leases, compensation,
  generated-UI resources, local external workers, queue delivery, scoped
  worker tokens, and approval resume.
- `packages/agent/src/engine/primitives/worker.rs` exposes
  `worker::protocol_guide` with model-readable authoring guidance, and the
  sandbox domain exposes worker creation only as canonical `worker::spawn`.
- `packages/agent/src/domains/capability/mod.rs` keeps the provider surface
  small: `execute` owns discovery, target resolution, schema repair, freshness,
  approval, idempotency forwarding, child invocation, and model-visible
  correction guidance.
- `packages/agent/src/domains/capability/registry/primer.rs` already primes
  core capabilities including `worker::spawn`,
  `worker::protocol_guide`, and spawned-worker cleanup, but it has not yet been
  proven as a complete self-modification lifecycle in a provider-visible turn.
- `packages/agent/src/engine/primitives/module.rs` already models module
  package/config/activation/trust/conformance/health/rollback/quarantine as
  resource-backed canonical `module::*` functions and composes activation
  through `worker::spawn`.
- `packages/ios-app/docs/architecture.md` describes iOS as a thin `/engine`
  client with Engine Console, generated UI, module package/config/activation/
  trust/health/action projections, approvals, and server-owned action target
  reconstruction.
- Existing static gates reject many alternate planes: dotted public methods,
  client-owned generated targets, local approval truth, raw worker-token
  authority fallbacks, `sandbox::spawn_worker` as a public creation API, and
  stale scorecard states.

Baseline conclusion: Tron has most primitives. The unproven north-star loop is
recursive and action-time: a model in an ordinary turn must know it can modify
the harness, author or install a scoped worker/module, test it through the live
catalog, expose useful generated/native UI, promote or discard it through
governed capability calls, and leave evidence strong enough for both the human
and the agent to inspect later.

## Primitive And Plane Budget

Durable primitives to keep:

- **Worker:** live actor with namespace claims, visibility ceiling, authority
  grant, provenance, health, conformance, lifecycle, and cleanup semantics.
- **Function:** callable contract with schema, effect, risk, authority,
  idempotency, approval, leases, compensation, examples, primer metadata,
  provenance, selected implementation, and revision.
- **Trigger:** causal rule with actor, grant, target revision, catalog
  revision, delivery mode, idempotency, trace, parent invocation, retry/DLQ,
  and loop budget.
- **Resource:** typed durable object for module packages, generated UI,
  artifacts, evidence, decisions, goals, claims, materialized files, and
  harness docs.
- **Grant:** delegated authority with visibility, namespace, effect,
  invocation, trigger, file-root, resource-selector, promotion, and expiry
  ceilings.
- **Ledger:** explanation and replay surface for invocations, idempotency,
  catalog changes, approvals, queues, resources, leases, compensation, traces,
  and promotions.
- **iOS Projection:** native human harness over server truth, never a policy or
  target-reconstruction plane.

Planes to delete or prevent:

- Client-owned policy, approval, generated action target, module trust, or
  routing truth.
- Static prompt-expanded tool catalogs that pretend to be the live catalog.
- Hidden compatibility dispatch paths, dotted public method aliases, or
  handler-shaped transport shortcuts.
- Global visibility defaults for agent-created functions.
- Schema-only safety without authority, idempotency, risk, approval, leases,
  loop budgets, provenance, and conformance.
- Worker/module activation that bypasses `worker::spawn`, scoped worker tokens,
  resource evidence, or conformance.
- Generated UI that displays capabilities but cannot submit server-stored
  action coordinates back through canonical invocations.

## Operating Loop

1. Pick the highest-weight pending row in scorecard order, unless a prior row
   has failed.
2. Run the real path with isolated temp data, temp ports, and explicit session
   ids unless the row states it is a static gate.
3. Capture exact proof: command, exit code, server PID/port, session id,
   invocation ids, catalog revisions, resource refs, approval ids, queue
   receipts, trace ids, screenshot paths, and DB/log summaries as applicable.
4. If a failure appears, stop breadth testing.
5. Classify owner, add or identify the smallest covering test, fix the owning
   module, remove nearby dead/fallback/compat code, rerun the exact scenario,
   and update the row.
6. Keep README, progressive module docs, tests, scorecards, and ledger aligned
   at every coherent checkpoint.

## Master Scenario Ledger

| ID | Scorecard | Weight | Status | Owner | Evidence contract |
|----|-----------|--------|--------|-------|-------------------|
| HMH-A | Source, baseline, and primitive audit | 10 | passed | docs_or_scorecard | Attachment synthesis, official iii source check, current-code audit, README link, static gate. |
| HMH-B | Agent self-modifying capability lifecycle | 20 | passed | engine_capability_runtime | Live agent/harness scenario creates, registers, discovers, tests, invokes, promotes/discards, and cleans a session worker. |
| HMH-C | Harness knowledge and context compiler | 15 | passed | agent_runner_context | Provider-visible turn context and execute guidance teach the lifecycle without prompt bloat or guessed fields. |
| HMH-D | Plug-and-play module/package lifecycle | 15 | passed | module_trust_runtime | Module install/verify/approve/configure/activate/health/conformance/upgrade/rollback/quarantine/revoke works through canonical functions/resources. |
| HMH-E | Human harness and generated UI | 15 | pending | ios_generated_ui | iOS renders and operates server-owned capability/module/generated UI/evidence flows on iPhone and iPad without owning policy. |
| HMH-F | Causality, safety, loops, and rollback | 15 | pending | engine_policy_ledger | Idempotency, approval resume, leases, trigger budgets, queues/DLQ, compensation, and trace/ledger proof fail closed. |
| HMH-G | Final adversarial closeout and absence gates | 10 | pending | test_harness | Static scans, integration tests, transcript audit, docs/README/ledger, and score math prove no parallel planes remain. |

## HMH-A Scorecard: Source, Baseline, And Primitive Audit

Scope: lock the fresh baseline before implementation begins.

Out of scope: runtime feature changes beyond tests/docs needed to prove the
baseline.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-A1 | Attachment synthesis is first-class source | 20 | passed | Scorecard cites both pasted text paths or attachment hashes, names the agent/human same-operation thesis, harness-as-worker-stack thesis, live discovery thesis, and slider thesis. | Stop if the plan cites only public docs or stale prior summaries. |
| HMH-A2 | Public iii facts verified | 15 | passed | Official iii docs/GitHub links and retrieval date prove primitive, discovery, trigger action, queue, protocol, worker-add, and license facts used by the plan. | Remove or weaken any unverified external claim. |
| HMH-A3 | Current Tron substrate map is evidence-backed | 25 | passed | Current file references cover engine, capability execute, worker guide/spawn, module lifecycle, iOS Engine Console/generated UI, and absence gates. | Stop if a claimed primitive is doc-only or unreachable. |
| HMH-A4 | Primitive/plane budget accepted | 20 | passed | Explicit keep/delete budget in this file plus static gate against client policy, public dotted methods, prompt-expanded catalog, global session-worker visibility, and alternate spawn paths. | Add or tighten static gates before coding. |
| HMH-A5 | Prior scorecards treated as prerequisites only | 10 | passed | README and this file reference completed scorecards as baseline evidence, not as proof that the new recursive loop is done. | Correct status language before continuing. |
| HMH-A6 | Fresh execution portfolio linked and guarded | 10 | passed | README links this file, and `hyper_modular_architecture_plan_invariants` asserts required portfolio rows and no stale attachment-source error. | Add test before marking HMH-A passed. |

Closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hyper_modular_architecture_plan_invariants -- --nocapture
git diff --check
```

HMH-A closeout evidence, 2026-06-02:

- HMH-A1 passed because this file treats the two pasted text attachments as the
  primary source and captures the same-operation, harness-as-worker-stack, live
  discovery, and composition-slider theses in `Source-Derived Requirements`.
- HMH-A2 passed after rechecking official iii docs/repo pages on 2026-06-02 and
  recording the URLs above for primitives, discovery, function/trigger use,
  trigger modes, queues/DLQ, WebSocket protocol, `iii worker add`, and license
  boundary.
- HMH-A3 passed because `Current Tron Baseline` maps each claimed substrate
  feature to current files under `packages/agent/src/engine`,
  `packages/agent/src/domains/capability`, `packages/agent/src/domains/sandbox`,
  `packages/agent/src/engine/primitives/module.rs`, and
  `packages/ios-app/docs/architecture.md`.
- HMH-A4 passed because `Primitive And Plane Budget`, README,
  `packages/agent/src/domains/capability_support/implementations/primitive_surface.rs`,
  `packages/agent/src/domains/capability/contract.rs`, and
  `packages/agent/tests/threat_model_invariants.rs` jointly guard the server
  ownership boundary, canonical `worker::spawn`, generated UI action-target
  reconstruction, module escape hatches, public dotted methods,
  prompt-expanded tools, and session-worker visibility defaults.
- HMH-A5 passed because README links older completed scorecards only as living
  baseline evidence while this file says the recursive harness loop is still
  unproven until HMH-B through HMH-G pass.
- HMH-A6 passed because README links this execution portfolio and
  `packages/agent/tests/hyper_modular_architecture_plan_invariants.rs` guards
  the portfolio shape, HMH-A pass state, source links, score, and stale
  attachment-source regression.

Open loops after HMH-A:

- HMH-A only proves the baseline and gates. It does not prove the recursive live
  agent turn; HMH-B remains the next active implementation lane.
- HMH-B should start with the smallest live-loop prerequisite:
  `execute -> worker::protocol_guide`, then advance to scoped `worker::spawn`
  only after the guide result is proven sufficient.
- Process note: avoid parallel Cargo test invocations in this repo during
  scorecard closeout; the run hit package-cache/artifact locks and the
  sequential rerun was cleaner. Run `cargo fmt` before `--check` after editing
  Rust tests to save one failed check.

## HMH-B Scorecard: Agent Self-Modifying Capability Lifecycle

Scope: prove the core recursive loop from an ordinary agent turn.

Out of scope: remote worker hosting or unscoped global package installation.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-B1 | Model is taught the lifecycle | 10 | passed_after_fix | Provider-visible transcript or deterministic runner fixture shows the model names discovery, `worker::protocol_guide`, worker authoring, `worker::spawn`, catalog watch/inspect, conformance/test, `execute`, promotion/disconnect, and evidence. | Stop if lifecycle appears only in hidden docs or test code. |
| HMH-B2 | Worker guide is sufficient | 10 | passed_after_fix | `execute` can call `worker::protocol_guide`; returned template/protocol/env/rules let the agent write a worker without source-searching or probing HTTP paths. | Fix guide/primer before testing spawn. |
| HMH-B3 | Session worker creation is scoped | 15 | passed | Live temp worker registers one harmless function under a session namespace through `worker::spawn`; result includes derived grant, expected ids, process id, visibility, and catalog revision. | Stop if default visibility is not session or grant exceeds parent. |
| HMH-B4 | Live catalog update and inspection work | 10 | passed | Catalog watch or revision delta shows the new function; `execute` discovery/inspect returns schema, health, provenance, trust tier, conformance state, authority, and visibility. | Fix registry/inspection before invocation. |
| HMH-B5 | Conformance/test evidence is resource-backed | 10 | passed_after_fix | `module::run_conformance` or capability conformance records pass/fail evidence resources linked to worker/function ids. | Do not promote without evidence resource refs. |
| HMH-B6 | Invocation uses the tiny harness | 15 | passed | Provider-visible `execute` invokes the new function; child invocation id, trace id, idempotency key, grant id, target revision, result, and ledger row are inspectable. | Stop if the provider receives a direct worker tool or hidden transport path. |
| HMH-B7 | Promotion is governed | 10 | passed_after_fix | Workspace/system promotion requires expected revision, explicit idempotency, authority, approval if needed, and catalog-change evidence. | Stop if promotion is implicit, global by default, or client-owned. |
| HMH-B8 | Cleanup and stale calls fail closed | 10 | passed | Disconnect/stop unregisters volatile functions or marks durable workers unhealthy; stale invocation fails closed; no UI cache can keep it callable. | Fix cleanup before broader module work. |
| HMH-B9 | Agent explains the evidence | 10 | passed | Agent answer cites live capability ids, resource refs, trace/ledger ids, and next maintenance actions; no stale README-only explanation. | Fix context/evidence projection if explanation is vague. |

Closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test integration e2e_local_process_module_activation_health_and_disable_use_real_worker_spawn -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle -- --nocapture
```

HMH-B1 evidence, 2026-06-02:

- Initial deterministic provider-visible checks failed:
  `primer_teaches_self_modifying_worker_lifecycle` showed the generated
  `capabilities.primer` only taught generic execute usage, and
  `execute_description_teaches_self_modifying_worker_lifecycle` showed the
  exported execute schema did not mention `worker::protocol_guide`.
- The fix keeps guidance in the existing model-facing surfaces instead of
  adding a second harness plane. `packages/agent/src/domains/capability/registry/primer.rs`
  now renders a compact "customize the harness" sequence covering
  `worker::protocol_guide`, worker authoring, `worker::spawn`, session
  visibility, catalog watch/inspect, conformance/test evidence, invoking the
  new function through `execute`, governed `engine::promote`, cleanup through
  `worker::disconnect`/sandbox stop, and trace/resource/catalog evidence.
- `packages/agent/src/domains/capability/contract.rs` now teaches the same loop
  in the provider-visible `execute` tool description, so HMH-B1 does not depend
  on README-only instructions.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml primer_teaches_self_modifying_worker_lifecycle -- --nocapture`
  and
  `cargo test --manifest-path packages/agent/Cargo.toml execute_description_teaches_self_modifying_worker_lifecycle -- --nocapture`.

HMH-B2 evidence, 2026-06-02:

- Initial live WebSocket proof failed in
  `capability_self_modifying_lifecycle_execute_returns_worker_protocol_guide`
  because public `invoke -> capability::execute` preserved `ActorKind::Client`.
  `worker::protocol_guide` is Agent-visible, so execute returned
  `needs_capability` despite direct system invocation working.
- The root fix is in `packages/agent/src/transport/engine.rs`: ordinary public
  `invoke` remains a client actor, but public `capability::execute` dispatches
  as the profile-backed agent actor while server-owned execution policy scopes
  and metadata are still derived from the active profile.
- A second red run resolved the guide but rejected `sessionId` as an extra
  target argument. `execute` now treats root `sessionId`, `workspaceId`,
  `traceId`, `parentInvocationId`, and `authorityScopes` as wrapper/context
  fields so transport context cannot leak into target payload validation.
- `worker::protocol_guide` now returns a session-complete
  `spawnWorkerPayloadExample`: the default `visibility` is `session`, the
  active `sessionId` is included when present, and `workspaceId` is included
  when the guide was invoked with workspace context.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_execute_returns_worker_protocol_guide -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml capability_execute_invoke_uses_agent_actor -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml orchestrated_execute_keeps_transport_context_out_of_target_arguments -- --nocapture`,
  and
  `cargo test --manifest-path packages/agent/Cargo.toml worker_protocol_guide -- --nocapture`.

HMH-B3 evidence, 2026-06-02:

- Passing live proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_spawns_session_worker -- --nocapture`.
- The proof uses public `/engine` WebSocket `capability::execute`, first
  targeting `worker::protocol_guide` to obtain the generated Python worker
  template and session-scoped spawn example, then materializing that template
  into a temp worker script.
- The same public `execute` path targets `worker::spawn` with
  `visibility=session`, active `sessionId`, `expectedFunctionIds`, explicit
  top-level `idempotencyKey`, and narrowed child-grant bounds:
  one namespace read scope, one evidence resource kind, one session resource
  selector, the temp file root, loopback network, low risk, delegation=false,
  and approval=false.
- The spawn result includes the worker id, `visibility=session`, expected
  registered function id, derived `authorityGrantId`, grant revision, numeric
  process id, positive catalog revision, complete loopback
  `/engine/workers` endpoint, and `sandbox.lifecycle` stream topic.
- `grant::inspect` confirms the derived grant has an active delegable parent
  and exact child bounds for capability, namespace, authority scope, resource
  kind, resource selector, file root, loopback network, low risk,
  delegation=false, and approval=false. Cleanup stops the spawned process
  through `sandbox::stop_spawned_worker`.

HMH-B4 evidence, 2026-06-02:

- Passing live proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_inspects_session_worker_catalog -- --nocapture`.
- The proof reuses the public `/engine` `capability::execute` guide/spawn flow,
  records the catalog revision before spawn, and proves `worker::spawn`
  advances the live catalog revision for a session-visible worker.
- A public `execute` call targeting `catalog::watch_snapshot` with the same
  session context, owner-worker filter, availability class, and
  `function_registered` kind returns the new function registration change with
  subject id, owner worker, session visibility, session id, and revision.
- The same watch response's snapshot contains the new function definition with
  request and response schemas, `Healthy` health, `Session` visibility,
  session provenance, `session_generated` trust tier, and healthy conformance
  metadata.
- A public `execute` call targeting `capability::inspect` for the new function
  returns the capability inspection record with input/output schemas,
  effect/risk, implementation health, session visibility, provenance, trust
  tier, healthy conformance state, engine-issued signature status, empty
  authority scope requirements, binding decision, and execution requirements.

HMH-B5 evidence, 2026-06-02:

- Initial live proof failed in
  `capability_self_modifying_lifecycle_records_session_worker_conformance_evidence`
  because `capability::conformance_run` returned healthy checks for the
  session-generated plugin but no top-level `resourceRefs`.
- The fix keeps conformance truth in the existing capability/resource substrate:
  `capability::conformance_run` now creates an `evidence` resource before
  returning, declares a resource-backed `evidence` output contract, and returns
  the created evidence plus `resourceRefs`.
- The evidence payload records `source=capability::conformance_run`, status,
  checked implementation ids, function ids, worker ids, parent invocation id,
  trace id, and session id, so the pass/fail record is linked to the spawned
  session worker and function instead of being a registry-only state flip.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_records_session_worker_conformance_evidence -- --nocapture`.

HMH-B6 evidence, 2026-06-02:

- Initial live proof in
  `capability_self_modifying_lifecycle_invokes_session_worker_through_execute`
  exposed the expected public RPC trace shape: `/engine` records an
  `engine::invoke` envelope above the `capability::execute` parent and the
  generated session worker child, rather than hiding the call behind a direct
  worker tool.
- The passing proof invokes `hmh_b_invoke::echo` through public
  `capability::execute`, returns the worker echo output, records the selected
  session-generated implementation, catalog revision, function revision,
  execute invocation id, child invocation id, and trace id.
- `observability::trace_get` with full payloads shows exactly three functions
  in the trace: `engine::invoke`, `capability::execute`, and the generated
  worker function. The generated worker child records its parent invocation,
  session id, idempotency key, authority grant id, catalog/function revisions,
  success result, and worker id.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_invokes_session_worker_through_execute -- --nocapture`.

HMH-B7 evidence, 2026-06-02:

- Initial live proof in
  `capability_self_modifying_lifecycle_governs_session_worker_promotion`
  found two promotion evidence gaps. First, stale
  `expectedFunctionRevision` rejection was correct in the engine but collapsed
  to `INTERNAL_ERROR` at the public transport boundary. Second, public promote
  recorded duplicate `engine.promote.workspace` authority scopes.
- The fixes keep ownership in the existing engine substrate:
  `engine_error_to_capability_error` now maps stale function revision, engine
  owner mismatch, and invalid visibility promotion to typed public errors with
  structured details, and `transport::engine` dedupes authority scopes while
  building public transport causal context.
- The passing live proof spawns a session-generated worker, proves missing
  public `promote.idempotencyKey` is rejected, proves stale
  `expectedFunctionRevision` returns `STALE_FUNCTION_REVISION`, promotes the
  function to workspace visibility with explicit idempotency and workspace
  context, and verifies duplicate promote calls replay the original result.
- `catalog::watch_snapshot` then exposes the ledger-backed
  `visibility_changed` catalog change and the promoted workspace-visible
  function revision/provenance. `observability::trace_get` shows
  `engine::promote` ran through `engine_ws:promote` as a user action with the
  explicit idempotency key, session/workspace scope, clean authority scopes,
  successful result, and the promotion trace id.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_governs_session_worker_promotion -- --nocapture`.

HMH-B8 evidence, 2026-06-02:

- Passing live proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_cleans_up_session_worker_and_stale_calls_fail_closed -- --nocapture`.
- The proof reuses the public `/engine` `capability::execute`
  guide/spawn flow, invokes the generated session worker once before cleanup,
  and confirms the worker output, selected function id, and worker id are live
  before any stop path runs.
- `sandbox::stop_spawned_worker` then stops the spawned process, returns the
  stopped worker record, preserves the registered function ids, publishes
  `streamTopic=sandbox.lifecycle`, and advances the catalog revision past the
  spawn revision. `sandbox::get_spawned_worker` confirms the local lifecycle
  store keeps the process record as `status=stopped`.
- A public `execute` call targeting `catalog::watch_snapshot` after the spawn
  revision returns both the `function_unregistered` change for the session
  generated function and the `worker_unregistered` change for the volatile
  worker. The same snapshot no longer contains the stopped function or worker.
- A stale public `invoke -> capability::execute` against the stopped function
  returns structured `needs_capability` guidance with
  `childInvocationCreated=false`, `approvalCreated=false`, empty
  `resourceRefs`, and no worker output. `observability::trace_get` for that
  stale trace shows only `engine::invoke` and `capability::execute`; no child
  invocation routes to the stopped worker id or function.
- Durable disconnect behavior remains covered by the existing engine-unit
  policy for external workers: durable disconnected workers stay in the catalog
  as unhealthy and invocation is not routable, while the live B8 proof covers
  volatile session workers unregistering and stale calls failing closed. The
  supporting durable policy proof is:
  `cargo test --manifest-path packages/agent/Cargo.toml local_external_worker_durable_disconnect_marks_functions_unhealthy -- --nocapture`.

HMH-B9 evidence, 2026-06-02:

- Passing live proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_self_modifying_lifecycle_explains_session_worker_evidence -- --nocapture`.
- The proof creates a real agent session, spawns a session-generated worker
  through public `capability::execute`, inspects the spawned function, runs
  `capability::conformance_run`, and inspects the resulting `evidence`
  resource before the agent answer is allowed to complete.
- A deterministic provider first emits a model `execute` invocation targeting
  `resource::inspect` for the live evidence resource. On the second provider
  turn, it parses the model-visible execute result from context and asserts the
  payload includes the current function id, worker id, plugin id,
  implementation id, evidence resource id/version id, trace id, parent
  invocation id, and session id.
- The final answer cites the live function, worker, plugin, implementation,
  `resourceRefs`, trace/parent invocation ids, `executeInvocationId`,
  `childInvocationIds`, governed promotion with `expectedFunctionRevision`,
  explicit idempotency, and cleanup through `sandbox::stop_spawned_worker` or
  `worker::disconnect`. Streamed `agent.text_delta` and
  `session::get_history` both preserve the live evidence markers, and the
  final answer contains no README-only explanation.

Open loops after HMH-B1/HMH-B2/HMH-B3/HMH-B4/HMH-B5/HMH-B6/HMH-B7/HMH-B8/HMH-B9:

- HMH-B is closed. It proves model-visible instruction, guide sufficiency,
  scoped session worker creation, live catalog/inspection, resource-backed
  conformance evidence, invocation through the tiny harness, governed
  promotion, cleanup/stale-call fail-closed behavior, and live evidence
  explanation in one coherent lifecycle lane.
- Continue with HMH-C to prove the context compiler keeps this knowledge
  bounded, current, and provider-visible without expanding the public prompt
  surface beyond `execute`.
- Process note: Cargo accepts one test-name filter per invocation; run multiple
  focused filters sequentially.

## HMH-C Scorecard: Harness Knowledge And Context Compiler

Scope: make the agent know and use the modifiable harness at action time.

Out of scope: dumping the full catalog into prompts.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-C1 | Primer contains the north-star recipe | 20 | passed_after_fix | `capabilities.primer` includes a compact "customize the harness" sequence with `worker::protocol_guide`, `worker::spawn`, inspection, conformance/test, generated UI, promotion, and cleanup. | Stop if the model must infer the loop from unrelated recipes. |
| HMH-C2 | Context budget remains bounded | 15 | passed_after_fix | Snapshot fixture records primer token estimate under profile budget while preserving core worker/module/generated-UI recipes. | Split recipe docs into resources if budget exceeds policy. |
| HMH-C3 | Execute correction covers lifecycle errors | 20 | passed_after_fix | Missing `expectedFunctionIds`, missing `sessionId`, stale revision, target trigger id, missing idempotency, ambiguous target, and approval-required states return actionable repair guidance. | Fix result presentation before model-run proof. |
| HMH-C4 | Harness docs are resources | 15 | passed_after_fix | Agent-readable harness guide/recipes are versioned resources or capability-backed docs tied to catalog revision, not only repo prose. | Add resource/doc projection before closeout. |
| HMH-C5 | Model-run proof across providers | 20 | passed_after_fix | At least one high-capability hosted model and one alternate provider/local path answer "how can you customize your harness?" with current live capabilities and safety gates. | Classify provider-quality failures only after substrate proof. |
| HMH-C6 | Prompt surface stays tiny | 10 | passed_after_fix | Provider schemas expose only `execute`; `search`/`inspect`/admin functions stay operator/internal unless intentionally invoked through execute discovery. | Static gate or provider test must fail if prompt-expanded tools return. |

Closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml capability_primer -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml execute_guidance -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml harness_docs_are_versioned_resources -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml model_run_proves_harness_customization_across_providers -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml provider_prompt_surface_stays_tiny -- --nocapture
```

HMH-C1 evidence, 2026-06-02:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml primer_teaches_self_modifying_worker_lifecycle -- --nocapture`
  initially failed after the C1 test was strengthened to require generated
  `ui_surface` guidance, `ui::surface_for_target`, `ui::inspect_surface`,
  `ui::submit_action`, and stored surface/version/action ids.
- The fix keeps the recipe in the fixed `capabilities.primer` header under
  `packages/agent/src/domains/capability/registry/primer.rs`, so it survives
  compact entry truncation and does not depend on README-only prose.
- The compact recipe now teaches the same `execute` primitive for
  `worker::protocol_guide`, worker authoring, `worker::spawn`, live catalog
  proof, `capability::inspect`, conformance/test evidence, invocation,
  generated `ui_surface` handoff, governed `engine::promote`, cleanup through
  `worker::disconnect` or `sandbox::stop_spawned_worker`, and evidence markers
  including trace id, resource refs, catalog revision, child invocation ids,
  and cleanup state.
- README's worker-protocol section now matches the primer by documenting that
  human/operator controls are server-owned generated UI surfaces and that iOS
  submits stored surface/version/action ids instead of reconstructing targets.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml primer_teaches_self_modifying_worker_lifecycle -- --nocapture`.

Open loops after HMH-C1:

- HMH-C1 proves the compact recipe content only. Continue with HMH-C2 to prove
  the context compiler keeps that recipe inside budget while preserving core
  worker, module, and generated-UI guidance in a provider-visible snapshot.

HMH-C2 evidence, 2026-06-02:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_primer_context_stays_within_budget -- --nocapture`
  initially failed with a `2633` estimated-token primer against the default
  profile `2600` token budget. The noisy snapshot exposed that
  `render_capability_primer` checked the candidate entry before appending the
  truncation notice, so the notice itself could push the provider-visible
  primer over budget.
- The same fixture requires the bounded primer to preserve worker,
  module/package, and generated-UI recipe markers while rendering a noisy core
  catalog. It checks catalog revision, the approximate token estimate, explicit
  truncation through the same `execute` primitive, `worker::protocol_guide`,
  `worker::spawn`, catalog/inspection proof, conformance/test evidence,
  `module::register_package`, `worker_package`, source trust,
  `module::activate`, `module::run_conformance`, generated `ui_surface`,
  `ui::surface_for_target`, `ui::inspect_surface`, `ui::submit_action`, stored
  surface/version/action ids, governed `engine::promote`, cleanup, trace ids,
  resource refs, catalog revision, child invocation ids, and cleanup state.
- The fix reserves `TRUNCATION_NOTICE` before adding another rendered catalog
  entry and skips the entry if the line plus notice would exceed the active
  policy. The fixed header now also carries the compact module/package recipe,
  so module guidance is preserved even when entries are truncated.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml capability_primer_context_stays_within_budget -- --nocapture`.

HMH-C3 evidence, 2026-06-02:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml execute_guidance_covers_self_modifying_lifecycle_errors -- --nocapture`
  initially failed with the stale-revision case exposing `guidance.kind=null`
  instead of `refresh_capability_revision` in the model-visible terminal
  execute details.
- The strengthened proof covers the lifecycle repair set needed for
  self-modifying harness work: missing `worker::spawn.expectedFunctionIds`,
  missing `sessionId`, stale capability revision, trigger id used as a target,
  missing top-level `idempotencyKey`, ambiguous target selection, and
  approval-required state with an approval id.
- The fix keeps ownership split by phase: `operations/run.rs` now returns a
  stable `provide_idempotency_key` guidance object for idempotency preflight;
  `operations/execute/result.rs` synthesizes structured `select_target`,
  `refresh_capability_revision`, `refresh_capability_schema`, and
  `refresh_inspection_handle` guidance for terminal orchestration details; and
  bare approval-required results carry their `approvalId` through normalized
  `approvalDecision`.
- README and `domains/capability/mod.rs` now document that execute repair
  guidance covers stale guards, trigger target repairs, missing fields,
  idempotency, ambiguity, and approval ids.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml execute_guidance_covers_self_modifying_lifecycle_errors -- --nocapture`.

HMH-C4 evidence, 2026-06-02:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml harness_docs_are_versioned_resources -- --nocapture`
  initially failed because the rendered primer contained only prompt text: it
  had no `Harness docs resource:` pointer, no `harness_doc` resource id/version
  marker, and no resource payload inspectable through `resource::inspect`.
- The fix registers `harness_doc` as a built-in resource kind owned by the
  resource worker. The async capability-primer path now renders the bounded
  guide from the live catalog snapshot, materializes that exact body as a
  session-scoped versioned `harness_doc` resource keyed by primer policy,
  catalog revision, and content hash, then appends a compact resource id/version
  pointer with `inspectTarget=resource::inspect`.
- The passing proof inspects the created resource and verifies
  `kind=harness_doc`, the current `versionId`, `docId=capability-primer`,
  matching catalog revision, primer policy, session/workspace metadata, and the
  full harness-customization guide body with `worker::spawn` lifecycle text.
- README and progressive resource/capability docs now document that harness
  primer docs are versioned substrate resources, not README-only or
  prompt-only prose.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml harness_docs_are_versioned_resources -- --nocapture`.

HMH-C5 evidence, 2026-06-02:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml model_run_proves_harness_customization_across_providers -- --nocapture`
  initially returned a false green with zero matching tests. After adding a
  provider-run proof, the first run failed because the isolated in-memory
  harness did not seed the capability-domain `execute` contract, so provider
  doubles saw no model-facing capability primitive.
- The proof now drives `TronAgent::run` through two provider doubles:
  `Provider::OpenAi` as the hosted high-capability path and `Provider::Ollama`
  as the alternate/local path. Each double asserts against its actual
  provider-visible `Context`, not renderer internals.
- Both provider paths must see exactly one model-facing primitive,
  `execute`; a bounded `capabilities.primer` containing the harness
  customization recipe; a compact `harness_doc` resource id/version pointer
  with `inspectTarget=resource::inspect`; and no prompt-expanded
  `search`/`inspect`/admin capability surface. The local path additionally
  proves memory, skill index, and job result blocks are stripped by profile
  policy while the primer and `execute` remain visible.
- The generated answer must explain the live harness sequence: inspect the
  versioned `harness_doc`, run `worker::protocol_guide`, author and
  `worker::spawn` the worker, inspect the catalog, collect conformance/test
  evidence, expose generated `ui_surface` controls, use `engine::promote` only
  after evidence passes, and clean up with `worker::disconnect` or
  `sandbox::stop_spawned_worker`.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml model_run_proves_harness_customization_across_providers -- --nocapture`.

HMH-C6 evidence, 2026-06-02:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml provider_prompt_surface_stays_tiny -- --nocapture`
  initially returned a false green with zero matching tests. After adding the
  prompt-surface proof, the first real run failed because a rogue registered
  function could set `capabilityPrimitive=true` and `modelPrimitiveName=execute`
  with a lower sort order, causing the provider surface to bind model-visible
  `execute` to `rogue::execute` instead of the canonical orchestrator.
- The fix pins model-facing capability primitives to the canonical
  `capability::execute` function id before reading model primitive metadata, so
  arbitrary worker metadata cannot prompt-expand or replace the tiny provider
  surface.
- The passing proof seeds the normal capability-domain contracts plus a rogue
  worker and resolves provider schemas for both `Provider::OpenAi` and
  `Provider::Ollama`. Each path must expose exactly one schema named `execute`,
  bind it to `capability::execute`, and exclude the rogue schema text.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml provider_prompt_surface_stays_tiny -- --nocapture`.

Open loops after HMH-C1/HMH-C2/HMH-C3/HMH-C4/HMH-C5/HMH-C6:

- HMH-C is closed: compact lifecycle knowledge, bounded context, repair
  guidance, versioned resource-backed harness docs, provider-visible
  hosted/local model-run answers, and the tiny provider prompt surface are now
  proven. HMH-D and HMH-E1 are also closed; continue with HMH-E2 to prove
  generated UI for a new capability.

## HMH-D Scorecard: Plug-And-Play Module/Package Lifecycle

Scope: turn harness composition into local-first module operations.

Out of scope: remote marketplace trust without explicit local policy.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-D1 | Package registration is resource-backed | 10 | passed | `module::register_package` writes worker-package resources with declared capabilities, expected ids, digest, provenance, runtime entry point, and no raw secrets. | Stop if package truth lands in an unowned side table. |
| HMH-D2 | Source trust is explicit and revocable | 15 | passed | Register/verify/approve/revoke/expire/rotate/reconcile trust flows create decision/evidence resources and enforce trust ceilings before activation. | Stop if activation can bypass source trust. |
| HMH-D3 | Activation composes worker spawn | 15 | passed | `module::activate` invokes child `worker::spawn` outside host locks with narrowed grant, file roots, expected ids, scoped token, and activation lineage. | Stop if module runtime owns a parallel process launcher. |
| HMH-D4 | Health, integrity, and conformance are inspectable | 15 | passed | `check_health`, `verify_integrity`, and `run_conformance` produce linked evidence, child invocation ids, and recovery recommendations. | Block promotion if evidence is missing/stale. |
| HMH-D5 | Upgrade, rollback, disable, quarantine work | 15 | passed | Upgrade and rollback require expected versions and idempotency; disable/quarantine stop workers or fail closed; stale invocations cannot use quarantined functions. | Stop if rollback is doc-only. |
| HMH-D6 | Local marketplace shape exists | 10 | passed | Installing a first-party/local package is a capability operation over local package resources; remote source approval is explicit and policy-bound. | Reject implicit network trust. |
| HMH-D7 | iOS/operator projection is complete | 10 | passed_after_fix | Engine Console shows package/config/activation/trust/conformance actions and evidence without hardcoded package policy. | Fix iOS projection only after server truth is proven. |
| HMH-D8 | No generic action escape hatch | 10 | passed_after_fix | Static scan rejects `module::act`, generic package mutation multiplexers, and client-side module policy. | Remove escape hatches before closeout. |

Closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test integration e2e_local_process_module_activation_health_and_disable_use_real_worker_spawn -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml module_activation module_trust module_conformance -- --nocapture
```

HMH-D1 evidence, 2026-06-02:

- The existing D1 command was real but too narrow before this checkpoint: it
  validated digest, namespace, and idempotent declared contracts, but did not
  inspect the persisted `worker_package` resource payload.
- The strengthened proof registers an existing-worker package and a
  local-process package, then inspects
  `worker-package:demo-local-resource-backed` through `resource::inspect`.
  The current resource version must be kind `worker_package`, owned by the
  `module` worker, lifecycle `available`, and must carry the normalized
  manifest payload rather than an invocation echo.
- The inspected payload proves declared capabilities, `requiredGrants`
  expected function ids, `packageDigest`, `sourceDigest`,
  `sourceProvenance`, normalized `sourceRef`, `sourceTrustStatus`,
  `effectiveTrustTier`, `signatureVerification`, empty source approval,
  source evidence, and conformance refs, plus the local-process
  `runtimeEntryPoint` worker id, command/executable resource refs,
  `expectedFunctionIds`, and empty environment policy.
- The same test rejects a digest-correct adversarial local-process manifest
  containing raw `apiKey: sk-test-secret` runtime material before persistence.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml module_register_package_validates_digest_namespace_and_contracts -- --nocapture`.

HMH-D2 evidence, 2026-06-02:

- Production ownership is in
  `packages/agent/src/engine/primitives/module/source_trust.rs` and its
  focused `approval`, `verification`, `registration`, `policy`, and
  `lifecycle` submodules. `module::activate` calls
  `ensure_activation_source_policy` in
  `packages/agent/src/engine/primitives/module/activation_lifecycle.rs` before
  spawning, so activation cannot bypass source trust.
- The strengthened proof adds
  `module_source_approval_ceiling_denies_overbroad_activation_before_spawn`.
  It verifies a local package, creates a `module_source_approval` decision with
  a narrow grant ceiling, proves a matching narrow policy decision is allowed,
  then asks `module::activate` for broader capability/authority/risk. The call
  fails with a source-approval ceiling violation and records zero
  `worker::spawn` calls.
- The full source-trust suite covers activation denial before verification and
  approval, local source verification evidence, source approval decisions,
  approval revocation evidence and warnings, signed trust-root registration and
  signature verification, trust-root revocation, policy audit evidence, trust
  reconciliation with affected package/activation refs, trust-root renewal,
  trust decision expiry, signature-key rotation links, explicit revocation
  enforcement, bad signatures/unknown keys, and adversarial manifests without
  persistence.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml module_activation::source_trust -- --nocapture`.

HMH-D3 evidence, 2026-06-02:

- The strengthened unit proof is
  `module_activate_local_process_invokes_worker_spawn_and_records_integrity`.
  It drives `module::activate` through the recording `worker::spawn` handler,
  which calls back into the engine to register the worker/functions and derive
  the grant while activation is awaiting the child invocation. That passing
  callback path proves activation is not holding a host lock that deadlocks
  child engine work.
- The same proof now asserts the exact `worker::spawn` payload:
  activation-derived grant id, expected function ids, narrowed authority
  scopes, resource kinds, selectors, file roots, network policy, risk,
  session visibility, session id, and workspace id.
- It inspects the derived grant and verifies parent grant lineage, subject
  worker, subject spawn invocation, allowed capabilities/namespaces/authority
  scopes/resource kinds/selectors/file roots/network/risk, then inspects the
  `activation_record` resource to verify current version, `spawnInvocationId`,
  incoming `activates` package link, and outgoing `configured_by` config link.
- The real integration proof
  `e2e_local_process_module_activation_health_and_disable_use_real_worker_spawn`
  passed through the actual local-process `worker::spawn` path, including the
  scoped worker-token/protocol worker wiring needed for the spawned worker to
  register and respond.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml module_activate_local_process_invokes_worker_spawn_and_records_integrity -- --nocapture`.
- Passing integration proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test integration e2e_local_process_module_activation_health_and_disable_use_real_worker_spawn -- --nocapture`.

HMH-D4 evidence, 2026-06-02:

- Production ownership is in
  `packages/agent/src/engine/primitives/module/health_integrity.rs`, which owns
  `module::check_health`, `module::verify_integrity`,
  `module::run_conformance`, health scheduling, and activation recovery.
- The strengthened health proof asserts an `invoke_function` health policy
  records the child invocation id in `healthResult`, the activation payload,
  and the linked evidence resource payload.
- The new
  `module_run_conformance_links_evidence_and_updates_package_policy` proof
  runs `module::run_conformance` in activation mode with a child grant
  simulation request, inspects the linked evidence resource, and verifies the
  updated `worker_package` payload records `conformanceEvidenceRefs` and
  `policyDiagnostics.conformance.evidenceRef`.
- The existing integrity and recovery tests prove `module::verify_integrity`
  writes evidence, rejects stale activation versions, updates activation
  diagnostics, and that `module::recover_activation` records cleanup evidence,
  quarantines unsafe activations, surfaces manual recovery when spawned-worker
  stop fails, and exposes `module::recover_activation` as the recommended
  canonical action through package diagnostics.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml module_activation::health_integrity -- --nocapture`.

HMH-D5 evidence, 2026-06-02:

- Production ownership remains in
  `packages/agent/src/engine/primitives/module/activation_lifecycle.rs`,
  with request shape in
  `packages/agent/src/engine/primitives/module/schemas.rs`.
- `module::upgrade` and `module::rollback` schemas now require
  `expectedCurrentVersionId`, and the lifecycle handler checks the activation
  record's current version before deriving grants, spawning local-process
  workers, revoking old grants, or stopping workers.
- `module::rollback` now uses the same replacement-source cleanup path as
  `module::upgrade`: it supersedes the current activation version, revokes the
  replaced activation grant, records `supersedes`, and disconnects/stops the
  replaced worker when the worker id changes.
- Replacement local-process upgrades and rollbacks now stop the superseded
  spawned worker through `sandbox::stop_spawned_worker` before the replacement
  worker registers the same package function ids, avoiding function-owner
  conflicts while preserving the canonical sandbox lifecycle.
- The recording `worker::spawn` test fixture now scopes its child
  `grant::derive` idempotency key by spawn invocation id, matching the
  production activation grant shape and allowing a rollback to re-spawn the
  original worker id without idempotency collision.
- The new
  `module_upgrade_and_rollback_require_current_version_before_spawn_and_replay`
  proof covers missing/stale expected-version rejection before extra spawn/stop
  effects, successful local-process upgrade, idempotent replay, successful
  rollback to the prior activation version, revoked replaced grants, stopped
  replaced workers, and no duplicate child effects on replay.
- The new
  `module_quarantine_stale_activation_fails_before_stop_and_blocks_stale_grant`
  proof covers stale quarantine rejection before worker stop or grant revoke,
  successful quarantine of a local-process activation, sandbox worker stop,
  revoked activation grant, unregistered worker, and a closed error for a stale
  invocation after quarantine.
- The new
  `module_local_process_replacement_spawn_failure_marks_activation_failed_closed`
  proof covers replacement spawn failure after the superseded worker has been
  stopped, verifies the old grant is revoked, both old and replacement workers
  are absent, and inspects the activation resource lifecycle/payload to prove
  `activationStatus=failed`, `compensationState.status=failed_closed`,
  `runtimeDiagnostics.recoveryStatus=failed_closed`, and linked evidence refs.
- Existing proofs still cover configure secret boundaries, upgrade activation
  resource matching, grant replacement, disable grant revocation, explicit
  revocation enforcement through quarantine, and the real local-process disable
  path.
- Passing focused proof:
  `cargo test --manifest-path packages/agent/Cargo.toml module_activation::lifecycle_controls -- --nocapture`.

HMH-D6 evidence, 2026-06-02:

- No production-code change was required for D6. The existing install primitive
  is `module::register_package`: it is an idempotent, resource-backed
  capability operation that writes normalized `worker_package` resources.
- The model-facing primer already teaches agents to "install packaged modules
  with `module::register_package` over `worker_package` resources", then verify
  source trust, activate through `module::activate`, and record conformance or
  health evidence before lifecycle operations.
- The new
  `module_local_package_install_shape_is_resource_backed_and_rejects_implicit_remote_trust`
  proof registers a local digest-pinned `local_process` package, inspects the
  resulting `worker_package` resource and current payload, and verifies
  `sourceRef`, `sourceDigest`, `sourceTrustStatus=unverified`,
  `effectiveTrustTier=untrusted`, empty source evidence/approval refs, and
  server-authored package actions for verify, approve, conformance, configure,
  and activate.
- The same proof registers explicit local source policy through
  `module::register_source` as decision/evidence resources with
  `allowedPackageSelectors` and a bounded grant ceiling. It then rejects an
  unsupported `remote_url` package provenance without creating another
  `worker_package`, and rejects unsupported remote `sourceKind` registration
  through schema/policy validation.
- Passing proof:
  `cargo test --manifest-path packages/agent/Cargo.toml module_local_package_install_shape_is_resource_backed_and_rejects_implicit_remote_trust -- --nocapture`.

HMH-D7 evidence, 2026-06-02:

- Server truth was already proven by
  `generated_ui_can_author_package_and_activation_operator_surfaces`: generated
  `ui_surface` resources for package, worker-package resource, trust-root
  decision, and trust-audit schedule targets expose canonical module actions
  for source verification, conformance, trust simulation/review, audit
  scheduling/status/run/retention, trust-root renewal, signature-key rotation,
  expiry, revocation enforcement, and generated-surface refresh.
- The iOS red proof initially failed at compile time because
  `ControlSnapshotDTO` did not decode the server's `moduleHealth` and
  `moduleSourceTrust` fields and `EngineConsoleState` had no
  `moduleOperatorProjection`.
- The fix adds
  `packages/ios-app/Sources/ViewModels/State/EngineConsoleModuleProjection.swift`
  as a typed normalization layer over `control::snapshot` data. It preserves
  package/config/activation resources, module health evidence, source
  trust/approval/registration/trust-root/conformance evidence refs, warning
  codes, and every server-advertised `module::` action. Non-module actions are
  filtered out by namespace only, so Swift does not keep a package-policy
  allowlist or reconstruct action targets.
- `EngineConsoleModuleProjectionCard` now renders that projection in the
  Substrate section, replacing the prior read-only package-count card. The card
  shows counts, resource rows, trust/evidence rows, health/evidence rows, and
  server-advertised module action summaries. Mutations still go through
  generated `ui_surface` actions and `ui::submit_action`; iOS has no direct
  module lifecycle client or trust policy implementation.
- Passing iOS proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests`.
- Passing iOS source-boundary proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`.

HMH-D8 evidence, 2026-06-02:

- The existing module static gate already rejected `module::act`,
  `module::run_action`, sync `module::dispatch`, `control::act`, and local
  iOS `targetFunctionId` construction in `CapabilityClient.swift`.
- The strengthened gate now rejects generic package/action multiplexer names in
  the module primitive, control projections, generated module UI authoring, and
  every production Swift source file. The forbidden set includes generic
  `module::package_action`, `module::mutate_package`,
  `module::dispatch_package`, `module_action_multiplexer`,
  `package_action_multiplexer`, and `generic_package_mutation` markers.
- The iOS `SourceGuardTests` production-source scan now also rejects
  client-side module policy/action ownership strings such as `modulePolicy`,
  `packagePolicy`, `module::act`, and direct module lifecycle action ids while
  still allowing the server-owned generated-UI DTO shape.
- README now documents the absence rule: there is no generic `module::act` or
  package mutation multiplexer; module operator controls are server-advertised
  summaries over canonical `module::*` functions.
- Passing Rust absence proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`.
- Passing iOS source-boundary proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`.

Open loops after HMH-D1/HMH-D2/HMH-D3/HMH-D4/HMH-D5/HMH-D6/HMH-D7/HMH-D8:

- HMH-D and HMH-E1 are closed. Continue with HMH-E2 to prove generated UI for a
  new capability uses stored surface/version/action ids.

## HMH-E Scorecard: Human Harness And Generated UI

Scope: make the iOS app the intuitive human harness over the same substrate.

Out of scope: client-side target reconstruction or native-only feature forks.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-E1 | Engine Console is substrate-first | 15 | passed_after_fix | Console search/inspect covers workers, capabilities, modules, generated UI, traces, primer, conformance, and audit without a hardcoded tool catalog. | Stop if UI reads fixed capability descriptors. |
| HMH-E2 | Generated surface for new capability | 20 | pending | Engine creates a `ui_surface` for a session-created function; iOS renders it natively; submit references stored surface/version/action ids only. | Stop if iOS constructs target payloads. |
| HMH-E3 | Approval and consequence clarity | 15 | pending | iOS approval UI shows server risk/effect/authority/idempotency/lease/compensation metadata and resolves only through `approval::resolve`. | Stop if local approval state becomes final truth. |
| HMH-E4 | Module controls are native projections | 15 | pending | iOS can inspect/configure/activate/disable/upgrade/rollback/quarantine module packages through canonical server functions with evidence drill-down. | Stop if module policy appears in Swift. |
| HMH-E5 | Human can understand agent-created harness changes | 15 | pending | Session-created capability, provenance, tests, generated UI, promotion status, cleanup, and trace are visible in an ergonomic iPhone/iPad flow. | Fix UX before declaring north-star proof. |
| HMH-E6 | Visual proof covers iPhone and iPad | 10 | pending | Browser/Simulator/Computer Use proof includes device, UDID, bundle id, screenshots, action sequence, server rows, and return codes. | No screenshot-only proof without DB/event evidence. |
| HMH-E7 | Disconnected cache is read-only | 10 | pending | Offline Engine Console cache cannot submit generated actions, approvals, module changes, or policy edits. | Fix before live UI closeout. |

Closeout commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/GeneratedUIRendererTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests
```

HMH-E1 evidence, 2026-06-02:

- The red audit found the Engine Console's capability-search chips were still a
  fixed Swift mini catalog (`Read files`, `Run command`, `Search web`,
  `Ask user`, `Spawn worker`) even though the rest of the Console already
  loaded live status, registry documents/bindings, control snapshots, audit,
  policies, generated UI refs, and program runs.
- The fix replaces fixed search chips with
  `EngineConsoleState.substrateSearchSuggestions`, a projection over live
  server substrate state: status/index primer context, registry
  implementations/documents, control-advertised actions, module packages,
  generated `ui_surface` refs, redacted audit event/trace ids, and program-run
  ids/traces. The suggestions are search queries only; inspect and mutation
  paths still go through `CapabilityClient`, `control::snapshot`,
  `ui::inspect_surface`, generated `ui_surface` actions, and server-owned
  capability/admin primitives.
- The new
  `searchSuggestionsProjectLiveSubstrate` proof seeds a fake live substrate
  with a dynamic implementation, worker document, module action, module package
  resource, generated surface, trace/audit event, primer status, conformance
  state, and program run. It verifies the suggestion queries are all derived
  from those server-owned inputs and that the former fixed catalog queries are
  absent.
- `SourceGuardTests` now asserts the Engine Console wires
  `EngineConsoleSuggestionChips(suggestions: state.substrateSearchSuggestions)`,
  that the projection reads registry/control/audit/program/primer inputs, and
  that `EngineConsoleComponents.swift` does not keep the removed fixed
  suggestion strings.
- Passing state proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleStateTests`.
- Passing source-boundary proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`.
- Passing accessibility proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineConsoleAccessibilityTests`.

Open loops after HMH-E1:

- Continue with HMH-E2: prove the engine creates a `ui_surface` for a
  session-created function, iOS renders it natively, and submit references
  stored surface/version/action ids only.

## HMH-F Scorecard: Causality, Safety, Loops, And Rollback

Scope: prove modularity does not create unsafe autonomous mutation paths.

Out of scope: exactly-once guarantees or automatic rollback for irreversible
external effects.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-F1 | Idempotency is mandatory for mutations | 15 | pending | Mutating worker/module/ui/promotion/queue/resource paths reject missing/conflicting idempotency before handler execution. | Stop if child invocation starts before idempotency reservation. |
| HMH-F2 | Approval resume preserves original context | 15 | pending | Approval-required execute stores pause state and resumes same trace/grant/parent/idempotency after `approval::resolve`; agent cannot self-resolve. | Stop if approval creates disconnected child commands. |
| HMH-F3 | Trigger delivery modes are bounded | 15 | pending | Sync, Void, and Enqueue carry causal metadata; Void is restricted to loss-tolerant effects; trigger cascades have loop/depth budgets and fail closed. | Stop on unbounded trigger recursion. |
| HMH-F4 | Queue/DLQ is inspectable | 15 | pending | Enqueue records receipt, attempts, leases, retries, cancellation, DLQ, replay, and compensation refs. | Stop if queue errors are log-only. |
| HMH-F5 | Leases and compensation are visible | 15 | pending | Shared worktree/files/process/module/generated-action mutations acquire leases and record compensation/manual recovery status. | Stop if high-risk effects lack recovery notes. |
| HMH-F6 | Trace and ledger explain the full graph | 15 | pending | One scenario traces client request to agent turn, worker spawn, catalog change, function invocation, approval/queue/resource events, and UI action. | Stop if trace correlation relies on timestamps. |
| HMH-F7 | Restart/disconnect chaos fails closed | 10 | pending | Server restart, worker socket loss, approval worker absence, vector index unavailable, and client reconnect states are explicit and non-optimistic. | Fix fail-open paths before final UI proof. |

Closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::approval engine::tests::queue engine::tests::leases -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture
```

## HMH-G Scorecard: Final Adversarial Closeout And Absence Gates

Scope: prove the full objective, not just individual feature presence.

Out of scope: marking implementation complete while any HMH-A through HMH-F row
is pending, indirectly verified, or stale.

| ID | Scenario | Weight | Status | Evidence | Stop/fix rule |
|----|----------|--------|--------|----------|---------------|
| HMH-G1 | Requirement-by-requirement completion audit | 20 | pending | Matrix maps each source-derived requirement and user objective clause to authoritative files, commands, tests, screenshots, DB rows, and scorecard rows. | Keep goal active if any requirement is indirect or missing. |
| HMH-G2 | Absence gates are current | 15 | pending | Static scans reject client policy/targets, prompt-expanded tool catalogs, fallback discovery, global dynamic visibility, alternate spawn, generic module action, and stale scorecard states. | Tighten tests before closeout. |
| HMH-G3 | Transcript/session audit | 15 | pending | Session audit searches prior failures and current campaign transcripts for repeated architecture drift, stale claims, or unfinished rows. | Add successor rows if patterns remain. |
| HMH-G4 | Live recursive loop rerun | 20 | pending | End-to-end HMH-B/HMH-E scenario reruns from clean temp state after fixes and passes without harness pollution. | Do not use earlier partial run as final proof. |
| HMH-G5 | Docs and README are canonical | 10 | pending | README, engine docs, iOS docs, scorecards, and module docs agree on current commands, surfaces, status, and residual risk. | Remove aspirational or stale claims. |
| HMH-G6 | Diff hygiene and dead-code scan | 10 | pending | Diff scan removes unrelated churn, AI-ish comments, redundant defensive checks, type escapes, stale compatibility code, and metadata noise. | Fix before ledger/final. |
| HMH-G7 | Ledger and final status are honest | 10 | pending | Ledger entry records completed work and remaining successor scope; no scorecard says 100/100 while Next Test implies active work. | Keep goal active if implementation is not fully proven. |

Closeout commands:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo test --manifest-path packages/agent/Cargo.toml --test hyper_modular_architecture_plan_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture
git diff --check
```

## Adversarial Audit Of This Portfolio

Strong findings:

- Tron already has the right primitive vocabulary in code, not only docs:
  `worker::protocol_guide`, canonical `worker::spawn`, scoped worker tokens,
  module package/resource lifecycle, `capabilities.primer`, generated
  `ui_surface` resources, and iOS thin-client generated-UI submission are all
  current substrate pieces.
- The iii attachment thesis maps cleanly to Tron's intended specialization:
  iii's shared worker bus becomes Tron's local-first engine fabric; `iii worker
  add` becomes governed worker/module capability calls; the live catalog remains
  server truth; and iOS is a human projection over the same substrate.
- The portfolio starts from a fresh baseline. Completed older scorecards are
  prerequisites and absence evidence, not proof that this recursive harness
  loop has already been delivered.

Failure modes this portfolio is designed to catch:

- **Modular in docs, not in the agent turn.** HMH-C requires provider-visible
  transcripts so a model proves it knows the lifecycle at action time.
- **Worker creation without self-knowledge.** HMH-B requires the agent to obtain
  the worker guide, author the worker, spawn it, inspect it, test it, invoke it,
  and explain evidence without source-searching for hidden protocol details.
- **Installable modules that bypass safety.** HMH-D requires module activation
  to compose through `worker::spawn`, source trust, narrowed grants,
  conformance, health, and resource evidence.
- **Human harness as a second engine.** HMH-E requires iOS proof and negative
  checks that Swift never owns policy, approval truth, generated action target
  reconstruction, module trust, or capability routing.
- **Live discovery without causality.** HMH-F requires idempotency, approval
  resume, queue/DLQ, leases, compensation, loop budgets, and trace/ledger
  linkage for the whole graph.
- **Scorecard closure by rhetoric.** HMH-G requires a requirement-by-requirement
  completion audit against authoritative current state before any final
  implementation closeout.

Residual risk:

- This portfolio is a complete plan, not runtime proof. The north-star system is
  not complete until HMH-A through HMH-G have passed with live evidence.
- The official iii docs can evolve. Implementation checkpoints should record
  retrieval dates or commit hashes for any external facts they still depend on.
- A single portfolio file is easier to review now, but execution owners may
  split lanes into separate scorecards once a lane begins; when that happens,
  each split file must inherit the same row weights, evidence contracts, and
  static gates.

## Static Gates

- README must link this execution portfolio and the planning scorecard.
- `hyper_modular_architecture_plan_invariants` must assert this portfolio has
  HMH-A through HMH-G, source-derived requirements, primitive/plane budget,
  operating loop, closeout commands, and no stale attachment-source error.
- Existing absence gates in `threat_model_invariants.rs` must remain the broad
  production safety net for public dotted methods, client-owned targets,
  approval truth, generated UI target reconstruction, alternate worker spawn
  paths, and module escape hatches.
- Future implementation scorecards may split these rows into separate files,
  but this portfolio remains the owner until each split file is linked,
  statused, and guarded.

## Final Closeout Criteria

The north-star objective is not complete until all of the following are true:

- HMH-A through HMH-G are passed or explicitly delegated to linked successor
  scorecards with honest remaining scope.
- A clean end-to-end run proves that an ordinary agent can learn, author or
  install, spawn/activate, discover, inspect, test, invoke, explain, expose UI
  for, promote or discard, and clean up a scoped capability through `execute`
  and canonical server capabilities.
- iOS visual/action proof shows the same substrate is intuitive for humans and
  does not own policy, approval, target reconstruction, or module trust.
- Static gates prove the old alternate planes did not return.
- README and living docs describe only working, verified behavior.
- Ledger records the campaign checkpoint before final response.

## Next Test

HMH-A, HMH-B, HMH-C, HMH-D, and HMH-E1 are closed. Continue with HMH-E2:
prove generated UI for a new capability uses stored surface/version/action ids.

```bash
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/GeneratedUIRendererTests
```
