# Capability Dynamic Replacement Scorecard

Status: **implementation candidate**

Current score: **64/100**

This scorecard tracks the path from measurable modularity to governed dynamic
replacement. It is intentionally narrower than "self-update everything": the
first route target is the read-only `git_status` operation, and the route is
scoped, explicit, versioned, auditable, disableable, and rollbackable. The
minimal engine remains responsible for registry truth, grants, resource
custody, redaction, trace/audit, module governance, route decisions, and
fail-closed routing.

The current implementation can record candidates, route bindings, route
activations, route events, and route rollbacks. The dispatcher can resolve an
active scoped `git_status` route and annotate the built-in provider-safe status
projection with route evidence. It does **not** yet invoke a live module-owned
adapter projection because the supervised module runtime has not exposed a
synchronous provider-safe adapter projection call.

Source of truth:

- Registry: `packages/agent/src/domains/capability/operations/registry.rs`
- Dispatcher seam: `packages/agent/src/domains/capability/operations/git.rs`
- Route governance: `packages/agent/src/domains/capability_binding/route.rs`
- Resource definitions: `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs`
- Inventory: `packages/agent/docs/capability-dynamic-replacement-inventory.tsv`
- Evidence: `packages/agent/docs/capability-dynamic-replacement-evidence-manifest.md`

Provider-visible surface remains one tool: `capability::execute`.

## Weighted Scorecard

| Area | Weight | Status | Score | Acceptance |
|---|---:|---|---:|---|
| Runtime route model | 15 | partial | 10 | Active replacement routes are explicit, versioned, scoped, and reversible. Current `git_status` route lookup is exact-scope and reversible, but live module adapter execution is deferred. |
| Candidate module contract | 15 | partial | 10 | Candidates publish schemas, authority, risk, evidence, lifecycle, and rollback controls. Current candidate records enforce bounded contract evidence, exact accepted shadow-evidence resource/version proof, and refs; module runtime projection invocation is not yet executable. |
| Shadow execution | 12 | passed | 12 | Built-in and candidate can run side by side safely before activation. Current shadow trial is metadata-only for `git_status` and preserves no-candidate-execution proof. |
| Activation and routing | 14 | partial | 8 | Only approved adapter-replaceable/module-owned operations can route to candidates. Current activation is limited to `git_status`, requires approval refs, candidate/binding/shadow-evidence stale guards, and annotates built-in projection under the active route. |
| Rollback and disable | 12 | passed | 12 | Every route can be disabled, rolled back, and audited deterministically. Current route events and rollback resources provide terminal route controls. |
| Agent workflow | 10 | partial | 5 | Tron can inspect gaps, propose replacements, run trials, request approval, activate, and explain results. The records support this workflow; full scripted stress workflow remains next. |
| Cockpit/session visibility | 10 | partial | 3 | User sees what changed, why, current owner, route state, failures, and rollback actions. Current cockpit sees new operations through the catalog; dedicated route-state cockpit sections remain next. |
| Tests/stress harness | 8 | partial | 2 | Simulator and backend stress tests prove real replacement workflows. Static invariants are present; full route lifecycle and simulator stress tests remain next. |
| Minimal-engine guardrails | 4 | passed | 4 | Kernel/governance operations remain non-routable and no fallback/legacy paths return. Route operations are governance-locked and do not create package-manager, network, deploy, or raw-material side effects. |

## Runtime Route Model

The dispatcher has one route seam today:

```text
capability::execute(git_status)
  -> built-in Git status provider-safe projection
  -> scoped capability route lookup
       no active route -> return built-in projection
       active route -> verify route/binding/candidate refs
                    -> emit route event
                    -> annotate result.dynamicReplacement
                    -> return built-in projection with route evidence
```

This is deliberately not a domain-specific module adapter executor. The route
resolver only chooses whether a governed route exists and whether it is safe to
surface route evidence. It fails closed if route records are stale, terminal,
wrong-scope, missing authority evidence, missing referenced records, or unsafe.

## Route Records

| Record | Purpose |
|---|---|
| `capability_replacement_candidate` | Candidate contract, owner, module/runtime/lifecycle refs, schema/effect/risk evidence, exact authority constraints, rollback controls, safe audit refs, and `networkPolicy: none`. |
| `capability_route_binding` | Exact-scope link from a validated candidate to a versioned route binding with activation gates. |
| `capability_route_activation` | Approval-backed active route state with rollback and disable controls. |
| `capability_route_event` | Activation, routed invocation, disable, and rollback history. |
| `capability_route_rollback` | Deterministic built-in restoration proof. |

## Guardrails

- `kernel_locked` and `governance_locked` operations cannot be dynamic
  replacement targets.
- The first route target is only `git_status`.
- No write operation is eligible in this slice.
- `capability::execute` remains the only model-facing tool.
- Route activation requires explicit approval refs.
- Route lookup is exact scope and expected-version guarded.
- Route records cannot use wildcard selectors or `agent_state` inheritance.
- Route records cannot invoke package managers, restore dependencies, access
  networks, deploy, mutate dispatch tables, expose raw paths/commands/logs/code,
  expose raw grants/authority IDs, or touch repo-managed `packages/agent/skills`.

## Agent Workflow

1. Inspect the cockpit/capability catalog and identify an adapter-replaceable
   operation gap.
2. Inspect the operation schema, modularity scorecard row, authority
   constraints, and current owner.
3. Record a replacement candidate rationale with lifecycle/runtime refs,
   rollback controls, and provider-safe contract evidence.
4. Run the shadow trial and inspect shadow evidence.
5. Request user approval for route activation.
6. Activate the scoped route when approved.
7. Invoke the operation and inspect route events.
8. Explain what changed using route events and evidence refs.
9. Disable or roll back if verification fails.

## Deferred Work

- Add a supervised module-runtime adapter projection call so an active route can
  execute the module-owned provider-safe projection instead of annotating the
  built-in projection.
- Add dedicated Engine Cockpit and Session Briefing route-state sections:
  current owner, candidate owner, active/shadow/disabled/rolled-back state,
  last verification, failed adaptations, and rollback action detail.
- Add end-to-end lifecycle tests that create a candidate, approve a shadow
  trial, activate a route, invoke `git_status`, disable it, roll it back, and
  inspect route events.
- Add simulator stress tests that verify the cockpit and session briefing tell
  the replacement story without raw IDs or low-level material at top level.
