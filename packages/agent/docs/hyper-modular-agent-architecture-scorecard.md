# Hyper Modular Agent Architecture Planning Scorecard

Created: 2026-06-02

Initial score: **0/100**

Current score: **100/100**

Status: **completed planning artifact**

Implementation execution status: **not started by this planning scorecard**

Scope:
- Source-backed plan for moving Tron from the current live capability fabric to
  the north star: a hyper modular, plug-and-play agent harness where the agent
  can discover, create, test, use, explain, and promote harness capabilities.
- Translation of iii's worker/function/trigger philosophy into Tron-specific
  server, agent, iOS, module, trust, generated-UI, and evidence requirements.
- Successor scorecard portfolio, evidence contracts, static gates, and
  adversarial audit requirements for the implementation campaign.

Out of scope:
- Implementing every successor row in this planning checkpoint.
- Copying iii engine code or depending directly on iii runtime internals.
- Replacing completed cleanup, collapsed-engine, token-accounting, iPad, or
  action-time scorecards. This plan composes those results and assigns the next
  execution work.

## Summary

This scorecard closes the planning layer for the modular-agent-harness goal.
iii's useful idea is a small live primitive model: workers register functions
and triggers; the engine is the registry; new capabilities join the system
without a new integration category. Tron's specialization should keep that
collapse while adding local-first authority, idempotency, approval, provenance,
scoped visibility, generated UI, and a model-facing `execute` harness that
teaches the agent how to modify the harness safely.

Canonical truth owner: the Tron server engine substrate. iOS is the intuitive
human harness and native projection surface, not the owner of routing, policy,
generated action targets, approvals, grants, or durable state.

## Primary Source Basis

The two pasted text attachments in this thread are the primary iii philosophy
source for this plan:

- `/Users/moose/.codex/attachments/0af3ea78-c386-4055-ba8d-6e04c8eb5c49/pasted-text.txt`
  (90 lines, 15,598 bytes): installable substrate, live worker catalog,
  same operation for agent and human extension, worker/function/trigger
  composition, realtime discovery, and same-contract platform/application
  workers.
- `/Users/moose/.codex/attachments/053a570d-434a-4879-bb93-1db134477b7c/pasted-text.txt`
  (78 lines, 19,751 bytes): decomposed agent harness jobs, independently
  swappable harness workers, durable turn loop, policy/approval/budget/hooks,
  skills and prompt assembly as bus-driven layers, and harness thickness as a
  worker-count slider.

Official public iii materials were checked on 2026-06-02 to verify external
facts and avoid relying only on pasted prose:

- iii manifesto: https://iii.dev/manifesto
- iii home/product page: https://iii.dev/
- iii primitives docs: https://iii.dev/docs/0-10-0/primitives-and-concepts/functions-triggers-workers
- iii discovery docs: https://iii.dev/docs/0-10-0/primitives-and-concepts/discovery
- iii functions/triggers how-to: https://iii.dev/docs/0-10-0/how-to/use-functions-and-triggers
- iii trigger actions docs: https://iii.dev/docs/0-10-0/how-to/trigger-actions
- iii request/response format docs: https://iii.dev/docs/0-10-0/how-to/define-request-response-formats
- iii queues docs: https://iii.dev/docs/0-10-0/how-to/use-queues
- iii protocol docs: https://iii.dev/docs/0-10-0/advanced/protocol
- iii console docs: https://iii.dev/docs/0-10-0/console
- official iii GitHub README/license map: https://github.com/iii-hq/iii

Source-backed facts used by this plan:

- iii's mental model is workers, functions, and triggers. A worker is a joined
  process, a function is callable work, and a trigger causes a function to run.
- `iii worker add` is the important product operation because it installs a
  complete running worker that registers functions/triggers into the live
  system rather than importing a library into each neighbor.
- The agent and the human use the same operation to extend the same system:
  install or author a worker, watch the catalog change, then call the new
  functions through the same bus.
