# Engine Capability Pool And Kernel Evolution Scorecard

Status: **accepted**

This scorecard closes the semantic gap between model-facing
`capability::execute` operations and engine/catalog functions. Tron now has one
canonical capability-pool classification model while still preserving the
important surface distinction:

- `agent_operation`: an operation the model may invoke through
  `capability::execute`.
- `catalog_function`: an engine function registered in the live catalog for
  transport, iOS, domain workers, runtime workers, diagnostics, or kernel
  substrate.

The goal is full inspectability without collapsing trust boundaries. Internal
catalog functions are not hidden from audit, but they do not masquerade as
normal session actions. Each unit is classified by audience, replacement class,
visibility, minimality decision, authority boundary, evidence boundary, and
evolution path.

## Artifacts

- Machine-readable inventory:
  `packages/agent/docs/engine-capability-pool-inventory.tsv`
- Evidence manifest:
  `packages/agent/docs/engine-capability-pool-evidence-manifest.md`
- Runtime classification:
  `packages/agent/src/domains/capability/pool.rs`

## Replacement Classes

| Class | Meaning | Runtime rule |
|---|---|---|
| `runtime_routable` | A governed route may switch execution to a validated module-owned replacement. | Requires candidate validation, shadow evidence, user approval, activation, route events, disable, and rollback. |
| `producer_extensible` | Modules may add producers, records, workers, or richer projections. | Server-owned resource custody, redaction, replay, and trace refs remain mandatory. |
| `kernel_evolution_only` | This unit is part of the trusted kernel/governance/transport substrate. | It is improvable only through source-level candidate change, validation, adversarial review, user-approved integration, and rollback evidence. |

## Audiences

| Audience | Meaning |
|---|---|
| `session_work` | Useful for ordinary user-session work. |
| `agent_diagnostics` | Useful when diagnosing Tron, catalog state, traces, logs, or engine freshness. |
| `governance` | Used to propose, validate, approve, activate, inspect, or roll back modular behavior. |
| `engine_internal` | Needed by the engine/iOS/runtime substrate, not a normal agent action. |
| `kernel_evolution` | Relevant when evaluating source-level improvements to the root of trust. |

## Visibility Policy

Normal capability discovery should prefer `default_visible` and
`search_visible` agent operations. Catalog functions are inspectable, but they
default to `inspect_only` or `hidden_unless_evolution_mode` unless they are
diagnostic bridges such as catalog-discovery functions or the
`capability::execute` bridge itself.

## Scorecard

| ID | Check | Weight | Status | Evidence |
|---|---|---:|---|---|
| ECP-1 | Execute operation coverage | 15 | accepted | Every `SUPPORTED_OPERATION_NAMES` entry has one `agent_operation` inventory row. |
| ECP-2 | Catalog function coverage | 15 | accepted | Every startup-registered catalog function has one `catalog_function` inventory row. |
| ECP-3 | Surface distinction | 10 | accepted | Discovery annotations explain when to invoke `capability::execute` versus inspect catalog substrate. |
| ECP-4 | Replacement classification | 15 | accepted | Every row is classified as `runtime_routable`, `producer_extensible`, or `kernel_evolution_only`. |
| ECP-5 | Minimality closure | 10 | accepted | Every row records whether it stays core/governance/transport or is a module candidate. |
| ECP-6 | Kernel evolution path | 10 | accepted | Kernel/governance rows name source-level validation and adversarial review as their improvement path. |
| ECP-7 | Agent discovery ergonomics | 10 | accepted | Provider-visible catalog guidance separates session-useful operations from internal/evolution substrate. |
| ECP-8 | UI language alignment | 10 | accepted | Cockpit top-level counts use operation language and drill into substrate only as needed. |
| ECP-9 | Static gates | 5 | accepted | Focused Rust tests, docs drift checks, personal-info guard, whitespace check, and no managed skills guard. |

## Kernel Evolution Protocol

Kernel/governance functions are not runtime-routed. Tron can still improve them
through a verified source-level path:

1. Inspect the capability-pool row and current source owner.
2. Record the concrete gap or failure with evidence.
3. Create a source-level candidate change on a branch/worktree.
4. Run focused tests, relevant static gates, and replay or differential checks.
5. Run simulator validation when UI/protocol behavior changes.
6. Run adversarial review.
7. Require explicit user approval for integration.
8. Merge, validate from `main`, push, and verify ancestry.
9. Preserve rollback evidence and explain the change through cockpit/session
   audit surfaces.

## Hard Rules

- `capability::execute` remains the only model-facing tool.
- Catalog functions are inspectable substrate, not a second normal model-facing
  tool family.
- `kernel_evolution_only` rows cannot be runtime-routed.
- `producer_extensible` rows cannot bypass server-owned resource custody.
- `runtime_routable` rows require candidate, shadow, approval, activation,
  event, disable, and rollback evidence before routing.
- No raw local paths, commands, logs, secrets, grant IDs, authority IDs, schema
  internals, or hidden reasoning should appear in top-level user/provider
  surfaces.
