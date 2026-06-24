# Self-Sufficient Agent Runtime Readiness Inventory

Status: `complete`
Machine-readable inventory:
[`self-sufficient-agent-runtime-readiness-inventory.tsv`](self-sufficient-agent-runtime-readiness-inventory.tsv)

This inventory maps current primitive-engine extension points to future
self-sufficient/self-adapting runtime readiness dimensions. It distinguishes
implemented primitive substrate from forbidden successor features and historical
evidence. The audit does not implement generated workers, learned rules/memory,
tool synthesis, or agent-authored state systems.

## Controlled Vocabulary

Readiness dimensions:

- `generated_workers`
- `learned_rules_memory`
- `tool_synthesis`
- `agent_authored_state`
- `runtime_orchestration_auditability`
- `public_protocol_ios_shell`
- `static_gates_docs`
- `historical_quarry_classification`

Implementation states:

- `ready_extension_point`: current primitive substrate can support future work
  after a separate design and tests.
- `future_prerequisite`: current boundary is useful but missing future policy,
  schema, migration, lifecycle, or authority design.
- `historical_evidence`: retained evidence or stale branch classification, not
  current architecture authority.
- `forbidden_successor_feature`: explicitly absent or rejected by static gates.
- `static_gate`: docs/tests/CI wiring that guards SSARR truthfulness.

## Readiness Matrix

| Future surface | Current owner/proof | Current readiness | Blocker/risk | No-implementation decision |
| --- | --- | --- | --- | --- |
| Generated workers | `engine/runtime/external_workers`, `engine/durability/queue`, `engine/runtime/triggers`, `engine/mod.rs` | The host, worker protocol, scoped grants, queue receipts, triggers, streams, and ledger records are clean extension points. | Missing future worker authoring, activation, schedule, launch, approval, and rollback policy. | SSARR does not add worker authoring, worker schedule, worker activation, scheduler/autostart, or generated-worker runtime code. |
| Learned rules/memory | `domains/capability/operations/state.rs`, `domains/agent/runtime/service/context.rs`, `engine/durability/resources`, `domains/session/event_store` | Agent-owned state is persisted and projected into context; resources/session evidence can custody future artifacts. | Missing explicit schema, retention, privacy, migration, compaction, and trust policy for learned behavior. | SSARR does not add learned-memory stores, repo-managed rules, first-party skills, or separate memory planes. |
| Tool synthesis | `domains/capability/contract.rs`, `domains/model/protocol`, `transport/engine/contracts.rs`, `engine/catalog` | The current model-facing surface is one `execute` tool, while engine catalog/promote/worker contracts can host future authority-gated synthesis. | Future synthesized-tool lifecycle needs schema, provenance, idempotency, compensation, security, and provider portability rules. | SSARR does not widen `execute`, add generated capability lifecycle, or convert public `promote` into a tool-synthesis API. |
| Agent-authored state | `engine/durability/resources`, `engine/durability/state`, `domains/session/event_store`, `shared/foundation/paths` | State/resources/events/traces/logs already provide durable custody and evidence surfaces. | Future agent-authored state needs migration/versioning, cleanup, quota, and ownership policy. | SSARR does not check in unowned state, generated code, skills, memory, or product catalogs. |
| Runtime orchestration/auditability | ODA, DSEMD, PERF, CSD, SOL, SACB artifacts plus engine queue/trigger/ledger code | Existing closeout proof covers bounded queues, durable receipts, replay/log/trace evidence, migrations, security, and shutdown preconditions. | Future autonomy still needs explicit runtime policy and failure semantics for generated behavior. | SSARR records cross-links instead of adding autonomous orchestration behavior. |
| Public protocol/iOS shell | `transport/engine`, `packages/ios-app/docs/architecture.md`, `GeneratedRuntimeSurfaceView.swift` | Public context is strict and iOS renders generic runtime data. | Future UI/action semantics need protocol/versioning and simulator coverage when Swift changes. | SSARR does not add self-adapting product panels or iOS successor-specific UI. |
| Static gates/docs | SSARR invariant, README, local/GitHub closeout lists, predecessor inventories | SSARR artifacts are wired into existing closeout parity gates. | New successor terms or artifacts need future guard updates. | SSARR guards current truth and records no-feature scope. |
| Historical/quarry classification | OPSAA/PET evidence and stale SSARR branch identity | Historical wording remains available as provenance. | Historical evidence can look current without classification. | SSARR classifies quarry/historical material and rejects active completion claims. |

## Source Findings

- Current source already separates engine substrate (`EngineHost`,
  `EngineHostHandle`, trigger runtime, external workers, queue/resource/state
  stores) from domain workers and transport surfaces.
- The single provider-visible tool remains `capability::execute`; its schema
  does not expose function/catalog/tool-synthesis targets.
- Agent-owned state exists through primitive state operations and context
  projection; no separate learned-memory store or repo-managed skill surface is
  present.
- Generic `ui_surface` resources and iOS `GeneratedRuntimeSurfaceView` are
  retained runtime rendering substrate, not a successor product panel system.
- Public `/engine` `promote` is user-owned engine visibility promotion with
  idempotency and authority requirements, not a public tool-synthesis or
  client-side catalog edit API.
- Historical PET/OPSAA/IOSTC wording about self-adapting agents, generated
  workers, learned memory/rules, and successor UI is retained as evidence or
  future-readiness context, not current completed architecture.

## Evidence Policy

Every row in the TSV names a proof source and scorecard rows. Paths must be
tracked or present unless the row is explicitly historical branch evidence or an
absent forbidden successor feature such as `packages/agent/skills/`.