- The harness is a stack of workers, not a framework block. Turn
  orchestration, provider routing, credentials, model catalog, approvals,
  policy, budget tracking, hooks, session state, skills, prompt assembly,
  compaction, streams, and observability are independently replaceable layers.
- Discovery is live: connected workers receive current functions and topology
  changes as workers connect, disconnect, register, or unregister functions.
- Functions are cross-language and cross-service callable through the engine.
- Trigger actions distinguish synchronous invocation, fire-and-forget `Void`,
  and durable `Enqueue`.
- Queues add retry, concurrency, optional FIFO ordering, receipts, and DLQ
  inspection.
- Function registrations carry request/response formats and metadata.
- The console makes workers, functions, triggers, state, streams, traces, logs,
  and direct invocation visible in real time.
- The official README explicitly frames the agent story as: agents use the same
  catalog and function calls, and workers can create other workers at runtime.
- The repository license boundary matters: iii engine is ELv2; SDK, console,
  docs, CLI, and website are Apache-2.0. Tron should adopt the primitive model
  and avoid importing the iii engine as a dependency.

## Current Tron Baseline

Evidence from the current codebase:

- `packages/agent/docs/engine-redesign/README.md` already names Tron as a live
  capability fabric: `namespace::function` capabilities owned by workers,
  invoked by triggers, and recorded through the ledger.
- `packages/agent/docs/engine-redesign/iii-teardown.md` already identifies the
  iii primitives to adopt, the Tron-specific divergences, and the anti-goals.
- `packages/agent/docs/engine-redesign/target-engine-design.md` defines worker,
  function, trigger, transport, guardrail, stream, state, queue, approval,
  lease, and compensation contracts.
- `packages/agent/docs/engine-redesign/tron-capability-matrix.md` maps current
  worker namespaces, visibility, effect classes, idempotency, and risk notes.
- `packages/agent/src/engine/mod.rs` documents a revisioned live catalog,
  primitive workers, scoped external-worker tokens, generated UI resources,
  worker package lifecycle, and ledger-backed causality.
- `packages/agent/src/engine/primitives/mod.rs` owns primitive workers for
  streams, state, queue, resource, trigger, grant, approval, catalog, worker,
  observability, UI, module, and storage.
- `packages/agent/src/domains/capability/mod.rs` keeps the provider surface
  tiny with model-facing `execute` and operator/internal search, inspect,
  policy, plugin, binding, conformance, primer, and audit functions.
- `packages/agent/src/domains/sandbox/mod.rs` exposes sandbox-created workers
  through canonical `worker::spawn`, scoped tokens, derived grants, expected
  function ids, catalog registration waiting, and cleanup.
- `packages/ios-app/docs/architecture.md` describes iOS as a thin `/engine`
  client with capability-native invocation/result rendering, server-owned
  approval resolution, Engine Console, and server-authored generated UI.
- Completed scorecards have already removed many legacy planes:
  `collapsed-engine-hardening-scorecard.md`,
  `codebase-cleanup-scorecard.md`,
  `legacy-fallback-cleanup-pass-scorecard.md`,
  `token-accounting-hardening-scorecard.md`,
  `post-scorecard-gap-hardening-scorecard.md`, and the active
  `ipad-action-time-followup-scorecard.md`.

Baseline conclusion: Tron has the substrate vocabulary and much of the
infrastructure. The remaining work is to prove the recursive harness loop:
agent knows the loop, uses it without guessing, creates a scoped capability,
tests it, explains it, exposes a native/generated UI affordance when useful,
and promotes or discards it under audited authority.

## North-Star Requirements

1. The engine is the only executable substrate.
   All executable behavior is a canonical capability. No client-owned policy,
   handler-shaped RPC shortcut, hidden prompt tool catalog, fallback dispatch,
   or compatibility alias may become a second execution plane.

2. The model-facing harness stays tiny and live.
   Providers see `execute` only. Search, inspect, schema validation, freshness,
   approval, idempotency, target resolution, generated UI, and promotion are
   internal phases over the live catalog, not prompt-expanded tool lists.

3. The agent knows the harness is modifiable.
   Turn context, `capabilities.primer`, recipes, docs, and execute guidance must
   teach the exact lifecycle for discovering, spawning, testing, invoking,
   publishing UI, promoting, rolling back, and disconnecting capabilities.

4. Self-created capabilities are scoped by default.
   Agent-created workers/functions start session-visible, with narrowed derived
   grants, namespace claims, expected function ids, expiry, provenance, health,
   conformance state, and cleanup. Workspace/system promotion is explicit.

5. Plug-and-play modules are runtime participants.
   Worker packages, source trust, config, activation, conformance, upgrade,
   rollback, quarantine, trust audits, key rotation, revocation, and retention
   evidence must be capability functions and typed resources.

6. Every mutation has an idempotency and authority story.
   Mutating or durable functions require idempotency contracts; high-risk work
   requires approval; shared resources require leases; irreversible/high-risk
   effects require compensation notes; trigger cascades require budgets.

7. The causal ledger is the explanation surface.
   Every catalog mutation, worker spawn, trigger fire, queue receipt, approval,
   resource write, generated UI action, promotion, rollback, and retry is
   inspectable by actor, grant, trace, parent, target revision, catalog
   revision, idempotency key, and result.

8. iOS is the human harness, not a parallel engine.
   The iOS app should make the system intuitive and easy to operate: capability
   search/inspect, generated UI, approvals, module/package controls, evidence,
   and action-time confirmation. It must not own target reconstruction,
   authorization, fallback state, approval truth, or policy.

9. Generated UI is a first-class harness customization path.
   The engine authors fixed-catalog `ui_surface` resources for current
   capability targets. Clients render them natively and submit stored action
   coordinates; the server reconstructs and authorizes the target invocation.

10. The implementation proves absence, not just presence.
    Static gates and scenario harnesses must prove no legacy/fallback/dead
    paths reappear, tests stay split, docs stay linked, and completed
    scorecards do not drift back into active state.

## Primitive And Plane Budget

Durable primitives:

- Worker: live actor with namespace claims, lifecycle, authority, provenance,
  health, and visibility.
- Function: callable capability contract with schema, effect, risk, authority,
  idempotency, approval, lease, compensation, revision, provenance, selected
  implementation, and context-primer metadata.
- Trigger: causal rule with delivery mode, actor, grant, trace, parent, target
  revision, catalog revision, idempotency, retry/DLQ, and loop budget.
- Resource: typed durable object for artifacts, goals, claims, evidence,
  decisions, generated UI, module packages, materialized files, and harness
  docs.
- Grant: delegated authority with namespace, visibility, effect, invocation,
  trigger, and promotion ceilings.
- Ledger: explanation and replay substrate for invocations, catalog changes,
  idempotency, queues, approvals, leases, compensation, and resource lineage.

Planes that must not exist:

- Client-side approval, generated action target, policy, or routing truth.
- Static prompt dump that claims to be the catalog.
- Dotted method compatibility path or handler-shaped transport shim.
- Global visibility default for session-created capabilities.
- Schema-only safety without authority, idempotency, risk, and loop policy.
- Fallback lexical-only discovery without explicit degraded status.
- Silent worker/module activation without conformance and provenance evidence.

## Execution Scorecard Portfolio

These successor lanes are the implementation plan. The fresh, detailed
execution portfolio is now materialized in
`packages/agent/docs/hyper-modular-agent-harness-execution-scorecards.md`.
This planning scorecard keeps the summary table below so the closed planning
artifact still names the whole campaign.

| ID | Successor scorecard | Weight | Status | Owner | Evidence contract |
|----|---------------------|--------|--------|-------|-------------------|
| HMA-A | Source-backed primitive model and current-state audit | 10 | planned_successor | docs_or_scorecard | Primary iii source map, local docs/code audit, README link, static plan gate. |
| HMA-B | Agent self-modifying capability lifecycle | 20 | planned_successor | engine_capability_runtime | Live scenario: agent receives recipe, calls `worker::protocol_guide`, writes a local worker, spawns it with expected ids, observes catalog change, inspects schema, runs conformance, invokes through `execute`, disconnects, and verifies cleanup/ledger. |
| HMA-C | Harness knowledge and context compiler | 15 | planned_successor | agent_runner_context | `capabilities.primer` and execute guidance teach the full lifecycle without prompt bloat; provider-visible transcript shows the model can repair missing fields and choose discovery/inspect/execute/promotion steps. |
| HMA-D | Plug-and-play module/package lifecycle | 15 | planned_successor | module_trust_runtime | Package registration, source verification, activation, config, health, conformance, upgrade, rollback, quarantine, revocation, scheduled trust audit, and resource evidence work through canonical `module::*` capabilities. |
| HMA-E | Human harness and generated UI north star | 15 | planned_successor | ios_generated_ui | iOS renders server-authored generated surfaces, action summaries, approvals, module controls, and evidence flows on iPhone/iPad with visual proof and no client-side target reconstruction. |
| HMA-F | Causality, safety, loops, and rollback | 15 | planned_successor | engine_policy_ledger | Mutations require idempotency; high-risk work pauses for approval; leases protect shared resources; trigger cascades have budgets; queue retries/DLQ and compensation records are inspectable. |
| HMA-G | Final adversarial closeout and absence gates | 10 | planned_successor | test_harness | Static scans, integration tests, transcript audits, large-file gates, README/docs, and ledger prove no fallback/dead/compatibility planes or stale scorecard states remain. |

## Required Scenario Rows For HMA-B

HMA-B is the critical proof row for the user's hypothesis. Minimum scenarios:

| ID | Scenario | Evidence |
|----|----------|----------|
| HMA-B1 | Agent is taught the self-modification lifecycle | Provider transcript or deterministic runner fixture shows the model reads execute guidance, asks for discovery when needed, and names `worker::protocol_guide`, `worker::spawn`, conformance, invoke, promote/disconnect without guessed fields. |
| HMA-B2 | Session worker creation | Temp worker script registers one harmless read function under a session namespace; `worker::spawn` derives a narrowed grant and waits for expected ids. |
| HMA-B3 | Catalog watch and inspection | Catalog revision changes, watch emits availability, `execute` can inspect the new function, and schema/provenance/visibility/health appear in the result. |
| HMA-B4 | Invocation through the tiny harness | Provider-visible `execute` invokes the new function; child invocation, trace, grant, idempotency, and result appear in the ledger. |
| HMA-B5 | Conformance and promotion request | Conformance records pass/fail as resources; workspace/system promotion requires expected revision and explicit idempotency, then records catalog-change evidence. |
| HMA-B6 | Cleanup and failure isolation | Disconnect removes session-visible functions or marks durable workers unhealthy; stale invocations fail closed; no UI/client cache can keep the function callable. |

## Required Scenario Rows For HMA-C

| ID | Scenario | Evidence |
|----|----------|----------|
| HMA-C1 | Context budget stays bounded | `capabilities.primer` includes lifecycle recipes and selected first-party core capability summaries without dumping the whole catalog. |
| HMA-C2 | Execute correction is enough | Missing-field, stale revision, ambiguous target, trigger-id target, and approval-required results all provide actionable repair guidance in provider-visible text. |
| HMA-C3 | Harness docs are resources | Agent-readable harness docs and recipes are resource/capability-backed, versioned, searchable, and tied to catalog revisions. |
| HMA-C4 | Agent can explain its substrate | A model-run fixture asks how to customize the harness; answer cites live capabilities and exact safety gates, not stale README prose. |

## Required Scenario Rows For HMA-D

| ID | Scenario | Evidence |
|----|----------|----------|
| HMA-D1 | Module package lifecycle is capability-native | Every package/trust/config/action path is a canonical `module::*` function with resource evidence and no generic `module::act` escape hatch. |
| HMA-D2 | Activation composes worker spawn | Module activation can spawn or connect a worker without holding host locks and without bypassing worker-token/grant policy. |
| HMA-D3 | Trust is revocable and inspectable | Source trust, signatures, revocation, expiry, key rotation, and trust-review evidence are queryable by agent and visible to iOS operator surfaces. |
| HMA-D4 | Marketplace shape is local-first | Installing a capability package is a local resource/module operation; no remote marketplace, package download, or source approval is trusted without explicit policy. |

## Required Scenario Rows For HMA-E

| ID | Scenario | Evidence |
|----|----------|----------|
| HMA-E1 | Generated surface for new capability | Engine creates a `ui_surface` for the session-created function; iOS renders it; action submission references stored surface/action ids only. |
| HMA-E2 | Approval and consequence clarity | iOS shows risk/effect/authority/idempotency/lease consequences from server metadata and uses canonical `approval::resolve`. |
| HMA-E3 | Operator console is substrate-first | Engine Console searches/inspects workers, capabilities, modules, generated UI, traces, primer, and audit without hardcoded tool catalogs. |
| HMA-E4 | iOS visual proof | iPhone and iPad screenshots or simulator proof cover core flows, generated UI, approvals, module control, and evidence drill-down. |

## Required Scenario Rows For HMA-F

| ID | Scenario | Evidence |
|----|----------|----------|
| HMA-F1 | Idempotency is mandatory for mutations | Mutating worker/module/ui/promotion/queue paths reject missing or conflicting idempotency before handler execution. |
| HMA-F2 | Approval resume preserves context | Approval-required execution resumes the original invocation trace/grant/parent/idempotency rather than starting a disconnected command. |
| HMA-F3 | Trigger cascade budgets | Sync, void, and enqueue delivery paths carry causal depth and loop budgets; runaway trigger graphs fail closed with ledger records. |
| HMA-F4 | Queue/DLQ evidence is inspectable | Enqueued work records receipt, attempts, leases, retry, cancellation, DLQ, and replay/compensation state. |
| HMA-F5 | Rollback/compensation visible | High-risk module, source-control, filesystem, process, and generated action paths expose compensation records even when automatic rollback is not possible. |

## Adversarial Audit

Strong findings:

- Tron already matches the iii primitive philosophy better than a normal RPC
  rewrite. The engine docs and module docs repeatedly collapse behavior into
  worker/function/trigger/resource/grant/ledger primitives.
- The provider surface is intentionally smaller than iii's worker-facing API:
  `execute` keeps model schemas stable while preserving live catalog change.
  This is the right Tron specialization if the guidance and recipes are strong.
- iOS is correctly modeled as a thin human harness, especially around approval,
  generated UI, Engine Console, and event/cache boundaries.

Risks that must be attacked before implementation closeout:

- The substrate can exist without the agent reliably knowing it can customize
  the harness. HMA-C must prove this with model-visible transcripts, not only
  docs.
- Worker spawn and module activation can become operator-only features unless
  `execute` recipes and turn context make the lifecycle obvious at action time.
- Generated UI can become a pretty inspection surface instead of a genuine
  harness-modification surface unless new/self-created capabilities can produce
  server-authored surfaces and iOS can submit their actions.
- Static gates prove absence of some old paths, but they do not prove the full
  recursive loop. HMA-B/HMA-E need live integration evidence.
- `Void` trigger delivery is dangerous for important side effects. Tron should
  keep it only for explicitly loss-tolerant telemetry-like paths and still
  record causality.
- Schemas are necessary but insufficient. Authority, idempotency, risk,
  approval, leases, loop budgets, and provenance must remain enforced in engine
  policy before handler execution.
- The cleanup pass intentionally left current `isLegacy`/`isDeprecated` model
  DTO keys as protocol facts. Future compatibility words must keep current
  boundary ownership or be removed.

## Static Gates

- This planning scorecard must stay linked from the README living-doc map.
- The separate static gate
  `packages/agent/tests/hyper_modular_architecture_plan_invariants.rs` must
  assert the source map, current-state evidence, successor portfolio, detailed
  HMH execution file, north-star requirements, adversarial audit, and completed
  planning score are present.
- Future implementation scorecards may split HMH-A through HMH-G from
  `hyper-modular-agent-harness-execution-scorecards.md` into separate files,
  but the portfolio owns their status, evidence contract, and residual scope
  until those files exist.
- No implementation checkpoint may add a client-owned policy/approval/generated
  action target plane, global session-worker visibility default, hidden
  compatibility dispatch path, fallback discovery path, or unowned large-file
  growth.

## Closeout Criteria For This Planning Scorecard

- README living-doc map links this plan.
- README living-doc map links the detailed HMH execution portfolio.
- Static plan invariant passes.
- Formatting/diff checks pass.
- Ledger records that the north-star planning artifact was created.
- The active goal can be considered complete only for the requested planning
  objective. The implementation successor rows remain future execution work.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence | Residual risk | Checkpoint |
|----|------|--------|--------|-------|----------|---------------|------------|
| HMA-0 | Scorecard formalization | 10 | passed_after_fix | docs_or_scorecard | Added this scorecard with scope, out-of-scope, primitive/plane budget, attachment-backed source map, successor portfolio, static gates, and closeout criteria. | None for the planning layer; implementation proof belongs to the HMH execution portfolio. | this checkpoint |
| HMA-1 | iii source synthesis | 15 | passed_after_fix | docs_or_scorecard | The two pasted text attachments are now the explicit primary philosophy source; official iii materials checked on 2026-06-02 verify primitives, live discovery, functions/triggers, trigger actions, schema metadata, queues, protocol, console, README agent framing, and license boundary. | Public docs may evolve; successor rows should cite exact versions or commit hashes when implementing. | this checkpoint |
| HMA-2 | Current Tron baseline audit | 15 | passed | docs_or_scorecard | Audited engine redesign docs, capability matrix, engine/primitive/capability/sandbox module docs, iOS architecture, completed scorecards, and static gates. | Live runtime proof is successor work. | this checkpoint |
| HMA-3 | North-star requirements | 15 | passed | engine_architecture | Derived ten concrete requirements for engine substrate, tiny live harness, agent knowledge, scoped self-modification, modules, idempotency/authority, causal ledger, iOS human harness, generated UI, and absence proof. | Requirements must be decomposed into implementation scorecards before code work. | this checkpoint |
| HMA-4 | Successor execution portfolio | 20 | passed_after_fix | docs_or_scorecard | Defined HMA-A through HMA-G summary lanes here and created `packages/agent/docs/hyper-modular-agent-harness-execution-scorecards.md` with fresh detailed HMH-A through HMH-G row weights, evidence contracts, gates, closeout commands, and final audit criteria. | The HMH portfolio rows are ready for execution but not implemented by this planning checkpoint. | this checkpoint |
| HMA-5 | Adversarial audit | 15 | passed | docs_or_scorecard | Listed strong findings and risks that could make the system modular in docs but not in agent action-time behavior. | Must be repeated after each successor scorecard. | this checkpoint |
| HMA-6 | Closeout verification | 10 | passed | test_harness | Added the README link and `hyper_modular_architecture_plan_invariants` static gate. Closeout commands: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`; `cargo test --manifest-path packages/agent/Cargo.toml --test hyper_modular_architecture_plan_invariants -- --nocapture`; `git diff --check`. | Implementation successor scorecards remain future work by design. | this checkpoint |

## Next Test

The planning artifact is closed. Implementation should start with HMH-A in the
fresh execution portfolio, then proceed to HMH-B or HMH-C depending on whether
the next checkpoint prioritizes live worker-spawn proof or agent turn-context
proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hyper_modular_architecture_plan_invariants -- --nocapture
```
